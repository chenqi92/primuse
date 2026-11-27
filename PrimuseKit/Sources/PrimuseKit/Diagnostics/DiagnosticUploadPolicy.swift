import Foundation

/// 诊断报告直接上传给作者:上限、打包超限时逐级缩小的顺序、服务端回复的归类。
///
/// 这里只放纯决定;打包、签名请求、上传都在 App 里。上传前先向中转要一个上传位
/// (`POST /v1/diagnostics/uploads`),拿到预签名地址后把 zip 原样 PUT 上去,最后
/// 告诉中转传完了(`/complete`),中转回一个给人看的编号。
public enum DiagnosticUpload {
    /// 单次上传的上限,中转按同一个数拒收。
    public static let maximumBytes = 8 * 1_048_576
    /// 中转按 JavaScript 字符串长度(UTF-16 码元)数留言的字数。
    public static let maximumMessageUTF16Count = 2_000
    /// 中转保存多久。界面上的说明照这个数写。
    public static let retentionDays = 30
    /// 每台设备每个 UTC 日最多传几次。
    public static let dailyLimit = 5
    /// 压缩包里那个目录的名字,解压后一眼认得出是什么。
    public static let directoryName = "primuse-diagnostics"
    /// 留言与技术摘要写在这个文件里(邮件正文的同一段文字)。
    public static let feedbackFileName = "feedback.txt"
    public static let logFileName = "primuse_debug.log"

    /// 请求体里的 `contents`:这份包里有哪几类东西。
    public enum Content: String, Sendable, CaseIterable, Codable {
        case reports
        case log
        case screenshots
        case message
    }

    /// 顺序固定(reports、log、screenshots、message),中转与日志里比对起来不乱。
    public static func contents(
        includesReports: Bool,
        includesLog: Bool,
        screenshotCount: Int,
        message: String?
    ) -> [Content] {
        var result: [Content] = []
        if includesReports { result.append(.reports) }
        if includesLog { result.append(.log) }
        if screenshotCount > 0 { result.append(.screenshots) }
        if message.flatMap(clampedMessage) != nil { result.append(.message) }
        return result
    }

    /// 日志带多长的尾巴。日志文本压缩比大约 8~10 倍,两档都放得进 8 MiB 的包;
    /// 正式版少带一些 —— 日志里有歌名、路径这类使用痕迹,够排查就行。用户自己打开了
    /// 诊断模式(就是为了把问题记下来发给作者)时按长的一档带。
    public static func logTailBytes(channel: AppDistributionChannel, diagnosticMode: Bool = false) -> Int {
        channel == .appStore && !diagnosticMode ? 4 * 1_048_576 : 8 * 1_048_576
    }

    /// 截图重新编码的一档:长边像素与 JPEG 质量。
    public struct ImageScale: Equatable, Sendable {
        public let maxPixel: Int
        public let quality: Double

        public init(maxPixel: Int, quality: Double) {
            self.maxPixel = maxPixel
            self.quality = quality
        }
    }

    /// 包超限时截图依次缩到这两档。选图时已经缩到 2048px / 0.8,这里只往下走。
    public static let screenshotSteps: [ImageScale] = [
        ImageScale(maxPixel: 1_600, quality: 0.7),
        ImageScale(maxPixel: 1_200, quality: 0.6),
    ]

    /// 日志尾巴最短缩到多少;再短就看不出前因后果了,不如报超限让人少选几样。
    public static let minimumLogTailBytes = 1_048_576

    /// 打一次包用的参数。`logTailBytes` 为 nil 表示不带日志;`screenshotScale`
    /// 为 nil 表示截图按选图时的样子放进去。
    public struct Attempt: Equatable, Sendable {
        public let logTailBytes: Int?
        public let screenshotScale: ImageScale?

        public init(logTailBytes: Int?, screenshotScale: ImageScale?) {
            self.logTailBytes = logTailBytes
            self.screenshotScale = screenshotScale
        }
    }

    /// 超限时的退让顺序:先缩截图(日志更有用),截图缩到最小还超,再把日志尾巴
    /// 依次减半,减到 `minimumLogTailBytes` 为止。最后一次仍超限就报「太大」。
    /// 没有截图、没有日志时对应的几步不出现,所以不会白打同样的包。
    public static func attempts(logTailBytes: Int?, hasScreenshots: Bool) -> [Attempt] {
        var scale: ImageScale?
        var result = [Attempt(logTailBytes: logTailBytes, screenshotScale: nil)]
        if hasScreenshots {
            for step in screenshotSteps {
                scale = step
                result.append(Attempt(logTailBytes: logTailBytes, screenshotScale: step))
            }
        }
        if var tail = logTailBytes {
            while tail / 2 >= minimumLogTailBytes {
                tail /= 2
                result.append(Attempt(logTailBytes: tail, screenshotScale: scale))
            }
        }
        return result
    }

