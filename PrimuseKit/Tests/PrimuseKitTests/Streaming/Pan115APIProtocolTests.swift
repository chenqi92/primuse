import Foundation
import Testing
@testable import PrimuseKit

@Suite("115 open platform protocol")
struct Pan115APIProtocolTests {

    // MARK: - 业务包络

    @Test("state 为真即成功,空的 error / errno 不算失败")
    func successEnvelopeIgnoresEmptyErrorFields() {
        let body = #"{"state":true,"code":0,"message":"","error":"","errno":0,"data":[]}"#
        #expect(Pan115APIProtocol.envelope(of: Data(body.utf8)) == .success)
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":1,"data":{}}"#.utf8)) == .success)
        // 没有 state 的老写法:code 缺省或为 0 是成功,非 0 是失败。
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"code":0,"data":[]}"#.utf8)) == .success)
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"code":20018,"message":"参数错误"}"#.utf8))
                == .failure(code: 20018, message: "参数错误"))
        #expect(Pan115APIProtocol.envelope(of: Data("<html></html>".utf8)) == nil)
    }

    @Test("access_token 失效的业务码触发刷新")
    func authorizationCodesAskForRefresh() {
        for code in [99, 401, 40_140_123, 40_140_124, 40_140_125, 40_140_126] {
            let body = #"{"state":false,"code":\#(code),"message":"access_token 无效","data":[]}"#
            #expect(Pan115APIProtocol.envelope(of: Data(body.utf8)) == .tokenExpired, "code \(code)")
        }
        // 4010xxxx(参数缺失)不是 token 的问题。
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":false,"code":40100000,"message":"参数缺失"}"#.utf8))
                == .failure(code: 40_100_000, message: "参数缺失"))
    }

    @Test("限流按业务码或说法识别,优先于授权类业务码")
    func rateLimitIsRecognizedFromCodeOrMessage() {
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":false,"code":40140117,"message":"刷新太频繁"}"#.utf8))
                == .rateLimited)
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":false,"code":0,"message":"请求过于频繁，请稍后再试"}"#.utf8))
                == .rateLimited)
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":false,"error":"Too Many Requests"}"#.utf8))
                == .rateLimited)
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":false,"code":50001,"message":"今日已达上限"}"#.utf8))
                == .rateLimited)
    }

    @Test("出错时空的 data 不会被当成空文件夹")
    func failedListingIsNotAnEmptyFolder() {
        let body = #"{"state":false,"code":20130827,"message":"系统繁忙","data":[]}"#
        #expect(Pan115APIProtocol.envelope(of: Data(body.utf8)) == .failure(code: 20_130_827, message: "系统繁忙"))
        #expect(Pan115APIProtocol.envelope(of: Data(#"{"state":false,"message":"文件不存在或已删除"}"#.utf8))
                == .notFound)
    }

    // MARK: - 刷新

    @Test("成功体带空 error 时照样收下轮换后的 refresh_token")
    func refreshSuccessWithEmptyErrorKeepsRotation() {
        let body = #"{"state":1,"code":0,"message":"","error":"","errno":0,"data":{"access_token":"AT","refresh_token":"RT2","expires_in":7200}}"#
        guard case .refreshed(let grant) = Pan115APIProtocol.refreshOutcome(Data(body.utf8)) else {
            Issue.record("Success body was rejected")
            return
        }
        #expect(grant.accessToken == "AT")
        #expect(grant.refreshToken == "RT2")
        #expect(grant.expiresIn == 7200)
        let stringExpiry = #"{"state":true,"data":{"access_token":"AT","refresh_token":"RT3","expires_in":"7200"}}"#
        #expect(Pan115APIProtocol.refreshOutcome(Data(stringExpiry.utf8))
                == .refreshed(.init(accessToken: "AT", refreshToken: "RT3", expiresIn: 7200, tokenType: nil)))
    }

    @Test("已被用过 / 失效的 refresh_token 要用户重新拿一个")
    func consumedRefreshTokenIsInvalid() {
        for code in [40_140_114, 40_140_115, 40_140_116, 40_140_119, 40_140_120] {
            let body = #"{"state":false,"code":\#(code),"message":"refresh_token 无效","error":"refresh_token 无效","errno":\#(code),"data":[]}"#
            #expect(Pan115APIProtocol.refreshOutcome(Data(body.utf8))
                    == .invalidRefreshToken(code: code, message: "refresh_token 无效"), "code \(code)")
        }
        // 「超出授权应用个数上限」带着「上限」二字,也不能当成限流。
        #expect(Pan115APIProtocol.refreshOutcome(Data(#"{"state":false,"code":40140122,"message":"超出授权应用个数上限"}"#.utf8))
                == .invalidRefreshToken(code: 40_140_122, message: "超出授权应用个数上限"))
        // state 为假时,body 里夹带的 token 不算数。
        let rejected = #"{"state":false,"code":40140116,"data":{"access_token":"rejected"}}"#
        #expect(Pan115APIProtocol.refreshOutcome(Data(rejected.utf8))
                == .invalidRefreshToken(code: 40_140_116, message: ""))
    }

    @Test("刷新太频繁是可以重试的限流,不是授权失效")
    func refreshRateLimitIsRetryable() {
        let body = #"{"state":false,"code":40140117,"message":"access_token 刷新太频繁","data":[]}"#
        #expect(Pan115APIProtocol.refreshOutcome(Data(body.utf8)) == .rateLimited)
        #expect(Pan115APIProtocol.refreshOutcome(Data(#"{"state":false,"code":40110000,"message":"请求异常需要重试"}"#.utf8))
                == .temporaryFailure(code: 40_110_000, message: "请求异常需要重试"))
    }

    @Test("说成功却没给 token、或只有非空 error 时仍是失败")
    func bodiesWithoutTokensStillFail() {
        #expect(Pan115APIProtocol.refreshOutcome(Data(#"{"state":true,"data":{"access_token":" "}}"#.utf8))
                == .temporaryFailure(code: nil, message: ""))
        #expect(Pan115APIProtocol.refreshOutcome(Data(#"{"error":"something went wrong"}"#.utf8))
                == .temporaryFailure(code: nil, message: "something went wrong"))
        #expect(Pan115APIProtocol.refreshOutcome(Data("not json".utf8)) == .temporaryFailure(code: nil, message: ""))
    }

    // MARK: - 直链与列表字段

    @Test("downurl:有地址、没这个文件、有文件没地址三种")
    func downloadLinkShapes() throws {
        let link = try #require(JSONSerialization.jsonObject(with: Data(
            #"{"state":true,"data":{"77":{"file_name":"a.flac","url":{"url":"https://cdn.115.example/a.flac"}}}}"#.utf8)) as? [String: Any])
        #expect(Pan115APIProtocol.downloadLink(in: link)
                == .link(fileID: "77", url: URL(string: "https://cdn.115.example/a.flac")!))
        let missing = try #require(JSONSerialization.jsonObject(with: Data(#"{"state":true,"data":[]}"#.utf8)) as? [String: Any])
        #expect(Pan115APIProtocol.downloadLink(in: missing) == .missingFile)
        let unavailable = try #require(JSONSerialization.jsonObject(with: Data(
            #"{"state":true,"data":{"78":{"url":{"url":""}}}}"#.utf8)) as? [String: Any])
        #expect(Pan115APIProtocol.downloadLink(in: unavailable) == .unavailable(fileID: "78"))
    }

    @Test("列表时间戳认秒和毫秒,空值和 0 不给日期")
    func listingTimestamps() {
        #expect(Pan115APIProtocol.date(fromTimestamp: "1700000000") == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(Pan115APIProtocol.date(fromTimestamp: NSNumber(value: 1_700_000_000_000)) == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(Pan115APIProtocol.date(fromTimestamp: "0") == nil)
        #expect(Pan115APIProtocol.date(fromTimestamp: nil) == nil)
        #expect(Pan115APIProtocol.intValue("1200") == 1200)
    }

    @Test("只给 115 的接口主机限频")
    func apiHosts() {
        #expect(Pan115APIProtocol.isAPIHost("proapi.115.com"))
        #expect(Pan115APIProtocol.isAPIHost("PassportAPI.115.com"))
        #expect(!Pan115APIProtocol.isAPIHost("cdnfhnfdfs.115cdn.net"))
        #expect(!Pan115APIProtocol.isAPIHost(nil))
    }

    @Test("115 播放只多预读一块")
    func playbackPrefetchIsCapped() {
        #expect(RangeStreamingPrefetchPolicy.aheadCount(for: .pan115, defaultValue: 4) == 1)
        #expect(RangeStreamingPrefetchPolicy.aheadCount(for: .pan115, defaultValue: 0) == 0)
    }
}

