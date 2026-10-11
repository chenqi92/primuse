import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class LRCLIBHTTPErrorTests: XCTestCase {
    func testSeparateInstancesShareLongCooldown() async {
        let fixture = HTTPFixture(status: 429, retryAfter: "3600")
        defer { fixture.close() }
        // Fresh service quota keeps this test independent of order and repeated runs.
        let quota = RequestExecutor(policy: .init(minimumInterval: 0.2, maximumConcurrentRequests: 1))
        let first = LRCLIBScraper(session: fixture.session, requestExecutor: quota)
        let other = LRCLIBScraper(session: fixture.session, requestExecutor: quota)
        for scraper in [first, other] {
            do {
                _ = try await scraper.fetchLyrics(title: "Fixture Song", artist: "Fixture Artist")
                XCTFail("Both callers must observe the server cooldown")
            } catch ScraperError.rateLimited(let delay) {
                XCTAssertGreaterThanOrEqual(delay ?? 0, 3599)
            } catch {
                XCTFail("Expected shared cooldown, got \(error)")
            }
        }
        XCTAssertEqual(fixture.requests.count, 1, "A new scraper must not request during another caller's cooldown")
    }

    func testSuccessfulLookupAndArtistlessSearchStillReturnLyrics() async throws {
        for artist in ["Fixture Artist", nil] {
            let object: [String: Any] = [
                "trackName": "Fixture Song",
                "syncedLyrics": "[00:01.00]Fixture lyrics",
                "plainLyrics": "Fixture lyrics"
            ]
            let body = try JSONSerialization.data(withJSONObject: artist == nil ? [object] : object)
            let fixture = HTTPFixture(status: 200, body: body)
            defer { fixture.close() }

            let result = try await fixture.scraper.fetchLyrics(title: "Fixture Song", artist: artist)

            XCTAssertEqual(result?.lrcContent, "[00:01.00]Fixture lyrics")
            XCTAssertEqual(result?.plainText, "Fixture lyrics")
            XCTAssertEqual(fixture.requests.map(\.url?.path), [artist == nil ? "/api/search" : "/api/get"])
        }
    }

    func testRateLimitedAndUnavailableResponsesPreserveRetryAfter() async {
        let cases: [(String?, Int?)] = [
            ("120", 120), (" 17 ", 17), ("0", 0),
            (nil, nil), ("later", nil), ("-1", nil), ("1.5", nil),
            ("99999999999999999999999999999999999999", Int.max)
        ]
        for status in [429, 503] {
            for (header, expected) in cases {
                let fixture = HTTPFixture(status: status, retryAfter: header)
                defer { fixture.close() }
                do {
                    _ = try await fixture.scraper.fetchLyrics(title: "Fixture Song", artist: "Fixture Artist")
                    XCTFail("HTTP \(status) must fail")
                } catch ScraperError.rateLimited(let retryAfter) {
                    XCTAssertEqual(retryAfter, expected, "HTTP \(status), Retry-After \(header ?? "absent")")
                } catch {
                    XCTFail("HTTP \(status) must trigger backoff, got \(error)")
                }
                XCTAssertEqual(fixture.requests.count, 1, "The scraper must not retry internally")
            }
        }
    }

    func testRetryAfterHTTPDateIsRoundedUp() async {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let header = formatter.string(from: Date().addingTimeInterval(120))
        let deadline = formatter.date(from: header)!
        let fixture = HTTPFixture(status: 429, retryAfter: header)
        defer { fixture.close() }
        let earliest = Date()
        do {
            _ = try await fixture.scraper.fetchLyrics(title: "Fixture Song", artist: "Fixture Artist")
            XCTFail("Expected backoff")
        } catch ScraperError.rateLimited(let retryAfter) {
            let latest = Date()
            guard let retryAfter else { return XCTFail("HTTP-date Retry-After was discarded") }
            XCTAssertGreaterThanOrEqual(retryAfter, Int(ceil(deadline.timeIntervalSince(latest))))
            XCTAssertLessThanOrEqual(retryAfter, Int(ceil(deadline.timeIntervalSince(earliest))))
        } catch {
            XCTFail("Expected rateLimited, got \(error)")
        }
    }

    func testOtherHTTPFailuresKeepTheirStatusInsteadOfBecomingMisses() async {
        for status in [400, 401, 403, 500, 502, 504] {
            let fixture = HTTPFixture(status: status)
            defer { fixture.close() }
            do {
                _ = try await fixture.scraper.fetchLyrics(title: "Fixture Song", artist: "Fixture Artist")
                XCTFail("HTTP \(status) must fail")
            } catch ScraperError.networkError(let message) {
                XCTAssertTrue(message.contains("LRCLIB"))
                XCTAssertTrue(message.contains(String(status)))
            } catch {
                XCTFail("HTTP \(status) must remain an HTTP failure, got \(error)")
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testNonHTTPResponseIsNotReportedAsMissingLyrics() async {
        let fixture = HTTPFixture(status: nil)
        defer { fixture.close() }
        do {
            _ = try await fixture.scraper.fetchLyrics(title: "Fixture Song", artist: "Fixture Artist")
            XCTFail("Expected an invalid response failure")
        } catch ScraperError.networkError {
        } catch {
            XCTFail("Non-HTTP response must not become notFound: \(error)")
        }
    }

    func test404RemainsAMissAndDoesNotDisableTheProvider() async {
        let fixture = HTTPFixture(status: 404)
        defer { fixture.close() }
        do {
            _ = try await fixture.scraper.fetchLyrics(title: "Fixture Song", artist: "Fixture Artist")
            XCTFail("Expected a lyric miss")
        } catch ScraperError.notFound {
        } catch {
            XCTFail("404 must remain notFound, got \(error)")
        }
        let manager = fixture.manager()
        for index in 0..<4 {
            let result = await scrape(manager, index: index)
            XCTAssertNil(result.lyrics)
            XCTAssertEqual(result.errors.count, 1)
        }
        XCTAssertEqual(fixture.requests.count, 5, "A genuine miss must not trip the provider circuit")
    }

    func testManagerSkipsFollowingSongsDuringLRCLIBBackoff() async {
        for status in [429, 503] {
            for retryAfter in ["120", nil, "invalid"] {
                let fixture = HTTPFixture(status: status, retryAfter: retryAfter)
                defer { fixture.close() }
                let manager = fixture.manager()
                let first = await scrape(manager, index: 0)
                XCTAssertEqual(first.errors.count, 1)
                for index in 1...3 {
                    let subsequent = await scrape(manager, index: index)
                    XCTAssertNil(subsequent.lyrics)
                    XCTAssertTrue(subsequent.errors.isEmpty, "A skipped provider must not make a failing request")
                }
                XCTAssertEqual(fixture.requests.count, 1, "HTTP \(status) must pause LRCLIB across songs")
            }
        }
    }

    func testRepeatedServerFailuresOpenTheExistingCircuit() async {
        let fixture = HTTPFixture(status: 500)
        defer { fixture.close() }
        let manager = fixture.manager()
        for index in 0..<3 {
            let result = await scrape(manager, index: index)
            XCTAssertEqual(result.errors.count, 1)
        }
        let next = await scrape(manager, index: 3)
        XCTAssertTrue(next.errors.isEmpty)
        XCTAssertEqual(fixture.requests.count, 3, "The fourth song must respect the failure circuit")
    }

    private func scrape(_ manager: ScraperManager, index: Int) async -> ScrapeResult {
        await manager.scrapeMetadata(
            title: "Fixture Song \(index)", artist: "Fixture Artist", album: nil, duration: nil,
            needs: .init(metadata: false, cover: false, lyrics: true),
            settings: .init(sources: [.init(id: "fixture-lrclib", type: .lrclib, isEnabled: true, priority: 0)])
        )
    }
}

private final class HTTPFixture: @unchecked Sendable {
    let session: URLSession
    let scraper: LRCLIBScraper
    private let id = UUID().uuidString
    private let reply: LRCLIBURLProtocol.Reply

    init(status: Int?, retryAfter: String? = nil, body: Data = Data("{}".utf8)) {
        reply = .init(status: status, retryAfter: retryAfter, body: body)
        LRCLIBURLProtocol.register(reply, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LRCLIBURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-LRCLIB-Test-ID": id]
        session = URLSession(configuration: configuration)
        scraper = LRCLIBScraper(session: session, requestExecutor: RequestExecutor())
    }

    var requests: [URLRequest] { reply.requests }
    func manager() -> ScraperManager { ScraperManager(scraperFactory: { [scraper] _ in scraper }) }
    func close() {
        session.invalidateAndCancel()
        LRCLIBURLProtocol.remove(id: id)
    }
}

private final class LRCLIBURLProtocol: URLProtocol, @unchecked Sendable {
    final class Reply: @unchecked Sendable {
        let status: Int?
        let retryAfter: String?
        let body: Data
        private let lock = NSLock()
        private var capturedRequests: [URLRequest] = []

        init(status: Int?, retryAfter: String?, body: Data) {
            self.status = status
            self.retryAfter = retryAfter
            self.body = body
        }

        var requests: [URLRequest] { lock.withLock { capturedRequests } }
        func record(_ request: URLRequest) { lock.withLock { capturedRequests.append(request) } }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]

    static func register(_ reply: Reply, id: String) { lock.withLock { replies[id] = reply } }
    static func remove(id: String) { _ = lock.withLock { replies.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let id = request.value(forHTTPHeaderField: "X-LRCLIB-Test-ID"),
              let reply = Self.lock.withLock({ Self.replies[id] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        reply.record(request)
        let response: URLResponse
        if let status = reply.status {
            response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: reply.retryAfter.map { ["Retry-After": $0] }
            )!
        } else {
            response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
