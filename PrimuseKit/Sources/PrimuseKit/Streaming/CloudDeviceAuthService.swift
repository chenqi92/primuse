import CryptoKit
import Foundation

/// Apple TV 上的云盘授权:电视画二维码,手机扫码确认,电视轮询拿 token。
///
/// 与 iOS / macOS 的区别只在「怎么把用户送到提供方的授权页」这一段 —— 手机端拉
/// `ASWebAuthenticationSession`,电视端换成提供方的扫码 / 设备码通道。拿到 token 之后
/// 两边完全一样:同一个 `SourceCredential`,同一套 `StreamResolverRegistry` 刷新与播放。
public actor CloudDeviceAuthService {
    public static let shared = CloudDeviceAuthService()

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - 开始授权

    public func begin(
        provider: MusicSourceType,
        clientID: String,
        clientSecret: String?
    ) async throws -> CloudDeviceAuthSession {
        guard let kind = CloudDeviceAuthSupport.kind(for: provider) else {
            throw CloudDeviceAuthError.unsupportedProvider(provider)
        }
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { throw CloudDeviceAuthError.missingClientCredentials }
        let secret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        if CloudDeviceAuthSupport.requiresClientSecret(provider), secret?.isEmpty != false {
            throw CloudDeviceAuthError.missingClientCredentials
        }

        switch kind {
        case .deviceCode:
            return try await beginDeviceCode(provider: provider, clientID: trimmedID)
        case .qrCode:
            switch provider {
            case .aliyunDrive:
                return try await beginAliyun(clientID: trimmedID, clientSecret: secret ?? "")
            case .pan115:
                return try await beginPan115(clientID: trimmedID)
            default:
                throw CloudDeviceAuthError.unsupportedProvider(provider)
            }
        case .manualCode:
            return try beginDropbox(clientID: trimmedID)
        }
    }

    // MARK: - 轮询

    /// 轮询一次。调用方按 `session.interval` 节流,并在超过 `expiresIn` 后自行重新 `begin`。
    public func poll(
        _ authSession: CloudDeviceAuthSession,
        clientID: String,
        clientSecret: String?
    ) async throws -> CloudDeviceAuthProgress {
        switch authSession.provider {
        case .baiduPan, .oneDrive, .googleDrive:
            return try await pollDeviceCode(
                authSession, clientID: clientID, clientSecret: clientSecret
            )
        case .aliyunDrive:
            return try await pollAliyun(authSession, clientID: clientID, clientSecret: clientSecret)
        case .pan115:
            return try await pollPan115(authSession, clientID: clientID)
        case .dropbox:
            // Dropbox 没有设备码通道,授权码只能由用户从手机上抄到电视里。
            return .pending
        default:
            throw CloudDeviceAuthError.unsupportedProvider(authSession.provider)
        }
    }

    /// Dropbox 这类「手机上回显授权码」的提供方:用户输完码后调用。
    public func redeemManualCode(
        _ authSession: CloudDeviceAuthSession,
        code: String,
        clientID: String,
        clientSecret: String?
    ) async throws -> CloudDeviceAuthResult {
        guard authSession.provider == .dropbox else {
            throw CloudDeviceAuthError.unsupportedProvider(authSession.provider)
        }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudDeviceAuthError.invalidResponse }
        var fields = [
            "code": trimmed,
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code_verifier": authSession.extra["code_verifier"] ?? "",
        ]
        if let secret = clientSecret, !secret.isEmpty { fields["client_secret"] = secret }
        let request = CloudDeviceAuthRequests.form(
            url: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
            fields: fields
        )
        let data = try await send(request)
        guard var result = CloudDeviceAuthParsing.parseTokenResponse(data) else {
            throw CloudDeviceAuthError.providerRejected(Self.errorText(data))
        }
        result = Self.stamping(result, clientID: clientID, clientSecret: clientSecret)
        return result
    }

    // MARK: - 设备码(百度 / OneDrive / Google)

    private func beginDeviceCode(
        provider: MusicSourceType,
        clientID: String
    ) async throws -> CloudDeviceAuthSession {
        let scope = CloudDeviceAuthRequests.deviceCodeScope(for: provider)
        let request: URLRequest
        switch provider {
        case .baiduPan:
            guard let url = CloudDeviceAuthRequests.get(
                "https://openapi.baidu.com/oauth/2.0/device/code",
                ["response_type": "device_code", "client_id": clientID, "scope": scope]
            ) else { throw CloudDeviceAuthError.cannotBuildURL }
            request = URLRequest(url: url)
        case .oneDrive:
            request = CloudDeviceAuthRequests.form(
                url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode")!,
                fields: ["client_id": clientID, "scope": scope]
            )
        case .googleDrive:
            request = CloudDeviceAuthRequests.form(
                url: URL(string: "https://oauth2.googleapis.com/device/code")!,
                fields: ["client_id": clientID, "scope": scope]
            )
        default:
            throw CloudDeviceAuthError.unsupportedProvider(provider)
        }
        let data = try await send(request)
        guard let start = CloudDeviceAuthParsing.parseDeviceCodeStart(data) else {
            throw CloudDeviceAuthError.providerRejected(Self.errorText(data))
        }
        // 二维码优先用提供方给的地址;没有就把 user_code 拼进 verification_uri,
        // 让用户扫完直接落在已填好码的页面上,省掉在手机上手输六位码。
        let payload = start.qrCodeURL
            ?? Self.verificationURL(withUserCode: start.userCode, base: start.verificationURL)
            ?? start.verificationURL
        guard let payload, !payload.isEmpty else {
            throw CloudDeviceAuthError.invalidResponse
        }
        return CloudDeviceAuthSession(
            provider: provider,
            kind: .deviceCode,
            qrPayload: payload,
            userCode: start.userCode,
            verificationURL: start.verificationURL,
            handle: start.deviceCode,
            interval: start.interval,
            expiresIn: start.expiresIn
        )
    }

    private func pollDeviceCode(
        _ authSession: CloudDeviceAuthSession,
        clientID: String,
        clientSecret: String?
    ) async throws -> CloudDeviceAuthProgress {
        let request: URLRequest
        switch authSession.provider {
        case .baiduPan:
            guard let url = CloudDeviceAuthRequests.get(
                "https://openapi.baidu.com/oauth/2.0/token",
                [
                    "grant_type": "device_token",
                    "code": authSession.handle,
                    "client_id": clientID,
                    "client_secret": clientSecret ?? "",
                ]
            ) else { throw CloudDeviceAuthError.cannotBuildURL }
            request = URLRequest(url: url)
        case .oneDrive:
            request = CloudDeviceAuthRequests.form(
                url: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                fields: [
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "client_id": clientID,
                    "device_code": authSession.handle,
                ]
            )
        case .googleDrive:
            var fields = [
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "client_id": clientID,
                "device_code": authSession.handle,
            ]
            if let clientSecret, !clientSecret.isEmpty { fields["client_secret"] = clientSecret }
            request = CloudDeviceAuthRequests.form(
                url: URL(string: "https://oauth2.googleapis.com/token")!, fields: fields
            )
        default:
            throw CloudDeviceAuthError.unsupportedProvider(authSession.provider)
        }
        // 设备码端点在「还没授权」时按规范回 400 + error=authorization_pending,
        // 所以这里不能把非 2xx 当失败,必须先看 body。
        let data = try await sendAllowingBodyErrors(request)
        guard let progress = CloudDeviceAuthParsing.parseDeviceCodePoll(data) else {
            throw CloudDeviceAuthError.providerRejected(Self.errorText(data))
        }
        if case .authorized(let result) = progress {
            return .authorized(Self.stamping(result, clientID: clientID, clientSecret: clientSecret))
        }
        return progress
    }

    // MARK: - 阿里云盘扫码

    private func beginAliyun(clientID: String, clientSecret: String) async throws -> CloudDeviceAuthSession {
        let request = CloudDeviceAuthRequests.json(
            url: URL(string: "https://openapi.alipan.com/oauth/authorize/qrcode")!,
            body: [
                "client_id": clientID,
                "client_secret": clientSecret,
                "scopes": CloudDeviceAuthRequests.aliyunScopes,
                "width": 430,
                "height": 430,
            ]
        )
        let data = try await send(request)
        guard let start = CloudDeviceAuthParsing.parseAliyunQRStart(data) else {
            throw CloudDeviceAuthError.providerRejected(Self.errorText(data))
        }
        return CloudDeviceAuthSession(
            provider: .aliyunDrive,
            kind: .qrCode,
            qrPayload: start.qrCodeURL,
            verificationURL: start.qrCodeURL,
            handle: start.sid,
            interval: 3,
            expiresIn: 300
        )
    }

    private func pollAliyun(
        _ authSession: CloudDeviceAuthSession,
        clientID: String,
        clientSecret: String?
    ) async throws -> CloudDeviceAuthProgress {
        guard let url = URL(string:
            "https://openapi.alipan.com/oauth/qrcode/\(authSession.handle)/status") else {
            throw CloudDeviceAuthError.cannotBuildURL
        }
        let data = try await send(URLRequest(url: url))
        guard let status = CloudDeviceAuthParsing.parseAliyunQRStatus(data) else {
            throw CloudDeviceAuthError.providerRejected(Self.errorText(data))
        }
        switch status {
        case .waiting: return .pending
        case .scanned: return .scanned
        case .expired: return .expired
        case .confirmed(let authCode):
            let exchange = CloudDeviceAuthRequests.json(
                url: URL(string: "https://openapi.alipan.com/oauth/access_token")!,
                body: [
                    "client_id": clientID,
                    "client_secret": clientSecret ?? "",
                    "grant_type": "authorization_code",
                    "code": authCode,
                ]
            )
            let tokenData = try await send(exchange)
            guard let result = CloudDeviceAuthParsing.parseTokenResponse(tokenData) else {
                throw CloudDeviceAuthError.providerRejected(Self.errorText(tokenData))
            }
            return .authorized(Self.stamping(result, clientID: clientID, clientSecret: clientSecret))
        }
    }

    // MARK: - 115 扫码

    private func beginPan115(clientID: String) async throws -> CloudDeviceAuthSession {
        let verifier = Self.makeCodeVerifier()
        let request = CloudDeviceAuthRequests.form(
            url: URL(string: "https://passportapi.115.com/open/authDeviceCode")!,
            fields: [
                "client_id": clientID,
                "code_challenge": Self.codeChallenge(for: verifier),
                "code_challenge_method": "sha256",
            ]
        )
        let data = try await send(request)
        guard let start = CloudDeviceAuthParsing.parsePan115QRStart(data) else {
            throw CloudDeviceAuthError.providerRejected(Self.errorText(data))
        }
        return CloudDeviceAuthSession(
            provider: .pan115,
            kind: .qrCode,
            qrPayload: start.qrPayload,
            handle: start.uid,
            interval: 3,
            expiresIn: 300,
            extra: ["time": start.time, "sign": start.sign, "code_verifier": verifier]
        )
    }

    private func pollPan115(
        _ authSession: CloudDeviceAuthSession,
        clientID: String
    ) async throws -> CloudDeviceAuthProgress {
        guard let url = CloudDeviceAuthRequests.get(
            "https://qrcodeapi.115.com/get/status/",
            [
                "uid": authSession.handle,
                "time": authSession.extra["time"] ?? "",
                "sign": authSession.extra["sign"] ?? "",
            ]
        ) else { throw CloudDeviceAuthError.cannotBuildURL }
        let data = try await send(URLRequest(url: url))
        guard CloudDeviceAuthParsing.pan115IsConfirmed(data) else {
            guard let progress = CloudDeviceAuthParsing.parsePan115QRStatus(data) else {
                throw CloudDeviceAuthError.providerRejected(Self.errorText(data))
            }
            return progress
        }
        let exchange = CloudDeviceAuthRequests.form(
            url: URL(string: "https://passportapi.115.com/open/deviceCodeToToken")!,
            fields: [
                "uid": authSession.handle,
                "code_verifier": authSession.extra["code_verifier"] ?? "",
            ]
        )
        let tokenData = try await send(exchange)
        guard let result = CloudDeviceAuthParsing.parsePan115Token(tokenData) else {
            throw CloudDeviceAuthError.providerRejected(Self.errorText(tokenData))
        }
        // 115 刷新只认 refresh_token,不需要 client_secret,但 client_id 仍要留着
        // 供重新授权时复用。
        return .authorized(Self.stamping(result, clientID: clientID, clientSecret: nil))
    }

    // MARK: - Dropbox(手机授权 + 电视手输授权码)

    private func beginDropbox(clientID: String) throws -> CloudDeviceAuthSession {
        let verifier = Self.makeCodeVerifier()
        // 不带 redirect_uri:Dropbox 会在授权成功后直接把授权码显示在网页上,
        // 由用户抄进电视 —— 这是 Dropbox 官方为无浏览器设备提供的做法。
        guard let url = CloudDeviceAuthRequests.get(
            "https://www.dropbox.com/oauth2/authorize",
            [
                "client_id": clientID,
                "response_type": "code",
                "token_access_type": "offline",
                "code_challenge": Self.codeChallenge(for: verifier),
                "code_challenge_method": "S256",
                "scope": CloudDeviceAuthRequests.dropboxScopes.joined(separator: " "),
            ]
        ) else { throw CloudDeviceAuthError.cannotBuildURL }
        return CloudDeviceAuthSession(
            provider: .dropbox,
            kind: .manualCode,
            qrPayload: url.absoluteString,
            verificationURL: url.absoluteString,
            handle: "",
            interval: 5,
            expiresIn: 900,
            extra: ["code_verifier": verifier]
        )
    }

    // MARK: - 传输与小工具

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CloudDeviceAuthError.badServerResponse(http.statusCode)
        }
        return data
    }

    /// 设备码轮询端点会用 4xx 表达「还没授权」,状态码不能当失败,必须解 body。
    private func sendAllowingBodyErrors(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode),
           http.statusCode != 400, http.statusCode != 401, http.statusCode != 403,
           http.statusCode != 428 {
            throw CloudDeviceAuthError.badServerResponse(http.statusCode)
        }
        return data
    }

    private static func errorText(_ data: Data) -> String {
        String(data: data.prefix(512), encoding: .utf8) ?? ""
    }

    /// 把 client 凭据留在 credential 里,后续 token 过期时 `CloudDriveStreamResolver`
    /// 才能自己拿 refresh_token 换新的,不用再把用户拉回扫码页。
    private static func stamping(
        _ result: CloudDeviceAuthResult,
        clientID: String,
        clientSecret: String?
    ) -> CloudDeviceAuthResult {
        var credential = result.credential
        credential.clientID = clientID
        if let clientSecret, !clientSecret.isEmpty { credential.clientSecret = clientSecret }
        return CloudDeviceAuthResult(
            credential: credential,
            expiresAt: result.expiresAt,
            tokenType: result.tokenType
        )
    }

    static func verificationURL(withUserCode userCode: String?, base: String?) -> String? {
        guard let base, let userCode, !userCode.isEmpty,
              var components = URLComponents(string: base) else { return nil }
        var items = components.queryItems ?? []
        guard items.contains(where: { $0.name == "user_code" }) == false else { return base }
        items.append(URLQueryItem(name: "user_code", value: userCode))
        components.queryItems = items
        return FormSafeQueryURLBuilder.url(from: components)?.absoluteString
    }

    static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
