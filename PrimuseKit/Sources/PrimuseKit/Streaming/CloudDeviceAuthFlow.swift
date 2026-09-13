import Foundation

/// 云盘在「无浏览器」设备(Apple TV)上的授权方式。
///
/// iPhone / Mac 走 `ASWebAuthenticationSession` 拉系统浏览器,Apple TV 没有浏览器、
/// 也没有键盘输入长网址的能力,只能用提供方自己的「扫码 / 设备码」通道:
/// 电视上画二维码,用户用手机扫、在手机上确认,电视这边轮询拿 token。
public enum CloudDeviceAuthKind: String, Sendable, Equatable {
    /// OAuth 2.0 Device Authorization Grant(RFC 8628):
    /// 拿 device_code + user_code,轮询 token 端点。百度网盘 / OneDrive / Google Drive。
    case deviceCode
    /// 提供方自有的二维码通道:先换一个二维码句柄,轮询扫码状态,确认后再换 token。
    /// 阿里云盘(sid)、115(uid+time+sign)。
    case qrCode
    /// 没有设备码通道的提供方:二维码只承载授权网址,用户在手机上授权后提供方
    /// 回显一串授权码,再由用户在电视上手动输入。Dropbox 属于这一类。
    case manualCode
}

/// 起一次设备授权后拿到的会话句柄。
public struct CloudDeviceAuthSession: Sendable, Equatable {
    public let provider: MusicSourceType
    public let kind: CloudDeviceAuthKind
    /// 编成二维码给用户扫的内容。设备码流程是 verification_uri(带 user_code 更省事),
    /// 阿里是提供方给的 qrCodeUrl,115 是 uid。
    public let qrPayload: String
    /// 需要用户在手机上核对或输入的短码。阿里 / 115 没有,为 nil。
    public let userCode: String?
    /// 给用户看的授权网址(手机上打不开二维码时可手输)。
    public let verificationURL: String?
    /// 轮询句柄:设备码流程是 device_code,阿里是 sid,115 是 uid。
    public let handle: String
    /// 提供方要求的轮询间隔(秒)。
    public let interval: TimeInterval
    /// 二维码有效期(秒)。
    public let expiresIn: TimeInterval
    /// 流程内部状态:115 的 time/sign/code_verifier、Dropbox 的 code_verifier。
    public let extra: [String: String]

    public init(
        provider: MusicSourceType,
        kind: CloudDeviceAuthKind,
        qrPayload: String,
        userCode: String? = nil,
        verificationURL: String? = nil,
        handle: String,
        interval: TimeInterval,
        expiresIn: TimeInterval,
        extra: [String: String] = [:]
    ) {
        self.provider = provider
        self.kind = kind
        self.qrPayload = qrPayload
        self.userCode = userCode
        self.verificationURL = verificationURL
        self.handle = handle
        self.interval = interval
        self.expiresIn = expiresIn
        self.extra = extra
    }
}

/// 一次轮询的结果。
public enum CloudDeviceAuthProgress: Sendable, Equatable {
    /// 二维码还没被扫 / 用户还没在手机上点确认。
    case pending
    /// 已扫码,等用户在手机上确认(阿里 / 115 有这个中间态,可以给用户反馈)。
    case scanned
    /// 授权成功,拿到可用凭据。
    case authorized(CloudDeviceAuthResult)
    /// 二维码 / 设备码过期,需要重新生成。
    case expired
    /// 用户在手机上点了拒绝。
    case denied
}

/// 授权完成后的凭据。`credential` 已经可以直接交给 `StreamResolverRegistry` 播放,
/// `expiresAt` / `tokenType` 供调用方按 CloudTokenManager 的格式落钥匙串。
public struct CloudDeviceAuthResult: Sendable, Equatable {
    public let credential: SourceCredential
    public let expiresAt: Date?
    public let tokenType: String?

    public init(credential: SourceCredential, expiresAt: Date?, tokenType: String?) {
        self.credential = credential
        self.expiresAt = expiresAt
        self.tokenType = tokenType
    }
}

public enum CloudDeviceAuthError: Error, Sendable, Equatable {
    /// 该提供方没有可用的扫码 / 设备码通道(如 123 云盘用 clientID+secret 直接换 token,
    /// Drime 用用户自建的 API token),不需要也不能走这条路。
    case unsupportedProvider(MusicSourceType)
    /// 本机没有内置该提供方的 client_id(未在 Info.plist 注入)。
    case missingClientCredentials
    case badServerResponse(Int)
    case invalidResponse
    case cannotBuildURL
    /// 提供方明确拒绝(client 未开通设备码 / 参数非法),带上服务端原文便于排查。
    case providerRejected(String)
}

// MARK: - 支持矩阵

