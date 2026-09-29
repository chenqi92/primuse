import Foundation
import Testing
@testable import PrimuseKit

@Suite("Feiniu library and session recovery")
struct FnMusicLibraryTests {
    /// 歌单索引照网页端那样一次请求、不带分页参数；歌单内曲目仍按页翻。
    @Test func playlistIndexIsFetchedOnceAndTracksArePaged() async throws {
        let fixture = FnMusicLibraryFixture()
        let summaries = (0..<51).map { ["guid": "p\($0)", "name": "List \($0)", "trackCount": $0 == 0 ? 51 : 0] as [String: Any] }
        fixture.setPage("/playlist/list", page: 1, list: summaries, total: 51)
        for i in 0..<51 {
            fixture.setPage("/track/playlist-detail/list", playlist: "p\(i)", page: 1, list: [], total: 0)
        }
        fixture.setPage("/track/playlist-detail/list", playlist: "p0", page: 1,
                        list: (0..<50).map { ["guid": "s\($0)"] }, total: 51)
        fixture.setPage("/track/playlist-detail/list", playlist: "p0", page: 2,
                        list: [["guid": "s50"]], total: 51)
        fixture.setPage("/track/playlist-detail/list", playlist: "p1", page: 1,
                        list: [["guid": "unexpected"]], total: 1)
        let (client, _, _) = fixture.clients()
        let snapshot = try await client.library.playlists()
        #expect(snapshot.failedPlaylistIDs == ["p1"])
        #expect(snapshot.playlists.map(\.id) == ["p0"] + (2..<51).map { "p\($0)" })
        #expect(snapshot.playlists.first?.trackIDs == (0..<51).map { "s\($0)" })
        #expect(snapshot.playlists.last?.trackIDs.isEmpty == true)
        #expect(fixture.requests.allSatisfy { request in
            request.url?.path.hasSuffix("password-login") == true
                || request.value(forHTTPHeaderField: "Cookie") != nil
        })
        #expect(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "authx") != nil })
        let indexRequests = fixture.requests.filter { $0.url?.path.hasSuffix("/playlist/list") == true }
        #expect(indexRequests.count == 1)
        #expect((indexRequests.first?.url?.query ?? "").isEmpty, "索引请求不带 page/size")
        // p1 每次都读不全：第一轮失败后补读一次，仍失败才记进 failedPlaylistIDs。
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("/track/playlist-detail/list") == true }.count == 53)
    }

    /// 明细翻到一半失败的歌单在同一次同步里补读一次，不再整份漏掉；顺序仍按服务端清单。
    @Test func playlistDetailsThatFailOnceAreReadAgainInTheSameSync() async throws {
        let fixture = FnMusicLibraryFixture(transientDetailFailures: ["p1": 1])
        fixture.setPage("/playlist/list", page: 1,
                        list: (0..<3).map { ["guid": "p\($0)", "name": "List \($0)"] }, total: 3)
        for i in 0..<3 {
            fixture.setPage("/track/playlist-detail/list", playlist: "p\(i)", page: 1,
                            list: [["guid": "s\(i)"]], total: 1)
        }
        let (client, _, _) = fixture.clients()
        let snapshot = try await client.library.playlists()
        #expect(snapshot.failedPlaylistIDs.isEmpty)
        #expect(snapshot.playlists.map(\.id) == ["p0", "p1", "p2"])
        #expect(snapshot.playlists.map(\.trackIDs) == [["s0"], ["s1"], ["s2"]])
        let details = fixture.requests.filter { $0.url?.path.hasSuffix("/track/playlist-detail/list") == true }
        #expect(details.count == 4)
    }

    /// 每读全一个歌单就先交出去，不等整轮：补读成功的在第二轮交出，始终读不全的不交。
    @Test func playlistsAreHandedOverAsSoonAsEachOneIsRead() async throws {
        let fixture = FnMusicLibraryFixture(transientDetailFailures: ["p1": 1])
        fixture.setPage("/playlist/list", page: 1,
                        list: (0..<4).map { ["guid": "p\($0)", "name": "List \($0)"] }, total: 4)
        for i in [0, 1, 3] {
            fixture.setPage("/track/playlist-detail/list", playlist: "p\(i)", page: 1,
                            list: [["guid": "s\(i)"]], total: 1)
        }
        fixture.setPage("/track/playlist-detail/list", playlist: "p2", page: 1,
                        list: [["guid": "unexpected"]], total: 2)
        let (client, _, _) = fixture.clients()
        let delivered = DeliveredPlaylists()
        let snapshot = try await client.library.playlists { await delivered.append($0) }
        #expect(await delivered.ids == ["p0", "p3", "p1"])
        #expect(await delivered.trackIDs == [["s0"], ["s3"], ["s1"]])
        #expect(snapshot.playlists.map(\.id) == ["p0", "p1", "p3"])
        #expect(snapshot.failedPlaylistIDs == ["p2"])
    }

    /// 飞牛同一个 deviceId 只认最后一次登录。曲库客户端与播放解析器以前各存各的 token，
    /// 谁登录都会让对方 401、再重新登录把对方挤掉；现在两边共用一次登录。
    @Test func libraryClientAndStreamResolverShareOneLogin() async throws {
        let fixture = FnMusicLibraryFixture(enforcesDeviceSessions: true, favorites: ["s0"])
        let (client, resolver, source) = fixture.clients()
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/fnmusic/tracks/song.flac", sourceID: source.id)
        let credential = SourceCredential(username: "qa", password: "test")

        #expect(try await client.library.favorites() == ["s0"])
        let resolved = try await resolver.resolve(for: song, source: source, credential: credential)
        #expect(resolved.headers["Cookie"] == "music-token=token-1")
        #expect(try await client.library.favorites() == ["s0"])
        _ = try await resolver.resolve(for: song, source: source, credential: credential)

        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("password-login") == true }.count == 1)
        #expect(fixture.unauthorizedCount == 0)
    }

    /// 两边同时第一次用到时也只登录一次。
    @Test func concurrentFirstUseByLibraryAndPlaybackLogsInOnce() async throws {
        let fixture = FnMusicLibraryFixture(enforcesDeviceSessions: true, favorites: ["s0"])
        let (client, resolver, source) = fixture.clients()
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/fnmusic/tracks/song.flac", sourceID: source.id)
        async let favorites = client.library.favorites()
        async let resolved = resolver.resolve(for: song, source: source, credential: .init(username: "qa", password: "test"))
        _ = try await (favorites, resolved)
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("password-login") == true }.count == 1)
        #expect(fixture.unauthorizedCount == 0)
    }

    /// 会话在服务端过期后，先发现的一方重新登录一次，另一方被拒后直接改用新的 token，
    /// 不会再各自登录、来回挤掉对方。登录始终用同一个设备号。
    @Test func expiredSharedSessionIsRenewedOnceAndAdoptedByTheOtherClient() async throws {
        let fixture = FnMusicLibraryFixture(enforcesDeviceSessions: true, favorites: ["s0"])
        let (client, resolver, source) = fixture.clients()
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/fnmusic/tracks/song.flac", sourceID: source.id)
        let credential = SourceCredential(username: "qa", password: "test")

        #expect(try await client.library.favorites() == ["s0"])
        _ = try await resolver.resolve(for: song, source: source, credential: credential)
        fixture.expireSessions()

        let renewed = try await resolver.resolve(for: song, source: source, credential: credential)
        #expect(renewed.headers["Cookie"] == "music-token=token-2")
        #expect(try await client.library.favorites() == ["s0"])
        _ = try await resolver.resolve(for: song, source: source, credential: credential)

        let logins = fixture.requests.filter { $0.url?.path.hasSuffix("password-login") == true }
        #expect(logins.count == 2)
        #expect(fixture.unauthorizedCount == 2)
        let deviceIDs = try logins.map { request -> String in
            let body = try JSONSerialization.jsonObject(with: FnMusicLibraryFixture.body(request)) as? [String: Any]
            return try #require(body?["deviceId"] as? String)
        }
        #expect(Set(deviceIDs).count == 1)
    }

    /// 服务端照单全给、条数正好是 50 的整数倍时，以前会再翻一页拿到同一批歌单而报「重复项」。
    @Test func playlistIndexWithExactlyOnePageOfEntriesDoesNotRequestASecondPage() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setRawPage("/playlist/list", page: 1,
                           data: ["list": (0..<50).map { ["guid": "p\($0)", "name": "List \($0)"] }])
        fixture.setRawPage("/playlist/list", page: 2,
                           data: ["list": (0..<50).map { ["guid": "p\($0)", "name": "List \($0)"] }])
        for i in 0..<50 {
            fixture.setRawPage("/track/playlist-detail/list", playlist: "p\(i)", page: 1, data: ["list": NSNull(), "total": 0])
        }
        let (client, _, _) = fixture.clients()
        let snapshot = try await client.library.playlists()
        #expect(snapshot.playlists.count == 50)
        #expect(snapshot.failedPlaylistIDs.isEmpty)
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("/playlist/list") == true }.count == 1)
    }

    @Test func incompletePlaylistIndexCannotBecomeAnEmptyAuthoritativeSnapshot() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setPage("/playlist/list", page: 1, list: [], total: 1)
        let (client, _, _) = fixture.clients()
        await #expect(throws: FnMusicServiceError.self) { try await client.library.playlists() }
    }

    @Test func playlistTrackRepetitionsRetainServerOrder() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setPage("/playlist/list", page: 1,
                        list: [["guid": "p", "name": "我喜欢", "trackCount": 3, "coverId": "cover", "updatedAt": 42]], total: 1)
        fixture.setPage("/track/playlist-detail/list", playlist: "p", page: 1,
                        list: [["guid": "b"], ["guid": "a"], ["guid": "b"]], total: 3)
        let (client, _, _) = fixture.clients()
        let playlist = try #require(try await client.library.playlists().playlists.first)
        #expect(playlist.trackIDs == ["b", "a", "b"])
        #expect(playlist.coverReference == "fnmusic-cover/cover?revision=42")
    }

    @Test func favoriteWritesAreIdempotentAndConfirmedAcrossAllPages() async throws {
        let fixture = FnMusicLibraryFixture(favorites: (0..<51).map { "s\($0)" })
        let (client, _, _) = fixture.clients()
        #expect(try await client.library.favorites().count == 51)
        #expect(try await client.library.setFavorite(trackID: "new.track", isFavorite: true).contains("new.track"))
        _ = try await client.library.setFavorite(trackID: "new.track", isFavorite: true)
        #expect(try await !client.library.setFavorite(trackID: "new.track", isFavorite: false).contains("new.track"))
        _ = try await client.library.setFavorite(trackID: "new.track", isFavorite: false)
        let writes = fixture.requests.filter { $0.url?.path.contains("/favorite-track/") == true && $0.httpMethod == "POST" }
        #expect(writes.map { $0.url!.lastPathComponent } == ["create", "delete"])
        for write in writes {
            let object = try JSONSerialization.jsonObject(with: FnMusicLibraryFixture.body(write)) as? [String: String]
            #expect(object == ["trackGUID": "new.track"])
        }
    }

    @Test func malformedFavoritesAndUnconfirmedWritesFailClosed() async throws {
        let malformed = FnMusicLibraryFixture()
        malformed.setPage("/favorite-track/list", page: 1, list: [["guid": "a"], ["guid": "a"]], total: 2)
        let (reader, _, _) = malformed.clients()
        await #expect(throws: FnMusicServiceError.self) { try await reader.library.favorites() }
        let rejected = FnMusicLibraryFixture(ignoresFavoriteWrites: true)
        let (writer, _, _) = rejected.clients()
        await #expect(throws: FnMusicServiceError.self) {
            try await writer.library.setFavorite(trackID: "new", isFavorite: true)
        }
        let before = rejected.requests.count
        await #expect(throws: FnMusicServiceError.self) {
            try await writer.library.setFavorite(trackID: "nested/song", isFavorite: true)
        }
        #expect(rejected.requests.count == before)
    }

    /// 飞牛把空集合序列化成 null（`{"list":null,"total":0}`），命令类接口甚至整个 data 为 null。
    /// 以前这两种都被判成「响应不是有效的飞牛音乐 JSON」，歌单与收藏同步三天没成功过一次。
    @Test func emptyServerCollectionsArriveAsNullListsOrNullData() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setRawPage("/favorite-track/list", page: 1, data: ["list": NSNull(), "total": 0])
        fixture.setRawPage("/playlist/list", page: 1, data: NSNull())
        let (client, _, _) = fixture.clients()
        #expect(try await client.library.favorites().isEmpty)
        let snapshot = try await client.library.playlists()
        #expect(snapshot.playlists.isEmpty)
        #expect(snapshot.failedPlaylistIDs.isEmpty)
    }

    /// 没有 total 时短页就是末页；歌单清单不分页、一次全给，条数可以超过我们请求的 size。
    @Test func listsWithoutTotalEndAtTheFirstShortPage() async throws {
        let fixture = FnMusicLibraryFixture()
        fixture.setRawPage("/favorite-track/list", page: 1, data: ["list": (0..<50).map { ["guid": "s\($0)"] }])
        fixture.setRawPage("/favorite-track/list", page: 2, data: ["list": [["guid": "s50"]]])
        fixture.setRawPage("/playlist/list", page: 1,
                           data: ["list": (0..<60).map { ["guid": "p\($0)", "name": "List \($0)"] }])
        for i in 0..<60 {
            fixture.setRawPage("/track/playlist-detail/list", playlist: "p\(i)", page: 1, data: ["list": NSNull(), "total": 0])
        }
        let (client, _, _) = fixture.clients()
        #expect(try await client.library.favorites() == (0..<51).map { "s\($0)" })
        let snapshot = try await client.library.playlists()
        #expect(snapshot.playlists.map(\.id) == (0..<60).map { "p\($0)" })
        #expect(snapshot.playlists.allSatisfy { $0.trackIDs.isEmpty })
        #expect(snapshot.failedPlaylistIDs.isEmpty)
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("/playlist/list") == true }.count == 1)
    }

    /// 带 total 的清单一次给全也照收；说了 total 却给了短页、list 不是数组、没有 total 又
    /// 永远返回同一满页，仍然是坏响应而不是被当成空集合或无限翻页。
    @Test func completeUnpagedListsAreAcceptedAndBrokenPagesStillFailClosed() async throws {
        let whole = FnMusicLibraryFixture()
        whole.setPage("/playlist/list", page: 1,
                      list: (0..<60).map { ["guid": "p\($0)", "name": "List \($0)"] }, total: 60)
        for i in 0..<60 {
            whole.setPage("/track/playlist-detail/list", playlist: "p\(i)", page: 1, list: [], total: 0)
        }
        let (reader, _, _) = whole.clients()
        #expect(try await reader.library.playlists().playlists.count == 60)

        let short = FnMusicLibraryFixture()
        short.setRawPage("/favorite-track/list", page: 1, data: ["list": NSNull(), "total": 3])
        let (shortReader, _, _) = short.clients()
        await #expect(throws: FnMusicServiceError.self) { try await shortReader.library.favorites() }

        let malformed = FnMusicLibraryFixture()
        malformed.setRawPage("/favorite-track/list", page: 1, data: ["list": "nope"])
        let (malformedReader, _, _) = malformed.clients()
        await #expect(throws: FnMusicServiceError.self) { try await malformedReader.library.favorites() }

        let looping = FnMusicLibraryFixture()
        let full = (0..<50).map { ["guid": "s\($0)"] }
        looping.setRawPage("/favorite-track/list", page: 1, data: ["list": full])
        looping.setRawPage("/favorite-track/list", page: 2, data: ["list": full])
        let (loopingReader, _, _) = looping.clients()
        await #expect(throws: FnMusicServiceError.self) { try await loopingReader.library.favorites() }
        #expect(looping.requests.filter { $0.url?.path.hasSuffix("/favorite-track/list") == true }.count == 2)
    }

    @Test(arguments: [99999, 120001, 401, 403])
    func streamBusinessAuthenticationErrorsRefreshExactlyOnce(code: Int) async throws {
        let fixture = FnMusicLibraryFixture(streamError: code)
        let (_, resolver, source) = fixture.clients()
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/fnmusic/tracks/song.flac", sourceID: source.id)
        let resolved = try await resolver.resolve(for: song, source: source, credential: .init(username: "qa", password: "test"))
        #expect(resolved.headers["Cookie"] == "music-token=token-2")
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("password-login") == true }.count == 2)
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("track/stream") == true }.count == 2)
    }

    @Test func ordinaryHTTP200MediaErrorsDoNotCauseRepeatedLogins() async throws {
        let fixture = FnMusicLibraryFixture(streamError: 500)
        let (_, resolver, source) = fixture.clients()
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/fnmusic/tracks/song.flac", sourceID: source.id)
        await #expect(throws: StreamResolveError.badServerResponse(200)) {
            try await resolver.resolve(for: song, source: source, credential: .init(username: "qa", password: "test"))
        }
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("password-login") == true }.count == 1)
    }
}

