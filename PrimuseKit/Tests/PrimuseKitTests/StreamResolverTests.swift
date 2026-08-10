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
    #expect(S3StreamResolver.host(from: "minio.example.com", port: 9000) == "minio.example.com:9000")
    #expect(S3StreamResolver.host(from: "s3.amazonaws.com", port: 443) == "s3.amazonaws.com")
    #expect(S3StreamResolver.pathPrefix(from: "https://minio.example.com:9000/s3-proxy") == "s3-proxy")
    #expect(
        S3StreamResolver.canonicalObjectPath(
            endpointPrefix: "s3-proxy",
            bucket: "music",
            key: "artists/song.flac"
        ) == "/s3-proxy/music/artists/song.flac"
    )
}

@Test func s3ClockSkewUsesBoundedServerDateAdjustment() {
    let localDate = Date(timeIntervalSince1970: 0)
    let adjustment = S3ClockSkewPolicy.adjustment(
        serverDateHeader: "Thu, 01 Jan 1970 00:10:00 GMT",
        localDate: localDate
    )
    #expect(adjustment == 600)
    #expect(S3ClockSkewPolicy.adjustment(
        serverDateHeader: "Thu, 01 Jan 1970 00:00:10 GMT",
        localDate: localDate
    ) == 10)
    #expect(S3ClockSkewPolicy.adjustment(
        serverDateHeader: "Fri, 02 Jan 1970 01:00:00 GMT",
        localDate: localDate
    ) == nil)
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

@Test func s3EndToEndUsesConfiguredPort() async throws {
    let song = Song(id: "s-port", title: "T", fileFormat: .flac,
                    filePath: "artists/song.flac", sourceID: "src")
    let source = MusicSource(name: "MinIO", type: .s3, host: "minio.example.com",
                             port: 9000, useSsl: false, username: "AKIA", basePath: "music",
                             extraConfig: #"{"region":"us-east-1"}"#)
    let url = try await S3StreamResolver().streamURL(for: song, source: source,
                                                     credential: SourceCredential(password: "secret"))
    #expect(url.host == "minio.example.com")
    #expect(url.port == 9000)
}

@Test func s3EndToEndPreservesReverseProxyPrefixWithoutReplacingBucket() async throws {
    let song = Song(id: "s-proxy", title: "T", fileFormat: .flac,
                    filePath: "artists/song.flac", sourceID: "src")
    let source = MusicSource(name: "MinIO Proxy", type: .s3,
                             host: "https://minio.example.com/s3-proxy",
                             port: 443, useSsl: true, username: "AKIA", basePath: "music",
                             extraConfig: #"{"region":"us-east-1"}"#)
    let url = try await S3StreamResolver().streamURL(
        for: song,
        source: source,
        credential: SourceCredential(password: "secret")
    )
    #expect(url.path == "/s3-proxy/music/artists/song.flac")
    #expect(url.host == "minio.example.com")
}

// MARK: - Synology FileStation URL 构造

@Test func synologyBaseURL() {
    #expect(SynologyStreamResolver.baseURL(host: "nas.local", port: 5001, useSsl: true)?.absoluteString
            == "https://nas.local:5001")
    #expect(SynologyStreamResolver.baseURL(host: "http://192.168.1.9", port: 5000, useSsl: false)?.absoluteString
            == "http://192.168.1.9:5000")
    #expect(
        SynologyStreamResolver.baseURL(
            host: "https://nas.example.com:5443/dsm-proxy",
            port: 5001,
            useSsl: false
        )?.absoluteString == "https://nas.example.com:5443/dsm-proxy"
    )
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
                                      .jellyfin, .emby, .plex, .qnap, .fnMusic, .daoliyu, .ugreen,
                                      .googleDrive, .pan115, .baiduPan, .drime]))
    // Phase 3:原生库源经中继也注册了
    #expect(supported.isSuperset(of: [.smb, .sftp, .nfs, .webdav, .local, .appleMusic]))
    #expect(!supported.contains(.appleMusicLibrary))   // macOS-only,不接
}

@Test func relayResolver() async throws {
    let song = Song(id: "r", title: "T", fileFormat: .flac, filePath: "/share/m/a b.flac", sourceID: "smb1")
    let source = MusicSource(id: "smb1", name: "NAS", type: .smb, host: "x")

    // 无中继端点 → relayUnavailable
    await #expect(throws: StreamResolveError.relayUnavailable) {
        try await RelayStreamResolver().streamURL(for: song, source: source, credential: nil)
    }
    // 有中继端点 → 拼出中继 URL
    let cred = SourceCredential(extra: ["relay_host": "192.168.1.5", "relay_port": "8080", "relay_token": "TK"])
    let url = try await RelayStreamResolver().streamURL(for: song, source: source, credential: cred)
    #expect(url.host == "192.168.1.5")
    #expect(url.port == 8080)
    let q = Dictionary(uniqueKeysWithValues:
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(q["source"] == "smb1" && q["path"] == "/share/m/a b.flac" && q["token"] == "TK")
}

