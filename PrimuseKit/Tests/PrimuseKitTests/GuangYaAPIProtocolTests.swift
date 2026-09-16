import Foundation
import Testing
@testable import PrimuseKit

@Suite("GuangYa open platform protocol")
struct GuangYaAPIProtocolTests {

    // MARK: - 签名

    /// 签名原文的参数顺序、参数名与分隔符都不能动,MD5 结果也不再做二次编码 ——
    /// 任一处改动都会被服务端判成 116(签名无效)。这里用一组固定向量钉住它。
    /// 向量里的值是占位用的示例值,真实接入方凭据只经构建配置注入。
    @Test("签名原文顺序与 MD5 结果不可改")
    func signatureMatchesFixedVector() {
        let sign = GuangYaAPIProtocol.signature(
            clientID: "primuse-openapi-demo",
            timestamp: "1789353678",
            signSecret: "demo-sign-secret"
        )
        #expect(sign == "d14d6f108a28660eda4f029cf04f803b")
    }

    @Test("业务头带齐 Authorization / client_id / timestamp / sign")
    func businessHeadersCarrySignature() throws {
        let config = GuangYaAPIProtocol.AppConfig(
            clientID: "primuse-openapi-demo",
            projectID: "demo-project",
            signSecret: "demo-sign-secret"
        )
        let headers = GuangYaAPIProtocol.businessHeaders(
            accessToken: "at",
            config: config,
            date: Date(timeIntervalSince1970: 1_789_353_678)
        )
        #expect(headers["Authorization"] == "Bearer at")
        #expect(headers["client_id"] == "primuse-openapi-demo")
        #expect(headers["timestamp"] == "1789353678")
        #expect(headers["sign"] == "d14d6f108a28660eda4f029cf04f803b")
        // traceparent 建议携带,格式是 W3C Trace Context。
        let trace = try #require(headers["traceparent"])
        let parts = trace.split(separator: "-")
        #expect(parts.count == 4)
        #expect(parts[0] == "00")
        #expect(parts[1].count == 32)
        #expect(parts[2].count == 16)
    }

    // MARK: - URL 构造

    @Test("根目录不传 parentId,子目录才带")
    func fileListURLOmitsParentIDAtRoot() throws {
        let root = try #require(GuangYaAPIProtocol.fileListURL(parentID: nil, page: 0))
        let rootQuery = URLComponents(url: root, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!rootQuery.contains { $0.name == "parentId" })
        #expect(rootQuery.first { $0.name == "pageSize" }?.value
            == String(GuangYaAPIProtocol.defaultPageSize))
        #expect(root.path == "/openapi/v1/file/get_file_list")

