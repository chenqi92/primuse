import Foundation
import XCTest
import PrimuseKit
@testable import Primuse

final class NativeScraperHTTPTests: XCTestCase {
    func testNativeInstancesShareCooldownAndPreserveSchedulerSignal() async throws {
        for type in [MusicScraperType.musicBrainz, .itunes] {
            let id = UUID().uuidString
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RateLimitedNativeProtocol.self]
            configuration.httpAdditionalHeaders = ["X-Fixture-ID": id]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel(); RateLimitedNativeProtocol.counts.remove(id) }
            let executor = RequestExecutor()
            let scrapers: [any MusicScraper] = type == .musicBrainz
                ? [MusicBrainzScraper(session: session, requestExecutor: executor),
                   MusicBrainzScraper(session: session, requestExecutor: executor)]
                : [ITunesScraper(session: session, requestExecutor: executor),
                   ITunesScraper(session: session, requestExecutor: executor)]
            for scraper in scrapers {
                do {
                    _ = try await scraper.search(query: "cooldown", artist: nil, album: nil, limit: 1)
                    XCTFail("Expected rate limiting")
                } catch ScraperError.rateLimited(let delay) {
                    XCTAssertGreaterThanOrEqual(try XCTUnwrap(delay), 3599)
                }
            }
            XCTAssertEqual(RateLimitedNativeProtocol.counts.count(id), 1)
        }
    }

    func testITunesServerFailureIsNotAnEmptySearchResult() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailedMusicBrainzProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await ITunesScraper(session: session).search(
                query: "HTTP failure fixture", artist: nil, album: nil, limit: 1
            )
            XCTFail("HTTP 500 must remain a failure so callers can back off")
        } catch let failure as HTTPResponseFailure {
            XCTAssertEqual(failure.statusCode, 500)
            XCTAssertEqual(failure.body, FailedMusicBrainzProtocol.body)
        }
    }

    func testMusicBrainzServerFailureIsNotAnEmptySearchResult() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailedMusicBrainzProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await MusicBrainzScraper(session: session).search(
                query: "HTTP failure fixture", artist: nil, album: nil, limit: 1
            )
            XCTFail("HTTP 500 must remain a failure so callers can back off")
        } catch let failure as HTTPResponseFailure {
            XCTAssertEqual(failure.statusCode, 500)
            XCTAssertEqual(failure.body, FailedMusicBrainzProtocol.body)
        }
    }
}

private final class FailedMusicBrainzProtocol: URLProtocol, @unchecked Sendable {
    static let body = Data(#"{"error":"Temporary server error","resultCount":0,"results":[]}"#.utf8)

    override class func canInit(with request: URLRequest) -> Bool {
        ["musicbrainz.org", "itunes.apple.com"].contains(request.url?.host ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 500, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class NativeRequestCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Int] = [:]
    func increment(_ id: String) { lock.withLock { values[id, default: 0] += 1 } }
    func count(_ id: String) -> Int { lock.withLock { values[id, default: 0] } }
    func remove(_ id: String) { _ = lock.withLock { values.removeValue(forKey: id) } }
}

private final class RateLimitedNativeProtocol: URLProtocol, @unchecked Sendable {
    static let counts = NativeRequestCounts()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Fixture-ID") else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        Self.counts.increment(id)
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                                       headerFields: ["Retry-After": "3600"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
