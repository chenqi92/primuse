import Foundation
import Security
import Testing
@testable import PrimuseKit

// MARK: - S3 SigV4 预签名(对齐 AWS 官方文档向量)
// AWS「Authenticating Requests: Using Query Parameters」GET examplebucket/test.txt 示例,
// 期望签名为 aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404。

@Test func s3PresignMatchesAWSVector() {
    let url = S3StreamResolver.presignedURL(
        method: "GET", scheme: "https", host: "examplebucket.s3.amazonaws.com",
        canonicalURI: "/test.txt",
        accessKey: "AKIAIOSFODNN7EXAMPLE",
        secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        region: "us-east-1", service: "s3",
        amzDate: "20130524T000000Z", dateStamp: "20130524", expires: 86400)
    let s = url?.absoluteString ?? ""
    #expect(s.contains("X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"))
    #expect(s.contains("X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"))
    #expect(s.hasPrefix("https://examplebucket.s3.amazonaws.com/test.txt?"))
}

@Test func s3URIEncode() {
    #expect(S3StreamResolver.uriEncode("a/b c", encodeSlash: false) == "a/b%20c")
    #expect(S3StreamResolver.uriEncode("a/b c", encodeSlash: true) == "a%2Fb%20c")
    #expect(S3StreamResolver.uriEncode("AZaz09-._~", encodeSlash: false) == "AZaz09-._~")
}

@Test func s3RegionParsing() {
    #expect(S3StreamResolver.region(from: #"{"region":"eu-west-1"}"#) == "eu-west-1")
    #expect(S3StreamResolver.region(from: nil) == "us-east-1")
    #expect(S3StreamResolver.region(from: "{}") == "us-east-1")
    #expect(S3StreamResolver.host(from: "https://minio.example.com:9000/x") == "minio.example.com:9000")
}

@Test func s3EndToEnd() async throws {
    let song = Song(id: "s", title: "T", fileFormat: .flac,
                    filePath: "artists/song.flac", sourceID: "src")
    let source = MusicSource(name: "S3", type: .s3, host: "s3.amazonaws.com",
                             useSsl: true, username: "AKIA", basePath: "my-bucket",
                             extraConfig: #"{"region":"us-west-2"}"#)
    let url = try await S3StreamResolver().streamURL(for: song, source: source,
                                                     credential: SourceCredential(password: "secret"))
    let s = url.absoluteString
    #expect(s.hasPrefix("https://s3.amazonaws.com/my-bucket/artists/song.flac?"))
    #expect(s.contains("X-Amz-Algorithm=AWS4-HMAC-SHA256"))
    #expect(s.contains("X-Amz-Signature="))
    #expect(s.contains("us-west-2%2Fs3%2Faws4_request"))
}

// MARK: - Synology FileStation URL 构造

@Test func synologyBaseURL() {
    #expect(SynologyStreamResolver.baseURL(host: "nas.local", port: 5001, useSsl: true)?.absoluteString
            == "https://nas.local:5001")
    #expect(SynologyStreamResolver.baseURL(host: "http://192.168.1.9", port: 5000, useSsl: false)?.absoluteString
            == "http://192.168.1.9:5000")
}

@Test func synologyDownloadURL() {
    let base = URL(string: "https://nas.local:5001")!
    let url = SynologyStreamResolver.downloadURL(base: base, path: "/music/a.flac", sid: "SID123")
    let q = Dictionary(uniqueKeysWithValues:
        (URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(url?.path == "/webapi/entry.cgi")
    #expect(q["api"] == "SYNO.FileStation.Download")
    #expect(q["method"] == "download")
    #expect(q["path"] == "/music/a.flac")
    #expect(q["_sid"] == "SID123")
}

// MARK: - 注册表覆盖

@Test func registryCoversNasAndS3() async {
    let supported = await StreamResolverRegistry().supportedTypes
    #expect(supported.isSuperset(of: [.subsonic, .navidrome, .airsonic, .gonic, .synology, .s3,
                                      .aliyunDrive, .oneDrive, .dropbox, .pan123,
                                      .jellyfin, .emby, .plex, .qnap, .fnos, .ugreen,
                                      .googleDrive, .pan115, .baiduPan]))
    #expect(!supported.contains(.smb))          // 原生库源仍不支持(需 Phase 3 中继)
    #expect(!supported.contains(.appleMusic))
}

