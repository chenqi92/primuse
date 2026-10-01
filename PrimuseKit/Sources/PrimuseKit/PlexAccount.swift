import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - plex.tv 账号

/// plex.tv 账号登录与服务器清单。
///
/// 走的是 Plex 公开的 PIN 授权（developer.plex.tv「Authenticating with Plex」）：
/// - `POST /api/v2/pins?strong=true` 拿一枚长码，交给 `app.plex.tv/auth` 网页去授权；
///   不带 `strong` 拿到的是 4 位短码，给没有浏览器的电视用 plex.tv/link 输入。
/// - `GET /api/v2/pins/{id}` 轮询，用户在网页上点了允许之后 `authToken` 才有值。
/// - `GET clients.plex.tv/api/v2/resources` 列出这个账号能用的设备。好友分享的服务器也在里面，
///   每台服务器都带一枚**这台服务器专属**的 accessToken —— 对分享来的服务器，它和账号 token 不是同一个。
///
/// 轮询和建 PIN 必须带同一个 `X-Plex-Client-Identifier`，否则 plex.tv 认不出是谁来取结果。
public enum PlexAccountAPI {
    public static let product = "Primuse"
    public static let pinsURL = URL(string: "https://plex.tv/api/v2/pins")!
    public static let resourcesURL = URL(
        string: "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1"
    )!
    /// 电视上用的短码要到这里输入。
    public static let linkPageURL = URL(string: "https://plex.tv/link")!
    /// 轮询间隔。PIN 的有效期是半小时，用户在手机上登录通常要十几秒到一分钟。
    public static let pollInterval: Duration = .seconds(2)

    public static func pinURL(id: Int) -> URL {
        pinsURL.appendingPathComponent(String(id))
    }

    /// 账号 token 存在钥匙串里的条目名。服务器专属 token 照旧存在源自己的密码条目里。
    public static func accountTokenKeychainAccount(sourceID: String) -> String {
        "plex-account.\(sourceID)"
    }

    /// `app.plex.tv/auth` 的授权页地址。参数写在 `#?` 后面，这是 Plex 网页应用自己的约定。
    public static func authorizationPageURL(
        clientIdentifier: String,
        code: String,
        forwardURL: URL? = nil
    ) -> URL {
        var parameters: [(String, String)] = [
            ("clientID", clientIdentifier),
            ("code", code),
            ("context[device][product]", product),
        ]
        if let forwardURL {
            parameters.append(("forwardUrl", forwardURL.absoluteString))
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+#?[]/:")
        // 类型写明：PrimuseKit 链接了 GRDB，它的 `SQL` 也接受字符串插值并带 `joined(separator:)`，
        // 不写的话这一串会被推断成 SQL，拼出来的是它的调试描述。
        let pairs: [String] = parameters.map { pair -> String in
            let (name, value) = pair
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedName)=\(encodedValue)"
        }
        let fragment: String = pairs.joined(separator: "&")
        return URL(string: "https://app.plex.tv/auth#?\(fragment)")!
    }

    /// plex.tv 认设备用的几项请求头。设备会以这些名字出现在用户 Plex 账号的「已授权设备」里。
    public static func headers(
        clientIdentifier: String,
        platform: String,
        deviceName: String,
        version: String,
        token: String? = nil
    ) -> [String: String] {
        var headers: [String: String] = [
            "Accept": "application/json",
            "X-Plex-Product": product,
            "X-Plex-Version": version,
            "X-Plex-Client-Identifier": clientIdentifier,
            "X-Plex-Platform": platform,
            "X-Plex-Device": deviceName,
            "X-Plex-Device-Name": "\(product) (\(deviceName))",
        ]
        if let token, token.isEmpty == false {
            headers["X-Plex-Token"] = token
        }
        return headers
    }
}

/// 一枚登录用的 PIN。`authToken` 在用户授权之前一直是 nil。
public struct PlexPin: Decodable, Sendable, Equatable {
    public let id: Int
    public let code: String
    public let authToken: String?

    public init(id: Int, code: String, authToken: String? = nil) {
        self.id = id
        self.code = code
        self.authToken = authToken
    }

