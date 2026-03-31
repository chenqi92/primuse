import Foundation
import PrimuseKit

actor MusicBrainzScraper: MusicScraper {
    let type = MusicScraperType.musicBrainz

    private let session: URLSession
    private var lastRequestTime: ContinuousClock.Instant?
    private let minInterval: Duration = .seconds(1)

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0 (iOS Music Player)"]
        self.session = URLSession(configuration: config)
    }

    // MARK: - MusicScraper

    func search(query: String, artist: String?, album: String?, limit: Int) async throws -> ScraperSearchResult {
        var queryParts = ["recording:\(query)"]
        if let artist, !artist.isEmpty { queryParts.append("artist:\(artist)") }
        if let album, !album.isEmpty { queryParts.append("release:\(album)") }

        let queryStr = queryParts.joined(separator: " AND ")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        guard let url = URL(string: "https://musicbrainz.org/ws/2/recording/?query=\(queryStr)&fmt=json&limit=\(limit)") else {
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

    // Also provide direct cover fetch for ScraperManager
    func fetchCoverData(releaseID: String) async throws -> Data? {
        guard let url = URL(string: "https://coverartarchive.org/release/\(releaseID)/front-250") else {
            return nil
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }
        return data
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
        let (data, _) = try await session.data(from: url)
        return data
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
