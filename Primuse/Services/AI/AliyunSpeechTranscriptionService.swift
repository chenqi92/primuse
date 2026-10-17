import Foundation
import Observation
import PrimuseKit

/// 阿里云百炼的 API Key 与地区存在钥匙串里(和别的服务密钥同一套存法:开着凭据同步就进 iCloud 钥匙串)。
enum AliyunSpeechCredentialStore {
    static let account = "primuse.transcript.aliyunBailian"

    nonisolated static func load() -> AliyunFunASR.Credentials? {
        guard let stored = KeychainService.getPassword(for: account),
              let credentials = try? JSONDecoder().decode(AliyunFunASR.Credentials.self, from: Data(stored.utf8)),
              credentials.isUsable else { return nil }
        return credentials
    }

    @discardableResult
    nonisolated static func save(_ credentials: AliyunFunASR.Credentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else { return false }
        return KeychainService.setPassword(String(decoding: data, as: UTF8.self), for: account)
    }

    @discardableResult
    nonisolated static func delete() -> Bool {
        KeychainService.deletePassword(for: account)
    }
}

enum AliyunSpeechTranscriptionError: Error, Equatable {
    case notConfigured
    case network
    case invalidResponse
    /// 接口拒绝了这次请求(密钥、权限、欠费、限流……)。
    case service(AliyunFunASR.ServiceError)
    /// 识别任务提交上去了,但服务端没做成。
    case taskFailed(AliyunFunASR.ServiceError)
    /// 传到 OSS 被拒;`code` 是 OSS 的错误码(如 `EntityTooLarge`)。
    case uploadRejected(code: String?, statusCode: Int)
    case fileTooLarge
    case timedOut
}

