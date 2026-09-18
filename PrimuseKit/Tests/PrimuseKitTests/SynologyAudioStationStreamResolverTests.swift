import Foundation
import Testing
@testable import PrimuseKit

@Suite("Synology Audio Station stream resolver")
struct SynologyAudioStationStreamResolverTests {
    @Test func catalogTrackResolvesToSessionStreamURLAfterConfirmingSession() async throws {
        let fixture = ResolverFixture()
        let resolver = fixture.resolver()
        let url = try await resolver.streamURL(
            for: song("/songs/music_6906.flac"), source: fixture.source, credential: fixture.credential
        )
        #expect(url.absoluteString.hasPrefix("https://nas.example:5001/proxy/webapi/AudioStation/stream.cgi?"))
        let query = resolverFormDecode(url.query ?? "")
        #expect(query["method"] == "stream" && query["id"] == "music_6906" && query["_sid"] == "sid-1")

        // 同一个源的第二首复用客户端:不再发现接口、不再登录,但交链接前仍确认一次会话。
        _ = try await resolver.streamURL(
            for: song("/songs/music_5961.flac"), source: fixture.source, credential: fixture.credential
        )
        #expect(await fixture.logins == 1)
        let paths = await fixture.requestPaths
        #expect(paths.filter { $0.hasSuffix("/query.cgi") }.count == 1)
        #expect(paths.filter { $0.hasSuffix("/AudioStation/info.cgi") }.count == 2)
    }

    @Test func virtualCueTrackResolvesToServerTranscodedMP3() async throws {
        let fixture = ResolverFixture()
        let url = try await fixture.resolver().streamURL(
            for: song("/songs/music_v_1111.mp3"), source: fixture.source, credential: fixture.credential
        )
        #expect(url.path == "/proxy/webapi/AudioStation/stream.cgi/0.mp3")
        let query = resolverFormDecode(url.query ?? "")
        #expect(query["method"] == "transcode" && query["format"] == "mp3" && query["id"] == "music_v_1111")
    }

    @Test func clientIsReplacedWhenCredentialDeviceTokenOrSessionChanges() async throws {
        let fixture = ResolverFixture()
        let resolver = fixture.resolver()
        let track = song("/songs/music_6906.flac")
        _ = try await resolver.streamURL(for: track, source: fixture.source, credential: fixture.credential)

        _ = try await resolver.streamURL(
            for: track, source: fixture.source, credential: SourceCredential(username: "alice", password: "changed")
        )
        #expect(await fixture.logins == 2)
        #expect(await fixture.loginBodies().last?["passwd"] == "changed")

        await resolver.invalidateSession(sourceID: fixture.source.id)
        _ = try await resolver.streamURL(
            for: track, source: fixture.source, credential: SourceCredential(username: "alice", password: "changed")
        )
        #expect(await fixture.logins == 3)

        var trusted = fixture.source
        trusted.deviceId = "did-tv"
        _ = try await resolver.streamURL(for: track, source: trusted, credential: fixture.credential)
        #expect(await fixture.logins == 4)
        let body = try #require(await fixture.loginBodies().last)
        // 普通登录只带受信设备令牌,不再申请新的。
        #expect(body["device_id"] == "did-tv" && body["device_name"] == nil && body["enable_device_token"] == nil)
        #expect(await fixture.requestPaths.filter { $0.hasSuffix("/query.cgi") }.count == 4)
    }

    @Test func quickConnectRouteIsResolvedByTheClient() async throws {
        let fixture = ResolverFixture()
        let resolutions = ResolverResolutionLog()
        let resolver = fixture.resolver { id in
            await resolutions.record(id)
            return URL(string: "https://nas.example:5001/proxy")!
        }
        var routed = fixture.source
        routed.host = "my-nas"
        routed.synologyConnectionMode = .quickConnect
        routed.basePath = nil
        let url = try await resolver.streamURL(
            for: song("/songs/music_6906.flac"), source: routed, credential: fixture.credential
        )
        #expect(url.host == "nas.example" && url.path == "/proxy/webapi/AudioStation/stream.cgi")
        #expect(await resolutions.ids == ["my-nas"])
    }

