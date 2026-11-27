import Foundation
import Testing
@testable import PrimuseKit

@Suite("Alibaba Cloud Fun-ASR requests (#314)")
struct AliyunFunASRRequestTests {
    private let credentials = AliyunFunASR.Credentials(apiKey: "  sk-test1234567890abcd \n", region: .beijing)

    @Test("Credentials are trimmed, masked, and survive an unknown region")
    func credentialHandling() throws {
        #expect(credentials.apiKey == "sk-test1234567890abcd")
        #expect(credentials.isUsable)
        #expect(credentials.maskedAPIKey == "sk-te…abcd")
        #expect(!AliyunFunASR.Credentials(apiKey: "sk-a b", region: .beijing).isUsable)
        #expect(!AliyunFunASR.Credentials(apiKey: "   ", region: .beijing).isUsable)

        let encoded = try JSONEncoder().encode(AliyunFunASR.Credentials(apiKey: "sk-x", region: .singapore))
        #expect(try JSONDecoder().decode(AliyunFunASR.Credentials.self, from: encoded).region == .singapore)
        let future = Data(#"{"apiKey":"sk-x","region":"virginia"}"#.utf8)
        let decoded = try JSONDecoder().decode(AliyunFunASR.Credentials.self, from: future)
        #expect(decoded.region == .beijing)
        #expect(decoded.apiKey == "sk-x")
    }

    @Test("Each region talks to its own DashScope host")
    func endpoints() {
        #expect(AliyunFunASR.uploadPolicyURL(region: .beijing).absoluteString
            == "https://dashscope.aliyuncs.com/api/v1/uploads?action=getPolicy&model=fun-asr")
        #expect(AliyunFunASR.transcriptionURL(region: .singapore).absoluteString
            == "https://dashscope-intl.aliyuncs.com/api/v1/services/audio/asr/transcription")
        #expect(AliyunFunASR.taskURL(region: .beijing, taskID: "8d47c5c3-2f2b-4c2e-a1b9").absoluteString
            == "https://dashscope.aliyuncs.com/api/v1/tasks/8d47c5c3-2f2b-4c2e-a1b9")
        #expect(AliyunFunASR.authorizationHeaders(credentials) == ["Authorization": "Bearer sk-test1234567890abcd"])
        #expect(AliyunFunASR.submitHeaders["X-DashScope-Async"] == "enable")
        #expect(AliyunFunASR.submitHeaders["X-DashScope-OssResourceResolve"] == "enable")
    }

    @Test("The submit body always carries parameters, with a hint only when it is supported")
    func submitBody() throws {
        func object(_ hint: String?) throws -> [String: Any] {
            let data = AliyunFunASR.submitBody(fileURL: "oss://dashscope-instant/a/b.m4a", languageHint: hint)
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let plain = try object(nil)
        #expect(plain["model"] as? String == "fun-asr")
        let input = try #require(plain["input"] as? [String: Any])
        #expect(input["file_urls"] as? [String] == ["oss://dashscope-instant/a/b.m4a"])
        let parameters = try #require(plain["parameters"] as? [String: Any])
        #expect(parameters.isEmpty)

        let hinted = try #require(try object("en")["parameters"] as? [String: Any])
        #expect(hinted["language_hints"] as? [String] == ["en"])
        let unsupported = try #require(try object("xx")["parameters"] as? [String: Any])
        #expect(unsupported["language_hints"] == nil)
    }

    @Test("Only a language the show declares becomes a hint")
    func languageHint() {
        #expect(AliyunFunASR.languageHint(declaredLanguage: "en-US") == "en")
        #expect(AliyunFunASR.languageHint(declaredLanguage: "zh_CN") == "zh")
        #expect(AliyunFunASR.languageHint(declaredLanguage: "zh-Hant-TW") == "zh")
        #expect(AliyunFunASR.languageHint(declaredLanguage: "nb") == "no")
        #expect(AliyunFunASR.languageHint(declaredLanguage: "fil") == "tl")
        #expect(AliyunFunASR.languageHint(declaredLanguage: "sw") == nil)
        #expect(AliyunFunASR.languageHint(declaredLanguage: nil) == nil)
        #expect(AliyunFunASR.languageHint(declaredLanguage: "  ") == nil)
    }

    @Test("Polling slows down over time and the wait scales with length")
    func pacing() {
        #expect(AliyunFunASR.pollInterval(elapsed: 5) == 3)
        #expect(AliyunFunASR.pollInterval(elapsed: 120) == 6)
        #expect(AliyunFunASR.pollInterval(elapsed: 900) == 15)
        #expect(AliyunFunASR.resultTimeout(forDuration: 600) == 20 * 60)
        #expect(AliyunFunASR.resultTimeout(forDuration: 4 * 3_600) == 2 * 3_600)
        #expect(AliyunFunASR.resultTimeout(forDuration: 12 * 3_600) == 3 * 3_600)
        #expect(AliyunFunASR.resultTimeout(forDuration: .nan) == 20 * 60)
    }
}