@Suite("115 file upload")
struct Pan115FileUploadTests {
    @Test func rangeChallengeUsesInclusiveOffsetsAndInstantUploadSkipsOSS() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abcdefgh".utf8).write(to: url)
        let fingerprint = try Pan115FileUpload.Fingerprint(file: url)
        let calls = UploadTrace()
        try await Pan115FileUpload.upload(file: url, fingerprint: fingerprint, parent: "7", name: "夜.flac") { items in
            let attempts = await calls.nextAttempt()
            let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            #expect(fields["target"] == "U_1_7")
            #expect(fields["fileid"] == "425AF12A0743502B322E93A015BCF868E324D56A")
            #expect(fields["preid"] == fields["fileid"])
            if attempts == 1 {
                return Data(#"{"status":7,"sign_check":"1-3","sign_key":"key"}"#.utf8)
            }
            #expect(fields["sign_key"] == "key")
            #expect(fields["sign_val"] == "924F61661A3472DA74307A35F2C8D22E07E84A4D")
            return Data(#"{"status":2}"#.utf8)
        } credentials: { throw URLError(.unsupportedURL) } transfer: { _, _ in throw URLError(.unsupportedURL) }
        #expect(await calls.attempts == 2)
        for range in ["4-3", "0-8", "-2-3", "2-x"] {
            #expect(throws: (any Error).self) { try Pan115FileUpload.challengeHash(range, file: url, size: 8) }
        }
    }

    @Test func signingUsesTheAssignedBucketAndKeepsSTSOnOSS() throws {
        let credentials = ["endpoint": "http://oss-cn-shenzhen.aliyuncs.com", "AccessKeyId": "fixture-id",
                           "AccessKeySecret": "fixture-secret", "SecurityToken": "fixture-token"]
        let signer = try Pan115FileUpload.OSS(bucket: "fixture-bucket", key: "a b/key", credentials: credentials)
        let request = signer.request("PUT", date: Date(timeIntervalSince1970: 1704067200))
        #expect(request.url?.absoluteString == "https://fixture-bucket.oss-cn-shenzhen.aliyuncs.com/a%20b/key")
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "OSS4-HMAC-SHA256 Credential=fixture-id/20240101/cn-shenzhen/oss/aliyun_v4_request,Signature=3c1d5b1b4d168e2c4fd2c14375d2b020e50a500241f7afa47a535c390ad9870b")
        let sequentialInit = signer.request("POST", query: [("uploads", ""), ("sequential", "")], date: Date(timeIntervalSince1970: 1704067200))
        #expect(sequentialInit.url?.query == "sequential&uploads")
        let keyOrdered = signer.request("GET", query: [("a-b", "1"), ("a", "2")], date: Date(timeIntervalSince1970: 1704067200))
        #expect(keyOrdered.url?.query == "a=2&a-b=1")
        var otherHost = credentials
        otherHost["endpoint"] = "https://oss-cn-shenzhen.aliyuncs.com.example.org"
        #expect(throws: (any Error).self) { try Pan115FileUpload.OSS(bucket: "fixture-bucket", key: "key", credentials: otherHost) }
    }