        let child = try #require(
            GuangYaAPIProtocol.fileListURL(parentID: "1835243138919944265", page: 2)
        )
        let childQuery = URLComponents(url: child, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(childQuery.first { $0.name == "parentId" }?.value == "1835243138919944265")
        #expect(childQuery.first { $0.name == "page" }?.value == "2")
    }

    @Test("空串 / 斜杠 / 0 都算根目录")
    func rootIdentifiersAreNormalized() {
        #expect(GuangYaAPIProtocol.isRootIdentifier(""))
        #expect(GuangYaAPIProtocol.isRootIdentifier("/"))
        #expect(GuangYaAPIProtocol.isRootIdentifier("0"))
        #expect(!GuangYaAPIProtocol.isRootIdentifier("1835243138919944265"))
    }

    @Test("下载与详情接口按 fileId 取址")
    func fileEndpointsCarryFileID() throws {
        let download = try #require(GuangYaAPIProtocol.downloadURL(fileID: "abc"))
        #expect(download.path == "/openapi/v1/file/get_res_download_url")
        #expect(download.query == "fileId=abc")

        let detail = try #require(GuangYaAPIProtocol.fileDetailURL(fileID: "abc"))
        #expect(detail.path == "/openapi/v1/file/get_file_detail")
    }

    // MARK: - 应答解析

    @Test("列表区分文件与文件夹,并保留大小与创建时间")
    func parsesFileList() throws {
        let json = """
        {"code":0,"msg":"success[0]","data":{"total":2,"list":[
          {"fileId":"1835243138919944265","fileName":"111","depth":1,"resType":2,"ctime":1762845661},
          {"fileId":"1835603479919075411","fileName":"track.flac","fileSize":5046219,
           "bizId":"biz-1","parentId":"1835243138919944265","depth":1,"mineType":"audio/flac",
           "fileType":3,"resType":1,"ext":".flac","ctime":1762931573}
        ]}}
        """
        let page = try #require(GuangYaAPIProtocol.parseFileList(Data(json.utf8)))
        #expect(page.total == 2)
        #expect(page.entries.count == 2)

        let folder = page.entries[0]
        #expect(folder.isDirectory)
        #expect(folder.size == 0)
        #expect(folder.createdAt == Date(timeIntervalSince1970: 1_762_845_661))

        let file = page.entries[1]
        #expect(!file.isDirectory)
        #expect(file.size == 5_046_219)
        #expect(file.bizID == "biz-1")
        #expect(file.fileType == 3)
        #expect(file.parentID == "1835243138919944265")
    }

    @Test("空目录只回 total 也要解成空页,而不是解析失败")
    func parsesEmptyDirectory() throws {
        let page = try #require(
            GuangYaAPIProtocol.parseFileList(Data(#"{"code":0,"msg":"success[0]","data":{"total":0}}"#.utf8))
        )
        #expect(page.total == 0)
        #expect(page.entries.isEmpty)
    }

    @Test("坏条目只跳过自己,不让整页解析失败")
    func skipsUnparsableEntriesInsteadOfFailingPage() throws {
        let json = """
        {"code":0,"msg":"success[0]","data":{"total":2,"list":[
          {"fileId":"1","fileName":"ok.flac","fileSize":1,"resType":1,"ctime":1},
          {"fileName":"缺 fileId 的异常行","resType":1}
        ]}}
        """
        // 整页判失败会让这个目录连同整次扫描一起报错,用户侧看到的是
        // 「歌进来了但没有文件夹」外加反复重试,代价远大于漏掉一行。
        let page = try #require(GuangYaAPIProtocol.parseFileList(Data(json.utf8)))
        #expect(page.entries.count == 1)
        #expect(page.entries[0].fileID == "1")

        // 一条都读不出来才算应答不可用。
        let allUnparsable = Data(#"{"code":0,"msg":"success[0]","data":{"total":1,"list":[{"fileName":"x"}]}}"#.utf8)
        #expect(GuangYaAPIProtocol.parseFileList(allUnparsable) == nil)
    }

    // MARK: - 翻页

    @Test("服务端把 pageSize 截短时仍按 total 翻完")
    func paginationFollowsReportedTotal() {
        // 请求 100 条、服务端只给 50 条:按「本页不满就是到底」判断的话,
        // 每个目录都只会扫到第一页,剩下 270 首歌永远进不了资料库。
        #expect(GuangYaAPIProtocol.shouldRequestNextPage(
            receivedCount: 50,
            accumulatedCount: 50,
            reportedTotal: 320,
            requestedPageSize: 100,
            nextPage: 1
        ))
        #expect(!GuangYaAPIProtocol.shouldRequestNextPage(
            receivedCount: 20,
            accumulatedCount: 320,
            reportedTotal: 320,
            requestedPageSize: 100,
            nextPage: 7
        ))
    }

    @Test("拿不到 total 时回落到满页判断")
    func paginationFallsBackToFullPage() {
        #expect(GuangYaAPIProtocol.shouldRequestNextPage(
            receivedCount: 100,
            accumulatedCount: 100,
            reportedTotal: nil,
            requestedPageSize: 100,
            nextPage: 1
        ))
        #expect(!GuangYaAPIProtocol.shouldRequestNextPage(
            receivedCount: 37,
            accumulatedCount: 137,
            reportedTotal: nil,
            requestedPageSize: 100,
            nextPage: 2
        ))
    }

    @Test("空页与页数上限都终止翻页")
    func paginationStopsOnEmptyPageAndPageLimit() {
        #expect(!GuangYaAPIProtocol.shouldRequestNextPage(
            receivedCount: 0,
            accumulatedCount: 100,
            reportedTotal: 999,
            requestedPageSize: 100,
            nextPage: 1
        ))
        #expect(!GuangYaAPIProtocol.shouldRequestNextPage(
            receivedCount: 100,
            accumulatedCount: 100,
            reportedTotal: 10_000,
            requestedPageSize: 100,
            nextPage: 5,
            pageLimit: 5
        ))
    }

    @Test("限频间隔比厂商上限更慢,给并发留出余量")
    func throttleIntervalsLeaveHeadroom() {
        // 文档:列表 5 次/秒、其余业务接口 2 次/秒,并明确要求不要贴着上限发。
        #expect(GuangYaAPIProtocol.fileListMinimumInterval > 1.0 / 5.0)
        #expect(GuangYaAPIProtocol.defaultMinimumInterval > 1.0 / 2.0)
        #expect(GuangYaAPIProtocol.rateLimitCooldown > GuangYaAPIProtocol.defaultMinimumInterval)
    }

    @Test("业务码非 0 时不产出数据")
    func rejectsNonZeroBusinessCode() {
        let invalidToken = Data(#"{"code":117,"msg":"无效token"}"#.utf8)
        #expect(GuangYaAPIProtocol.parseFileList(invalidToken) == nil)
        let envelope = GuangYaAPIProtocol.parseEnvelope(invalidToken)
        #expect(envelope?.code == GuangYaAPIProtocol.ResultCode.invalidAccessToken)
        #expect(envelope?.isSuccess == false)
        #expect(GuangYaAPIProtocol.indicatesInvalidToken(code: 117))
        #expect(!GuangYaAPIProtocol.indicatesInvalidToken(code: 116))

        // 签名无效走的是 HTTP 200 + code 116,只能靠 body 认出来。
        let badSign = Data(#"{"code":116,"msg":"无效签名","data":null}"#.utf8)
        #expect(GuangYaAPIProtocol.parseEnvelope(badSign)?.code
            == GuangYaAPIProtocol.ResultCode.invalidSign)
    }

    @Test("直链优先取 signedURL,并带回有效期")
    func parsesDownloadTicket() throws {
        let signed = try #require(GuangYaAPIProtocol.parseDownloadTicket(
            Data(#"{"code":0,"msg":"success[0]","data":{"signedURL":"https://cdn.example/a.flac","urlDuration":21600}}"#.utf8)
        ))
        #expect(signed.url.absoluteString == "https://cdn.example/a.flac")
        #expect(signed.duration == 21_600)

        let fallback = try #require(GuangYaAPIProtocol.parseDownloadTicket(
            Data(#"{"code":0,"msg":"success[0]","data":{"downloadUrl":"https://cdn.example/b.flac"}}"#.utf8)
        ))
        #expect(fallback.url.absoluteString == "https://cdn.example/b.flac")
    }

    @Test("用户信息取 userId 作为账号标识")
    func parsesUserInfo() throws {
        let info = try #require(GuangYaAPIProtocol.parseUserInfo(
            Data("""
            {"code":0,"msg":"success[0]","data":{"userId":"u-1","nickName":"duck",
             "vipStatus":2,"totalSpace":1000000,"usedSpace":100}}
            """.utf8)
        ))
        #expect(info.userID == "u-1")
        #expect(info.nickName == "duck")
        #expect(info.totalSpace == 1_000_000)
        #expect(info.usedSpace == 100)
    }

    // MARK: - 设备码授权

    /// 真实服务端的设备码应答形状(用测试接入方凭据取回)。共享的
    /// `CloudDeviceAuthParsing` 必须能直接吃下它,否则电视端扫不出二维码。
    @Test("设备码应答可被通用解析层消费")
    func deviceCodeStartParsesWithSharedLayer() throws {
        let json = """
        {"device_code":"dc-1","user_code":"uc-1","expires_in":120,"interval":2,
         "verification_url":"https://openapi-account.guangyapan.com/__/auth/device/?client_id=cid&scope=user%20offline",
         "verification_uri_complete":"https://openapi-account.guangyapan.com/__/auth/device/?client_id=cid&scope=user%20offline&user_code=uc-1"}
        """
        let start = try #require(CloudDeviceAuthParsing.parseDeviceCodeStart(Data(json.utf8)))
        #expect(start.deviceCode == "dc-1")
        #expect(start.userCode == "uc-1")
        #expect(start.interval == 2)
        #expect(start.expiresIn == 120)
        #expect(start.verificationURLComplete?.contains("user_code=uc-1") == true)
    }

    /// 未授权时服务端回 HTTP 400 + `authorization_pending`,不能当失败。
    @Test("轮询未授权状态解成 pending")
    func deviceCodePendingIsNotAFailure() {
        let json = Data("""
        {"error":"authorization_pending","error_code":4050,
         "error_description":"Precondition Required"}
        """.utf8)
        #expect(CloudDeviceAuthParsing.parseDeviceCodePoll(json) == .pending)
    }

    @Test("光鸭走设备码通道,且不需要 client_secret")
    func deviceAuthSupportIncludesGuangYa() {
        #expect(CloudDeviceAuthSupport.providers.contains(.guangya))
        #expect(CloudDeviceAuthSupport.kind(for: .guangya) == .deviceCode)
        #expect(!CloudDeviceAuthSupport.requiresClientSecret(.guangya))
    }

    @Test("拉起光鸭 App 的深链会对授权地址整体编码")
    func buildsAppDeepLink() throws {
        let complete = "https://openapi-account.guangyapan.com/__/auth/device/?client_id=cid&user_code=uc-1"
        let link = try #require(
            GuangYaAPIProtocol.appAuthorizationDeepLink(verificationURLComplete: complete)
        )
        #expect(link.scheme == "gyp")
        #expect(link.host == "auth")
        // 整个授权地址是一个参数值:里面的 ? 与 & 必须被编码,否则会被当成
        // 深链自己的查询参数切开。
        #expect(!link.absoluteString.dropFirst("gyp://auth?url=".count).contains("&"))
        let decoded = URLComponents(url: link, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "url" }?.value
        #expect(decoded == complete)
        #expect(GuangYaAPIProtocol.appAuthorizationDeepLink(verificationURLComplete: "  ") == nil)
    }

    // MARK: - 设备标识

    @Test("设备 ID 规整成 32 位小写十六进制")
    func normalizesDeviceIdentifier() {
        #expect(GuangYaAPIProtocol.normalizedDeviceIdentifier("0123456789ABCDEF0123456789abcdef")
            == "0123456789abcdef0123456789abcdef")
        #expect(GuangYaAPIProtocol.normalizedDeviceIdentifier(
            "01234567-89ab-cdef-0123-456789abcdef"
        ) == "0123456789abcdef0123456789abcdef")
        #expect(GuangYaAPIProtocol.normalizedDeviceIdentifier("too-short") == nil)
        #expect(GuangYaAPIProtocol.normalizedDeviceIdentifier(String(repeating: "z", count: 32)) == nil)
        #expect(GuangYaAPIProtocol.normalizedDeviceIdentifier(
            GuangYaAPIProtocol.randomDeviceIdentifier()
        ) != nil)
    }

    @Test("设备 ID 首次生成后保持稳定")
    func deviceIdentifierIsStableAcrossReads() throws {
        let suiteName = "guangya-device-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = GuangYaAPIProtocol.deviceIdentifier(defaults: defaults)
        let second = GuangYaAPIProtocol.deviceIdentifier(defaults: defaults)
        #expect(first == second)
        #expect(GuangYaAPIProtocol.normalizedDeviceIdentifier(first) == first)
    }

    // MARK: - 源类型接线

    @Test("光鸭是只读云盘:不写 sidecar、不删源文件、用不透明目录 ID")
    func sourceTypeWiring() {
        #expect(MusicSourceType.guangya.category == .cloudDrive)
        #expect(MusicSourceType.guangya.isCloudDrive)
        #expect(MusicSourceType.guangya.requiresOAuth)
        #expect(!MusicSourceType.guangya.requiresHost)
        #expect(!MusicSourceType.guangya.requiresCredentials)
        #expect(MusicSourceType.guangya.usesOpaqueDirectoryIdentifiers)
        #expect(MusicSourceType.guangya.supportsRangeStreaming)
        #expect(!MusicSourceType.guangya.supportsSidecarWriting)
        #expect(!MusicSourceType.guangya.supportsFileDeletion)
        #expect(MusicSourceType.guangya.continuesToDirectorySelectionAfterCreation)
        #expect(MusicSourceType.catalogCases.contains(.guangya))
        // 不能写回源站,刮削结果只能留在本地元数据缓存里。
        #expect(AudioMetadataWritebackPolicy.capability(sourceType: .guangya, format: .mp3)
            == .localOnly)
        #expect(AudioMetadataWritebackPolicy.capability(sourceType: .guangya, format: .flac)
            == .localOnly)
    }
}