    @Test func foreignTypesAndPathsAreRejectedBeforeAnyRequest() async throws {
        let fixture = ResolverFixture()
        let resolver = fixture.resolver()
        var fileStation = fixture.source
        fileStation.type = .synology
        await #expect(throws: StreamResolveError.unsupportedSourceType(.synology)) {
            try await resolver.streamURL(for: song("/songs/music_1.flac"), source: fileStation, credential: fixture.credential)
        }
        await #expect(throws: StreamResolveError.unsupportedSourceType(.synology)) {
            try await resolver.loginForDeviceToken(source: fileStation, credential: fixture.credential, otp: "123456")
        }
        for path in ["/music/a.flac", "/songs/music_/volume1/music/a.flac", "/songs/music_1.flac?_sid=x"] {
            await #expect(throws: StreamResolveError.cannotBuildURL) {
                try await resolver.streamURL(for: song(path), source: fixture.source, credential: fixture.credential)
            }
        }
        #expect(await fixture.requestPaths.isEmpty)
    }

    @Test func twoFactorSurfacesAsNeeds2FAAndOTPLoginIssuesTheDeviceToken() async throws {
        let fixture = ResolverFixture(mode: .twoFactor)
        let resolver = fixture.resolver()
        let track = song("/songs/music_6906.flac")
        await #expect(throws: StreamResolveError.needs2FA) {
            try await resolver.streamURL(for: track, source: fixture.source, credential: fixture.credential)
        }
        await #expect(throws: StreamResolveError.needs2FA) {
            try await resolver.loginForDeviceToken(source: fixture.source, credential: fixture.credential, otp: "000000")
        }

        let token = try await resolver.loginForDeviceToken(
            source: fixture.source, credential: fixture.credential, otp: "123456"
        )
        #expect(token == ResolverFixture.trustedDeviceID)
        let body = try #require(await fixture.loginBodies().last)
        #expect(body["otp_code"] == "123456" && body["enable_device_token"] == "yes")
        #expect(body["device_name"] == SynologyAudioStationStreamResolver.trustedDeviceName)
        // 验证码通过之后还确认了一次 Audio Station 权限。
        #expect(await fixture.requestPaths.last?.hasSuffix("/AudioStation/info.cgi") == true)

        // 电视端存下令牌后,同一个解析器按新的 deviceId 另建客户端,不再要验证码。
        var trusted = fixture.source
        trusted.deviceId = token
        let url = try await resolver.streamURL(for: track, source: trusted, credential: fixture.credential)
        #expect(resolverFormDecode(url.query ?? "")["id"] == "music_6906")
    }

    @Test func accountErrorsBecomeStreamErrorsAndOthersKeepTheirMeaning() async throws {
        let track = song("/songs/music_6906.flac")
        let fixture = ResolverFixture()
        await #expect(throws: StreamResolveError.missingCredential) {
            try await fixture.resolver().streamURL(
                for: track, source: fixture.source, credential: SourceCredential(username: "alice", password: "")
            )
        }
        #expect(await fixture.requestPaths.isEmpty)

        let wrong = ResolverFixture(mode: .wrongPassword)
        await #expect(throws: StreamResolveError.authFailed) {
            try await wrong.resolver().streamURL(for: track, source: wrong.source, credential: wrong.credential)
        }

        // 没有 Audio Station 权限不是账号密码的问题,原样带出去,由它自己的描述说明怎么处理。
        let denied = ResolverFixture(mode: .noPermission)
        await #expect(throws: SynologyAudioStationError.noAudioStationPermission) {
            try await denied.resolver().streamURL(for: track, source: denied.source, credential: denied.credential)
        }

        typealias Resolver = SynologyAudioStationStreamResolver
        #expect(Resolver.streamError(from: SynologyAudioStationError.badServerResponse(502)) as? StreamResolveError
                == .badServerResponse(502))
        #expect(Resolver.streamError(from: SynologyAudioStationError.invalidURL) as? StreamResolveError == .cannotBuildURL)
        #expect(Resolver.streamError(from: SynologyAudioStationError.invalidOneTimePassword) as? StreamResolveError
                == .needs2FA)
        #expect(Resolver.streamError(from: SynologyAudioStationError.serverBusy(code: 117)) as? SynologyAudioStationError
                == .serverBusy(code: 117))
        #expect((Resolver.streamError(from: URLError(.timedOut)) as? URLError)?.code == .timedOut)
        #expect(Resolver.streamError(from: CancellationError()) is CancellationError)
    }

    private func song(_ path: String) -> Song {
        Song(id: path, title: "T", fileFormat: .flac, filePath: path, sourceID: "as")
    }
}

