import Foundation
import Testing
@testable import PrimuseKit

// MARK: - 纯函数

@Test func subsonicMD5KnownVector() {
    // 已知 MD5: md5("hello") = 5d41402abc4b2a76b9719d911017c592
    #expect(SubsonicStreamResolver.md5Hex("hello") == "5d41402abc4b2a76b9719d911017c592")
}

@Test func subsonicSongIDFromPath() {
    #expect(SubsonicStreamResolver.songID(from: "/songs/abc123.flac") == "abc123")
    #expect(SubsonicStreamResolver.songID(from: "/songs/xy.z.mp3") == "xy.z")
    #expect(SubsonicStreamResolver.songID(from: "track9.wav") == "track9")
    #expect(SubsonicStreamResolver.songID(from: "") == nil)
}

@Test func subsonicBaseURL() {
    #expect(SubsonicStreamResolver.makeBaseURL(host: "music.example.com", port: 4533,
                                               useSsl: true, basePath: nil)?.absoluteString
            == "https://music.example.com:4533")
    // host 自带 scheme 时尊重它
    #expect(SubsonicStreamResolver.makeBaseURL(host: "http://nas.local", port: nil,
                                               useSsl: true, basePath: nil)?.absoluteString
            == "http://nas.local")
    // basePath 逐段拼接
    #expect(SubsonicStreamResolver.makeBaseURL(host: "h.com", port: 80,
                                               useSsl: false, basePath: "/navidrome")?.absoluteString
            == "http://h.com:80/navidrome")
    #expect(SubsonicStreamResolver.makeBaseURL(host: "", port: 4533,
                                               useSsl: true, basePath: nil) == nil)
}

@Test func subsonicStreamURLExactString() {
    let base = URL(string: "https://demo.navidrome.org:443")!
    let raw = SubsonicStreamResolver.streamURL(base: base, username: "u", token: "TT",
                                               salt: "abcdef", songID: "song1", transcode: false)
    #expect(raw?.absoluteString
            == "https://demo.navidrome.org:443/rest/stream.view?u=u&t=TT&s=abcdef&v=1.16.1&c=Primuse&f=json&id=song1&format=raw")

    let mp3 = SubsonicStreamResolver.streamURL(base: base, username: "u", token: "TT",
                                               salt: "abcdef", songID: "song1", transcode: true)
    #expect(mp3?.absoluteString
            == "https://demo.navidrome.org:443/rest/stream.view?u=u&t=TT&s=abcdef&v=1.16.1&c=Primuse&f=json&id=song1&format=mp3&maxBitRate=320")
}

// MARK: - 端到端解析(随机 salt → 校验 token 一致)

