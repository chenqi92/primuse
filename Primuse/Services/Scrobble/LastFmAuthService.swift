import Foundation
import AuthenticationServices

/// Last.fm web auth 流程封装。Last.fm 不是标准 OAuth 2.0, 不能复用
/// CloudDrive 的 OAuthService —— 流程更轻:
///
/// 1. 引用户去 https://www.last.fm/api/auth/?api_key=...&cb=primuse://lastfm-auth
/// 2. 用户在 Last.fm 上点 Allow
/// 3. Last.fm 跳转 cb URL 并附 ?token=xxx
/// 4. 客户端拿 token 调 auth.getSession (带签名), 换出永久 sessionKey
/// 5. sessionKey 进 Keychain, 后续 scrobble 用它签名
///
/// API key/secret 由用户在设置里粘贴 (要先去 last.fm/api/account/create
/// 注册一个 application). 这样不用在仓库里硬编码 secret, 也方便用户
/// 自己控制配额。
@MainActor
final class LastFmAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = LastFmAuthService()
    private override init() { super.init() }

    /// URL scheme 在 Info.plist 里已注册的 `primuse://`。
    /// host 用 `lastfm-auth` 作区分, 不会和 cloud drive OAuth 撞。
    static let callbackScheme = "primuse"
    static let callbackHost = "lastfm-auth"

    private var currentSession: ASWebAuthenticationSession?

    /// 跑完整登录流程 — 弹 Last.fm 授权页 → 拿 token → 换 sessionKey → 存 Keychain。
    /// 返回成功后的用户名 (从 sessionKey 拿不到 username, 再调 user.getInfo
    /// 拿一下当 UI 反馈)。失败抛 error。
    func performLogin() async throws -> String {
        let apiKey = LastFmCredentialsStore.effectiveAPIKey()
        let apiSecret = LastFmCredentialsStore.effectiveAPISecret()
        guard !apiKey.isEmpty, !apiSecret.isEmpty else {
            throw LastFmAuthError.missingCredentials
        }
        let callback = URL(string: "\(Self.callbackScheme)://\(Self.callbackHost)")!
        guard let authURL = LastFmProvider.makeAuthURL(apiKey: apiKey, callback: callback) else {
            throw LastFmAuthError.invalidConfiguration
        }

        let callbackURL = try await presentAuthSession(url: authURL)
        let token = try extractToken(from: callbackURL)
        let sessionKey = try await LastFmProvider.exchangeToken(
            token: token, apiKey: apiKey, apiSecret: apiSecret
        )
        LastFmCredentialsStore.saveSessionKey(sessionKey)

        // 用 sessionKey 拿一下 username 当 UI 反馈, 失败也没关系 (登录已经成功)。
        let username = (try? await fetchUsername(apiKey: apiKey, sessionKey: sessionKey)) ?? ""
        return username
    }

    private func presentAuthSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // 同 OAuthService 的注释 —— 闭包在 XPC reply 队列触发, 不能继承
            // @MainActor isolation, 必须 @Sendable 否则 iOS 26 会 trap。
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.callbackScheme
            ) { @Sendable callbackURL, error in
                if let error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: LastFmAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: LastFmAuthError.sessionFailed(error.localizedDescription))
                    }
                    return
                }
                guard let callbackURL else {
                    continuation.resume(throwing: LastFmAuthError.noCallback)
                    return
                }
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            currentSession = session
            if !session.start() {
                continuation.resume(throwing: LastFmAuthError.sessionFailed("Failed to start"))
            }
        }
    }

    private func extractToken(from url: URL) throws -> String {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = comps.queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty else {
            throw LastFmAuthError.noToken
        }
        return token
    }

    private func fetchUsername(apiKey: String, sessionKey: String) async throws -> String {
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        components.queryItems = [
            URLQueryItem(name: "method", value: "user.getInfo"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "sk", value: sessionKey),
            URLQueryItem(name: "format", value: "json")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let user = json?["user"] as? [String: Any]
        return (user?["name"] as? String) ?? ""
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes
            let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            return windowScene?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}

enum LastFmAuthError: LocalizedError {
    case missingCredentials
    case invalidConfiguration
    case userCancelled
    case sessionFailed(String)
    case noCallback
    case noToken

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return String(localized: "scrobble_lastfm_err_missing_creds")
        case .invalidConfiguration:
            return String(localized: "scrobble_lastfm_err_config")
        case .userCancelled:
            return String(localized: "scrobble_lastfm_err_cancelled")
        case .sessionFailed(let msg):
            return String(format: String(localized: "scrobble_lastfm_err_session_format"), msg)
        case .noCallback:
            return String(localized: "scrobble_lastfm_err_no_callback")
        case .noToken:
            return String(localized: "scrobble_lastfm_err_no_token")
        }
    }
}