/// 调百炼:要上传凭证、把文件传到临时存储、提交 Fun-ASR 任务、轮询、取回结果。
actor AliyunSpeechTranscriptionClient {
    static let shared = AliyunSpeechTranscriptionClient()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        // 一小时的节目转成 22 kHz 单声道约 20 MB,慢网络上也要传得完。
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// 轮询时连续这么多次连不上才算失败;偶尔断一下网接着等。
    private static let tolerablePollFailures = 5

    /// 「测试连接」:要一次上传凭证。要得到说明密钥和地区对得上;不上传任何东西、不产生费用。
    func validate(_ credentials: AliyunFunASR.Credentials) async throws {
        _ = try await uploadPolicy(credentials)
    }

    /// 把一个文件传到百炼的临时存储,回给 Fun-ASR 用的 `oss://` 地址。`progress` 是 0…1。
    func upload(
        fileURL: URL,
        credentials: AliyunFunASR.Credentials,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let policy = try await uploadPolicy(credentials)
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw AliyunSpeechTranscriptionError.invalidResponse }
        guard size <= policy.maximumFileBytes else { throw AliyunSpeechTranscriptionError.fileTooLarge }
        let fileExtension = fileURL.pathExtension.isEmpty ? "m4a" : fileURL.pathExtension.lowercased()
        let form = AliyunFunASR.uploadForm(
            policy: policy,
            fileName: "\(UUID().uuidString.lowercased()).\(fileExtension)",
            fileContentType: "audio/mp4",
            boundary: "PrimuseBoundary-\(UUID().uuidString)"
        )
        let bodyURL = try Self.writeBody(form: form, fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: policy.uploadHost)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let delegate = AliyunUploadProgressDelegate(progress: progress)
        let result: (Data, URLResponse)
        do {
            result = try await session.upload(for: request, fromFile: bodyURL, delegate: delegate)
        } catch {
            throw Self.transportError(error)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw AliyunSpeechTranscriptionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let code = AliyunFunASR.ossErrorCode(result.0)
            plog("[transcript] aliyun upload rejected status=\(http.statusCode) code=\(code ?? "-")")
            throw AliyunSpeechTranscriptionError.uploadRejected(code: code, statusCode: http.statusCode)
        }
        return form.ossURL
    }

    /// 提交识别任务,回 task_id。
    func submit(
        ossURL: String,
        languageHint: String?,
        credentials: AliyunFunASR.Credentials
    ) async throws -> String {
        var request = URLRequest(url: AliyunFunASR.transcriptionURL(region: credentials.region))
        request.httpMethod = "POST"
        Self.apply(AliyunFunASR.authorizationHeaders(credentials), to: &request)
        Self.apply(AliyunFunASR.submitHeaders, to: &request)
        request.httpBody = AliyunFunASR.submitBody(fileURL: ossURL, languageHint: languageHint)
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw AliyunSpeechTranscriptionError.service(Self.serviceError(response.statusCode, data, "submit"))
        }
        do {
            return try AliyunFunASR.decodeSubmittedTaskID(data)
        } catch {
            throw AliyunSpeechTranscriptionError.invalidResponse
        }
    }

    /// 等任务做完,取回识别结果。等到 `timeout` 还没好就抛 `.timedOut`(任务还在服务端,之后可以接着等)。
    func result(
        taskID: String,
        credentials: AliyunFunASR.Credentials,
        timeout: TimeInterval
    ) async throws -> AIAudioTranscriptionResult {
        let started = Date()
        var consecutiveFailures = 0
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: AliyunFunASR.taskURL(region: credentials.region, taskID: taskID))
            request.httpMethod = "GET"
            Self.apply(AliyunFunASR.authorizationHeaders(credentials), to: &request)
            do {
                let (data, response) = try await send(request)
                switch response.statusCode {
                case 200..<300:
                    consecutiveFailures = 0
                    let state: AliyunFunASR.TaskState
                    do {
                        state = try AliyunFunASR.decodeTaskState(data)
                    } catch {
                        throw AliyunSpeechTranscriptionError.invalidResponse
                    }
                    switch state {
                    case .running:
                        break
                    case .succeeded(let transcriptionURL):
                        return try await fetchTranscription(transcriptionURL)
                    case .failed(let code, let message):
                        plog("[transcript] aliyun task failed code=\(code ?? "-")")
                        throw AliyunSpeechTranscriptionError.taskFailed(.task(code: code, message: message))
                    }
                case 429, 500...599:
                    // 限流或服务端一时出错:任务还在,接着等。
                    consecutiveFailures += 1
                    if consecutiveFailures > Self.tolerablePollFailures {
                        throw AliyunSpeechTranscriptionError.service(Self.serviceError(response.statusCode, data, "poll"))
                    }
                default:
                    throw AliyunSpeechTranscriptionError.service(Self.serviceError(response.statusCode, data, "poll"))
                }
            } catch AliyunSpeechTranscriptionError.network {
                consecutiveFailures += 1
                if consecutiveFailures > Self.tolerablePollFailures { throw AliyunSpeechTranscriptionError.network }
            }
            let elapsed = Date().timeIntervalSince(started)
            guard elapsed < timeout else { throw AliyunSpeechTranscriptionError.timedOut }
            try await Task.sleep(for: .seconds(AliyunFunASR.pollInterval(elapsed: elapsed)))
        }
    }

    // MARK: Requests

    private func uploadPolicy(_ credentials: AliyunFunASR.Credentials) async throws -> AliyunFunASR.UploadPolicy {
        var request = URLRequest(url: AliyunFunASR.uploadPolicyURL(region: credentials.region))
        request.httpMethod = "GET"
        Self.apply(AliyunFunASR.authorizationHeaders(credentials), to: &request)
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw AliyunSpeechTranscriptionError.service(Self.serviceError(response.statusCode, data, "policy"))
        }
        do {
            return try AliyunFunASR.decodeUploadPolicy(data)
        } catch {
            throw AliyunSpeechTranscriptionError.invalidResponse
        }
    }

    /// 结果地址是带签名的 OSS 地址:不能带百炼的鉴权头(OSS 会把它当成自己的签名去校验)。
    private func fetchTranscription(_ url: URL) async throws -> AIAudioTranscriptionResult {
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else {
            throw AliyunSpeechTranscriptionError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else {
            plog("[transcript] aliyun result download failed status=\(response.statusCode)")
            throw AliyunSpeechTranscriptionError.invalidResponse
        }
        do {
            return try AliyunFunASR.decodeTranscription(data)
        } catch {
            throw AliyunSpeechTranscriptionError.invalidResponse
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw Self.transportError(error)
        }
        guard let http = result.1 as? HTTPURLResponse else { throw AliyunSpeechTranscriptionError.invalidResponse }
        return (result.0, http)
    }

    private static func transportError(_ error: Error) -> Error {
        if error is CancellationError { return CancellationError() }
        if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
        return AliyunSpeechTranscriptionError.network
    }

    private static func serviceError(_ statusCode: Int, _ data: Data, _ step: String) -> AliyunFunASR.ServiceError {
        let error = AliyunFunASR.ServiceError.parse(statusCode: statusCode, body: data)
        plog("[transcript] aliyun \(step) failed status=\(statusCode) code=\(error.code ?? "-") kind=\(error.kind.rawValue)")
        return error
    }

    private static func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    }

    /// 表单的头、文件、尾拼成一个临时文件再传,不把整集读进内存。
    private nonisolated static func writeBody(form: AliyunFunASR.UploadForm, fileURL: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Primuse-TranscriptGeneration", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("upload")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AliyunSpeechTranscriptionError.invalidResponse
        }
        do {
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            try output.write(contentsOf: form.head)
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: form.tail)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }
}