    @Test(arguments: [false, true])
    func streamsOrdinaryAndMultipartUploadsAndConfirmsCallback(multipart: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("data".utf8).write(to: file)
        if multipart {
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 65 * 1024 * 1024)
            try handle.close()
        }
        let fingerprint = try Pan115FileUpload.Fingerprint(file: file)
        let trace = UploadTrace()
        try await Pan115FileUpload.upload(file: file, fingerprint: fingerprint, parent: "0", name: "stage") { _ in
            Data(#"{"status":1,"bucket":"fixture","object":"a/b","callback":{"callback":"call","callback_var":"vars"}}"#.utf8)
        } credentials: {
            Data(#"{"endpoint":"oss-cn-shenzhen.aliyuncs.com","AccessKeyId":"id","AccessKeySecret":"secret","SecurityToken":"sts"}"#.utf8)
        } transfer: { request, body in
            let url = try #require(request.url)
            #expect(url.host == "fixture.oss-cn-shenzhen.aliyuncs.com")
            let part = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "partNumber" }?.value
            var data = Data()
            var headers: [String: String] = [:]
            if url.query == "sequential&uploads" {
                #expect(request.httpMethod == "POST")
                data = Data("<InitiateMultipartUploadResult><UploadId>abc</UploadId></InitiateMultipartUploadResult>".utf8)
            } else if let part, case .bytes(let bytes) = body {
                await trace.part(Int(part)!, size: bytes.count)
                headers["ETag"] = "\"0123456789ABCDEF0123456789ABCDEF\""
            } else {
                #expect(request.value(forHTTPHeaderField: "x-oss-callback") == "Y2FsbA==")
                #expect(request.value(forHTTPHeaderField: "x-oss-callback-var") == "dmFycw==")
                if multipart, case .bytes(let bytes) = body {
                    #expect(String(decoding: bytes, as: UTF8.self).contains("<PartNumber>9</PartNumber>"))
                } else if case .file(let bodyURL) = body { #expect(bodyURL == file) }
                else { Issue.record("Unexpected upload body") }
                await trace.complete()
                data = Data(#"{"state":true}"#.utf8)
            }
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!)
        }
        #expect(await trace.completed)
        if multipart {
            #expect(await trace.parts == Array(1...9))
            #expect(await trace.size == 65 * 1024 * 1024)
        }
    }

    @Test func callbackResponsesSurface203AndProviderErrorsInsteadOfOpaqueBadServerResponse() throws {
        let callbackFailedXML = Data("<Error><Code>CallbackFailed</Code><Message>timeout</Message></Error>".utf8)
        do {
            try Pan115FileUpload.validateCallbackResponse(callbackFailedXML, statusCode: 203)
            Issue.record("HTTP 203 CallbackFailed must fail")
        } catch let error as Pan115FileUpload.CallbackError {
            #expect(error == .unexpectedResponse(
                statusCode: 203,
                ossCode: "CallbackFailed",
                bodyPreview: "<Error><Code>CallbackFailed</Code><Message>timeout</Message></Error>"
            ))
            #expect(error.isRetryable)
        }

