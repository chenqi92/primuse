import Foundation
import AuthenticationServices
import CryptoKit
#if os(iOS)
#if os(iOS)
import UIKit
#endif
#else
import AppKit
#endif

/// Handles the complete OAuth 2.0 Authorization Code + PKCE flow for cloud drive sources.
/// Uses ASWebAuthenticationSession for system-level browser authentication.
@MainActor
final class OAuthService: NSObject, ASWebAuthenticationPresentationContextProviding {

    static let shared = OAuthService()

    private var currentSession: ASWebAuthenticationSession?

    private override init() { super.init() }

    // MARK: - Public API

    /// Starts the full OAuth flow: authorize → get code → exchange for tokens.
    /// Returns the obtained tokens ready to be stored.
    func authorize(config: CloudOAuthConfig) async throws -> CloudTokenManager.Tokens {
        let pkce = config.usesPKCE ? PKCEChallenge() : nil

        // CSRF / authorization-code-injection 防护:每次授权生成一次性随机 state,
        // 写进授权 URL,回调时校验它原样返回。对没有 PKCE 的 provider(如百度)
        // 这是唯一能阻止外来 primuse://?code=… 被错误接受的手段。
        let state = Self.makeRandomState()

        // 1. Build authorize URL
        let authURL = try buildAuthorizeURL(config: config, pkce: pkce, state: state)
        plog("☁️ OAuth authorize host=\(authURL.host ?? "?") path=\(authURL.path)")

        // 2. Present system browser
        let callbackURL = try await presentAuthSession(
            url: authURL,
            callbackScheme: config.callbackURLScheme
        )

        // 3. Extract authorization code from callback (校验 state 一致后才接受)
        let code = try extractCode(from: callbackURL, expectedState: state)

        // 4. Exchange code for tokens
        let tokens = try await exchangeCodeForTokens(
            code: code,
            config: config,
            codeVerifier: pkce?.verifier
        )

        return tokens
    }

    // MARK: - Step 1: Build Authorize URL

    private func buildAuthorizeURL(config: CloudOAuthConfig, pkce: PKCEChallenge?, state: String) throws -> URL {
        guard var components = URLComponents(string: config.authURL) else {
            throw OAuthError.invalidConfiguration("Invalid auth URL: \(config.authURL)")
        }

        var queryItems: [URLQueryItem] = [
            .init(name: "client_id", value: config.clientId),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "state", value: state),
        ]

        // 123 云盘授权页(www.123pan.com/auth)只接受 client_id/redirect_uri/scope/state
        // (官方示例不带 response_type);其余 provider 走标准 OAuth 加 response_type=code。
        if !config.authURL.contains("123pan.com") {
            queryItems.append(.init(name: "response_type", value: "code"))
        }

        if let pkce {
            queryItems.append(.init(name: "code_challenge", value: pkce.challenge))
            queryItems.append(.init(name: "code_challenge_method", value: "S256"))
        }

        if !config.scopes.isEmpty {
            queryItems.append(.init(name: "scope", value: config.scopes.joined(separator: config.scopeSeparator)))
        }

        // Platform-specific parameters
        if config.authURL.contains("baidu.com") {
            queryItems.append(.init(name: "display", value: "mobile"))
        } else if config.authURL.contains("dropbox.com") {
            queryItems.append(.init(name: "token_access_type", value: "offline"))
        } else if config.authURL.contains("microsoftonline.com") {
            queryItems.append(.init(name: "response_mode", value: "query"))
        }

