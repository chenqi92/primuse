import Foundation
import XCTest
import PrimuseKit
@testable import Primuse

final class WebDAVDirectoryQuotaTests: XCTestCase {
    func testLongCooldownSurvivesAnotherDirectoryAndConnector() async throws {
        let fixture = DirectoryQuotaFixture { request in
            if request.url!.path.contains("/A") { return (429, ["Retry-After": "3600"], Data()) }
            return DirectoryQuotaFixture.listing(request)
        }
        let host = UUID().uuidString + ".invalid"
        let first = makeSource(fixture, host: host)
        let second = makeSource(fixture, host: host)
        try await first.connect()
        try await second.connect()
        for (source, path) in [(first, "/A"), (first, "/B"), (second, "/C")] {
            do { _ = try await source.listFiles(at: path); XCTFail("A shared directory cooldown must stop this call") }
            catch let error as RemoteDirectoryHTTPStatusError {
                XCTAssertEqual(error.statusCode, 429)
                XCTAssertTrue(error.isRateLimited)
                XCTAssertGreaterThan(error.retryAfter ?? 0, 3590)
            }
        }
        XCTAssertEqual(fixture.requests.count, 3, "Only two connects and the initial limited PROPFIND may reach transport")
        fixture.clock.advance(to: 3599)
        let nearDeadline = Task { try await second.listFiles(at: "/B") }
        defer { nearDeadline.cancel() }
        try await fixture.clock.waitForSleep(at: 3600)
        XCTAssertEqual(fixture.requests.count, 3, "No PROPFIND may send before the complete server deadline")
        fixture.clock.advance(to: 3600)
        let files = try await nearDeadline.value
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(fixture.requests.count, 4)
    }

    func testExplicit503SecondsAndDateSurviveReconnectAndCredentialRotation() async throws {
        for header in ["3600", "Tue, 14 Nov 2023 23:13:20 GMT"] {
            let fixture = DirectoryQuotaFixture { request in
                if request.url!.path.contains("/A") { return (503, ["Retry-After": header], Data()) }
                return DirectoryQuotaFixture.listing(request)
            }
            let host = UUID().uuidString + ".invalid"
            let source = makeSource(fixture, host: host)
            try await source.connect()
            do { _ = try await source.listFiles(at: "/A"); XCTFail("Expected explicit service cooldown") }
            catch let error as RemoteDirectoryHTTPStatusError {
                XCTAssertEqual(error.statusCode, 503)
                XCTAssertTrue(error.isRateLimited)
                XCTAssertEqual(error.retryAfter, 3600)
            }
            await source.disconnect()
            let replacement = makeSource(fixture, host: host.uppercased(), password: "rotated-fixture")
            for candidate in [source, replacement] {
                do { try await candidate.connect(); XCTFail("Reconnection must retain the account deadline") }
                catch let error as RemoteDirectoryHTTPStatusError {
                    XCTAssertEqual(error.statusCode, 503)
                    XCTAssertEqual(error.retryAfter, 3600)
                }
            }
            XCTAssertEqual(fixture.requests.count, 2)
        }
    }

