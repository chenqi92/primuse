import Foundation

/// 正则实例常驻复用，避免批量日志反复编译脱敏规则。
public enum LogRedactionPolicy {
    /// 1. URL / 查询串里的 key=value。key 后紧跟 = 语义明确, 即便是 code/state/k
    ///    这类短名, 出现在 query 串里也几乎一定是凭证, 故保留全集。
    private static let queryParameterRule = makeRule(
        #"(?i)([?&](?:access_token|refresh_token|api_key|x-plex-token|token|code|state|k|client_secret|password|pwd|pass|sid|_sid|authorization|cookie|u|t|s|p)=)[^&#\s"')\]]+"#,
        "$1<redacted>"
    )
    /// 2. HTTP 头 Authorization / Cookie
    private static let headerRule = makeRule(
        #"(?i)\b(Authorization|Cookie)\s*[:=]\s*[^,\]\n]+"#,
        "$1=<redacted>"
    )
    /// 3. Bearer token
    private static let bearerRule = makeRule(
        #"(?i)\b(Bearer)\s+[A-Za-z0-9._~+/=-]+"#,
        "$1 <redacted>"
    )
    /// 4. JSON 体里的 "key":"value"(覆盖 OAuth 错误体等带引号的结构化日志)。
    private static let jsonBodyRule = makeRule(
        #"(?i)("(?:access_token|refresh_token|client_secret|api_key|code|password|token)"\s*:\s*)"[^"]*""#,
        "$1\"<redacted>\""
    )
    /// 5. 裸 key=value / key: value。仅限不会与正常日志词冲突的明确凭证名,
    ///    不再包含 code/state/pass/token/k —— 它们在普通日志里太常见(如
    ///    "state: playing"、"scan code: 42"), 会误删正常内容。URL 与 JSON
    ///    形态分别由规则 1、4 兜底。
    private static let bareCredentialRule = makeRule(
        #"(?i)\b(access_token|refresh_token|client_secret|api_key|password|passwd|pwd|passphrase|secret|otp|otp_code|otpcode)\b\s*[:=]\s*[^,\]\s"')}]+"#,
        "$1=<redacted>"
    )

    /// 6. 家目录里的用户名 —— `/Users/chenqi/…` 一露就是真名。
    ///    `/Users/Shared` 是系统目录,不是人。
    private static let homeDirectoryRule = makeRule(
        #"(?i)(/(?:Users|home)/)(?!Shared(?:/|$))[^/\s"'<>]{1,64}"#,
        "$1<user>"
    )
    /// 7. 沙箱容器 id。每次安装都不同,认不出人,但它把日志和某一台设备上的
    ///    某一次安装钉在一起,而且对排查毫无用处。
    private static let appContainerRule = makeRule(
        #"(/(?:private/)?var/mobile/Containers/(?:Data|Shared)/[A-Za-z]+/)[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}"#,
        "$1<app>"
    )

    private static let rules: [(regex: NSRegularExpression, template: String)] = [
        queryParameterRule,
        headerRule,
        bearerRule,
        jsonBodyRule,
        bareCredentialRule,
        homeDirectoryRule,
        appContainerRule,
    ].compactMap { $0 }

    public static func redact(_ message: String) -> String {
        var redacted = message
        for rule in rules {
            let range = NSRange(redacted.startIndex..<redacted.endIndex, in: redacted)
            redacted = rule.regex.stringByReplacingMatches(
                in: redacted,
                range: range,
                withTemplate: rule.template
            )
        }
        let hints = hints(of: redacted)
        for rule in identityRules where rule.gate(hints) {
            redacted = apply(rule, to: redacted)
        }
        return redacted
    }

    // MARK: - 身份:地址、账号、邮箱

    /// 把一个值折成 6 位十六进制的短标记。
    ///
    /// **不是密码学哈希**,只为「同一个值在几万行日志里前后能对上」而存在:
    /// 同一台 NAS 的地址在不同会话、不同设备上折出同一个标记,所以"它换地址了"
    /// 和"这两条说的是同一台"仍然看得出来。没有加盐也正是为了这个跨设备的可比性
    /// —— 代价是私网地址那种取值空间极小的值,拿字典撞得出来(而私网地址本身
    /// 不可路由,泄露它的代价接近零);公网域名的取值空间撞不动。
    ///
    /// 不用 Swift 的 `Hasher`(每个进程随机种子,跨会话对不上),也不引 CryptoKit
    /// (这份策略要能在没有它的环境里被测试覆盖)。FNV-1a,取低 24 位。
    public static func digest(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%06x", UInt32(truncatingIfNeeded: hash) & 0x00ff_ffff)
    }

