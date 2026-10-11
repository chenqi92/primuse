import Foundation
import XCTest
import PrimuseKit
#if os(tvOS)
@testable import PrimuseTV
#else
@testable import Primuse
#endif

final class PodcastRequestQuotaTests: XCTestCase {
    func testFeedsOnTheSameEndpointShareLongCooldown() async throws {
        for status in [429, 503] {
            let fixture = PodcastRequestFixture(status: status, headers: ["Retry-After": "3600"])
            for path in ["/first.xml", "/second.xml"] {
                do {
                    _ = try await PodcastNetwork.fetchFeed(fixture.url(path), session: fixture.session)
                    XCTFail("A throttled feed must not become successful content")
                } catch { }
            }
            XCTAssertEqual(fixture.requests.count, 1, "Other feeds must respect the endpoint's cooldown")
        }
    }

    func testEpisodeAssetsAndDirectoryShareDateCooldownWithFeeds() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        for entry in ["directory", "chapters", "transcript", "enclosure"] {
            let fixture = PodcastRequestFixture(status: 503, headers: ["Retry-After": formatter.string(from: Date().addingTimeInterval(3600))])
            switch entry {
            case "directory": _ = try? await PodcastNetwork.json(from: fixture.url(), session: fixture.session)
            case "chapters": let result = await PodcastNetwork.chapters(from: fixture.url(), session: fixture.session); XCTAssertTrue(result.isEmpty)
            case "transcript": let result = await PodcastNetwork.transcript(from: fixture.url(), session: fixture.session); XCTAssertNil(result)
            default: let result = await PodcastNetwork.probeEnclosure(fixture.url(), session: fixture.session); XCTAssertNil(result)
            }
            do {
                _ = try await PodcastNetwork.fetchFeed(fixture.url("/another.xml"), session: fixture.session)
                XCTFail("An asset's quota applies to feeds on the same endpoint")
            } catch PodcastNetwork.Failure.httpStatus(let status, let retryAfter) {
                XCTAssertEqual(status, 503)
                XCTAssertGreaterThan(retryAfter ?? 0, 3590)
            } catch { XCTFail("Lost server deadline: \(error)") }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testConditional304AndSuccessfulFeedMetadataArePreserved() async throws {
        let unchanged = PodcastRequestFixture(status: 304)
        let result = try await PodcastNetwork.fetchFeed(unchanged.url(), etag: "tag-v1", lastModified: "Wed, 01 Jul 2026 00:00:00 GMT", session: unchanged.session)
        guard case .notModified = result else { return XCTFail("304 must keep the cached feed") }
        XCTAssertEqual(unchanged.requests.first?.value(forHTTPHeaderField: "If-None-Match"), "tag-v1")
        XCTAssertEqual(unchanged.requests.first?.value(forHTTPHeaderField: "If-Modified-Since"), "Wed, 01 Jul 2026 00:00:00 GMT")
        let fresh = PodcastRequestFixture(status: 200, headers: ["ETag": "tag-v2", "Last-Modified": "Thu, 02 Jul 2026 00:00:00 GMT"], body: Data("<rss/>".utf8))
        guard case .fetched(let data, let url, let etag, let modified) = try await PodcastNetwork.fetchFeed(fresh.url(), session: fresh.session) else {
            return XCTFail("A successful feed returns its content and validators")
        }
        XCTAssertEqual(data, Data("<rss/>".utf8)); XCTAssertEqual(url, fresh.url())
        XCTAssertEqual(etag, "tag-v2"); XCTAssertEqual(modified, "Thu, 02 Jul 2026 00:00:00 GMT")
    }

    func testPermanentFailureDoesNotRetryOrCacheEmptyTranscript() async throws {
        let missing = PodcastRequestFixture(status: 404)
        let absent = await PodcastNetwork.transcript(from: missing.url(), session: missing.session)
        XCTAssertNil(absent); XCTAssertEqual(missing.requests.count, 1)
        let valid = PodcastRequestFixture(status: 200, body: Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhello\n".utf8), host: missing.host)
        let transcript = await PodcastNetwork.transcript(from: valid.url(), session: valid.session)
        XCTAssertTrue(transcript?.contains("hello") == true)
        XCTAssertEqual(valid.requests.count, 1)
    }

    func testHTTPSProbeQuotaDoesNotFallBackToInsecureHTTP() async throws {
        let fixture = PodcastRequestFixture(status: 429, headers: ["Retry-After": "3600"])
        let plain = URL(string: "http://\(fixture.host)/feed.xml")!
        for _ in 0..<2 {
            do { _ = try await PodcastNetwork.reachableURL(for: plain, session: fixture.session); XCTFail("Expected quota failure") }
            catch PodcastNetwork.Failure.httpStatus(let status, let delay) {
                XCTAssertEqual(status, 429); XCTAssertGreaterThan(delay ?? 0, 3590)
            } catch { XCTFail("Quota must not become a trust prompt: \(error)") }
        }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(fixture.requests.first?.httpMethod, "HEAD")
        XCTAssertEqual(fixture.requests.first?.url?.scheme, "https")
    }

    func testFailedTLSProbeStillRequiresExplicitHTTPTrust() async throws {
        let fixture = PodcastRequestFixture(status: 0, transportError: URLError(.secureConnectionFailed))
        do {
            _ = try await PodcastNetwork.reachableURL(for: URL(string: "http://\(fixture.host)/feed")!, session: fixture.session)
            XCTFail("Untrusted public HTTP must not be returned")
        } catch PodcastNetwork.Failure.insecureHTTP { }
        catch { XCTFail("Unexpected trust result: \(error)") }
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertTrue(fixture.requests.allSatisfy { $0.url?.scheme == "https" })
    }

    func testResponseLimitAndRangeProbeArePreserved() async throws {
        let oversized = PodcastRequestFixture(status: 200, headers: ["Content-Length": "9"], body: Data(repeating: 0, count: 9))
        do { _ = try await PodcastNetwork.json(from: oversized.url(), maxBytes: 8, session: oversized.session); XCTFail("Body limit must be enforced") }
        catch { XCTAssertEqual(oversized.requests.count, 1) }
        let audio = PodcastRequestFixture(status: 206, headers: ["Content-Range": "bytes 0-1/999", "Content-Length": "2"], body: Data([1, 2]))
        let probe = await PodcastNetwork.probeEnclosure(audio.url(), session: audio.session)
        XCTAssertEqual(probe?.totalLength, 999); XCTAssertEqual(probe?.supportsRange, true)
        XCTAssertEqual(audio.requests.first?.value(forHTTPHeaderField: "Range"), "bytes=0-1")
        XCTAssertEqual(audio.requests.first?.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
    }

    func testCancelledFeedStopsWithoutReplay() async throws {
        let fixture = PodcastRequestFixture(status: 0)
        let session = fixture.session
        let done = expectation(description: "Feed cancelled promptly")
        let task = Task {
            defer { done.fulfill() }
            do { _ = try await PodcastNetwork.fetchFeed(fixture.url(), session: session); XCTFail("Expected cancellation") }
            catch is CancellationError { }
            catch let error as URLError where error.code == .cancelled { }
            catch { XCTFail("Unexpected cancellation: \(error)") }
        }
        for _ in 0..<200 {
            if !fixture.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.requests.count, 1)
        task.cancel()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(fixture.requests.count, 1)
    }
}

private final class PodcastRequestFixture: @unchecked Sendable {
    let host: String
    let status: Int
    let headers: [String: String]
    let body: Data
    let transportError: URLError?
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    lazy var session: URLSession = {
        PodcastRequestProtocol.register(self)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PodcastRequestProtocol.self]
        return URLSession(configuration: config)
    }()
    init(status: Int, headers: [String: String] = [:], body: Data = Data(), host: String = UUID().uuidString.lowercased() + ".invalid", transportError: URLError? = nil) {
        self.status = status; self.headers = headers; self.body = body
        self.host = host; self.transportError = transportError
    }
    func url(_ path: String = "/feed.xml") -> URL { URL(string: "https://\(host)\(path)")! }
    func record(_ request: URLRequest) { lock.withLock { recorded.append(request) } }
}

private final class PodcastRequestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: PodcastRequestFixture] = [:]
    static func register(_ fixture: PodcastRequestFixture) { lock.withLock { fixtures[fixture.host] = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        fixture.record(request)
        if let error = fixture.transportError { client?.urlProtocol(self, didFailWithError: error); return }
        if fixture.status == 0 { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: nil, headerFields: fixture.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
