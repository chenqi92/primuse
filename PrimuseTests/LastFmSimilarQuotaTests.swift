import Foundation
import XCTest
import PrimuseKit
@testable import Primuse

final class LastFmSimilarQuotaTests: XCTestCase {
    func testBusinessRateLimitIsNotCachedAsEmptyRecommendations() async throws {
        let fixture = SimilarFixture(status: 200, body: #"{"error":29,"message":"Rate limit exceeded"}"#)
        let service = fixture.service()
        for _ in 0..<2 {
            do { _ = try await service.fetchSimilar(to: seed, library: []); XCTFail("A business failure is not a successful empty list") }
            catch { }
        }
        XCTAssertEqual(fixture.requests.count, 1, "Track and artist lookups share a cooldown")
    }

    func testHTTPThrottleDoesNotFallBackToArtist() async throws {
        let fixture = SimilarFixture(status: 429, headers: ["Retry-After": "3600"])
        do { _ = try await fixture.service().fetchSimilar(to: seed, library: []); XCTFail("Expected throttling") }
        catch { }
        XCTAssertEqual(fixture.requests.count, 1, "Fallback must not spend a cooling quota")
    }

    func testHTTPStatusAndFullDateCooldownArePreservedAcrossServices() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        for status in [429, 503] {
            let fixture = SimilarFixture(status: status, headers: ["Retry-After": formatter.string(from: Date().addingTimeInterval(172800))])
            for _ in 0..<2 {
                do { _ = try await fixture.service().fetchSimilar(to: seed, library: []); XCTFail("Expected throttle") }
                catch let failure as HTTPResponseFailure {
                    XCTAssertEqual(failure.statusCode, status)
                    XCTAssertGreaterThan(failure.retryAfter ?? 0, 172790)
                }
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testTrackAndArtistClientsSpendTheSameAPIKeyQuota() async throws {
        let fixture = SimilarFixture(status: 429, headers: ["Retry-After": "3600"])
        _ = try? await fixture.api().similarTracks(artist: "Artist", track: "Seed")
        do { _ = try await fixture.api().similarArtistTracks(artist: "Artist"); XCTFail("Artist lookup must share the track cooldown") }
        catch let failure as HTTPResponseFailure { XCTAssertGreaterThan(failure.retryAfter ?? 0, 3590) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testBusinessErrorRetainsCodeMessageAndHTTPResponse() async throws {
        let fixture = SimilarFixture(status: 200, body: #"{"error":29,"message":"Rate limit exceeded"}"#)
        do { _ = try await fixture.service().fetchSimilar(to: seed, library: []); XCTFail("Expected business error") }
        catch LastFmSimilarAPI.SimilarError.api(let code, let message, let response) {
            XCTAssertEqual(code, 29); XCTAssertEqual(message, "Rate limit exceeded")
            XCTAssertEqual(response.statusCode, 200); XCTAssertTrue(response.isRateLimited)
            XCTAssertGreaterThan(response.retryAfter ?? 0, 0)
        }
    }

    func testSuccessfulEmptyResponsesAreCachedAfterArtistFallback() async throws {
        let fixture = SimilarFixture(status: 200, body: #"{"similartracks":{"track":[]},"similarartists":{"artist":[]}}"#)
        let service = fixture.service()
        for _ in 0..<2 {
            let result = try await service.fetchSimilar(to: seed, library: [])
            XCTAssertTrue(result.isEmpty)
        }
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertTrue(fixture.requests[1].url!.absoluteString.contains("artist.getSimilar"))
    }

    func testValidCandidatesAndMatchingArePreserved() async throws {
        let fixture = SimilarFixture(status: 200, body: #"{"similartracks":{"track":[{"name":"Result","artist":{"name":"Artist"},"match":"0.9","url":"https://www.last.fm/music/fixture"}]}}"#)
        var song = seed; song.id = "result"; song.title = "Result"
        let service = fixture.service()
        let result = try await service.fetchSimilar(to: seed, library: [song])
        XCTAssertEqual(result.first?.librarySong?.id, "result")
        XCTAssertEqual(result.first?.match, 0.9)
        _ = try await service.fetchSimilar(to: seed, library: [song])
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testMalformedAndPermanentBusinessFailuresAreNotCached() async throws {
        for body in ["{}", #"{"error":6,"message":"Invalid parameters"}"#] {
            let fixture = SimilarFixture(status: 200, body: body)
            let service = fixture.service()
            for _ in 0..<2 {
                do { _ = try await service.fetchSimilar(to: seed, library: []); XCTFail("Failure must not become empty content") }
                catch { }
            }
            XCTAssertEqual(fixture.requests.count, 4)
            XCTAssertEqual(fixture.requests.map { $0.url!.absoluteString.contains("track.getSimilar") }, [true, false, true, false])
        }
    }

    func testUnknownTrackStillFallsBackToSimilarArtists() async throws {
        let fixture = SimilarFixture(
            status: 200,
            body: #"{"error":6,"message":"Track not found"}"#,
            artistBody: #"{"similarartists":{"artist":[{"name":"Neighbour","match":"0.8"}]}}"#
        )
        let service = fixture.service()
        for _ in 0..<2 {
            let result = try await service.fetchSimilar(to: seed, library: [], includeUnmatched: true)
            XCTAssertEqual(result.map(\.artist), ["Neighbour"])
        }
        XCTAssertEqual(fixture.requests.count, 2, "The artist result is cached like any successful lookup")
        XCTAssertTrue(fixture.requests[1].url!.absoluteString.contains("artist.getSimilar"))
    }

    func testFailedArtistFallbackDoesNotCacheAnEmptyTrackResult() async throws {
        let fixture = SimilarFixture(status: 200, body: #"{"similartracks":{"track":[]}}"#)
        let service = fixture.service()
        for _ in 0..<2 {
            do { _ = try await service.fetchSimilar(to: seed, library: []); XCTFail("Malformed artist response must remain a failure") }
            catch { }
        }
        XCTAssertEqual(fixture.requests.count, 4)
    }

    func testDifferentAPIKeysKeepIndependentQuotas() async throws {
        let registry = RequestQuotaRegistry()
        let first = SimilarFixture(status: 429, headers: ["Retry-After": "3600"], registry: registry)
        let second = SimilarFixture(status: 200, body: #"{"similartracks":{"track":[]},"similarartists":{"artist":[]}}"#, registry: registry)
        _ = try? await first.service().fetchSimilar(to: seed, library: [])
        let result = try await second.service().fetchSimilar(to: seed, library: [])
        XCTAssertTrue(result.isEmpty); XCTAssertEqual(second.requests.count, 2)
    }

    func testCancelledRequestDoesNotStartFallback() async throws {
        let fixture = SimilarFixture(status: 0)
        let service = fixture.service()
        let seed = seed
        let done = expectation(description: "Cancelled promptly")
        let task = Task {
            defer { done.fulfill() }
            do { _ = try await service.fetchSimilar(to: seed, library: []); XCTFail("Expected cancellation") }
            catch is CancellationError { }
            catch { XCTFail("Cancellation lost: \(error)") }
        }
        for _ in 0..<200 {
            if !fixture.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(fixture.requests.count, 1)
        task.cancel()
        await fulfillment(of: [done], timeout: 3)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    private var seed: Song {
        Song(id: "seed", title: "Seed", artistName: "Artist", duration: 1,
             fileFormat: .mp3, filePath: "seed.mp3", sourceID: "fixture", fileSize: 1)
    }
}

private final class SimilarFixture: @unchecked Sendable {
    let key = UUID().uuidString
    let status: Int
    let headers: [String: String]
    let body: Data
    let artistBody: Data?
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    let registry: RequestQuotaRegistry
    lazy var session: URLSession = {
        SimilarProtocol.lock.withLock { SimilarProtocol.fixtures[key] = self }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SimilarProtocol.self]
        return URLSession(configuration: config)
    }()
    init(status: Int, headers: [String: String] = [:], body: String = "{}", artistBody: String? = nil,
         registry: RequestQuotaRegistry = RequestQuotaRegistry()) {
        self.registry = registry
        self.status = status; self.headers = headers; self.body = Data(body.utf8)
        self.artistBody = artistBody.map { Data($0.utf8) }
    }
    func body(for request: URLRequest) -> Data {
        guard let artistBody, request.url!.absoluteString.contains("artist.getSimilar") else { return body }
        return artistBody
    }
    func api() -> LastFmSimilarAPI {
        let key = key
        return LastFmSimilarAPI(apiKey: { key }, session: session, quotaRegistry: registry)
    }
    func service() -> SimilarTracksService { SimilarTracksService(api: api()) }
    func record(_ request: URLRequest) { lock.withLock { recorded.append(request) } }
}

private final class SimilarProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var fixtures: [String: SimilarFixture] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "api_key" }?.value ?? ""
        guard let fixture = Self.lock.withLock({ Self.fixtures[key] }) else { return }
        fixture.record(request)
        if fixture.status == 0 { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: nil, headerFields: fixture.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body(for: request))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
