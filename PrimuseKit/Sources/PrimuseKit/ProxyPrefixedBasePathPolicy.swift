import Foundation

/// 反向代理把整个服务地址塞进路径里时的基址拼接。
///
/// Cloudflare Worker 之类的加速地址长这样:
/// `https://proxy.example.com/https://nav.example.com:4533`。内层那截必须逐字
/// 送到代理手里 —— `//` 不能折叠成 `/`、`:` 不能转义成 `%3A`、内层端口和子路径
/// 都要留着。而连接器一直在用的「`split(separator: "/")` 逐段
/// `appendPathComponent`」恰好把这三件事全做错:`https://` 折成 `https:/`,
/// 而 `https:` 作为路径第一段时还会被转义成 `https%3A`。
///
/// 所以把「路径前缀怎么接到基址后面」收到这里一处。**普通前缀必须逐字节沿用
/// 原来的结果**:basePath 参与目录快照与歌曲身份
/// (`MusicSourceScopeFingerprint` / `SourceCatalogSnapshotPolicy`),悄悄改写
/// 老用户的配置等于让他们整库重扫。只有值里检测到 `://` 时才走逐字保留的分支。
public enum ProxyPrefixedBasePathPolicy {
    /// 地址字段拆出来的三段。authority 不做 IPv6 规范化 —— 那是
    /// `NetworkHostAuthority` 的事,这里只按字符切分,好让本策略保持
    /// Foundation-only(可以在 Linux 上真跑测试)。
    public struct Address: Equatable, Sendable {
        /// 地址自带的 scheme;为 nil 表示用表单上的 SSL 开关决定。
        public var scheme: String?
        /// `host` 或 `host:port`,原样保留。
        public var authority: String
        /// authority 之后的那截路径,`""` 或以 `/` 开头。未做转义。
        public var pathPrefix: String

        public init(scheme: String?, authority: String, pathPrefix: String) {
            self.scheme = scheme
            self.authority = authority
            self.pathPrefix = pathPrefix
        }
    }

    /// 把用户填的地址切成 scheme / authority / 路径。
    ///
    /// 只认第一个 `://` 和它之后的第一个 `/`:后面还有几个 `://` 是嵌套的内层
    /// 地址,属于路径,不能再当成分隔符。第一个 `://` 前面那截也要真的像个
    /// scheme —— 否则 `proxy.example.com/https://nav:4533` 会被当成
    /// scheme 是 `proxy.example.com/https`,外层主机整个丢掉。
    public static func splitAddress(_ rawValue: String) -> Address {
        var remainder = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var scheme: String?
        if let separator = remainder.range(of: "://"),
           isSchemeToken(remainder[..<separator.lowerBound]) {
            scheme = String(remainder[..<separator.lowerBound]).lowercased()
            remainder = String(remainder[separator.upperBound...])
        }
        guard let slash = remainder.firstIndex(of: "/") else {
            return Address(scheme: scheme, authority: remainder, pathPrefix: "")
        }
        return Address(
            scheme: scheme,
            authority: String(remainder[..<slash]),
            pathPrefix: String(remainder[slash...])
        )
    }

    /// 这段路径里是不是嵌了一个完整 URL(也就是反代前缀)。
    public static func containsEmbeddedURL(_ value: String?) -> Bool {
        value?.contains("://") == true
    }

    /// 规范化一段路径前缀:去掉首尾多余的 `/`,该转义的转义,返回 `""` 或以
    /// `/` 开头的 percent-encoded 串。
    ///
    /// - Parameter continuingExistingPath: 基址上已经有路径了。
    ///   `appendPathComponent` 只在路径为空时转义第一段里的冒号(相对引用的
    ///   首段不能带 `:`),这个开关就是为了逐字节复刻那个差别。
    public static func encodedPathPrefix(
        _ value: String?,
        continuingExistingPath: Bool = false
    ) -> String {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return ""
        }

