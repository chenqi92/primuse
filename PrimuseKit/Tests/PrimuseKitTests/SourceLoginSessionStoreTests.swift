import Foundation
import Testing
@testable import PrimuseKit

@Suite("Shared source login session")
struct SourceLoginSessionStoreTests {
    private let account = SourceLoginSessionStore.Account(sourceID: "source", username: "qa", secret: "test")
    private let lan = SourceLoginSessionStore.Route(
        host: "192.168.0.2", port: 5666, useSSL: false, basePath: nil, variant: "address"
    )
    private let remote = SourceLoginSessionStore.Route(
        host: "nas", port: nil, useSSL: true, basePath: nil, variant: "fnConnect"
    )

    @Test func concurrentCallersOnOneRouteShareOneLogin() async throws {
        let store = SourceLoginSessionStore()
        let logins = LoginCounter()
        let login: @Sendable () async throws -> String = {
            let count = await logins.increment()
            try await Task.sleep(for: .milliseconds(50))
            return "token-\(count)"
        }
        async let first = store.token(for: account, route: lan, holder: UUID(), login: login)
        async let second = store.token(for: account, route: lan, holder: UUID(), login: login)
        let tokens = try await [first, second]
        #expect(tokens == ["token-1", "token-1"])
        #expect(await logins.count == 1)
        // 已有 token 时后来的调用方直接用，不再登录。
        #expect(try await store.token(for: account, route: remote, holder: UUID(), login: login) == "token-1")
        #expect(await logins.count == 1)
    }

