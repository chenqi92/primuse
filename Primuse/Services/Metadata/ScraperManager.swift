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
        let cleanedTitle = Self.cleanTitle(title)

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
                        if let data = try await downloadImage(url: coverUrl) {
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
                           let data = try await downloadImage(url: coverUrl) {
                            result.coverData = data
                            break
                        }
                    }
                } catch {
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

    private func downloadImage(url: String) async throws -> Data? {
        guard let imageURL = URL(string: url) else { return nil }
        let (data, response) = try await URLSession.shared.data(from: imageURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return data
    }

    private func parseLyrics(_ result: ScraperLyricsResult) -> [LyricLine]? {
        if let lrc = result.lrcContent, !lrc.isEmpty {
            let parsed = LyricsParser.parse(lrc)
            return parsed.isEmpty ? nil : parsed
        }
        return nil
    }

    /// Remove bracket content that interferes with search
    /// e.g. "只爱西经 (中四版)" → "只爱西经"
    static func cleanTitle(_ title: String) -> String {
        var result = title
        result = result.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "（[^）]*）", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "【[^】]*】", with: "", options: .regularExpression)
        if let dashRange = result.range(of: "\\s*[–—-]\\s+", options: .regularExpression) {
            result = String(result[result.startIndex..<dashRange.lowerBound])
        }
        result = result.trimmingCharacters(in: .whitespaces)
        result = result.replacingOccurrences(of: "^\\d+[.\\s]+", with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespaces)
    }
}
