import Foundation
import Observation
import PrimuseKit

/// 歌词翻译选了「百度翻译」时用的服务(#320)：用户自己在百度翻译开放平台申请的 APP ID 与密钥。

enum BaiduTranslateError: Error, Equatable, Sendable {
    case notConfigured
    case network
    case invalidResponse
    case service(BaiduTranslateAPI.ServiceError)
}

/// 选了百度翻译却用不上的原因：歌词页提示、设置页说明都用它。
enum BaiduTranslateIssue: Equatable, Sendable {
    case notConfigured
    /// 百度译不成目标语言。
    case unsupportedTarget
    /// 请求出错；附上说给人听的原因。
    case failed(String)

    /// 现在开始翻译会不会被挡住：没填 APP ID 和密钥、百度译不成这种语言，或者刚因为密钥、余额一类
    /// 问题失败过（过一阵再试，免得每首歌都白等一次）。
    @MainActor
    static func current(targetLanguageCode: String) -> BaiduTranslateIssue? {
        let account = BaiduTranslateAccount.shared
        // 凭据可能刚从别的设备经 iCloud 钥匙串同步过来。
        account.reload()
        guard account.isConfigured else { return .notConfigured }
        guard BaiduTranslateAPI.supportsTarget(targetLanguageCode) else { return .unsupportedTarget }
        if let blocked = account.blockingError { return .failed(blocked) }
        return nil
    }

    /// 没用上的原因（不说改用了什么，各端自己接）。
    var reason: String {
        switch self {
        case .notConfigured:
            String(localized: "baidu_translate_reason_not_configured")
        case .unsupportedTarget:
            String(localized: "baidu_translate_error_language")
        case .failed(let reason):
            reason
        }
    }

    /// 手机、Mac 歌词页的一句提示：原因，以及这次改用了系统翻译。
    var notice: String {
        String(format: String(localized: "baidu_translate_notice_system_fallback_format"), reason)
    }
}

/// APP ID 和密钥一起存进钥匙串（和智能服务的 API 密钥同一套存法：开着凭据同步就进 iCloud 钥匙串，
/// Apple TV 读同步过来的那份）。
enum BaiduTranslateCredentialStore {
    static let account = "primuse.lyrics.translation.baidu"

    nonisolated static func load() -> BaiduTranslateAPI.Credentials? {
        guard let stored = KeychainService.getPassword(for: account),
              let credentials = try? JSONDecoder().decode(BaiduTranslateAPI.Credentials.self, from: Data(stored.utf8)),
              credentials.isComplete else { return nil }
        return credentials
    }

    @discardableResult
    nonisolated static func save(_ credentials: BaiduTranslateAPI.Credentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        return KeychainService.setPassword(String(decoding: data, as: UTF8.self), for: account)
    }

    @discardableResult
    nonisolated static func delete() -> Bool {
        KeychainService.deletePassword(for: account)
    }
}

