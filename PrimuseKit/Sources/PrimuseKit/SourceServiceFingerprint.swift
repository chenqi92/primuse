import Foundation

/// 「这个地址后面确实是我要找的那个服务吗」——纯判定,不发请求。
///
/// 端口候选逐个试的时候,"能连上"远远不够:反代的默认站点、路由器的管理页、
/// 另一台机器上的别的服务,都会好端端地回一个 200。所以每个类型给一条
/// **不需要登录、不带任何凭据**的探测请求,再按状态码 + 响应头 + 响应体前缀判断
/// 对方是不是它。凭据只在真正登录时才发,探测阶段一个字节都不带。
///
/// 全 Foundation:请求与响应都用自己的值类型描述,不碰 `URLRequest` /
/// `HTTPURLResponse`(它们在 Linux 上属于 FoundationNetworking),这样判定逻辑
/// 能在本机被真实测试覆盖。执行在 `SourceEndpointResolver`。
public enum SourceServiceFingerprint {

    /// 一条免登录探测请求,路径相对服务根(反代前缀由执行方接上)。
    public struct ProbeRequest: Sendable, Equatable {
        public var method: String
        public var path: String
        public var queryItems: [URLQueryItem]

        public init(method: String = "GET", path: String, queryItems: [URLQueryItem] = []) {
            self.method = method
            self.path = path
            self.queryItems = queryItems
        }
    }

    /// 探测拿回来的东西。正文只取前几 KB —— 判定只看开头的字段名,
    /// 而一个搞错了的候选可能是个几 MB 的页面。
    public struct ProbeResponse: Sendable, Equatable {
        public var statusCode: Int
        public var headerFields: [String: String]
        public var bodyPrefix: String

        public init(statusCode: Int, headerFields: [String: String] = [:], bodyPrefix: String = "") {
            self.statusCode = statusCode
            self.headerFields = headerFields
            self.bodyPrefix = bodyPrefix
        }

        /// HTTP 头名大小写不敏感。
        public func headerValue(_ name: String) -> String? {
            let wanted = name.lowercased()
            return headerFields.first { $0.key.lowercased() == wanted }?.value
        }
    }

    /// 这个候选为什么算不通。都是结构化的,界面把它翻成人话。
    public enum UnreachableReason: String, Sendable, Equatable {
        case timedOut
        /// 主机名解析不出来。单列出来是因为它对用户的含义完全不同:不是端口或
        /// 协议选错了,而是地址本身写错了,换哪个候选都没用。
        case hostNotFound
        /// TLS 握手失败(多半是把 https 打到了明文端口)。
        case tlsFailure
        /// 明文请求打到了 TLS 端口:对方用 HTTP 400 抱怨了一句。
        case cleartextOnTLSPort
        case connectionFailed
        case cancelled
        /// 前面已经有更高优先级的候选确认了,这条没再试。
        case notAttempted
    }

    public enum Verdict: Sendable, Equatable {
        /// 认出来了,确实是这个服务。
        case confirmed
        /// 有 HTTP 响应,但认不出是谁。
        case responded(statusCode: Int)
        case unreachable(UnreachableReason)

        public var isConfirmed: Bool { self == .confirmed }

        public var isResponded: Bool {
            if case .responded = self { return true }
            return false
        }
    }

    /// 正文读到这里就够判定了,也够界面显示一行原因。
    public static let maximumInspectedBodyBytes = 4096

    /// Subsonic 协议参数,与 `SubsonicStreamResolver` 用的保持一致 —— 换了客户端名
    /// 或协议版本,服务端日志里就对不上同一个客户端了。
    private static let subsonicAPIVersion = "1.16.1"
    private static let airsonicAPIVersion = "1.15.0"
    private static let subsonicClientName = "Primuse"

