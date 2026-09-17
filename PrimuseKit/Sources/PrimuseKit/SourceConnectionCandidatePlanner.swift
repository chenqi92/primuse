import Foundation

/// 地址里没写明协议或端口时,该按什么顺序去试。
///
/// 规则的出发点是浏览器地址栏:**看不见端口就是 80 / 443**。以前的表单反过来
/// 做 —— 端口框预填服务默认端口并且永远赢,所以反代后面的 Emby 被连到
/// `https://host:8096`。这里把「用户明确写下的」和「我们替他猜的」分开,写下的
/// 是硬约束,猜的排成一串候选交给 `SourceEndpointResolver` 逐个验证。
///
/// 纯函数、不访问网络,给出的顺序就是探测的优先级顺序。
public enum SourceConnectionCandidatePlanner {

    /// 这个候选是怎么来的。界面要把它翻成人话("按你写的端口"/"该协议的默认
    /// 端口"/"Emby 的默认端口"),所以是枚举而不是自由文本。
    public enum CandidateOrigin: String, Sendable, Equatable {
        /// 地址里写明的端口。
        case explicitAddress
        /// 用户在高级选项里手填的端口 / 手选的协议。
        case manualOverride
        /// 该协议的默认端口:https 443、http 80。
        case schemeDefaultPort
        /// 该服务在这个协议下的公布端口:Emby 8096 / 8920 之类。
        case serviceDefaultPort
        /// 非 HTTP 协议只有一个端口可言(SMB 445、SFTP 22…)。
        case fixedProtocolPort
    }

    public struct Candidate: Sendable, Equatable, Identifiable {
        public var useSsl: Bool
        public var port: Int
        public var origin: CandidateOrigin

        public init(useSsl: Bool, port: Int, origin: CandidateOrigin) {
            self.useSsl = useSsl
            self.port = port
            self.origin = origin
        }

        /// 同一个 (传输, 端口) 只该出现一次 —— WebDAV 这种服务端口本身就是
        /// 80/443 的类型,四条规则会塌缩成两条。
        public var id: String { "\(useSsl ? "ssl" : "plain"):\(port)" }

        /// 仅对 HTTP 类型有意义;SMB / SFTP / NFS 的协议名由
        /// `SourceAddressInputPolicy.acceptedSchemes(for:)` 决定。
        public var httpScheme: String { useSsl ? "https" : "http" }
    }

    /// 探测要花真实时间,而再往下排的候选已经没有实际命中率了。五条足够覆盖
    /// 「两种协议 × (协议默认端口 + 服务默认端口)」再多一条手填的。
    public static let maximumCandidateCount = 5

    public static func candidates(
        for input: SourceAddressInputPolicy.ParsedEndpointInput,
        sourceType: MusicSourceType,
        manualPort: Int? = nil,
        manualUseSsl: Bool? = nil
    ) -> [Candidate] {
        let manualPort = manualPort.flatMap { (1...65_535).contains($0) ? $0 : nil }
        guard sourceType.usesHTTPTransport else {
            return [nonHTTPCandidate(for: input, sourceType: sourceType, manualPort: manualPort, manualUseSsl: manualUseSsl)]
        }

        let fixedSsl = input.explicitUseSsl ?? manualUseSsl
        let fixedPort = input.explicitPort ?? manualPort
        let portOrigin: CandidateOrigin = input.explicitPort != nil ? .explicitAddress : .manualOverride

        let planned: [Candidate]
        switch (fixedSsl, fixedPort) {
        case (let ssl?, let port?):
            // 两维都定死了,没得猜。
            planned = [Candidate(useSsl: ssl, port: port, origin: portOrigin)]
        case (let ssl?, nil):
            // 地址栏语义:协议写了、端口没写,先按该协议的默认端口试,再退回
            // 服务自己公布的端口(直连 NAS 的情形)。
            planned = [
                Candidate(useSsl: ssl, port: ssl ? 443 : 80, origin: .schemeDefaultPort),
                Candidate(useSsl: ssl, port: sourceType.defaultPort(useSsl: ssl), origin: .serviceDefaultPort)
            ]
        case (nil, let port?):
            planned = orderedByPortHint(
                port: port,
                origin: portOrigin,
                sourceType: sourceType,
                hostClass: input.hostClass
            )
        case (nil, nil):
            planned = orderedByHostClass(sourceType: sourceType, hostClass: input.hostClass)
        }

        return deduplicated(planned)
    }