/// 调用通用文本翻译：按字节上限分批，批与批之间隔开（标准版每秒 1 次），限流、超时这类错误等一会儿重发。
actor BaiduTranslateClient {
    static let shared = BaiduTranslateClient()

    struct Outcome: Sendable {
        /// 下标对应传进来的 `texts`。
        var translations: [Int: String]
        /// 中途停下的原因；前面已经翻好的批照样在 `translations` 里。
        var error: BaiduTranslateError?
    }

    private var lastRequestAt: ContinuousClock.Instant?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    /// 一批（已经按 `BaiduTranslateAPI.batches` 切好的）同一源语言的行，按顺序给出译文。
    /// 出错时抛 `BaiduTranslateError`，被取消时抛 `CancellationError`。
    func translate(
        _ lines: [String],
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async throws -> [String?] {
        guard let credentials = BaiduTranslateCredentialStore.load() else {
            throw BaiduTranslateError.notConfigured
        }
        guard let target = BaiduTranslateAPI.languageCode(for: targetLanguageCode) else {
            throw BaiduTranslateError.service(BaiduTranslateAPI.ServiceError(code: "58001", message: nil))
        }
        return try await translateBatch(
            lines,
            from: BaiduTranslateAPI.sourceCode(for: sourceLanguageCode),
            to: target,
            credentials: credentials
        )
    }

    /// 一组行自己分批，全部发完再返回；中途出错时带着已经翻好的部分返回。
    func translateAll(
        _ texts: [String],
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) async -> Outcome {
        var translations: [Int: String] = [:]
        for batch in BaiduTranslateAPI.batches(texts) {
            if Task.isCancelled { break }
            do {
                let results = try await translate(
                    batch.map { texts[$0] },
                    sourceLanguageCode: sourceLanguageCode,
                    targetLanguageCode: targetLanguageCode
                )
                for (offset, translated) in results.enumerated() {
                    if let translated { translations[batch[offset]] = translated }
                }
            } catch let error as BaiduTranslateError {
                return Outcome(translations: translations, error: error)
            } catch {
                break
            }
        }
        return Outcome(translations: translations, error: nil)
    }

    private func translateBatch(
        _ lines: [String],
        from source: String,
        to target: String,
        credentials: BaiduTranslateAPI.Credentials
    ) async throws -> [String?] {
        var attempt = 0
        while true {
            try await waitForTurn()
            do {
                return try await send(lines, from: source, to: target, credentials: credentials)
            } catch BaiduTranslateError.service(let error) where error.isRetryable && attempt < 2 {
                attempt += 1
                let delay: Duration = error.kind == .longQueryRateLimited ? .seconds(3) : .milliseconds(1_500)
                plog("🌐 Baidu translate retry \(attempt) after \(error.code)")
                try await Task.sleep(for: delay)
            }
        }
    }

    /// 标准版每秒只收 1 次，离上一次不到间隔就等一等。
    private func waitForTurn() async throws {
        let interval = Duration.milliseconds(Int(BaiduTranslateAPI.minimumRequestInterval * 1_000))
        if let lastRequestAt {
            let elapsed = ContinuousClock.now - lastRequestAt
            if elapsed < interval { try await Task.sleep(for: interval - elapsed) }
        }
        lastRequestAt = .now
    }

    private func send(
        _ lines: [String],
        from source: String,
        to target: String,
        credentials: BaiduTranslateAPI.Credentials
    ) async throws -> [String?] {
        let query = BaiduTranslateAPI.query(for: lines)
        let salt = String(UInt32.random(in: 10_000...UInt32.max))
        let sign = BaiduTranslateAPI.sign(
            appID: credentials.appID,
            query: query,
            salt: salt,
            secretKey: credentials.secretKey
        )
        var request = URLRequest(url: BaiduTranslateAPI.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = BaiduTranslateAPI.formBody(
            query: query,
            from: source,
            to: target,
            appID: credentials.appID,
            salt: salt,
            sign: sign
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw BaiduTranslateError.network
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BaiduTranslateError.invalidResponse
        }
        do {
            return try BaiduTranslateAPI.decodeResponse(data, lines: lines)
        } catch let error as BaiduTranslateAPI.ServiceError {
            plog("🌐 Baidu translate failed code=\(error.code)")
            throw BaiduTranslateError.service(error)
        } catch {
            throw BaiduTranslateError.invalidResponse
        }
    }
}

/// 设置页和歌词页看的百度翻译状态：填没填、填的是哪个 APP ID、最近一次出错的原因。
@MainActor
@Observable
final class BaiduTranslateAccount {
    static let shared = BaiduTranslateAccount()

    struct TestSample: Identifiable, Equatable {
        let id: Int
        let original: String
        let translated: String
    }

    enum TestOutcome: Equatable {
        case success([TestSample])
        case failure(String)
    }

    /// 填好时是打码后的 APP ID。
    private(set) var maskedAppID: String?
    /// 保存、移除时加一；歌词翻译任务据此重来。
    private(set) var revision: UInt = 0
    private(set) var lastError: String?
    private(set) var lastErrorDate: Date?
    /// 密钥不对、余额不足这类重发也没用的错误之后，这段时间里不再发请求。
    private var blockedUntil: Date?

    var isConfigured: Bool { maskedAppID != nil }

    /// 还在冷却中时是上次的原因。
    var blockingError: String? {
        guard let blockedUntil, blockedUntil > Date() else { return nil }
        return lastError
    }

    private static let blockingDuration: TimeInterval = 10 * 60

    private init() {
        reload()
    }

    /// 回到前台时再读一次：别的设备的凭据可能刚经 iCloud 钥匙串同步过来。
    func reload() {
        let next = BaiduTranslateCredentialStore.load()?.maskedAppID
        if next != maskedAppID {
            maskedAppID = next
            revision &+= 1
        }
    }

    /// 存进钥匙串；两项有一项空着返回 false。
    @discardableResult
    func save(appID: String, secretKey: String) -> Bool {
        let credentials = BaiduTranslateAPI.Credentials(appID: appID, secretKey: secretKey)
        guard credentials.isComplete, BaiduTranslateCredentialStore.save(credentials) else { return false }
        lastError = nil
        lastErrorDate = nil
        blockedUntil = nil
        maskedAppID = credentials.maskedAppID
        revision &+= 1
        return true
    }

    func remove() {
        BaiduTranslateCredentialStore.delete()
        lastError = nil
        lastErrorDate = nil
        blockedUntil = nil
        reload()
        revision &+= 1
    }

    func recordFailure(_ error: BaiduTranslateError) {
        lastError = Self.message(for: error)
        lastErrorDate = Date()
        if Self.blocksFurtherRequests(error) {
            blockedUntil = Date().addingTimeInterval(Self.blockingDuration)
        }
    }

    func recordSuccess() {
        blockedUntil = nil
        guard lastError != nil else { return }
        lastError = nil
        lastErrorDate = nil
    }

    /// 换首歌重发也不会好的错误：要用户去改设置、充值或认证。
    private static func blocksFurtherRequests(_ error: BaiduTranslateError) -> Bool {
        guard case .service(let error) = error else { return false }
        switch error.kind {
        case .unauthorized, .signature, .insufficientBalance, .clientIPNotAllowed, .serviceClosed, .notVerified:
            return true
        case .rateLimited, .longQueryRateLimited, .unsupportedLanguage, .contentRejected, .serverBusy, .other:
            return false
        }
    }

    /// 「测试」：当前歌词里挑最多 3 行发出去（只挑和目标语言不同的）；没有合适的行时用一句英文示例。
    func test(lines: [String], targetLanguageCode: String) async -> TestOutcome {
        let texts = lines.isEmpty ? [Self.testSample] : Array(lines.prefix(3))
        let outcome = await BaiduTranslateClient.shared.translateAll(
            texts,
            sourceLanguageCode: nil,
            targetLanguageCode: BaiduTranslateAPI.supportsTarget(targetLanguageCode) ? targetLanguageCode : "zh-Hans"
        )
        if let error = outcome.error, outcome.translations.isEmpty {
            recordFailure(error)
            return .failure(Self.message(for: error))
        }
        recordSuccess()
        return .success(texts.enumerated().compactMap { index, text in
            outcome.translations[index].map { TestSample(id: index, original: text, translated: $0) }
        })
    }

    private static let testSample = "Every song tells a story."

    static func message(for error: BaiduTranslateError) -> String {
        switch error {
        case .notConfigured:
            return String(localized: "baidu_translate_error_not_configured")
        case .network:
            return String(localized: "baidu_translate_error_network")
        case .invalidResponse:
            return String(localized: "baidu_translate_error_response")
        case .service(let error):
            let reason: String = switch error.kind {
            case .unauthorized:
                String(localized: "baidu_translate_error_unauthorized")
            case .signature:
                String(localized: "baidu_translate_error_signature")
            case .rateLimited, .longQueryRateLimited:
                String(localized: "baidu_translate_error_rate_limited")
            case .insufficientBalance:
                String(localized: "baidu_translate_error_balance")
            case .clientIPNotAllowed:
                String(localized: "baidu_translate_error_ip")
            case .unsupportedLanguage:
                String(localized: "baidu_translate_error_language")
            case .serviceClosed:
                String(localized: "baidu_translate_error_closed")
            case .notVerified:
                String(localized: "baidu_translate_error_verification")
            case .contentRejected:
                String(localized: "baidu_translate_error_content")
            case .serverBusy:
                String(localized: "baidu_translate_error_busy")
            case .other:
                String(format: String(localized: "baidu_translate_error_code_format"), error.code)
            }
            return reason
        }
    }
}
