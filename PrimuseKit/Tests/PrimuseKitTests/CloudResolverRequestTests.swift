import Foundation
import Testing
@testable import PrimuseKit

@Suite("Cloud resolver request quotas", .serialized, .timeLimit(.minutes(1)))
struct CloudResolverRequestTests {
    @Test(arguments: [MusicSourceType.oneDrive, .baiduPan])
    func invalidatedSharedRefreshReportsAuthenticationInsteadOfCallerCancellation(type: MusicSourceType) async throws {
        let scenario = CloudRefreshScenario(firstSucceeds: true)
        let fixture = CloudResolverFixture { try await scenario.reply($0) }
        let source = MusicSource(id: UUID().uuidString, name: "fixture", type: type)
        let credential = SourceCredential(token: "old", refreshToken: "refresh", clientID: "client")
        let cloud = CloudDriveStreamResolver(session: fixture.session, quotaRegistry: fixture.registry)
        let baidu = BaiduPanStreamResolver(session: fixture.session, quotaRegistry: fixture.registry)
        let request = Task {
            if type == .oneDrive {
                _ = try await cloud.listDirectory(source: source, credential: credential, path: "/")
            } else {
                let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/track.flac", sourceID: source.id)
                _ = try await baidu.resolve(for: song, source: source, credential: credential)
            }
        }
        try await scenario.waitForRefresh()
        if type == .oneDrive { await cloud.invalidateSession(sourceID: source.id) }
        else { await baidu.invalidateSession(sourceID: source.id) }
        // Release the deliberately held fixture response; invalidation has
        // already cancelled the shared task before it can publish that token.
        await scenario.releaseRefresh()
        do { try await request.value; Issue.record("Expected session invalidation") }
        catch { #expect((error as? URLError)?.code == .userAuthenticationRequired) }
        #expect(!request.isCancelled)
        #expect(await scenario.refreshes == 1, "Invalidation must not silently restart an old credential's refresh")
    }

    @Test(arguments: [MusicSourceType.oneDrive, .baiduPan], [false, true])
    func cancelledRefreshOwnerCannotPoisonLaterRequests(type: MusicSourceType, succeeds: Bool) async throws {
        let scenario = CloudRefreshScenario(firstSucceeds: succeeds)
        let fixture = CloudResolverFixture { try await scenario.reply($0) }
        let source = MusicSource(id: UUID().uuidString, name: "fixture", type: type)
        let credential = SourceCredential(token: "old", refreshToken: "refresh", clientID: "client")
        let cloud = CloudDriveStreamResolver(session: fixture.session, quotaRegistry: fixture.registry)
        let baidu = BaiduPanStreamResolver(session: fixture.session, quotaRegistry: fixture.registry)
        let read: @Sendable () async throws -> Void = {
            if type == .oneDrive {
                _ = try await cloud.listDirectory(source: source, credential: credential, path: "/")
            } else {
                let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/track.flac", sourceID: source.id)
                _ = try await baidu.resolve(for: song, source: source, credential: credential)
            }
        }
        let owner = Task { try await read() }
        try await scenario.waitForRefresh()
        owner.cancel()
        do { try await owner.value; Issue.record("Expected caller cancellation") }
        catch is CancellationError { }
        await scenario.releaseRefresh()
        // This observer may join the finishing task; after it finishes, subsequent
        // reads must never inherit its error or reuse a completed forced refresh.
        _ = try? await read()
        await scenario.rejectFirstToken()
        try await read()
        #expect(await scenario.refreshes == 2)
    }

    @Test func accountCooldownSurvivesMountIdentityChanges() async throws {
        let fixture = CloudResolverFixture { _ in (429, ["Retry-After": "3600"], Data()) }
        let account = UUID().uuidString
        for _ in 0..<2 {
            let source = MusicSource(id: UUID().uuidString, name: "Mount", type: .oneDrive, cloudAccountID: account)
            do {
                _ = try await CloudDriveStreamResolver(session: fixture.session, quotaRegistry: fixture.registry).listDirectory(source: source, credential: .init(token: "fixture"), path: "/")
                Issue.record("Expected cooldown")
            } catch let failure as HTTPResponseFailure { #expect(failure.statusCode == 429) }
        }
        #expect(fixture.requests.count == 1)
    }

    @Test func headerless503RecoversWithoutInventingThirtySecondCooldown() async throws {
        let replies = CloudTransientReplies()
        let fixture = CloudResolverFixture { _ in await replies.next() }
        let source = MusicSource(id: UUID().uuidString, name: "fixture", type: .oneDrive)
        let result = try await CloudDriveStreamResolver(session: fixture.session, quotaRegistry: fixture.registry).listDirectory(source: source, credential: .init(token: "fixture"), path: "/")
        #expect(result.isEmpty)
        #expect(fixture.requests.count == 2)
    }

    @Test func guangyaBusinessCooldownIsSharedAcrossAccounts() async throws {
        let requests = CloudResolverRequests(registry: RequestQuotaRegistry())
        let count = CloudSendCount()
        let url = try #require(GuangYaAPIProtocol.downloadURL(fileID: "fixture"))
        for _ in 0..<2 {
            let source = MusicSource(id: UUID().uuidString, name: "fixture", type: .guangya)
            do {
                let _: Data = try await requests.execute(url: url, account: .init(source: source, credential: .init(token: "fixture")), operation: {
                    await count.sent()
                    throw HTTPResponseFailure(statusCode: 429, retryAfter: 3600)
                })
                Issue.record("Expected shared IP cooldown")
            } catch let failure as HTTPResponseFailure { #expect((failure.retryAfter ?? 0) > 3590) }
        }
        #expect(await count.value == 1)
    }

    @Test(arguments: [429, 503])
    func directoryReadersShareCooldownAcrossResolverInstances(status: Int) async throws {
        let fixture = CloudResolverFixture { _ in (status, ["Retry-After": "3600"], Data()) }
        let source = MusicSource(id: UUID().uuidString, name: "OneDrive", type: .oneDrive)
        let credential = SourceCredential(token: "fixture")
        for _ in 0..<2 {
            do {
                _ = try await CloudDriveStreamResolver(session: fixture.session, quotaRegistry: fixture.registry).listDirectory(source: source, credential: credential, path: "/")
                Issue.record("Expected quota failure")
            } catch let failure as HTTPResponseFailure {
                #expect(failure.statusCode == status)
                #expect((failure.retryAfter ?? 0) > 3590)
            } catch { Issue.record("Lost HTTP response: \(error)") }
        }
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: [429, 503, 200])
    func baiduRetainsHTTPAndBusinessQuota(status: Int) async throws {
        let fixture = CloudResolverFixture { _ in
            (status, ["Retry-After": "3600"], Data(#"{"errno":31034}"#.utf8))
        }
        let source = MusicSource(id: UUID().uuidString, name: "Baidu", type: .baiduPan)
        let song = Song(id: "track", title: "Track", fileFormat: .flac, filePath: "/music/track.flac", sourceID: source.id)
        for _ in 0..<2 {
            do {
                _ = try await BaiduPanStreamResolver(session: fixture.session, quotaRegistry: fixture.registry).resolve(for: song, source: source, credential: .init(token: "fixture"))
                Issue.record("Expected quota failure")
            } catch let failure as HTTPResponseFailure {
                #expect(failure.statusCode == status)
                #expect((failure.retryAfter ?? 0) > 3590)
                if status == 200 { #expect(failure.isRateLimited) }
            } catch { Issue.record("Lost Baidu quota: \(error)") }
        }
        #expect(fixture.requests.count == 1)
    }

    @Test func authenticationRecoveryUsesTheSameReadAttemptBudget() async throws {
        let fixture = CloudResolverFixture { request in
            if request.url?.host == "login.microsoftonline.com" {
                return (200, [:], Data(#"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#.utf8))
            }
            return (request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh" ? 500 : 401, [:], Data())
        }
        let source = MusicSource(id: UUID().uuidString, name: "OneDrive", type: .oneDrive)
        do {
            _ = try await CloudDriveStreamResolver(session: fixture.session, quotaRegistry: fixture.registry).listDirectory(source: source,
                credential: .init(token: "expired", refreshToken: "refresh", clientID: "client"), path: "/")
            Issue.record("Expected exhausted HTTP budget")
        } catch let failure as HTTPResponseFailure { #expect(failure.statusCode == 500) }
        #expect(fixture.requests.filter { $0.url?.host == "graph.microsoft.com" }.count == 5)
        #expect(fixture.requests.filter { $0.url?.host == "login.microsoftonline.com" }.count == 1)
    }

    @Test func pan123BusinessQuotaUsesTheDefaultSharedCooldown() async throws {
        let fixture = CloudResolverFixture { request in
            if request.url?.path.hasSuffix("access_token") == true {
                return (200, [:], Data(#"{"code":0,"data":{"accessToken":"fixture"}}"#.utf8))
            }
            return (200, [:], Data(#"{"code":429,"message":"limited"}"#.utf8))
        }
        let source = MusicSource(id: UUID().uuidString, name: "123", type: .pan123)
        let song = Song(id: "track", title: "Track", fileFormat: .flac, filePath: "123", sourceID: source.id)
        for _ in 0..<2 {
            do {
                _ = try await CloudDriveStreamResolver(session: fixture.session, quotaRegistry: fixture.registry).streamURL(for: song, source: source,
                    credential: .init(clientID: "client", clientSecret: "fixture"))
                Issue.record("Expected business quota failure")
            } catch let failure as HTTPResponseFailure {
                #expect(failure.statusCode == 200); #expect(failure.isRateLimited)
            } catch { Issue.record("Business quota was lost: \(error)") }
        }
        #expect(fixture.requests.filter { $0.url?.path.hasSuffix("access_token") == true }.count == 1)
        #expect(fixture.requests.count == 6, "Five read attempts, then the next caller is deferred before issuing another token")
        #expect(fixture.times[2] - fixture.times[1] >= 2, "The default cooldown is shared and never shortened")
    }

    @Test(arguments: [MusicSourceType.oneDrive, .baiduPan], [111, -6])
    func forbiddenOrBaiduErrnoRefreshesOnce(type: MusicSourceType, errno: Int) async throws {
        let fixture = CloudResolverFixture { request in
            let url = request.url!
            if url.host == "login.microsoftonline.com" || url.host == "openapi.baidu.com" {
                return (200, [:], Data(#"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#.utf8))
            }
            let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
                ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "access_token" }?.value
            if token != "fresh" { return (403, [:], Data("{\"errno\":\(errno)}".utf8)) }
            if url.host == "graph.microsoft.com" { return (200, [:], Data(#"{"value":[]}"#.utf8)) }
            if request.httpMethod == "HEAD" { return (302, ["Location": "https://cdn.invalid/track.flac"], Data()) }
            if url.path.contains("multimedia") { return (200, [:], Data(#"{"errno":0,"list":[{"dlink":"https://d.pcs.baidu.com/file"}]}"#.utf8)) }
            return (200, [:], Data(#"{"errno":0,"list":[{"server_filename":"track.flac","fs_id":123}]}"#.utf8))
        }
        let source = MusicSource(id: UUID().uuidString, name: "fixture", type: type)
        let credential = SourceCredential(token: "old", refreshToken: "refresh", clientID: "client")
        if type == .oneDrive {
            _ = try await CloudDriveStreamResolver(session: fixture.session, quotaRegistry: fixture.registry).listDirectory(source: source, credential: credential, path: "/")
        } else {
            let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/track.flac", sourceID: source.id)
            let stream = try await BaiduPanStreamResolver(session: fixture.session, quotaRegistry: fixture.registry).resolve(for: song, source: source, credential: credential)
            #expect(stream.url.host == "cdn.invalid")
        }
        #expect(fixture.requests.filter { $0.url?.host == "openapi.baidu.com" || $0.url?.host == "login.microsoftonline.com" }.count == 1)
    }

    @Test func concurrentReadersDeduplicateRefreshAndPersistRotatedCredentials() async throws {
        let fixture = CloudResolverFixture { request in
            if request.url?.host == "login.microsoftonline.com" {
                return (200, [:], Data(#"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600,"token_type":"Bearer"}"#.utf8))
            }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh"
                ? (200, [:], Data(#"{"value":[]}"#.utf8)) : (401, [:], Data())
        }
        let source = MusicSource(id: UUID().uuidString, name: "Cloud", type: .oneDrive)
        let credential = SourceCredential(token: "expired", refreshToken: "refresh", clientID: "client")
        let resolver = CloudDriveStreamResolver(session: fixture.session, quotaRegistry: fixture.registry)
        let saved = CloudRefreshRecorder()
        await resolver.setCredentialRefreshHandler { id, refresh in await saved.append(id, refresh) }
        async let first = resolver.listDirectory(source: source, credential: credential, path: "/")
        async let second = resolver.listDirectory(source: source, credential: credential, path: "/other")
        _ = try await (first, second)
        #expect(fixture.requests.filter { $0.url?.host == "login.microsoftonline.com" }.count == 1)
        let records = await saved.values
        #expect(records.count == 1)
        #expect(records.first?.0 == source.id)
        #expect(records.first?.1.credential.refreshToken == "rotated")
        #expect(records.first?.1.tokenType == "Bearer")
        #expect(records.first?.1.expiresAt != nil)
    }

    @Test func oneDrivePaginationKeepsOpaqueQueryAndRejectsForeignNextLink() async throws {
        let opaque = "https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=A%2BB%2F%3D"
        for nextLink in [opaque, "https://graph.microsoft.com.evil.invalid/steal"] {
            let fixture = CloudResolverFixture { request in
                if request.url?.absoluteString == opaque {
                    return (200, [:], Data(#"{"value":[{"id":"two","name":"two.flac","size":2,"file":{}}]}"#.utf8))
                }
                let body = try! JSONSerialization.data(withJSONObject: ["value": [["id": "one", "name": "one.flac", "size": 1, "file": [:]]], "@odata.nextLink": nextLink])
                return (200, [:], body)
            }
            let source = MusicSource(id: UUID().uuidString, name: "Cloud", type: .oneDrive)
            do {
                let entries = try await CloudDriveStreamResolver(session: fixture.session, quotaRegistry: fixture.registry).listDirectory(source: source, credential: .init(token: "fixture"), path: "/")
                #expect(nextLink == opaque)
                #expect(entries.map(\.path) == ["one", "two"])
            } catch { #expect(nextLink != opaque) }
            #expect(fixture.requests.count == (nextLink == opaque ? 2 : 1))
            #expect(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" })
        }
    }

    @Test func baiduHeadPreservesDateCooldownAndPlaybackHeaders() async throws {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let retry = date.string(from: Date().addingTimeInterval(3600))
        for headStatus in [302, 503] {
            let fixture = CloudResolverFixture { request in
                if request.httpMethod == "HEAD" {
                    return (headStatus, headStatus == 302 ? ["Location": "https://cdn.invalid/track.flac"] : ["Retry-After": retry], Data())
                }
                if request.url?.path.contains("multimedia") == true {
                    return (200, [:], Data(#"{"errno":0,"list":[{"dlink":"https://d.pcs.baidu.com/file?sign=A%2BB%2F%3D"}]}"#.utf8))
                }
                return (200, [:], Data(#"{"errno":0,"list":[{"server_filename":"track.flac","fs_id":123}]}"#.utf8))
            }
            let source = MusicSource(id: UUID().uuidString, name: "Baidu", type: .baiduPan)
            let song = Song(id: "track", title: "Track", fileFormat: .flac, filePath: "/music/track.flac", sourceID: source.id)
            for _ in 0..<(headStatus == 302 ? 1 : 2) {
                do {
                    let stream = try await BaiduPanStreamResolver(session: fixture.session, quotaRegistry: fixture.registry).resolve(for: song, source: source, credential: .init(token: "fixture+&"))
                    #expect(headStatus == 302)
                    #expect(stream.url.absoluteString == "https://cdn.invalid/track.flac")
                    #expect(stream.headers["User-Agent"] == "pan.baidu.com")
                    #expect(stream.headers["Referer"] == "https://pan.baidu.com/")
                } catch let failure as HTTPResponseFailure {
                    #expect(headStatus == 503); #expect(failure.statusCode == 503)
                    #expect((failure.retryAfter ?? 0) > 3590)
                }
            }
            let heads = fixture.requests.filter { $0.httpMethod == "HEAD" }
            #expect(heads.count == 1)
            #expect(heads.first?.url?.absoluteString == "https://d.pcs.baidu.com/file?sign=A%2BB%2F%3D&access_token=fixture%2B%26")
            #expect(heads.first?.value(forHTTPHeaderField: "User-Agent") == "pan.baidu.com")
            #expect(heads.first?.value(forHTTPHeaderField: "Referer") == "https://pan.baidu.com/")
            #expect(!fixture.requests.contains { $0.url?.host == "cdn.invalid" })
        }
    }

    @Test(arguments: [403, 410])
    func baiduExpiredHeadRefreshesItsLinkOnce(status: Int) async throws {
        let fixture = CloudResolverFixture { request in
            let url = request.url!
            if url.host == "openapi.baidu.com" {
                return (200, [:], Data(#"{"access_token":"fresh"}"#.utf8))
            }
            if request.httpMethod == "HEAD" {
                let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "access_token" }?.value
                return token == "fresh" ? (302, ["Location": "https://cdn.invalid/track.flac"], Data()) : (status, [:], Data())
            }
            if url.path.contains("multimedia") { return (200, [:], Data(#"{"errno":0,"list":[{"dlink":"https://d.pcs.baidu.com/file"}]}"#.utf8)) }
            return (200, [:], Data(#"{"errno":0,"list":[{"server_filename":"track.flac","fs_id":123}]}"#.utf8))
        }
        let source = MusicSource(id: UUID().uuidString, name: "fixture", type: .baiduPan)
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/track.flac", sourceID: source.id)
        let resolver = BaiduPanStreamResolver(session: fixture.session, quotaRegistry: fixture.registry)
        let stream = try await resolver.resolve(for: song, source: source, credential: .init(token: "old", refreshToken: "refresh", clientID: "client"))
        #expect(stream.url.host == "cdn.invalid")
        #expect(fixture.requests.filter { $0.httpMethod == "HEAD" }.count == 2)
        #expect(fixture.requests.filter { $0.url?.host == "openapi.baidu.com" }.count == 1)
    }

    @Test func cancellationStopsReadWithoutReplay() async throws {
        let fixture = CloudResolverFixture { _ in (0, [:], Data()) }
        let source = MusicSource(id: UUID().uuidString, name: "Cloud", type: .oneDrive)
        let resolver = CloudDriveStreamResolver(session: fixture.session, quotaRegistry: fixture.registry)
        let task = Task { try await resolver.listDirectory(source: source, credential: .init(token: "fixture"), path: "/") }
        for _ in 0..<200 {
            if !fixture.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.requests.count == 1)
        task.cancel()
        do { _ = try await task.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
        catch let error as URLError { #expect(error.code == .cancelled) }
        #expect(fixture.requests.count == 1)
    }
}

private actor CloudRefreshRecorder {
    private(set) var values: [(String, CloudCredentialRefresh)] = []
    func append(_ id: String, _ refresh: CloudCredentialRefresh) { values.append((id, refresh)) }
}

private final class CloudResolverFixture: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> (Int, [String: String], Data)
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    let handler: Handler
    let clock: CloudRetryClock
    let registry: RequestQuotaRegistry
    private var starts: [TimeInterval] = []
    var times: [TimeInterval] { lock.withLock { starts } }
    var requests: [URLRequest] { lock.withLock { captured } }
    lazy var session: URLSession = {
        CloudResolverProtocol.fixture = self
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudResolverProtocol.self]
        return URLSession(configuration: config)
    }()
    init(_ handler: @escaping Handler) {
        self.handler = handler
        let clock = CloudRetryClock()
        self.clock = clock
        self.registry = RequestQuotaRegistry(timing: clock.timing)
    }
    func response(_ request: URLRequest) async throws -> (Int, [String: String], Data) {
        lock.withLock { captured.append(request); starts.append(clock.now) }
        return try await handler(request)
    }
}

private final class CloudResolverProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored: CloudResolverFixture?
    static var fixture: CloudResolverFixture? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var loading: Task<Void, Never>?
    override func startLoading() {
        guard let fixture = Self.fixture, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        loading = Task {
            do {
                let (status, headers, body) = try await fixture.response(request)
                if status == 0 { return }
                try Task.checkCancellation()
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { loading?.cancel() }
}

private actor CloudRefreshScenario {
    let firstSucceeds: Bool
    private(set) var refreshes = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var rejectFirst = false
    init(firstSucceeds: Bool) { self.firstSucceeds = firstSucceeds }
    func reply(_ request: URLRequest) async throws -> (Int, [String: String], Data) {
        let url = request.url!
        if url.host == "login.microsoftonline.com" || url.host == "openapi.baidu.com" {
            refreshes += 1
            if refreshes == 1 {
                await withCheckedContinuation { continuation = $0 }
                if !firstSucceeds { return (400, [:], Data()) }
            }
            return (200, [:], Data("{\"access_token\":\"fresh\(refreshes)\",\"refresh_token\":\"rotated\",\"expires_in\":3600}".utf8))
        }
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")
            ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "access_token" }?.value
        if token == "old" || (rejectFirst && token == "fresh1") { return (401, [:], Data()) }
        if url.host == "graph.microsoft.com" { return (200, [:], Data(#"{"value":[]}"#.utf8)) }
        if request.httpMethod == "HEAD" { return (302, ["Location": "https://cdn.invalid/track.flac"], Data()) }
        if url.path.contains("multimedia") { return (200, [:], Data(#"{"errno":0,"list":[{"dlink":"https://d.pcs.baidu.com/file"}]}"#.utf8)) }
        return (200, [:], Data(#"{"errno":0,"list":[{"server_filename":"track.flac","fs_id":123}]}"#.utf8))
    }
    func waitForRefresh() async throws {
        for _ in 0..<10000 {
            if continuation != nil { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    func releaseRefresh() { continuation?.resume(); continuation = nil }
    func rejectFirstToken() { rejectFirst = true }
}

private actor CloudTransientReplies {
    private var count = 0
    func next() -> (Int, [String: String], Data) {
        count += 1
        return count == 1 ? (503, [:], Data()) : (200, [:], Data(#"{"value":[]}"#.utf8))
    }
}

private final class CloudRetryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 0
    var now: TimeInterval { lock.withLock { instant } }
    var timing: RequestExecutor.Timing {
        .init(now: { self.now }, sleep: { delay in
            try Task.checkCancellation()
            // Retry/pacing waits advance virtual time. Overall deadlines remain
            // pending until the operation cancels them; no wall-clock assertion.
            if delay >= 30 { try await Task.sleep(for: .seconds(3600)) }
            else { self.lock.withLock { self.instant += delay }; await Task.yield() }
        })
    }
}

private actor CloudSendCount {
    private(set) var value = 0
    func sent() { value += 1 }
}