@Test func webDavGuestModeOmitsAuthorization() async throws {
    let song = Song(id: "dav", title: "T", fileFormat: .flac,
                    filePath: "/Music/a.flac", sourceID: "dav-source")
    let source = MusicSource(id: "dav-source", name: "Public DAV", type: .webdav,
                             host: "dav.example.com", port: 8443, useSsl: true,
                             basePath: "/public", authType: .none)
    let resolved = try await WebDavStreamResolver().resolve(
        for: song, source: source, credential: SourceCredential())

    #expect(resolved.url.absoluteString == "https://dav.example.com:8443/public/Music/a.flac")
    #expect(resolved.headers["Authorization"] == nil)
}

@Test func anonymousSupportMatchesImplementedProtocols() {
    #expect(MusicSourceType.smb.supportsAnonymous)
    #expect(MusicSourceType.webdav.supportsAnonymous)
    #expect(MusicSourceType.ftp.supportsAnonymous)
    #expect(!MusicSourceType.sftp.supportsAnonymous)
}

// MARK: - 媒体服务器(Jellyfin/Emby/Plex)

@Test func mediaServerStreamURLs() {
    let base = URL(string: "https://jelly.example.com:8096")!
    let jf = MediaServerStreamResolver.jellyfinStreamURL(base: base, itemID: "abc123", token: "TK")
    #expect(jf?.absoluteString == "https://jelly.example.com:8096/Audio/abc123/stream?Static=true&api_key=TK")

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

@Test func mediaServerConcurrentResolvesShareLogin() async throws {
    CountingLoginURLProtocol.reset()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [CountingLoginURLProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }

    let resolver = MediaServerStreamResolver(session: session)
    let source = MusicSource(id: "jf-concurrent", name: "Jellyfin", type: .jellyfin,
                             host: "resolver.test", useSsl: true, username: "user")
    let firstSong = Song(id: "one", title: "One", fileFormat: .flac,
                         filePath: "/items/one.flac", sourceID: source.id)
    let secondSong = Song(id: "two", title: "Two", fileFormat: .flac,
                          filePath: "/items/two.flac", sourceID: source.id)
    let credential = SourceCredential(username: "user", password: "password")

    async let first = resolver.streamURL(for: firstSong, source: source, credential: credential)
    async let second = resolver.streamURL(for: secondSong, source: source, credential: credential)
    let (firstURL, secondURL) = try await (first, second)

    #expect(firstURL.absoluteString.contains("/Audio/one/stream"))
    #expect(secondURL.absoluteString.contains("/Audio/two/stream"))
    #expect(CountingLoginURLProtocol.requestCount == 1)
}

@Test func jellyfinPasswordlessUserCanResolve() async throws {
    PasswordlessLoginURLProtocol.reset()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [PasswordlessLoginURLProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }

    let resolver = MediaServerStreamResolver(session: session)
    let source = MusicSource(id: "jf-passwordless", name: "Jellyfin", type: .jellyfin,
                             host: "resolver.test", useSsl: true, username: "guest")
    let song = Song(id: "song", title: "Song", fileFormat: .flac,
                    filePath: "/items/song.flac", sourceID: source.id)

    let url = try await resolver.streamURL(for: song, source: source, credential: nil)
    #expect(url.absoluteString.contains("/Audio/song/stream"))
    #expect(PasswordlessLoginURLProtocol.requestCount == 1)
}

@Test func jellyfinAPIKeySkipsLogin() async throws {
    let resolver = MediaServerStreamResolver()
    let source = MusicSource(id: "jf-key", name: "Jellyfin", type: .jellyfin,
                             host: "jelly.example.com", useSsl: true, authType: .apiKey)
    let song = Song(id: "song", title: "Song", fileFormat: .flac,
                    filePath: "/items/song.flac", sourceID: source.id)

    let url = try await resolver.streamURL(
        for: song,
        source: source,
        credential: SourceCredential(password: "API-KEY")
    )
    #expect(url.absoluteString == "https://jelly.example.com:8096/Audio/song/stream?Static=true&api_key=API-KEY")
}

private final class PasswordlessLoginURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestCountStorage = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCountStorage
    }

    static func reset() {
        lock.lock()
        requestCountStorage = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCountStorage += 1
        Self.lock.unlock()
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"AccessToken":"passwordless-token"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class CountingLoginURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestCountStorage = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCountStorage
    }

    static func reset() {
        lock.lock()
        requestCountStorage = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCountStorage += 1
        Self.lock.unlock()

        // Keep the first login in flight long enough for the actor to admit a
        // second resolve call at its suspension point.
        Thread.sleep(forTimeInterval: 0.05)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200,
                                             httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"AccessToken":"shared-token"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FnMusicServiceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loginCountStorage = 0
    nonisolated(unsafe) private static var trackCountStorage = 0
    nonisolated(unsafe) private static var unsignedAPIRequestCountStorage = 0
    nonisolated(unsafe) private static var encodedCookieCountStorage = 0
    nonisolated(unsafe) private static var unexpectedAccessHeaderCountStorage = 0
    nonisolated(unsafe) private static var unexpectedServiceHeaderCountStorage = 0

    static var counts: (
        login: Int,
        track: Int,
        unsignedAPI: Int,
        encodedCookie: Int,
        unexpectedAccessHeader: Int,
        unexpectedServiceHeader: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            loginCountStorage,
            trackCountStorage,
            unsignedAPIRequestCountStorage,
            encodedCookieCountStorage,
            unexpectedAccessHeaderCountStorage,
            unexpectedServiceHeaderCountStorage
        )
    }

    static func reset() {
        lock.lock()
        loginCountStorage = 0
        trackCountStorage = 0
        unsignedAPIRequestCountStorage = 0
        encodedCookieCountStorage = 0
        unexpectedAccessHeaderCountStorage = 0
        unexpectedServiceHeaderCountStorage = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let isLogin = url.path.hasSuffix("/music/api/v1/user/password-login")
        let isTrackList = url.path.hasSuffix("/music/api/v1/track/list")
        let hasAuthx = request.value(forHTTPHeaderField: FnMusicAPIProtocol.authxHeaderField) != nil
        let hasUnexpectedAccessHeaders = request.value(forHTTPHeaderField: "x-access-code") != nil
            || request.value(forHTTPHeaderField: "x-access-source") != nil

        Self.lock.lock()
        if url.path.contains(FnMusicAPIProtocol.apiPath), !hasAuthx {
            Self.unsignedAPIRequestCountStorage += 1
        }
        if isLogin { Self.loginCountStorage += 1 }
        if isTrackList {
            Self.trackCountStorage += 1
            if request.value(forHTTPHeaderField: "Cookie") == "music-token=T%2BA%2FB%3D" {
                Self.encodedCookieCountStorage += 1
            }
        }
        if hasUnexpectedAccessHeaders { Self.unexpectedAccessHeaderCountStorage += 1 }
        if request.value(forHTTPHeaderField: "X-Music-API") != nil {
            Self.unexpectedServiceHeaderCountStorage += 1
        }
        Self.lock.unlock()

        if isLogin {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let data: Data
        if isLogin {
            data = Data(#"{"code":200,"data":{"userToken":"T+A/B="}}"#.utf8)
        } else if isTrackList {
            data = Data(#"{"code":200,"data":{"list":[],"total":0}}"#.utf8)
        } else {
            data = Data()
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FnMusicUnauthorizedOnceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loginCountStorage = 0
    nonisolated(unsafe) private static var trackCountStorage = 0

    static var counts: (login: Int, track: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (loginCountStorage, trackCountStorage)
    }

    static func reset() {
        lock.lock()
        loginCountStorage = 0
        trackCountStorage = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let isLogin = url.path.hasSuffix("/music/api/v1/user/password-login")
        let isTrackList = url.path.hasSuffix("/music/api/v1/track/list")
        let status: Int
        let data: Data

        Self.lock.lock()
        if isLogin {
            Self.loginCountStorage += 1
            status = 200
            data = Data("{\"code\":200,\"data\":{\"userToken\":\"token-\(Self.loginCountStorage)\"}}".utf8)
        } else if isTrackList {
            Self.trackCountStorage += 1
            if Self.trackCountStorage == 1 {
                status = 401
                data = Data(#"{"code":401,"msg":"expired"}"#.utf8)
            } else {
                status = 200
                data = Data(#"{"code":200,"data":{"list":[],"total":0}}"#.utf8)
            }
        } else {
            status = 404
            data = Data()
        }
        Self.lock.unlock()

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FnMusicRateLimitOnceURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loginCountStorage = 0
    nonisolated(unsafe) private static var trackCountStorage = 0

    static var counts: (login: Int, track: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (loginCountStorage, trackCountStorage)
    }

    static func reset() {
        lock.lock()
        loginCountStorage = 0
        trackCountStorage = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let isLogin = url.path.hasSuffix("/music/api/v1/user/password-login")
        let isTrackList = url.path.hasSuffix("/music/api/v1/track/list")
        let status: Int
        let data: Data

        Self.lock.lock()
        if isLogin {
            Self.loginCountStorage += 1
            status = 200
            data = Data(#"{"code":200,"data":{"userToken":"token"}}"#.utf8)
        } else if isTrackList {
            Self.trackCountStorage += 1
            if Self.trackCountStorage == 1 {
                status = 429
                data = Data(#"{"code":429,"msg":"rate limited"}"#.utf8)
            } else {
                status = 200
                data = Data(#"{"code":200,"data":{"list":[],"total":0}}"#.utf8)
            }
        } else {
            status = 404
            data = Data()
        }
        Self.lock.unlock()

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - 绿联 Ugreen(含 RSA 往返验证)

@Test func ugreenURLAndParse() {
    #expect(
        UgreenStreamResolver.baseURL(
            host: "https://ug.example.com:9443/ug-proxy",
            port: 9999,
            useSsl: false
        )?.absoluteString == "https://ug.example.com:9443/ug-proxy"
    )
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

@Test func ugreenRSAEncryptsWithServerPublicKey() throws {
    // 固定的测试公钥模拟 NAS 下发的 X.509 SubjectPublicKeyInfo。测试不应在运行时
    // 生成临时私钥，否则受宿主 Security/keychain 状态影响，可能以 paramErr 偶发失败。
    let publicKeyDER = try #require(Data(base64Encoded: "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAuer9d6mPjA5NwPwf5koROT6osTJoesWOFPJVgwhxCm6YM8TorGDm4wyPF2Qbw6jt8zoqDYK+4/dYmZB8HBEsbKCRY+8Gi/rnNnr9oxK4DlkEtE5TYFwl8P6x6ITX9p1vEejYgv6ZHAFbh0z8qoP+EkHsUHeUhZIcEXGMoeoXT9oNU4DjLqXxJoZpxLu/gxPSE3q1h02xEKKMvU2k4dBbX1D/eTMEkRMuDtl66ZhHy/WM6LLau4hGquFm+0wEJfuG03gQ2g213ILd01e0WIs188yzIz9IXv53jLGUi1xR3EmcKpA8zPyJSm8mrYVmm97WbZIfjFglr1MzHKCnW5C0fQIDAQAB"))

    let first = try #require(Data(base64Encoded: UgreenStreamResolver.encrypt(
        password: "hunter2",
        withPublicKeyData: publicKeyDER
    )))
    let second = try #require(Data(base64Encoded: UgreenStreamResolver.encrypt(
        password: "hunter2",
        withPublicKeyData: publicKeyDER
    )))

    #expect(first.count == 256)
    #expect(second.count == 256)
    #expect(first != second) // PKCS#1 v1.5 padding must be randomized.
}

// MARK: - QNAP / Feiniu Music

@Test func nasHttpURLs() {
    let qnap = NasHttpStreamResolver.qnapDownloadURL(
        base: URL(string: "http://nas:8080")!, path: "/Music/a.flac", sid: "S1")
    let q = Dictionary(uniqueKeysWithValues:
        (URLComponents(url: qnap!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(qnap?.path == "/cgi-bin/filemanager/utilRequest.cgi")
    #expect(q["func"] == "download" && q["source_path"] == "/Music/a.flac" && q["sid"] == "S1")

    let fnMusic = FnMusicStreamResolver.fnMusicStreamURL(
        base: URL(string: "http://fn:5666")!, trackGUID: "track-1")
    let f = Dictionary(uniqueKeysWithValues:
        (URLComponents(url: fnMusic!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(fnMusic?.path == "/music/api/v1/track/stream")
    #expect(f["guid"] == "track-1")

    let proxyBase = NasHttpStreamResolver.baseURL(
        host: "https://nas.example.com:8443/qnap",
        port: 8080,
        useSsl: false
    )
    #expect(proxyBase?.absoluteString == "https://nas.example.com:8443/qnap")
    #expect(
        NasHttpStreamResolver.qnapDownloadURL(
            base: proxyBase!,
            path: "/Music/a.flac",
            sid: "S2"
        )?.path == "/qnap/cgi-bin/filemanager/utilRequest.cgi"
    )
}

@Test func nasHttpAuthParsing() {
    #expect(NasHttpStreamResolver.parseQnapSID(Data(#"{"authPassed":1,"authSid":"SID9"}"#.utf8)) == "SID9")
    #expect(NasHttpStreamResolver.parseQnapSID(Data("<QDocRoot><authPassed>1</authPassed><authSid><![CDATA[XSID]]></authSid></QDocRoot>".utf8)) == "XSID")
    #expect(NasHttpStreamResolver.parseQnapSID(Data(#"{"authPassed":0}"#.utf8)) == nil)
    #expect(FnMusicStreamResolver.parseFnMusicToken(Data(#"{"code":200,"data":{"userToken":"TK"}}"#.utf8)) == "TK")
    #expect(FnMusicStreamResolver.parseFnMusicToken(Data(#"{"code":200,"data":{"userToken":"  "}}"#.utf8)) == nil)
    #expect(FnMusicStreamResolver.parseFnMusicToken(Data(#"{"code":0,"data":{"token":"wrong-field"}}"#.utf8)) == nil)
    #expect(FnMusicStreamResolver.parseFnMusicToken(Data(#"{"code":120001,"data":{}}"#.utf8)) == nil)
}

@Test func fnMusicProtocolCanonicalizesEndpointQuery() throws {
    let base = try #require(FnMusicAPIProtocol.serverBaseURL(
        host: "http://fn.local:5666/proxy",
        port: nil,
        useSSL: false
    ))
    let url = try #require(FnMusicAPIProtocol.endpointURL(
        serverBaseURL: base,
        path: "/search/track",
        queryItems: [
            URLQueryItem(name: "q", value: "hello world"),
            URLQueryItem(name: "page", value: "1"),
        ]
    ))
    #expect(url.path == "/proxy/music/api/v1/search/track")
    #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
            == "page=1&q=hello%20world")
    #expect(url.absoluteString.contains("page=1&q=hello%20world"))
    #expect(FnMusicAPIProtocol.authxPath(for: url) == "/music/api/v1/search/track")
    #expect(FnMusicAPIProtocol.authxPath(
        for: try #require(URL(string: "https://fn.local/proxy/music/api/v1"))
    ) == "/music/api/v1")

    let officialWebBase = try #require(FnMusicAPIProtocol.serverBaseURL(
        host: "http://fn.local:5666/music",
        port: nil,
        useSSL: false
    ))
    let officialWebEndpoint = try #require(FnMusicAPIProtocol.endpointURL(
        serverBaseURL: officialWebBase,
        path: "/track/list"
    ))
    #expect(officialWebEndpoint.path == "/music/api/v1/track/list")
}