    /// 主机名 / IP 在日志里的替身。回环不折 —— 它不指向任何人,而"连的是本机"
    /// 本身是要看的信息。
    public static func hostTag(_ rawHost: String) -> String {
        let host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        guard host.isEmpty == false else { return "<host:empty>" }
        if host == "localhost" || host == "::1" || host.hasPrefix("127.") { return "<loopback>" }
        return isIPLiteral(host) ? "<ip:\(digest(host))>" : "<host:\(digest(host))>"
    }

    /// 明确表示"没有"的值不折 —— 折出来的标记只会让人以为真有一个账号。
    private static let emptyValues: Set<String> = ["nil", "null", "(null)", "none", "-", "empty", "(empty)"]

    /// 自家 scheme 的"主机"其实是源 id 之类的自家标识:折了反而与同一行
    /// `source=` 的前 8 位对不上,而它本身不是个人信息。
    private static let appInternalSchemes: Set<String> = [
        "primuse", "primuse-stream", "file", "data", "asset", "assets-library", "shortcuts",
        // `musicKit://artwork/library/…` 的"主机"是个写死的字面量,不是地址。
        "musickit"
    ]

    /// authority 里的主机:方括号 IPv6,或者不含端口的普通主机名 / IPv4。
    private static let hostPattern = #"(\[[0-9A-Fa-f:.]{2,45}\]|[A-Za-z0-9._\-]{1,253})"#

    /// 单遍扫描得到的"这行里有没有可能藏着地址"。脱敏对每一行都要跑一次,
    /// 而绝大多数行里连 `://`、`@`、"数字后面跟点" 都没有 —— 一次按字节的扫描
    /// 比多跑几趟正则便宜一个数量级。
    private struct Hints {
        var hasSchemeSeparator = false
        var hasAt = false
        var hasDigitDot = false
    }

    private static func hints(of message: String) -> Hints {
        var hints = Hints()
        var previous: UInt8 = 0
        var beforePrevious: UInt8 = 0
        for byte in message.utf8 {
            switch byte {
            case UInt8(ascii: "@"):
                hints.hasAt = true
            case UInt8(ascii: "/"):
                if previous == UInt8(ascii: "/"), beforePrevious == UInt8(ascii: ":") {
                    hints.hasSchemeSeparator = true
                }
            case UInt8(ascii: "."):
                if previous >= UInt8(ascii: "0"), previous <= UInt8(ascii: "9") {
                    hints.hasDigitDot = true
                }
            default:
                break
            }
            beforePrevious = previous
            previous = byte
        }
        return hints
    }

    private struct IdentityRule {
        let regex: NSRegularExpression
        /// 扫描结果够不够触发这条规则 —— 不够就连正则都不用跑。替换只会写出
        /// `<…>` 形状的标记,不会新引入 `://` 或 `@`,所以一次扫描管到底。
        let gate: @Sendable (Hints) -> Bool
        /// 返回整段匹配的替换文本;nil 表示这一处不动。
        let replace: @Sendable (NSTextCheckingResult, String) -> String?
    }

    /// 8. URL 的 authority:`user:password@` 整段扔掉,主机折成标记。协议、端口、
    ///    路径留着 —— 走的是 http 还是 https、打的哪个端口、哪个接口,是排查的
    ///    主要线索,而这几样由 App 自己拼,不含用户信息。
    private static let urlAuthorityRule = makeIdentityRule(
        #"(?i)\b([a-z][a-z0-9+.\-]{1,15})://(?:[^/@\s"'<>]{1,160}@)?"# + hostPattern,
        gate: { $0.hasSchemeSeparator }
    ) { match, message in
        guard let scheme = group(1, of: match, in: message),
              let host = group(2, of: match, in: message),
              appInternalSchemes.contains(scheme.lowercased()) == false else { return nil }
        return "\(scheme)://\(hostTag(host))"
    }

    /// 9. `host=` / `Host:` / `server=` 这类字段后面跟的主机。端口不在捕获里,
    ///    所以 `host=10.0.0.2:5001` 只折地址、留端口。
    private static let hostFieldRule = makeIdentityRule(
        #"(?i)\b(host|hostname|server|endpoint|peer|domain|subject|issuer|commonName)(\s*[:=]\s*"?)"#
            + hostPattern
    ) { match, message in
        guard isInsideTag(match, in: message) == false,
              let key = group(1, of: match, in: message),
              let separator = group(2, of: match, in: message),
              let host = group(3, of: match, in: message),
              emptyValues.contains(host.lowercased()) == false,
              looksLikeErrorDomain(host) == false else { return nil }
        return "\(key)\(separator)\(hostTag(host))"
    }

