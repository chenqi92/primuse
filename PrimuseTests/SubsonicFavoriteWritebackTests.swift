import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class SubsonicFavoriteWritebackTests: XCTestCase {
    func testStarAndUnstarUseOnlyTheOpaqueSongIDAndAreIdempotent() async throws {
        let host = "favorite-success.invalid"
        SubsonicFavoriteURLProtocol.configure(host: host, mode: .success)
        let (source, session) = makeSource(host: host)
        defer { session.invalidateAndCancel() }

        _ = try await source.setServerFavorite(itemID: "song.a-42", isFavorite: true)
        _ = try await source.setServerFavorite(itemID: "song.a-42", isFavorite: true)
        _ = try await source.setServerFavorite(itemID: "song.a-42", isFavorite: false)
        let finalSnapshot = try await source.setServerFavorite(itemID: "song.a-42", isFavorite: false)

        XCTAssertFalse(finalSnapshot.itemIDs.contains("song.a-42"))
        let mutationRequests = SubsonicFavoriteURLProtocol.requests(host: host).filter {
            $0.url?.path == "/rest/star.view" || $0.url?.path == "/rest/unstar.view"
        }
        XCTAssertEqual(mutationRequests.map { $0.url?.path }, [
            "/rest/star.view",
            "/rest/star.view",
            "/rest/unstar.view",
            "/rest/unstar.view",
        ])
        for request in mutationRequests {
            XCTAssertEqual(request.httpMethod, "GET")
            let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems ?? []
            let objectItems = items.filter { ["id", "albumId", "artistId"].contains($0.name) }
            XCTAssertEqual(objectItems, [URLQueryItem(name: "id", value: "song.a-42")])
        }
    }

    func testHTTPApplicationTransportAndConfirmationErrorsRemainDistinct() async throws {
        try await assertAuthenticationFailure(mode: .httpUnauthorized, host: "favorite-401.invalid")
        try await assertAuthenticationFailure(mode: .applicationAuthenticationFailure, host: "favorite-40.invalid")
        try await assertConnectionFailure(mode: .httpServerFailure, host: "favorite-500.invalid")
        try await assertConnectionFailure(mode: .applicationDataFailure, host: "favorite-70.invalid")
        try await assertConnectionFailure(mode: .confirmationMismatch, host: "favorite-mismatch.invalid")
        try await assertURLError(.timedOut, mode: .timedOut, host: "favorite-timeout.invalid")
        try await assertURLError(
            .notConnectedToInternet,
            mode: .offline,
            host: "favorite-offline.invalid"
        )
    }

    func testInvalidItemIDNeverReachesAStarOrUnstarEndpoint() async throws {
        let host = "favorite-invalid-id.invalid"
        SubsonicFavoriteURLProtocol.configure(host: host, mode: .success)
        let (source, session) = makeSource(host: host)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await source.setServerFavorite(itemID: "nested/song", isFavorite: true)
            XCTFail("Expected invalid item ID to fail")
        } catch {
            guard let sourceError = error as? SourceError,
                  case .fileNotFound = sourceError else {
                return XCTFail("Unexpected error: \(type(of: error))")
            }
        }

        let mutationPaths = SubsonicFavoriteURLProtocol.requests(host: host).compactMap(\.url?.path)
            .filter { $0 == "/rest/star.view" || $0 == "/rest/unstar.view" }
        XCTAssertTrue(mutationPaths.isEmpty)
    }

    private func assertAuthenticationFailure(
        mode: SubsonicFavoriteURLProtocol.Mode,
        host: String
    ) async throws {
        SubsonicFavoriteURLProtocol.configure(host: host, mode: mode)
        let (source, session) = makeSource(host: host)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await source.setServerFavorite(itemID: "song-1", isFavorite: true)
            XCTFail("Expected authentication failure")
        } catch {
            guard let sourceError = error as? SourceError,
                  case .authenticationFailed = sourceError else {
                return XCTFail("Unexpected error: \(type(of: error))")
            }
        }
    }

    private func assertConnectionFailure(
        mode: SubsonicFavoriteURLProtocol.Mode,
        host: String
    ) async throws {
        SubsonicFavoriteURLProtocol.configure(host: host, mode: mode)
        let (source, session) = makeSource(host: host)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await source.setServerFavorite(itemID: "song-1", isFavorite: true)
            XCTFail("Expected connection failure")
        } catch {
            guard let sourceError = error as? SourceError,
                  case .connectionFailed = sourceError else {
                return XCTFail("Unexpected error: \(type(of: error))")
            }
        }
    }

    private func assertURLError(
        _ expectedCode: URLError.Code,
        mode: SubsonicFavoriteURLProtocol.Mode,
        host: String
    ) async throws {
        SubsonicFavoriteURLProtocol.configure(host: host, mode: mode)
        let (source, session) = makeSource(host: host)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await source.setServerFavorite(itemID: "song-1", isFavorite: true)
            XCTFail("Expected URL error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, expectedCode)
        } catch {
            XCTFail("Unexpected error: \(type(of: error))")
        }
    }

    private func makeSource(host: String) -> (SubsonicSource, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubsonicFavoriteURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (
            SubsonicSource(
                sourceID: host,
                sourceType: .navidrome,
                host: host,
                port: nil,
                useSsl: true,
                basePath: nil,
                username: "qa-user",
                password: "qa-password",
                session: session
            ),
            session
        )
    }
}