// MARK: - 媒体服务器(Jellyfin/Emby/Plex)

@Test func mediaServerStreamURLs() {
    let base = URL(string: "https://jelly.example.com:8096")!
    let jf = MediaServerStreamResolver.jellyfinStreamURL(base: base, itemID: "abc123", token: "TK")
    #expect(jf?.absoluteString == "https://jelly.example.com:8096/Videos/abc123/stream?Static=true&api_key=TK")

    let plexBase = URL(string: "http://plex.local:32400")!
    let px = MediaServerStreamResolver.plexStreamURL(base: plexBase, partKey: "/library/parts/77/file.mp3", token: "PT")
    #expect(px?.absoluteString == "http://plex.local:32400/library/parts/77/file.mp3?X-Plex-Token=PT")
}

@Test func mediaServerParsing() {
    #expect(MediaServerStreamResolver.parseAccessToken(Data(#"{"AccessToken":"TK","User":{"Id":"u1"}}"#.utf8)) == "TK")
    let plexJSON = #"{"MediaContainer":{"Metadata":[{"Media":[{"Part":[{"key":"/library/parts/9/a.flac"}]}]}]}}"#
    #expect(MediaServerStreamResolver.parsePlexPartKey(Data(plexJSON.utf8)) == "/library/parts/9/a.flac")
    #expect(MediaServerStreamResolver.itemID(from: "/items/xyz789.mp3") == "xyz789")
    #expect(MediaServerStreamResolver.mediaBrowserAuth(deviceID: "d1", token: nil).contains("DeviceId=\"d1\""))
    #expect(MediaServerStreamResolver.baseURL(host: "h", port: 8096, useSsl: false, basePath: "/jf")?.absoluteString
            == "http://h:8096/jf")
}

// MARK: - 绿联 Ugreen(含 RSA 往返验证)

@Test func ugreenURLAndParse() {
    let url = UgreenStreamResolver.downloadURL(base: URL(string: "https://ug.local:9999")!,
                                               path: "/音乐/a b.flac", token: "TKN")
    let s = url?.absoluteString ?? ""
    #expect(s.hasPrefix("https://ug.local:9999/ugreen/v1/file/download?path="))
    #expect(s.contains("&token=TKN"))
    #expect(s.contains("%20"))   // 空格已编码
    #expect(UgreenStreamResolver.parseToken(Data(#"{"code":200,"data":{"token":"TT","uid":"u"}}"#.utf8)) == "TT")
    #expect(UgreenStreamResolver.parseToken(Data(#"{"code":200,"data":{"static_token":"ST"}}"#.utf8)) == "ST")
    #expect(UgreenStreamResolver.parseToken(Data(#"{"code":401,"data":{}}"#.utf8)) == nil)
}

@Test func ugreenRSARoundTrip() throws {
    // 生成 RSA 密钥对 → 用我们的 encrypt(公钥)加密 → 私钥解密,验证 RSA + 取公钥逻辑。
    var err: Unmanaged<CFError>?
    let priv = SecKeyCreateRandomKey([
        kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
        kSecAttrKeySizeInBits as String: 2048,
    ] as CFDictionary, &err)
    let privateKey = try #require(priv)
    let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
    let pubData = try #require(SecKeyCopyExternalRepresentation(publicKey, &err) as Data?)

    let b64 = try UgreenStreamResolver.encrypt(password: "hunter2", withPublicKeyData: pubData)
    let cipher = try #require(Data(base64Encoded: b64))
    let plain = try #require(SecKeyCreateDecryptedData(privateKey, .rsaEncryptionPKCS1, cipher as CFData, &err) as Data?)
    #expect(String(data: plain, encoding: .utf8) == "hunter2")
}