    func testOtherAccountsEndpointsAndRangeReadsRemainUsable() async throws {
        let fixture = DirectoryQuotaFixture { request in
            if request.httpMethod == "GET" {
                return (206, ["Content-Type": "audio/flac", "Content-Range": "bytes 0-3/100", "Content-Length": "4"], Data("fLaC".utf8))
            }
            if request.url!.path.contains("/A") { return (429, ["Retry-After": "3600"], Data()) }
            return DirectoryQuotaFixture.listing(request)
        }
        let host = UUID().uuidString + ".invalid"
        let source = makeSource(fixture, host: host)
        try await source.connect()
        _ = try? await source.listFiles(at: "/A")
        let data = try await source.fetchRange(path: "/song.flac", offset: 0, length: 4)
        XCTAssertEqual(data, Data("fLaC".utf8))
        XCTAssertEqual(fixture.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=0-3")
        XCTAssertEqual(fixture.requests.last?.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("reader:fixture".utf8).base64EncodedString())
        for other in [makeSource(fixture, host: host, username: "other"),
                      makeSource(fixture, host: host, port: 8443),
                      makeSource(fixture, host: "other." + host)] {
            try await other.connect()
        }
        XCTAssertEqual(fixture.requests.count, 6)
    }

    func testHeaderless429HasFiniteWaitsAndCancellationDoesNotResetCooldown() async throws {
        let fixture = DirectoryQuotaFixture { request in
            if request.url!.path.contains("/A") { return (429, [:], Data()) }
            return DirectoryQuotaFixture.listing(request)
        }
        let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
        try await source.connect()
        let limited = Task { try await source.listFiles(at: "/A") }
        defer { limited.cancel() }
        for deadline: TimeInterval in [2, 7, 17] {
            try await fixture.clock.waitForSleep(at: deadline)
            fixture.clock.advance(to: deadline)
        }
        do { _ = try await limited.value; XCTFail("A fourth wait must not be scheduled") }
        catch let error as RemoteDirectoryHTTPStatusError {
            XCTAssertEqual(error.statusCode, 429)
            XCTAssertEqual(error.retryAfter, 10)
        }
        XCTAssertEqual(fixture.requests.count, 5, "One connect plus exactly four attempts, without nested executor retries")
        let next = Task { try await source.listFiles(at: "/B") }
        defer { next.cancel() }
        try await fixture.clock.waitForSleep(at: 27)
        XCTAssertEqual(fixture.requests.count, 5)
        next.cancel()
        do { _ = try await next.value; XCTFail("Waiting directory cancellation must finish") }
        catch { XCTAssertTrue(OperationCancellationPolicy.isCancellation(error)) }
        fixture.clock.advance(to: 27)
        _ = try await source.listFiles(at: "/B")
        XCTAssertEqual(fixture.requests.count, 6)
    }

    func testOrdinary503DoesNotBlockAnotherDirectoryOrAddNestedRetries() async throws {
        for headers in [[:], ["Retry-After": "malformed"]] {
            let fixture = DirectoryQuotaFixture { request in
                if request.url!.path.contains("/slow") { return (503, headers, Data()) }
                return DirectoryQuotaFixture.listing(request)
            }
            let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
            try await source.connect()
            do { _ = try await source.listFiles(at: "/slow"); XCTFail("The directory must still fail") }
            catch SourceError.connectionFailed { }
            _ = try await source.listFiles(at: "/healthy")
            XCTAssertEqual(fixture.requests.count, 4, "One connect, two transient attempts, one healthy directory")
        }
    }

    func testCancellingAnInflightDirectoryReleasesItsAdmission() async throws {
        let fixture = DirectoryQuotaFixture { request in
            if request.url!.path.contains("/held") { return nil }
            return DirectoryQuotaFixture.listing(request)
        }
        let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
        try await source.connect()
        let pending = Task { try await source.listFiles(at: "/held") }
        defer { pending.cancel() }
        try await fixture.waitForRequests(2)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled transport must complete promptly") }
        catch { XCTAssertTrue(OperationCancellationPolicy.isCancellation(error)) }
        _ = try await source.listFiles(at: "/healthy")
        XCTAssertEqual(fixture.requests.count, 3)
    }

    func testFreshEmptyConfirmationPreservesListingAndHTTPContracts() async throws {
        let fixture = DirectoryQuotaFixture { request in
            if request.url!.path.contains("/missing") { return (404, [:], Data()) }
            if request.url!.path.contains("/denied") { return (403, [:], Data()) }
            return DirectoryQuotaFixture.listing(request)
        }
        let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
        try await source.connect()
        let files = try await source.listFiles(at: "/empty", confirmingPreviouslyObservedPaths: ["/empty/old.flac"])
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(fixture.requests.filter { $0.url?.path == "/Music/empty" || $0.url?.path == "/Music/empty/" }.count, 2)
        do { _ = try await source.listFiles(at: "/missing"); XCTFail("Missing directory must retain its path error") }
        catch SourceError.pathNotFound(let path) { XCTAssertEqual(path, "/missing") }
        do { _ = try await source.listFiles(at: "/denied"); XCTFail("Permission failure must not become a quota") }
        catch SourceError.authenticationFailed { }
        _ = try await source.listFiles(at: "/healthy")
        XCTAssertEqual(fixture.requests.count, 6)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.httpMethod == "PROPFIND" && $0.value(forHTTPHeaderField: "Depth") == "1" })
    }

    func testDirectoryBodyLimitAndMalformedXMLRemainFailures() async throws {
        for body in [Data(repeating: 32, count: 16 * 1024 * 1024 + 1), Data("<broken>".utf8)] {
            let fixture = DirectoryQuotaFixture { request in
                if request.url!.path.contains("/invalid") { return (207, [:], body) }
                return DirectoryQuotaFixture.listing(request)
            }
            let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
            try await source.connect()
            do { _ = try await source.listFiles(at: "/invalid"); XCTFail("Invalid data must never become an authoritative empty listing") }
            catch {
                if body.count > 16 * 1024 * 1024 {
                    XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
                } else if case SourceError.connectionFailed = error { }
                else { XCTFail("Unexpected XML failure: \(error)") }
            }
            _ = try await source.listFiles(at: "/healthy")
        }
    }

    func testPopulatedDirectoryRetainsPathScopeAndProperties() async throws {
        let fixture = DirectoryQuotaFixture { request in
            let response = DirectoryQuotaFixture.listing(request)
            let prefix = request.url!.path.hasSuffix("/") ? request.url!.path : request.url!.path + "/"
            let child = """
            <D:response><D:href>\(prefix)track%20%26%20song.flac</D:href><D:propstat><D:prop>
            <D:displayname>Track &amp; Song</D:displayname><D:getcontentlength>123</D:getcontentlength>
            <D:getetag>fixture</D:getetag><D:resourcetype/></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
            """
            let xml = String(decoding: response.2, as: UTF8.self).replacingOccurrences(of: "</D:multistatus>", with: child + "</D:multistatus>")
            return (207, response.1, Data(xml.utf8))
        }
        let source = makeSource(fixture, host: UUID().uuidString + ".invalid")
        try await source.connect()
        let files = try await source.listFiles(at: "/日本語")
        XCTAssertEqual(files.map(\.path), ["/日本語/track & song.flac"])
        XCTAssertEqual(files.first?.name, "Track & Song")
        XCTAssertEqual(files.first?.size, 123)
        XCTAssertEqual(files.first?.revision, "fixture")
    }

    private func makeSource(_ fixture: DirectoryQuotaFixture, host: String, port: Int? = nil,
                            username: String = "reader", password: String = "fixture") -> WebDAVSource {
        let id = "webdav-quota-" + UUID().uuidString
        let source = WebDAVSource(sourceID: id, host: host, port: port, useSsl: true, basePath: "/Music",
                                  username: username, password: password, sessionConfiguration: { fixture.configuration() },
                                  quotaRegistry: fixture.registry, directoryTiming: fixture.clock.timing)
        addTeardownBlock {
            await source.disconnect()
            fixture.close()
            let cache = FileManager.default.temporaryDirectory.appendingPathComponent("primuse_webdav_cache").appendingPathComponent(id)
            try? FileManager.default.removeItem(at: cache)
        }
        return source
    }
}