    private enum CodingKeys: String, CodingKey {
        case id, code, authToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = try container.plexLossyInt(forKey: .id) else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "PIN without an id"
            )
        }
        self.id = id
        code = try container.decode(String.self, forKey: .code)
        let token = try container.decodeIfPresent(String.self, forKey: .authToken)
        authToken = token?.isEmpty == false ? token : nil
    }
}

/// plex.tv 设备清单里的一项。只有 `provides` 含 `server` 的才是媒体服务器。
public struct PlexResource: Decodable, Sendable, Equatable, Identifiable {
    public struct Connection: Decodable, Sendable, Equatable {
        public let scheme: String?
        public let address: String?
        public let port: Int?
        public let uri: String?
        public let isLocal: Bool
        public let isRelay: Bool
        public let isIPv6: Bool

        public init(
            scheme: String?,
            address: String?,
            port: Int?,
            uri: String?,
            isLocal: Bool,
            isRelay: Bool = false,
            isIPv6: Bool = false
        ) {
            self.scheme = scheme
            self.address = address
            self.port = port
            self.uri = uri
            self.isLocal = isLocal
            self.isRelay = isRelay
            self.isIPv6 = isIPv6
        }

        private enum CodingKeys: String, CodingKey {
            case scheme = "protocol"
            case address, port, uri
            case isLocal = "local"
            case isRelay = "relay"
            case isIPv6 = "IPv6"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            scheme = try container.decodeIfPresent(String.self, forKey: .scheme)
            address = try container.decodeIfPresent(String.self, forKey: .address)
            port = try container.plexLossyInt(forKey: .port)
            uri = try container.decodeIfPresent(String.self, forKey: .uri)
            isLocal = container.plexLossyBool(forKey: .isLocal) ?? false
            isRelay = container.plexLossyBool(forKey: .isRelay) ?? false
            isIPv6 = container.plexLossyBool(forKey: .isIPv6) ?? false
        }
    }

    public let name: String
    public let clientIdentifier: String
    public let provides: String
    public let isOwned: Bool
    public let isHome: Bool
    /// 分享这台服务器的人（只有好友分享来的服务器才有）。
    public let ownerName: String?
    public let accessToken: String?
    /// 服务器此刻有没有连上 plex.tv。离线的服务器照样能加，地址是它上次报告的。
    public let isOnline: Bool
    /// 现在发请求的这台设备和服务器是不是同一个公网出口 —— 也就是在不在同一个家里。
    public let publicAddressMatches: Bool
    public let httpsRequired: Bool
    /// 服务器探测到自己所在的网络会拦掉解析到内网地址的域名（`*.plex.direct`）。
    public let dnsRebindingProtection: Bool
    public let connections: [Connection]

    public var id: String { clientIdentifier }

    public var isServer: Bool {
        provides
            .split(separator: ",")
            .contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "server" }
    }

    public init(
        name: String,
        clientIdentifier: String,
        provides: String = "server",
        isOwned: Bool,
        isHome: Bool = false,
        ownerName: String? = nil,
        accessToken: String?,
        isOnline: Bool = true,
        publicAddressMatches: Bool = false,
        httpsRequired: Bool = false,
        dnsRebindingProtection: Bool = false,
        connections: [Connection]
    ) {
        self.name = name
        self.clientIdentifier = clientIdentifier
        self.provides = provides
        self.isOwned = isOwned
        self.isHome = isHome
        self.ownerName = ownerName
        self.accessToken = accessToken
        self.isOnline = isOnline
        self.publicAddressMatches = publicAddressMatches
        self.httpsRequired = httpsRequired
        self.dnsRebindingProtection = dnsRebindingProtection
        self.connections = connections
    }

    private enum CodingKeys: String, CodingKey {
        case name, clientIdentifier, provides, accessToken, connections
        case isOwned = "owned"
        case isHome = "home"
        case ownerName = "sourceTitle"
        case isOnline = "presence"
        case publicAddressMatches, httpsRequired, dnsRebindingProtection
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        clientIdentifier = try container.decode(String.self, forKey: .clientIdentifier)
        provides = try container.decodeIfPresent(String.self, forKey: .provides) ?? ""
        isOwned = container.plexLossyBool(forKey: .isOwned) ?? false
        isHome = container.plexLossyBool(forKey: .isHome) ?? false
        let owner = try container.decodeIfPresent(String.self, forKey: .ownerName)
        ownerName = owner?.isEmpty == false ? owner : nil
        let token = try container.decodeIfPresent(String.self, forKey: .accessToken)
        accessToken = token?.isEmpty == false ? token : nil
        isOnline = container.plexLossyBool(forKey: .isOnline) ?? true
        publicAddressMatches = container.plexLossyBool(forKey: .publicAddressMatches) ?? false
        httpsRequired = container.plexLossyBool(forKey: .httpsRequired) ?? false
        dnsRebindingProtection = container.plexLossyBool(forKey: .dnsRebindingProtection) ?? false
        // 一条连接解析不了就丢掉这一条，不让整台服务器从清单里消失。
        connections = (try? container.decodeIfPresent(
            [PlexLossyElement<Connection>].self,
            forKey: .connections
        ))?.compactMap(\.value) ?? []
    }
}

