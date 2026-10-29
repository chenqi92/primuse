import Foundation

protocol MusicScraper: Sendable {
    var type: MusicScraperType { get }

    func isCoolingDown() async -> Bool

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult

    func getDetail(externalId: String) async throws -> ScraperDetail?

    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult]

    func getLyrics(externalId: String) async throws -> ScraperLyricsResult?
}

extension MusicScraper {
    func isCoolingDown() async -> Bool { false }
}

protocol AlbumMusicScraper: MusicScraper {
    func searchAlbums(title: String, artist: String?, limit: Int) async throws -> [ScraperAlbum]
    func albumTracks(externalID: String) async throws -> [ScraperDetail]
}

/// 不靠搜索候选、直接按歌名和歌手取歌词的源（LRCLIB、歌词 API 服务、AMLL）。
/// 刮削时绕过「搜索 → 取歌词」那一套，由各源自己决定怎么查、怎么认。
protocol DirectLyricsLookup: MusicScraper {
    func fetchLyrics(
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?
    ) async throws -> ScraperLyricsResult?
}

enum ScraperError: Error, LocalizedError {
    case networkError(String)
    case parseError(String)
    case notFound
    case rateLimited(retryAfter: Int?)
    case noEnabledSource
    case busy

    var errorDescription: String? {
        switch self {
        case .networkError(let msg): msg
        case .parseError(let msg): msg
        case .notFound: String(localized: "error_not_found")
        case .rateLimited: String(localized: "error_rate_limited")
        case .noEnabledSource: String(localized: "scraper_no_source_message")
        case .busy: String(localized: "intent_scrape_busy")
        }
    }
}