@Test func fnMusicAuthxMatchesCurrentProtocolVector() {
    let header = FnMusicAPIProtocol.authxHeader(
        method: "GET",
        path: "/music/api/v1/search/track",
        queryItems: [
            URLQueryItem(name: "q", value: "hello world"),
            URLQueryItem(name: "page", value: "1"),
        ],
        nonce: "123456",
        timestampMilliseconds: 1_700_000_000_000,
        prefix: "prefix",
        key: "key"
    )

    #expect(header == "nonce=123456&timestamp=1700000000000&sign=a32d34bb733dfb367391b7fd7e0ce2d7")

    let proxiedURL = URL(string: "https://fn.local/proxy/music/api/v1/search/track?q=hello%20world&page=1")!
    let proxiedHeader = FnMusicAPIProtocol.authxHeader(
        method: "GET",
        path: FnMusicAPIProtocol.authxPath(for: proxiedURL),
        queryItems: URLComponents(url: proxiedURL, resolvingAgainstBaseURL: false)?.queryItems ?? [],
        nonce: "123456",
        timestampMilliseconds: 1_700_000_000_000,
        prefix: "prefix",
        key: "key"
    )
    #expect(proxiedHeader == header)
}

@Test func fnMusicAuthxHashesExactNonGetBody() {
    let body = Data(#"{"username":"u"}"#.utf8)
    let header = FnMusicAPIProtocol.authxHeader(
        method: "POST",
        path: "/music/api/v1/user/password-login",
        bodyData: body,
        nonce: "123456",
        timestampMilliseconds: 1_700_000_000_000,
        prefix: "prefix",
        key: "key"
    )

    #expect(header == "nonce=123456&timestamp=1700000000000&sign=3deb2c59683b5fe5f94cd86555a17cea")
}

@Test func fnMusicCurrentAuthxUsesSixDigitNonceAndUnixMilliseconds() {
    let header = FnMusicAPIProtocol.currentAuthxHeader(
        method: "GET",
        path: "/music/api/v1/initialization/state",
        now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let fields: [String: String] = Dictionary(
        uniqueKeysWithValues: header.split(separator: "&").compactMap { field in
            let parts = field.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    )

    #expect(fields["nonce"]?.count == 6)
    #expect(fields["nonce"]?.allSatisfy(\.isNumber) == true)
    #expect(fields["timestamp"] == "1700000000000")
    #expect(fields["sign"]?.count == 32)
}

@Test func fnMusicServiceConcurrentRequestsShareOneSignedLogin() async throws {
    FnMusicServiceURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FnMusicServiceURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let source = MusicSource(
        id: "fnmusic-concurrent",
        name: "Feiniu Music",
        type: .fnMusic,
        host: "fnmusic.test",
        port: 5666,
        useSsl: false,
        username: "user",
        basePath: "/proxy"
    )
    let credential = SourceCredential(
        username: "user",
        password: "password"
    )
    let client = FnMusicServiceClient(source: source, credential: credential, session: session)

    async let first = client.validateConnection()
    async let second = client.validateConnection()
    let totals = try await (first, second)
    let counts = FnMusicServiceURLProtocol.counts

    #expect(totals.0 == 0)
    #expect(totals.1 == 0)
    #expect(counts.login == 1)
    #expect(counts.track == 2)
    #expect(counts.unsignedAPI == 0)
    #expect(counts.encodedCookie == 2)
    #expect(counts.unexpectedAccessHeader == 0)
    #expect(counts.unexpectedServiceHeader == 0)
}

@Test func fnMusicServiceRefreshesOnlyAnExpiredSession() async throws {
    FnMusicUnauthorizedOnceURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FnMusicUnauthorizedOnceURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let source = MusicSource(
        id: "fnmusic-refresh",
        name: "Feiniu Music",
        type: .fnMusic,
        host: "fnmusic.test",
        port: 5666,
        useSsl: false,
        username: "user"
    )
    let client = FnMusicServiceClient(
        source: source,
        credential: SourceCredential(username: "user", password: "password"),
        session: session
    )

    let total = try await client.validateConnection()
    let counts = FnMusicUnauthorizedOnceURLProtocol.counts

    #expect(total == 0)
    #expect(counts.login == 2)
    #expect(counts.track == 2)
}

@Test func fnMusicServiceKeepsSessionAfterRateLimit() async throws {
    FnMusicRateLimitOnceURLProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FnMusicRateLimitOnceURLProtocol.self]
    let session = URLSession(configuration: configuration)
    let source = MusicSource(
        id: "fnmusic-rate-limit",
        name: "Feiniu Music",
        type: .fnMusic,
        host: "fnmusic.test",
        port: 5666,
        useSsl: false,
        username: "user"
    )
    let client = FnMusicServiceClient(
        source: source,
        credential: SourceCredential(username: "user", password: "password"),
        session: session
    )

    await #expect(throws: FnMusicServiceError.badServerResponse(429)) {
        _ = try await client.validateConnection()
    }
    let total = try await client.validateConnection()
    let counts = FnMusicRateLimitOnceURLProtocol.counts

    #expect(total == 0)
    #expect(counts.login == 1)
    #expect(counts.track == 2)
}

@Test func fnMusicProtocolHashesCredentialsAndKeepsOpaqueReferences() {
    #expect(FnMusicAPIProtocol.passwordHash("password")
            == "5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8")
    #expect(FnMusicAPIProtocol.defaultAuthxSigningPrefix == "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh")
    #expect(FnMusicAPIProtocol.defaultAuthxClientKey == "6D5602D4-A342-4799-A0F0-BB795E7167D0")
    #expect(FnMusicAPIProtocol.musicTokenCookie("A+B/C=") == "music-token=A%2BB%2FC%3D")

    let path = FnMusicAPIProtocol.trackPath(guid: "track-guid", fileExtension: "FLAC")
    #expect(path == "/fnmusic/tracks/track-guid.flac")
    #expect(FnMusicAPIProtocol.trackGUID(from: path) == "track-guid")
}

