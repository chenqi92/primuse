import Foundation
import PrimuseKit

actor OnlineMetadataService {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.httpAdditionalHeaders = ["User-Agent": "Primuse/1.0 (iOS Music Player)"]
        self.session = URLSession(configuration: config)
    }

    // MARK: - MusicBrainz

    struct MusicBrainzRelease: Codable {
        let id: String
        let title: String?
        let date: String?
        let artistCredit: [ArtistCredit]?

        enum CodingKeys: String, CodingKey {
            case id, title, date
            case artistCredit = "artist-credit"
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

    struct MBSearchResult: Codable {
        let releases: [MusicBrainzRelease]?
    }

    func searchMusicBrainz(artist: String, album: String) async throws -> MusicBrainzRelease? {
        let query = "artist:\(artist) AND release:\(album)"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        guard let url = URL(string: "https://musicbrainz.org/ws/2/release/?query=\(query)&fmt=json&limit=1") else {
            return nil
        }

        let (data, _) = try await session.data(from: url)
        let result = try JSONDecoder().decode(MBSearchResult.self, from: data)
        return result.releases?.first
    }

    /// Fetches cover art from Cover Art Archive
    func fetchCoverArt(releaseID: String) async throws -> Data? {
        guard let url = URL(string: "https://coverartarchive.org/release/\(releaseID)/front-250") else {
            return nil
        }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }

        return data
    }

    // MARK: - LRCLIB (Lyrics)

    struct LRCLibResult: Codable {
        let syncedLyrics: String?
        let plainLyrics: String?
    }

    func fetchLyrics(title: String, artist: String, album: String? = nil, duration: TimeInterval? = nil) async throws -> [LyricLine]? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        if let album {
            queryItems.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration {
            queryItems.append(URLQueryItem(name: "duration", value: String(Int(duration))))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return nil }

        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }

        let result = try JSONDecoder().decode(LRCLibResult.self, from: data)

        if let synced = result.syncedLyrics {
            return LyricsParser.parse(synced)
        }

        return nil
    }
}
