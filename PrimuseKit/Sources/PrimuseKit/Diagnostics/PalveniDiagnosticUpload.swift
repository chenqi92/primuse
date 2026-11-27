import Foundation

/// 诊断报告直接上传到 Palveni(palveni.com,作者的网站和后台)时的纯决定:密钥、安装 ID、
/// 渠道、请求体和回复的归类。
///
/// 流程、字段和错误码与 primuse-ai 的 `/v1/diagnostics/uploads` 相同(见 `DiagnosticUpload`),
/// 只是认证换了:每个 App 一把上传密钥(`Authorization: Bearer pvk_…`),外加一个只为诊断
/// 生成的匿名安装 ID(`X-Installation-Id`),不需要 App Attest。协议写在 palveni.com 仓库的
/// docs/app-integration.md。构建里没带密钥时诊断仍走 primuse-ai。
public enum PalveniDiagnosticUpload {
    public static let baseURL = URL(string: "https://palveni.com/api/v1/")!
    public static let configPath = "diagnostics/config"
    public static let uploadsPath = "diagnostics/uploads"
    public static let completePath = "diagnostics/uploads/complete"

    /// Info.plist 里放密钥的键,值来自构建设置 `PALVENI_UPLOAD_KEY`
    /// (写在不进 Git 的 Config/Secrets.local.xcconfig 里)。
    public static let infoPlistKey = "PrimusePalveniUploadKey"

    // MARK: - 密钥与安装 ID

    /// 构建里带的密钥。没填、没展开(还是 `$(…)`)或不像 Palveni 的密钥都算没有。
    public static func uploadKey(fromInfoValue value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              isUploadKey(text) else { return nil }
        return text
    }