        components.queryItems = queryItems
        guard let url = components.url else {
            throw OAuthError.invalidConfiguration("Failed to build authorize URL")
        }
        return url
    }

    // MARK: - Step 2: Present Auth Session

    private func presentAuthSession(url: URL, callbackScheme: String) async throws -> URL {
        #if os(macOS)
        // macOS 26 + sandbox 下 ASWebAuthenticationSession 的浏览器窗口经常
        // 不显示/不加载 URL(已确认设 prefersEphemeralWebBrowserSession 也无效)。
        // 改成走系统默认浏览器,通过 primuse:// URL Scheme 把 code 回调进 app。
        // 配合 PrimuseApp.onOpenURL → MacOAuthBridge.handle 完成回调链路。
        return try await withCheckedThrowingContinuation { continuation in
            MacOAuthBridge.shared.expectCallback(scheme: callbackScheme) { @Sendable result in
                switch result {
                case .success(let url):
                    continuation.resume(returning: url)
                case .failure(let err):
                    continuation.resume(throwing: err)
                }
            }
            plog("☁️ OAuth NSWorkspace.open authURL callbackScheme=\(callbackScheme)")
            let opened = NSWorkspace.shared.open(url)
            plog("☁️ OAuth NSWorkspace.open returned \(opened)")
            if !opened {
                MacOAuthBridge.shared.cancel(reason: .failure(OAuthError.authSessionFailed("Failed to open browser")))
            }
        }
        #else
        return try await withCheckedThrowingContinuation { continuation in
            // The completion closure must NOT inherit `@MainActor` from this
            // type — ASWebAuthenticationSession invokes it on its XPC reply
            // queue (`com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent`),
            // and Swift 6 / iOS 26 enforces that a main-actor-isolated
            // closure is actually running on main. Without `@Sendable`,
            // the runtime trips `_swift_task_checkIsolatedSwift` and the
            // process crashes (SIGTRAP) before the continuation resumes.
            // `continuation.resume` is itself nonisolated, so running this
            // closure on a non-main queue is safe.
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { @Sendable callbackURL, error in
                if let error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: OAuthError.userCancelled)
                    } else {
                        continuation.resume(throwing: OAuthError.authSessionFailed(error.localizedDescription))
                    }
                    return
                }

                guard let callbackURL else {
                    continuation.resume(throwing: OAuthError.noCallbackURL)
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.currentSession = session

            if !session.start() {
                continuation.resume(throwing: OAuthError.authSessionFailed("Failed to start auth session"))
            }
        }
        #endif
    }

    // MARK: - Step 3: Extract Code

    private func extractCode(from url: URL, expectedState: String) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidCallback("Cannot parse callback URL")
        }

        // Check for error
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            let desc = components.queryItems?.first(where: { $0.name == "error_description" })?.value
            throw OAuthError.authorizationDenied(error, desc)
        }

        // 校验 state 与本次会话生成的随机数一致:授权服务器会原样回传 state,
        // 任意第三方构造的 primuse://?code=… 因拿不到本次 state 而被拒,
        // 阻断授权码注入 / 登录 CSRF(对无 PKCE 的百度尤为关键)。
        let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        guard let returnedState, constantTimeEquals(returnedState, expectedState) else {
            throw OAuthError.invalidCallback("State mismatch in callback URL")
        }

        guard let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw OAuthError.invalidCallback("No authorization code in callback URL")
        }

        return code
    }

    // MARK: - Step 4: Exchange Code for Tokens

    private func exchangeCodeForTokens(
        code: String,
        config: CloudOAuthConfig,
        codeVerifier: String?
    ) async throws -> CloudTokenManager.Tokens {
        guard let tokenURL = URL(string: config.tokenURL) else {
            throw OAuthError.invalidConfiguration("Invalid token URL")
        }

        var bodyParams: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "client_id": config.clientId,
        ]

        if let codeVerifier {
            bodyParams["code_verifier"] = codeVerifier
        }

        if let secret = config.clientSecret, !secret.isEmpty {
            bodyParams["client_secret"] = secret
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        // Decide content type based on platform
        if config.tokenURL.contains("alipan.com") {
            // Aliyun Drive prefers JSON
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyParams)
        } else if config.tokenURL.contains("123pan.com") {
            // 123 云盘 oauth2/access_token 用 QueryString 传参(POST, body 空)+ Platform 头。
            var comps = URLComponents(string: config.tokenURL)!
            comps.queryItems = bodyParams.keys.sorted().map { URLQueryItem(name: $0, value: bodyParams[$0]) }
            if let u = comps.url { request.url = u }
            request.setValue("open_platform", forHTTPHeaderField: "Platform")
        } else {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            // Sort keys for stable, debuggable bodies, and use strict
            // x-www-form-urlencoded escaping (only unreserved chars stay raw).
            let bodyString = bodyParams.keys.sorted()
                .map { key in "\(key)=\(formURLEncode(bodyParams[key] ?? ""))" }
                .joined(separator: "&")
            request.httpBody = bodyString.data(using: .utf8)
        }

        // Mask the secret in logs but show everything else — invaluable when an
        // OAuth provider rejects the request and you need to compare what we
        // sent against what they registered.
        plog("☁️ OAuth token POST host=\(tokenURL.host ?? "?") path=\(tokenURL.path) paramKeys=\(bodyParams.keys.sorted())")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.tokenExchangeFailed("Invalid response")
        }

        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            let safeBody = FileLogger.redactSensitiveData(String(body.prefix(500)))
            plog("☁️ OAuth token HTTP \(http.statusCode) body=\(safeBody)")
            throw OAuthError.tokenExchangeFailed("HTTP \(http.statusCode): \(safeBody)")
        }

        var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        // 部分网盘(123 / 115 等)把 token 包在 {state/code/message, data:{…}} 里;
        // 顶层没有 access_token 但 data 里有,就解包。其余 provider 顶层直出,不受影响。
        if json["access_token"] == nil,
           let inner = json["data"] as? [String: Any], inner["access_token"] != nil {
            json = inner
        }

        guard let accessToken = json["access_token"] as? String else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw OAuthError.tokenExchangeFailed("No access_token in response: \(snippet)")
        }

        let refreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)
        plog("☁️ OAuth token OK provider=\(providerName(for: config.tokenURL)) refresh=\(refreshToken != nil) expiresIn=\(Int(expiresIn))s")

        // Extract extra fields (e.g. drive_id for Aliyun)
        var extra: [String: String]?
        if let driveId = json["default_drive_id"] as? String {
            extra = ["drive_id": driveId]
        }

        return CloudTokenManager.Tokens(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            tokenType: json["token_type"] as? String,
            extra: extra
        )
    }

    // MARK: - PKCE

    private struct PKCEChallenge {
        let verifier: String
        let challenge: String

        init() {
            // Generate 32-byte random verifier
            var buffer = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
            verifier = Data(buffer)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")

            // SHA-256 hash of verifier
            let verifierData = Data(verifier.utf8)
            let hash = SHA256.hash(data: verifierData)
            challenge = Data(hash)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
    }

    // MARK: - Helpers

    /// 生成加密随机的一次性 OAuth `state`(URL-safe base64,与 PKCE verifier 同样的
    /// CSPRNG 来源)。用于把回调绑定到本次授权会话,防授权码注入 / 登录 CSRF。
    private static func makeRandomState() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 定长时间比较,避免 state 校验泄漏时序信息。
    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8)
        let rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<lhs.count {
            diff |= lhs[i] ^ rhs[i]
        }
        return diff == 0
    }

    private func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// Strict `application/x-www-form-urlencoded` escaping: only unreserved
    /// characters (`A–Z a–z 0–9 - _ . ~`) stay raw, everything else gets
    /// percent-encoded. Matches what most OAuth providers — including Baidu —
    /// expect, where leaving `:` or `/` raw inside the body can cause the
    /// server to reject `redirect_uri` validation.
    private func formURLEncode(_ string: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    private func providerName(for tokenURL: String) -> String {
        if tokenURL.contains("baidu.com") { return "baidu" }
        if tokenURL.contains("alipan.com") { return "aliyun" }
        if tokenURL.contains("googleapis.com") { return "google" }
        if tokenURL.contains("microsoftonline.com") { return "onedrive" }
        if tokenURL.contains("dropboxapi.com") { return "dropbox" }
        return URL(string: tokenURL)?.host ?? "unknown"
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // ASWebAuthenticationSession calls this on main thread, but we need nonisolated for the protocol
        MainActor.assumeIsolated {
            #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes
            let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            return windowScene?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
            #else
            // macOS: anchor 选取规则（按优先级）——
            // 1. 正在挂着 sheet 的非 sheet 窗口（OAuth sheet 实际的父窗口，
            //    比如 "Manage Sources"），这样 ASWebAuth 的浏览器窗口
            //    会出现在用户当前看到的窗口上方，不会被遮挡；
            // 2. 任意可见且非 sheet 的可成为 key 的窗口；
            // 3. mainWindow / keyWindow / 空 anchor 兜底。
            let windows = NSApplication.shared.windows
            plog("☁️ OAuth presentationAnchor: windows=\(windows.map { "[\(type(of: $0))|\($0.title)|sheet=\($0.isSheet)|visible=\($0.isVisible)|key=\($0.canBecomeKey)|attachedSheet=\($0.attachedSheet != nil)]" })")
            if let host = windows.first(where: { $0.isVisible && !$0.isSheet && $0.attachedSheet != nil }) {
                plog("☁️ OAuth presentationAnchor → host \(type(of: host)) title=\(host.title)")
                return host
            }
            if let parent = windows.first(where: { $0.isVisible && !$0.isSheet && $0.canBecomeKey }) {
                plog("☁️ OAuth presentationAnchor → \(type(of: parent)) title=\(parent.title)")
                return parent
            }
            let fallback = NSApplication.shared.mainWindow
                ?? NSApplication.shared.keyWindow
                ?? ASPresentationAnchor()
            plog("☁️ OAuth presentationAnchor fallback → \(type(of: fallback))")
            return fallback
            #endif
        }
    }
}