@Test func subsonicResolveEndToEnd() async throws {
    let song = Song(id: "s1", title: "Track", duration: 200,
                    fileFormat: .flac, filePath: "/songs/track42.flac", sourceID: "src1")
    let source = MusicSource(name: "Navi", type: .navidrome, host: "music.x.com",
                             port: 4533, useSsl: true, username: "admin")
    let cred = SourceCredential(password: "secret")
    let url = try await SubsonicStreamResolver().streamURL(for: song, source: source, credential: cred)

    let comp = URLComponents(url: url, resolvingAgainstBaseURL: false)!
    let q = Dictionary(uniqueKeysWithValues: (comp.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(comp.host == "music.x.com")
    #expect(comp.path == "/rest/stream.view")
    #expect(q["id"] == "track42")
    #expect(q["u"] == "admin")
    #expect(q["format"] == "raw")
    // token 必须等于 md5(password + 实际下发的 salt)
    #expect(q["t"] == SubsonicStreamResolver.md5Hex("secret" + (q["s"] ?? "")))
}

@Test func subsonicWMATranscodes() async throws {
    let host = "subsonic-stream.example.com"
    let session = subsonicLyricsTestSession(host: host) { _ in
        (200, Data(#"{"subsonic-response":{"status":"ok"}}"#.utf8))
    }
    defer { SubsonicLyricsURLProtocol.reset(host: host) }
    let song = Song(id: "s2", title: "Old", duration: 180,
                    fileFormat: .wma, filePath: "/songs/old1.wma", sourceID: "src1")
    let source = MusicSource(name: "Subsonic", type: .subsonic, host: host,
                             port: 443, useSsl: true, username: "u")
    let resolver = SubsonicStreamResolver(session: session)
    let url = try await resolver.streamURL(for: song, source: source,
                                          credential: SourceCredential(password: "p"))
    let q = Dictionary(uniqueKeysWithValues:
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(q["format"] == "mp3")
    #expect(q["maxBitRate"] == "320")
    #expect(q["p"] == nil)
    #expect(q["t"] == SubsonicStreamResolver.md5Hex("p" + (q["s"] ?? "")))
    _ = try await resolver.streamURL(for: song, source: source, credential: SourceCredential(password: "p"))
    let requests = SubsonicLyricsURLProtocol.requests(host: host)
    #expect(requests.count == 1)
    #expect(requests.first?.url?.lastPathComponent == "ping.view")
    let pingQuery = subsonicTestQuery(try #require(requests.first?.url))
    #expect(pingQuery["p"] == nil)
    #expect(pingQuery["t"] == SubsonicStreamResolver.md5Hex("p" + (pingQuery["s"] ?? "")))
}

@Test func subsonicStreamFallsBackOnlyAfterTokenUnsupported() async throws {
    let host = "legacy-subsonic-stream.example.com"
    let session = subsonicLyricsTestSession(host: host) { request in
        let query = subsonicTestQuery(request.url!)
        if query["p"] == nil {
            return (200, Data(#"{"subsonic-response":{"_attributes":{"status":"failed"},"error":{"_attributes":{"code":41}}}}"#.utf8))
        }
        return (200, Data(#"{"subsonic-response":{"status":"ok"}}"#.utf8))
    }
    defer { SubsonicLyricsURLProtocol.reset(host: host) }
    let source = MusicSource(name: "Legacy", type: .subsonic, host: host, useSsl: true, username: "u")
    let song = Song(id: "s", title: "Track", fileFormat: .flac, filePath: "/songs/track.flac", sourceID: source.id)
    let resolver = SubsonicStreamResolver(session: session)
    let credential = SourceCredential(password: "测试+&口令")
    async let first = resolver.streamURL(for: song, source: source, credential: credential)
    async let second = resolver.streamURL(for: song, source: source, credential: credential)
    let urls = try await [first, second]
    let expectedPassword = "enc:" + SubsonicStreamResolver.hexEncoded(credential.password!)
    for url in urls {
        let query = subsonicTestQuery(url)
        #expect(query["p"] == expectedPassword)
        #expect(query["t"] == nil)
        #expect(query["s"] == nil)
        #expect(query["format"] == "raw")
    }
    let requests = SubsonicLyricsURLProtocol.requests(host: host)
    #expect(requests.count == 2)
    #expect(subsonicTestQuery(try #require(requests.first?.url))["p"] == nil)
    #expect(subsonicTestQuery(try #require(requests.last?.url))["p"] == expectedPassword)
    _ = try await resolver.streamURL(for: song, source: source, credential: credential)
    #expect(SubsonicLyricsURLProtocol.requests(host: host).count == 2)
}

@Test(arguments: [40, 50, 0, 401, 403, -1])
func subsonicStreamDoesNotDowngradeOnOtherFailures(code: Int) async throws {
    let host = "failed-subsonic-\(code).example.com"
    let session = subsonicLyricsTestSession(host: host) { _ in
        if code == -1 { return (200, Data("invalid response".utf8)) }
        if code >= 400 { return (code, Data()) }
        return (200, Data("{\"subsonic-response\":{\"status\":\"failed\",\"error\":{\"code\":\(code)}}}".utf8))
    }
    defer { SubsonicLyricsURLProtocol.reset(host: host) }
    let source = MusicSource(name: "Failure", type: .subsonic, host: host, useSsl: true, username: "u")
    let song = Song(id: "s", title: "Track", fileFormat: .flac, filePath: "/songs/track.flac", sourceID: source.id)
    let resolver = SubsonicStreamResolver(session: session)
    for _ in 0..<2 {
        await #expect(throws: (any Error).self) {
            try await resolver.streamURL(for: song, source: source, credential: SourceCredential(password: "p"))
        }
    }
    let requests = SubsonicLyricsURLProtocol.requests(host: host)
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { subsonicTestQuery($0.url!)["p"] == nil })
}

@Test func subsonicStreamRechecksAuthenticationWhenSourceChanges() async throws {
    let host = "changed-subsonic-stream.example.com"
    let session = subsonicLyricsTestSession(host: host) { request in
        if request.url!.path.hasPrefix("/legacy/"), subsonicTestQuery(request.url!)["p"] == nil {
            return (200, Data(#"{"subsonic-response":{"status":"failed","error":{"code":41}}}"#.utf8))
        }
        return (200, Data(#"{"subsonic-response":{"status":"ok"}}"#.utf8))
    }
    defer { SubsonicLyricsURLProtocol.reset(host: host) }
    var source = MusicSource(name: "Changed", type: .subsonic, host: host, useSsl: true, username: "u", basePath: "/legacy")
    let song = Song(id: "s", title: "Track", fileFormat: .flac, filePath: "/songs/track.flac", sourceID: source.id)
    let resolver = SubsonicStreamResolver(session: session)
    let legacy = try await resolver.streamURL(for: song, source: source, credential: SourceCredential(password: "p"))
    #expect(subsonicTestQuery(legacy)["p"] == "enc:70")
    source.basePath = "/modern"
    let modern = try await resolver.streamURL(for: song, source: source, credential: SourceCredential(password: "p"))
    #expect(subsonicTestQuery(modern)["p"] == nil)
    _ = try await resolver.streamURL(for: song, source: source, credential: SourceCredential(password: "changed"))
    _ = try await resolver.streamURL(for: song, source: source, credential: SourceCredential(username: "other", password: "changed"))
    await resolver.invalidateSession(sourceID: source.id)
    _ = try await resolver.streamURL(for: song, source: source, credential: SourceCredential(username: "other", password: "changed"))
    let requests = SubsonicLyricsURLProtocol.requests(host: host)
    #expect(requests.count == 6)
    #expect(requests.dropFirst(2).allSatisfy { subsonicTestQuery($0.url!)["p"] == nil })
    #expect(requests.last?.url?.path == "/modern/rest/ping.view")
}

@Test func subsonicStreamRejectsFailedPasswordFallback() async throws {
    let host = "rejected-fallback-subsonic.example.com"
    let session = subsonicLyricsTestSession(host: host) { _ in
        (200, Data(#"{"subsonic-response":{"status":"failed","error":{"code":41}}}"#.utf8))
    }
    defer { SubsonicLyricsURLProtocol.reset(host: host) }
    let source = MusicSource(name: "Rejected", type: .subsonic, host: host, useSsl: true, username: "u")
    let song = Song(id: "s", title: "Track", fileFormat: .flac, filePath: "/songs/track.flac", sourceID: source.id)
    let resolver = SubsonicStreamResolver(session: session)
    for _ in 0..<2 {
        await #expect(throws: StreamResolveError.authFailed) {
            try await resolver.streamURL(for: song, source: source, credential: SourceCredential(password: "p"))
        }
    }
    let requests = SubsonicLyricsURLProtocol.requests(host: host)
    #expect(requests.count == 4)
    #expect(requests.map { subsonicTestQuery($0.url!)["p"] } == [nil, "enc:70", nil, "enc:70"])
}

@Test(.timeLimit(.minutes(1)))
func subsonicStreamInvalidationCancelsAuthenticationInProgress() async throws {
    let host = "invalidated-subsonic.example.com"
    let entered = AsyncStream<Void>.makeStream()
    defer { entered.continuation.finish() }
    let session = subsonicLyricsTestSession(host: host) { _ in
        if SubsonicLyricsURLProtocol.requests(host: host).count == 1 {
            entered.continuation.yield(())
            try await Task.sleep(for: .seconds(10))
            return (200, Data(#"{"subsonic-response":{"status":"failed","error":{"code":41}}}"#.utf8))
        }
        return (200, Data(#"{"subsonic-response":{"status":"ok"}}"#.utf8))
    }
    defer { SubsonicLyricsURLProtocol.reset(host: host) }
    let source = MusicSource(name: "Invalidated", type: .subsonic, host: host, useSsl: true, username: "u")
    let song = Song(id: "s", title: "Track", fileFormat: .flac, filePath: "/songs/track.flac", sourceID: source.id)
    let resolver = SubsonicStreamResolver(session: session)
    let credential = SourceCredential(password: "p")
    let first = Task { try await resolver.streamURL(for: song, source: source, credential: credential) }
    for await _ in entered.stream { break }
    await resolver.invalidateSession(sourceID: source.id)
    await #expect(throws: (any Error).self) { try await first.value }
    let url = try await resolver.streamURL(for: song, source: source, credential: credential)
    #expect(subsonicTestQuery(url)["p"] == nil)
    let requests = SubsonicLyricsURLProtocol.requests(host: host)
    #expect(requests.count == 2)
    #expect(requests.allSatisfy { subsonicTestQuery($0.url!)["p"] == nil })
}

@Test func airsonicUsesCompatibleProtocolVersion() async throws {
    let song = Song(id: "s-air", title: "Legacy", duration: 180,
                    fileFormat: .mp3, filePath: "/songs/air1.mp3", sourceID: "src-air")
    let source = MusicSource(name: "Airsonic", type: .airsonic, host: "air.local",
                             port: 4040, useSsl: false, username: "u")
    let url = try await SubsonicStreamResolver().streamURL(
        for: song,
        source: source,
        credential: SourceCredential(password: "p")
    )
    let query = Dictionary(uniqueKeysWithValues:
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })

    #expect(query["v"] == "1.15.0")
    #expect(query["p"] == "enc:70")
    #expect(query["t"] == nil)
    #expect(query["s"] == nil)
}

@Test func subsonicMissingCredentialThrows() async {
    let song = Song(id: "s3", title: "T", fileFormat: .flac, filePath: "/songs/a.flac", sourceID: "src1")
    let source = MusicSource(name: "Navi", type: .navidrome, host: "h.com", username: "u")
    await #expect(throws: StreamResolveError.missingCredential) {
        try await SubsonicStreamResolver().streamURL(for: song, source: source, credential: nil)
    }
}

@Test(arguments: [MusicSourceType.navidrome, .subsonic])
func subsonicLyricsClientLoadsOpenSubsonicLyrics(sourceType: MusicSourceType) async throws {
    let host = "\(sourceType.rawValue)-lyrics.example.com"
    let session = subsonicLyricsTestSession(host: host) { request in
        switch request.url?.lastPathComponent {
        case "ping.view":
            return (200, Data(#"{"subsonic-response":{"status":"ok","type":"navidrome","openSubsonic":true}}"#.utf8))
        case "getLyricsBySongId.view":
            return (200, Data(#"{"subsonic-response":{"status":"ok","lyricsList":{"structuredLyrics":[{"kind":"main","synced":true,"line":[{"start":1000,"value":"Cold cache line"}]}]}}}"#.utf8))
        default:
            return (404, Data())
        }
    }
    defer { SubsonicLyricsURLProtocol.reset(host: host) }
    let source = MusicSource(
        name: "Navidrome",
        type: sourceType,
        host: host,
        port: 443,
        useSsl: true,
        username: "listener"
    )

    let result = await SubsonicLyricsClient(session: session).readLyrics(
        forSongPath: "/songs/song-42.flac",
        source: source,
        credential: SourceCredential(password: "secret")
    )

    guard case .content(let text) = result else {
        Issue.record("Expected OpenSubsonic lyrics, got \(result)")
        return
    }
    let line = try #require(LyricsContentParser.parseText(text).first)
    #expect(line.text == "Cold cache line")
    #expect(line.timestamp == 1)
    let requests = SubsonicLyricsURLProtocol.requests(host: host)
    #expect(requests.map { $0.url?.lastPathComponent } == ["ping.view", "getLyricsBySongId.view"])
    let lyricsQuery = Dictionary(uniqueKeysWithValues:
        (URLComponents(url: try #require(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    #expect(lyricsQuery["id"] == "song-42")
    #expect(lyricsQuery["enhanced"] == "true")
    #expect(requests.allSatisfy { subsonicTestQuery($0.url!)["p"] == nil })
    #expect(lyricsQuery["t"] == SubsonicStreamResolver.md5Hex("secret" + (lyricsQuery["s"] ?? "")))
}

@Test func subsonicLyricsClientLoadsAirsonicLegacyLyrics() async throws {
    let host = "airsonic-lyrics.example.com"
    let session = subsonicLyricsTestSession(host: host) { request in
        switch request.url?.lastPathComponent {
        case "ping.view":
            return (200, Data(#"{"subsonic-response":{"status":"ok","type":"airsonic","openSubsonic":false}}"#.utf8))
        case "getSong.view":
            return (200, Data(#"{"subsonic-response":{"status":"ok","song":{"title":"Legacy Song","artist":"Singer"}}}"#.utf8))
        case "getLyrics.view":
            return (200, Data(#"{"subsonic-response":{"status":"ok","lyrics":{"value":"Line one\nLine two"}}}"#.utf8))
        default:
            return (404, Data())
        }
    }
    defer { SubsonicLyricsURLProtocol.reset(host: host) }
    let source = MusicSource(
        name: "Airsonic",
        type: .airsonic,
        host: host,
        port: 443,
        useSsl: true,
        username: "listener"
    )

    let result = await SubsonicLyricsClient(session: session).readLyrics(
        forSongPath: "/songs/legacy-7.mp3",
        source: source,
        credential: SourceCredential(password: "p")
    )

    #expect(result == .content("Line one\nLine two"))
    let requests = SubsonicLyricsURLProtocol.requests(host: host)
    #expect(requests.map { $0.url?.lastPathComponent } == ["ping.view", "getSong.view", "getLyrics.view"])
    let lyricsQuery = Dictionary(uniqueKeysWithValues:
        (URLComponents(url: try #require(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    #expect(lyricsQuery["title"] == "Legacy Song")
    #expect(lyricsQuery["artist"] == "Singer")
    #expect(lyricsQuery["p"] == "enc:70")
    #expect(lyricsQuery["v"] == "1.15.0")
    #expect(lyricsQuery["t"] == nil)
}

@Test func subsonicMalformedEnhancedLyricsFallsBackToBasicLyrics() async throws {
    let host = UUID().uuidString.lowercased() + ".invalid"
    let session = subsonicLyricsTestSession(host: host) { request in
        if request.url?.lastPathComponent == "ping.view" {
            return (200, Data(#"{"subsonic-response":{"status":"ok","openSubsonic":true}}"#.utf8))
        }
        if URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "enhanced" }) == true {
            return (200, Data("invalid enhanced response".utf8))
        }
        return (200, Data(#"{"subsonic-response":{"status":"ok","lyricsList":{"structuredLyrics":[{"kind":"main","synced":true,"line":[{"start":1000,"value":"Fallback line"}]}]}}}"#.utf8))
    }
    defer { session.invalidateAndCancel(); SubsonicLyricsURLProtocol.reset(host: host) }
    let source = MusicSource(name: "fixture", type: .navidrome, host: host, useSsl: true, username: "qa")
    let result = await SubsonicLyricsClient(session: session).readLyrics(forSongPath: "/songs/test.flac", source: source, credential: .init(password: "fixture"))
    guard case .content(let text) = result else { Issue.record("Expected compatible basic lyrics"); return }
    #expect(text.contains("Fallback line"))
    #expect(SubsonicLyricsURLProtocol.requests(host: host).filter { $0.url?.lastPathComponent == "getLyricsBySongId.view" }.count == 2)
}

@Test(arguments: [403, 404, 500])
func subsonicLyricsClientDoesNotRestartHTTPBudgetForBasicLyrics(status: Int) async throws {
    let host = UUID().uuidString.lowercased() + ".invalid"
    let session = subsonicLyricsTestSession(host: host) { request in
        if request.url?.lastPathComponent == "ping.view" {
            return (200, Data(#"{"subsonic-response":{"status":"ok","openSubsonic":true}}"#.utf8))
        }
        return (status, Data())
    }
    defer { session.invalidateAndCancel(); SubsonicLyricsURLProtocol.reset(host: host) }
    let source = MusicSource(name: "Test", type: .navidrome, host: host, useSsl: true, username: "qa")
    let result = await SubsonicLyricsClient(session: session).readLyrics(forSongPath: "/songs/test.flac",
        source: source, credential: SourceCredential(password: "fixture"))
    guard case .unavailable = result else { Issue.record("A failure must not become absent lyrics"); return }
    #expect(SubsonicLyricsURLProtocol.requests(host: host).filter { $0.url?.lastPathComponent == "getLyricsBySongId.view" }.count == (status == 500 ? 3 : 1))
}

@Test(arguments: [MusicSourceType.navidrome, .subsonic])
func subsonicLyricsClientRetriesCompatibleAuthenticationAndBasicLyrics(sourceType: MusicSourceType) async throws {
    let host = "\(sourceType.rawValue)-fallback-lyrics.example.com"
    let session = subsonicLyricsTestSession(host: host) { request in
        let query = Dictionary(uniqueKeysWithValues:
            (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") })
        switch request.url?.lastPathComponent {
        case "ping.view" where query["p"] == nil:
            return (200, Data(#"{"subsonic-response":{"status":"failed","error":{"code":41,"message":"token unsupported"}}}"#.utf8))
        case "ping.view":
            return (200, Data(#"{"subsonic-response":{"status":"ok","openSubsonic":true}}"#.utf8))
        case "getLyricsBySongId.view" where query["enhanced"] == "true":
            return (200, Data(#"{"subsonic-response":{"status":"failed","error":{"code":0,"message":"unknown parameter"}}}"#.utf8))
        case "getLyricsBySongId.view":
            return (200, Data(#"{"subsonic-response":{"status":"ok","lyricsList":{"structuredLyrics":[{"kind":"main","synced":true,"line":[{"start":2500,"value":"Fallback line"}]}]}}}"#.utf8))
        default:
            return (404, Data())
        }
    }
    defer { SubsonicLyricsURLProtocol.reset(host: host) }
    let source = MusicSource(
        name: "Compatible server",
        type: sourceType,
        host: host,
        port: 443,
        useSsl: true,
        username: "listener"
    )

    let result = await SubsonicLyricsClient(session: session).readLyrics(
        forSongPath: "/songs/fallback.flac",
        source: source,
        credential: SourceCredential(password: "p")
    )

    guard case .content(let text) = result else {
        Issue.record("Expected fallback lyrics, got \(result)")
        return
    }
    #expect(LyricsContentParser.parseText(text).first?.text == "Fallback line")
    let requests = SubsonicLyricsURLProtocol.requests(host: host)
    #expect(requests.map { $0.url?.lastPathComponent } == [
        "ping.view",
        "ping.view",
        "getLyricsBySongId.view",
        "getLyricsBySongId.view",
    ])
    let finalQuery = Dictionary(uniqueKeysWithValues:
        (URLComponents(url: try #require(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    #expect(finalQuery["p"] == "enc:70")
    #expect(finalQuery["enhanced"] == nil)
}

// MARK: - 注册表

@Test func registryUnsupportedType() async {
    let song = Song(id: "s4", title: "T", fileFormat: .flac, filePath: "/x/a.flac", sourceID: "src1")
    // appleMusicLibrary 是 macOS-only,不注册任何 resolver。
    let source = MusicSource(name: "AML", type: .appleMusicLibrary, host: "h.com")
    await #expect(throws: StreamResolveError.unsupportedSourceType(.appleMusicLibrary)) {
        try await StreamResolverRegistry().streamURL(for: song, source: source, credential: nil)
    }
}

@Test func registrySupportsSubsonicFamily() async {
    let reg = StreamResolverRegistry()
    let supported = await reg.supportedTypes
    #expect(supported.isSuperset(of: [.subsonic, .navidrome, .airsonic, .gonic]))
    #expect(!supported.contains(.appleMusicLibrary))
}

private func subsonicLyricsTestSession(
    host: String,
    handler: @escaping SubsonicLyricsURLProtocol.Handler
) -> URLSession {
    SubsonicLyricsURLProtocol.configure(host: host, handler: handler)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SubsonicLyricsURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func subsonicTestQuery(_ url: URL) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") })
}

private final class SubsonicLyricsURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (statusCode: Int, body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var capturedRequests: [String: [URLRequest]] = [:]
    private let taskLock = NSLock()
    private var responseTask: Task<Void, Never>?

    static func configure(host: String, handler: @escaping Handler) {
        lock.lock()
        handlers[host] = handler
        capturedRequests[host] = []
        lock.unlock()
    }

    static func reset(host: String) {
        lock.lock()
        handlers[host] = nil
        capturedRequests[host] = nil
        lock.unlock()
    }

    static func requests(host: String) -> [URLRequest] {
        lock.lock()
        let snapshot = capturedRequests[host] ?? []
        lock.unlock()
        return snapshot
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let host = request.url?.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.capturedRequests[host, default: []].append(request)
        let handler = Self.handlers[host]
        Self.lock.unlock()

        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        taskLock.withLock {
            responseTask = Task { @Sendable [self, request] in
                do {
                    let result = try await handler(request)
                    try Task.checkCancellation()
                    guard let response = HTTPURLResponse(
                        url: url, statusCode: result.statusCode, httpVersion: "HTTP/1.1",
                        headerFields: ["Content-Type": "application/json"]
                    ) else { throw URLError(.badServerResponse) }
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: result.body)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
        }
    }

    override func stopLoading() {
        taskLock.withLock { responseTask?.cancel() }
    }
}
