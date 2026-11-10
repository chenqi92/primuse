import Foundation
import XCTest
import PrimuseKit
#if os(tvOS)
@testable import PrimuseTV
#else
@testable import Primuse
#endif

final class RadioDirectoryQuotaTests: XCTestCase {
    func testLogoLookupsShareAnHourCooldown() async throws {
        let fixture = RadioQuotaFixture()
        defer { fixture.close() }
        let client = RadioDirectoryClient(session: fixture.session, mirrors: RadioDirectoryMirrors(hosts: [fixture.host]))
        _ = await client.lookup(streamURL: "https://stream.invalid/live")
        _ = await client.lookup(streamURL: "https://stream.invalid/other")
        XCTAssertEqual(fixture.requests.count, 1, "A second logo lookup must respect the mirror's Retry-After")
    }
    func testMirrorDiscoverySharesLookupCooldown() async throws {
        let fixture = RadioQuotaFixture()
        defer { fixture.close() }
        let registry = RequestQuotaRegistry()
        let client = RadioDirectoryClient(session: fixture.session,
            mirrors: RadioDirectoryMirrors(hosts: [fixture.host]), quotaRegistry: registry)
        _ = await client.lookup(streamURL: "https://stream.invalid/live")
        let discovery = RadioDirectoryMirrors(session: fixture.session, quotaRegistry: registry,
            serverListURL: URL(string: "https://\(fixture.host)/json/servers")!)
        _ = await discovery.orderedHosts()
        XCTAssertEqual(fixture.requests.count, 1, "Mirror discovery must not bypass the directory quota")
    }
    func testCancellationDuringDiscoveryDoesNotWaitForItsHTTPTimeout() async throws {
        let started = expectation(description: "Discovery reached HTTP")
        let finished = expectation(description: "Cancelled lookup returned")
        let fixture = RadioQuotaFixture { _ in started.fulfill(); return .init(hold: true) }
        defer { fixture.close() }
        let registry = RequestQuotaRegistry()
        let mirrors = RadioDirectoryMirrors(session: fixture.session, quotaRegistry: registry,
            serverListURL: URL(string: "https://\(fixture.host)/json/servers")!)
        let client = RadioDirectoryClient(session: fixture.session, mirrors: mirrors, quotaRegistry: registry)
        let request = Task {
            defer { finished.fulfill() }
            let result = await client.lookup(streamURL: "https://stream.invalid/live")
            XCTAssertNil(result)
        }
        await fulfillment(of: [started], timeout: 2)
        request.cancel()
        await fulfillment(of: [finished], timeout: 1)
        fixture.close()
        _ = await request.result
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testLongSecondsAndHTTPDateSurviveNewClientsAndExpireWithoutEarlySends() async throws {
        for status in [429, 503] {
            for header in ["3600", "Fri, 15 Jan 2027 09:00:00 GMT"] {
                let fixture = RadioQuotaFixture { _ in .init(status: status,
                    headers: ["Retry-After": header], body: Data("busy".utf8)) }
                defer { fixture.close() }
                let clock = RadioQuotaClock()
                let registry = RequestQuotaRegistry(timing: clock.timing)
                func client() -> RadioDirectoryClient {
                    .init(session: fixture.session, mirrors: RadioDirectoryMirrors(hosts: [fixture.host]),
                          quotaRegistry: registry)
                }
                let initial = await client().lookup(streamURL: "https://stream.invalid/live")
                XCTAssertNil(initial)
                clock.advance(to: 600)
                let other = await client().lookup(streamURL: "https://stream.invalid/other")
                XCTAssertNil(other)
                let logo = await client().lookup(streamURL: "https://stream.invalid/live")
                XCTAssertNil(logo)
                XCTAssertEqual(fixture.requests.count, 1)
                clock.advance(to: 3600)
                _ = await client().lookup(streamURL: "https://stream.invalid/after-expiry")
                XCTAssertEqual(fixture.requests.count, 2)
            }
        }
    }

    func testIndependentMirrorCanSucceedWhileTheFirstKeepsItsCooldown() async throws {
        let payload = Data(#"[{"stationuuid":"station-1","name":"Fixture FM","url":"https://stream.invalid/live","favicon":"https://image.invalid/logo.png"}]"#.utf8)
        let fixture = RadioQuotaFixture { request in
            request.url?.host?.hasPrefix("second.") == true
                ? .init(status: 200, headers: [:], body: payload) : .init()
        }
        defer { fixture.close() }
        let registry = RequestQuotaRegistry()
        let hosts = [fixture.host, "second." + fixture.host]
        for _ in 0..<2 {
            let client = RadioDirectoryClient(session: fixture.session,
                mirrors: RadioDirectoryMirrors(hosts: hosts), quotaRegistry: registry)
            let result = await client.lookup(streamURL: "https://stream.invalid/live")
            XCTAssertEqual(result?.faviconURL, "https://image.invalid/logo.png")
        }
        XCTAssertEqual(fixture.requests.compactMap { $0.url?.host }, [hosts[0], hosts[1], hosts[1]])
    }

    func testMirrorFailoverOwnsOneThreeSendBudget() async throws {
        for status in [429, 500, 503] {
            let fixture = RadioQuotaFixture { _ in .init(status: status, headers: [:]) }
            defer { fixture.close() }
            let hosts = (1...4).map { "mirror\($0)." + fixture.host }
            let client = RadioDirectoryClient(session: fixture.session,
                mirrors: RadioDirectoryMirrors(hosts: hosts), quotaRegistry: RequestQuotaRegistry())
            let result = await client.lookup(streamURL: "https://stream.invalid/live")
            XCTAssertNil(result)
            XCTAssertEqual(fixture.requests.compactMap { $0.url?.host }, Array(hosts.prefix(3)))
        }
    }

    func testPermanentFailuresAndTransportCancellationNeverSwitchMirrors() async throws {
        for status in [400, 401, 403, 404] {
            let fixture = RadioQuotaFixture { _ in .init(status: status, headers: [:]) }
            defer { fixture.close() }
            let client = RadioDirectoryClient(session: fixture.session,
                mirrors: RadioDirectoryMirrors(hosts: [fixture.host, "other." + fixture.host]),
                quotaRegistry: RequestQuotaRegistry())
            for _ in 0..<2 {
                let result = await client.lookup(streamURL: "https://stream.invalid/live")
                XCTAssertNil(result)
            }
            XCTAssertEqual(fixture.requests.count, 2, "Ordinary 4xx must not create a quota or retry")
            XCTAssertTrue(fixture.requests.allSatisfy { $0.url?.host == fixture.host })
        }
        let fixture = RadioQuotaFixture { _ in .init(error: URLError(.cancelled)) }
        defer { fixture.close() }
        let client = RadioDirectoryClient(session: fixture.session,
            mirrors: RadioDirectoryMirrors(hosts: [fixture.host, "other." + fixture.host]))
        let result = await client.lookup(streamURL: "https://stream.invalid/live")
        XCTAssertNil(result)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testSuccessfulMappingAndReadOnlyLookupPOSTArePreserved() async throws {
        let payload = Data(#"[{"stationuuid":"station-1","name":"Fixture FM","url":"https://stream.invalid/original","url_resolved":"https://stream.invalid/live","codec":"UNKNOWN","bitrate":128,"country":"Japan","favicon":"https://image.invalid/logo.png","homepage":"https://radio.invalid/"}]"#.utf8)
        let fixture = RadioQuotaFixture { _ in .init(status: 200, headers: [:], body: payload) }
        defer { fixture.close() }
        let client = RadioDirectoryClient(session: fixture.session,
            mirrors: RadioDirectoryMirrors(hosts: [fixture.host]))
        let logo = await client.lookup(streamURL: "https://stream.invalid/live")
        XCTAssertEqual(logo?.id, "station-1")
        XCTAssertEqual(logo?.streamURL, "https://stream.invalid/live")
        XCTAssertNil(logo?.codec)
        XCTAssertEqual(logo?.bitrate, 128)
        XCTAssertEqual(logo?.faviconURL, "https://image.invalid/logo.png")
        XCTAssertEqual(fixture.requests.last?.httpMethod, "POST")
        XCTAssertEqual(fixture.requests.last?.url?.path, "/json/stations/byurl")
        XCTAssertEqual(fixture.requests.last?.value(forHTTPHeaderField: "User-Agent"), "Primuse/1.0")
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(fixture.requests.first?.url), resolvingAgainstBaseURL: false))
        XCTAssertNil(query.queryItems, "Lookup must not send a station search query")
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testMalformedSuccessDoesNotFailOverAndInvalidStreamDoesNotSend() async throws {
        let fixture = RadioQuotaFixture { _ in .init(status: 200, headers: [:], body: Data("invalid".utf8)) }
        defer { fixture.close() }
        let client = RadioDirectoryClient(session: fixture.session,
            mirrors: RadioDirectoryMirrors(hosts: [fixture.host, "other." + fixture.host]))
        let invalid = await client.lookup(streamURL: " ")
        XCTAssertNil(invalid)
        XCTAssertTrue(fixture.requests.isEmpty)
        let malformed = await client.lookup(streamURL: "https://stream.invalid/live")
        XCTAssertNil(malformed)
        XCTAssertEqual(fixture.requests.count, 1)
    }

}

private final class RadioQuotaFixture: @unchecked Sendable {
    struct Reply: Sendable {
        var status = 429
        var headers = ["Retry-After": "3600"]
        var body = Data()
        var error: URLError?
        var hold = false
    }
    let id = UUID().uuidString
    var host: String { id.lowercased() + ".radio-browser.info" }
    let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var handler: @Sendable (URLRequest) -> Reply
    var requests: [URLRequest] { lock.withLock { recorded } }
    lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RadioQuotaProtocol.self]
        config.httpAdditionalHeaders = ["X-Radio-Fixture": id]
        RadioQuotaProtocol.register(self)
        return URLSession(configuration: config)
    }()
    init(handler: @escaping @Sendable (URLRequest) -> Reply = { _ in Reply() }) {
        self.handler = handler
    }
    func reply(_ request: URLRequest) -> Reply {
        lock.withLock { recorded.append(request) }
        return handler(request)
    }
    func close() { session.invalidateAndCancel(); RadioQuotaProtocol.remove(id) }
}

private final class RadioQuotaProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var fixtures: [String: RadioQuotaFixture] = [:]
    static func register(_ fixture: RadioQuotaFixture) { lock.withLock { fixtures[fixture.id] = fixture } }
    static func remove(_ id: String) { lock.withLock { _ = fixtures.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[request.value(forHTTPHeaderField: "X-Radio-Fixture") ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        let reply = fixture.reply(request)
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        if reply.hold { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RadioQuotaClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 0
    private var now: TimeInterval { lock.withLock { instant } }
    func advance(to value: TimeInterval) { lock.withLock { instant = value } }
    var timing: RequestExecutor.Timing {
        .init(now: { self.now }, date: { Date(timeIntervalSince1970: 1_800_000_000 + self.now) })
    }
}
