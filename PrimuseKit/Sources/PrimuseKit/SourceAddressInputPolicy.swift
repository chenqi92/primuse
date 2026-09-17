import Foundation

/// 「添加音乐源」里那一个地址框能吃下什么。
///
/// 以前地址和端口是两个框,端口框还预填着真实默认值,于是
/// `https://emby.example.com`(反代在 443)被拼成
/// `https://emby.example.com:8096` —— 用户看得见的地址栏语义(没写端口就是
/// 80/443)和表单的语义(端口框永远赢)是反的。这里把「用户输入 → 结构化意图」
/// 单独抽出来:先判断输入到底是厂商 ID 还是一个地址,再把地址拆成协议 / 主机 /
/// 端口 / 路径四段,**哪一段没写就明确记成 nil**,交给
/// `SourceConnectionCandidatePlanner` 去逐个试。
///
/// 全 Foundation 实现(主机分类转给现成的 `InsecureHTTPHostPolicy` /
/// `PrivateOverlayHostPolicy`),不做任何网络访问。
public enum SourceAddressInputPolicy {

    /// 主机在网络上的位置。决定候选顺序(公网先 https、内网先 http)与探测超时。
    public enum HostClass: String, Sendable, Equatable, CaseIterable {
        case loopback
        case lan
        /// Tailscale / ZeroTier 之类的私有覆盖网:不在 LAN 上,也不是公网。
        case overlay
        case `public`

        /// 从内网视角看是否「够得着就在自己家里」。
        public var isPrivate: Bool { self != .public }
    }

    /// 厂商自己的远程接入标识,不是 URL。
    public enum VendorIdentifierKind: String, Sendable, Equatable {
        case synologyQuickConnect
        case fnConnect
    }

    /// 地址里能直接读出来的部分。写了的才有值 —— `nil` 表示用户没写,
    /// 由候选规划去猜,而不是被表单的预填值悄悄顶掉。
    public struct ParsedEndpointInput: Sendable, Equatable {
        /// 地址自带的协议,已小写;没写就是 nil。
        public var explicitScheme: String?
        /// 规范化后的主机。IPv6 字面量不带方括号(套接字要的形态),
        /// zone 标识保留。
        public var host: String
        public var explicitPort: Int?
        /// authority 之后那截路径,逐字保留(反代前缀里嵌的整个 URL 也在内)。
        /// 空路径与单个 `/` 都记成 nil。
        public var pathPrefix: String?
        public var hostClass: HostClass
        public var isIPLiteral: Bool

        public init(
            explicitScheme: String? = nil,
            host: String,
            explicitPort: Int? = nil,
            pathPrefix: String? = nil,
            hostClass: HostClass,
            isIPLiteral: Bool
        ) {
            self.explicitScheme = explicitScheme
            self.host = host
            self.explicitPort = explicitPort
            self.pathPrefix = pathPrefix
            self.hostClass = hostClass
            self.isIPLiteral = isIPLiteral
        }

        /// 地址自带的协议是否明确要求 TLS。没写协议、或者该协议本来就不分明文
        /// 密文(smb / sftp / nfs)时为 nil。
        public var explicitUseSsl: Bool? {
            switch explicitScheme {
            case "https", "ftps": return true
            case "http", "ftp": return false
            default: return nil
            }
        }
    }

    /// 输入为什么用不了。界面负责翻成人话,所以这里只给枚举。
    public enum InvalidReason: String, Sendable, Equatable {
        /// 只写了协议或只写了路径,没有主机。
        case missingHost
        /// 协议和源类型对不上(往 SMB 源里贴 `https://`)。
        case schemeMismatch
        /// 端口不是 1…65535 的整数。
        case invalidPort
        /// 主机里有 URL 里不该出现的字符。
        case invalidHost
        /// 地址里带了用户名/密码。宁可让用户挪到账号栏,也不要把口令
        /// 顺手写进会被日志和同步带走的 host 字段。
        case credentialsInAddress
    }

    public enum Interpretation: Sendable, Equatable {
        case empty
        case vendorIdentifier(kind: VendorIdentifierKind, id: String)
        case endpoint(ParsedEndpointInput)
        case invalid(InvalidReason)
    }

