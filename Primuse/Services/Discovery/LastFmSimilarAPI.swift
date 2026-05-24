import Foundation
import PrimuseKit

/// Last.fm `track.getSimilar` / `artist.getSimilar` 客户端。返回 raw 数据,
/// 本地匹配交给 `SimilarTracksService`。
///
/// 不需要用户 sessionKey, 只用 application apiKey (内置在 AppSecrets)。
/// rate limit: Last.fm 官方说 5 req/s, 我们这里没做并发限流, 调用方记得
/// 节流 (一首歌的 seed 5 分钟内不重复查就够)。
enum LastFmSimilarAPI {
    struct SimilarTrack: Sendable, Hashable {
        let title: String
        let artist: String
        /// 0~1 的相似度分数, Last.fm 内部按"听众重叠"计算。
        let match: Double
        let lastFmURL: URL?
    }

    enum SimilarError: LocalizedError {
        case missingAPIKey
        case http(Int)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "Last.fm API key not configured"
            case .http(let s): return "Last.fm HTTP \(s)"
            case .decode(let m): return "Last.fm decode: \(m)"
            }
        }
    }

    /// 拿一首歌的相似歌。`limit` 上限 100 (Last.fm 接口最大值)。
    static func similarTracks(artist: String, track: String, limit: Int = 30) async throws -> [SimilarTrack] {
        let apiKey = LastFmCredentialsStore.effectiveAPIKey()
        guard !apiKey.isEmpty else { throw SimilarError.missingAPIKey }
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        components.queryItems = [
            URLQueryItem(name: "method", value: "track.getSimilar"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "track", value: track),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 100)))),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json")
        ]
        return try await fetchList(url: components.url!, listKey: "similartracks", itemKey: "track")
    }

    /// `track.getSimilar` 没返回结果时降级用 (例如冷门歌)。
    static func similarArtistTracks(artist: String, limit: Int = 30) async throws -> [SimilarTrack] {
        let apiKey = LastFmCredentialsStore.effectiveAPIKey()
        guard !apiKey.isEmpty else { throw SimilarError.missingAPIKey }
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        components.queryItems = [
            URLQueryItem(name: "method", value: "artist.getSimilar"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 100)))),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json")
        ]
        // artist.getSimilar 返回的是相似艺术家 (不是 tracks), 我们 wrap 成 SimilarTrack
        // 用艺术家代表作 (title 字段塞 "*", 调用方按 artist 匹配 library)。
        let url = components.url!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SimilarError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let container = json?["similarartists"] as? [String: Any]
        let items = container?["artist"] as? [[String: Any]] ?? []
        return items.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            let match = (dict["match"] as? String).flatMap(Double.init) ?? 0
            let url = (dict["url"] as? String).flatMap(URL.init)
            return SimilarTrack(title: "", artist: name, match: match, lastFmURL: url)
        }
    }

    // MARK: - Private

    private static func fetchList(url: URL, listKey: String, itemKey: String) async throws -> [SimilarTrack] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SimilarError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let container = json?[listKey] as? [String: Any]
        let items = container?[itemKey] as? [[String: Any]] ?? []
        return items.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            let artist = (dict["artist"] as? [String: Any])?["name"] as? String ?? ""
            let match = (dict["match"] as? String).flatMap(Double.init) ?? 0
            let lastFmURL = (dict["url"] as? String).flatMap(URL.init)
            return SimilarTrack(title: name, artist: artist, match: match, lastFmURL: lastFmURL)
        }
    }
}