public enum PlexResourceList {
    /// 清单里的媒体服务器：自己的在前，其次是 Plex Home 里共享的，最后是好友分享的；同组按名字排。
    public static func servers(from resources: [PlexResource]) -> [PlexResource] {
        resources
            .filter { $0.isServer && $0.clientIdentifier.isEmpty == false }
            .sorted { lhs, rhs in
                let left = rank(lhs)
                let right = rank(rhs)
                if left != right { return left < right }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    public static func decodeServers(from data: Data) throws -> [PlexResource] {
        let elements = try JSONDecoder().decode([PlexLossyElement<PlexResource>].self, from: data)
        return servers(from: elements.compactMap(\.value))
    }

    private static func rank(_ resource: PlexResource) -> Int {
        if resource.isOwned { return 0 }
        if resource.isHome { return 1 }
        return 2
    }
}

// MARK: - 连接列表 → 线路

/// 一台服务器在音乐源里的一条线路。
public struct PlexServerRoute: Sendable, Equatable {
    public let host: String
    public let port: Int
    public let useSsl: Bool
    /// 走的是 Plex 的中转服务器：能连上，但带宽有限，高码率无损可能播不顺。
    public let isRelay: Bool

    public init(host: String, port: Int, useSsl: Bool, isRelay: Bool = false) {
        self.host = host
        self.port = port
        self.useSsl = useSsl
        self.isRelay = isRelay
    }

    public var endpoint: SourceConnectionEndpoint {
        SourceConnectionEndpoint(host: host, port: port, useSsl: useSsl)
    }
}

/// 音乐源只有内网、外网两个槽，这里从 Plex 给的一串连接里各挑一条。
public struct PlexServerRoutes: Sendable, Equatable {
    public let local: PlexServerRoute?
    public let remote: PlexServerRoute?

    public init(local: PlexServerRoute?, remote: PlexServerRoute?) {
        self.local = local
        self.remote = remote
    }

    public var isEmpty: Bool { local == nil && remote == nil }

    /// 只能经 Plex 中转连上（好友的服务器没开远程访问时就是这样）。
    public var reachesOnlyThroughRelay: Bool {
        local == nil && remote?.isRelay == true
    }

    public var connectionConfiguration: SourceConnectionConfiguration {
        SourceConnectionConfiguration(
            localEndpoint: local?.endpoint,
            publicEndpoint: remote?.endpoint
        )
    }
}

public enum PlexServerConnectionPlanner {
    /// - 内网线路只在「服务器是自己的」或「此刻和服务器在同一个公网出口后面」时才要：
    ///   好友家的 192.168.1.10 在你家可能是另一台机器。
    /// - 内网优先用 `*.plex.direct` 的 HTTPS 地址（证书是公开签发的，不用弹信任框）；
    ///   服务器报告所在网络会拦这种域名、而它又没强制 HTTPS 时，退回明文 IP。
    /// - 外网优先直连，没有直连才用中转。
    /// - IPv6 连接只在没有 IPv4 可选时才用。
    public static func routes(for resource: PlexResource) -> PlexServerRoutes {
        let usable = resource.connections.filter { route(from: $0, preferPlainAddress: false) != nil }

        var local: PlexServerRoute?
        if resource.isOwned || resource.publicAddressMatches {
            let candidates = usable.filter { $0.isLocal && !$0.isRelay }
            if let best = preferred(candidates, rankAddress: localAddressRank) {
                let plain = resource.dnsRebindingProtection && !resource.httpsRequired
                local = route(from: best, preferPlainAddress: plain)
                    ?? route(from: best, preferPlainAddress: false)
            }
        }

        let direct = usable.filter { !$0.isLocal && !$0.isRelay }
        let relays = usable.filter(\.isRelay)
        let remote = preferred(direct, rankAddress: { _ in 0 })
            .flatMap { route(from: $0, preferPlainAddress: false) }
            ?? preferred(relays, rankAddress: { _ in 0 })
                .flatMap { route(from: $0, preferPlainAddress: false) }

        return PlexServerRoutes(local: local, remote: remote)
    }

    /// 同类连接里挑一条：IPv4 先于 IPv6，HTTPS 先于 HTTP，再按地址段排，最后保持 Plex 给的顺序。
    private static func preferred(
        _ connections: [PlexResource.Connection],
        rankAddress: (String) -> Int
    ) -> PlexResource.Connection? {
        connections.enumerated().min { lhs, rhs in
            let left = sortKey(lhs.element, index: lhs.offset, rankAddress: rankAddress)
            let right = sortKey(rhs.element, index: rhs.offset, rankAddress: rankAddress)
            return left.lexicographicallyPrecedes(right)
        }?.element
    }

    private static func sortKey(
        _ connection: PlexResource.Connection,
        index: Int,
        rankAddress: (String) -> Int
    ) -> [Int] {
        [
            connection.isIPv6 ? 1 : 0,
            isSecure(connection) ? 0 : 1,
            rankAddress(connection.address ?? ""),
            index,
        ]
    }

    private static func isSecure(_ connection: PlexResource.Connection) -> Bool {
        if let scheme = connection.uri.flatMap({ URLComponents(string: $0)?.scheme }) {
            return scheme.lowercased() == "https"
        }
        return connection.scheme?.lowercased() == "https"
    }

    /// 家用路由器常见网段排前面。装在 Docker 里的 Plex 会把容器网桥（172.17.x.x）也报成内网地址，
    /// 那个地址从别的设备是连不到的。
    private static func localAddressRank(_ address: String) -> Int {
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return 3 }
        switch (octets[0], octets[1]) {
        case (192, 168): return 0
        case (10, _): return 1
        case (172, 16...31): return 2
        default: return 3
        }
    }

    static func route(
        from connection: PlexResource.Connection,
        preferPlainAddress: Bool
    ) -> PlexServerRoute? {
        if preferPlainAddress {
            guard let address = connection.address?.trimmingCharacters(in: .whitespacesAndNewlines),
                  address.isEmpty == false,
                  let port = connection.port,
                  (1...65_535).contains(port) else {
                return nil
            }
            return PlexServerRoute(
                host: stripBrackets(address),
                port: port,
                useSsl: false,
                isRelay: connection.isRelay
            )
        }

        if let uri = connection.uri,
           let components = URLComponents(string: uri),
           let scheme = components.scheme?.lowercased(),
           scheme == "https" || scheme == "http",
           let host = components.host.map(stripBrackets),
           host.isEmpty == false {
            let useSsl = scheme == "https"
            let port = components.port ?? connection.port ?? (useSsl ? 443 : 80)
            guard (1...65_535).contains(port) else { return nil }
            return PlexServerRoute(host: host, port: port, useSsl: useSsl, isRelay: connection.isRelay)
        }

        guard let address = connection.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              address.isEmpty == false,
              let port = connection.port,
              (1...65_535).contains(port) else {
            return nil
        }
        return PlexServerRoute(
            host: stripBrackets(address),
            port: port,
            useSsl: connection.scheme?.lowercased() == "https",
            isRelay: connection.isRelay
        )
    }

    private static func stripBrackets(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }
}

/// 在服务器清单里点中的那一台，连同建源要写进去的全部东西。
public struct PlexServerSelection: Equatable, Sendable {
    public let resource: PlexResource
    public let routes: PlexServerRoutes
    public let accountToken: String