public enum CloudDeviceAuthSupport {
    /// 能在 Apple TV 上扫码 / 设备码授权的云盘。
    ///
    /// 不在此列的原因:
    /// - `.pan123` 直接用 clientID + clientSecret 换 token,电视上填两个字段即可,不需要授权页;
    /// - `.drime` 用用户在网页后台自建的 API token,同样是填字段;
    /// - 其余类型不是云盘。
    public static let providers: Set<MusicSourceType> = [
        .aliyunDrive, .baiduPan, .pan115, .oneDrive, .googleDrive, .dropbox,
    ]

    public static func kind(for provider: MusicSourceType) -> CloudDeviceAuthKind? {
        switch provider {
        case .aliyunDrive, .pan115: return .qrCode
        case .baiduPan, .oneDrive, .googleDrive: return .deviceCode
        case .dropbox: return .manualCode
        default: return nil
        }
    }

    /// 该提供方换 token 时是否必须带 client_secret。
    public static func requiresClientSecret(_ provider: MusicSourceType) -> Bool {
        switch provider {
        case .aliyunDrive, .baiduPan: return true
        default: return false
        }
    }
}

// MARK: - 纯解析层(可脱离网络单测)

/// 各提供方设备授权应答的解析。全部是纯函数:给 `Data` 返回结构体,不碰网络,
/// 这样电视端上线前能在本机把每家的报文格式跑通。
public enum CloudDeviceAuthParsing {
    private static func json(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: 设备码流程(RFC 8628 形状:百度 / OneDrive / Google)

    public struct DeviceCodeStart: Sendable, Equatable {
        public let deviceCode: String
        public let userCode: String?
        public let verificationURL: String?
        /// 提供方直接给出的二维码地址(百度有 qrcode_url,微软 / Google 没有)。
        public let qrCodeURL: String?
        public let interval: TimeInterval
        public let expiresIn: TimeInterval
    }

    public static func parseDeviceCodeStart(_ data: Data) -> DeviceCodeStart? {
        guard let json = json(data) else { return nil }
        guard let deviceCode = nonEmpty(json["device_code"]) else { return nil }
        let verification = nonEmpty(json["verification_url"])
            ?? nonEmpty(json["verification_uri"])
            ?? nonEmpty(json["verification_uri_complete"])
        return DeviceCodeStart(
            deviceCode: deviceCode,
            userCode: nonEmpty(json["user_code"]),
            verificationURL: verification,
            qrCodeURL: nonEmpty(json["qrcode_url"]),
            // RFC 8628 默认 5 秒;提供方给了就听它的,但不让它小于 1 秒把服务端打崩。
            interval: max(1, number(json["interval"]) ?? 5),
            expiresIn: number(json["expires_in"]) ?? 300
        )
    }

    /// 设备码轮询:同一个 token 端点既可能返回 token,也可能返回 `error`。
    public static func parseDeviceCodePoll(_ data: Data) -> CloudDeviceAuthProgress? {
        guard let json = json(data) else { return nil }
        if let result = parseTokenPayload(json) { return .authorized(result) }
        guard let error = nonEmpty(json["error"])?.lowercased()
            ?? nonEmpty(json["error_code"])?.lowercased() else { return nil }
        switch error {
        case "authorization_pending", "slow_down": return .pending
        case "expired_token", "code_expired", "expired_code": return .expired
        case "authorization_declined", "access_denied": return .denied
        default:
            return nil
        }
    }

    /// 从一个已经解出来的 JSON 里取标准 OAuth token 三件套。
    public static func parseTokenPayload(_ json: [String: Any]) -> CloudDeviceAuthResult? {
        guard let accessToken = nonEmpty(json["access_token"]) else { return nil }
        var credential = SourceCredential()
        credential.token = accessToken
        credential.refreshToken = nonEmpty(json["refresh_token"])
        let expiresAt = number(json["expires_in"]).map { Date().addingTimeInterval($0) }
        return CloudDeviceAuthResult(
            credential: credential,
            expiresAt: expiresAt,
            tokenType: nonEmpty(json["token_type"])
        )
    }

    public static func parseTokenResponse(_ data: Data) -> CloudDeviceAuthResult? {
        guard let json = json(data) else { return nil }
        return parseTokenPayload(json)
    }

    // MARK: 阿里云盘二维码

    public struct AliyunQRStart: Sendable, Equatable {
        public let sid: String
        public let qrCodeURL: String
    }

    public static func parseAliyunQRStart(_ data: Data) -> AliyunQRStart? {
        guard let json = json(data),
              let sid = nonEmpty(json["sid"]),
              let qr = nonEmpty(json["qrCodeUrl"]) ?? nonEmpty(json["qrCodeURL"]) else { return nil }
        return AliyunQRStart(sid: sid, qrCodeURL: qr)
    }

    /// 阿里的状态机:WaitLogin → ScanSuccess → LoginSuccess(带 authCode)。
    /// 返回 `.authorized` 时 credential 里只有 `token` 位放着 authCode,
    /// 调用方还要再拿它换真正的 access_token —— 所以这里单独返回 authCode。
    public enum AliyunQRStatus: Sendable, Equatable {
        case waiting
        case scanned
        case confirmed(authCode: String)
        case expired
    }

    public static func parseAliyunQRStatus(_ data: Data) -> AliyunQRStatus? {
        guard let json = json(data), let status = nonEmpty(json["status"]) else { return nil }
        switch status {
        case "WaitLogin": return .waiting
        case "ScanSuccess": return .scanned
        case "LoginSuccess":
            guard let code = nonEmpty(json["authCode"]) else { return nil }
            return .confirmed(authCode: code)
        case "QRCodeExpired": return .expired
        default: return nil
        }
    }

    // MARK: 115 扫码

    public struct Pan115QRStart: Sendable, Equatable {
        public let uid: String
        public let time: String
        public let sign: String
        /// 115 返回的二维码内容;没给时用 uid 兜底(官方二维码图里编的就是 uid)。
        public let qrPayload: String
    }

    /// 115 的应答统一包一层 `{"state":1,"data":{...}}`,失败时 state 为 0 / false。
    private static func pan115Payload(_ data: Data) -> [String: Any]? {
        guard let json = json(data) else { return nil }
        if let state = json["state"] {
            let ok = (state as? NSNumber)?.boolValue ?? (state as? Bool) ?? false
            guard ok else { return nil }
        }
        return json["data"] as? [String: Any] ?? json
    }

    public static func parsePan115QRStart(_ data: Data) -> Pan115QRStart? {
        guard let payload = pan115Payload(data),
              let uid = nonEmpty(payload["uid"]) else { return nil }
        let time: String = nonEmpty(payload["time"])
            ?? (payload["time"] as? NSNumber).map { String($0.int64Value) }
            ?? ""
        guard !time.isEmpty, let sign = nonEmpty(payload["sign"]) else { return nil }
        return Pan115QRStart(
            uid: uid,
            time: time,
            sign: sign,
            qrPayload: nonEmpty(payload["qrcode"]) ?? uid
        )
    }

    /// 115 扫码状态:0 等待、1 已扫待确认、2 已确认、-1/-2 失效或取消。
    public static func parsePan115QRStatus(_ data: Data) -> CloudDeviceAuthProgress? {
        guard let payload = pan115Payload(data) else { return .expired }
        guard let status = number(payload["status"]).map({ Int($0) }) else { return nil }
        switch status {
        case 0: return .pending
        case 1: return .scanned
        // 已确认:token 要再用 uid + code_verifier 去 deviceCodeToToken 换,
        // 这里只能报告「可以去换了」,由调用方接着走。
        case 2: return .scanned
        case -2: return .denied
        default: return .expired
        }
    }

    public static func parsePan115Token(_ data: Data) -> CloudDeviceAuthResult? {
        guard let payload = pan115Payload(data) else { return nil }
        return parseTokenPayload(payload)
    }

    public static func pan115IsConfirmed(_ data: Data) -> Bool {
        guard let payload = pan115Payload(data),
              let status = number(payload["status"]).map({ Int($0) }) else { return false }
        return status == 2
    }
}

// MARK: - 请求构造(纯函数,便于核对每家的参数)

public enum CloudDeviceAuthRequests {
    public static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
    }