private func resolverFormDecode(_ encoded: String) -> [String: String] {
    var values: [String: String] = [:]
    for pair in encoded.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let value = parts.count > 1 ? String(parts[1]).removingPercentEncoding ?? "" : ""
        values[String(parts[0]).removingPercentEncoding ?? ""] = value
    }
    return values
}

private actor ResolverResolutionLog {
    var ids: [String] = []
    func record(_ id: String) { ids.append(id) }
}

/// 只模拟解析器用得到的几个接口:接口发现、登录(含两步验证)与 Info。
private actor ResolverFixture {
    enum Mode: Sendable {
        case normal, twoFactor, wrongPassword, noPermission
    }

    static let trustedDeviceID = "did-new"
    static let apiInfo = #"{"data":{"SYNO.API.Auth":{"maxVersion":7,"minVersion":1,"path":"entry.cgi"},"SYNO.AudioStation.Info":{"maxVersion":6,"minVersion":1,"path":"AudioStation/info.cgi"},"SYNO.AudioStation.Song":{"maxVersion":3,"minVersion":1,"path":"AudioStation/song.cgi"},"SYNO.AudioStation.Stream":{"maxVersion":2,"minVersion":1,"path":"AudioStation/stream.cgi"}},"success":true}"#

    let mode: Mode
    private(set) var logins = 0
    private var requests: [URLRequest] = []

    init(mode: Mode = .normal) {
        self.mode = mode
    }

    nonisolated var source: MusicSource {
        MusicSource(id: "as", name: "Audio Station", type: .synologyAudioStation, host: "nas.example", port: 5001,
                    useSsl: true, username: "alice", basePath: "/proxy")
    }

    nonisolated var credential: SourceCredential {
        SourceCredential(username: "alice", password: "secret")
    }

    nonisolated func resolver(
        quickConnect: SynologyAudioStationClient.QuickConnectResolver? = nil
    ) -> SynologyAudioStationStreamResolver {
        SynologyAudioStationStreamResolver(
            transport: SynologyAudioStationRequestTransport(
                data: { try await self.reply($0) },
                download: { _ in throw URLError(.unsupportedURL) }
            ),
            quickConnectResolver: quickConnect
        )
    }

    var requestPaths: [String] { requests.compactMap { $0.url?.path } }

    func loginBodies() -> [[String: String]] {
        requests.filter { $0.url?.path.hasSuffix("/auth.cgi") == true }
            .map { resolverFormDecode(String(decoding: $0.httpBody ?? Data(), as: UTF8.self)) }
    }

    func reply(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard let url = request.url, url.path.hasPrefix("/proxy/webapi/") else { throw URLError(.unsupportedURL) }
        switch String(url.path.dropFirst("/proxy/webapi/".count)) {
        case "query.cgi":
            return json(url, Self.apiInfo)
        case "auth.cgi":
            logins += 1
            let params = resolverFormDecode(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
            if mode == .wrongPassword {
                return json(url, #"{"error":{"code":400},"success":false}"#)
            }
            if mode == .twoFactor, params["device_id"] != Self.trustedDeviceID {
                switch params["otp_code"] {
                case nil:
                    return json(url, #"{"error":{"code":403,"errors":{"token":"otp-token","types":[{"type":"otp"}]}},"success":false}"#)
                case "000000":
                    return json(url, #"{"error":{"code":404},"success":false}"#)
                default:
                    break
                }
            }
            let did = params["enable_device_token"] == "yes" ? #","did":"\#(Self.trustedDeviceID)""# : ""
            return json(url, #"{"data":{"sid":"sid-\#(logins)"\#(did)},"success":true}"#)
        case "AudioStation/info.cgi":
            if mode == .noPermission {
                return json(url, #"{"error":{"code":105},"success":false}"#)
            }
            return json(url, #"{"data":{"transcode_capability":["mp3"],"version_string":"7.2.0-5516"},"success":true}"#)
        default:
            throw URLError(.unsupportedURL)
        }
    }

    private func json(_ url: URL, _ body: String) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json; charset=utf-8"])!
        return (Data(body.utf8), response)
    }
}