@Test func fnMusicProtocolPersistsOneDeviceIDPerDefaultsSuite() throws {
    let suiteName = "FnMusicAPIProtocolTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = FnMusicAPIProtocol.deviceID(sourceID: "source-1", defaults: defaults)
    let second = FnMusicAPIProtocol.deviceID(sourceID: "source-2", defaults: defaults)
    let reopenedDefaults = try #require(UserDefaults(suiteName: suiteName))
    let reopened = FnMusicAPIProtocol.deviceID(sourceID: "source-3", defaults: reopenedDefaults)

    #expect(first.count == 32)
    #expect(first == first.lowercased())
    #expect(first.allSatisfy { $0.isHexDigit })
    #expect(second == first)
    #expect(reopened == first)
}

@Test func fnMusicCoverReferencePreservesRevisionAndParsesCoverID() {
    let plain = FnMusicAPIProtocol.coverReference(coverID: "cover-guid")
    let revised = FnMusicAPIProtocol.coverReference(coverID: "cover-guid", revision: 1_725_000_000)

    #expect(plain == "fnmusic-cover/cover-guid")
    #expect(revised == "fnmusic-cover/cover-guid?revision=1725000000")
    #expect(plain != revised)
    #expect(FnMusicAPIProtocol.coverID(from: revised) == "cover-guid")
    #expect(FnMusicAPIProtocol.coverRevision(from: revised) == 1_725_000_000)
    #expect(FnMusicAPIProtocol.coverRevision(from: plain) == nil)
    #expect(!revised.contains("music-token"))
}

