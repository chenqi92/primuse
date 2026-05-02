import Foundation
import AuthenticationServices
import CryptoKit
#if os(iOS)
import UIKit
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

        // 1. Build authorize URL
        let authURL = try buildAuthorizeURL(config: config, pkce: pkce)
        plog("☁️ OAuth authorize URL: \(authURL.absoluteString)")

        // 2. Present system browser
        let callbackURL = try await presentAuthSession(
            url: authURL,
            callbackScheme: config.callbackURLScheme
        )

        // 3. Extract authorization code from callback
        let code = try extractCode(from: callbackURL)

        // 4. Exchange code for tokens
        let tokens = try await exchangeCodeForTokens(
            code: code,
            config: config,
            codeVerifier: pkce?.verifier
        )

        return tokens
    }

    // MARK: - Step 1: Build Authorize URL

    private func buildAuthorizeURL(config: CloudOAuthConfig, pkce: PKCEChallenge?) throws -> URL {
        guard var components = URLComponents(string: config.authURL) else {
            throw OAuthError.invalidConfiguration("Invalid auth URL: \(config.authURL)")
        }

        var queryItems: [URLQueryItem] = [
            .init(name: "client_id", value: config.clientId),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "response_type", value: "code"),
        ]

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
        try await withCheckedThrowingContinuation { continuation in
            // The completion closure must NOT inherit `@MainActor` from this
            // type — ASWebAuthenticationSession invokes it on its XPC reply
            // queue (`com.apple.NSXPCConnection.m-user.com.apple.SafariLaunchAgent`),
            // and Swift 6 / macOS 26 enforces that a main-actor-isolated
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
            session.prefersEphemeralWebBrowserSession = false // Allow SSO / existing login
            self.currentSession = session

            if !session.start() {
                continuation.resume(throwing: OAuthError.authSessionFailed("Failed to start auth session"))
            }
        }
    }

    // MARK: - Step 3: Extract Code

    private func extractCode(from url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidCallback("Cannot parse callback URL")
        }

        // Check for error
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            let desc = components.queryItems?.first(where: { $0.name == "error_description" })?.value
            throw OAuthError.authorizationDenied(error, desc)
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
        let loggedParams = bodyParams.mapValues { _ in "" }.merging(
            bodyParams.mapValues { v -> String in
                v.count > 8 ? "\(v.prefix(4))…\(v.suffix(4))" : "***"
            }
        ) { _, b in b }
        plog("☁️ OAuth token POST \(tokenURL.absoluteString) params=\(loggedParams.sorted(by: { $0.key < $1.key }))")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.tokenExchangeFailed("Invalid response")
        }

        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            plog("☁️ OAuth token HTTP \(http.statusCode) body=\(body)")
            throw OAuthError.tokenExchangeFailed("HTTP \(http.statusCode): \(body)")
        }

        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        guard let accessToken = json["access_token"] as? String else {
            throw OAuthError.tokenExchangeFailed("No access_token in response")
        }

        let refreshToken = json["refresh_token"] as? String
        let expiresIn = json["expires_in"] as? TimeInterval ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)

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

    // MARK: - ASWebAuthenticationPresentationContextProviding

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // ASWebAuthenticationSession calls this on main thread, but we need nonisolated for the protocol
        MainActor.assumeIsolated {
            #if os(iOS)
            let scenes = UIApplication.shared.connectedScenes
            let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
            return windowScene?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
            #else
            return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
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
