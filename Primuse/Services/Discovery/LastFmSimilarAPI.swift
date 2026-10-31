import Foundation
import PrimuseKit

/// Last.fm 相似歌曲、相似艺人与简介客户端。相似结果返回 raw 数据,
/// 本地匹配交给 `SimilarTracksService`。
///
/// 不需要用户 sessionKey, 只用 application apiKey (内置在 AppSecrets)。
/// 同一 API key 的各端点共享请求节奏和服务端冷却。
struct LastFmSimilarAPI: Sendable {
    private let apiKey: @Sendable () -> String
    private let session: URLSession
    private let quotaRegistry: RequestQuotaRegistry

    init(apiKey: @escaping @Sendable () -> String = { LastFmCredentialsStore.effectiveAPIKey() },
         session: URLSession = .shared, quotaRegistry: RequestQuotaRegistry = .shared) {
        self.apiKey = apiKey
        self.session = session
        self.quotaRegistry = quotaRegistry
    }

    struct SimilarTrack: Sendable, Hashable {
        let title: String
        let artist: String
        /// 0~1 的相似度分数, Last.fm 内部按"听众重叠"计算。
        let match: Double
        let lastFmURL: URL?
    }

    enum SimilarError: LocalizedError {
        case missingAPIKey
        case api(code: Int, message: String, response: HTTPResponseFailure)
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return String(localized: "error_lastfm_api_key_missing")
            case .api(_, let message, _):
                return message
            case .decode(let message):
                return String(format: String(localized: "error_lastfm_decode %@"), message)
            }
        }
    }

    func libraryInsight(for subject: LibraryInsightSubject, languageCode: String) async throws -> LibraryInsightImportedDraft? {
        let key = apiKey()
        guard !key.isEmpty else { throw SimilarError.missingAPIKey }
        let language = LastFmLibraryInsight.language(languageCode)
        for code in language == "en" ? ["en"] : [language, "en"] {
            try Task.checkCancellation()
            guard var items = LastFmLibraryInsight.queryItems(for: subject, languageCode: code) else { return nil }
            items += [URLQueryItem(name: "api_key", value: key), URLQueryItem(name: "format", value: "json")]
            var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
            components.queryItems = items
            let data: Data
            do {
                data = try await response(for: components.url!, apiKey: key)
            } catch SimilarError.api(let code, _, _) where code == 6 || code == 7 {
                return nil
            }
            try Task.checkCancellation()
            if let draft = try LastFmLibraryInsight.decode(data, for: subject) { return draft }
        }
        return nil
    }

    /// 拿一首歌的相似歌。`limit` 上限 100 (Last.fm 接口最大值)。
    func similarTracks(artist: String, track: String, limit: Int = 30) async throws -> [SimilarTrack] {
        let apiKey = apiKey()
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
        return try await fetchList(url: components.url!, apiKey: apiKey, listKey: "similartracks", itemKey: "track")
    }

    /// `track.getSimilar` 没返回结果时降级用 (例如冷门歌)。
    func similarArtistTracks(artist: String, limit: Int = 30) async throws -> [SimilarTrack] {
        let apiKey = apiKey()
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
        // title 留空，调用方按 artist 匹配 library。
        let data = try await response(for: components.url!, apiKey: apiKey)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let container = json?["similarartists"] as? [String: Any],
              let items = container["artist"] as? [[String: Any]] else {
            throw SimilarError.decode("Missing similarartists.artist")
        }
        return items.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            let match = (dict["match"] as? String).flatMap(Double.init) ?? 0
            let url = (dict["url"] as? String).flatMap(URL.init)
            return SimilarTrack(title: "", artist: name, match: match, lastFmURL: url)
        }
    }

    // MARK: - Private

    private func fetchList(url: URL, apiKey: String, listKey: String, itemKey: String) async throws -> [SimilarTrack] {
        let data = try await response(for: url, apiKey: apiKey)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let container = json?[listKey] as? [String: Any],
              let items = container[itemKey] as? [[String: Any]] else {
            throw SimilarError.decode("Missing \(listKey).\(itemKey)")
        }
        return items.compactMap { dict in
            guard let name = dict["name"] as? String, !name.isEmpty else { return nil }
            let artist = (dict["artist"] as? [String: Any])?["name"] as? String ?? ""
            let match = (dict["match"] as? String).flatMap(Double.init) ?? 0
            let lastFmURL = (dict["url"] as? String).flatMap(URL.init)
            return SimilarTrack(title: name, artist: artist, match: match, lastFmURL: lastFmURL)
        }
    }

    private func response(for url: URL, apiKey: String) async throws -> Data {
        let quota = RequestQuota(service: .lastFM, url: url, account: .init(stableID: apiKey))!
        let request = URLRequest(url: url, timeoutInterval: 15)
        do {
            return try await quotaRegistry.execute(for: quota, replay: .idempotent, operation: {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                let retryAfter = HTTPResponseFailure.retryDelay(from: http)
                // Last.fm 的应用额度(29)写在错误体里,HTTP 200 和 400 都可能;先认它再看状态码,
                // 否则 400 + 29 会被当成普通拒绝,不建立共享冷却。
                let envelopeCode = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? Int
                if envelopeCode == 29 {
                    throw HTTPResponseFailure(statusCode: http.statusCode, body: data,
                        retryAfter: retryAfter ?? RequestQuota.Service.lastFM.policy.defaultCooldown,
                        isRateLimited: true, isRetryable: true)
                }
                guard (200...299).contains(http.statusCode) else {
                    throw HTTPResponseFailure(statusCode: http.statusCode, body: data, retryAfter: retryAfter)
                }
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["error"] is Int {
                    throw HTTPResponseFailure(statusCode: http.statusCode, body: data, retryAfter: retryAfter)
                }
                return data
            })
        } catch let failure as HTTPResponseFailure {
            if let json = (try? JSONSerialization.jsonObject(with: failure.body)) as? [String: Any],
               let code = json["error"] as? Int {
                throw SimilarError.api(code: code, message: json["message"] as? String ?? "Last.fm error \(code)", response: failure)
            }
            throw failure
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
    }
}
