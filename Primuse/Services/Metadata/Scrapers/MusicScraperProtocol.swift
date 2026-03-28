import Foundation

protocol MusicScraper: Sendable {
    var type: MusicScraperType { get }

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult

    func getDetail(externalId: String) async throws -> ScraperDetail?

    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult]

    func getLyrics(externalId: String) async throws -> ScraperLyricsResult?
}

enum ScraperError: Error, LocalizedError {
    case networkError(String)
    case parseError(String)
    case notFound
    case rateLimited(retryAfter: Int?)

    var errorDescription: String? {
        switch self {
        case .networkError(let msg): msg
        case .parseError(let msg): msg
        case .notFound: "Not found"
        case .rateLimited: "Rate limited"
        }
    }
}
