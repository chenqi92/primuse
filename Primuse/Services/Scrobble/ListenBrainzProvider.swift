import Foundation
import PrimuseKit

/// ListenBrainz scrobble provider。Token-based 鉴权 (用户在
/// https://listenbrainz.org/profile/ 拿 user token, 没有 OAuth flow)。
///
/// API doc: https://listenbrainz.readthedocs.io/en/latest/users/api/index.html
struct ListenBrainzProvider: ScrobbleProvider {
    let id: ScrobbleProviderID = .listenBrainz

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "Primuse/\(version) ( https://palveni.com )"
    }()

    /// 服务端地址。默认官方 listenbrainz.org, 用户可改为自部署。
    let baseURL: URL
    let userToken: String

    let requests: ScrobbleRequests
    let session: URLSession

    init(userToken: String, baseURL: URL = URL(string: "https://api.listenbrainz.org")!, session: URLSession = .shared, requests: ScrobbleRequests = .init()) {
        self.requests = requests
        self.session = session
        self.userToken = userToken
        self.baseURL = baseURL
    }

    var credentialFingerprint: String {
        ScrobbleCredentialFingerprint.of(id.rawValue, baseURL.absoluteString, userToken)
    }

    func validateCredentials() async -> Bool? {
        guard !userToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent("1/validate-token"))
        request.setValue("Token \(userToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        struct Validation: Decodable {
            let valid: Bool
            let code: Int?
        }
        do {
            let (data, http) = try await requests.send(request, session: session,
                service: ScrobbleRequests.listenBrainz, account: userToken) { _, http in
                    Self.logFailure(http, operation: "validate-token")
                }
            guard http.statusCode == 200 else { return nil }
            let result = try JSONDecoder().decode(Validation.self, from: data)
            guard result.code == nil || result.code == 200 else { return nil }
            return result.valid
        } catch {
            // Only the documented valid:false envelope proves a rejected token.
            return nil
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
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 30

        _ = try await requests.send(request, session: session, service: ScrobbleRequests.listenBrainz, account: userToken) { _, http in
            Self.logFailure(http, operation: "submit-listens")
            let retryAfter = HTTPResponseFailure.retryDelay(from: http)
            if retryAfter == nil, http.statusCode == 401 {
                throw ScrobbleError.invalidCredentials
            }
            // A proxy or service policy can reject a valid token's submission.
            // Keep the listens and share a cooldown with validation/Now Playing.
            if http.statusCode == 403 {
                throw HTTPResponseFailure(statusCode: 403, retryAfter: retryAfter ?? 60, isRetryable: true)
            }
        }

    }

    private static func logFailure(_ response: HTTPURLResponse, operation: String) {
        guard !(200...299).contains(response.statusCode) else { return }
        let mime = response.mimeType?.lowercased() ?? ""
        let responseKind = mime == "application/json" || mime.hasSuffix("+json")
            ? "json" : (mime == "text/html" ? "html" : "other")
        plog("scrobble [ListenBrainz] \(operation) HTTP \(response.statusCode) response=\(responseKind)")
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