// MARK: - QNAP / fnOS NAS

@Test func nasHttpURLs() {
    let qnap = NasHttpStreamResolver.qnapDownloadURL(
        base: URL(string: "http://nas:8080")!, path: "/Music/a.flac", sid: "S1")
    let q = Dictionary(uniqueKeysWithValues:
        (URLComponents(url: qnap!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(qnap?.path == "/cgi-bin/filemanager/utilRequest.cgi")
    #expect(q["func"] == "download" && q["source_path"] == "/Music/a.flac" && q["sid"] == "S1")

    let fnos = NasHttpStreamResolver.fnosDownloadURL(
        base: URL(string: "http://fn:5666")!, path: "/m/b.mp3", token: "T1")
    let f = Dictionary(uniqueKeysWithValues:
        (URLComponents(url: fnos!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(fnos?.path == "/api/v1/file/download")
    #expect(f["path"] == "/m/b.mp3" && f["token"] == "T1")
}

@Test func nasHttpAuthParsing() {
    #expect(NasHttpStreamResolver.parseQnapSID(Data(#"{"authPassed":1,"authSid":"SID9"}"#.utf8)) == "SID9")
    #expect(NasHttpStreamResolver.parseQnapSID(Data("<QDocRoot><authPassed>1</authPassed><authSid><![CDATA[XSID]]></authSid></QDocRoot>".utf8)) == "XSID")
    #expect(NasHttpStreamResolver.parseQnapSID(Data(#"{"authPassed":0}"#.utf8)) == nil)
    #expect(NasHttpStreamResolver.parseFnosToken(Data(#"{"code":200,"data":{"token":"TK"}}"#.utf8)) == "TK")
    #expect(NasHttpStreamResolver.parseFnosToken(Data(#"{"code":0,"data":{"access_token":"AT"}}"#.utf8)) == "AT")
    #expect(NasHttpStreamResolver.parseFnosToken(Data(#"{"code":1001,"data":{}}"#.utf8)) == nil)
}

// MARK: - 云盘:响应解析 + 请求构造

@Test func cloudResponseParsing() {
    #expect(CloudDriveStreamResolver.parseAliyunURL(Data(#"{"url":"https://ali.example/x"}"#.utf8))?.absoluteString
            == "https://ali.example/x")
    #expect(CloudDriveStreamResolver.parseOneDriveURL(Data(#"{"@microsoft.graph.downloadUrl":"https://od.example/y"}"#.utf8))?.absoluteString
            == "https://od.example/y")
    #expect(CloudDriveStreamResolver.parseDropboxURL(Data(#"{"link":"https://db.example/z"}"#.utf8))?.absoluteString
            == "https://db.example/z")
    // 123:code 必须为 0
    #expect(CloudDriveStreamResolver.parse123URL(Data(#"{"code":0,"data":{"downloadUrl":"https://p123/a"}}"#.utf8))?.absoluteString
            == "https://p123/a")
    #expect(CloudDriveStreamResolver.parse123URL(Data(#"{"code":1,"data":{"downloadUrl":"https://p123/a"}}"#.utf8)) == nil)
    #expect(CloudDriveStreamResolver.parse123Token(Data(#"{"code":0,"data":{"accessToken":"TK"}}"#.utf8)) == "TK")
    #expect(CloudDriveStreamResolver.parseOAuthAccessToken(Data(#"{"access_token":"AT","expires_in":3600}"#.utf8)) == "AT")
}

@Test func cloud115Parsing() {
    #expect(CloudDriveStreamResolver.parse115URL(Data(#"{"state":1,"data":{"99":{"url":{"url":"https://115cdn/x.mp3"}}}}"#.utf8))?.absoluteString
            == "https://115cdn/x.mp3")
    #expect(CloudDriveStreamResolver.parse115AccessToken(Data(#"{"data":{"access_token":"AT115"}}"#.utf8)) == "AT115")
    #expect(CloudDriveStreamResolver.parse115AccessToken(Data(#"{"access_token":"T2"}"#.utf8)) == "T2")
}

@Test func googleDriveResolveAddsBearer() async throws {
    let song = Song(id: "g", title: "T", fileFormat: .flac, filePath: "FILEID123", sourceID: "gd")
    let source = MusicSource(name: "GD", type: .googleDrive)
    let resolved = try await CloudDriveStreamResolver().resolve(
        for: song, source: source, credential: SourceCredential(token: "GT"))
    #expect(resolved.url.absoluteString
            == "https://www.googleapis.com/drive/v3/files/FILEID123?alt=media&acknowledgeAbuse=true")
    #expect(resolved.headers["Authorization"] == "Bearer GT")
}

