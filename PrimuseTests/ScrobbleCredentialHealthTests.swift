import Foundation
import PrimuseKit
import XCTest
#if os(tvOS)
@testable import PrimuseTV
#else
@testable import Primuse
#endif

final class ScrobbleCredentialHealthTests: XCTestCase, @unchecked Sendable {
    func testListenBrainzTemporaryFailuresStayUnconfirmed() async {
        for status in [429, 503, 500, 404, 403] {
            let fixture = CredentialHTTPFixture(status: status, body: "{}")
            let provider = ListenBrainzProvider(userToken: UUID().uuidString, session: fixture.session())
            let result = await provider.validateCredentials()
            XCTAssertNil(result, "HTTP \(status) does not prove an invalid token")
        }
    }
    func testLastFMBusinessErrorIsNotAValidSession() async {
        for code in [4, 9, 10, 26] {
            let fixture = CredentialHTTPFixture(status: 200, body: "{\"error\":\(code)}")
            let provider = LastFmProvider(apiKey: UUID().uuidString, apiSecret: "fixture", sessionKey: "fixture", session: fixture.session())
            let result = await provider.validateCredentials()
            XCTAssertEqual(result, false)
        }
    }
    func testHealthChecksAndSubmissionsRetainTheSameCooldown() async throws {
        for (lastFM, body) in [(false, "{}"), (true, #"{"error":29}"#), (true, #"{"error":16}"#)] {
            let fixture = CredentialHTTPFixture(status: lastFM ? 200 : 503,
                body: body, headers: ["Retry-After": "86400"])
            let session = fixture.session()
            let key = UUID().uuidString
            func provider(_ account: String) -> any ScrobbleProvider {
                if lastFM { return LastFmProvider(apiKey: account, apiSecret: "fixture", sessionKey: "fixture", session: session) }
                return ListenBrainzProvider(userToken: account, session: session)
            }
            for _ in 0..<2 {
                let result = await provider(key).validateCredentials()
                XCTAssertNil(result)
            }
            do { try await provider(key).sendNowPlaying(.init(songID: "fixture", title: "Track", artist: "Artist", startedAt: 1_700_000_000)); XCTFail("Submission bypassed health cooldown") }
            catch let failure as HTTPResponseFailure { XCTAssertGreaterThan(failure.retryAfter ?? 0, 86390) }
            XCTAssertEqual(fixture.requests.count, 1)
            _ = await provider("independent-" + key).validateCredentials()
            XCTAssertEqual(fixture.requests.count, 2)
        }
    }

    func testCancelledValidationIsUnconfirmedAndStopsTransport() async throws {
        let fixture = CredentialHTTPFixture(status: 200, body: "{}", hold: true)
        let started = expectation(description: "health request started")
        let stopped = expectation(description: "health request stopped")
        fixture.started = started; fixture.stopped = stopped
        let provider = ListenBrainzProvider(userToken: UUID().uuidString, session: fixture.session())
        let pending = Task { await provider.validateCredentials() }
        defer { pending.cancel() }
        await fulfillment(of: [started], timeout: 5)
        pending.cancel()
        let result = await pending.value
        XCTAssertNil(result)
        await fulfillment(of: [stopped], timeout: 5)
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return await provider.validateCredentials() }
        let second = await cancelled.value
        XCTAssertNil(second)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testOnlyValidSuccessEnvelopesConfirmCredentials() async {
        let valid = CredentialHTTPFixture(status: 200, body: #"{"user":{"name":"reader"}}"#)
        let confirmed = await LastFmProvider(apiKey: UUID().uuidString, apiSecret: "fixture", sessionKey: "fixture", session: valid.session()).validateCredentials()
        XCTAssertEqual(confirmed, true)
        for (body, expected) in [(#"{"valid":true,"code":200}"#, true), (#"{"valid":false,"code":200}"#, false)] {
            let fixture = CredentialHTTPFixture(status: 200, body: body)
            let result = await ListenBrainzProvider(userToken: UUID().uuidString, session: fixture.session()).validateCredentials()
            XCTAssertEqual(result, expected)
        }
        for body in ["{}", "not-json", #"{"valid":1}"#, #"{"valid":true,"code":503}"#] {
            let fixture = CredentialHTTPFixture(status: 200, body: body)
            let result = await ListenBrainzProvider(userToken: UUID().uuidString, session: fixture.session()).validateCredentials()
            XCTAssertNil(result)
        }
        for body in ["{}", "not-json", #"{"user":{}}"#, #"{"error":16}"#] {
            let fixture = CredentialHTTPFixture(status: 200, body: body)
            let result = await LastFmProvider(apiKey: UUID().uuidString, apiSecret: "fixture", sessionKey: "fixture", session: fixture.session()).validateCredentials()
            XCTAssertNil(result)
        }
    }
}

private final class CredentialHTTPFixture: @unchecked Sendable {
    let status: Int
    let body: Data
    let headers: [String: String]
    let hold: Bool
    var started: XCTestExpectation?
    var stopped: XCTestExpectation?
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { captured } }
    init(status: Int, body: String, headers: [String: String] = [:], hold: Bool = false) {
        self.status = status; self.body = Data(body.utf8); self.headers = headers; self.hold = hold
    }
    func record(_ request: URLRequest) { lock.withLock { captured.append(request) } }
    func session() -> URLSession {
        CredentialHTTPProtocol.lock.withLock { CredentialHTTPProtocol.fixture = self }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CredentialHTTPProtocol.self]
        return URLSession(configuration: config)
    }
}
private final class CredentialHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var fixture: CredentialHTTPFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.lock.withLock { Self.fixture! }; fixture.record(request)
        fixture.started?.fulfill()
        if fixture.hold { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: fixture.status,
            httpVersion: nil, headerFields: fixture.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { Self.fixture }?.stopped?.fulfill() }
}