        guard containsEmbeddedURL(trimmed) == false else {
            // 内层地址原样保留,只剪掉首尾多余的 `/`。
            var body = Substring(trimmed)
            while body.hasPrefix("/") { body.removeFirst() }
            while body.hasSuffix("/") { body.removeLast() }
            guard body.isEmpty == false else { return "" }
            return encodedPath(String(body))
        }

        let segments = trimmed.split(separator: "/").map(String.init)
        guard segments.isEmpty == false else { return "" }
        return segments.enumerated().map { index, segment in
            let encoded = encodedSegment(segment)
            guard index == 0, continuingExistingPath == false else { return encoded }
            return encoded.replacingOccurrences(of: ":", with: "%3A")
        }
        .joined(separator: "/")
        .withLeadingSlash
    }

    /// 在基址后面接一段路径(base path 或 API 路径)。
    ///
    /// 只改 `percentEncodedPath`:`URL.appendPathComponent` 会把已有路径里的
    /// 嵌套前缀一起规范化掉,而 `URLComponents` 的路径 setter 只负责转义,不会
    /// 折叠 `//`,也不会动已有的那截。
    public static func appending(_ path: String?, to base: URL) -> URL {
        guard let path, path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return base
        }
        let existing = components.percentEncodedPath
        let suffix = encodedPathPrefix(path, continuingExistingPath: existing.isEmpty == false)
        guard suffix.isEmpty == false else { return base }

        // 两边都是转义过的合法路径,拼起来仍然合法 —— percentEncodedPath 的
        // setter 遇到非法字符会直接终止进程,不能喂生文本。
        let prefix = existing.hasSuffix("/") ? String(existing.dropLast()) : existing
        components.percentEncodedPath = prefix + suffix
        return components.url ?? base
    }

    /// 用切好的 authority 装出基址:`scheme://authority` + 地址字段自带的路径 +
    /// base path。authority 由调用方(`NetworkHostAuthority` / `NetworkURLBuilder`)
    /// 先规范化好,IPv6 的方括号与 zone 转义不在本策略的职责里。
    public static func baseURL(
        scheme: String,
        authority: String,
        hostPath: String = "",
        basePath: String? = nil
    ) -> URL? {
        guard authority.isEmpty == false,
              let root = URL(string: "\(scheme)://\(authority)") else { return nil }
        return appending(basePath, to: appending(hostPath, to: root))
    }

    /// 地址自带 scheme、没写端口,而且路径里嵌了完整 URL 时,端口属于外层代理。
    /// 表单里那个按源类型预填的默认端口(Navidrome 的 4533 之类)一定是错的,
    /// 改用 scheme 的默认端口。
    ///
    /// authority 里出现冒号就一律不猜(可能是端口,也可能是 IPv6 字面量),
    /// 保持调用方传进来的端口。
    public static func embeddedURLProxyPort(for address: Address) -> Int? {
        guard let scheme = address.scheme,
              containsEmbeddedURL(address.pathPrefix),
              address.authority.contains(":") == false else {
            return nil
        }
        return scheme == "https" || scheme == "wss" || scheme == "ftps" ? 443 : 80
    }

    private static func isSchemeToken(_ value: Substring) -> Bool {
        guard let first = value.first, first.isLetter else { return false }
        return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }

    private static func encodedSegment(_ segment: String) -> String {
        String(encodedPath(segment).dropFirst())
    }

    /// 走 `URLComponents` 的路径 setter 做转义:`/` 与 `:` 原样保留,空格、中文、
    /// `%` 等按 RFC 3986 转义。直接写 `percentEncodedPath` 才是会崩的那条路。
    private static func encodedPath(_ body: String) -> String {
        var components = URLComponents()
        components.path = body.withLeadingSlash
        return components.percentEncodedPath
    }
}

private extension String {
    var withLeadingSlash: String {
        hasPrefix("/") ? self : "/\(self)"
    }
}
