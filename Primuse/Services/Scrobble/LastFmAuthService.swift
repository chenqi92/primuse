import Foundation
import AuthenticationServices

/// Last.fm desktop auth flow 封装。
///
/// 移动 / 桌面 app 不能用 web auth (`cb=` 参数), 因为 Last.fm 注册时只
/// 接受 http(s) callback URL —— 你不能注册 `primuse://` scheme, 用
/// `cb=primuse://...` 又跟注册时不匹配会被 Last.fm 403 拒绝。
///
/// 正确流程 (官方 desktop application auth):
/// 1. 调 `auth.getToken` 拿一个 anonymous token (60 分钟有效)
/// 2. 浏览器打开 `https://www.last.fm/api/auth/?api_key=xxx&token=yyy`
///    (注意没有 cb 参数)
/// 3. 用户在浏览器里点 Allow → Last.fm 显示「You can close this page」
/// 4. App 这边检测用户回前台后, 调 `auth.getSession?token=yyy` (带签名)
///    换 sessionKey 存 Keychain
///
/// 关键: 步骤 2-3 不会回调 app, 没有 callback URL 这个概念。app 自己
/// 监听用户回前台, 然后主动 poll getSession。
///
/// 我们用 `ASWebAuthenticationSession` 弹 in-app Safari, 用户授权完
/// 关闭 sheet → 触发 completion (callbackScheme 永远不会真匹配, 但 sheet
/// 关闭就完事了), app 这时去拉 sessionKey。`prefersEphemeralWebBrowserSession`
/// 关掉以便用户已登录的 last.fm 账号自动用上。
@MainActor
final class LastFmAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = LastFmAuthService()
    private override init() { super.init() }

    /// 用一个永远不会真出现的 callbackScheme, 让 ASWebAuthenticationSession
    /// 框架满意。Last.fm 不会真去跳这个, 用户关 sheet 时 system 直接给我们
    /// userCancelled, 我们靠这个信号 + 主动 poll getSession 完成登录。
    private static let dummyCallbackScheme = "primuse"

    private var currentSession: ASWebAuthenticationSession?

    /// 跑完整登录流程 — 拿 token → 用户授权 → poll getSession → 存 Keychain。
    /// 返回成功后的用户名。
    func performLogin() async throws -> String {
        let apiKey = LastFmCredentialsStore.effectiveAPIKey()
        let apiSecret = LastFmCredentialsStore.effectiveAPISecret()
        guard !apiKey.isEmpty, !apiSecret.isEmpty else {
            throw LastFmAuthError.missingCredentials
        }

        // 1. 拿 token
        let token = try await fetchToken(apiKey: apiKey)

        // 2. 弹浏览器让用户授权
        let authURL = URL(string: "https://www.last.fm/api/auth/?api_key=\(apiKey)&token=\(token)")!
        await presentAuthSheet(url: authURL)

        // 3. sheet 关掉后, 用户大概率已经点了 Allow。轮询 getSession。
        //    用户没点 Allow 的话 getSession 会一直返回 14 (token unauthorized),
        //    几次就放弃报错。
        let sessionKey = try await pollSession(token: token, apiKey: apiKey, apiSecret: apiSecret)
        LastFmCredentialsStore.saveSessionKey(sessionKey)

        // 4. 拿 username 当 UI 反馈, 失败也没关系 (登录已经成功)
        let username = (try? await fetchUsername(apiKey: apiKey, sessionKey: sessionKey)) ?? ""
        return username
    }

    // MARK: - Step 1: get anonymous token

    private func fetchToken(apiKey: String) async throws -> String {
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
            throw LastFmAuthError.tokenFailed("no token in response: \(String(data: data, encoding: .utf8) ?? "")")
        }
        return token
    }

    // MARK: - Step 2: show in-app browser

    private func presentAuthSheet(url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // ASWebAuthenticationSession 需要一个 callbackURLScheme, 但我们
            // 实际不靠它回调 (Last.fm desktop flow 没有 callback)。等用户
            // 点完 Allow 自己关 sheet, completion 拿 cancelled error, 我们
            // 走下面的轮询拿 sessionKey。
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: Self.dummyCallbackScheme
            ) { @Sendable _, _ in
                // 不管成功还是 cancel, 都到这里。两种情况都是「sheet 关了」
                // 就行。
                continuation.resume()
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            currentSession = session
            if !session.start() {
                continuation.resume()
            }
        }
    }

    // MARK: - Step 3: poll auth.getSession

    /// 用户关浏览器后调 getSession 验证授权。如果用户没点 Allow, Last.fm
    /// 返回 error 14 (token unauthorized)。给 5 次机会 (每次间隔 1.5s) 等
    /// 用户慢一点点完。第 6 次还失败就报错。
    private func pollSession(token: String, apiKey: String, apiSecret: String) async throws -> String {
        var lastError: Error?
        for attempt in 0..<6 {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(1500))
            }
            do {
                return try await LastFmProvider.exchangeToken(
                    token: token, apiKey: apiKey, apiSecret: apiSecret
                )
            } catch {
                lastError = error
                // 14 = token unauthorized, 用户还没点 Allow, 继续等
                let msg = error.localizedDescription.lowercased()
                if msg.contains("unauthorized") || msg.contains("error 14") {
                    continue
                }
                // 其他错误 (network / 4 invalid token / etc) 立即抛出
                throw LastFmAuthError.notAuthorized(error.localizedDescription)
            }
        }
        throw LastFmAuthError.notAuthorized(lastError?.localizedDescription ?? "user did not authorize")
    }

    // MARK: - Username fetch (cosmetic)

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
    case tokenFailed(String)
    case notAuthorized(String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return String(localized: "scrobble_lastfm_err_missing_creds")
        case .tokenFailed(let msg):
            return String(format: String(localized: "scrobble_lastfm_err_token_format"), msg)
        case .notAuthorized(let msg):
            return String(format: String(localized: "scrobble_lastfm_err_not_authorized_format"), msg)
        }
    }
}