        let rateLimited = Data(#"{"state":false,"code":40140117,"message":"请求过于频繁"}"#.utf8)
        do {
            try Pan115FileUpload.validateCallbackResponse(rateLimited, statusCode: 200)
            Issue.record("Rate-limited callback must fail")
        } catch let error as Pan115FileUpload.CallbackError {
            #expect(error == .rateLimited)
            #expect(error.isRetryable)
        }

        let businessError = Data(#"{"state":false,"code":10002,"message":"校验文件失败"}"#.utf8)
        do {
            try Pan115FileUpload.validateCallbackResponse(businessError, statusCode: 200)
            Issue.record("Provider callback error must fail")
        } catch let error as Pan115FileUpload.CallbackError {
            #expect(error == .providerFailure(code: 10002, message: "校验文件失败"))
            #expect(!error.isRetryable)
        }

        let code200Payload = Data(#"{"code":200,"data":{"pick_code":"pc1","file_id":"1"}}"#.utf8)
        try Pan115FileUpload.validateCallbackResponse(code200Payload, statusCode: 200)
    }

    @Test func arrayWrappedCallbackAndMultipartSTSRefreshSucceed() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("data".utf8).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 65 * 1024 * 1024)
        try handle.close()
        let fingerprint = try Pan115FileUpload.Fingerprint(file: file)
        let trace = UploadTrace()
        try await Pan115FileUpload.upload(file: file, fingerprint: fingerprint, parent: "0", name: "stage") { _ in
            Data(#"{"status":1,"bucket":"fixture","object":"a/b","callback":[{"callback":"call","callback_var":"vars"}]}"#.utf8)
        } credentials: {
            let gen = await trace.nextCredentialGeneration()
            return Data(#"[{"endpoint":"OSS-CN-SHENZHEN.ALIYUNCS.COM","AccessKeyId":"id","AccessKeySecret":"secret","SecurityToken":"sts-\#(gen)"}]"#.utf8)
        } transfer: { request, body in
            let url = try #require(request.url)
            let part = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "partNumber" }?.value
            if url.query == "sequential&uploads" {
                #expect(request.httpMethod == "POST")
                return (Data("<InitiateMultipartUploadResult><UploadId>abc</UploadId></InitiateMultipartUploadResult>".utf8),
                        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            if part == "2", request.value(forHTTPHeaderField: "x-oss-security-token") == "sts-1" {
                let expired = Data("<Error><Code>SecurityTokenExpired</Code></Error>".utf8)
                return (expired, HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: nil)!)
            }
            if let part, case .bytes(let bytes) = body {
                await trace.part(Int(part)!, size: bytes.count)
                return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                headerFields: ["ETag": "\"0123456789ABCDEF0123456789ABCDEF\""])!)
            }
            #expect(request.value(forHTTPHeaderField: "x-oss-security-token") == "sts-2")
            await trace.complete()
            return (Data(#"{"state":true}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(await trace.completed)
        #expect(await trace.credentialGenerations == 2)
        #expect(await trace.parts == Array(1...9))
    }

    private actor UploadTrace {
        var attempts = 0
        func nextAttempt() -> Int { attempts += 1; return attempts }
        var credentialGenerations = 0
        func nextCredentialGeneration() -> Int { credentialGenerations += 1; return credentialGenerations }
        var parts: [Int] = []
        var size = 0
        var completed = false
        func part(_ n: Int, size: Int) { parts.append(n); self.size += size }
        func complete() { completed = true }
    }
}
