import Foundation
import Testing
@testable import PrimuseKit

@Suite("Device authorization polling", .serialized, .timeLimit(.minutes(1)))
struct CloudDeviceAuthRequestTests {
    @Test func slowDownIncreasesEverySubsequentInterval() async throws {
        let fixture = DeviceAuthFixture([
            .json(400, #"{"error":"slow_down"}"#), .json(400, #"{"error":"slow_down"}"#),
            .json(400, #"{"error":"authorization_pending"}"#), .authorized
        ])
        let result = try await fixture.service().pollUntilFinished(fixture.auth(), clientID: "client", clientSecret: nil)
        guard case .authorized(let tokens) = result else { Issue.record("Expected authorization"); return }
        #expect(tokens.credential.token == "fresh")
        #expect(tokens.credential.refreshToken == "rotated")
        #expect(fixture.times == [5, 15, 30, 45])
    }

    @Test(arguments: [429, 503])
    func explicitRetryAfterDefersTheNextPoll(status: Int) async throws {
        let fixture = DeviceAuthFixture([.init(status: status, headers: ["Retry-After": "20"]), .authorized])
        let result = try await fixture.service().pollUntilFinished(fixture.auth(), clientID: "client", clientSecret: nil)
        guard case .authorized = result else { Issue.record("Expected authorization"); return }
        #expect(fixture.times == [5, 25])
    }

    @Test(arguments: [429, 503])
    func longCooldownSurvivesReopeningAuthorization(status: Int) async throws {
        let fixture = DeviceAuthFixture([.init(status: status, headers: ["Retry-After": "86400"])])
        do { _ = try await fixture.service().poll(fixture.auth(), clientID: "client", clientSecret: nil); Issue.record("Expected quota") }
        catch let failure as HTTPResponseFailure { #expect(failure.retryAfter == 86400) }
        do { _ = try await fixture.service().begin(provider: .oneDrive, clientID: "client", clientSecret: nil); Issue.record("New authorization bypassed quota") }
        catch let failure as HTTPResponseFailure { #expect(failure.retryAfter == 86400) }
        #expect(fixture.times == [0])
    }

    @Test(arguments: [200, 400, 429])
    func slowDownAndRetryAfterBothApply(status: Int) async throws {
        let fixture = DeviceAuthFixture([
            .init(status: status, headers: ["Retry-After": "20"], body: Data(#"{"error":"slow_down"}"#.utf8)),
            .json(400, #"{"error":"authorization_pending"}"#), .authorized
        ])
        _ = try await fixture.service().pollUntilFinished(fixture.auth(), clientID: "client", clientSecret: nil)
        #expect(fixture.times == [5, 25, 35])
    }

    @Test func dateCooldownAndExpiryKeepTheirFullDeadlines() async throws {
        let fixture = DeviceAuthFixture([
            .init(status: 503, headers: ["Retry-After": "Tue, 14 Nov 2023 22:14:25 GMT"]), .authorized
        ])
        _ = try await fixture.service().pollUntilFinished(fixture.auth(), clientID: "client", clientSecret: nil)
        #expect(fixture.times == [5, 65])
        let expired = DeviceAuthFixture([.init(status: 429, headers: ["Retry-After": "86400"])])
        #expect(try await expired.service().pollUntilFinished(expired.auth(expires: 30), clientID: "client", clientSecret: nil) == .expired)
        #expect(expired.times == [5])
    }

    @Test func unknownTokenOutcomeIsNotAutomaticallyReplayed() async throws {
        let fixture = DeviceAuthFixture([.init(status: 0, error: URLError(.timedOut))])
        do { _ = try await fixture.service().pollUntilFinished(fixture.auth(), clientID: "client", clientSecret: nil); Issue.record("Expected timeout") }
        catch { #expect((error as? URLError)?.code == .timedOut) }
        #expect(fixture.times == [5])
    }

    @Test func expiryDuringWaitStopsBeforeSending() async throws {
        let fixture = DeviceAuthFixture([.json(400, #"{"error":"authorization_pending"}"#)])
        let result = try await fixture.service().pollUntilFinished(fixture.auth(expires: 3), clientID: "client", clientSecret: nil)
        #expect(result == .expired)
        #expect(fixture.times.isEmpty)
    }

    @Test func admissionCooldownCannotSendAfterAuthorizationExpires() async throws {
        let fixture = DeviceAuthFixture([.init(status: 429, headers: ["Retry-After": "3"]), .authorized])
        do { _ = try await fixture.service().poll(fixture.auth(), clientID: "client", clientSecret: nil) }
        catch is HTTPResponseFailure {}
        let short = CloudDeviceAuthSession(provider: .oneDrive, kind: .deviceCode,
            qrCode: .content("fixture"), handle: "device", interval: 1, expiresIn: 2)
        let result = try await fixture.service().pollUntilFinished(short, clientID: "client", clientSecret: nil)
        #expect(result == .expired)
        #expect(fixture.times == [0])
    }

    @Test func denialAndCancellationStopPolling() async throws {
        let fixture = DeviceAuthFixture([.json(400, #"{"error":"access_denied"}"#)])
        #expect(try await fixture.service().pollUntilFinished(fixture.auth(), clientID: "client", clientSecret: nil) == .denied)
        #expect(fixture.times == [5])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.service().pollUntilFinished(fixture.auth(), clientID: "client", clientSecret: nil)
        }
        do { _ = try await task.value; Issue.record("Cancellation reported a flow result") }
        catch { #expect(OperationCancellationPolicy.isCancellation(error)) }
        #expect(fixture.times == [5])
    }
}

private final class DeviceAuthClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    var timing: RequestExecutor.Timing {
        .init(now: { self.now }, date: { Date(timeIntervalSince1970: 1_700_000_000 + self.now) }, sleep: { delay in
            try Task.checkCancellation()
            self.lock.withLock { self.value += delay }
            await Task.yield()
        })
    }
    var requestTiming: RequestExecutor.Timing {
        .init(now: { self.now }, date: { Date(timeIntervalSince1970: 1_700_000_000 + self.now) },
              sleep: { delay in
                  if delay <= 8 { self.lock.withLock { self.value += delay }; await Task.yield() }
                  else { try await Task.sleep(for: .seconds(3600)) }
              })
    }
}

private final class DeviceAuthFixture: @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
        var error: URLError? = nil
        static func json(_ status: Int, _ value: String) -> Reply { .init(status: status, body: Data(value.utf8)) }
        static let authorized = json(200, #"{"access_token":"fresh","refresh_token":"rotated","expires_in":3600}"#)
    }
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []
    let replies: [Reply]
    let clock = DeviceAuthClock()
    lazy var registry = RequestQuotaRegistry(timing: clock.requestTiming)
    var times: [TimeInterval] { lock.withLock { recorded } }
    lazy var session: URLSession = {
        DeviceAuthProtocol.lock.withLock { DeviceAuthProtocol.fixture = self }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DeviceAuthProtocol.self]
        return URLSession(configuration: config)
    }()
    init(_ replies: [Reply]) { self.replies = replies }
    func service() -> CloudDeviceAuthService { .init(session: session, quotaRegistry: registry, timing: clock.timing) }
    func auth(expires: TimeInterval = 300) -> CloudDeviceAuthSession {
        .init(provider: .oneDrive, kind: .deviceCode, qrCode: .content("fixture"), handle: "device",
              interval: 5, expiresIn: expires)
    }
    func reply() -> Reply {
        lock.withLock {
            let reply = replies[min(recorded.count, replies.count - 1)]
            recorded.append(clock.now)
            return reply
        }
    }
}

private final class DeviceAuthProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var fixture: DeviceAuthFixture?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock { Self.fixture! }.reply()
        if let error = reply.error { client?.urlProtocol(self, didFailWithError: error); return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.status,
            httpVersion: nil, headerFields: reply.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