    /// 把一个候选落成能存进源记录的端点。第二步的界面保存路径要用它,
    /// 顺带保证「渲染地址 → 再识别 → 取第一个候选」能原样回到同一个端点。
    public static func endpoint(
        for input: SourceAddressInputPolicy.ParsedEndpointInput,
        candidate: Candidate
    ) -> SourceConnectionEndpoint {
        SourceConnectionEndpoint(
            host: input.host,
            port: candidate.port,
            useSsl: candidate.useSsl,
            pathPrefix: input.pathPrefix
        )
    }

    // MARK: - 排序

    /// 端口本身就是提示:写 443 的人要的是 https,写 8096 的人要的是 Emby 的
    /// 明文口。都不是就按主机位置猜 —— 公网上明文是异常,内网里 TLS 才是异常。
    private static func orderedByPortHint(
        port: Int,
        origin: CandidateOrigin,
        sourceType: MusicSourceType,
        hostClass: SourceAddressInputPolicy.HostClass
    ) -> [Candidate] {
        let secure = Candidate(useSsl: true, port: port, origin: origin)
        let cleartext = Candidate(useSsl: false, port: port, origin: origin)

        let servicePort = (https: sourceType.defaultPort(useSsl: true), http: sourceType.defaultPort(useSsl: false))
        if port == 443 || port == 8443 || (port == servicePort.https && servicePort.https != servicePort.http) {
            return [secure, cleartext]
        }
        if port == 80 || (port == servicePort.http && servicePort.https != servicePort.http) {
            return [cleartext, secure]
        }
        return hostClass.isPrivate ? [cleartext, secure] : [secure, cleartext]
    }

    private static func orderedByHostClass(
        sourceType: MusicSourceType,
        hostClass: SourceAddressInputPolicy.HostClass
    ) -> [Candidate] {
        let serviceHTTP = Candidate(
            useSsl: false,
            port: sourceType.defaultPort(useSsl: false),
            origin: .serviceDefaultPort
        )
        let serviceHTTPS = Candidate(
            useSsl: true,
            port: sourceType.defaultPort(useSsl: true),
            origin: .serviceDefaultPort
        )
        let schemeHTTP = Candidate(useSsl: false, port: 80, origin: .schemeDefaultPort)
        let schemeHTTPS = Candidate(useSsl: true, port: 443, origin: .schemeDefaultPort)

        guard hostClass.isPrivate else {
            // 公网名字后面多半站着一台反代,443 命中率最高。
            return [schemeHTTPS, serviceHTTPS, serviceHTTP, schemeHTTP]
        }
        // 内网直连的是服务本体,而且多半没配证书。
        return [serviceHTTP, serviceHTTPS, schemeHTTPS, schemeHTTP]
    }

    private static func nonHTTPCandidate(
        for input: SourceAddressInputPolicy.ParsedEndpointInput,
        sourceType: MusicSourceType,
        manualPort: Int?,
        manualUseSsl: Bool?
    ) -> Candidate {
        let useSsl = input.explicitUseSsl ?? manualUseSsl ?? sourceType.defaultSSL
        if let port = input.explicitPort {
            return Candidate(useSsl: useSsl, port: port, origin: .explicitAddress)
        }
        if let manualPort {
            return Candidate(useSsl: useSsl, port: manualPort, origin: .manualOverride)
        }
        return Candidate(useSsl: useSsl, port: sourceType.defaultPort(useSsl: useSsl), origin: .fixedProtocolPort)
    }

    private static func deduplicated(_ candidates: [Candidate]) -> [Candidate] {
        var seen = Set<String>()
        var result: [Candidate] = []
        for candidate in candidates where seen.insert(candidate.id).inserted {
            result.append(candidate)
            if result.count == maximumCandidateCount { break }
        }
        return result
    }
}