    /// 一条能用的线路都没有就没法建源，返回 nil。
    public init?(resource: PlexResource, accountToken: String) {
        let routes = PlexServerConnectionPlanner.routes(for: resource)
        guard routes.isEmpty == false, accountToken.isEmpty == false else { return nil }
        self.resource = resource
        self.routes = routes
        self.accountToken = accountToken
    }

    /// 自己的服务器 plex.tv 也会给一枚专属 token；万一没给，账号 token 对自己的服务器同样有效。
    public var serverToken: String { resource.accessToken ?? accountToken }
}

/// `1-2-3-4.<32 位十六进制>.plex.direct` 这类主机名把服务器的 IPv4 写在第一段里，
/// 内网那条线路的主机名长得和公网域名一样，靠这个才认得出它其实是内网地址。
public enum PlexDirectHost {
    public static let suffix = ".plex.direct"

    public static func isPlexDirect(_ host: String) -> Bool {
        host.lowercased().hasSuffix(suffix)
    }

    public static func embeddedIPv4Address(_ rawHost: String) -> String? {
        let host = rawHost.lowercased()
        guard host.hasSuffix(suffix) else { return nil }
        let labels = host.dropLast(suffix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 2,
              labels[1].count == 32,
              labels[1].allSatisfy(\.isHexDigit) else {
            return nil
        }
        let octets = labels[0].split(separator: "-", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ part in
                  guard part.isEmpty == false, part.count <= 3, part.allSatisfy(\.isNumber),
                        let value = Int(part) else { return false }
                  return (0...255).contains(value)
              }) else {
            return nil
        }
        return octets.joined(separator: ".")
    }
}

// MARK: - 已绑定服务器的线路刷新

/// 用账号重新查一遍服务器之后，源里哪些线路该换。
///
/// 只换 Plex 自己给的那几种地址：`*.plex.direct` 域名和裸 IP。用户自己填的域名（反向代理之类）原样留着；
/// 这次清单里没有的槽也不清空 —— 服务器暂时没报某条连接，不代表那条线路不能用了。
public enum PlexServerLinkRefreshPolicy {
    public static func refreshedConfiguration(
        current: SourceConnectionConfiguration?,
        routes: PlexServerRoutes
    ) -> SourceConnectionConfiguration? {
        guard routes.isEmpty == false else { return nil }
        let currentLocal = current?.localEndpoint?.normalized
        let currentPublic = current?.publicEndpoint?.normalized

        let local = replacement(current: currentLocal, with: routes.local?.endpoint.normalized)
        let remote = replacement(current: currentPublic, with: routes.remote?.endpoint.normalized)
        guard local != currentLocal || remote != currentPublic else { return nil }

        var configuration = current ?? SourceConnectionConfiguration()
        configuration.localEndpoint = local
        configuration.publicEndpoint = remote
        return configuration
    }