@Test func fnMusicCatalogTrackBuildsStableServiceBackedSong() throws {
    let json: [String: Any] = [
        "guid": "track-guid",
        "title": "Track",
        "year": 2026,
        "discNo": 1,
        "trackNo": 2,
        "duration": 999_999,
        "createdAt": 1_725_000_000,
        "updatedAt": 1_725_000_100,
        "album": ["guid": "album-guid", "name": "Album", "coverId": "cover-guid"],
        "artists": [["guid": "artist-guid", "name": "Artist"]],
        "audioSpec": [
            "path": "/volume/music/track.bin",
            "extension": "FLAC",
            "format": "mp3",
            "container": "wav",
            "duration": 123_456,
            "size": 12_345_678,
            "bitrate": 1_411_000,
            "sampleRate": 96_000,
            "bitDepth": 24,
        ],
    ]
    let track = try #require(FnMusicCatalogTrack(json: json))
    let first = try #require(track.makeSong(sourceID: "source-1"))
    let second = try #require(track.makeSong(sourceID: "source-1"))

    #expect(track.hasUsableCatalogTitle)
    #expect(first.id == second.id)
    #expect(first.filePath == "/fnmusic/tracks/track-guid.flac")
    #expect(first.filePath != "/volume/music/track.flac")
    #expect(first.albumID == "album-guid")
    #expect(first.artistName == "Artist")
    #expect(first.duration == 123.456)
    #expect(first.bitRate == 1_411)
    #expect(first.coverArtFileName == "fnmusic-cover/cover-guid?revision=1725000100")
}

