import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class SubsonicRatingTests: XCTestCase {
    func testSetAndClearUseOpaqueIDAndReadBackCurrentUserRating() async throws {
        let fixture = RatingHTTPFixture()
        let (source, session) = makeSource(fixture)
        defer { session.invalidateAndCancel() }
        let rated = try await source.setServerRating(itemID: "song.a-42", rating: 4)
        let cleared = try await source.setServerRating(itemID: "song.a-42", rating: nil)
        XCTAssertEqual(rated, 4)
        XCTAssertNil(cleared)
        let requests = fixture.requests
        XCTAssertEqual(requests.compactMap(\.url?.lastPathComponent), [
            "ping.view", "setRating.view", "getSong.view", "setRating.view", "getSong.view"
        ])
        let writes = requests.filter { $0.url?.lastPathComponent == "setRating.view" }
        XCTAssertEqual(writes.map { query($0)["rating"] }, ["4", "0"])
        for request in writes {
            XCTAssertEqual(query(request)["id"], "song.a-42")
            XCTAssertEqual(query(request)["c"], "Primuse")
            XCTAssertNotNil(query(request)["t"])
            XCTAssertNil(query(request)["albumId"])
            XCTAssertNil(query(request)["artistId"])
        }
    }

    func testInvalidRatingAndIDsNeverReachNetwork() async {
        let fixture = RatingHTTPFixture()
        let (source, session) = makeSource(fixture)
        defer { session.invalidateAndCancel() }
        for (id, rating) in [("song", 6), ("song", -1), ("song", 0), ("", 3), ("nested/song", 3), ("..", 3)] {
            do {
                _ = try await source.setServerRating(itemID: id, rating: rating)
                XCTFail("Expected invalid input to fail")
            } catch {}
        }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testHTTP200AuthenticationFailureIsNotSuccess() async {
        let fixture = RatingHTTPFixture(mode: .authenticationFailure)
        let (source, session) = makeSource(fixture)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await source.setServerRating(itemID: "song", rating: 4)
            XCTFail("Expected authentication failure")
        } catch SourceError.authenticationFailed {} catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMismatchedMissingAndInvalidReadbackNeverConfirm() async {
        for mode in [RatingHTTPFixture.Mode.mismatchedRating, .missingSong, .wrongSong, .invalidRating] {
            let fixture = RatingHTTPFixture(mode: mode)
            let (source, session) = makeSource(fixture)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await source.setServerRating(itemID: "song", rating: 4)
                XCTFail("Expected readback failure for \(mode)")
            } catch {}
        }
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { _, rhs in rhs })
    }

    private func makeSource(_ fixture: RatingHTTPFixture) -> (SubsonicSource, URLSession) {
        let host = "rating-\(UUID().uuidString.lowercased()).invalid"
        RatingHTTPProtocol.register(fixture, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RatingHTTPProtocol.self]
        let session = URLSession(configuration: configuration)
        let source = SubsonicSource(sourceID: host, sourceType: .navidrome, host: host, port: nil,
                                    useSsl: true, basePath: nil, username: "qa", password: "qa", session: session)
        return (source, session)
    }
}

private final class RatingHTTPFixture: @unchecked Sendable {
    enum Mode { case success, authenticationFailure, mismatchedRating, missingSong, wrongSong, invalidRating }
    let mode: Mode
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var rating = 0
    var requests: [URLRequest] { lock.withLock { recorded } }
    init(mode: Mode = .success) { self.mode = mode }

    func response(_ request: URLRequest) -> Data {
        lock.withLock {
            recorded.append(request)
            let items = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
            func param(_ name: String) -> String? { items.first { $0.name == name }?.value }
            var body: [String: Any] = ["status": "ok"]
            switch request.url?.lastPathComponent {
            case "ping.view":
                body["type"] = "navidrome"
                body["openSubsonic"] = true
            case "setRating.view":
                if mode == .authenticationFailure {
                    body = ["status": "failed", "error": ["code": 40, "message": "Wrong credentials"]]
                } else { rating = Int(param("rating") ?? "") ?? 0 }
            case "getSong.view":
                if mode != .missingSong {
                    var song: [String: Any] = ["id": mode == .wrongSong ? "wrong" : (param("id") ?? "")]
                    if rating != 0 {
                        song["userRating"] = mode == .invalidRating ? 9 : (mode == .mismatchedRating ? 2 : rating)
                    }
                    // averageRating is not the authenticated user's personal score.
                    song["averageRating"] = 3.5
                    body["song"] = song
                }
            default:
                body = ["status": "failed", "error": ["code": 70, "message": "Unknown method"]]
            }
            return try! JSONSerialization.data(withJSONObject: ["subsonic-response": body])
        }
    }
}

private final class RatingHTTPProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: RatingHTTPFixture] = [:]
    static func register(_ fixture: RatingHTTPFixture, host: String) { lock.withLock { fixtures[host] = fixture } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[url.host ?? ""] }),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.response(request))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
