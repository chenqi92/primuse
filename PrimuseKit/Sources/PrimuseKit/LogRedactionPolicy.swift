import Foundation

/// 日志脱敏规则。五条正则只在首次使用时编译一次并常驻, 之前每写一行日志都
/// 要重新构造五个 `NSRegularExpression`, 批量元数据回填时这笔开销按行累加。
///
/// 规则的模式、模板与执行顺序与旧实现完全一致。
public enum LogRedactionPolicy {
    /// 1. URL / 查询串里的 key=value。key 后紧跟 = 语义明确, 即便是 code/state/k
    ///    这类短名, 出现在 query 串里也几乎一定是凭证, 故保留全集。
    private static let queryParameterRule = makeRule(
        #"(?i)([?&](?:access_token|refresh_token|api_key|x-plex-token|token|code|state|k|client_secret|password|pwd|pass|sid|_sid|authorization|cookie)=)[^&#\s"')\]]+"#,
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
        #"(?i)\b(access_token|refresh_token|client_secret|api_key|password)\b\s*[:=]\s*[^,\]\s"')}]+"#,
        "$1=<redacted>"
    )

    private static let rules: [(regex: NSRegularExpression, template: String)] = [
        queryParameterRule,
        headerRule,
        bearerRule,
        jsonBodyRule,
        bareCredentialRule,
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
        return redacted
    }

    private static func makeRule(
        _ pattern: String,
        _ template: String
    ) -> (regex: NSRegularExpression, template: String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return (regex, template)
    }
}