@Test func fnMusicCatalogTrackUsesCurrentAudioFallbacks() throws {
    let cases: [([String: Any], String)] = [
        (["format": "mp3", "path": "/music/wrong.bin"], "mp3"),
        (["container": "wav", "path": "/music/wrong.bin"], "wav"),
        (["path": "/music/fallback.ogg"], "ogg"),
    ]

    for (audioSpec, expectedExtension) in cases {
        let track = try #require(FnMusicCatalogTrack(json: [
            "guid": "track-\(expectedExtension)",
            "title": "Track",
            "duration": 42_000,
            "audioSpec": audioSpec,
        ]))
        #expect(track.fileExtension == expectedExtension)
        #expect(track.durationMilliseconds == 42_000)
    }
}

@Test func fnMusicCatalogTrackUsesCurrentIdentityAndCoverFallbacks() throws {
    let track = try #require(FnMusicCatalogTrack(json: [
        "id": "track-id",
        "name": "Alternate Track",
        "cover": ["guid": "track-cover"],
        "album": ["id": "album-id", "title": "Alternate Album"],
        "artists": [["id": "artist-id", "title": "Alternate Artist"]],
        "audioSpec": ["extension": "flac", "duration": 1_000],
    ]))
    let song = try #require(track.makeSong(sourceID: "source-1"))

    #expect(track.hasUsableCatalogTitle)
    #expect(track.guid == "track-id")
    #expect(song.title == "Alternate Track")
    #expect(song.albumID == "album-id")
    #expect(song.albumTitle == "Alternate Album")
    #expect(song.artistID == "artist-id")
    #expect(song.artistName == "Alternate Artist")
    #expect(song.coverArtFileName == "fnmusic-cover/track-cover")
}

