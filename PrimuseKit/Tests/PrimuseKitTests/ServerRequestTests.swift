import Foundation
import Testing
@testable import PrimuseKit

@Suite("Shared media-server request quotas", .serialized)
struct ServerRequestTests {
    @Test(arguments: [401, 403])
    func plexAuthenticationFailureKeepsPlaybackContract(status: Int) async throws {
        let host = UUID().uuidString + ".invalid"
        ServerQuotaProtocol.configure(host: host, status: status)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServerQuotaProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let resolver = MediaServerStreamResolver(session: session)
        let source = MusicSource(name: "fixture", type: .plex, host: host, useSsl: true)
        let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "42", sourceID: source.id)
        await #expect(throws: StreamResolveError.authFailed) {
            _ = try await resolver.streamURL(for: song, source: source, credential: .init(token: "fixture"))
        }
        #expect(ServerQuotaProtocol.readCount(host: host) == 1)
    }

    @Test func slowServerPageRetainsTheResourceTimeout() async throws {
        let clock = ControlledClock()
        let scheduler = ServerRequestScheduler(timing: clock.timing)
        let executor = scheduler.executor(baseURL: URL(string: "https://slow.invalid")!, account: "fixture")
        let read = Task {
            try await executor.execute(operation: {
                try await clock.timing.sleep(90)
                return "complete page"
            })
        }
        try await clock.waitForSleep(at: 90)
        clock.advance(to: 61)
        for _ in 0..<100 { await Task.yield() }
        clock.advance(to: 90)
        #expect(try await read.value == "complete page")
    }

    @Test func fnMusicForbiddenRenewsOnceAndKeepsAuthenticationFailure() async throws {
        let host = UUID().uuidString + ".invalid"
        ServerQuotaProtocol.configure(host: host, status: 403)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ServerQuotaProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let source = MusicSource(name: "fixture", type: .fnMusic, host: host, useSsl: true, username: "qa")
        let client = FnMusicServiceClient(source: source, credential: .init(username: "qa", password: "fixture"), session: session)
        await #expect(throws: FnMusicServiceError.authenticationFailed) {
            _ = try await client.trackPage(page: 1, size: 1)
        }
        #expect(ServerQuotaProtocol.loginCount(host: host) == 2)
        #expect(ServerQuotaProtocol.readCount(host: host) == 2)
    }

    @Test(arguments: [429, 503, 404])
    func fnMusicClientsRetainHTTPStatusAndShareQuota(status: Int) async throws {
        let host = UUID().uuidString + ".invalid"
        ServerQuotaProtocol.configure(host: host, status: status)
        for _ in 0..<2 {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ServerQuotaProtocol.self]
            let session = URLSession(configuration: config)
            let source = MusicSource(id: UUID().uuidString, name: "Test", type: .fnMusic,
                host: host, useSsl: true, username: "qa")
            let client = FnMusicServiceClient(source: source, credential: .init(username: "qa", password: "fixture"), session: session)
            do { _ = try await client.trackPage(page: 1, size: 1); Issue.record("Expected failure") }
            catch let failure as HTTPResponseFailure {
                #expect(failure.statusCode == status)
                if status == 429 || status == 503 { #expect((failure.retryAfter ?? 0) > 3590) }
            } catch { Issue.record("Lost HTTP failure: \(error)") }
        }
        #expect(ServerQuotaProtocol.readCount(host: host) == (status == 429 || status == 503 ? 1 : 2))
        #expect(ServerQuotaProtocol.loginCount(host: host) == 2, "404 must not renew an authenticated session")
    }

    @Test func plexMetadataResolversShareCooldown() async throws {
        let host = UUID().uuidString + ".invalid"
        ServerQuotaProtocol.configure(host: host, status: 429)
        for _ in 0..<2 {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [ServerQuotaProtocol.self]
            let resolver = MediaServerStreamResolver(session: URLSession(configuration: config))
            let source = MusicSource(id: UUID().uuidString, name: "Test", type: .plex, host: host, useSsl: true)
            let song = Song(id: "song", title: "Song", fileFormat: .flac, filePath: "/items/song.flac", sourceID: source.id)
            do { _ = try await resolver.streamURL(for: song, source: source, credential: .init(token: "fixture")); Issue.record("Expected quota failure") }
            catch let failure as HTTPResponseFailure { #expect(failure.statusCode == 429) }
            catch { Issue.record("Lost HTTP failure: \(error)") }
        }
        #expect(ServerQuotaProtocol.readCount(host: host) == 1)
    }

    @Test func nativeHistoryUsesTheSameServerCooldown() async throws {
        let base = URL(string: "https://" + UUID().uuidString + ".invalid")!
        let fixture = ServerHTTPFixture(status: 429)
        for _ in 0..<2 {
            do { _ = try await NavidromeListeningHistory.fetch(baseURL: base, username: "qa", password: "fixture",
                requestDataLoader: { try await fixture.send($0) }); Issue.record("Expected HTTP failure") }
            catch let failure as HTTPResponseFailure { #expect(failure.statusCode == 429) }
            catch { Issue.record("Lost HTTP failure: \(error)") }
        }
        #expect(await fixture.count == 1)
    }

    @Test(arguments: [429, 503])
    func synologyDiscoverySharesLongCooldown(status: Int) async throws {
        let host = UUID().uuidString + ".invalid"
        let fixture = ServerHTTPFixture(status: status)
        for _ in 0..<2 {
            let source = MusicSource(id: UUID().uuidString, name: "Test", type: .synologyAudioStation,
                                     host: host, useSsl: true, username: "qa")
            let client = SynologyAudioStationClient(source: source, credential: .init(username: "qa", password: "fixture"),
                transport: .init(data: { try await fixture.send($0) }, download: { _ in throw URLError(.unsupportedURL) }))
            do { try await client.prepareConnection(); Issue.record("Expected quota failure") }
            catch let failure as HTTPResponseFailure {
                #expect(failure.statusCode == status)
                #expect((failure.retryAfter ?? 0) > 3590)
            } catch { Issue.record("Lost HTTP failure: \(error)") }
        }
        #expect(await fixture.count == 1)
    }

    @Test(arguments: [403, 404])
    func permanentDiscoveryFailureDoesNotReplay(status: Int) async throws {
        let fixture = ServerHTTPFixture(status: status, retryAfter: nil)
        let source = MusicSource(id: UUID().uuidString, name: "Test", type: .synologyAudioStation,
                                 host: UUID().uuidString + ".invalid", useSsl: true, username: "qa")
        let client = SynologyAudioStationClient(source: source, credential: .init(username: "qa", password: "fixture"),
            transport: .init(data: { try await fixture.send($0) }, download: { _ in throw URLError(.unsupportedURL) }))
        do { try await client.prepareConnection(); Issue.record("Expected HTTP failure") }
        catch let failure as HTTPResponseFailure { #expect(failure.statusCode == status) }
        catch { Issue.record("Lost HTTP failure: \(error)") }
        #expect(await fixture.count == 1)
    }
}

private actor ServerHTTPFixture {
    let status: Int
    let retryAfter: String?
    var count = 0
    init(status: Int, retryAfter: String? = "3600") { self.status = status; self.retryAfter = retryAfter }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        count += 1
        return (Data("limited".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: retryAfter.map { ["Retry-After": $0] })!)
    }
}

private final class ServerQuotaProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private struct State { var status: Int; var reads = 0; var logins = 0 }
    nonisolated(unsafe) private static var states: [String: State] = [:]
    static func configure(host: String, status: Int) { lock.withLock { states[host.lowercased()] = State(status: status) } }
    static func readCount(host: String) -> Int { lock.withLock { states[host.lowercased()]?.reads ?? 0 } }
    static func loginCount(host: String) -> Int { lock.withLock { states[host.lowercased()]?.logins ?? 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let login = url.path.hasSuffix("password-login")
        let status = Self.lock.withLock { () -> Int in
            let host = url.host!.lowercased()
            if login { Self.states[host]!.logins += 1; return 200 }
            Self.states[host]!.reads += 1
            return Self.states[host]!.status
        }
        let body = login ? #"{"code":0,"data":{"userToken":"fixture"}}"# : #"{"error":"limited"}"#
        let headers = ["Content-Type": "application/json"].merging(
            status == 429 || status == 503 ? ["Retry-After": "3600"] : [:], uniquingKeysWith: { $1 })
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
