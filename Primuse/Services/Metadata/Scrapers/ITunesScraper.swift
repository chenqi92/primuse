import Foundation

/// Native scraper backed by Apple's public iTunes Search API.
/// Documentation: https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/
/// No auth required; Apple's loose rate limit is ~20 req/min/IP.
actor ITunesScraper: MusicScraper {
    let type = MusicScraperType.itunes

    private let session: URLSession
    private var lastRequestTime: ContinuousClock.Instant?
    private let minInterval: Duration = .milliseconds(200)

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = [
            "User-Agent": "Primuse/1.0 (iOS Music Player)",
            "Accept": "application/json",
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - MusicScraper

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        var keyword = query
        if let artist, !artist.isEmpty { keyword += " \(artist)" }
        if let album, !album.isEmpty { keyword += " \(album)" }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: keyword),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]

        guard let url = components.url else { return .empty(.itunes) }

        let data = try await throttledRequest(url: url)
        let result = try JSONDecoder().decode(ITunesSearchResult.self, from: data)

        let items = result.results.compactMap { track -> ScraperSearchItem? in
            guard let trackId = track.trackId else { return nil }
            return ScraperSearchItem(
                externalId: String(trackId),
                source: .itunes,
                title: track.trackName ?? "",
                artist: track.artistName,
                album: track.collectionName,
                year: track.releaseYear,
                durationMs: track.trackTimeMillis,
                coverUrl: track.coverURL(size: 300),
                trackNumber: track.trackNumber,
                genres: track.primaryGenreName.map { [$0] }
            )
        }
        return ScraperSearchResult(items: items, source: .itunes)
    }

    func getDetail(externalId: String) async throws -> ScraperDetail? {
        guard let track = try await lookup(id: externalId) else { return nil }
        return ScraperDetail(
            externalId: externalId,
            source: .itunes,
            title: track.trackName ?? "",
            artist: track.artistName,
            albumArtist: track.artistName,
            album: track.collectionName,
            year: track.releaseYear,
            trackNumber: track.trackNumber,
            discNumber: track.discNumber,
            durationMs: track.trackTimeMillis,
            genres: track.primaryGenreName.map { [$0] },
            coverUrl: track.coverURL(size: 600)
        )
    }

    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] {
        guard let track = try await lookup(id: externalId),
              let full = track.coverURL(size: 600) else { return [] }
        return [
            ScraperCoverResult(
                source: .itunes,
                coverUrl: full,
                thumbnailUrl: track.coverURL(size: 150)
            )
        ]
    }

    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? {
        nil // iTunes Search API doesn't expose lyrics.
    }

    // MARK: - Private

    private func lookup(id: String) async throws -> ITunesTrack? {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components.url else { return nil }

        let data = try await throttledRequest(url: url)
        let result = try JSONDecoder().decode(ITunesSearchResult.self, from: data)
        return result.results.first
    }

    private func throttledRequest(url: URL) async throws -> Data {
        if let last = lastRequestTime {
            let elapsed = ContinuousClock.now - last
            if elapsed < minInterval {
                try await Task.sleep(for: minInterval - elapsed)
            }
        }
        lastRequestTime = .now
        let (data, _) = try await session.data(from: url)
        return data
    }

    // MARK: - Models

    private struct ITunesSearchResult: Decodable {
        let resultCount: Int
        let results: [ITunesTrack]
    }

    private struct ITunesTrack: Decodable {
        let trackId: Int?
        let trackName: String?
        let artistName: String?
        let collectionName: String?
        let trackTimeMillis: Int?
        let trackNumber: Int?
        let discNumber: Int?
        let releaseDate: String?
        let primaryGenreName: String?
        let artworkUrl100: String?

        var releaseYear: Int? {
            guard let date = releaseDate, date.count >= 4 else { return nil }
            return Int(String(date.prefix(4)))
        }

        /// Apple stores artwork at fixed sizes; URL ends with `/<W>x<H>bb.jpg`.
        /// Replacing the suffix gets a higher-resolution variant on the same CDN.
        func coverURL(size: Int) -> String? {
            guard let base = artworkUrl100 else { return nil }
            return base.replacingOccurrences(
                of: #"/\d+x\d+bb\.jpg$"#,
                with: "/\(size)x\(size)bb.jpg",
                options: .regularExpression
            )
        }
    }
}