    /// 服务器专属 token 变了（分享被撤销又重新分享、账号改过密码）才需要改写。
    public static func refreshedToken(current: String?, resource: PlexResource) -> String? {
        guard let token = resource.accessToken, token != current else { return nil }
        return token
    }

    private static func replacement(
        current: SourceConnectionEndpoint?,
        with fresh: SourceConnectionEndpoint?
    ) -> SourceConnectionEndpoint? {
        guard let fresh else { return current }
        guard let current else { return fresh }
        return isPlexProvided(current.host) ? fresh : current
    }

    static func isPlexProvided(_ host: String) -> Bool {
        if PlexDirectHost.isPlexDirect(host) { return true }
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let ipv4Octets = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if ipv4Octets.count == 4, ipv4Octets.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) {
            return true
        }
        return trimmed.contains(":") && trimmed.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" }
    }
}

// MARK: - 网络请求

public enum PlexAccountError: Error, Equatable, Sendable {
    /// PIN 过期或被取消（plex.tv 返回 404）。
    case pinExpired
    /// 账号 token 失效了：用户在 plex.tv 上移除了这台设备或改了密码。
    case unauthorized
    case rateLimited
    case badStatus(Int)
    case invalidResponse
}

/// plex.tv 上的几个请求。不缓存、不重试，节奏由调用方决定。
public struct PlexAccountClient: Sendable {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public let clientIdentifier: String
    public let platform: String
    public let deviceName: String
    public let version: String
    private let loader: DataLoader