    /// `pvk_<产品>_<32 位字母数字>`,与 Palveni 校验的格式一致(产品段是小写字母、数字和连字符)。
    public static func isUploadKey(_ text: String) -> Bool {
        let parts = text.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "pvk" else { return false }
        let product = parts[1]
        let secret = parts[2]
        guard (1...40).contains(product.count), secret.count == 32 else { return false }
        let productOK = product.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39) || scalar.value == 0x2D
        }
        return productOK && secret.unicodeScalars.allSatisfy(isASCIIAlphanumeric)
    }

    /// 8–128 位的 `A-Z a-z 0-9 . _ : -`,Palveni 按同一规则校验。
    public static func isInstallationID(_ text: String) -> Bool {
        (8...128).contains(text.count) && text.unicodeScalars.allSatisfy { scalar in
            isASCIIAlphanumeric(scalar) || scalar == "." || scalar == "_" || scalar == ":" || scalar == "-"
        }
    }

    /// 存着的安装 ID 合格就沿用,否则换一个新的随机 UUID;`isNew` 为真时调用方要把它存下来。
    public static func installationID(stored: String?, make: () -> String = { UUID().uuidString }) -> (id: String, isNew: Bool) {
        if let stored, isInstallationID(stored) { return (stored, false) }
        return (make(), true)
    }

    // MARK: - 请求

    /// 请求体里的 `channel`:后台按它分开看正式版、TestFlight 和本机构建的报告。
    public static func channel(_ channel: AppDistributionChannel) -> String {
        switch channel {
        case .appStore: "app_store"
        case .testFlight: "testflight"
        case .development: "debug"
        }
    }

    /// 请求体里的 `locale`:第一个首选语言(如 zh-Hans-CN),格式不合 Palveni 的规则就不带。
    public static func locale(preferredLanguages: [String]) -> String? {
        guard let first = preferredLanguages.first else { return nil }
        let parts = first.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first, (2...3).contains(language.count),
              language.unicodeScalars.allSatisfy(isASCIILetter),
              parts.count <= 4,
              parts.dropFirst().allSatisfy({ (2...8).contains($0.count) && $0.unicodeScalars.allSatisfy(isASCIIAlphanumeric) })
        else { return nil }
        return first
    }

    /// `POST diagnostics/uploads` 的请求体:primuse-ai 那份字段,再加上渠道和语言。
    public struct UploadBody: Encodable, Sendable {
        public var request: DiagnosticUpload.Request
        public var channel: String
        public var locale: String?

        public init(request: DiagnosticUpload.Request, channel: AppDistributionChannel, locale: String?) {
            self.request = request
            self.channel = PalveniDiagnosticUpload.channel(channel)
            self.locale = locale
        }

        private enum CodingKeys: String, CodingKey {
            case channel
            case locale
        }

        public func encode(to encoder: Encoder) throws {
            try request.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(channel, forKey: .channel)
            try container.encodeIfPresent(locale, forKey: .locale)
        }
    }

    // MARK: - 回复

    /// `GET diagnostics/config` 说收不收。读不懂算不收。
    public static func isAvailable(configResponse body: Data) -> Bool {
        (payload(body)?["diagnostics_upload"] as? String) == "available"
    }

    /// 要到的上传位;回复不像上传位(地址不是 https、大小对不上…)时为 nil。
    public static func slot(fromUploadResponse body: Data, byteCount: Int) -> DiagnosticUpload.Slot? {
        guard let data = payload(body),
              let uploadID = data["upload_id"] as? String,
              let code = data["code"] as? String,
              let uploadURL = data["upload_url"] as? String else { return nil }
        let method = data["method"] as? String ?? "PUT"
        var headers: [String: String] = [:]
        for (name, value) in data["headers"] as? [String: Any] ?? [:] {
            if let text = value as? String {
                headers[name] = text
            } else if let number = number(value), number.rounded() == number {
                headers[name] = String(Int(number))
            }
        }
        return DiagnosticUpload.validatedSlot(
            uploadID: uploadID,
            code: code,
            uploadURL: uploadURL,
            method: method,
            headers: headers,
            byteCount: byteCount,
            expiresAt: date(data["expires_at"])
        )
    }

    /// `/complete` 回的编号(PM-XXXXXX);不像编号时为 nil。
    public static func code(fromCompleteResponse body: Data) -> String? {
        guard let code = payload(body)?["code"] as? String, DiagnosticUpload.isDisplayableCode(code) else { return nil }
        return code
    }

    /// 出错回复(`{ error: { code, retry_after? }, request_id }`)归类,沿用 `DiagnosticUpload.failure`。
    /// 密钥认不出(被停用或吊销)也算不可用:它不会自己好起来,这时改走邮件。
    public static func failure(statusCode: Int, body: Data, retryAfterHeader: String?, now: Date = Date()) -> DiagnosticUpload.Failure {
        let error = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let detail = error?["error"] as? [String: Any]
        let code = detail?["code"] as? String ?? "http_\(statusCode)"
        if statusCode == 401 || code == "unauthorized" { return .unavailable }
        let retryAt = retryDate(seconds: detail?["retry_after"], header: retryAfterHeader, now: now)
        return DiagnosticUpload.failure(statusCode: statusCode, code: code, retryAt: retryAt)
    }

    /// 什么时候可以再试:回复体里的秒数优先,其次是 Retry-After 头(秒数或 HTTP 日期)。
    public static func retryDate(seconds: Any?, header: String?, now: Date = Date()) -> Date? {
        if let delay = number(seconds), delay.isFinite, delay >= 0 {
            return now.addingTimeInterval(delay)
        }
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
        if let delay = Double(header), delay.isFinite, delay >= 0 { return now.addingTimeInterval(delay) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header)
    }

    /// 成功回复的 `data` 对象。
    private static func payload(_ body: Data) -> [String: Any]? {
        ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["data"] as? [String: Any]
    }

    /// 过期时间:Unix 秒(或毫秒)、ISO 8601 都认,认不出就没有(只作参考)。
    private static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1_000 : seconds)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// JSON 里的数字;各平台的 JSONSerialization 给出的类型不一样(Int、Double 或 NSNumber)。
    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let value as Int: Double(value)
        case let value as Double: value
        case let value as NSNumber: value.doubleValue
        default: nil
        }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    private static func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || (scalar.value >= 0x30 && scalar.value <= 0x39)
    }
}