    /// 读一遍用户填的地址。
    ///
    /// - Parameter treatDotlessTokenAsHostname: 不带点的单词(`mynas`)既可能是
    ///   厂商 ID 也可能是内网主机名,只有用户知道。默认按厂商 ID —— 内网主机名
    ///   更常见的写法是 `mynas.local` 或直接写 IP,而 QuickConnect ID 天生就是
    ///   一个光秃秃的单词。界面给一个开关把它翻过来。
    public static func interpret(
        _ raw: String,
        sourceType: MusicSourceType,
        treatDotlessTokenAsHostname: Bool = false
    ) -> Interpretation {
        let value = sanitized(raw)
        guard value.isEmpty == false else { return .empty }

        if sourceType.supportsVendorRemoteAccess,
           let vendor = vendorIdentifier(
               in: value,
               sourceType: sourceType,
               treatDotlessTokenAsHostname: treatDotlessTokenAsHostname
           ) {
            return .vendorIdentifier(kind: vendor.kind, id: vendor.id)
        }

        return endpointInterpretation(of: value, sourceType: sourceType)
    }

    /// 把已经存下来的端点渲染回地址框里的那一行。
    ///
    /// 协议**一定**写出来:省掉它就等于把 `useSsl` 丢了,再读一遍地址时只能重新
    /// 猜。端口只在等于该协议默认端口时才省(浏览器地址栏就是这么做的),这样
    /// `渲染 → 再识别 → 取第一个候选` 能原样回到同一个端点。
    public static func renderedAddress(
        for rawEndpoint: SourceConnectionEndpoint,
        sourceType: MusicSourceType
    ) -> String {
        let endpoint = rawEndpoint.normalized
        guard endpoint.host.isEmpty == false else { return "" }

        let scheme = self.scheme(for: endpoint, sourceType: sourceType)
        let impliedPort = sourceType.usesHTTPTransport
            ? (endpoint.useSsl ? 443 : 80)
            : sourceType.defaultPort(useSsl: endpoint.useSsl)
        // 展示用,所以走 urlHost 而不是 percentEncodedURLHost:zone 标识要让用户
        // 看到 `%en0`,不是 `%25en0`。真正建 URL 时才需要转义。
        let hostPart = NetworkHostAuthority.urlHost(endpoint.host)
        let authority = endpoint.port == impliedPort ? hostPart : "\(hostPart):\(endpoint.port)"
        let path = endpoint.pathPrefix ?? ""
        return "\(scheme)://\(authority)\(path)"
    }

    /// 一个源类型的地址里允许出现的协议。第一个是渲染时用的规范写法。
    public static func acceptedSchemes(for sourceType: MusicSourceType) -> [String] {
        if sourceType.usesHTTPTransport { return ["https", "http"] }
        switch sourceType {
        case .smb: return ["smb", "cifs"]
        case .ftp: return ["ftp", "ftps"]
        case .sftp: return ["sftp", "ssh"]
        case .nfs: return ["nfs"]
        default: return []
        }
    }

    // MARK: - 输入规整

    /// 中文输入法下 `:` `.` `/` 很容易打成全角,肉眼还看不太出来。这些全角字符
    /// 在地址里本来就不合法,换掉不会误伤任何真地址。
    private static let fullWidthReplacements: [Character: Character] = [
        "\u{FF1A}": ":",    // ：
        "\u{3002}": ".",    // 。
        "\u{FF0E}": ".",    // ．
        "\u{FF0F}": "/",    // ／
        "\u{FF1B}": ":"     // ；
    ]

