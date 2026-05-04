import Foundation
import PrimuseKit

actor ScraperManager {
    private var scraperCache: [String: any MusicScraper] = [:]

    struct ScrapeNeeds: Sendable {
        var metadata: Bool = true
        var cover: Bool = true
        var lyrics: Bool = true
    }

    func scrapeMetadata(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?,
        needs: ScrapeNeeds,
        settings: ScraperSettings
    ) async -> ScrapeResult {
        var result = ScrapeResult(errors: [])
        let enabledSources = settings.enabledSources

        // Clean title for better search results (remove brackets, numbering etc.)
        let cleanedTitle = Self.searchTitle(title, artist: artist)

        // Scrape metadata from first successful source
        if needs.metadata {
            for config in enabledSources where config.type.supportsMetadata {
                do {
                    NSLog("🔍 Scraping metadata from \(config.type.displayName) for '\(cleanedTitle)'")
                    let scraper = getScraper(for: config)
                    let searchResult = try await scraper.search(
                        query: cleanedTitle, artist: artist, album: nil, limit: Self.autoScrapeLimit
                    )
                    NSLog("🔍 \(config.type.displayName) returned \(searchResult.items.count) results")
                    if let best = Self.bestMatch(in: searchResult.items, title: title, artist: artist, durationMs: durationMs(duration)) {
                        result.detail = try await scraper.getDetail(externalId: best.externalId)
                        if result.detail != nil { break }
                    }
                } catch {
                    NSLog("🔍 \(config.type.displayName) FAILED: \(error.localizedDescription)")
                    await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
                    result.errors.append("[\(config.type.displayName)] metadata: \(error.localizedDescription)")
                }
            }
        }

        // Scrape cover from first successful source
        if needs.cover {
            for config in enabledSources where config.type.supportsCover {
                do {
                    let scraper = getScraper(for: config)

                    // If we already have a detail with cover URL from the same source, use it
                    if let detail = result.detail, detail.source == config.type, let coverUrl = detail.coverUrl {
                        if let data = try await downloadImage(url: coverUrl, sourceConfig: config) {
                            result.coverData = data
                            break
                        }
                    }

                    // Otherwise search and get cover
                    let searchResult = try await scraper.search(
                        query: cleanedTitle, artist: artist, album: nil, limit: Self.autoScrapeLimit
                    )
                    if let best = Self.bestMatch(in: searchResult.items, title: title, artist: artist, durationMs: durationMs(duration)) {
                        let covers = try await scraper.getCoverArt(externalId: best.externalId)
                        if let coverUrl = covers.first?.coverUrl,
                           let data = try await downloadImage(url: coverUrl, sourceConfig: config) {
                            result.coverData = data
                            break
                        }
                    }
                } catch {
                    await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
                    result.errors.append("[\(config.type.displayName)] cover: \(error.localizedDescription)")
                }
            }
        }

        // Scrape lyrics from first successful source
        if needs.lyrics {
            plog("🎤 Lyrics tier: needs.lyrics=true, enabled sources w/ supportsLyrics: \(enabledSources.filter { $0.type.supportsLyrics }.map { $0.type.displayName })")
            for config in enabledSources where config.type.supportsLyrics {
                do {
                    let scraper = getScraper(for: config)

                    if config.type == .lrclib, let artist {
                        // LRCLIB uses direct lookup, not search
                        let lrclibScraper = scraper as! LRCLIBScraper
                        if let lyricsResult = try await lrclibScraper.fetchLyrics(
                            title: cleanedTitle, artist: artist, album: album, duration: duration
                        ), lyricsResult.hasLyrics {
                            result.lyrics = parseLyrics(lyricsResult)
                            if result.lyrics != nil { break }
                        }
                    } else {
                        // Standard search → getLyrics flow
                        // 选 top-3 候选依次 try, 优先返字级歌词的; 都没字级才
                        // 用第一个行级 fallback。这样同源内 score 相同的几个
                        // 候选(常见: title+duration 都接近)能挑到带逐字的版本。
                        let searchResult = try await scraper.search(
                            query: cleanedTitle, artist: artist, album: nil, limit: Self.autoScrapeLimit
                        )
                        let candidates = Self.topMatches(
                            in: searchResult.items, title: title, artist: artist,
                            durationMs: durationMs(duration), maxCount: 3
                        )
                        plog("🎤 [\(config.type.displayName)] lyrics search: \(searchResult.items.count) items → top \(candidates.count) candidates: \(candidates.map { "\($0.title)/\($0.artist ?? "?")" })")
                        var lineLevelFallback: [LyricLine]?
                        var triedCount = 0
                        var hasLyricsCount = 0
                        for candidate in candidates {
                            triedCount += 1
                            do {
                                guard let lyricsResult = try await scraper.getLyrics(externalId: candidate.externalId),
                                      lyricsResult.hasLyrics else { continue }
                                hasLyricsCount += 1
                                guard let parsed = parseLyrics(lyricsResult), !parsed.isEmpty else { continue }
                                if parsed.contains(where: { $0.isWordLevel }) {
                                    plog("🎤 [\(config.type.displayName)] picked WORD-level lyrics from '\(candidate.title)' (\(parsed.count) lines)")
                                    result.lyrics = parsed
                                    break
                                } else if lineLevelFallback == nil {
                                    lineLevelFallback = parsed
                                }
                            } catch {
                                plog("🎤 [\(config.type.displayName)] getLyrics failed for '\(candidate.title)': \(error.localizedDescription)")
                            }
                        }
                        if result.lyrics == nil, let fb = lineLevelFallback {
                            plog("🎤 [\(config.type.displayName)] picked LINE-level fallback (\(fb.count) lines)")
                            result.lyrics = fb
                        }
                        if result.lyrics == nil {
                            plog("🎤 [\(config.type.displayName)] NO lyrics found: tried=\(triedCount) hasLyrics=\(hasLyricsCount) — moving to next source")
                        }
                        if result.lyrics != nil { break }
                    }
                } catch {
                    plog("🎤 [\(config.type.displayName)] lyrics tier ERROR: \(error.localizedDescription)")
                    await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
                    result.errors.append("[\(config.type.displayName)] lyrics: \(error.localizedDescription)")
                }
            }
            if result.lyrics == nil {
                plog("🎤 Lyrics tier: NO source returned lyrics, result.lyrics=nil")
            }
        } else {
            plog("🎤 Lyrics tier: needs.lyrics=false, skipped")
        }

        return result
    }

    /// 自动刮削每个源拉这么多候选,然后用 `bestMatch` 多维度选最优。
    /// 之前是 15 + 取首位,实测经常错配（"冷酷到底"被刮成 Amrit Maan 那种）。
    /// 5 个候选下 server 通常会把官方主推排前面,且足够 scoring 区分。
    private static let autoScrapeLimit = 5

    private nonisolated func durationMs(_ d: TimeInterval?) -> Int? {
        guard let d, d > 0 else { return nil }
        return Int(d * 1000)
    }

    /// 多维度评分挑最佳候选:
    /// - duration 接近度（最强信号,误差 < 2s 满分,2-5s 中等,5-10s 弱）
    /// - title 完全相等 / 互相包含
    /// - artist 命中
    ///
    /// 全部维度都没匹配上时,fallback 取 `items.first`(server 默认顺序)。
    static func bestMatch(
        in items: [ScraperSearchItem],
        title: String,
        artist: String?,
        durationMs targetMs: Int?
    ) -> ScraperSearchItem? {
        topMatches(in: items, title: title, artist: artist, durationMs: targetMs, maxCount: 1).first
    }

    /// 评分后取前 N 个候选(按分数降序)。供 lyrics 阶段依次 try、优先字级使用。
    /// 全部都 0 分时 fallback 用 server 默认顺序。
    static func topMatches(
        in items: [ScraperSearchItem],
        title: String,
        artist: String?,
        durationMs targetMs: Int?,
        maxCount: Int
    ) -> [ScraperSearchItem] {
        guard !items.isEmpty else { return [] }
        let normTitle = normalizeComparableText(title)
        let normArtist = normalizeComparableText(artist)

        let scored = items.map { item -> (ScraperSearchItem, Int) in
            (item, score(item: item, normTitle: normTitle, normArtist: normArtist, targetMs: targetMs))
        }
        // 全部 0 分 = 没任何维度匹配上,直接用 server 顺序
        if scored.allSatisfy({ $0.1 == 0 }) {
            return Array(items.prefix(maxCount))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(maxCount).map(\.0)
    }

    private static func score(
        item: ScraperSearchItem,
        normTitle: String,
        normArtist: String,
        targetMs: Int?
    ) -> Int {
        var s = 0

        // duration 维度（最强信号）— 准确性最高,放最大权重
        if let target = targetMs, let itemMs = item.durationMs {
            let diff = abs(itemMs - target)
            if diff < 2000 { s += 50 }
            else if diff < 5000 { s += 30 }
            else if diff < 10000 { s += 10 }
            else { s -= 20 }     // 差距超 10s 直接扣分,大概率不是同一首
        }

        // title 维度
        let itemTitle = normalizeComparableText(item.title)
        if itemTitle == normTitle { s += 30 }
        else if !itemTitle.isEmpty && !normTitle.isEmpty {
            if itemTitle.contains(normTitle) || normTitle.contains(itemTitle) { s += 15 }
        }

        // artist 维度
        if !normArtist.isEmpty, let itemArtist = item.artist {
            let itemNormArtist = normalizeComparableText(itemArtist)
            if !itemNormArtist.isEmpty {
                if itemNormArtist == normArtist { s += 20 }
                else if itemNormArtist.contains(normArtist) || normArtist.contains(itemNormArtist) { s += 10 }
            }
        }

        return s
    }

    // MARK: - Helpers

    private func getScraper(for config: ScraperSourceConfig) -> any MusicScraper {
        if let cached = scraperCache[config.id] {
            return cached
        }
        let scraper = MusicScraperFactory.create(for: config)
        scraperCache[config.id] = scraper
        return scraper
    }

    /// Invalidate cached scrapers (e.g., when settings change)
    func invalidateCache() {
        scraperCache.removeAll()
    }

    private func downloadImage(url: String, sourceConfig: ScraperSourceConfig) async throws -> Data? {
        try await ConfigurableScraper.downloadResource(from: url, sourceConfig: sourceConfig)
    }

    private func parseLyrics(_ result: ScraperLyricsResult) -> [LyricLine]? {
        if let lrc = result.lrcContent, !lrc.isEmpty {
            let parsed = LyricsParser.parse(lrc)
            return parsed.isEmpty ? nil : parsed
        }
        return nil
    }

    static func searchTitle(_ title: String, artist: String?) -> String {
        let cleanedTitle = cleanTitle(title)
        let cleanedArtist = normalizeComparableText(artist)

        guard !cleanedArtist.isEmpty,
              let split = splitTitleAroundDash(cleanedTitle) else {
            return cleanedTitle
        }

        if normalizeComparableText(split.left) == cleanedArtist, !split.right.isEmpty {
            return split.right
        }
        if normalizeComparableText(split.right) == cleanedArtist, !split.left.isEmpty {
            return split.left
        }

        return cleanedTitle
    }

    static func shouldAppendArtist(to query: String, artist: String?) -> Bool {
        let cleanedArtist = normalizeComparableText(artist)
        guard !cleanedArtist.isEmpty else { return false }
        return !normalizeComparableText(query).contains(cleanedArtist)
    }

    /// Remove bracket content and noisy prefixes that interfere with search.
    static func cleanTitle(_ title: String) -> String {
        var result = title
        result = result.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "（[^）]*）", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "【[^】]*】", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "^\\d+[.\\s]+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func splitTitleAroundDash(_ title: String) -> (left: String, right: String)? {
        guard let dashRange = title.range(of: "\\s*[–—-]\\s+", options: .regularExpression) else {
            return nil
        }
        let left = String(title[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let right = String(title[dashRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !left.isEmpty, !right.isEmpty else { return nil }
        return (left, right)
    }

    private static func normalizeComparableText(_ text: String?) -> String {
        guard let text else { return "" }
        return cleanTitle(text)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: "[\\s·•・_\\-–—]+", with: "", options: .regularExpression)
    }
}
