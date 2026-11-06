import Foundation
import PrimuseKit

/// Native scraper backed by Apple's public iTunes Search API.
/// Documentation: https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/
/// No auth required; Apple's loose rate limit is ~20 req/min/IP.
actor ITunesScraper: AlbumMusicScraper {
    let type = MusicScraperType.itunes

    private let session: URLSession
    static let servicePolicy = RequestQuota.Service.appleCatalog.policy
    private static let quota = RequestQuota.appleCatalog(for: URL(string: "https://itunes.apple.com/search")!)!
    private let requestExecutor: RequestExecutor?
    private let quotaRegistry: RequestQuotaRegistry

    init(session: URLSession? = nil, requestExecutor: RequestExecutor? = nil,
         quotaRegistry: RequestQuotaRegistry = .shared) {
        self.requestExecutor = requestExecutor
        self.quotaRegistry = quotaRegistry
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = [
            "User-Agent": "Primuse/1.0 (iOS Music Player)",
            "Accept": "application/json",
        ]
        self.session = URLSession(configuration: config)
    }

    func isCoolingDown() async -> Bool {
        if let requestExecutor {
            if await requestExecutor.isCoolingDown { return true }
        } else if await quotaRegistry.isCoolingDown(for: Self.quota) { return true }
        return await ScraperRequestPool.shared.isCoolingDown(for: .resource(type.rawValue))
    }

    // MARK: - MusicScraper

    func cooldownRemaining() async -> TimeInterval {
        let api = if let requestExecutor { await requestExecutor.cooldownRemaining }
            else { await quotaRegistry.cooldownRemaining(for: Self.quota) }
        return max(api, await ScraperRequestPool.shared.cooldownRemaining(for: .resource(type.rawValue)))
    }

    private var countryByTrack: [String: String] = [:]
    private var aliasesByArtist: [Int: Set<String>] = [:]

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        guard limit > 0 else { return .empty(.itunes) }
        let firstCountry = ScraperIdentity.containsHan(artist ?? "") ? "TW" : "US"
        let first = try await searchTracks(query: query, artist: artist, album: album, country: firstCountry, limit: limit)
        remember(first, country: firstCountry)
        var tracks = first
        func compatible(_ track: ITunesTrack) -> Bool {
            let aliases = track.artistId.flatMap { aliasesByArtist[$0] }.map(Array.init) ?? []
            let title = ScraperIdentity.filenameTitle(query, matching: track.artistName, aliases: aliases) ?? query
            return ScraperIdentity.titleMatches(title, track.trackName ?? "")
                && (artist?.isEmpty != false || ScraperIdentity.artistMatches(artist, track.artistName, aliases: aliases))
        }
        if !tracks.contains(where: compatible) {
            let secondCountry = firstCountry == "US" ? "TW" : "US"
            let second = try await searchTracks(query: query, artist: artist, album: album, country: secondCountry, limit: limit)
            remember(second, country: secondCountry)
            var ids = Set(tracks.compactMap(\.trackId))
            tracks += second.filter { $0.trackId.map { ids.insert($0).inserted } == true }
        }
        let items = tracks.compactMap { track -> ScraperSearchItem? in
            guard let trackId = track.trackId else { return nil }
            return ScraperSearchItem(
                externalId: "\(countryByTrack[String(trackId)] ?? firstCountry):\(trackId)", source: .itunes, title: track.trackName ?? "",
                artist: track.artistName, album: track.collectionName, year: track.releaseYear,
                durationMs: track.trackTimeMillis, coverUrl: track.coverURL(size: 300),
                trackNumber: track.trackNumber, genres: track.primaryGenreName.map { [$0] },
                artistAliases: track.artistId.flatMap { aliasesByArtist[$0] }.map { $0.sorted() } ?? []
            )
        }
        return ScraperSearchResult(items: items, source: .itunes)
    }

    private func searchTracks(query: String, artist: String?, album: String?, country: String, limit: Int) async throws -> [ITunesTrack] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: [query, artist, album].compactMap { $0 }.joined(separator: " ")),
            URLQueryItem(name: "media", value: "music"), URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200))),
            URLQueryItem(name: "country", value: country)
        ]
        let data = try await throttledRequest(url: components.url!)
        return try JSONDecoder().decode(ITunesSearchResult.self, from: data).results
    }

    private func remember(_ tracks: [ITunesTrack], country: String) {
        if countryByTrack.count > 500 { countryByTrack.removeAll(keepingCapacity: true) }
        if aliasesByArtist.count > 500 { aliasesByArtist.removeAll(keepingCapacity: true) }
        for track in tracks {
            if let id = track.trackId, countryByTrack[String(id)] == nil { countryByTrack[String(id)] = country }
            if let id = track.artistId, let name = track.artistName { aliasesByArtist[id, default: []].insert(name) }
        }
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
            coverUrl: track.coverURL(size: 600),
            artistAliases: track.artistId.flatMap { aliasesByArtist[$0] }.map { $0.sorted() } ?? []
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

    func searchAlbums(title: String, artist: String?, limit: Int) async throws -> [ScraperAlbum] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: [title, artist].compactMap { $0 }.joined(separator: " ")),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 200))),
        ]
        let data = try await throttledRequest(url: components.url!)
        return try JSONDecoder().decode(ITunesSearchResult.self, from: data).results.compactMap { album in
            guard let id = album.collectionId, let title = album.collectionName else { return nil }
            return ScraperAlbum(externalID: String(id), source: .itunes, title: title,
                                artist: album.artistName, year: album.releaseYear, trackCount: album.trackCount)
        }
    }

    func albumTracks(externalID: String) async throws -> [ScraperDetail] {
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: externalID),
                                URLQueryItem(name: "entity", value: "song"),
                                URLQueryItem(name: "limit", value: "200")]
        let data = try await throttledRequest(url: components.url!)
        let rows = try JSONDecoder().decode(ITunesSearchResult.self, from: data).results
        let album = rows.first { $0.trackId == nil && $0.collectionId.map(String.init) == externalID }
        var seen = Set<Int>()
        return rows.compactMap { track in
            guard track.collectionId.map(String.init) == externalID,
                  let id = track.trackId, let title = track.trackName, seen.insert(id).inserted else { return nil }
            return ScraperDetail(externalId: String(id), source: .itunes, title: title,
                                 artist: track.artistName, albumArtist: album?.artistName,
                                 album: album?.collectionName ?? track.collectionName,
                                 year: album?.releaseYear ?? track.releaseYear,
                                 trackNumber: track.trackNumber, discNumber: track.discNumber,
                                 durationMs: track.trackTimeMillis,
                                 genres: track.primaryGenreName.map { [$0] }, coverUrl: track.coverURL(size: 600))
        }
    }

    // MARK: - Private

    private func lookup(id: String) async throws -> ITunesTrack? {
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        let scoped = parts.count == 2 && ["US", "TW"].contains(parts[0])
        let trackID = scoped ? parts[1] : id
        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [URLQueryItem(name: "id", value: trackID),
                                URLQueryItem(name: "country", value: scoped ? parts[0] : countryByTrack[id] ?? "US")]
        guard let url = components.url else { return nil }

        let data = try await throttledRequest(url: url)
        let result = try JSONDecoder().decode(ITunesSearchResult.self, from: data)
        return result.results.first
    }

    private func throttledRequest(url: URL) async throws -> Data {
        do {
            if let requestExecutor {
                return try await requestExecutor.execute(replay: .idempotent, timeout: 30) { [session] in
                    try await session.data(from: url)
                }.data
            }
            return try await quotaRegistry.execute(for: Self.quota, replay: .idempotent, timeout: 30) { [session] in
                try await session.data(from: url)
            }.data
        } catch let failure as HTTPResponseFailure
                    where Self.servicePolicy.rateLimitStatusCodes.contains(failure.statusCode) {
            // Preserve the scheduler's existing deferral signal. The executor
            // independently enforces long server cooldowns across all callers.
            let seconds = failure.retryAfter.map { delay in
                delay >= Double(Int.max) ? Int.max : Int(ceil(delay))
            }
            throw ScraperError.rateLimited(retryAfter: seconds)
        } catch RequestExecutor.AdmissionError.queueFull {
            throw ScraperError.busy
        }
    }

    // MARK: - Models

    private struct ITunesSearchResult: Decodable {
        let resultCount: Int
        let results: [ITunesTrack]
    }

    private struct ITunesTrack: Decodable {
        let collectionId: Int?
        let trackCount: Int?
        let trackId: Int?
        let artistId: Int?
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