@Test func baiduParsing() {
    let entries: [[String: Any]] = [
        ["server_filename": "a.flac", "fs_id": Int64(123)],
        ["server_filename": "b.mp3", "fs_id": 456],
    ]
    #expect(BaiduPanStreamResolver.fsId(in: entries, name: "b.mp3") == 456)
    #expect(BaiduPanStreamResolver.fsId(in: entries, name: "a.flac") == 123)
    #expect(BaiduPanStreamResolver.fsId(in: entries, name: "missing") == nil)
    let meta: [String: Any] = ["list": [["dlink": "https://d.pcs.baidu.com/file/abc"]]]
    #expect(BaiduPanStreamResolver.dlink(in: meta) == "https://d.pcs.baidu.com/file/abc")
    #expect(BaiduPanStreamResolver.dlink(in: ["list": []]) == nil)
}

@Test func cloudRequestBuilders() {
    let json = CloudDriveStreamResolver.jsonRequest(
        url: URL(string: "https://api.dropboxapi.com/2/files/get_temporary_link")!,
        token: "TK", body: ["path": "/Music/a.flac"])
    #expect(json.httpMethod == "POST")
    #expect(json.value(forHTTPHeaderField: "Authorization") == "Bearer TK")
    #expect(json.value(forHTTPHeaderField: "Content-Type") == "application/json")

    let form = CloudDriveStreamResolver.formRequest(
        url: URL(string: "https://oauth2.googleapis.com/token")!,
        fields: ["grant_type": "refresh_token", "refresh_token": "r t/+"])
    let bodyStr = String(data: form.httpBody ?? Data(), encoding: .utf8) ?? ""
    #expect(form.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    #expect(bodyStr.contains("refresh_token=r%20t%2F%2B"))   // 特殊字符已编码
}

// MARK: - 凭据包(CloudKit 加密同步的载荷)

@Test func credentialBundleRoundTrip() throws {
    let entry = CredentialEntry(username: "u", password: "p", token: "tok",
                                refreshToken: "rt", clientID: "cid", clientSecret: "sec",
                                extra: ["drive_id": "9"])
    let bundle = CredentialBundle(entries: ["src1": entry, "src2": CredentialEntry(password: "x")])
    let decoded = CredentialBundle.decode(try bundle.jsonData())
    #expect(decoded == bundle)

    let cred = decoded?.credential(for: "src1", defaultUsername: "fallback")
    #expect(cred?.username == "u")
    #expect(cred?.token == "tok")
    #expect(cred?.extra["drive_id"] == "9")

    // entry.username 为空时回退到默认用户名
    #expect(bundle.credential(for: "src2", defaultUsername: "fallback")?.username == "fallback")
    #expect(bundle.credential(for: "missing", defaultUsername: nil) == nil)
    #expect(CredentialEntry().isEmpty)
    #expect(!CredentialEntry(password: "p").isEmpty)
}
