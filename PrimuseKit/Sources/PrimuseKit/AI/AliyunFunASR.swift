import Foundation

/// 阿里云百炼(DashScope)的 Fun-ASR 录音文件识别(#314,通义听悟同一类识别):用户自己的 API Key,
/// 整集先传到百炼的临时存储,再提交异步识别任务、轮询、取回带时间的结果。这里只管请求怎么拼、
/// 应答怎么读,真正发请求在 App 里。
///
/// 接口约定(2026-10 按阿里云帮助中心核对):
/// - 临时上传:`GET /api/v1/uploads?action=getPolicy&model=<模型>` 拿上传凭证,按凭证把文件以表单
///   POST 到 `upload_host`,得到 `oss://<key>`;文件 48 小时后自动删除,只能给上传时写的那个模型用。
/// - 提交:`POST /api/v1/services/audio/asr/transcription`,头里要 `X-DashScope-Async: enable`,用
///   `oss://` 地址时还要 `X-DashScope-OssResourceResolve: enable`;`parameters` 不能省(没有设置也传 `{}`)。
/// - 轮询:`GET /api/v1/tasks/<task_id>`。任务 SUCCEEDED 只说明至少一个子任务成功,结果要看
///   `results[].subtask_status`;`transcription_url` 是带签名的 OSS 地址,24 小时内有效。
public enum AliyunFunASR {
    public static let model = "fun-asr"
    /// Fun-ASR 录音文件识别一个文件最长 12 小时、最大 2 GB。
    public static let maximumDuration: TimeInterval = 12 * 60 * 60
    public static let maximumFileBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    /// 识别结果在服务端留 24 小时;提交过的任务在这之前重试只接着等,不再上传、不再计费。
    public static let taskRetention: TimeInterval = 23 * 60 * 60

    /// Fun-ASR 能接的 `language_hints`(只认第一个)。
    public static let supportedLanguageHints: Set<String> = [
        "zh", "en", "ja", "ko", "vi", "th", "id", "ms", "tl", "hi", "ar", "fr", "de", "es", "pt",
        "ru", "it", "nl", "sv", "da", "fi", "no", "el", "pl", "cs", "hu", "ro", "bg", "hr", "sk",
    ]

    // MARK: - 地区与凭据

    /// API Key 分地区,和地区对不上的密钥会被当成无效。
    public enum Region: String, Codable, CaseIterable, Sendable {
        /// 中国内地(北京)。
        case beijing
        /// 国际(新加坡)。
        case singapore

        public static let defaultValue: Region = .beijing

        public var baseURL: URL {
            switch self {
            case .beijing: URL(string: "https://dashscope.aliyuncs.com")!
            case .singapore: URL(string: "https://dashscope-intl.aliyuncs.com")!
            }
        }
    }

    public struct Credentials: Codable, Equatable, Sendable {
        public var apiKey: String
        public var region: Region

        public init(apiKey: String, region: Region) {
            self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.region = region
        }

        /// 百炼的 API Key 形如 `sk-…`;只挡掉明显填错的(空、含空白),别的交给服务端判断。
        public var isUsable: Bool {
            !apiKey.isEmpty && !apiKey.contains(where: { $0.isWhitespace || $0.isNewline })
        }

        /// 设置页显示用:只露头尾几位。
        public var maskedAPIKey: String {
            guard apiKey.count > 10 else { return String(repeating: "•", count: max(4, apiKey.count)) }
            return "\(apiKey.prefix(5))…\(apiKey.suffix(4))"
        }

        private enum CodingKeys: String, CodingKey { case apiKey, region }

