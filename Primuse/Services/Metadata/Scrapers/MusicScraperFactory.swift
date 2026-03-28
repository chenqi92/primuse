import Foundation

enum MusicScraperFactory {
    static func create(for config: ScraperSourceConfig) -> any MusicScraper {
        switch config.type {
        case .source_b:
            source_bScraper()
        case .source_e:
            source_eScraper()
        case .source_d:
            source_dScraper()
        case .source_c:
            source_cScraper(cookie: config.cookie)
        case .source_a:
            source_aScraper(cookie: config.cookie)
        case .musicBrainz:
            MusicBrainzScraper()
        case .lrclib:
            LRCLIBScraper()
        }
    }
}
