import Foundation
import Network
import PrimuseKit
import XCTest
@testable import Primuse

final class CloudRequestTests: XCTestCase {
    func testLongCooldownIsPreservedAndSharedByHelpers() async throws {
        let fixture = CloudHTTPFixture(responses: [
            .init(status: 429, headers: ["Retry-After": "3600"]), .init(status: 200)
        ])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let first = CloudDriveHelper(sourceID: fixture.id)
        let second = CloudDriveHelper(sourceID: fixture.id)
        for helper in [first, second] {
            do {
                _ = try await helper.makeAuthorizedRequest(
                    url: fixture.url, method: "POST", accessToken: "fixture", session: session
                )
                XCTFail("Expected shared cooldown")
            } catch let failure as HTTPResponseFailure {
                XCTAssertEqual(failure.statusCode, 429)
                XCTAssertGreaterThan(try XCTUnwrap(failure.retryAfter), 3590)
            } catch { XCTFail("Expected complete HTTP failure, got \(error)") }
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }
    func testAPICooldownAlsoStopsRangeOnTheSameHost() async throws {
        let fixture = CloudHTTPFixture(responses: [
            .init(status: 429, headers: ["Retry-After": "3600"]), .init(status: 200)
        ])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let helper = CloudDriveHelper(sourceID: fixture.id)
        _ = try? await helper.makeAuthorizedRequest(url: fixture.url, method: "POST", accessToken: "fixture", session: session)
        do {
            _ = try await helper.rangeRequest(url: fixture.url, offset: 0, length: 4, session: session)
            XCTFail("Range bypassed the account/host quota")
        } catch let failure as HTTPResponseFailure {
            XCTAssertEqual(failure.statusCode, 429)
            XCTAssertGreaterThan(try XCTUnwrap(failure.retryAfter), 3590)
        } catch { XCTFail("Expected shared cooldown, got \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testReadDefersLongHTTPDateWithoutSendingAgain() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let fixture = CloudHTTPFixture(responses: [.init(status: 503,
            headers: ["Retry-After": formatter.string(from: Date().addingTimeInterval(3600))])])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        do {
            _ = try await CloudDriveHelper(sourceID: fixture.id).makeAuthorizedRequest(url: fixture.url, accessToken: "fixture", session: session)
            XCTFail("Expected deferral")
        } catch let failure as HTTPResponseFailure {
            XCTAssertEqual(failure.statusCode, 503)
            XCTAssertGreaterThan(try XCTUnwrap(failure.retryAfter), 3500)
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testMountsShareAccountQuotaButOtherAccountsStayIndependent() async throws {
        let scheduler = CloudRequestScheduler()
        let fixture = CloudHTTPFixture(responses: [.init(status: 429, headers: ["Retry-After": "3600"]), .init(status: 200)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        scheduler.register(sourceID: "mount-a", accountID: "account-one")
        scheduler.register(sourceID: "mount-b", accountID: "account-one")
        scheduler.register(sourceID: "mount-c", accountID: "account-two")
        for id in ["mount-a", "mount-b"] {
            do {
                _ = try await CloudDriveHelper(sourceID: id, requests: scheduler).makeAuthorizedRequest(
                    url: fixture.url, accessToken: "fixture", session: session)
                XCTFail("Expected account quota to be shared")
            } catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.statusCode, 429) }
        }
        _ = try await CloudDriveHelper(sourceID: "mount-c", requests: scheduler).makeAuthorizedRequest(
            url: fixture.url, accessToken: "fixture", session: session)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testPan123BusinessQuotaSurvivesHTTP200AndConnectorRecreation() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, headers: ["Retry-After": "3600"], body: Data(#"{"code":429,"message":"quota"}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        for _ in 0..<2 {
            let source = Pan123Source(sourceID: fixture.id, session: session, tokenProvider: { "fixture" })
            do { _ = try await source.listFiles(at: ""); XCTFail("Expected quota failure") }
            catch let failure as HTTPResponseFailure {
                XCTAssertEqual(failure.statusCode, 200)
                XCTAssertTrue(failure.isRateLimited)
                XCTAssertGreaterThan(try XCTUnwrap(failure.retryAfter), 3590)
                XCTAssertTrue(String(decoding: failure.body, as: UTF8.self).contains("429"))
            }
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testBaiduBusinessQuotaSurvivesHTTP200AndConnectorRecreation() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 200, headers: ["Retry-After": "3600"], body: Data(#"{"errno":31034}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        for _ in 0..<2 {
            let source = BaiduPanSource(sourceID: fixture.id, session: session, tokenProvider: { "fixture" })
            do { _ = try await source.listFiles(at: "/"); XCTFail("Expected quota failure") }
            catch let failure as HTTPResponseFailure {
                XCTAssertEqual(failure.statusCode, 200)
                XCTAssertTrue(failure.isRateLimited)
                XCTAssertGreaterThan(try XCTUnwrap(failure.retryAfter), 3590)
            }
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testGoogleQuota403KeepsReasonAndSharesCooldown() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 403, headers: ["Retry-After": "3600"],
            body: Data(#"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#.utf8))])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        for _ in 0..<2 {
            let source = GoogleDriveSource(sourceID: fixture.id, session: session, tokenProvider: { "fixture" })
            do { _ = try await source.listFiles(at: ""); XCTFail("Expected quota failure") }
            catch let failure as HTTPResponseFailure {
                XCTAssertEqual(failure.statusCode, 403)
                XCTAssertTrue(failure.isRateLimited)
                XCTAssertEqual(AutomaticOfflineFailureClassifier.classify(failure), .rateLimited)
                XCTAssertTrue(String(decoding: failure.body, as: UTF8.self).contains("userRateLimitExceeded"))
            }
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testOrdinaryGoogleAndBaidu403ArePermissionsWithoutRetry() async throws {
        for google in [true, false] {
            let fixture = CloudHTTPFixture(responses: [.init(status: 403,
                body: Data(#"{"error":{"errors":[{"reason":"insufficientFilePermissions"}]}}"#.utf8))])
            let session = fixture.session()
            defer { session.invalidateAndCancel(); fixture.remove() }
            do {
                if google {
                    _ = try await GoogleDriveSource(sourceID: fixture.id, session: session, tokenProvider: { "fixture" }).listFiles(at: "")
                } else {
                    _ = try await BaiduPanSource(sourceID: fixture.id, session: session, tokenProvider: { "fixture" }).listFiles(at: "/")
                }
                XCTFail("Expected permission rejection")
            } catch CloudDriveError.permissionDenied { }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testGuangYaSharesIPQuotaAcrossAccounts() async throws {
        let scheduler = CloudRequestScheduler()
        let fixture = CloudHTTPFixture(responses: [.init(status: 429, headers: ["Retry-After": "3600"])])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        for _ in 0..<2 {
            let source = GuangYaSource(sourceID: UUID().uuidString, session: session, tokenProvider: { "fixture" },
                configuration: .init(clientID: "fixture", projectID: "fixture", signSecret: "fixture"), requests: scheduler)
            do { _ = try await source.listFiles(at: ""); XCTFail("Expected shared IP quota") }
            catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.statusCode, 429) }
        }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertNotNil(fixture.requests.first?.value(forHTTPHeaderField: "sign"))
    }

    func testMixedGuangYaHTTPAndBusinessFailuresHaveOneAttemptBudget() async throws {
        let clock = CloudClock()
        let fixture = CloudHTTPFixture(responses: [.init(status: 500),
            .init(status: 200, body: Data(#"{"code":101,"msg":"temporary"}"#.utf8)),
            .init(status: 500), .init(status: 200, body: Data(#"{"code":101}"#.utf8)), .init(status: 500)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let source = GuangYaSource(sourceID: fixture.id, session: session, tokenProvider: { "fixture" },
            configuration: .init(clientID: "fixture", projectID: "fixture", signSecret: "fixture"),
            requests: CloudRequestScheduler(timing: clock.timing, jitter: { _ in 0 }))
        let task = Task { try await source.listFiles(at: "") }
        defer { task.cancel() }
        for delay in [0.5, 1.5, 3.5, 7.5] { try await clock.waitForSleep(at: delay); clock.advance(to: delay) }
        do { _ = try await task.value; XCTFail("Expected exhausted attempt budget") }
        catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.statusCode, 500) }
        XCTAssertEqual(fixture.requests.count, 5)
    }

    func testCancellingBackoffDoesNotSendAnotherRequest() async throws {
        let clock = CloudClock()
        let fixture = CloudHTTPFixture(responses: [.init(status: 500), .init(status: 200)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove() }
        let helper = CloudDriveHelper(sourceID: fixture.id, requests: CloudRequestScheduler(timing: clock.timing, jitter: { _ in 0 }))
        let task = Task { try await helper.makeAuthorizedRequest(url: fixture.url, accessToken: "fixture", session: session) }
        try await clock.waitForSleep(at: 0.5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testOfflineRecoveryDoesNotShortenCloudCooldowns() {
        XCTAssertNil(OfflineRangeDownloadRetry.delay(after: HTTPResponseFailure(statusCode: 429, retryAfter: 3600), failedAttempts: 1))
        XCTAssertEqual(OfflineRangeDownloadRetry.delay(after: HTTPResponseFailure(statusCode: 503, retryAfter: 12), failedAttempts: 1), 12)
        XCTAssertNil(OfflineRangeDownloadRetry.delay(after: HTTPResponseFailure(statusCode: 403), failedAttempts: 1))
    }

    func testTCPHeadersRetainLongSecondsAndHTTPDatesBeforeBodyRead() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "1994-11-06T08:49:37Z"))
        for (status, header, delay) in [(429, "3600", 3600.0), (503, "Sun, 06 Nov 1994 09:49:37 GMT", 3600.0)] {
            let data = Data("HTTP/1.1 \(status) Rejected\r\nRetry-After: \(header)\r\nContent-Length: 999999999\r\n".utf8)
            do { _ = try TCPRangeFetcher.parseResponseHead(data, now: now); XCTFail("Expected HTTP failure before reading body") }
            catch TCPRangeFetcher.FetchError.http(let failure) {
                XCTAssertEqual(failure.statusCode, status)
                XCTAssertEqual(failure.retryAfter, delay)
            }
        }
        do {
            _ = try TCPRangeFetcher.parseResponseHead(Data("HTTP/1.1 200 OK\r\nContent-Length: 999999999\r\n".utf8))
            XCTFail("Ignored Range must abort before full-file buffering")
        } catch TCPRangeFetcher.FetchError.http(let failure) { XCTAssertEqual(failure.statusCode, 200) }
    }

    func testRangeKeepsItsReadBoundOverARealLocalConnection() async throws {
        let server = try LocalCloudServer(response: .init(status: 206, body: Data(0..<8)))
        let url = try await server.start()
        defer { server.stop() }
        let helper = CloudDriveHelper(sourceID: UUID().uuidString)
        let data = try await helper.rangeRequest(url: url, offset: 0, length: 4)
        XCTAssertEqual(data, Data(0..<4))
        XCTAssertTrue(server.requestHeaders.lowercased().contains("range: bytes=0-3"))
    }

    func testIgnoredRangeDoesNotBecomeAFullFileResponse() async throws {
        let server = try LocalCloudServer(response: .init(status: 200, body: Data(repeating: 1, count: 65536)))
        let url = try await server.start()
        defer { server.stop() }
        do {
            _ = try await CloudDriveHelper(sourceID: UUID().uuidString).rangeRequest(url: url, offset: 0, length: 4)
            XCTFail("Expected ignored Range error")
        } catch CloudDriveError.apiError(let status, _) { XCTAssertEqual(status, 200) }
    }

    func testRangeAndStreamedDownloadsRetainRateLimitAndNeverPublishErrors() async throws {
        for download in [false, true] {
            for status in [429, 503] {
                let server = try LocalCloudServer(response: .init(status: status, headers: ["Retry-After": "3600"], body: Data("limited".utf8)))
                let url = try await server.start()
                let helper = CloudDriveHelper(sourceID: UUID().uuidString)
                let path = "fixture.flac"
                defer { server.stop(); try? FileManager.default.removeItem(at: helper.cacheDirectory.deletingLastPathComponent()) }
                do {
                    if download { _ = try await helper.downloadToCache(request: URLRequest(url: url), for: path) }
                    else { _ = try await helper.rangeRequest(url: url, offset: 0, length: 4) }
                    XCTFail("Expected HTTP failure")
                } catch let failure as HTTPResponseFailure {
                    XCTAssertEqual(failure.statusCode, status)
                    XCTAssertEqual(failure.retryAfter, 3600)
                }
                XCTAssertFalse(helper.hasCached(path: path))
                XCTAssertEqual(server.requestCount, 1)
            }
        }
    }

    func testStreamedDownloadPublishesCompleteFileAndReusesCache() async throws {
        let bytes = Data(repeating: 7, count: 65536)
        let server = try LocalCloudServer(response: .init(status: 200, body: bytes))
        let url = try await server.start()
        let helper = CloudDriveHelper(sourceID: UUID().uuidString)
        defer { server.stop(); try? FileManager.default.removeItem(at: helper.cacheDirectory.deletingLastPathComponent()) }
        let first = try await helper.downloadToCache(request: URLRequest(url: url), for: "fixture.flac")
        let second = try await helper.downloadToCache(request: URLRequest(url: url), for: "fixture.flac")
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(server.requestCount, 1)
    }

    func testTokenRecoveryConsumesExistingHTTPAttemptBudget() async throws {
        let clock = CloudClock()
        let fixture = CloudHTTPFixture(responses: [.init(status: 500), .init(status: 401), .init(status: 500)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove(); _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id) }
        let helper = CloudDriveHelper(sourceID: fixture.id, requests: CloudRequestScheduler(timing: clock.timing, jitter: { _ in 0 }))
        let saved = await helper.tokenManager.saveTokens(.init(accessToken: "old", refreshToken: "fixture-refresh"))
        XCTAssertTrue(saved, "The isolated simulator must support fixture Keychain credentials")
        let refreshes = CloudTestCounter()
        let task = Task {
            try await helper.withTokenRetry(initialToken: "old", refresh: { _ in
                refreshes.increment()
                return .init(accessToken: "new", refreshToken: "rotated-fixture")
            }) { token in
                try await helper.makeAuthorizedRequest(url: fixture.url, accessToken: token, session: session)
            }
        }
        defer { task.cancel() }
        for deadline in [0.5, 2.5, 6.5] { try await clock.waitForSleep(at: deadline); clock.advance(to: deadline) }
        do { _ = try await task.value; XCTFail("Expected exhausted HTTP budget") }
        catch let failure as HTTPResponseFailure { XCTAssertEqual(failure.statusCode, 500) }
        XCTAssertEqual(fixture.requests.count, 5)
        XCTAssertEqual(refreshes.value, 1)
        XCTAssertEqual(fixture.requests.map { $0.value(forHTTPHeaderField: "Authorization") ?? "" },
                       ["Bearer old", "Bearer old", "Bearer new", "Bearer new", "Bearer new"])
    }

    func testConcurrentTokenRejectionsStillShareOneRefresh() async throws {
        let clock = CloudClock()
        let fixture = CloudHTTPFixture(responses: [.init(status: 200)], responder: { request, _ in
            .init(status: request.value(forHTTPHeaderField: "Authorization") == "Bearer new" ? 200 : 401)
        })
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove(); _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id) }
        let helper = CloudDriveHelper(sourceID: fixture.id, requests: CloudRequestScheduler(timing: clock.timing))
        let saved = await helper.tokenManager.saveTokens(.init(accessToken: "old", refreshToken: "fixture-refresh"))
        XCTAssertTrue(saved)
        let refreshes = CloudTestCounter()
        let tasks = (0..<2).map { _ in Task {
            try await helper.withTokenRetry(initialToken: "old", refresh: { _ in
                refreshes.increment()
                try await clock.timing.sleep(0.1)
                return .init(accessToken: "new", refreshToken: "rotated-fixture")
            }) { token in
                try await helper.makeAuthorizedRequest(url: fixture.url, accessToken: token, session: session)
            }
        } }
        defer { tasks.forEach { $0.cancel() } }
        try await clock.waitForSleep(at: 0.1)
        for _ in 0..<10000 {
            if fixture.requests.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(fixture.requests.count, 2)
        clock.advance(to: 0.1)
        for task in tasks { _ = try await task.value }
        XCTAssertEqual(refreshes.value, 1)
        XCTAssertEqual(fixture.requests.count, 4)
    }

    func testRefreshedTokenIsNotRefreshedRepeatedly() async throws {
        let fixture = CloudHTTPFixture(responses: [.init(status: 401)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove(); _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id) }
        let helper = CloudDriveHelper(sourceID: fixture.id)
        let saved = await helper.tokenManager.saveTokens(.init(accessToken: "old", refreshToken: "fixture-refresh"))
        XCTAssertTrue(saved)
        let refreshes = CloudTestCounter()
        do {
            _ = try await helper.withTokenRetry(initialToken: "old", refresh: { _ in
                refreshes.increment()
                return .init(accessToken: "new", refreshToken: "rotated-fixture")
            }) { token in
                try await helper.makeAuthorizedRequest(url: fixture.url, accessToken: token, session: session)
            }
            XCTFail("Expected rejected credentials")
        } catch CloudDriveError.tokenExpired { }
        XCTAssertEqual(refreshes.value, 1)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testFinalAttemptAuthFailureCannotRestartTheBudgetOutsideExecutor() async throws {
        let clock = CloudClock()
        let fixture = CloudHTTPFixture(responses: [.init(status: 500), .init(status: 500), .init(status: 500), .init(status: 500), .init(status: 401)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove(); _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id) }
        let helper = CloudDriveHelper(sourceID: fixture.id, requests: CloudRequestScheduler(timing: clock.timing, jitter: { _ in 0 }))
        let saved = await helper.tokenManager.saveTokens(.init(accessToken: "old", refreshToken: "fixture"))
        XCTAssertTrue(saved)
        let refreshes = CloudTestCounter()
        let task = Task {
            try await helper.withTokenRetry(initialToken: "old", refresh: { _ in
                refreshes.increment(); return .init(accessToken: "new", refreshToken: "fixture")
            }) { token in
                try await helper.makeAuthorizedRequest(url: fixture.url, accessToken: token, session: session)
            }
        }
        defer { task.cancel() }
        for deadline in [0.5, 1.5, 3.5, 7.5] { try await clock.waitForSleep(at: deadline); clock.advance(to: deadline) }
        do { _ = try await task.value; XCTFail("Expected rejected token at exhausted budget") }
        catch CloudDriveError.tokenExpired { }
        XCTAssertEqual(fixture.requests.count, 5)
        XCTAssertEqual(refreshes.value, 0)
    }

    func testCancellingARequestStopsWaitingForSharedTokenRefresh() async throws {
        let clock = CloudClock()
        let fixture = CloudHTTPFixture(responses: [.init(status: 401)])
        let session = fixture.session()
        defer { session.invalidateAndCancel(); fixture.remove(); _ = CloudTokenManager.deleteStoredCredentials(for: fixture.id) }
        let helper = CloudDriveHelper(sourceID: fixture.id, requests: CloudRequestScheduler(timing: clock.timing))
        let saved = await helper.tokenManager.saveTokens(.init(accessToken: "old", refreshToken: "fixture"))
        XCTAssertTrue(saved)
        let finished = CloudTestCounter()
        let task = Task {
            defer { finished.increment() }
            return try await helper.withTokenRetry(initialToken: "old", refresh: { _ in
                try await clock.timing.sleep(100)
                return .init(accessToken: "new", refreshToken: "fixture")
            }) { token in
                try await helper.makeAuthorizedRequest(url: fixture.url, accessToken: token, session: session)
            }
        }
        try await clock.waitForSleep(at: 100)
        task.cancel()
        for _ in 0..<2000 {
            if finished.value == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(finished.value, 1, "Caller cancellation must not await the shared refresh")
        clock.advance(to: 100)
        _ = try await helper.tokenManager.refreshDeduped(.ifMatches("old"), refresh: { _ in
            XCTFail("The existing refresh should remain shared")
            return .init(accessToken: "new", refreshToken: "fixture")
        })
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

}

private final class CloudHTTPFixture: @unchecked Sendable {
    struct Response: Sendable {
        let status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
    }
    let id = UUID().uuidString
    var url: URL { URL(string: "https://fixture.invalid/\(id)")! }
    private let lock = NSLock()
    private let responses: [Response]
    private let responder: (@Sendable (URLRequest, Int) -> Response)?
    private var sent: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { sent } }
    init(responses: [Response], responder: (@Sendable (URLRequest, Int) -> Response)? = nil) {
        self.responses = responses
        self.responder = responder
    }
    func response(to request: URLRequest) -> Response {
        lock.withLock {
            sent.append(request)
            return responder?(request, sent.count) ?? responses[min(sent.count - 1, responses.count - 1)]
        }
    }
    func session() -> URLSession {
        CloudHTTPProtocol.fixtures.insert(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudHTTPProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Fixture-ID": id]
        return URLSession(configuration: configuration)
    }
    func remove() { CloudHTTPProtocol.fixtures.remove(id) }
}

private final class CloudHTTPFixtures: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: CloudHTTPFixture] = [:]
    func insert(_ fixture: CloudHTTPFixture) { lock.withLock { values[fixture.id] = fixture } }
    func remove(_ id: String) { _ = lock.withLock { values.removeValue(forKey: id) } }
    func get(_ id: String) -> CloudHTTPFixture? { lock.withLock { values[id] } }
}

private final class CloudHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let fixtures = CloudHTTPFixtures()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Fixture-ID"),
              let fixture = Self.fixtures.get(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let result = fixture.response(to: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: result.status,
                                       httpVersion: "HTTP/1.1", headerFields: result.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CloudClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 0
    private var recorded: [TimeInterval] = []
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    var now: TimeInterval { lock.withLock { instant } }
    var starts: [TimeInterval] { lock.withLock { recorded } }
    func recordStart() { lock.withLock { recorded.append(instant) } }
    func advance(to value: TimeInterval) {
        let ready = lock.withLock {
            instant = value
            let ready = sleepers.filter { $0.value.0 <= value }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return Array(ready.values)
        }
        for (_, continuation) in ready { continuation.resume() }
    }
    private func sleep(_ interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { sleepers[id] = (instant + interval, continuation) }
                }
            }
        } onCancel: {
            self.lock.withLock { self.sleepers.removeValue(forKey: id) }?.1.resume(throwing: CancellationError())
        }
    }
    func waitForSleep(at deadline: TimeInterval, count: Int = 1) async throws {
        for _ in 0..<10000 {
            if lock.withLock({ sleepers.values.filter { abs($0.0 - deadline) < 0.00001 }.count >= count }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    var timing: RequestExecutor.Timing {
        .init(now: { self.now }, sleep: { try await self.sleep($0) })
    }
}

/// An in-process HTTP peer exercises URLSession bytes/download transports,
/// including temporary-file creation. It never contacts a provider.
private final class LocalCloudServer: @unchecked Sendable {
    private let listener: NWListener
    private let response: CloudHTTPFixture.Response
    private let queue = DispatchQueue(label: "CloudRequestTests.server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var headers: [String] = []
    var requestCount: Int { lock.withLock { headers.count } }
    var requestHeaders: String { lock.withLock { headers.joined(separator: "\n") } }

    init(response: CloudHTTPFixture.Response) throws {
        self.response = response
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.lock.withLock { self.connections.append(connection) }
            connection.start(queue: self.queue)
            self.receive(connection, buffered: Data())
        }
    }
    func start() async throws -> URL {
        listener.start(queue: queue)
        for _ in 0..<10000 {
            if let port = listener.port, port.rawValue != 0 { return URL(string: "http://127.0.0.1:\(port.rawValue)/fixture")! }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }
    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var input = buffered
            input.append(data ?? Data())
            guard input.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete { connection.cancel() }
                else { self.receive(connection, buffered: input) }
                return
            }
            self.lock.withLock { self.headers.append(String(decoding: input, as: UTF8.self)) }
            var head = "HTTP/1.1 \(self.response.status) Fixture\r\nConnection: close\r\nContent-Length: \(self.response.body.count)\r\n"
            for (key, value) in self.response.headers { head += "\(key): \(value)\r\n" }
            var payload = Data((head + "\r\n").utf8)
            payload.append(self.response.body)
            connection.send(content: payload, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private final class CloudTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