    /// 去掉首尾空白;空的算没写。超过字数上限时在字符边界上截断,不切开一个 emoji。
    public static func clampedMessage(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.utf16.count > maximumMessageUTF16Count else { return trimmed }
        var result = ""
        var count = 0
        for character in trimmed {
            let width = character.utf16.count
            guard count + width <= maximumMessageUTF16Count else { break }
            result.append(character)
            count += width
        }
        return result
    }

    /// 截过的日志从第一个换行之后开始,不留半行(也不留被切开的多字节字符)。
    /// 头 64 KiB 里都没有换行时原样返回 —— 那不是正常的日志,宁可多带几个字节。
    public static func alignedToLineStart(_ data: Data) -> Data {
        let window = data.prefix(64 * 1_024)
        guard let newline = window.firstIndex(of: 0x0A) else { return data }
        return Data(data[data.index(after: newline)...])
    }

    /// 从已读出的日志尾巴里再取后 `maxBytes` 字节,按整行对齐;恰好切在行首时不再丢一行。
    public static func logSuffix(_ log: Data, maxBytes: Int) -> Data {
        guard log.count > maxBytes else { return log }
        guard maxBytes > 0 else { return Data() }
        let start = log.index(log.endIndex, offsetBy: -maxBytes)
        let tail = Data(log[start...])
        return log[log.index(before: start)] == 0x0A ? tail : alignedToLineStart(tail)
    }

