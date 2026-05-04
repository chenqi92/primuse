import Foundation
import UIKit

/// Last.fm desktop auth flow 封装。
///
/// 移动 app 不能用 web auth (`cb=` 参数), 因为 Last.fm 注册时只接受 http(s)
/// callback URL —— 不能注册 `primuse://` scheme, 用 `cb=primuse://...`
/// 又跟注册时不匹配会被 Last.fm 403 拒绝。
///
/// 用 desktop application auth flow, 拆成 user-driven 两步:
/// 1. `startLogin()` —— 拿 token, 在外置 Safari 打开授权页, 返回 token
///    给 UI 暂存
/// 2. UI 上让用户「点 Allow → 回到 app → 点 我已授权」, 然后
///    `completeLogin(token:)` 调 getSession 把 token 换成 sessionKey
///
/// **重要前提**: 用户必须**先**在 Safari 里登录 Last.fm 账号, 否则授权页
/// 直接 Cloudflare 403 (Last.fm 反 abuse, 没登录态 + 带 token 的请求被拦)。
/// UI 提供 `openLoginPage()` 入口让用户先去登录。
@MainActor
enum LastFmAuthService {
    /// 打开 https://www.last.fm/login 让用户先登录 Last.fm 账号。
    /// Safari 主程序登录后, cookie 共享给所有 in-app browser, 后续授权才不会 403。
    static func openLoginPage() async {
        guard let url = URL(string: "https://www.last.fm/login") else { return }
        await UIApplication.shared.open(url)
    }

    /// Step 1: 拿 token 并打开授权页。返回的 token 由 UI 持有, 等用户回来
    /// 点「我已授权」时传给 `completeLogin(token:)`。
    static func startLogin() async throws -> String {
        let apiKey = LastFmCredentialsStore.effectiveAPIKey()
        let apiSecret = LastFmCredentialsStore.effectiveAPISecret()
        guard !apiKey.isEmpty, !apiSecret.isEmpty else {
            throw LastFmAuthError.missingCredentials
        }
        _ = apiSecret  // silence unused

        let token = try await fetchToken(apiKey: apiKey)
        let authURL = URL(string: "https://www.last.fm/api/auth/?api_key=\(apiKey)&token=\(token)")!
        await UIApplication.shared.open(authURL)
        return token
    }

    /// Step 2: 用户回 app 点「我已授权」时调, 用 token 换 sessionKey 存
    /// Keychain。返回 username 当 UI 反馈。
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
            return (try? await fetchUsername(apiKey: apiKey, sessionKey: sessionKey)) ?? ""
        } catch {
            // 用户没点 Allow 就回来确认, getSession 抛 error 14 → 给个友好
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