@Suite("Alibaba Cloud temporary upload (#314)")
struct AliyunFunASRUploadTests {
    private let policyJSON = Data("""
    {"request_id":"r1","data":{"policy":"eyJleHBpcmF0aW9uIjoi","signature":"g5K=","upload_dir":"dashscope-instant/abc/2026-10-17/xyz",
    "upload_host":"https://dashscope-file-mgr.oss-cn-beijing.aliyuncs.com","expire_in_seconds":300,"max_file_size_mb":100,
    "capacity_limit_mb":999999,"oss_access_key_id":"LTAIxx","x_oss_object_acl":"private","x_oss_forbid_overwrite":"true"}}
    """.utf8)

    @Test("The upload credential decodes, and its size cap never exceeds Fun-ASR's 2 GB")
    func decodePolicy() throws {
        let policy = try AliyunFunASR.decodeUploadPolicy(policyJSON)
        #expect(policy.uploadHost.absoluteString == "https://dashscope-file-mgr.oss-cn-beijing.aliyuncs.com")
        #expect(policy.accessKeyID == "LTAIxx")
        #expect(policy.objectACL == "private")
        #expect(policy.forbidOverwrite == "true")
        #expect(policy.maximumFileSizeMB == 100)
        #expect(policy.maximumFileBytes == 100 * 1_024 * 1_024)
        #expect(policy.objectKey(fileName: "a.m4a") == "dashscope-instant/abc/2026-10-17/xyz/a.m4a")

        var uncapped = policy
        uncapped.maximumFileSizeMB = nil
        #expect(uncapped.maximumFileBytes == AliyunFunASR.maximumFileBytes)
        uncapped.maximumFileSizeMB = 10_000
        #expect(uncapped.maximumFileBytes == AliyunFunASR.maximumFileBytes)
    }

    @Test("A credential without an upload host is rejected")
    func missingHost() {
        let broken = Data(#"{"data":{"policy":"p","signature":"s","upload_dir":"d","oss_access_key_id":"k"}}"#.utf8)
        #expect(throws: AliyunFunASR.DecodeError.missingField("upload_host")) {
            try AliyunFunASR.decodeUploadPolicy(broken)
        }
        #expect(throws: AliyunFunASR.DecodeError.invalidJSON) {
            try AliyunFunASR.decodeUploadPolicy(Data("<html>".utf8))
        }
    }

    @Test("The form lists the policy fields before the file, and the file part last")
    func form() throws {
        let policy = try AliyunFunASR.decodeUploadPolicy(policyJSON)
        let form = AliyunFunASR.uploadForm(policy: policy, fileName: "ep.m4a", boundary: "B")
        #expect(form.contentType == "multipart/form-data; boundary=B")
        #expect(form.ossURL == "oss://dashscope-instant/abc/2026-10-17/xyz/ep.m4a")
        let head = String(decoding: form.head, as: UTF8.self)
        let order = ["OSSAccessKeyId", "Signature", "policy", "x-oss-object-acl", "x-oss-forbid-overwrite",
                     "key", "success_action_status", "file"]
        var cursor = head.startIndex
        for name in order {
            let marker = "name=\"\(name)\""
            let range = try #require(head.range(of: marker, range: cursor..<head.endIndex), "\(name) missing or out of order")
            cursor = range.upperBound
        }
        #expect(head.contains("\r\n\r\ndashscope-instant/abc/2026-10-17/xyz/ep.m4a\r\n"))
        #expect(head.contains("filename=\"ep.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n"))
        #expect(head.hasSuffix("\r\n\r\n"))
        #expect(String(decoding: form.tail, as: UTF8.self) == "\r\n--B--\r\n")
    }

    @Test("OSS errors are read from the XML body")
    func ossError() {
        let xml = Data("<?xml version=\"1.0\"?><Error><Code>EntityTooLarge</Code><Message>too big</Message></Error>".utf8)
        #expect(AliyunFunASR.ossErrorCode(xml) == "EntityTooLarge")
        #expect(AliyunFunASR.ossErrorCode(Data()) == nil)
    }
}