    /// 编号只认字母、数字和连字符,长度有限;中转回来的若不像编号就当回复不对。
    public static func isDisplayableCode(_ code: String) -> Bool {
        !code.isEmpty && code.count <= 32 && code.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || scalar.value == 0x2D
        }
    }

    /// 分享出去的压缩包文件名,按 UTC 时间排得开。
    public static func archiveName(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(directoryName)-\(formatter.string(from: date)).zip"
    }

    /// 次数用完时什么时候能再传:中转给了就用它给的,没给就是下一个 UTC 零点。
    public static func dailyLimitResetDate(retryAt: Date?, now: Date) -> Date {
        if let retryAt, retryAt > now { return retryAt }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let startOfDay = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now.addingTimeInterval(86_400)
    }

    /// 中转回的上传位是否能用:必须是 https 的 PUT,编号像编号,
    /// 要求的 Content-Length 与本地包一致(否则签名对不上,传了也是白传)。
    public static func validatedSlot(
        uploadID: String,
        code: String,
        uploadURL: String,
        method: String,
        headers: [String: String],
        byteCount: Int,
        expiresAt: Date?
    ) -> Slot? {
        guard !uploadID.isEmpty, uploadID.count <= 128,
              isDisplayableCode(code),
              method.uppercased() == "PUT",
              let url = URL(string: uploadURL),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        for (name, value) in headers where name.lowercased() == "content-length" {
            guard Int(value.trimmingCharacters(in: .whitespaces)) == byteCount else { return nil }
        }
        return Slot(uploadID: uploadID, code: code, uploadURL: url, headers: headers, expiresAt: expiresAt)
    }

    /// 一个已经要到的上传位。
    public struct Slot: Equatable, Sendable {
        public let uploadID: String
        public let code: String
        public let uploadURL: URL
        /// PUT 时原样带上的头(签名把它们算了进去)。
        public let headers: [String: String]
        public let expiresAt: Date?

        public init(uploadID: String, code: String, uploadURL: URL, headers: [String: String], expiresAt: Date?) {
            self.uploadID = uploadID
            self.code = code
            self.uploadURL = uploadURL
            self.headers = headers
            self.expiresAt = expiresAt
        }
    }

    /// `POST /v1/diagnostics/uploads` 的请求体。
    public struct Request: Encodable, Equatable, Sendable {
        public var byteCount: Int
        public var appVersion: String
        public var build: String
        /// "iOS" 或 "macOS"(iPad 也报 iOS,中转只认这两个)。
        public var platform: String
        public var osVersion: String
        public var deviceModel: String
        public var contents: [Content]
        public var message: String?

        public init(
            byteCount: Int,
            appVersion: String,
            build: String,
            platform: String,
            osVersion: String,
            deviceModel: String,
            contents: [Content],
            message: String?
        ) {
            self.byteCount = byteCount
            self.appVersion = appVersion
            self.build = build
            self.platform = platform
            self.osVersion = osVersion
            self.deviceModel = deviceModel
            self.contents = contents
            self.message = message.flatMap(DiagnosticUpload.clampedMessage)
        }

        private enum CodingKeys: String, CodingKey {
            case byteCount = "byte_count"
            case appVersion = "app_version"
            case build
            case platform
            case osVersion = "os_version"
            case deviceModel = "device_model"
            case contents
            case message
        }
    }

    /// 界面要分开说明的几种失败。
    public enum Failure: Error, Equatable, Sendable {
        /// 缩到最小仍超过 8 MiB,或中转嫌大。
        case tooLarge
        /// 今天的次数用完了;`retryAt` 是什么时候能再传。
        case dailyLimit(retryAt: Date?)
        /// 中转没开这项、是不认识这条路由的老版本,或这台设备注册不上:改走邮件。
        case unavailable
        /// 连不上网、超时。
        case network
        /// 其他被拒或中途出错;`code` 显示给人看,方便对照。
        case other(code: String)
    }

    /// 中转(或老版本中转)回的错误码归类。认不出的码原样带出去。
    /// 中转自己的 `diagnostics_*` 码按码处理,不看状态码 —— 确认时的 404
    /// `diagnostics_upload_not_found` 说的是这次上传找不到,不是没有这项服务。
    public static func failure(statusCode: Int, code: String, retryAt: Date?) -> Failure {
        switch code {
        case "diagnostics_too_large":
            return .tooLarge
        case "diagnostics_daily_limit":
            return .dailyLimit(retryAt: retryAt)
        case "diagnostics_unavailable", "route_not_found", "unsupported_purpose",
             "unsupported_feature", "feature_not_found":
            return .unavailable
        default:
            break
        }
        if code.hasPrefix("diagnostics_") { return .other(code: code) }
        switch statusCode {
        case 413: return .tooLarge
        case 404: return .unavailable
        default: return .other(code: code)
        }
    }

    // MARK: - 重试

    /// 同一个上传位最多 PUT 几次。申请上传位就占当天的名额(失败的申请也算),
    /// 所以 PUT 失败时在上传位过期前拿同一个地址重试,不重新申请。
    public static let maximumTransferAttempts = 3
    /// 确认最多发几次(确认是幂等的,重复发结果一样)。
    public static let maximumCompletionAttempts = 3
    /// 离上传位过期不到这么久就不再重试:来不及传完,只会白白被拒。
    public static let transferExpiryMargin: TimeInterval = 60

    /// PUT 失败后还能不能用同一个上传位再试。只有断网、超时和存储端 5xx 值得再试;
    /// 403(地址过期、签名不对)之类再试也一样。
    public static func canRetryTransfer(
        after failure: Failure,
        attemptsMade: Int,
        expiresAt: Date?,
        now: Date
    ) -> Bool {
        guard attemptsMade < maximumTransferAttempts else { return false }
        if let expiresAt, expiresAt.timeIntervalSince(now) <= transferExpiryMargin { return false }
        switch failure {
        case .network:
            return true
        case .other(let code):
            return code.hasPrefix("storage_http_5")
        case .tooLarge, .dailyLimit, .unavailable:
            return false
        }
    }

    /// 第 n 次失败后等多久再试:1 秒、3 秒,之后 5 秒封顶。
    public static func retryDelay(afterAttempt attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1: return 1
        case 2: return 3
        default: return 5
        }
    }

    /// 确认失败后怎么补救。
    public enum CompletionRecovery: Equatable, Sendable {
        /// 中转还没在存储里看到这个包:同一个地址重新 PUT,再确认。
        case reupload
        /// 存储暂时异常或网络断了:等一下再确认一次。
        case retry
        /// 补救不了,报给用户(大小不符要重新申请,交给用户再点一次)。
        case none
    }

    public static func completionRecovery(after failure: Failure) -> CompletionRecovery {
        switch failure {
        case .other("diagnostics_upload_missing"):
            return .reupload
        case .other("diagnostics_storage_error"), .network:
            return .retry
        default:
            return .none
        }
    }
}