// MARK: - Errors

enum OAuthError: Error, LocalizedError {
    case invalidConfiguration(String)
    case userCancelled
    case authSessionFailed(String)
    case noCallbackURL
    case invalidCallback(String)
    case authorizationDenied(String, String?)
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let msg): return "配置错误: \(msg)"
        case .userCancelled: return "用户取消了授权"
        case .authSessionFailed(let msg): return "授权失败: \(msg)"
        case .noCallbackURL: return "未收到回调"
        case .invalidCallback(let msg): return "回调异常: \(msg)"
        case .authorizationDenied(let error, let desc): return "授权被拒绝: \(error) \(desc ?? "")"
        case .tokenExchangeFailed(let msg): return "令牌获取失败: \(msg)"
        }
    }
}

#if os(macOS)
// MARK: - macOS OAuth callback bridge

/// macOS 上 OAuth 走系统浏览器,callback 通过 `primuse://` URL Scheme 回到 app。
/// PrimuseApp 的 `.onOpenURL` 会把 URL 转给 `handle(_:)`,这里负责唤醒等着
/// continuation 的 OAuth 请求。同一时间只支持一个未完成的请求(再次 expect
/// 会取消上一个)。
@MainActor
final class MacOAuthBridge {
    static let shared = MacOAuthBridge()

    private var pending: (@Sendable (Result<URL, Error>) -> Void)?
    private var expectedScheme: String?

    private init() {}

    func expectCallback(scheme: String, completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        if let pending {
            pending(.failure(OAuthError.userCancelled))
        }
        expectedScheme = scheme.lowercased()
        pending = completion
    }

    /// 由 `PrimuseApp.onOpenURL` 调用。返回 true 表示已消费这个 URL。
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let expected = expectedScheme,
              scheme == expected else {
            return false
        }
        let cb = pending
        pending = nil
        expectedScheme = nil
        cb?(.success(url))
        return true
    }

    func cancel(reason: Result<URL, Error> = .failure(OAuthError.userCancelled)) {
        let cb = pending
        pending = nil
        expectedScheme = nil
        cb?(reason)
    }
}
#endif