/// 上传进度:每前进 1% 或传完时才报,免得主线程被刷屏。URLSession 在自己的队列上回调,
/// 所以整个类不隔离到主线程。
private nonisolated final class AliyunUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var lastReported = -1.0

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, max(0, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
        let shouldReport: Bool = lock.withLock {
            guard fraction >= 1 || fraction - lastReported >= 0.01 else { return false }
            lastReported = fraction
            return true
        }
        if shouldReport { progress(fraction) }
    }
}

/// 设置页看的阿里云百炼状态:存没存密钥、哪个地区、最近一次出错的原因。
@MainActor
@Observable
final class AliyunSpeechTranscriptionAccount {
    static let shared = AliyunSpeechTranscriptionAccount()

    struct Summary: Equatable {
        let maskedAPIKey: String
        let region: AliyunFunASR.Region
    }

    enum TestOutcome: Equatable {
        case success
        case failure(String)
    }

    private(set) var summary: Summary?
    private(set) var lastError: String?
    private(set) var lastErrorDate: Date?

    var isConfigured: Bool { summary != nil }

    private init() {
        reload()
    }

    func reload() {
        let next = AliyunSpeechCredentialStore.load().map {
            Summary(maskedAPIKey: $0.maskedAPIKey, region: $0.region)
        }
        if next != summary { summary = next }
    }

    /// 保存并测试。`apiKey` 留空时沿用已经存的密钥,只改地区。
    func save(apiKey: String, region: AliyunFunASR.Region) async -> TestOutcome {
        let draft = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = draft.isEmpty ? AliyunSpeechCredentialStore.load()?.apiKey : draft else {
            return .failure(String(localized: "transcript_generation_aliyun_not_configured"))
        }
        let credentials = AliyunFunASR.Credentials(apiKey: key, region: region)
        guard credentials.isUsable else {
            return .failure(String(localized: "aliyun_speech_error_key_format"))
        }
        guard AliyunSpeechCredentialStore.save(credentials) else {
            return .failure(String(localized: "aliyun_speech_error_save"))
        }
        lastError = nil
        lastErrorDate = nil
        reload()
        return await test()
    }

    func test() async -> TestOutcome {
        guard let credentials = AliyunSpeechCredentialStore.load() else {
            return .failure(String(localized: "transcript_generation_aliyun_not_configured"))
        }
        do {
            try await AliyunSpeechTranscriptionClient.shared.validate(credentials)
            recordSuccess()
            return .success
        } catch is CancellationError {
            return .failure(String(localized: "aliyun_speech_error_network"))
        } catch {
            recordFailure(error)
            return .failure(Self.message(for: error))
        }
    }

    func remove() {
        AliyunSpeechCredentialStore.delete()
        lastError = nil
        lastErrorDate = nil
        reload()
    }

    func recordFailure(_ error: Error) {
        lastError = Self.message(for: error)
        lastErrorDate = Date()
    }

    func recordSuccess() {
        lastError = nil
        lastErrorDate = nil
    }

    static func message(for error: Error) -> String {
        guard let error = error as? AliyunSpeechTranscriptionError else {
            return String(localized: "aliyun_speech_error_network")
        }
        switch error {
        case .notConfigured:
            return String(localized: "transcript_generation_aliyun_not_configured")
        case .network:
            return String(localized: "aliyun_speech_error_network")
        case .invalidResponse:
            return String(localized: "aliyun_speech_error_response")
        case .fileTooLarge:
            return String(localized: "transcript_generation_aliyun_failure_too_long")
        case .timedOut:
            return String(localized: "transcript_generation_aliyun_failure_timed_out")
        case .uploadRejected(let code, let statusCode):
            if code == "EntityTooLarge" {
                return String(localized: "transcript_generation_aliyun_failure_too_long")
            }
            return String(
                format: String(localized: "aliyun_speech_error_upload_format"),
                code ?? "HTTP \(statusCode)"
            )
        case .service(let service), .taskFailed(let service):
            let reason: String = switch service.kind {
            case .invalidAPIKey: String(localized: "transcript_generation_aliyun_failure_key")
            case .accessDenied: String(localized: "transcript_generation_aliyun_failure_access")
            case .billing: String(localized: "transcript_generation_aliyun_failure_billing")
            case .throttled: String(localized: "transcript_generation_aliyun_failure_throttled")
            case .contentBlocked: String(localized: "transcript_generation_aliyun_failure_content")
            case .fileRejected: String(localized: "transcript_generation_aliyun_failure_file")
            case .server: String(localized: "aliyun_speech_error_server")
            case .other: String(localized: "transcript_generation_aliyun_failure_generic")
            }
            guard let code = service.code, !code.isEmpty else { return reason }
            return "\(reason) (\(code))"
        }
    }
}

extension AliyunFunASR.Region {
    var localizedTitle: String {
        switch self {
        case .beijing: String(localized: "aliyun_speech_region_beijing")
        case .singapore: String(localized: "aliyun_speech_region_singapore")
        }
    }
}