    public init(
        clientIdentifier: String,
        platform: String,
        deviceName: String,
        version: String,
        loader: DataLoader? = nil
    ) {
        self.clientIdentifier = clientIdentifier
        self.platform = platform
        self.deviceName = deviceName
        self.version = version
        if let loader {
            self.loader = loader
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 40
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration)
            self.loader = { request in try await session.data(for: request) }
        }
    }

    /// `strong = true`：给网页授权用的长码；`false`：给 plex.tv/link 手输的 4 位码。
    public func createPin(strong: Bool) async throws -> PlexPin {
        var components = URLComponents(url: PlexAccountAPI.pinsURL, resolvingAgainstBaseURL: false)!
        if strong {
            components.queryItems = [URLQueryItem(name: "strong", value: "true")]
        }
        var request = makeRequest(url: components.url!, token: nil)
        request.httpMethod = "POST"
        let data = try await send(request)
        return try decode(PlexPin.self, from: data)
    }

    public func checkPin(id: Int) async throws -> PlexPin {
        let data = try await send(makeRequest(url: PlexAccountAPI.pinURL(id: id), token: nil))
        return try decode(PlexPin.self, from: data)
    }

    public func servers(accountToken: String) async throws -> [PlexResource] {
        let data = try await send(makeRequest(url: PlexAccountAPI.resourcesURL, token: accountToken))
        do {
            return try PlexResourceList.decodeServers(from: data)
        } catch {
            throw PlexAccountError.invalidResponse
        }
    }

    private func makeRequest(url: URL, token: String?) -> URLRequest {
        var request = URLRequest(url: url)
        for (name, value) in PlexAccountAPI.headers(
            clientIdentifier: clientIdentifier,
            platform: platform,
            deviceName: deviceName,
            version: version,
            token: token
        ) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await loader(request)
        guard let http = response as? HTTPURLResponse else { throw PlexAccountError.invalidResponse }
        switch http.statusCode {
        case 200...299: return data
        case 401, 403: throw PlexAccountError.unauthorized
        case 404: throw PlexAccountError.pinExpired
        case 429: throw PlexAccountError.rateLimited
        default: throw PlexAccountError.badStatus(http.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw PlexAccountError.invalidResponse
        }
    }
}

#if canImport(CryptoKit)
public extension PlexAccountClient {
    /// 本机的登录客户端。设备号整机一个、和任何源都无关：登录发生在源存在之前，
    /// 而 plex.tv 只认「建 PIN 的和来取结果的是不是同一个设备号」。
    static func standard() -> PlexAccountClient {
        #if os(tvOS)
        let platform = "tvOS"
        #elseif os(macOS)
        let platform = "macOS"
        #else
        let platform = "iOS"
        #endif
        return PlexAccountClient(
            clientIdentifier: MediaServerDeviceIdentity.deviceID(sourceID: "plex.tv-account"),
            platform: platform,
            deviceName: MediaServerDeviceIdentity.deviceName,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        )
    }
}
#endif

// MARK: - 宽松解码

/// 清单里某一项解不出来时只丢这一项。
struct PlexLossyElement<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// plex.tv 的 JSON 里布尔值大多是 true/false，个别老接口写成 0/1 或 "1"。
    func plexLossyBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }

    func plexLossyInt(forKey key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }
}