@Test func fnMusicFilenameFallbackDoesNotAcknowledgeCatalogTitle() throws {
    let filenameFallback = try #require(FnMusicCatalogTrack(json: [
        "guid": "filename-only",
        "filename": "Visible Filename.flac",
        "audioSpec": ["extension": "flac"],
    ]))
    let missing = try #require(FnMusicCatalogTrack(json: [
        "guid": "missing-title",
        "audioSpec": ["extension": "flac"],
    ]))
    let placeholder = try #require(FnMusicCatalogTrack(json: [
        "guid": "placeholder-title",
        "title": "Unknown",
        "filename": "Real Looking Filename.flac",
        "audioSpec": ["extension": "flac"],
    ]))

    #expect(filenameFallback.title == "Visible Filename.flac")
    #expect(!filenameFallback.hasUsableCatalogTitle)
    #expect(missing.title == "Unknown")
    #expect(!missing.hasUsableCatalogTitle)
    #expect(placeholder.title == "Unknown")
    #expect(!placeholder.hasUsableCatalogTitle)
}

@Test func fnMusicCatalogTrackMapsGenreCueAndCodecAliases() throws {
    let track = try #require(FnMusicCatalogTrack(json: [
        "guid": "cue-track",
        "trackTitle": "Cue Track",
        "album": "Cue Album",
        "albumId": "cue-album",
        "artist": "Cue Artist",
        "artistId": "cue-artist",
        "genres": [["name": "Rock"], ["name": "Live"]],
        "coverUrl": "/music/api/v1/static/cover?coverId=cue-cover",
        "isCue": true,
        "startTime": 12.5,
        "endTime": 42.75,
        "trackIndex": 3,
        "createdAt": 1_725_000_000,
        "audioSpec": [
            "format": "cue",
            "container": "audio",
            "codec": "pcm_s24le",
            "duration": 180_000,
            "bitrate": 320,
            "sampleRate": 48_000,
            "bitDepth": 24,
        ],
    ]))
    let song = try #require(track.makeSong(sourceID: "source-1"))

    #expect(track.fileExtension == "wav")
    #expect(song.fileFormat == .wav)
    #expect(song.title == "Cue Track")
    #expect(song.albumID == "cue-album")
    #expect(song.albumTitle == "Cue Album")
    #expect(song.artistID == "cue-artist")
    #expect(song.artistName == "Cue Artist")
    #expect(song.genre == "Rock, Live")
    #expect(song.trackNumber == 3)
    #expect(song.duration == 30.25)
    #expect(song.bitRate == 320)
    #expect(song.cueSheetPath == "/fnmusic/cue/cue-track.cue")
    #expect(song.cueStartTime == 12.5)
    #expect(song.cueEndTime == 42.75)
    #expect(song.coverArtFileName == "fnmusic-cover/cue-cover?revision=1725000000")
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

