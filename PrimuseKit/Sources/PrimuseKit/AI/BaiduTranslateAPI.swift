import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// 百度翻译开放平台的「通用文本翻译」(#320)：用户自己的 APP ID 与密钥，国内注册方便、每月有免费额度。
///
/// 请求是表单 POST，`sign = MD5(appid + q + salt + 密钥)`，拼签名时 `q` 用原文、不做 URL 编码。`q` 里
/// 每一行单独翻译、按行返回，所以一批歌词用换行连起来发一次；官方要求单次 `q` 不超过 6000 字节。
/// 标准版每秒只收 1 次请求，分批之间由调用方留出间隔。
public enum BaiduTranslateAPI {
    public static let endpoint = URL(string: "https://fanyi-api.baidu.com/api/trans/vip/translate")!
    /// 官方上限 6000 字节；高峰期长请求容易超时，留些余量。
    public static let maximumQueryBytes = 4_500
    /// 标准版 QPS 为 1：两次请求之间至少隔这么久。
    public static let minimumRequestInterval: TimeInterval = 1.1

    public struct Credentials: Codable, Equatable, Sendable {
        public var appID: String
        public var secretKey: String

        public init(appID: String, secretKey: String) {
            self.appID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
            self.secretKey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public var isComplete: Bool { !appID.isEmpty && !secretKey.isEmpty }

        /// 设置页显示用：APP ID 只露头尾几位。
        public var maskedAppID: String {
            guard appID.count > 8 else { return appID }
            return "\(appID.prefix(4))…\(appID.suffix(4))"
        }
    }

    // MARK: Languages

    /// 应用里的语言标识（`zh-Hans`、`en`、`ja`……）对应百度的语种代码；百度没有或代码拿不准的返回 nil。
    /// 只列官方语种表里写明、且各家接入一致的代码。
    public static func languageCode(for identifier: String) -> String? {
        let parts = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
            .split(separator: "-")
            .map(String.init)
        guard let language = parts.first, !language.isEmpty else { return nil }
        if language == "zh" {
            let rest = Set(parts.dropFirst())
            return rest.isDisjoint(with: ["hant", "tw", "hk", "mo"]) ? "zh" : "cht"
        }
        return languageCodes[language]
    }

    /// 源语言：认得的用百度代码，认不得或没检测出来的交给百度自动识别。
    public static func sourceCode(for identifier: String?) -> String {
        identifier.flatMap(languageCode(for:)) ?? "auto"
    }

    /// 百度能不能译成这种语言。
    public static func supportsTarget(_ identifier: String) -> Bool {
        languageCode(for: identifier) != nil
    }

    private static let languageCodes: [String: String] = [
        "yue": "yue",
        "en": "en",
        "ja": "jp",
        "ko": "kor",
        "fr": "fra",
        "es": "spa",
        "th": "th",
        "ar": "ara",
        "ru": "ru",
        "pt": "pt",
        "de": "de",
        "it": "it",
        "el": "el",
        "nl": "nl",
        "pl": "pl",
        "bg": "bul",
        "et": "est",
        "da": "dan",
        "fi": "fin",
        "cs": "cs",
        "ro": "rom",
        "sv": "swe",
        "hu": "hu",
        "vi": "vie",
        "tr": "tr",
        "uk": "ukr",
        "id": "id",
        "in": "id",
        "fa": "per",
        "he": "heb",
        "iw": "heb",
    ]

    // MARK: Request