private final class SubsonicFavoriteURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Equatable {
        case success
        case httpUnauthorized
        case httpServerFailure
        case applicationAuthenticationFailure
        case applicationDataFailure
        case timedOut
        case offline
        case confirmationMismatch
    }

    private struct State {
        var mode: Mode
        var requests: [URLRequest] = []
        var starredItemIDs = Set<String>()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]

    static func configure(host: String, mode: Mode) {
        lock.lock()
        states[host] = State(mode: mode)
        lock.unlock()
    }

    static func requests(host: String) -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return states[host]?.requests ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            fail(.badURL)
            return
        }

        Self.lock.lock()
        guard var state = Self.states[host] else {
            Self.lock.unlock()
            fail(.cannotFindHost)
            return
        }
        state.requests.append(request)
        Self.states[host] = state
        Self.lock.unlock()

        switch url.path {
        case "/rest/ping.view":
            respond(json: #"{"subsonic-response":{"status":"ok","type":"navidrome","openSubsonic":true}}"#)
        case "/rest/star.view", "/rest/unstar.view":
            handleMutation(host: host, url: url, state: state)
        case "/rest/getStarred2.view":
            respondWithStarredSnapshot(host: host)
        default:
            fail(.unsupportedURL)
        }
    }

    override func stopLoading() {}

    private func handleMutation(host: String, url: URL, state: State) {
        switch state.mode {
        case .httpUnauthorized:
            respond(statusCode: 401, json: "{}")
        case .httpServerFailure:
            respond(statusCode: 500, json: "{}")
        case .applicationAuthenticationFailure:
            respond(json: failedResponse(code: 40, message: "Wrong credentials"))
        case .applicationDataFailure:
            respond(json: failedResponse(code: 70, message: "Song not found"))
        case .timedOut:
            fail(.timedOut)
        case .offline:
            fail(.notConnectedToInternet)
        case .success, .confirmationMismatch:
            if state.mode == .success,
               let itemID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value {
                Self.lock.lock()
                if var current = Self.states[host] {
                    if url.path == "/rest/star.view" {
                        current.starredItemIDs.insert(itemID)
                    } else {
                        current.starredItemIDs.remove(itemID)
                    }
                    Self.states[host] = current
                }
                Self.lock.unlock()
            }
            respond(json: #"{"subsonic-response":{"status":"ok"}}"#)
        }
    }

    private func respondWithStarredSnapshot(host: String) {
        Self.lock.lock()
        let ids = Self.states[host]?.starredItemIDs.sorted() ?? []
        Self.lock.unlock()
        let songs = ids.map { ["id": $0] }
        let root: [String: Any] = [
            "subsonic-response": [
                "status": "ok",
                "starred2": ["song": songs],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root),
              let json = String(data: data, encoding: .utf8) else {
            fail(.cannotDecodeContentData)
            return
        }
        respond(json: json)
    }

    private func failedResponse(code: Int, message: String) -> String {
        #"{"subsonic-response":{"status":"failed","error":{"code":\#(code),"message":"\#(message)"}}}"#
    }

    private func respond(statusCode: Int = 200, json: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            fail(.badServerResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ code: URLError.Code) {
        client?.urlProtocol(self, didFailWithError: URLError(code))
    }
}
