import Foundation
import PrimuseKit

/// ListenBrainz scrobble provider。Token-based 鉴权 (用户在
/// https://listenbrainz.org/profile/ 拿 user token, 没有 OAuth flow)。
///
/// API doc: https://listenbrainz.readthedocs.io/en/latest/users/api/index.html
struct ListenBrainzProvider: ScrobbleProvider {
    let id: ScrobbleProviderID = .listenBrainz

    /// 服务端地址。默认官方 listenbrainz.org, 用户可改为自部署。
    let baseURL: URL
    let userToken: String

    init(userToken: String, baseURL: URL = URL(string: "https://api.listenbrainz.org")!) {
        self.userToken = userToken
        self.baseURL = baseURL
    }

    func validateCredentials() async -> Bool? {
        // GET /1/validate-token 是专门的鉴权检查 endpoint。
        // 返回 200 + valid:true 表示 token 可用。
        var request = URLRequest(url: baseURL.appendingPathComponent("1/validate-token"))
        request.setValue("Token \(userToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["valid"] as? Bool) ?? false
        } catch {
            return nil  // 网络错, 不能确认
        }
    }

    func sendNowPlaying(_ entry: ScrobbleEntry) async throws {
        try await postListens(entries: [entry], listenType: "playing_now")
    }

    func submitListens(_ entries: [ScrobbleEntry]) async throws {
        guard !entries.isEmpty else { return }
        let listenType = entries.count == 1 ? "single" : "import"
        try await postListens(entries: entries, listenType: listenType)
    }

    /// POST /1/submit-listens 统一入口。listenType 决定语义:
    /// - "playing_now": now playing, 不带 listened_at
    /// - "single": 单条 listen
    /// - "import": 批量历史 listen
    private func postListens(entries: [ScrobbleEntry], listenType: String) async throws {
        let payload = ListensPayload(
            listen_type: listenType,
            payload: entries.map { entry in
                ListensPayload.Listen(
                    listened_at: listenType == "playing_now" ? nil : entry.startedAt,
                    track_metadata: .init(
                        artist_name: entry.artist,
                        track_name: entry.title,
                        release_name: entry.album,
                        additional_info: .init(
                            duration: entry.durationSec,
                            tracknumber: entry.trackNumber,
                            artist_names: nil,
                            release_artist_name: entry.albumArtist
                        )
                    )
                )
            }
        )
        let body = try JSONEncoder().encode(payload)

        var request = URLRequest(url: baseURL.appendingPathComponent("1/submit-listens"))
        request.httpMethod = "POST"
        request.setValue("Token \(userToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        let (data, response) = try await {
            do {
                return try await URLSession.shared.data(for: request)
            } catch {
                throw ScrobbleError.network(error)
            }
        }()

        guard let http = response as? HTTPURLResponse else {
            throw ScrobbleError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw ScrobbleError.invalidCredentials
        case 429:
            throw ScrobbleError.rateLimited
        default:
            let body = String(data: data, encoding: .utf8)
            throw ScrobbleError.http(http.statusCode, body)
        }
    }

    // MARK: - JSON 模型 (匹配 ListenBrainz spec)

    private struct ListensPayload: Encodable {
        let listen_type: String
        let payload: [Listen]

        struct Listen: Encodable {
            let listened_at: Int64?
            let track_metadata: TrackMetadata

            struct TrackMetadata: Encodable {
                let artist_name: String
                let track_name: String
                let release_name: String?
                let additional_info: AdditionalInfo?

                struct AdditionalInfo: Encodable {
                    let duration: Int?
                    let tracknumber: Int?
                    let artist_names: [String]?
                    let release_artist_name: String?
                }
            }
        }
    }
}
