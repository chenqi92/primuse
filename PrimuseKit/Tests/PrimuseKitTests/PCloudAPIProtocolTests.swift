import Foundation
import Testing
@testable import PrimuseKit

@Suite("pCloud HTTP JSON protocol")
struct PCloudAPIProtocolTests {

    // MARK: - 主机与地区

    @Test("只认 pcloud.com 之下的主机名")
    func hostValidationStaysInsidePCloud() {
        #expect(PCloudAPIProtocol.validatedHost("api.pcloud.com") == "api.pcloud.com")
        #expect(PCloudAPIProtocol.validatedHost(" EAPI.pCloud.com ") == "eapi.pcloud.com")
        #expect(PCloudAPIProtocol.validatedHost("edef4.pcloud.com") == "edef4.pcloud.com")
        #expect(PCloudAPIProtocol.validatedHost("api-ams1.pcloud.com") == "api-ams1.pcloud.com")
        #expect(PCloudAPIProtocol.validatedHost("pcloud.com") == nil)
        #expect(PCloudAPIProtocol.validatedHost("api.pcloud.com.evil.example") == nil)
        #expect(PCloudAPIProtocol.validatedHost("evilpcloud.com") == nil)
        #expect(PCloudAPIProtocol.validatedHost("api.pcloud.com:8443") == nil)
        #expect(PCloudAPIProtocol.validatedHost("user@api.pcloud.com") == nil)
        #expect(PCloudAPIProtocol.validatedHost("-api.pcloud.com") == nil)
        #expect(PCloudAPIProtocol.validatedHost("api..pcloud.com") == nil)
        #expect(PCloudAPIProtocol.validatedHost(nil) == nil)
    }

