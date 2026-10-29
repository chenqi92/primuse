import Foundation
import PrimuseKit

actor MusicBrainzScraper: AlbumMusicScraper {
    let type = MusicScraperType.musicBrainz

    private let session: URLSession
    // All factory instances and manual/background callers share this service budget.
    private static let serviceRequests = RequestExecutor(
        policy: .init(minimumInterval: 1, maximumConcurrentRequests: 1)
    )
    private let requestExecutor: RequestExecutor

    init(session: URLSession? = nil, requestExecutor: RequestExecutor? = nil) {
        self.requestExecutor = requestExecutor ?? Self.serviceRequests
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0 (iOS Music Player)"]
        self.session = URLSession(configuration: config)
    }

    func isCoolingDown() async -> Bool {
        if await requestExecutor.isCoolingDown { return true }
        return await ScraperRequestPool.shared.isCoolingDown(for: .resource(type.rawValue))
    }

    // MARK: - MusicScraper

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        var queryParts = [Self.literalClause(field: "recording", value: query)]
        if let artist, !artist.isEmpty {
            queryParts.append(Self.literalClause(field: "artist", value: artist))
        }
        if let album, !album.isEmpty {
            queryParts.append(Self.literalClause(field: "release", value: album))
        }

        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: queryParts.joined(separator: " AND ")),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))
        ]
        guard let url = components?.url else {
            return .empty(.musicBrainz)
        }

        let data = try await throttledRequest(url: url)
        let result = try JSONDecoder().decode(MBRecordingSearchResult.self, from: data)

        let items = (result.recordings ?? []).map { rec in
            ScraperSearchItem(
                externalId: rec.id,
                source: .musicBrainz,
                title: rec.title ?? "",
                artist: rec.primaryArtistName,
                album: rec.releases?.first?.title,
                year: rec.releaseYear,
                durationMs: rec.length,
                genres: rec.tags?.compactMap(\.name)
            )
        }
        return ScraperSearchResult(items: items, source: .musicBrainz)
    }

    /// MusicBrainz search uses Lucene syntax. Quote user text and escape every
    /// Lucene metacharacter before URLComponents performs transport encoding.
    private nonisolated static func literalClause(field: String, value: String) -> String {
        let special = CharacterSet(charactersIn: #"+-&|!(){}[]^\"~*?:\/"#)
        var escaped = ""
        for scalar in value.unicodeScalars {
            if special.contains(scalar) {
                escaped.append("\\")
            }
            escaped.append(Character(scalar))
        }
        return "\(field):\"\(escaped)\""
    }

    func getDetail(externalId: String) async throws -> ScraperDetail? {
        guard let url = URL(string: "https://musicbrainz.org/ws/2/recording/\(externalId)?inc=artist-credits+releases+tags&fmt=json") else {
            return nil
        }

        let data = try await throttledRequest(url: url)
        let rec = try JSONDecoder().decode(MBRecording.self, from: data)

        return ScraperDetail(
            externalId: rec.id,
            source: .musicBrainz,
            title: rec.title ?? "",
            artist: rec.primaryArtistName,
            album: rec.releases?.first?.title,
            year: rec.releaseYear,
            genres: rec.tags?.compactMap(\.name)
        )
    }

    func getCoverArt(externalId: String) async throws -> [ScraperCoverResult] {
        // First get recording to find release ID
        guard let url = URL(string: "https://musicbrainz.org/ws/2/recording/\(externalId)?inc=releases&fmt=json") else {
            return []
        }

        let data = try await throttledRequest(url: url)
        let rec = try JSONDecoder().decode(MBRecording.self, from: data)

        guard let releaseID = rec.releases?.first?.id else { return [] }

        return [
            ScraperCoverResult(
                source: .musicBrainz,
                coverUrl: "https://coverartarchive.org/release/\(releaseID)/front-500",
                thumbnailUrl: "https://coverartarchive.org/release/\(releaseID)/front-250"
            )
        ]
    }

    func getLyrics(externalId: String) async throws -> ScraperLyricsResult? {
        nil // MusicBrainz doesn't provide lyrics
    }

    /// Direct cover lookups share the resource budget used by artwork downloads.
    func fetchCoverData(releaseID: String) async throws -> Data? {
        try await ConfigurableScraper.downloadResource(
            from: "https://coverartarchive.org/release/\(releaseID)/front-250",
            sourceConfig: .init(id: type.rawValue, type: type, isEnabled: true, priority: 0),
            session: session
        )
    }

    func searchAlbums(title: String, artist: String?, limit: Int) async throws -> [ScraperAlbum] {
        var query = Self.literalClause(field: "release", value: title)
        if let artist, !artist.isEmpty { query += " AND " + Self.literalClause(field: "artist", value: artist) }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/")!
        components.queryItems = [URLQueryItem(name: "query", value: query),
                                URLQueryItem(name: "fmt", value: "json"),
                                URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100)))]
        let data = try await throttledRequest(url: components.url!)
        return try JSONDecoder().decode(AlbumSearchResponse.self, from: data).releases.map { release in
            ScraperAlbum(externalID: release.id, source: .musicBrainz, title: release.title,
                         artist: release.artist, year: release.year,
                         trackCount: release.trackCount ?? release.media?.compactMap(\.trackCount).reduce(0, +),
                         edition: [release.country, release.disambiguation].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }

    func albumTracks(externalID: String) async throws -> [ScraperDetail] {
        guard UUID(uuidString: externalID) != nil else { throw ScraperError.notFound }
        var components = URLComponents(string: "https://musicbrainz.org/ws/2/release/" + externalID)!
        components.queryItems = [URLQueryItem(name: "inc", value: "recordings+artist-credits"),
                                URLQueryItem(name: "fmt", value: "json")]
        let data = try await throttledRequest(url: components.url!)
        let album = try JSONDecoder().decode(AlbumRelease.self, from: data)
        return (album.media ?? []).flatMap { medium in
            (medium.tracks ?? []).map { track in
                ScraperDetail(externalId: track.id, source: .musicBrainz, title: track.title,
                              artist: Self.creditName(track.artistCredit) ?? track.recording?.primaryArtistName ?? album.artist,
                              albumArtist: album.artist, album: album.title, year: album.year,
                              trackNumber: track.position, discNumber: medium.position,
                              durationMs: track.length ?? track.recording?.length)
            }
        }
    }

    private static func creditName(_ credits: [AlbumArtistCredit]?) -> String? {
        let text = credits?.map { ($0.name ?? $0.artist?.name ?? "") + ($0.joinphrase ?? "") }.joined()
        return text?.isEmpty == false ? text : nil
    }

    private struct AlbumSearchResponse: Decodable { let releases: [AlbumRelease] }
    private struct AlbumArtistCredit: Decodable {
        let name: String?
        let artist: MBArtist?
        let joinphrase: String?
    }
    private struct AlbumRelease: Decodable {
        let id: String
        let title: String
        let date: String?
        let country: String?
        let disambiguation: String?
        let trackCount: Int?
        let artistCredit: [AlbumArtistCredit]?
        let media: [AlbumMedium]?
        var artist: String? { MusicBrainzScraper.creditName(artistCredit) }
        var year: Int? { date.flatMap { Int($0.prefix(4)) } }
        enum CodingKeys: String, CodingKey {
            case id, title, date, country, disambiguation, media
            case trackCount = "track-count"
            case artistCredit = "artist-credit"
        }
    }
    private struct AlbumMedium: Decodable {
        let position: Int?
        let trackCount: Int?
        let tracks: [AlbumTrack]?
        enum CodingKeys: String, CodingKey {
            case position, tracks
            case trackCount = "track-count"
        }
    }
    private struct AlbumTrack: Decodable {
        let id: String
        let title: String
        let position: Int?
        let length: Int?
        let artistCredit: [AlbumArtistCredit]?
        let recording: MBRecording?
        enum CodingKeys: String, CodingKey {
            case id, title, position, length, recording
            case artistCredit = "artist-credit"
        }
    }

    // MARK: - Rate Limiting

    private func throttledRequest(url: URL) async throws -> Data {
        do {
            return try await requestExecutor.execute(replay: .idempotent) { [session] in
                try await session.data(from: url)
            }.data
        } catch let failure as HTTPResponseFailure where failure.statusCode == 429 || failure.statusCode == 503 {
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

    // MARK: - MusicBrainz Models

    private struct MBRecordingSearchResult: Codable {
        let recordings: [MBRecording]?
    }

    struct MBRecording: Codable {
        let id: String
        let title: String?
        let length: Int?  // duration in milliseconds
        let artistCredit: [ArtistCredit]?
        let releases: [MBRelease]?
        let tags: [MBTag]?

        enum CodingKeys: String, CodingKey {
            case id, title, length, releases, tags
            case artistCredit = "artist-credit"
        }

        var primaryArtistName: String? {
            artistCredit?.compactMap { $0.name ?? $0.artist?.name }.first
        }

        var releaseYear: Int? {
            guard let date = releases?.first?.date else { return nil }
            return Int(String(date.prefix(4)))
        }
    }

    struct ArtistCredit: Codable {
        let name: String?
        let artist: MBArtist?
    }

    struct MBArtist: Codable {
        let id: String
        let name: String?
    }

    struct MBRelease: Codable {
        let id: String
        let title: String?
        let date: String?
    }

    struct MBTag: Codable {
        let name: String?
    }
}