    public static func formBody(_ fields: [String: String]) -> String {
        fields.keys.sorted()
            .map { "\($0)=\(formEncode(fields[$0] ?? ""))" }
            .joined(separator: "&")
    }

    static func form(url: URL, fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(fields).data(using: .utf8)
        return request
    }

    static func json(url: URL, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? SafeJSONSerialization.data(withJSONObject: body)
        return request
    }

    static func get(_ base: String, _ items: [String: String]) -> URL? {
        guard var components = URLComponents(string: base) else { return nil }
        components.queryItems = items.keys.sorted().map { URLQueryItem(name: $0, value: items[$0]) }
        return FormSafeQueryURLBuilder.url(from: components)
    }

    /// 设备码流程每家的 scope 与 iOS 浏览器授权保持一致,否则拿到的 token 权限对不上。
    public static func deviceCodeScope(for provider: MusicSourceType) -> String {
        switch provider {
        case .baiduPan: return "basic,netdisk"
        case .oneDrive: return "Files.ReadWrite offline_access"
        case .googleDrive: return "https://www.googleapis.com/auth/drive"
        default: return ""
        }
    }

    public static let aliyunScopes = ["user:base", "file:all:read", "file:all:write"]
    public static let dropboxScopes = [
        "account_info.read", "files.content.read", "files.content.write",
        "files.metadata.read", "files.metadata.write",
    ]
}
