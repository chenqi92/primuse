import Foundation

/// Last.fm auth flow 封装。
///
/// Last.fm 的 desktop auth 不会自动唤回 native app。授权成功后网页只会让
/// 用户关闭浏览器并回到应用。UI 层用 SFSafariViewController 把这个浏览器
/// 留在 App 内, dismiss 后自动调用 `completeLogin(token:)` 完成 session 交换。
///
/// 旧的「先登录 Last.fm」只打开 login 页面, 登录态只存在浏览器侧, App 没有
/// token 可换 sessionKey, 因此会出现用户已网页登录但 App 仍显示未连接。
@MainActor
enum LastFmAuthService {
    struct AuthorizationRequest {
        let token: String
        let url: URL
    }

    /// Step 1: 拿 token 并返回授权 URL。UI 负责展示网页, token 暂存到
    /// UserDefaults, 等网页 dismiss / app foreground 后换 sessionKey。
    static func startLogin() async throws -> AuthorizationRequest {
        let apiKey = LastFmCredentialsStore.effectiveAPIKey()
        let apiSecret = LastFmCredentialsStore.effectiveAPISecret()
        guard !apiKey.isEmpty, !apiSecret.isEmpty else {
            throw LastFmAuthError.missingCredentials
        }
        _ = apiSecret  // silence unused

        let token = try await fetchToken(apiKey: apiKey)
        return AuthorizationRequest(token: token, url: try authorizationURL(token: token))
    }

    static func authorizationURL(token: String) throws -> URL {
        let apiKey = LastFmCredentialsStore.effectiveAPIKey()
        guard !apiKey.isEmpty else {
            throw LastFmAuthError.missingCredentials
        }
        var components = URLComponents(string: "https://www.last.fm/api/auth/")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token)
        ]
        guard let url = components.url else {
            throw LastFmAuthError.tokenFailed("invalid auth URL")
        }
        return url
    }

    /// Step 2: 用 token 换 sessionKey 存 Keychain。返回 username 当 UI 反馈。
    @discardableResult
    static func completeLogin(token: String) async throws -> String {
        let apiKey = LastFmCredentialsStore.effectiveAPIKey()
        let apiSecret = LastFmCredentialsStore.effectiveAPISecret()
        guard !apiKey.isEmpty, !apiSecret.isEmpty else {
            throw LastFmAuthError.missingCredentials
        }
        do {
            let sessionKey = try await LastFmProvider.exchangeToken(
                token: token, apiKey: apiKey, apiSecret: apiSecret
            )
            LastFmCredentialsStore.saveSessionKey(sessionKey)
            LastFmCredentialsStore.savePendingAuthToken(nil)
            return (try? await fetchUsername(apiKey: apiKey, sessionKey: sessionKey)) ?? ""
        } catch {
            // 用户没点 Allow 就回来/关闭网页, getSession 抛 error 14 → 给个友好
            // 提示让 UI 区分这种情况。
            throw LastFmAuthError.notAuthorized(error.localizedDescription)
        }
    }

    // MARK: - Internal

    private static func fetchToken(apiKey: String) async throws -> String {
        var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")!
        components.queryItems = [
            URLQueryItem(name: "method", value: "auth.getToken"),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw LastFmAuthError.tokenFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let token = json?["token"] as? String, !token.isEmpty else {
            throw LastFmAuthError.tokenFailed("no token in response")
        }
        return token
    }

    private static func fetchUsername(apiKey: String, sessionKey: String) async throws -> String {
        let params = [
            "method": "user.getInfo",
            "api_key": apiKey,
            "sk": sessionKey,
            "format": "json"
        ]
        let body = params
            .sorted { $0.key < $1.key }
            .map { "\(LastFmProvider.formEncode($0.key))=\(LastFmProvider.formEncode($0.value))" }
            .joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://ws.audioscrobbler.com/2.0/")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let user = json?["user"] as? [String: Any]
        return (user?["name"] as? String) ?? ""
    }
}

enum LastFmAuthError: LocalizedError {
    case missingCredentials
    case tokenFailed(String)
    case notAuthorized(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return String(localized: "scrobble_lastfm_err_missing_creds")
        case .tokenFailed(let msg):
            return String(format: String(localized: "scrobble_lastfm_err_token_format"), msg)
        case .notAuthorized:
            return String(localized: "scrobble_lastfm_err_not_authorized")
        }
    }
}