    /// 卡在一条线路上的登录不拖着另一条线路的调用方一起等。
    @Test func aLoginStuckOnOneRouteDoesNotHoldBackAnotherRoute() async throws {
        let store = SourceLoginSessionStore()
        let stuck = Task {
            try await store.token(for: account, route: lan, holder: UUID()) {
                try await Task.sleep(for: .seconds(30))
                return "lan"
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let started = Date()
        let token = try await store.token(for: account, route: remote, holder: UUID()) { "remote" }
        #expect(token == "remote")
        #expect(Date().timeIntervalSince(started) < 5)
        stuck.cancel()
    }

    @Test func onlyTheCurrentTokenIsInvalidated() async throws {
        let store = SourceLoginSessionStore()
        let logins = LoginCounter()
        let login: @Sendable () async throws -> String = { "token-\(await logins.increment())" }
        #expect(try await store.token(for: account, route: lan, holder: UUID(), login: login) == "token-1")
        await store.invalidate(account, ifCurrent: "token-1")
        #expect(try await store.token(for: account, route: lan, holder: UUID(), login: login) == "token-2")
        // 另一个实例晚到的拒绝针对的是旧 token，不能把刚换上的新 token 也作废。
        await store.invalidate(account, ifCurrent: "token-1")
        #expect(try await store.token(for: account, route: lan, holder: UUID(), login: login) == "token-2")
        #expect(await logins.count == 2)
    }

    @Test func oneWaiterLeavingDoesNotCancelTheLoginOthersStillWaitFor() async throws {
        let store = SourceLoginSessionStore()
        let login: @Sendable () async throws -> String = {
            try await Task.sleep(for: .milliseconds(200))
            return "token"
        }
        let leaving = Task { try await store.token(for: account, route: lan, holder: UUID(), login: login) }
        try await Task.sleep(for: .milliseconds(20))
        let staying = Task { try await store.token(for: account, route: lan, holder: UUID(), login: login) }
        try await Task.sleep(for: .milliseconds(20))
        leaving.cancel()
        await #expect(throws: CancellationError.self) { try await leaving.value }
        #expect(try await staying.value == "token")
    }

    @Test func theLastWaiterLeavingCancelsTheLogin() async throws {
        let store = SourceLoginSessionStore()
        let observed = LoginCounter()
        let waiter = Task {
            try await store.token(for: account, route: lan, holder: UUID()) {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await observed.increment()
                    throw error
                }
                return "token"
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        for _ in 0..<100 {
            if await observed.count > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await observed.count == 1)
        // 下一个调用方重新登录，而不是拿到那次被取消的结果。
        #expect(try await store.token(for: account, route: lan, holder: UUID()) { "fresh" } == "fresh")
    }

    /// 等的是别人发起的登录、它被发起方那边取消了：自己再登录一次，而不是跟着失败。
    @Test func aJoinedLoginCancelledByItsStarterIsRetriedWithTheWaitersOwnLogin() async throws {
        let store = SourceLoginSessionStore()
        let starter = Task {
            try await store.token(for: account, route: lan, holder: UUID()) {
                try await Task.sleep(for: .milliseconds(100))
                throw CancellationError()
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let joined = try await store.token(for: account, route: lan, holder: UUID()) { "own" }
        #expect(joined == "own")
        _ = try? await starter.value
    }

    @Test func onlyTheLastHolderMayLogTheSessionOut() async throws {
        let store = SourceLoginSessionStore()
        let playback = UUID()
        let writeback = UUID()
        let logins = LoginCounter()
        let login: @Sendable () async throws -> String = { "token-\(await logins.increment())" }
        _ = try await store.token(for: account, route: lan, holder: playback, login: login)
        _ = try await store.token(for: account, route: lan, holder: writeback, login: login)

        #expect(await store.release(account, holder: writeback, token: "token-1") == false)
        #expect(try await store.token(for: account, route: lan, holder: writeback, login: login) == "token-1")
        #expect(await store.release(account, holder: writeback, token: nil) == false)
        #expect(await store.release(account, holder: playback, token: "token-1") == true)
        // 注销过的会话不再发给别人。
        #expect(try await store.token(for: account, route: lan, holder: UUID(), login: login) == "token-2")
    }

    @Test func differentCredentialsNeverShareASession() async throws {
        let store = SourceLoginSessionStore()
        let changed = SourceLoginSessionStore.Account(sourceID: "source", username: "qa", secret: "changed")
        _ = try await store.token(for: account, route: lan, holder: UUID()) { "old" }
        #expect(try await store.token(for: changed, route: lan, holder: UUID()) { "new" } == "new")
    }
}

/// Jellyfin / Emby：设备号每台设备、每个源一个；同一个源的播放与其它功能共用一次登录。
@Suite("Media server shared login")
struct MediaServerSharedLoginTests {
    @Test func deviceIDIsStablePerDeviceAndDistinctPerSourceAndDevice() throws {
        let phone = try Self.defaults()
        let television = try Self.defaults()
        defer {
            phone.suite.removePersistentDomain(forName: phone.name)
            television.suite.removePersistentDomain(forName: television.name)
        }
        let first = MediaServerDeviceIdentity.deviceID(sourceID: "jellyfin", defaults: phone.suite)
        #expect(first == MediaServerDeviceIdentity.deviceID(sourceID: "jellyfin", defaults: phone.suite))
        #expect(first.hasPrefix("primuse-"))
        #expect(first.dropFirst("primuse-".count).count == 32)
        // 源经 iCloud 同步，源 ID 在每台设备上都一样；设备号不能跟着一样。
        #expect(first != MediaServerDeviceIdentity.deviceID(sourceID: "jellyfin", defaults: television.suite))
        #expect(first != MediaServerDeviceIdentity.deviceID(sourceID: "emby", defaults: phone.suite))
        #expect(first != "primuse-jellyfin")
    }

    @Test func playbackAndAnotherClientShareOneLoginAndRenewItOnceAfterRejection() async throws {
        let host = "media-\(UUID().uuidString.lowercased()).invalid"
        MediaLoginURLProtocol.register(host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaLoginURLProtocol.self]
        let store = SourceLoginSessionStore()
        let playback = MediaServerStreamResolver(session: URLSession(configuration: config), sessionStore: store)
        let other = MediaServerStreamResolver(session: URLSession(configuration: config), sessionStore: store)
        let source = MusicSource(id: host, name: "Jellyfin", type: .jellyfin, host: host, useSsl: true, username: "user")
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/items/song.flac", sourceID: source.id)
        let credential = SourceCredential(username: "user", password: "password")

        let first = try await playback.streamURL(for: song, source: source, credential: credential)
        let adopted = try await other.streamURL(for: song, source: source, credential: credential)
        #expect(first.absoluteString.contains("ApiKey=token-1&api_key=token-1"))
        #expect(adopted.absoluteString.contains("ApiKey=token-1"))
        #expect(MediaLoginURLProtocol.logins(host: host).count == 1)

        // 播放地址被拒：播放端作废会话，重新登录一次。
        await playback.invalidateSession(sourceID: source.id)
        let renewed = try await playback.streamURL(for: song, source: source, credential: credential)
        #expect(renewed.absoluteString.contains("ApiKey=token-2"))
        // 另一方随后也被拒：作废的是旧 token，直接接手新的，不再登录。
        await other.invalidateSession(sourceID: source.id)
        let followed = try await other.streamURL(for: song, source: source, credential: credential)
        #expect(followed.absoluteString.contains("ApiKey=token-2"))

        let logins = MediaLoginURLProtocol.logins(host: host)
        #expect(logins.count == 2)
        let expectedDevice = "DeviceId=\"\(MediaServerDeviceIdentity.deviceID(sourceID: source.id))\""
        #expect(logins.allSatisfy { ($0.value(forHTTPHeaderField: "Authorization") ?? "").contains(expectedDevice) })
    }

    @Test func loginResponseUserIDTravelsWithTheSharedSession() {
        let body = Data(#"{"AccessToken":"token","User":{"Id":"user-id"}}"#.utf8)
        #expect(MediaServerStreamResolver.parseAccessToken(body) == "token")
        #expect(MediaServerStreamResolver.parseUserID(body) == "user-id")
        #expect(MediaServerStreamResolver.parseUserID(Data(#"{"AccessToken":"token"}"#.utf8)) == nil)
    }

    private static func defaults() throws -> (suite: UserDefaults, name: String) {
        let name = "MediaServerDeviceIdentityTests.\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }
}

private final class MediaLoginURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loginRequests: [String: [URLRequest]] = [:]

    static func register(host: String) { lock.withLock { loginRequests[host] = [] } }
    static func logins(host: String) -> [URLRequest] { lock.withLock { loginRequests[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              url.path.hasSuffix("/Users/AuthenticateByName") else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let count = Self.lock.withLock {
            Self.loginRequests[host, default: []].append(request)
            return Self.loginRequests[host]?.count ?? 0
        }
        let body = #"{"AccessToken":"token-\#(count)","User":{"Id":"user"}}"#
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor LoginCounter {
    private(set) var count = 0

    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}
