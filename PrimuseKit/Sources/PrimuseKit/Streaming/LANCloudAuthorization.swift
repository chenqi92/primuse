import Foundation

/// Apple TV 上添加云盘、而电视自己拿不到所需授权时,由手机上的 Primuse 代为登录。
///
/// Google 的设备码登录只放行 drive.file / drive.appdata,还要求专门的「电视与受限输入设备」
/// 类型客户端,读整个云端硬盘的授权在电视上拿不到。于是电视像「扫码直传」一样起一个一次性
/// 局域网端点,二维码形如
/// `primuse://tv-cloud-auth?host=192.168.1.50&port=54321&k=<base64url 32B>&code=123456&provider=googleDrive`;
/// iPhone / iPad 扫码后在本机完成浏览器授权,把 token 用二维码里的一次性密钥 AES-GCM 加密后
/// `POST /cloud-auth` 给电视。密钥、确认码与校验方式都沿用 `LANPairLink`,手机自己不保存这份授权。
public struct LANCloudAuthorizationLink: Sendable, Equatable {
    public static let urlHost = "tv-cloud-auth"
    public static let requestPath = "/cloud-auth"
    /// 走这条路登录的云盘。其余云盘在电视上用各自的扫码 / 设备码通道。
    public static let supportedProviders: Set<MusicSourceType> = [.googleDrive]

    public var endpoint: LANPairLink
    public var provider: MusicSourceType

    public init(endpoint: LANPairLink, provider: MusicSourceType) {
        self.endpoint = endpoint
        self.provider = provider
    }

    /// 从扫码得到的 `primuse://tv-cloud-auth?...` 解析。确认码必须随码给出:手机要把它
    /// 显示出来让用户与电视核对,不能像旧版配对码那样由密钥推算。
    public init?(url: URL) {
        guard url.scheme == "primuse", url.host == Self.urlHost,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        guard let rawProvider = items.first(where: { $0.name == "provider" })?.value,
              let provider = MusicSourceType(rawValue: rawProvider),
              let code = items.first(where: { $0.name == "code" })?.value,
              code.filter(\.isNumber).count == 6 else { return nil }
        components.host = "pair"
        components.queryItems = items.filter { $0.name != "provider" && $0.name != "v" }
        guard let pairURL = components.url, let endpoint = LANPairLink(url: pairURL) else { return nil }
        self.endpoint = endpoint
        self.provider = provider
    }

    /// 编码进电视二维码的字符串。
    public var qrContent: String {
        let fallback = "primuse://\(Self.urlHost)"
        guard var components = URLComponents(string: endpoint.qrContent) else { return fallback }
        components.host = Self.urlHost
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "v" }
            + [URLQueryItem(name: "provider", value: provider.rawValue)]
        return components.url?.absoluteString ?? fallback
    }

    /// 手机 POST 授权的目标(局域网明文 HTTP,载荷已 AES-GCM 加密)。
    public var requestURL: URL? {
        URL(string: "http://\(endpoint.host):\(endpoint.port)\(Self.requestPath)")
    }
}

/// 手机交给电视的授权。电视按自己的音乐源写进钥匙串,之后由连接器照常刷新。
public struct LANCloudAuthorizationPayload: Codable, Sendable, Equatable {
    public var provider: String
    /// 签发这份 token 的 OAuth client。刷新时必须用同一个,电视按它覆盖本源的 client 凭据。
    public var clientID: String
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var tokenType: String?

    public init(
        provider: MusicSourceType,
        clientID: String,
        accessToken: String,
        refreshToken: String?,
        expiresAt: Date?,
        tokenType: String?
    ) {
        self.provider = provider.rawValue
        self.clientID = clientID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.tokenType = tokenType
    }

    public func jsonData() throws -> Data { try JSONEncoder().encode(self) }

    public static func decode(_ data: Data) -> LANCloudAuthorizationPayload? {
        try? JSONDecoder().decode(LANCloudAuthorizationPayload.self, from: data)
    }

    /// 电视只收能长期用的授权:没有 refresh token,access token 一小时后过期,源随即掉线。
    public func isUsable(for provider: MusicSourceType) -> Bool {
        self.provider == provider.rawValue
            && !clientID.isEmpty
            && !accessToken.isEmpty
            && refreshToken?.isEmpty == false
    }
}