@Suite("Alibaba Cloud task polling and results (#314)")
struct AliyunFunASRResultTests {
    @Test("Submitting returns the task id")
    func submitted() throws {
        let body = Data(#"{"output":{"task_status":"PENDING","task_id":"t-1"},"request_id":"r"}"#.utf8)
        #expect(try AliyunFunASR.decodeSubmittedTaskID(body) == "t-1")
        #expect(throws: AliyunFunASR.DecodeError.missingField("task_id")) {
            try AliyunFunASR.decodeSubmittedTaskID(Data(#"{"output":{}}"#.utf8))
        }
    }

    @Test("Pending and running tasks keep polling")
    func running() throws {
        for status in ["PENDING", "RUNNING", "running"] {
            let body = Data(#"{"output":{"task_id":"t","task_status":"\#(status)"}}"#.utf8)
            #expect(try AliyunFunASR.decodeTaskState(body) == .running)
        }
    }

    @Test("A succeeded task hands back the subtask's result address")
    func succeeded() throws {
        let body = Data("""
        {"output":{"task_id":"t","task_status":"SUCCEEDED","results":[{"file_url":"oss://a",
        "transcription_url":"https://dashscope-result.oss-cn-beijing.aliyuncs.com/x.json?Expires=1&Signature=s",
        "subtask_status":"SUCCEEDED"}],"task_metrics":{"TOTAL":1,"SUCCEEDED":1,"FAILED":0}}}
        """.utf8)
        let state = try AliyunFunASR.decodeTaskState(body)
        #expect(state == .succeeded(transcriptionURL: URL(string:
            "https://dashscope-result.oss-cn-beijing.aliyuncs.com/x.json?Expires=1&Signature=s")!))
    }

    @Test("A task marked succeeded with a failed subtask is a failure with the subtask's reason")
    func succeededButSubtaskFailed() throws {
        let body = Data("""
        {"output":{"task_id":"t","task_status":"SUCCEEDED","results":[{"file_url":"oss://a",
        "code":"FILE_DOWNLOAD_FAILED","message":"FILE_DOWNLOAD_FAILED","subtask_status":"FAILED"}],
        "task_metrics":{"TOTAL":1,"SUCCEEDED":0,"FAILED":1}}}
        """.utf8)
        #expect(try AliyunFunASR.decodeTaskState(body)
            == .failed(code: "FILE_DOWNLOAD_FAILED", message: "FILE_DOWNLOAD_FAILED"))
    }

    @Test("A failed task carries its own code")
    func failed() throws {
        let body = Data(#"{"output":{"task_id":"t","task_status":"FAILED","code":"InvalidFile.Format","message":"bad"}}"#.utf8)
        #expect(try AliyunFunASR.decodeTaskState(body) == .failed(code: "InvalidFile.Format", message: "bad"))
        #expect(throws: AliyunFunASR.DecodeError.missingField("task_status")) {
            try AliyunFunASR.decodeTaskState(Data(#"{"output":{}}"#.utf8))
        }
    }

    @Test("Words keep their punctuation and turn milliseconds into seconds")
    func transcription() throws {
        let body = Data("""
        {"file_url":"oss://a","properties":{"audio_format":"aac","channels":[0],"original_duration_in_milliseconds":5200},
        "transcripts":[{"channel_id":0,"content_duration_in_milliseconds":4100,"text":"Hello world. 你好，世界。",
        "sentences":[
          {"begin_time":100,"end_time":1500,"text":"Hello world.","sentence_id":1,
           "words":[{"begin_time":100,"end_time":600,"text":"Hello ","punctuation":""},
                    {"begin_time":650,"end_time":1500,"text":"world","punctuation":"."}]},
          {"begin_time":2000,"end_time":4100,"text":"你好，世界。","sentence_id":2,
           "words":[{"begin_time":2000,"end_time":2600,"text":"你好","punctuation":"，"},
                    {"begin_time":2700,"end_time":3300,"text":"世界","punctuation":"。"}]}
        ]}]}
        """.utf8)
        let result = try AliyunFunASR.decodeTranscription(body)
        #expect(result.words.map(\.text) == ["Hello", "world.", "你好，", "世界。"])
        #expect(result.words.first?.startTime == 0.1)
        #expect(result.words.first?.endTime == 0.6)
        #expect(result.words.last?.startTime == 2.7)
        #expect(result.words.last?.endTime == 3.3)
        #expect(result.transcript == "Hello world.\n你好，世界。")
    }

    @Test("A sentence without word timings becomes one timed word; a stray punctuation joins the word before")
    func sentenceFallback() throws {
        let body = Data("""
        {"transcripts":[{"channel_id":0,"sentences":[
          {"begin_time":0,"end_time":900,"text":"整句没有逐词时间","words":[]},
          {"begin_time":1000,"end_time":2000,"text":"好的！","words":[
            {"begin_time":1000,"end_time":1800,"text":"好的","punctuation":""},
            {"begin_time":1800,"end_time":2000,"text":"","punctuation":"！"}]}
        ]}]}
        """.utf8)
        let result = try AliyunFunASR.decodeTranscription(body)
        #expect(result.words.map(\.text) == ["整句没有逐词时间", "好的！"])
        #expect(result.words[0].startTime == 0)
        #expect(result.words[0].endTime == 0.9)
    }

    @Test("Several channels: the lowest channel wins")
    func channels() throws {
        let body = Data("""
        {"transcripts":[
          {"channel_id":1,"sentences":[{"begin_time":0,"end_time":500,"text":"right","words":[]}]},
          {"channel_id":0,"sentences":[{"begin_time":0,"end_time":500,"text":"left","words":[]}]}
        ]}
        """.utf8)
        #expect(try AliyunFunASR.decodeTranscription(body).words.map(\.text) == ["left"])
        #expect(throws: AliyunFunASR.DecodeError.missingField("transcripts")) {
            try AliyunFunASR.decodeTranscription(Data("{}".utf8))
        }
    }
}

