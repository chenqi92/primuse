import Foundation

enum MusicScraperFactory {
    static func create(for config: ScraperSourceConfig) -> any MusicScraper {
        switch config.type {
        case .musicBrainz:
            MusicBrainzScraper()
        case .lrclib:
            LRCLIBScraper()
        case .itunes:
            ITunesScraper()
        case .custom(let configId):
            if let scraperConfig = ScraperConfigStore.shared.config(for: configId) {
                ConfigurableScraper(config: scraperConfig, cookie: config.cookie)
            } else {
                // Config not found — return a no-op scraper
                EmptyScraper(type: config.type)
            }
        }
    }
}

/// Placeholder scraper for missing configs — returns empty results.
actor EmptyScraper: MusicScraper {
    let type: MusicScraperType
    init(type: MusicScraperType) { self.type = type }
    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult { .empty(type) }
    func getDetail(externalId: String) async throws -> ScraperDetail? { nil }
    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] { [] }
    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? { nil }
}
