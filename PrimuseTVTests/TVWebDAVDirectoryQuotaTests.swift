#if os(tvOS)
import Foundation
import CryptoKit
import Network
import PrimuseKit
import XCTest
@testable import PrimuseTV

final class TVWebDAVDirectoryQuotaTests: XCTestCase {
    func testLongCooldownStopsAnotherDirectoryAndNewListerUntilExactExpiry() async throws {
        let fixture = TVDirectoryQuotaFixture { request in
            if request.url!.path.contains("/A") { return (429, ["Retry-After": "3600"], Data()) }
            return TVDirectoryQuotaFixture.listing(request)
        }
        defer { fixture.close() }
        let host = UUID().uuidString + ".invalid"
        let first = try makeLister(fixture, host: host)
        let second = try makeLister(fixture, host: host)
        for (lister, path) in [(first, "/A"), (first, "/B"), (second, "/C")] {
            do { _ = try await lister.list(path); XCTFail("Expected a shared directory cooldown") }
            catch let error as RemoteDirectoryHTTPStatusError {
                XCTAssertEqual(error.statusCode, 429)
                XCTAssertEqual(error.retryAfter, 3600)
                XCTAssertTrue(error.isRateLimited)
            }
        }
        XCTAssertEqual(fixture.requests.count, 1)
        fixture.clock.advance(to: 3599)
        let nearExpiry = Task { try await second.list("/B") }
        defer { nearExpiry.cancel() }
        try await fixture.clock.waitForSleep(at: 3600)
        XCTAssertEqual(fixture.requests.count, 1, "No request may send before the full server deadline")
        fixture.clock.advance(to: 3600)
        let files = try await nearExpiry.value
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testHeaderless429HasFiniteWaitsAndCancellationRetainsDeadline() async throws {
        let fixture = TVDirectoryQuotaFixture { request in
            if request.url!.path.contains("/A") { return (429, [:], Data()) }
            return TVDirectoryQuotaFixture.listing(request)
        }
        defer { fixture.close() }
        let lister = try makeLister(fixture)
        let limited = Task { try await lister.list("/A") }
        defer { limited.cancel() }
        for deadline: TimeInterval in [2, 7, 17] {
            try await fixture.clock.waitForSleep(at: deadline)
            fixture.clock.advance(to: deadline)
        }
        do { _ = try await limited.value; XCTFail("The fourth response must finish the call") }
        catch let error as RemoteDirectoryHTTPStatusError {
            XCTAssertEqual(error.statusCode, 429)
            XCTAssertEqual(error.retryAfter, 10)
            XCTAssertTrue(error.isRateLimited)
        }
        XCTAssertEqual(fixture.requests.count, 4, "The registry must not add a second retry budget")
        let waiting = Task { try await lister.list("/B") }
        defer { waiting.cancel() }
        try await fixture.clock.waitForSleep(at: 27)
        XCTAssertEqual(fixture.requests.count, 4)
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelling a cooldown wait must finish promptly") }
        catch { XCTAssertTrue(OperationCancellationPolicy.isCancellation(error)) }
        fixture.clock.advance(to: 27)
        let files = try await lister.list("/B")
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(fixture.requests.count, 5, "The cancelled operation must not replay after expiry")
    }

    func test503SecondsAndHTTPDateSurviveNewRootAndPasswordRotation() async throws {
        for header in ["3600", "Tue, 14 Nov 2023 23:13:20 GMT"] {
            let fixture = TVDirectoryQuotaFixture { _ in (503, ["Retry-After": header], Data()) }
            defer { fixture.close() }
            let host = UUID().uuidString + ".invalid"
            let first = try makeLister(fixture, host: host)
            let replacement = try makeLister(fixture, host: host.uppercased(), password: "rotated", basePath: "/AnotherRoot")
            for lister in [first, replacement] {
                do { _ = try await lister.list("/"); XCTFail("Expected an explicit service cooldown") }
                catch let error as RemoteDirectoryHTTPStatusError {
                    XCTAssertEqual(error.statusCode, 503)
                    XCTAssertEqual(error.retryAfter, 3600)
                    XCTAssertTrue(error.isRateLimited)
                }
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testOrdinaryServerFailuresDoNotCoolHealthyDirectories() async throws {
        for (status, headers) in [(503, [:]), (503, ["Retry-After": "malformed"]), (500, ["Retry-After": "3600"])] {
            let fixture = TVDirectoryQuotaFixture { request in
                if request.url!.path.contains("/slow") { return (status, headers, Data()) }
                return TVDirectoryQuotaFixture.listing(request)
            }
            defer { fixture.close() }
            let lister = try makeLister(fixture)
            do { _ = try await lister.list("/slow"); XCTFail("The failing directory must still fail") }
            catch let error as RemoteDirectoryHTTPStatusError {
                XCTAssertEqual(error.statusCode, status)
                XCTAssertFalse(error.isRateLimited)
                XCTAssertNil(error.retryAfter)
            }
            let files = try await lister.list("/healthy")
            XCTAssertTrue(files.isEmpty)
            XCTAssertEqual(fixture.requests.count, 2, "An ordinary failure keeps the old single-attempt behavior")
        }
    }

    func testDifferentAccountsHostsPortsAndSchemesRemainIndependent() async throws {
        let fixture = TVDirectoryQuotaFixture { request in
            if request.url!.path.contains("/A") { return (429, ["Retry-After": "3600"], Data()) }
            return TVDirectoryQuotaFixture.listing(request)
        }
        defer { fixture.close() }
        // LAN HTTP stays on URLSession; public cleartext trust is tested separately.
        let host = "127.0.0.1"
        let first = try makeLister(fixture, host: host)
        do { _ = try await first.list("/A"); XCTFail("Expected a directory limit") }
        catch let error as RemoteDirectoryHTTPStatusError { XCTAssertTrue(error.isRateLimited) }
        for lister in [try makeLister(fixture, host: host, username: "other"),
                       try makeLister(fixture, host: host, port: 8443),
                       try makeLister(fixture, host: "other.invalid"),
                       try makeLister(fixture, host: host, useSSL: false)] {
            let files = try await lister.list("/")
            XCTAssertTrue(files.isEmpty)
        }
        XCTAssertEqual(fixture.requests.count, 5)
    }

    func testInflightCancellationAndTimeoutReleaseAdmission() async throws {
        for cancel in [true, false] {
            let fixture = TVDirectoryQuotaFixture { request in
                if request.url!.path.contains("/held") { return nil }
                return TVDirectoryQuotaFixture.listing(request)
            }
            defer { fixture.close() }
            let lister = try makeLister(fixture)
            let pending = Task { try await lister.list("/held") }
            defer { pending.cancel() }
            try await fixture.waitForRequests(1)
            if cancel { pending.cancel() }
            else {
                try await fixture.clock.waitForSleep(at: 600)
                fixture.clock.advance(to: 600)
            }
            do { _ = try await pending.value; XCTFail("The held transport must finish promptly") }
            catch {
                if cancel { XCTAssertTrue(OperationCancellationPolicy.isCancellation(error)) }
                else { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
            }
            let files = try await lister.list("/healthy")
            XCTAssertTrue(files.isEmpty)
            XCTAssertEqual(fixture.requests.count, 2)
        }
    }

    func testRetryWaitDoesNotRestartOverallTimeout() async throws {
        let clock = TVDirectoryQuotaClock()
        let fixture = TVDirectoryQuotaFixture(clock: clock) { _ in
            clock.now == 0 ? (429, ["Retry-After": "2"], Data()) : nil
        }
        defer { fixture.close() }
        let lister = try makeLister(fixture)
        let pending = Task { try await lister.list("/") }
        defer { pending.cancel() }
        try await clock.waitForSleep(at: 2)
        clock.advance(to: 2)
        try await fixture.waitForRequests(2)
        try await clock.waitForSleep(at: 600)
        clock.advance(to: 600)
        do { _ = try await pending.value; XCTFail("The retry must share the original total deadline") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testHTTPAndInvalidBodyFailuresNeverBecomeEmptyListings() async throws {
        let oversized = Data(repeating: 32, count: 16 * 1024 * 1024 + 1)
        let invalidBodies = [Data("<broken>".utf8), Data("<html/>".utf8), oversized]
        for (index, body) in invalidBodies.enumerated() {
            let fixture = TVDirectoryQuotaFixture { _ in (207, ["Content-Length": String(body.count)], body) }
            defer { fixture.close() }
            let lister = try makeLister(fixture)
            do { _ = try await lister.list("/"); XCTFail("Invalid body must not authorize removing unseen files") }
            catch {
                if index == 2 { XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum) }
                else if case SourceError.connectionFailed = error {} else { XCTFail("Unexpected XML error: \(error)") }
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
        for status in [401, 403, 404] {
            let fixture = TVDirectoryQuotaFixture { _ in (status, [:], Data()) }
            defer { fixture.close() }
            let lister = try makeLister(fixture)
            do { _ = try await lister.list("/missing"); XCTFail("HTTP errors must fail the directory") }
            catch SourceError.pathNotFound(let path) { XCTAssertEqual(status, 404); XCTAssertEqual(path, "/missing") }
            catch SourceError.authenticationFailed { XCTAssertTrue([401, 403].contains(status)) }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testListingRetainsUnicodeRootPropertiesVisibilityAndCredentials() async throws {
        let fixture = TVDirectoryQuotaFixture { request in
            let listing = TVDirectoryQuotaFixture.listing(request)
            let children = """
            <D:response><D:href>/Music/日本語/track%20%26%20song.flac</D:href><D:propstat><D:prop>
            <D:displayname>Track &amp; Song</D:displayname><D:getcontentlength>123</D:getcontentlength>
            <D:getlastmodified>Tue, 14 Nov 2023 22:13:20 GMT</D:getlastmodified><D:resourcetype/>
            </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
            <D:response><D:href>/Music/日本語/sub/</D:href><D:propstat><D:prop>
            <D:resourcetype><D:collection/></D:resourcetype></D:prop>
            <D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
            <D:response><D:href>/Music/日本語/.hidden</D:href></D:response>
            <D:response><D:href>/Music-old/escape.flac</D:href></D:response>
            <D:response><D:href>/Music/日本語/denied.flac</D:href><D:status>HTTP/1.1 403 Forbidden</D:status></D:response>
            """
            return (207, listing.1, Data(String(decoding: listing.2, as: UTF8.self)
                .replacingOccurrences(of: "</D:multistatus>", with: children + "</D:multistatus>").utf8))
        }
        defer { fixture.close() }
        let lister = try makeLister(fixture, basePath: " /Music/ ")
        let entries = try await lister.list("日本語")
        XCTAssertEqual(Set(entries.map(\.path)), ["/日本語/track & song.flac", "/日本語/sub"])
        let song = try XCTUnwrap(entries.first { !$0.isDir })
        XCTAssertEqual(song.name, "Track & Song")
        XCTAssertEqual(song.size, 123)
        XCTAssertEqual(song.parentPath, "/日本語")
        XCTAssertEqual(song.modifiedDate, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(entries.filter(\.isDir).count, 1)
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(request.httpMethod, "PROPFIND")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "1")
        XCTAssertEqual(request.url?.path, "/Music/日本語")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("reader:fixture".utf8).base64EncodedString())
        do { _ = try await lister.list("../outside"); XCTFail("A parent reference must not send") }
        catch SourceError.pathNotFound { }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    @MainActor
    func testLimitedScanKeepsPendingDirectoriesAndCannotPrune() async throws {
        let fixture = TVDirectoryQuotaFixture { _ in (429, ["Retry-After": "3600"], Data()) }
        defer { fixture.close() }
        let lister = try makeLister(fixture)
        let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let scanner = TVSourceScanner(metadataInspections: TVMetadataInspectionStore(url: storeURL))
        let result = await scanner.scan(source: MusicSource(name: "Fixture", type: .webdav), lister: lister,
            dirs: ["/A", "/B"], credential: nil, existingSongs: [], onSkeletonBatch: { _ in }, onMetadataBatch: { _ in })
        XCTAssertFalse(result.enumerationCompleted)
        XCTAssertFalse(result.canPrune)
        XCTAssertEqual(result.resumeState.pendingDirectories, ["/A", "/B"])
        if case .enumerationFailed = result.completion {} else { XCTFail("Expected resumable enumeration failure") }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    @MainActor
    func testPublicHTTPUsesTVTrustBeforeSending() async throws {
        let fixture = TVDirectoryQuotaFixture { _ in XCTFail("Denied public HTTP must not send"); return nil }
        defer { fixture.close() }
        let host = UUID().uuidString.lowercased() + ".invalid"
        let lister = try makeLister(fixture, host: host, useSSL: false)
        let pending = Task { try await lister.list("/") }
        defer { pending.cancel() }
        let store = TVServerCertificateTrustStore.shared
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.pendingInsecureHTTPRequest == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let request = try XCTUnwrap(store.pendingInsecureHTTPRequest)
        XCTAssertEqual(request.endpoint, "http://\(host):80")
        XCTAssertEqual(fixture.requests.count, 0)
        store.resolvePendingInsecureHTTPRequest(approved: false)
        do { _ = try await pending.value; XCTFail("Denied HTTP must fail") }
        catch { XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired) }
    }

    func testRealDigestChallengeAndRejectedPasswordHaveBoundedRequests() async throws {
        let server = try TVWebDAVHTTPServer { request in
            if TVWebDAVHTTPServer.validDigest(request) { return TVWebDAVHTTPServer.listing() }
            return (401, ["WWW-Authenticate": "Digest realm=\"PrimuseFixture\", nonce=\"quota-nonce\", qop=\"auth\", algorithm=MD5"], Data())
        }
        let port = try await server.start()
        defer { server.stop() }
        let source = MusicSource(name: "Digest fixture", type: .webdav, host: "127.0.0.1",
                                 port: Int(port), useSsl: false, basePath: "/Music")
        let lister = try XCTUnwrap(TVWebDAVDirectoryLister(source: source,
            credential: SourceCredential(username: "reader", password: "fixture")))
        let files = try await lister.list("/")
        XCTAssertTrue(files.isEmpty)
        XCTAssertEqual(server.requests.count, 2, "One challenge and one authenticated PROPFIND")
        XCTAssertTrue(TVWebDAVHTTPServer.validDigest(try XCTUnwrap(server.requests.last)))
        let rejected = try XCTUnwrap(TVWebDAVDirectoryLister(source: source,
            credential: SourceCredential(username: "reader", password: "wrong")))
        do { _ = try await rejected.list("/"); XCTFail("An incorrect password must fail") }
        catch { XCTAssertFalse(OperationCancellationPolicy.isCancellation(error)) }
        XCTAssertLessThanOrEqual(server.requests.count, 5, "Rejected credentials must not loop or acquire quota retries")
    }

    func testRealMediaRangeRemainsUsableDuringDirectoryCooldown() async throws {
        let server = try TVWebDAVHTTPServer { request in
            if request.httpMethod == "PROPFIND" { return (429, ["Retry-After": "3600"], Data()) }
            return (206, ["Content-Range": "bytes 0-3/100", "Content-Type": "audio/flac"], Data("fLaC".utf8))
        }
        let port = try await server.start()
        defer { server.stop() }
        let source = MusicSource(name: "Range fixture", type: .webdav, host: "127.0.0.1",
                                 port: Int(port), useSsl: false, basePath: "/Music")
        let credential = SourceCredential(username: "reader", password: "fixture")
        let lister = try XCTUnwrap(TVWebDAVDirectoryLister(source: source, credential: credential))
        do { _ = try await lister.list("/"); XCTFail("Expected a directory limit") }
        catch let error as RemoteDirectoryHTTPStatusError { XCTAssertEqual(error.statusCode, 429) }
        let pool = TVMetadataReaderPool(source: source, credential: credential)
        let bytes = try await pool.read(path: "/song.flac", size: 100, offset: 0, length: 4)
        await pool.closeAll()
        XCTAssertEqual(bytes, Data("fLaC".utf8))
        XCTAssertEqual(server.requests.map(\.httpMethod), ["PROPFIND", "GET"])
        XCTAssertEqual(server.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=0-3")
        XCTAssertEqual(server.requests.last?.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("reader:fixture".utf8).base64EncodedString())
    }

    func testRealRedirectPreservesPROPFINDAndRejectsForeignEndpoint() async throws {
        let foreign = try TVWebDAVHTTPServer { _ in TVWebDAVHTTPServer.listing() }
        let foreignPort = try await foreign.start()
        defer { foreign.stop() }
        for location in ["/Music/canonical/", "http://127.0.0.1:\(foreignPort)/Music/"] {
            let server = try TVWebDAVHTTPServer { request in
                if request.url?.path == "/Music" { return (307, ["Location": location], Data()) }
                return TVWebDAVHTTPServer.listing()
            }
            let port = try await server.start()
            defer { server.stop() }
            let source = MusicSource(name: "Redirect fixture", type: .webdav, host: "127.0.0.1",
                                     port: Int(port), useSsl: false, basePath: "/Music")
            let lister = try XCTUnwrap(TVWebDAVDirectoryLister(source: source,
                credential: SourceCredential(username: "reader", password: "fixture")))
            if location.hasPrefix("/") {
                let files = try await lister.list("/")
                XCTAssertTrue(files.isEmpty)
                XCTAssertEqual(server.requests.count, 2)
                let redirected = try XCTUnwrap(server.requests.last)
                XCTAssertEqual(redirected.httpMethod, "PROPFIND")
                XCTAssertEqual(redirected.httpBody, server.requests.first?.httpBody)
                XCTAssertEqual(redirected.value(forHTTPHeaderField: "Depth"), "1")
                XCTAssertEqual(redirected.value(forHTTPHeaderField: "Authorization"), server.requests.first?.value(forHTTPHeaderField: "Authorization"))
            } else {
                do { _ = try await lister.list("/"); XCTFail("Credentials must not follow a foreign endpoint") }
                catch let error as RemoteDirectoryHTTPStatusError { XCTAssertEqual(error.statusCode, 307) }
                XCTAssertEqual(server.requests.count, 1)
                XCTAssertTrue(foreign.requests.isEmpty)
            }
        }
    }

    private func makeLister(_ fixture: TVDirectoryQuotaFixture, host: String = UUID().uuidString + ".invalid",
                            port: Int? = nil, username: String = "reader", password: String = "fixture",
                            basePath: String = "/Music", useSSL: Bool = true) throws -> TVWebDAVDirectoryLister {
        let source = MusicSource(name: "Directory fixture", type: .webdav, host: host, port: port,
                                 useSsl: useSSL, basePath: basePath)
        return try XCTUnwrap(TVWebDAVDirectoryLister(source: source,
            credential: SourceCredential(username: username, password: password),
            sessionConfiguration: { fixture.configuration() }, quotaRegistry: fixture.registry, timing: fixture.clock.timing))
    }

}

private final class TVDirectoryQuotaFixture: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)?
    let id = UUID().uuidString
    let clock: TVDirectoryQuotaClock
    let registry: RequestQuotaRegistry
    private let handler: Handler
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { captured } }
    init(clock: TVDirectoryQuotaClock = TVDirectoryQuotaClock(), _ handler: @escaping Handler) {
        self.handler = handler
        self.clock = clock
        registry = RequestQuotaRegistry(timing: clock.timing)
        TVDirectoryQuotaProtocol.register(self)
    }
    func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TVDirectoryQuotaProtocol.self]
        config.httpAdditionalHeaders = ["X-Directory-Fixture": id]
        return config
    }
    func close() { TVDirectoryQuotaProtocol.remove(id) }
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

private final class TVDirectoryQuotaProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: TVDirectoryQuotaFixture] = [:]
    static func register(_ fixture: TVDirectoryQuotaFixture) { lock.withLock { fixtures[fixture.id] = fixture } }
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

private final class TVDirectoryQuotaClock: @unchecked Sendable {
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

/// A loopback HTTP server exercises URLSession's real auth/redirect handling.
private final class TVWebDAVHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, [String: String], Data)
    private let handler: Handler
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TVWebDAVHTTPServer")
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private var connections: [NWConnection] = []
    private var started = false
    var requests: [URLRequest] { lock.withLock { captured } }

    init(handler: @escaping Handler) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                let result: Result<UInt16, Error>
                switch state {
                case .ready:
                    guard let port = self.listener.port else { return }
                    result = .success(port.rawValue)
                case .failed(let error): result = .failure(error)
                default: return
                }
                let resume = self.lock.withLock {
                    guard !self.started else { return false }
                    self.started = true
                    return true
                }
                if resume { continuation.resume(with: result) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.withLock { self.connections.append(connection) }
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var bytes = accumulated
            bytes.append(data ?? Data())
            if let end = bytes.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: bytes[..<end.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                let headers = Dictionary(lines.dropFirst().compactMap { line -> (String, String)? in
                    guard let separator = line.firstIndex(of: ":") else { return nil }
                    return (line[..<separator].lowercased(), line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
                }, uniquingKeysWith: { _, last in last })
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if first.count >= 2, bytes.count >= end.upperBound + length {
                    var request = URLRequest(url: URL(string: "http://127.0.0.1" + first[1])!)
                    request.httpMethod = String(first[0])
                    request.allHTTPHeaderFields = headers
                    request.httpBody = bytes.subdata(in: end.upperBound..<(end.upperBound + length))
                    self.lock.withLock { self.captured.append(request) }
                    let (status, responseHeaders, body) = self.handler(request)
                    var response = "HTTP/1.1 \(status) Fixture\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                    for (key, value) in responseHeaders { response += "\(key): \(value)\r\n" }
                    var payload = Data((response + "\r\n").utf8)
                    payload.append(body)
                    connection.send(content: payload, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            guard !complete, error == nil, bytes.count < 1_048_576 else { connection.cancel(); return }
            self.receive(connection, accumulated: bytes)
        }
    }
    static func listing() -> (Int, [String: String], Data) {
        TVDirectoryQuotaFixture.listing(URLRequest(url: URL(string: "http://127.0.0.1/Music/")!))
    }
    static func validDigest(_ request: URLRequest) -> Bool {
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Digest ") else { return false }
        let pattern = try! NSRegularExpression(pattern: #"(\w+)=(?:"([^"]*)"|([^,\s]+))"#)
        let text = header as NSString
        let fields = Dictionary(pattern.matches(in: header, range: NSRange(location: 0, length: text.length)).map { match in
            let value = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            return (text.substring(with: match.range(at: 1)), text.substring(with: value))
        }, uniquingKeysWith: { _, last in last })
        guard fields["username"] == "reader", fields["realm"] == "PrimuseFixture",
              fields["nonce"] == "quota-nonce", fields["qop"] == "auth",
              let uri = fields["uri"], let nonceCount = fields["nc"], let cnonce = fields["cnonce"] else { return false }
        let ha1 = md5("reader:PrimuseFixture:fixture")
        let ha2 = md5("PROPFIND:\(uri)")
        return fields["response"] == md5("\(ha1):quota-nonce:\(nonceCount):\(cnonce):auth:\(ha2)")
    }
    private static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