@Suite("Alibaba Cloud error classification (#314)")
struct AliyunFunASRErrorTests {
    private func kind(_ status: Int, _ body: String) -> AliyunFunASR.ServiceError.Kind {
        AliyunFunASR.ServiceError.parse(statusCode: status, body: Data(body.utf8)).kind
    }

    @Test("DashScope codes map to what the listener can do about them")
    func codes() {
        #expect(kind(401, #"{"code":"InvalidApiKey","message":"Invalid API-key provided."}"#) == .invalidAPIKey)
        #expect(kind(403, #"{"code":"AccessDenied","message":"Access denied."}"#) == .accessDenied)
        #expect(kind(403, #"{"code":"Model.AccessDenied","message":"Model access denied."}"#) == .accessDenied)
        #expect(kind(403, #"{"code":"AccessDenied.Unpurchased","message":"..."}"#) == .accessDenied)
        #expect(kind(400, #"{"code":"Arrearage","message":"Access denied, please make sure your account is in good standing."}"#) == .billing)
        #expect(kind(403, #"{"code":"AllocationQuota.FreeTierOnly","message":"The free tier of the model has been exhausted."}"#) == .billing)
        #expect(kind(429, #"{"code":"Throttling.RateQuota","message":"You have exceeded your request limit."}"#) == .throttled)
        #expect(kind(400, #"{"code":"DataInspectionFailed","message":"Input or output data may contain inappropriate content."}"#) == .contentBlocked)
        #expect(kind(500, #"{"code":"InternalError","message":"An internal error has occured"}"#) == .server)
        #expect(kind(400, #"{"code":"InvalidParameter","message":"x"}"#) == .other)
    }

    @Test("Without a code the HTTP status decides")
    func statusOnly() {
        #expect(kind(401, "") == .invalidAPIKey)
        #expect(kind(403, "<html>") == .accessDenied)
        #expect(kind(429, "") == .throttled)
        #expect(kind(503, "") == .server)
        #expect(kind(400, "") == .other)
    }

    @Test("Task failures about the file are file problems, and the code and message are kept")
    func taskFailures() {
        let error = AliyunFunASR.ServiceError.task(code: "FILE_DOWNLOAD_FAILED", message: "FILE_DOWNLOAD_FAILED")
        #expect(error.kind == .fileRejected)
        #expect(error.code == "FILE_DOWNLOAD_FAILED")
        #expect(AliyunFunASR.ServiceError.task(code: "InvalidFile.Duration", message: nil).kind == .fileRejected)
        #expect(AliyunFunASR.ServiceError.task(code: nil, message: nil).kind == .other)
        let parsed = AliyunFunASR.ServiceError.parse(
            statusCode: 400,
            body: Data(#"{"code":"Arrearage","message":"pay","request_id":"r"}"#.utf8)
        )
        #expect(parsed.code == "Arrearage")
        #expect(parsed.message == "pay")
        #expect(parsed.statusCode == 400)
    }
}