        /// 地区认不出(以后加了新地区、老版本读到)时退回北京,不整份丢掉。
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let apiKey = try container.decode(String.self, forKey: .apiKey)
            let region = (try? container.decode(String.self, forKey: .region)).flatMap(Region.init(rawValue:))
            self.init(apiKey: apiKey, region: region ?? .defaultValue)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(apiKey, forKey: .apiKey)
            try container.encode(region.rawValue, forKey: .region)
        }
    }

    /// 发给百炼接口的请求头。
    public static func authorizationHeaders(_ credentials: Credentials) -> [String: String] {
        ["Authorization": "Bearer \(credentials.apiKey)"]
    }

    // MARK: - 临时上传

    public static func uploadPolicyURL(region: Region, model: String = AliyunFunASR.model) -> URL {
        var components = URLComponents(url: region.baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/api/v1/uploads"
        components.queryItems = [
            URLQueryItem(name: "action", value: "getPolicy"),
            URLQueryItem(name: "model", value: model),
        ]
        return components.url!
    }

    /// `getPolicy` 返回的上传凭证。
    public struct UploadPolicy: Equatable, Sendable {
        public var policy: String
        public var signature: String
        public var uploadDirectory: String
        public var uploadHost: URL
        public var accessKeyID: String
        public var objectACL: String?
        public var forbidOverwrite: String?
        /// 这个模型一个文件最多多少 MB;没给时为 nil。
        public var maximumFileSizeMB: Int?
        public var expiresInSeconds: Int?

        public init(
            policy: String,
            signature: String,
            uploadDirectory: String,
            uploadHost: URL,
            accessKeyID: String,
            objectACL: String? = nil,
            forbidOverwrite: String? = nil,
            maximumFileSizeMB: Int? = nil,
            expiresInSeconds: Int? = nil
        ) {
            self.policy = policy
            self.signature = signature
            self.uploadDirectory = uploadDirectory
            self.uploadHost = uploadHost
            self.accessKeyID = accessKeyID
            self.objectACL = objectACL
            self.forbidOverwrite = forbidOverwrite
            self.maximumFileSizeMB = maximumFileSizeMB
            self.expiresInSeconds = expiresInSeconds
        }

        /// 文件超过这个大小就不传了:取凭证给的上限与 Fun-ASR 的 2 GB 里小的那个。
        public var maximumFileBytes: Int64 {
            guard let maximumFileSizeMB, maximumFileSizeMB > 0 else { return AliyunFunASR.maximumFileBytes }
            return min(AliyunFunASR.maximumFileBytes, Int64(maximumFileSizeMB) * 1_024 * 1_024)
        }

        /// 上传后在 OSS 里的对象名:`upload_dir/文件名`。
        public func objectKey(fileName: String) -> String {
            let directory = uploadDirectory.hasSuffix("/") ? String(uploadDirectory.dropLast()) : uploadDirectory
            return directory.isEmpty ? fileName : "\(directory)/\(fileName)"
        }
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case invalidJSON
        case missingField(String)
    }

    public static func decodeUploadPolicy(_ data: Data) throws -> UploadPolicy {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.invalidJSON
        }
        let object = root["data"] as? [String: Any] ?? root
        func string(_ name: String) throws -> String {
            guard let value = (object[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { throw DecodeError.missingField(name) }
            return value
        }
        func optionalString(_ name: String) -> String? {
            if let value = object[name] as? String { return value }
            if let value = object[name] as? Bool { return value ? "true" : "false" }
            return nil
        }
        func optionalInt(_ name: String) -> Int? {
            if let value = object[name] as? Int { return value }
            if let value = object[name] as? Double, value.isFinite { return Int(value) }
            if let value = object[name] as? String { return Int(value) }
            return nil
        }
        let hostString = try string("upload_host")
        guard let host = URL(string: hostString), host.scheme?.lowercased() == "https" || host.scheme?.lowercased() == "http",
              host.host?.isEmpty == false else {
            throw DecodeError.missingField("upload_host")
        }
        return UploadPolicy(
            policy: try string("policy"),
            signature: try string("signature"),
            uploadDirectory: try string("upload_dir"),
            uploadHost: host,
            accessKeyID: try string("oss_access_key_id"),
            objectACL: optionalString("x_oss_object_acl"),
            forbidOverwrite: optionalString("x_oss_forbid_overwrite"),
            maximumFileSizeMB: optionalInt("max_file_size_mb"),
            expiresInSeconds: optionalInt("expire_in_seconds")
        )
    }

    /// 上传表单。文件那一段放在最后(OSS 只认 `file` 之前的字段),所以拆成文件前、文件后两块,
    /// 中间由调用方把文件内容一块块写进去,不用把整集读进内存。
    public struct UploadForm: Equatable, Sendable {
        public var boundary: String
        public var objectKey: String
        public var head: Data
        public var tail: Data

        public var contentType: String { "multipart/form-data; boundary=\(boundary)" }
        /// 识别时交给 Fun-ASR 的地址。
        public var ossURL: String { "oss://\(objectKey)" }
    }

    public static func uploadForm(
        policy: UploadPolicy,
        fileName: String,
        fileContentType: String = "audio/mp4",
        boundary: String
    ) -> UploadForm {
        let key = policy.objectKey(fileName: fileName)
        var fields: [(String, String)] = [
            ("OSSAccessKeyId", policy.accessKeyID),
            ("Signature", policy.signature),
            ("policy", policy.policy),
        ]
        if let acl = policy.objectACL { fields.append(("x-oss-object-acl", acl)) }
        if let forbid = policy.forbidOverwrite { fields.append(("x-oss-forbid-overwrite", forbid)) }
        fields.append(("key", key))
        fields.append(("success_action_status", "200"))
        var head = ""
        for (name, value) in fields {
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
        head += "Content-Type: \(fileContentType)\r\n\r\n"
        return UploadForm(
            boundary: boundary,
            objectKey: key,
            head: Data(head.utf8),
            tail: Data("\r\n--\(boundary)--\r\n".utf8)
        )
    }

    /// OSS 上传失败时回的是 XML `<Error><Code>…</Code><Message>…</Message></Error>`。
    public static func ossErrorCode(_ data: Data) -> String? {
        let text = String(decoding: data.prefix(4_096), as: UTF8.self)
        guard let start = text.range(of: "<Code>"),
              let end = text.range(of: "</Code>", range: start.upperBound..<text.endIndex) else { return nil }
        let code = text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    // MARK: - 提交与轮询

    public static func transcriptionURL(region: Region) -> URL {
        region.baseURL.appendingPathComponent("api/v1/services/audio/asr/transcription")
    }

    public static func taskURL(region: Region, taskID: String) -> URL {
        region.baseURL
            .appendingPathComponent("api/v1/tasks")
            .appendingPathComponent(taskID)
    }

    /// 提交任务的请求头(鉴权之外)。用 `oss://` 临时地址时不带 `X-DashScope-OssResourceResolve` 会直接失败。
    public static let submitHeaders: [String: String] = [
        "Content-Type": "application/json",
        "X-DashScope-Async": "enable",
        "X-DashScope-OssResourceResolve": "enable",
    ]

    public static func submitBody(fileURL: String, languageHint: String?) -> Data {
        var parameters: [String: Any] = [:]
        if let languageHint, supportedLanguageHints.contains(languageHint) {
            parameters["language_hints"] = [languageHint]
        }
        let body: [String: Any] = [
            "model": model,
            "input": ["file_urls": [fileURL]],
            "parameters": parameters,
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// 提交成功回的 task_id。
    public static func decodeSubmittedTaskID(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.invalidJSON
        }
        guard let output = root["output"] as? [String: Any],
              let taskID = (output["task_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !taskID.isEmpty else {
            throw DecodeError.missingField("task_id")
        }
        return taskID
    }

    /// 轮询一次读到的任务状态。
    public enum TaskState: Equatable, Sendable {
        /// 还在排队或在识别。
        case running
        /// 做完了,结果在这个地址。
        case succeeded(transcriptionURL: URL)
        /// 失败了(整个任务或唯一的子任务);`code` 形如 `FILE_DOWNLOAD_FAILED`。
        case failed(code: String?, message: String?)
    }

    public static func decodeTaskState(_ data: Data) throws -> TaskState {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.invalidJSON
        }
        guard let output = root["output"] as? [String: Any],
              let status = (output["task_status"] as? String)?.uppercased() else {
            throw DecodeError.missingField("task_status")
        }
        let results = output["results"] as? [[String: Any]] ?? []
        switch status {
        case "PENDING", "RUNNING":
            return .running
        case "SUCCEEDED":
            if let succeeded = results.first(where: { ($0["subtask_status"] as? String)?.uppercased() == "SUCCEEDED" }),
               let address = succeeded["transcription_url"] as? String,
               let url = URL(string: address) {
                return .succeeded(transcriptionURL: url)
            }
            // 任务算成功、子任务却失败了:原因在子任务里。
            let failed = results.first { ($0["subtask_status"] as? String)?.uppercased() == "FAILED" }
            return .failed(
                code: failed?["code"] as? String ?? output["code"] as? String,
                message: failed?["message"] as? String ?? output["message"] as? String
            )
        default:
            // FAILED / CANCELED / UNKNOWN:原因可能写在任务上,也可能在子任务里。
            let failed = results.first { ($0["code"] as? String) != nil }
            return .failed(
                code: output["code"] as? String ?? failed?["code"] as? String,
                message: output["message"] as? String ?? failed?["message"] as? String
            )
        }
    }

    /// 下一次隔多久再问:头一分钟每 3 秒,之后每 6 秒,十分钟后每 15 秒。
    public static func pollInterval(elapsed: TimeInterval) -> TimeInterval {
        if elapsed < 60 { return 3 }
        if elapsed < 600 { return 6 }
        return 15
    }

    /// 等结果最多等多久:至少 20 分钟,长节目按时长加,封顶 3 小时。到点没结果就停下,重试时接着等同一个任务。
    public static func resultTimeout(forDuration duration: TimeInterval) -> TimeInterval {
        let length = duration.isFinite ? max(0, duration) : 0
        return min(3 * 60 * 60, max(20 * 60, length * 0.5))
    }

    /// 语言提示:只用节目自己写明的语言(播客 RSS 的 `language`)。设备语言、标题里的文字都不可靠,
    /// 提示错了比不给更糟,不给时 Fun-ASR 自己判断。
    public static func languageHint(declaredLanguage: String?) -> String? {
        guard let declaredLanguage else { return nil }
        let base = declaredLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map { $0.lowercased() } ?? ""
        let mapped: String = switch base {
        case "nb", "nn": "no"
        case "fil": "tl"
        case "in": "id"
        case "iw": "he"
        case "zh", "cmn", "yue", "wuu": "zh"
        default: base
        }
        return supportedLanguageHints.contains(mapped) ? mapped : nil
    }

    // MARK: - 识别结果

    /// 识别结果 JSON:`transcripts[].sentences[].words[]`,时间是毫秒,标点单独放在 `punctuation` 里。
    /// 标点并回词里交给文稿排版(它按句末标点断行);某句没有逐词时间时整句当一个词。
    public static func decodeTranscription(_ data: Data) throws -> AIAudioTranscriptionResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodeError.invalidJSON
        }
        guard let transcripts = root["transcripts"] as? [[String: Any]] else {
            throw DecodeError.missingField("transcripts")
        }
        // 单声道只有一条;多条时取声道号最小的那条。
        let transcript = transcripts.min { channel($0) < channel($1) }
        let sentences = transcript?["sentences"] as? [[String: Any]] ?? []
        var words: [AIAudioTranscriptionWord] = []
        var plainLines: [String] = []
        for sentence in sentences {
            let sentenceText = (sentence["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !sentenceText.isEmpty { plainLines.append(sentenceText) }
            let sentenceWords = sentence["words"] as? [[String: Any]] ?? []
            var appended = false
            for word in sentenceWords {
                let text = ((word["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let punctuation = ((word["punctuation"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let combined = text + punctuation
                guard !combined.isEmpty,
                      let start = milliseconds(word["begin_time"]),
                      let end = milliseconds(word["end_time"]) else { continue }
                if text.isEmpty, let last = words.indices.last {
                    // 只有标点的「词」并到前一个词上,别单独占一格。
                    words[last].text += punctuation
                    continue
                }
                words.append(AIAudioTranscriptionWord(text: combined, startTime: start, endTime: end))
                appended = true
            }
            if !appended, !sentenceText.isEmpty,
               let start = milliseconds(sentence["begin_time"]),
               let end = milliseconds(sentence["end_time"]) {
                words.append(AIAudioTranscriptionWord(text: sentenceText, startTime: start, endTime: end))
            }
        }
        let fullText = (transcript?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AIAudioTranscriptionResult(
            transcript: plainLines.isEmpty ? (fullText ?? "") : plainLines.joined(separator: "\n"),
            words: words
        )
    }

    private static func channel(_ transcript: [String: Any]) -> Int {
        (transcript["channel_id"] as? Int) ?? Int.max
    }

    private static func milliseconds(_ value: Any?) -> TimeInterval? {
        let raw: Double?
        switch value {
        case let number as Int: raw = Double(number)
        case let number as Double: raw = number
        case let text as String: raw = Double(text)
        default: raw = nil
        }
        guard let raw, raw.isFinite, raw >= 0 else { return nil }
        return raw / 1_000
    }

    // MARK: - 错误

    /// 百炼接口回的错误:`{"code": "...", "message": "...", "request_id": "..."}`。
    public struct ServiceError: Error, Equatable, Sendable {
        public enum Kind: String, Sendable {
            /// 密钥不对,或者密钥和选的地区对不上。
            case invalidAPIKey
            /// 账号没开通百炼 / 没权限用这个模型。
            case accessDenied
            /// 欠费,或者开了「仅用免费额度」且额度用完了。
            case billing
            case throttled
            /// 内容审核拦下了。
            case contentBlocked
            /// 文件取不到、格式或时长不对。
            case fileRejected
            case server
            case other
        }

        public var kind: Kind
        public var statusCode: Int
        public var code: String?
        public var message: String?

        public init(kind: Kind, statusCode: Int, code: String? = nil, message: String? = nil) {
            self.kind = kind
            self.statusCode = statusCode
            self.code = code
            self.message = message
        }

        public static func parse(statusCode: Int, body: Data) -> ServiceError {
            let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let output = root?["output"] as? [String: Any]
            let code = (root?["code"] as? String) ?? (output?["code"] as? String)
            let message = (root?["message"] as? String) ?? (output?["message"] as? String)
            return ServiceError(
                kind: kind(statusCode: statusCode, code: code),
                statusCode: statusCode,
                code: code,
                message: message.map { String($0.prefix(300)) }
            )
        }

        /// 识别任务本身失败时(轮询读到的 code)。
        public static func task(code: String?, message: String?) -> ServiceError {
            ServiceError(kind: kind(statusCode: 200, code: code), statusCode: 200, code: code, message: message)
        }

        static func kind(statusCode: Int, code: String?) -> Kind {
            let code = code ?? ""
            let lower = code.lowercased()
            if code == "InvalidApiKey" || lower.contains("invalidapikey") { return .invalidAPIKey }
            if code == "Arrearage" || lower.contains("freetieronly") || lower.contains("arrearage") { return .billing }
            if lower.hasPrefix("throttling") { return .throttled }
            if code == "DataInspectionFailed" || lower.contains("datainspection") { return .contentBlocked }
            if lower.hasPrefix("accessdenied") || lower.hasPrefix("model.accessdenied") || code == "ModelNotFound" {
                return .accessDenied
            }
            if lower.contains("file") || lower.hasPrefix("invalidfile") || lower.contains("audio")
                || lower.contains("duration") {
                return .fileRejected
            }
            switch statusCode {
            case 401: return .invalidAPIKey
            case 403: return .accessDenied
            case 429: return .throttled
            case 500...599: return .server
            default: return code == "InternalError" ? .server : .other
            }
        }
    }
}
