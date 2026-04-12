import Foundation
import PrimuseKit

actor LRCLIBScraper: MusicScraper {
    let type = MusicScraperType.lrclib

    private let session: URLSession
    private var lastRequestTime: ContinuousClock.Instant?
    private let minInterval: Duration = .milliseconds(200)

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0 (iOS Music Player)"]
        self.session = URLSession(configuration: config)
    }

    // MARK: - MusicScraper

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        .empty(.lrclib) // Lyrics only, no search
    }

    func getDetail(externalId: String) async throws -> ScraperDetail? {
        nil
    }

    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] {
        []
    }

    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? {
        // externalId format: title|artist|album|duration
        let parts = externalId.split(separator: "|", maxSplits: 3).map(String.init)
        guard parts.count >= 2 else { return nil }

        let title = parts[0]
        let artist = parts[1]
        let album = parts.count > 2 ? parts[2] : nil
        let duration = parts.count > 3 ? TimeInterval(parts[3]) : nil

        return try await fetchLyrics(title: title, artist: artist, album: album, duration: duration)
    }

    /// Direct lyrics fetch (used by ScraperManager)
    func fetchLyrics(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) async throws -> ScraperLyricsResult? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album {
            queryItems.append(URLQueryItem(name: "album_name", value: album))
        }
        let safeDuration = duration?.sanitizedDuration ?? 0
        if safeDuration > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(safeDuration.rounded(.down)))))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return nil }

        let data = try await throttledRequest(url: url)
        let result = try JSONDecoder().decode(LRCLibResponse.self, from: data)

        guard result.syncedLyrics != nil || result.plainLyrics != nil else {
            return nil
        }

        return ScraperLyricsResult(
            source: .lrclib,
            lrcContent: result.syncedLyrics,
            plainText: result.plainLyrics
        )
    }

    // MARK: - Rate Limiting

    private func throttledRequest(url: URL) async throws -> Data {
        if let last = lastRequestTime {
            let elapsed = ContinuousClock.now - last
            if elapsed < minInterval {
                try await Task.sleep(for: minInterval - elapsed)
            }
        }
        lastRequestTime = .now
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ScraperError.notFound
        }
        return data
    }

    // MARK: - Models

    private struct LRCLibResponse: Codable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }
}