    /// 一行歌词放进 `q` 前的样子：行内的换行换成空格（换行是分行符），去掉首尾空白。
    public static func queryLine(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按 `q` 的字节上限把行分批，返回每批里各行在 `texts` 中的下标。空行不发；单独一行就超长的
    /// 自己成一批（百度会报错，调用方按失败处理，不影响其他批）。
    public static func batches(_ texts: [String], maximumBytes: Int = maximumQueryBytes) -> [[Int]] {
        var output: [[Int]] = []
        var current: [Int] = []
        var currentBytes = 0
        for (index, text) in texts.enumerated() {
            let line = queryLine(text)
            guard !line.isEmpty else { continue }
            let bytes = line.utf8.count
            let added = current.isEmpty ? bytes : bytes + 1
            if !current.isEmpty, currentBytes + added > maximumBytes {
                output.append(current)
                current = []
                currentBytes = 0
            }
            currentBytes += current.isEmpty ? bytes : bytes + 1
            current.append(index)
        }
        if !current.isEmpty { output.append(current) }
        return output
    }

    /// 一批要发的 `q`：各行用换行连起来。
    public static func query(for lines: [String]) -> String {
        lines.map(queryLine).joined(separator: "\n")
    }

    public static func signingInput(appID: String, query: String, salt: String, secretKey: String) -> String {
        appID + query + salt + secretKey
    }

    #if canImport(CryptoKit)
    /// 32 位小写十六进制的 MD5。
    public static func sign(appID: String, query: String, salt: String, secretKey: String) -> String {
        let input = signingInput(appID: appID, query: query, salt: salt, secretKey: secretKey)
        return Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    #endif

    /// `application/x-www-form-urlencoded` 的请求体。按 RFC 3986 的非保留字符编码，`+` 与空格都编码。
    public static func formBody(
        query: String,
        from: String,
        to: String,
        appID: String,
        salt: String,
        sign: String
    ) -> Data {
        let fields: [(String, String)] = [
            ("q", query),
            ("from", from),
            ("to", to),
            ("appid", appID),
            ("salt", salt),
            ("sign", sign),
        ]
        let body = fields
            .map { "\($0.0)=\(formEncoded($0.1))" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    private static let formAllowed: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()

    static func formEncoded(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? value
    }

    // MARK: Response

    /// 百度返回的错误码归成几类，设置页和歌词页据此说原因。
    public enum ErrorKind: String, Sendable {
        /// 52003：APP ID 不对，或没开通通用文本翻译。
        case unauthorized
        /// 54001：签名不对，多半是密钥填错。
        case signature
        /// 54003：请求太频繁（标准版每秒 1 次）。
        case rateLimited
        /// 54005：长文本请求太频繁，等 3 秒再试。
        case longQueryRateLimited
        /// 54004：账户余额不足（免费额度用完且没充值）。
        case insufficientBalance
        /// 58000：开发者信息里绑定了服务器 IP，手机的 IP 不在里面。
        case clientIPNotAllowed
        /// 58001：不支持译成这种语言。
        case unsupportedLanguage
        /// 58002：服务被关掉了。
        case serviceClosed
        /// 90107：实名认证没通过或还没生效。
        case notVerified
        /// 20003：内容被判有安全风险。
        case contentRejected
        /// 52001 / 52002：超时或百度那边出错，过会儿重试。
        case serverBusy
        case other
    }

    public struct ServiceError: Error, Equatable, Sendable {
        public var code: String
        public var message: String?

        public init(code: String, message: String?) {
            self.code = code
            self.message = message
        }

        public var kind: ErrorKind {
            switch code {
            case "52003": .unauthorized
            case "54001": .signature
            case "54003": .rateLimited
            case "54005": .longQueryRateLimited
            case "54004": .insufficientBalance
            case "58000": .clientIPNotAllowed
            case "58001": .unsupportedLanguage
            case "58002": .serviceClosed
            case "90107": .notVerified
            case "20003": .contentRejected
            case "52001", "52002": .serverBusy
            default: .other
            }
        }

        /// 等一会儿重发可能就好的错误。
        public var isRetryable: Bool {
            switch kind {
            case .rateLimited, .longQueryRateLimited, .serverBusy: true
            default: false
            }
        }
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case invalidResponse
    }

    /// 解析一批的应答，按 `lines` 的顺序给出译文；某行没拿到时为 nil。
    ///
    /// `trans_result` 一行一条。条数对得上就按顺序对应；对不上（百度合并或丢了空白行）时按原文
    /// 对回去，同一句出现多次按先后取。
    public static func decodeResponse(_ data: Data, lines: [String]) throws -> [String?] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.invalidResponse
        }
        if let code = stringValue(object["error_code"]), code != "52000" {
            throw ServiceError(code: code, message: stringValue(object["error_msg"]))
        }
        guard let results = object["trans_result"] as? [[String: Any]] else {
            throw DecodeError.invalidResponse
        }
        let pairs: [(source: String, translated: String)] = results.compactMap { item in
            guard let translated = stringValue(item["dst"]) else { return nil }
            return (stringValue(item["src"]) ?? "", translated)
        }
        let sent = lines.map(queryLine)
        func cleaned(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if pairs.count == sent.count {
            return pairs.map { cleaned($0.translated) }
        }
        var bySource: [String: [String]] = [:]
        for pair in pairs {
            bySource[pair.source.trimmingCharacters(in: .whitespacesAndNewlines), default: []].append(pair.translated)
        }
        return sent.map { line in
            guard var queue = bySource[line], !queue.isEmpty else { return nil }
            let translated = queue.removeFirst()
            bySource[line] = queue
            return cleaned(translated)
        }
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }
}