private final class FnMusicLibraryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let host = UUID().uuidString.lowercased() + ".invalid"
    private var pages: [String: Data] = [:]
    private var favorites: [String]
    private let ignoresFavoriteWrites: Bool
    private let streamError: Int?
    /// 照真服务端的行为：同一个 deviceId 再登录一次，之前发出去的 token 就 401。
    private let enforcesDeviceSessions: Bool
    private var tokenByDevice: [String: String] = [:]
    private var unauthorized = 0
    private var transientDetailFailures: [String: Int]
    private var loginCount = 0
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    var unauthorizedCount: Int { lock.withLock { unauthorized } }
    /// 模拟服务端会话过期：之前发出的 token 全部作废。
    func expireSessions() { lock.withLock { tokenByDevice.removeAll() } }

    init(
        enforcesDeviceSessions: Bool = false,
        transientDetailFailures: [String: Int] = [:],
        favorites: [String] = [],
        ignoresFavoriteWrites: Bool = false,
        streamError: Int? = nil
    ) {
        self.enforcesDeviceSessions = enforcesDeviceSessions
        self.transientDetailFailures = transientDetailFailures
        self.favorites = favorites
        self.ignoresFavoriteWrites = ignoresFavoriteWrites
        self.streamError = streamError
    }

    func setPage(_ path: String, playlist: String = "", page: Int, list: [[String: Any]], total: Int) {
        lock.withLock { pages["\(path)|\(playlist)|\(page)"] = Self.json(["code": 0, "data": ["list": list, "total": total]]) }
    }

    /// 原样塞一个 `data`：用来摆服务端真实会给的形状（`list: null`、整个 data 为 null、没有 total）。
    func setRawPage(_ path: String, playlist: String = "", page: Int, data: Any) {
        lock.withLock { pages["\(path)|\(playlist)|\(page)"] = Self.json(["code": 0, "data": data]) }
    }

    func clients() -> (FnMusicServiceClient, FnMusicStreamResolver, MusicSource) {
        FnMusicLibraryURLProtocol.register(self, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FnMusicLibraryURLProtocol.self]
        let session = URLSession(configuration: config)
        let source = MusicSource(id: host, name: "Feiniu", type: .fnMusic, host: host, port: 5666, useSsl: false, username: "qa")
        // 和真机一样，曲库客户端与播放解析器共用同一个会话仓库。
        let sessions = SourceLoginSessionStore()
        return (FnMusicServiceClient(source: source, credential: .init(username: "qa", password: "test"),
                                     session: session, sessionStore: sessions),
                FnMusicStreamResolver(session: URLSession(configuration: config), sessionStore: sessions), source)
    }

    func response(_ request: URLRequest) -> (Int, [String: String], Data) {
        lock.withLock {
            var saved = request
            if request.httpMethod == "POST" { saved.httpBody = Self.body(request) }
            recorded.append(saved)
            let path = request.url!.path.replacingOccurrences(of: FnMusicAPIProtocol.apiPath, with: "")
            let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            let headers = ["Content-Type": "application/json"]
            if path == "/user/password-login" {
                loginCount += 1
                let token = "token-\(loginCount)"
                if let body = try? JSONSerialization.jsonObject(with: saved.httpBody ?? Data()) as? [String: Any],
                   let device = body["deviceId"] as? String {
                    tokenByDevice[device] = token
                }
                return (200, headers, Self.json(["code": 200, "data": ["userToken": token]]))
            }
            if enforcesDeviceSessions {
                let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
                let token = cookie.components(separatedBy: "; ").first { $0.hasPrefix("music-token=") }
                    .map { String($0.dropFirst("music-token=".count)) }
                guard let token, tokenByDevice.values.contains(token) else {
                    unauthorized += 1
                    return (401, headers, Data())
                }
            }
            if path == "/track/playlist-detail/list", let playlist = query["playlistGUID"],
               let remaining = transientDetailFailures[playlist], remaining > 0 {
                transientDetailFailures[playlist] = remaining - 1
                return (500, headers, Data())
            }
            if path == "/track/stream" {
                if let streamError, loginCount == 1 {
                    return (200, headers, Self.json(["code": String(streamError), "msg": "INVALID TOKEN"]))
                }
                return (206, ["Content-Type": "audio/flac", "Content-Range": "bytes 0-1/8", "Content-Length": "2"], Data([1, 2]))
            }
            let page = Int(query["page"] ?? "1") ?? 1
            if let payload = pages["\(path)|\(query["playlistGUID"] ?? "")|\(page)"] { return (200, headers, payload) }
            if path == "/favorite-track/list" {
                let start = min((page - 1) * 50, favorites.count)
                let ids = favorites.dropFirst(start).prefix(50).map { ["guid": $0] }
                return (200, headers, Self.json(["code": 0, "data": ["list": ids, "total": favorites.count]]))
            }
            if path == "/favorite-track/create" || path == "/favorite-track/delete" {
                if !ignoresFavoriteWrites,
                   let body = try? JSONSerialization.jsonObject(with: saved.httpBody ?? Data()) as? [String: String],
                   let id = body["trackGUID"] {
                    favorites.removeAll { $0 == id }
                    if path.hasSuffix("create") { favorites.append(id) }
                }
                return (200, headers, Self.json(["code": 0, "data": NSNull()]))
            }
            return (404, headers, Data())
        }
    }

    static func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class FnMusicLibraryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: FnMusicLibraryFixture] = [:]
    static func register(_ fixture: FnMusicLibraryFixture, host: String) { lock.withLock { fixtures[host] = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, headers, data) = fixture.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor DeliveredPlaylists {
    private(set) var ids: [String] = []
    private(set) var trackIDs: [[String]] = []

    func append(_ playlist: FnMusicPlaylist) {
        ids.append(playlist.id)
        trackIDs.append(playlist.trackIDs)
    }
}