    @Test("hostname 优先,其次按 locationid 换算,再其次是应答的那台")
    func apiHostResolutionOrder() {
        #expect(PCloudAPIProtocol.apiHost(hostname: "eapi.pcloud.com", locationID: "1") == "eapi.pcloud.com")
        #expect(PCloudAPIProtocol.apiHost(hostname: nil, locationID: "2") == "eapi.pcloud.com")
        #expect(PCloudAPIProtocol.apiHost(hostname: "attacker.example", locationID: "1") == "api.pcloud.com")
        #expect(PCloudAPIProtocol.apiHost(hostname: nil, locationID: "9", answeringHost: "eapi.pcloud.com")
            == "eapi.pcloud.com")
        #expect(PCloudAPIProtocol.apiHost(hostname: nil, locationID: nil) == nil)
    }

    @Test("凭据里没记主机时按美国区")
    func storedCredentialHost() {
        #expect(PCloudAPIProtocol.apiHost(from: nil) == "api.pcloud.com")
        #expect(PCloudAPIProtocol.apiHost(from: [PCloudAPIProtocol.locationIDKey: "2"]) == "eapi.pcloud.com")
        let extra = PCloudAPIProtocol.credentialExtra(apiHost: "eapi.pcloud.com", locationID: "2")
        #expect(PCloudAPIProtocol.apiHost(from: extra) == "eapi.pcloud.com")
        // 被篡改成别的域名的记录不会被采用。
        #expect(PCloudAPIProtocol.apiHost(from: [PCloudAPIProtocol.apiHostKey: "example.com"]) == "api.pcloud.com")
    }

    // MARK: - 标识

    @Test("目录与文件标识带前缀,浏览器根落到 folderid 0")
    func identifiers() {
        #expect(PCloudAPIProtocol.folderID(from: "") == 0)
        #expect(PCloudAPIProtocol.folderID(from: "/") == 0)
        #expect(PCloudAPIProtocol.folderID(from: "d0") == 0)
        #expect(PCloudAPIProtocol.folderID(from: "d230807") == 230_807)
        #expect(PCloudAPIProtocol.folderID(from: "230807") == 230_807)
        #expect(PCloudAPIProtocol.folderID(from: "f230807") == nil)
        #expect(PCloudAPIProtocol.folderID(from: "/Music") == nil)
        #expect(PCloudAPIProtocol.fileID(from: "f1723778") == 1_723_778)
        #expect(PCloudAPIProtocol.fileID(from: "d1723778") == nil)
        #expect(PCloudAPIProtocol.fileID(from: "f-1") == nil)
        #expect(PCloudAPIProtocol.isRootFolder("/"))
        #expect(!PCloudAPIProtocol.isRootFolder("d1"))
    }

    // MARK: - 接口地址

    @Test("业务接口打到账号所在的主机,时间字段要 Unix 秒")
    func methodURLs() throws {
        let list = try #require(PCloudAPIProtocol.listFolderURL(host: "eapi.pcloud.com", folderID: 230_807))
        #expect(list.host == "eapi.pcloud.com")
        #expect(list.path == "/listfolder")
        let items = URLComponents(url: list, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "folderid" }?.value == "230807")
        #expect(items.first { $0.name == "timeformat" }?.value == "timestamp")
        // token 走请求头,不进 URL。
        #expect(!items.contains { $0.name == "access_token" || $0.name == "auth" })

        let link = try #require(PCloudAPIProtocol.fileLinkURL(host: "api.pcloud.com", fileID: 1_723_778))
        #expect(link.path == "/getfilelink")
        #expect(link.query?.contains("fileid=1723778") == true)
        #expect(PCloudAPIProtocol.deleteFileURL(host: "api.pcloud.com", fileID: 5)?.path == "/deletefile")
        #expect(PCloudAPIProtocol.userInfoURL(host: "api.pcloud.com")?.path == "/userinfo")
        #expect(PCloudAPIProtocol.listFolderURL(host: "example.com", folderID: 0) == nil)
    }

    // MARK: - 授权

    @Test("隐式授权回调:fragment 里取 token、地区与主机")
    func implicitCallback() throws {
        let fragment = "access_token=TOKEN123&token_type=bearer&uid=34535&state=abc"
            + "&locationid=2&hostname=eapi.pcloud.com"
        let parameters = PCloudAPIProtocol.parameters(fromFragment: fragment)
        #expect(parameters["state"] == "abc")
        let authorization = try #require(PCloudAPIProtocol.authorization(from: parameters))
        #expect(authorization.accessToken == "TOKEN123")
        #expect(authorization.userID == "34535")
        #expect(authorization.apiHost == "eapi.pcloud.com")
        #expect(authorization.credentialExtra == [
            PCloudAPIProtocol.apiHostKey: "eapi.pcloud.com",
            PCloudAPIProtocol.locationIDKey: "2",
        ])

        // 官方 SDK 读的是 userid;只给 locationid 也能定主机。
        let sdkShape = PCloudAPIProtocol.parameters(fromFragment: "access_token=T&userid=7&locationid=1")
        let fallback = try #require(PCloudAPIProtocol.authorization(from: sdkShape))
        #expect(fallback.userID == "7")
        #expect(fallback.apiHost == "api.pcloud.com")

        // 定不下主机、或没有 token,都不算可用授权。
        #expect(PCloudAPIProtocol.authorization(from: ["access_token": "T"]) == nil)
        #expect(PCloudAPIProtocol.authorization(from: ["locationid": "1"]) == nil)
        #expect(PCloudAPIProtocol.parameters(fromFragment: nil).isEmpty)
    }

    @Test("poll_token 授权网址与轮询地址")
    func pollTokenURLs() throws {
        let requestID = PCloudAPIProtocol.makeRequestID()
        #expect(requestID.count == PCloudAPIProtocol.requestIDLength)
        #expect(requestID.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
        #expect(requestID != PCloudAPIProtocol.makeRequestID())

        let authorize = try #require(PCloudAPIProtocol.pollAuthorizeURL(clientID: "CID", requestID: requestID))
        #expect(authorize.host == "my.pcloud.com")
        #expect(authorize.path == "/oauth2/authorize")
        let authorizeItems = URLComponents(url: authorize, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(authorizeItems.first { $0.name == "response_type" }?.value == "poll_token")
        #expect(authorizeItems.first { $0.name == "request_id" }?.value == requestID)
        #expect(!authorizeItems.contains { $0.name == "redirect_uri" })

        let poll = try #require(PCloudAPIProtocol.pollTokenURL(
            host: "eapi.pcloud.com", clientID: "CID", requestID: requestID
        ))
        #expect(poll.host == "eapi.pcloud.com")
        #expect(poll.path == "/oauth2_token")
        #expect(poll.query?.contains("request_id=\(requestID)") == true)
    }

    @Test("轮询应答:成功拿授权,失败带业务码")
    func pollResponse() throws {
        let success = Data(#"{"result":0,"access_token":"AT","token_type":"bearer","uid":42,"locationid":2}"#.utf8)
        let outcome = try #require(PCloudAPIProtocol.parsePollResponse(success, answeringHost: "api.pcloud.com"))
        guard case .authorized(let authorization) = outcome else {
            Issue.record("expected authorization, got \(outcome)")
            return
        }
        #expect(authorization.accessToken == "AT")
        #expect(authorization.userID == "42")
        // locationid 比应答的主机可信:两区同时挂着,先回来的不一定是账号所在的那区。
        #expect(authorization.apiHost == "eapi.pcloud.com")

        let noLocation = Data(#"{"result":0,"access_token":"AT"}"#.utf8)
        guard case .authorized(let answered) = PCloudAPIProtocol.parsePollResponse(
            noLocation, answeringHost: "eapi.pcloud.com"
        ) else {
            Issue.record("expected authorization from answering host")
            return
        }
        #expect(answered.apiHost == "eapi.pcloud.com")

        let failure = Data(#"{"result":1128,"error":"Please provide 'code' or 'request_id'."}"#.utf8)
        #expect(PCloudAPIProtocol.parsePollResponse(failure, answeringHost: "api.pcloud.com")
            == .rejected(.init(result: 1128, message: "Please provide 'code' or 'request_id'.")))
        #expect(PCloudAPIProtocol.parsePollResponse(Data("<html>".utf8), answeringHost: "api.pcloud.com") == nil)
    }

    // MARK: - 应答

    @Test("业务码分类")
    func resultCodes() throws {
        let invalid = try #require(PCloudAPIProtocol.parseEnvelope(
            Data(#"{"result":2094,"error":"Invalid 'access_token' provided."}"#.utf8)
        ))
        #expect(!invalid.isSuccess)
        #expect(PCloudAPIProtocol.indicatesInvalidToken(invalid.result))
        #expect(PCloudAPIProtocol.indicatesInvalidToken(1000))
        #expect(!PCloudAPIProtocol.indicatesInvalidToken(2009))
        #expect(PCloudAPIProtocol.isTransient(4000))
        #expect(PCloudAPIProtocol.isTransient(5000))
        #expect(!PCloudAPIProtocol.isTransient(2005))
        #expect(PCloudAPIProtocol.indicatesMissingItem(2005))
        #expect(PCloudAPIProtocol.indicatesMissingItem(2009))
        // 没有 result 字段的 JSON 不当成功处理。
        #expect(PCloudAPIProtocol.parseEnvelope(Data(#"{"ok":true}"#.utf8))?.isSuccess == false)
    }

    @Test("listfolder:只取直接子项,坏行跳过,文件夹与文件用带前缀的 ID")
    func folderListing() throws {
        let data = Data("""
        {"result":0,"metadata":{"folderid":0,"isfolder":true,"name":"/","id":"d0","contents":[
          {"parentfolderid":0,"id":"d230807","modified":1380719015,"folderid":230807,
           "isfolder":true,"name":"Simple Folder"},
          {"contenttype":"audio/flac","parentfolderid":0,"modified":1380719000,
           "hash":10681749967730527559,"id":"f1723778","category":3,"fileid":1723778,
           "isfolder":false,"name":"Song.flac","size":11252576},
          {"isfolder":false,"name":"no-id.mp3","size":1},
          {"isfolder":false,"fileid":99,"name":"legacy.mp3","size":3,"modified":"1380719001"},
          "garbage"
        ]}}
        """.utf8)
        let entries = try #require(PCloudAPIProtocol.parseFolderListing(data))
        #expect(entries.map(\.id) == ["d230807", "f1723778", "f99"])

        let folder = entries[0]
        #expect(folder.isFolder)
        #expect(folder.size == 0)
        #expect(folder.contentHash == nil)

        let song = entries[1]
        #expect(!song.isFolder)
        #expect(song.name == "Song.flac")
        #expect(song.size == 11_252_576)
        #expect(song.modifiedAt == Date(timeIntervalSince1970: 1_380_719_000))
        #expect(song.contentHash?.isEmpty == false)

        #expect(entries[2].modifiedAt == Date(timeIntervalSince1970: 1_380_719_001))

        let empty = Data(#"{"result":0,"metadata":{"folderid":5,"isfolder":true,"name":"x"}}"#.utf8)
        #expect(PCloudAPIProtocol.parseFolderListing(empty) == [])
        let failed = Data(#"{"result":2005,"error":"Directory does not exist."}"#.utf8)
        #expect(PCloudAPIProtocol.parseFolderListing(failed) == nil)
    }

    @Test("getfilelink:拼 https + 第一台合法主机 + path")
    func fileLink() throws {
        let data = Data(#"""
        {"result":0,"path":"/cBZ6S0VkZ/My%20Song.flac","expires":1380780409,
         "hosts":["evil.example.com","c63.pcloud.com","c1.pcloud.com"]}
        """#.utf8)
        let link = try #require(PCloudAPIProtocol.parseFileLink(data))
        #expect(link.url.absoluteString == "https://c63.pcloud.com/cBZ6S0VkZ/My%20Song.flac")
        #expect(link.expiresAt == Date(timeIntervalSince1970: 1_380_780_409))

        let noHosts = Data(#"{"result":0,"path":"/a","hosts":["example.com"]}"#.utf8)
        #expect(PCloudAPIProtocol.parseFileLink(noHosts) == nil)
        let failed = Data(#"{"result":2009,"error":"File not found."}"#.utf8)
        #expect(PCloudAPIProtocol.parseFileLink(failed) == nil)
    }

    @Test("userinfo 与 deletefile")
    func userInfoAndDeletion() throws {
        let info = try #require(PCloudAPIProtocol.parseUserInfo(
            Data(#"{"result":0,"userid":1234,"email":"someone@example.com","premium":false}"#.utf8)
        ))
        #expect(info.userID == "1234")
        #expect(info.email == "someone@example.com")
        #expect(PCloudAPIProtocol.parseUserInfo(Data(#"{"result":2094}"#.utf8)) == nil)

        #expect(PCloudAPIProtocol.confirmsDeletion(
            Data(#"{"result":0,"metadata":{"isdeleted":true,"fileid":1736716,"name":"a.mp3"}}"#.utf8)
        ))
        #expect(!PCloudAPIProtocol.confirmsDeletion(Data(#"{"result":0,"metadata":{"fileid":1}}"#.utf8)))
        #expect(!PCloudAPIProtocol.confirmsDeletion(Data(#"{"result":2009,"error":"File not found."}"#.utf8)))
    }
}