private final class DirectoryQuotaFixture: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)?
    let id = UUID().uuidString
    let clock = DirectoryQuotaClock()
    let registry: RequestQuotaRegistry
    private let handler: Handler
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { captured } }
    init(_ handler: @escaping Handler) {
        self.handler = handler
        registry = RequestQuotaRegistry(timing: clock.timing)
        DirectoryQuotaProtocol.register(self)
    }
    func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DirectoryQuotaProtocol.self]
        config.httpAdditionalHeaders = ["X-Directory-Fixture": id]
        return config
    }
    func close() { DirectoryQuotaProtocol.remove(id) }
    func response(_ request: URLRequest) -> (Int, [String: String], Data)? {
        lock.withLock { captured.append(request) }
        return handler(request)
    }
    func waitForRequests(_ count: Int) async throws {
        for _ in 0..<2000 {
            if requests.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    static func listing(_ request: URLRequest) -> (Int, [String: String], Data) {
        var path = request.url!.path
        if !path.hasSuffix("/") { path += "/" }
        return (207, ["Content-Type": "application/xml"], Data("""
        <D:multistatus xmlns:D="DAV:"><D:response><D:href>\(path)</D:href>
        <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
        """.utf8))
    }
}

private final class DirectoryQuotaProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: DirectoryQuotaFixture] = [:]
    static func register(_ fixture: DirectoryQuotaFixture) { lock.withLock { fixtures[fixture.id] = fixture } }
    static func remove(_ id: String) { _ = lock.withLock { fixtures.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let fixture = Self.lock.withLock({ Self.fixtures[request.value(forHTTPHeaderField: "X-Directory-Fixture") ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        guard let (status, headers, body) = fixture.response(request) else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DirectoryQuotaClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 0
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    var now: TimeInterval { lock.withLock { instant } }
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
    func waitForSleep(at deadline: TimeInterval) async throws {
        for _ in 0..<2000 {
            if lock.withLock({ sleepers.values.contains { abs($0.0 - deadline) < 0.00001 } }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    var timing: RequestExecutor.Timing {
        .init(now: { self.now }, date: { Date(timeIntervalSince1970: 1_700_000_000 + self.now) },
              sleep: { try await self.sleep($0) })
    }
}