    /// 该类型的免登录探测请求;没有可用指纹(非 HTTP 类型、云盘)时为 nil。
    public static func probeRequest(for sourceType: MusicSourceType) -> ProbeRequest? {
        guard sourceType.usesHTTPTransport else { return nil }

        switch sourceType {
        case .jellyfin, .emby:
            // 两者同源,`/System/Info/Public` 的字段名一模一样,所以互认:
            // 用户把 Jellyfin 当 Emby 添加时,端口仍然能定下来。
            return ProbeRequest(path: "/System/Info/Public")
        case .plex:
            return ProbeRequest(path: "/identity")
        case .subsonic, .navidrome, .airsonic, .gonic:
            return ProbeRequest(
                path: "/rest/ping.view",
                queryItems: [
                    URLQueryItem(name: "f", value: "json"),
                    URLQueryItem(
                        name: "v",
                        value: sourceType == .airsonic ? airsonicAPIVersion : subsonicAPIVersion
                    ),
                    URLQueryItem(name: "c", value: subsonicClientName)
                ]
            )
        case .synology:
            return ProbeRequest(
                path: "/webapi/query.cgi",
                queryItems: [
                    URLQueryItem(name: "api", value: "SYNO.API.Info"),
                    URLQueryItem(name: "version", value: "1"),
                    URLQueryItem(name: "method", value: "query"),
                    URLQueryItem(name: "query", value: "SYNO.API.Auth")
                ]
            )
        case .synologyAudioStation:
            // 同一个免登录的接口发现,但只问 Audio Station 自己的接口:套件没装
            // 或没启用时 DSM 不报它,这样端口能定下来,又不会把「DSM 在但没有
            // Audio Station」误判成确认。
            return ProbeRequest(
                path: "/webapi/query.cgi",
                queryItems: [
                    URLQueryItem(name: "api", value: "SYNO.API.Info"),
                    URLQueryItem(name: "version", value: "1"),
                    URLQueryItem(name: "method", value: "query"),
                    URLQueryItem(name: "query", value: "SYNO.AudioStation.Info")
                ]
            )
        case .webdav:
            // OPTIONS 打在路径前缀上,因为 DAV 头是挂在那个集合上的,
            // 站点根目录未必开了 DAV。
            return ProbeRequest(method: "OPTIONS", path: "/")
        default:
            // 其余 HTTP 类型没有公开的免登录握手,只能判"有没有人应答"。
            return ProbeRequest(path: "/")
        }
    }

    public static func evaluate(_ response: ProbeResponse, sourceType: MusicSourceType) -> Verdict {
        if let reason = transportMismatchReason(in: response) {
            return .unreachable(reason)
        }

        let body = response.bodyPrefix
        switch sourceType {
        case .jellyfin, .emby:
            // 实测 demo.jellyfin.org:200 + {"LocalAddress":…,"ServerName":"Stable
            // Demo","Version":"12.1.0","ProductName":"Jellyfin Server","Id":…}。
            // 只认一个 ServerName 太松 —— 任何 JSON 配置页都可能有;所以再要一个
            // 同源字段。
            if response.statusCode == 200,
               body.contains("\"ServerName\""),
               body.contains("\"Version\"") || body.contains("\"Id\"") {
                return .confirmed
            }
        case .plex:
            // `/identity` 默认回 XML,带 Accept 时回 JSON;两边都有
            // machineIdentifier,所以按子串认。
            if response.statusCode == 200, body.contains("machineIdentifier") {
                return .confirmed
            }
        case .subsonic, .navidrome, .airsonic, .gonic:
            // 不带凭据时 status 一定是 failed(实测 demo.navidrome.org 回
            // {"subsonic-response":{"status":"failed",…,"error":{"code":10,
            // "message":"missing parameter: 'u'"}}}),但信封在就说明对方讲
            // Subsonic。
            if body.contains("subsonic-response") { return .confirmed }
        case .synology:
            if response.statusCode == 200, body.contains("SYNO.API.Auth") { return .confirmed }
        case .synologyAudioStation:
            if response.statusCode == 200, body.contains("SYNO.AudioStation.Info") { return .confirmed }
        case .webdav:
            if response.headerValue("DAV") != nil { return .confirmed }
        default:
            break
        }

        return .responded(statusCode: response.statusCode)
    }

    /// 明文请求撞上 TLS 端口。三家主流服务端各自回一句不同的话,但都是 400,
    /// 而且都会把原因写进正文 —— 这不是"服务不在",是"协议挑错了",所以按该
    /// 候选不可达处理,让下一个候选去试 https。
    private static let cleartextOnTLSPortMarkers = [
        "plain http request was sent to https port",      // nginx
        "client sent an http request to an https server", // Go net/http
        "this combination of host and port requires tls"  // Caddy
    ]

    private static func transportMismatchReason(in response: ProbeResponse) -> UnreachableReason? {
        guard response.statusCode == 400 else { return nil }
        let body = response.bodyPrefix.lowercased()
        guard cleartextOnTLSPortMarkers.contains(where: { body.contains($0) }) else { return nil }
        return .cleartextOnTLSPort
    }
}

/// 探测加载器唯一该抛的错误。刻意不用 `URLError`:那是 Linux 上的
/// FoundationNetworking 类型,让判定与选择逻辑没法在本机跑测试。生产实现负责把
/// 平台错误翻译成这里的原因码。
public struct SourceServiceProbeFailure: Error, Sendable, Equatable {
    public var reason: SourceServiceFingerprint.UnreachableReason

    public init(_ reason: SourceServiceFingerprint.UnreachableReason) {
        self.reason = reason
    }
}