    /// `Error Domain=NSURLErrorDomain Code=-1001` 里的 `Domain=` 不是主机,那是
    /// 错误域 —— 而它恰好是排查时最要看的字段之一。系统错误域的名字形状固定。
    private static func looksLikeErrorDomain(_ value: String) -> Bool {
        value.contains("ErrorDomain")
    }

    /// 10. 裸 IPv4。不由我们拼的字符串(`NSErrorFailingURLStringKey`、系统错误
    ///     描述)里还会再露一次,而四段点分数字在这个 App 的日志里只可能是地址。
    private static let ipv4Rule = makeIdentityRule(
        #"(?<![\d.])(\d{1,3}(?:\.\d{1,3}){3})(?![\d.])"#,
        gate: { $0.hasDigitDot }
    ) { match, message in
        guard let address = group(1, of: match, in: message),
              isIPv4Literal(address) else { return nil }
        return hostTag(address)
    }

    /// 11. 账号名与云盘 uid。**不折成标记,直接丢掉** —— 账号和口令一样不该被
    ///     记录,连"同一个账号"这种关联性都不必留;需要知道的只是"这里有没有
    ///     账号",而那件事 `accountSet=true` 这类写法本身就说清了。
    ///     现在的调用点(审过一遍)只打布尔和长度,这条是给以后的调用点兜底。
    private static let accountFieldRule = makeIdentityRule(
        #"(?i)\b(account|username|user|login|nickname|uid)(\s*[:=]\s*"?)([^\s"',;)\]}]{1,128})"#
    ) { match, message in
        guard isInsideTag(match, in: message) == false,
              let key = group(1, of: match, in: message),
              let separator = group(2, of: match, in: message),
              let value = group(3, of: match, in: message),
              emptyValues.contains(value.lowercased()) == false else { return nil }
        return "\(key)\(separator)<redacted>"
    }

    /// 12. 邮箱。
    private static let emailRule = makeIdentityRule(
        #"[A-Za-z0-9._%+\-]{1,64}@[A-Za-z0-9.\-]{1,253}\.[A-Za-z]{2,24}"#,
        gate: { $0.hasAt }
    ) { match, message in
        guard let value = group(0, of: match, in: message) else { return nil }
        return "<mail:\(digest(value))>"
    }

    private static let identityRules: [IdentityRule] = [
        urlAuthorityRule,
        hostFieldRule,
        ipv4Rule,
        accountFieldRule,
        emailRule,
    ].compactMap { $0 }

    /// 从后往前替换,前面那些匹配的下标才不会被挪动。
    private static func apply(_ rule: IdentityRule, to message: String) -> String {
        let text = message as NSString
        let matches = rule.regex.matches(
            in: message,
            range: NSRange(location: 0, length: text.length)
        )
        guard matches.isEmpty == false else { return message }
        var result = message
        for match in matches.reversed() {
            guard let replacement = rule.replace(match, message),
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// 已经折过一次的 `<host:…>` / `<id:…>` 不能再折一次,否则同一条消息脱敏
    /// 两遍会得到不同结果(日志器对同一行只脱敏一次,但重复脱敏必须是幂等的)。
    private static func isInsideTag(_ match: NSTextCheckingResult, in message: String) -> Bool {
        let start = match.range.location
        guard start > 0, let range = Range(NSRange(location: start - 1, length: 1), in: message) else {
            return false
        }
        return message[range] == "<"
    }

    private static func group(_ index: Int, of match: NSTextCheckingResult, in message: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: message) else { return nil }
        return String(message[swiftRange])
    }

    private static func isIPv4Literal(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard part.isEmpty == false, part.count <= 3, let octet = Int(part) else { return false }
            return (0...255).contains(octet)
        }
    }

    private static func isIPLiteral(_ value: String) -> Bool {
        isIPv4Literal(value) || (value.contains(":") && value.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." })
    }

    private static func makeIdentityRule(
        _ pattern: String,
        gate: @escaping @Sendable (Hints) -> Bool = { _ in true },
        _ replace: @escaping @Sendable (NSTextCheckingResult, String) -> String?
    ) -> IdentityRule? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return IdentityRule(regex: regex, gate: gate, replace: replace)
    }

    private static func makeRule(
        _ pattern: String,
        _ template: String
    ) -> (regex: NSRegularExpression, template: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (regex, template)
    }
}