@Test func cloudBodyAuthenticationErrorsAreTyped() {
    #expect(throws: StreamResolveError.authFailed) {
        try CloudDriveStreamResolver.checkBodyAuthenticationFailure(Data(#"{"code":401,"message":"expired"}"#.utf8))
    }
    #expect(throws: StreamResolveError.authFailed) {
        try CloudDriveStreamResolver.checkBodyAuthenticationFailure(Data(#"{"error":"invalid_token"}"#.utf8))
    }
    #expect(throws: Never.self) {
        try CloudDriveStreamResolver.checkBodyAuthenticationFailure(Data(#"{"code":5001,"message":"file unavailable"}"#.utf8))
    }
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

@Test func baiduFileManagerValidatesEveryItem() throws {
    let data = Data(#"{"errno":0,"info":[{"errno":0,"path":"/a.mp3"},{"errno":0,"path":"/b.mp3"}]}"#.utf8)
    let response = try BaiduFileManagerBatchResponse.decode(data)
    try response.validate(expectedPaths: ["/a.mp3", "/b.mp3"])
}

@Test func baiduFileManagerRejectsPartialFailure() throws {
    let data = Data(#"{"errno":0,"info":[{"errno":0,"path":"/a.mp3"},{"errno":12,"path":"/b.mp3"}]}"#.utf8)
    let response = try BaiduFileManagerBatchResponse.decode(data)

    #expect(throws: BaiduFileManagerBatchResponse.ValidationError.failedItems([
        .init(errno: 12, path: "/b.mp3")
    ])) {
        try response.validate(expectedPaths: ["/a.mp3", "/b.mp3"])
    }
}

@Test func baiduFileManagerRejectsMissingResultRows() throws {
    let data = Data(#"{"errno":0,"info":[{"errno":0,"path":"/a.mp3"}]}"#.utf8)
    let response = try BaiduFileManagerBatchResponse.decode(data)

    #expect(throws: BaiduFileManagerBatchResponse.ValidationError.missingPaths(["/b.mp3"])) {
        try response.validate(expectedPaths: ["/a.mp3", "/b.mp3"])
    }
}

@Test func baiduFileManagerRequiresSynchronousItemResults() throws {
    let data = Data(#"{"errno":0,"taskid":123}"#.utf8)
    let response = try BaiduFileManagerBatchResponse.decode(data)

    #expect(throws: BaiduFileManagerBatchResponse.ValidationError.missingItemResults) {
        try response.validate(expectedPaths: ["/a.mp3"])
    }
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
    #expect(!CredentialEntry(extra: ["custom": "value"]).isEmpty)
}

@Test func credentialBundleDecodesEntriesWrittenBeforeExtraWasAdded() throws {
    let historicalJSON = Data(#"{"version":1,"entries":{"src":{"username":"u","password":"p","token":"t","refreshToken":"r","clientID":"id","clientSecret":"secret"}}}"#.utf8)
    let decoded = try #require(CredentialBundle.decode(historicalJSON))

    #expect(decoded.entries["src"]?.username == "u")
    #expect(decoded.entries["src"]?.password == "p")
    #expect(decoded.entries["src"]?.token == "t")
    #expect(decoded.entries["src"]?.extra == [:])
}
