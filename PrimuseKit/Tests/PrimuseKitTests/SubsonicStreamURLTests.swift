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
    let song = Song(id: "s2", title: "Old", duration: 180,
                    fileFormat: .wma, filePath: "/songs/old1.wma", sourceID: "src1")
    let source = MusicSource(name: "Navi", type: .subsonic, host: "h.com",
                             port: 4533, useSsl: false, username: "u")
    let url = try await SubsonicStreamResolver().streamURL(for: song, source: source,
                                                           credential: SourceCredential(password: "p"))
    let q = Dictionary(uniqueKeysWithValues:
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    #expect(q["format"] == "mp3")
    #expect(q["maxBitRate"] == "320")
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
