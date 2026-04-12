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
                        query: cleanedTitle, artist: artist, album: nil, limit: 15
                    )
                    NSLog("🔍 \(config.type.displayName) returned \(searchResult.items.count) results")
                    if let best = searchResult.items.first {
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
                        query: cleanedTitle, artist: artist, album: nil, limit: 15
                    )
                    if let best = searchResult.items.first {
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
                        let searchResult = try await scraper.search(
                            query: cleanedTitle, artist: artist, album: nil, limit: 15
                        )
                        if let best = searchResult.items.first {
                            if let lyricsResult = try await scraper.getLyrics(externalId: best.externalId),
                               lyricsResult.hasLyrics {
                                result.lyrics = parseLyrics(lyricsResult)
                                if result.lyrics != nil { break }
                            }
                        }
                    }
                } catch {
                    await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
                    result.errors.append("[\(config.type.displayName)] lyrics: \(error.localizedDescription)")
                }
            }
        }

        return result
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