    private static func sanitized(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return "" }
        guard trimmed.contains(where: { fullWidthReplacements[$0] != nil }) else { return trimmed }
        return String(trimmed.map { fullWidthReplacements[$0] ?? $0 })
    }

    // MARK: - 厂商标识

    private static func vendorIdentifier(
        in value: String,
        sourceType: MusicSourceType,
        treatDotlessTokenAsHostname: Bool
    ) -> (kind: VendorIdentifierKind, id: String)? {
        if treatDotlessTokenAsHostname, isDotlessToken(value) { return nil }

        switch sourceType {
        case .synology:
            guard let id = SynologyQuickConnectResolver.quickConnectID(from: value)
                ?? schemelessQuickConnectID(in: value) else { return nil }
            return (.synologyQuickConnect, id)
        case .fnMusic:
            guard let id = FnConnectResolver.fnID(from: value) else { return nil }
            return (.fnConnect, id)
        default:
            return nil
        }
    }

    /// `SynologyQuickConnectResolver` 认 `xxx.quickconnect.to` 只在地址带 scheme
    /// 时成立(它内部要先构造 URL 才能取 host)。可用户从浏览器地址栏抄下来的
    /// 常常是光秃秃的 `mynas.quickconnect.to` —— 补一个 scheme 再问一遍,判定规则
    /// 仍然是那份现成的。
    private static func schemelessQuickConnectID(in value: String) -> String? {
        guard value.contains("://") == false, value.contains("/") == false else { return nil }
        return SynologyQuickConnectResolver.quickConnectID(from: "https://\(value)")
    }

    /// 只有「一个不带点、不带斜杠、不带冒号的词」才是歧义的那种输入。
    /// `quickconnect.to/xxx`、`xxx.5ddd.com` 这些形态本身就写明了是厂商入口,
    /// 开关管不着它们。
    private static func isDotlessToken(_ value: String) -> Bool {
        value.isEmpty == false
            && value.contains(".") == false
            && value.contains("/") == false
            && value.contains(":") == false
    }

    // MARK: - 地址解析

    private static func endpointInterpretation(
        of value: String,
        sourceType: MusicSourceType
    ) -> Interpretation {
        // 反代前缀(`https://proxy/https://nav:4533`)的切分规则已经在
        // ProxyPrefixedBasePathPolicy 里定死了:只认第一个 `://`,后面的属于路径。
        let address = ProxyPrefixedBasePathPolicy.splitAddress(value)

        if let scheme = address.scheme {
            guard acceptedSchemes(for: sourceType).contains(scheme) else {
                return .invalid(.schemeMismatch)
            }
        }

        let authority = address.authority
        guard authority.isEmpty == false else { return .invalid(.missingHost) }
        guard authority.contains("@") == false else { return .invalid(.credentialsInAddress) }

        let split = NetworkHostAuthority.splitHostAndPort(authority)
        let host = NetworkHostAuthority.canonicalHost(split.host)
        guard host.isEmpty == false else { return .invalid(.missingHost) }

        let family = NetworkHostAuthority.addressFamily(of: host)
        if family == .name {
            // splitHostAndPort 把 `host:abc` 这种解析不出端口的整段退回来,
            // 所以名字里剩下的冒号只可能是写坏的端口。
            guard host.contains(":") == false else { return .invalid(.invalidPort) }
            guard isValidHostname(host) else { return .invalid(.invalidHost) }
        }
        if let port = split.port, (1...65_535).contains(port) == false {
            return .invalid(.invalidPort)
        }

        return .endpoint(
            ParsedEndpointInput(
                explicitScheme: address.scheme,
                host: host,
                explicitPort: split.port,
                pathPrefix: normalizedPathPrefix(address.pathPrefix),
                hostClass: hostClass(of: host),
                isIPLiteral: family != .name
            )
        )
    }

    /// 主机名允许的字符。下划线不合 RFC 1035,但真实存在于不少家用路由器
    /// 派发的名字里,拒掉只会让用户没法添加自己的 NAS。
    private static func isValidHostname(_ host: String) -> Bool {
        host.unicodeScalars.allSatisfy { scalar in
            // 国际化域名逐字保留,IDNA 交给系统解析器。这里只拦 ASCII 里
            // 明确不属于主机名的字符(空格、`?`、`#`、`%`…)。
            guard scalar.value < 128 else { return true }
            switch scalar {
            case ".", "-", "_": return true
            default: break
            }
            let value = scalar.value
            return (UInt32(97)...UInt32(122)).contains(value)   // a-z
                || (UInt32(65)...UInt32(90)).contains(value)    // A-Z
                || (UInt32(48)...UInt32(57)).contains(value)    // 0-9
        }
    }

    private static func normalizedPathPrefix(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false, trimmed != "/" else { return nil }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    public static func hostClass(of rawHost: String) -> HostClass {
        let host = NetworkHostAuthority.canonicalHost(rawHost).lowercased()
        guard host.isEmpty == false else { return .public }
        if isLoopbackHost(host) { return .loopback }
        // 覆盖网要先于 LAN 判:Tailscale 的 IPv6 前缀本身就落在 ULA 里,
        // 先问 isLocalNetworkHost 会把它归成 LAN 并按 LAN 的超时去探测。
        if PrivateOverlayHostPolicy.isOverlayHost(host) { return .overlay }
        if InsecureHTTPHostPolicy.isLocalNetworkHost(host) { return .lan }
        return .public
    }

    /// 只按字符判断,不引 `Network` —— 这个策略要能在 Linux 上直接跑测试。
    private static func isLoopbackHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.hasPrefix("127.") { return true }
        let literal = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        return literal == "::1" || literal == "0:0:0:0:0:0:0:1"
    }

    private static func scheme(
        for endpoint: SourceConnectionEndpoint,
        sourceType: MusicSourceType
    ) -> String {
        if sourceType.usesHTTPTransport { return endpoint.useSsl ? "https" : "http" }
        switch sourceType {
        case .ftp: return endpoint.useSsl ? "ftps" : "ftp"
        default: return acceptedSchemes(for: sourceType).first ?? "http"
        }
    }
}
