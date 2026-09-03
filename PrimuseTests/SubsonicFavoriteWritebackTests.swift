import CryptoKit
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

@MainActor
final class SubsonicServerScanTests: XCTestCase {
    func testAutomaticCatalogResourceGatePreservesExplicitUserRefresh() {
        XCTAssertFalse(ScanService.shouldDeferAutomaticServerCatalogWork(
            context: .userInitiatedForeground,
            resourcesAllowWork: false
        ))
        XCTAssertTrue(ScanService.shouldDeferAutomaticServerCatalogWork(
            context: .foregroundResume,
            resourcesAllowWork: false
        ))
        XCTAssertTrue(ScanService.shouldDeferAutomaticServerCatalogWork(
            context: .background,
            resourcesAllowWork: false
        ))
        XCTAssertFalse(ScanService.shouldDeferAutomaticServerCatalogWork(
            context: .foregroundResume,
            resourcesAllowWork: true
        ))
        XCTAssertTrue(ScanService.requiresAutomaticServerCatalogResourceGate(.navidrome))
        XCTAssertTrue(ScanService.requiresAutomaticServerCatalogResourceGate(.upnp))
        XCTAssertTrue(ScanService.requiresAutomaticServerCatalogResourceGate(.synology))
        XCTAssertFalse(ScanService.requiresAutomaticServerCatalogResourceGate(.baiduPan))
    }

    func testScanScopeChangesForCredentialOnlySourceRevision() {
        var source = MusicSource(
            id: "scope-revision",
            name: "Navidrome",
            type: .navidrome,
            host: "music.example.com",
            username: "user"
        )
        source.modifiedAt = Date(timeIntervalSinceReferenceDate: 100)
        let publicIdentity = MusicSourceScopeFingerprint.make(
            for: source,
            directories: ["/"]
        )
        let first = ScanService.scopeFingerprint(for: source, directories: ["/"])

        source.modifiedAt = Date(timeIntervalSinceReferenceDate: 101)

        XCTAssertEqual(
            publicIdentity,
            MusicSourceScopeFingerprint.make(for: source, directories: ["/"])
        )
        XCTAssertNotEqual(
            first,
            ScanService.scopeFingerprint(for: source, directories: ["/"])
        )
    }

    func testScanScopeSurvivesSourcesJSONDateRoundTrip() throws {
        var source = MusicSource(
            id: "scope-round-trip",
            name: "Navidrome",
            type: .navidrome,
            host: "music.example.com",
            username: "user"
        )
        source.modifiedAt = Date(timeIntervalSince1970: 1_788_200_000.875)
        let before = ScanService.scopeFingerprint(for: source, directories: ["/"])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MusicSource.self, from: encoder.encode(source))

        XCTAssertEqual(
            before,
            ScanService.scopeFingerprint(for: decoded, directories: ["/"])
        )
    }

    func testScanScopeKeepsLegacySecurityRevisionRepresentation() throws {
        var source = MusicSource(
            id: "scope-security-revision-\(UUID().uuidString)",
            name: "Navidrome",
            type: .navidrome,
            host: "music.example.com",
            username: "user"
        )
        source.modifiedAt = Date(timeIntervalSince1970: 1_788_200_000)
        let identity = MusicSourceScopeFingerprint.make(
            for: source,
            directories: ["/"]
        )
        let revision = try XCTUnwrap(
            MusicSourceSecurityRevision.revision(for: source.id)
        )
        let sourceRevision = Int64(source.modifiedAt.timeIntervalSince1970)
        let legacyValue = "\(identity)\u{1E}\(sourceRevision)\u{1E}Optional(\(revision))"
        let expected = SHA256.hash(data: Data(legacyValue.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertEqual(
            ScanService.scopeFingerprint(for: source, directories: ["/"]),
            expected
        )
    }

    func testSuccessfulRequestReturnsScanStatusAndUsesStartScanEndpoint() async throws {
        let host = "server-scan-success.invalid"
        SubsonicServerScanURLProtocol.configure(host: host, mode: .success)
        let (source, session) = makeSource(host: host)
        defer { session.invalidateAndCancel() }

        let result = try await source.requestServerCatalogScan()
        guard case .accepted(let status) = result else {
            return XCTFail("Expected accepted result, got \(result)")
        }
        XCTAssertTrue(status.isScanning)
        XCTAssertEqual(status.itemCount, 42)
        XCTAssertEqual(
            status.lastCompletedScanAt,
            ISO8601DateFormatter().date(from: "2026-08-31T04:00:00Z")
        )
        let requests = SubsonicServerScanURLProtocol.requests(host: host)
        XCTAssertEqual(requests.compactMap(\.url?.path), [
            "/rest/ping.view",
            "/rest/startScan.view",
        ])
        XCTAssertEqual(requests.last?.httpMethod, "GET")
        XCTAssertEqual(
            requests.last?.url.flatMap {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "fullScan" })?.value
            },
            "true"
        )
    }

    func testPermissionFailuresAreCapabilityResults() async throws {
        for (host, mode) in [
            ("server-scan-code50.invalid", SubsonicServerScanURLProtocol.Mode.applicationPermissionDenied),
            ("server-scan-403.invalid", .httpStatus(403)),
        ] {
            SubsonicServerScanURLProtocol.configure(host: host, mode: mode)
            let (source, session) = makeSource(host: host)
            defer { session.invalidateAndCancel() }
            let result = try await source.requestServerCatalogScan()
            XCTAssertEqual(result, .permissionDenied)
        }
    }

    func testUnsupportedEndpointsAreCapabilityResults() async throws {
        let cases: [(String, SubsonicServerScanURLProtocol.Mode)] = [
            ("server-scan-404.invalid", .httpStatus(404)),
            ("server-scan-405.invalid", .httpStatus(405)),
            ("server-scan-410.invalid", .httpStatus(410)),
            ("server-scan-501.invalid", .httpStatus(501)),
            ("server-scan-unknown.invalid", .applicationUnsupported),
        ]
        for (host, mode) in cases {
            SubsonicServerScanURLProtocol.configure(host: host, mode: mode)
            let (source, session) = makeSource(host: host)
            defer { session.invalidateAndCancel() }
            let result = try await source.requestServerCatalogScan()
            XCTAssertEqual(result, .unsupported)
        }
    }

    func testCredentialFailuresRemainAuthenticationFailures() async throws {
        for (host, mode) in [
            ("server-scan-401.invalid", SubsonicServerScanURLProtocol.Mode.httpStatus(401)),
            ("server-scan-code40.invalid", .applicationAuthenticationFailure),
        ] {
            SubsonicServerScanURLProtocol.configure(host: host, mode: mode)
            let (source, session) = makeSource(host: host)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await source.requestServerCatalogScan()
                XCTFail("Expected authentication failure")
            } catch let sourceError as SourceError {
                guard case .authenticationFailed = sourceError else {
                    return XCTFail("Unexpected source error: \(sourceError)")
                }
            }
        }
    }

    func testTransportFailuresRemainRetryableErrors() async throws {
        let cases: [(String, SubsonicServerScanURLProtocol.Mode)] = [
            ("server-scan-500.invalid", .httpStatus(500)),
            ("server-scan-timeout.invalid", .urlError(.timedOut)),
            ("server-scan-offline.invalid", .urlError(.notConnectedToInternet)),
        ]
        for (host, mode) in cases {
            SubsonicServerScanURLProtocol.configure(host: host, mode: mode)
            let (source, session) = makeSource(host: host)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await source.requestServerCatalogScan()
                XCTFail("Expected transport failure")
            } catch let sourceError as SourceError {
                if case .authenticationFailed = sourceError {
                    XCTFail("Transport failure was misclassified as authentication")
                }
            } catch {
                // Any non-authentication transport error preserves retry semantics.
            }
        }
    }

    func testPagedCatalogFetchesBoundedSearchWindows() async throws {
        let host = "server-paged-catalog.invalid"
        SubsonicServerScanURLProtocol.configure(host: host, mode: .pagedCatalog)
        let (source, session) = makeSource(host: host)
        defer { session.invalidateAndCancel() }

        let revision = try await source.stableSongCatalogRevision()
        XCTAssertEqual(revision, "2026-08-31T04:00:00Z|501")
        let first = try await source.songCatalogPage(from: "/", offset: 0)
        XCTAssertEqual(first.itemIDs.count, 500)
        XCTAssertEqual(first.songs.count, 500)
        XCTAssertEqual(first.itemIDs.first, "song-0")
        XCTAssertEqual(first.nextOffset, 500)

        let final = try await source.songCatalogPage(from: "/", offset: 500)
        XCTAssertEqual(final.itemIDs, ["song-500"])
        XCTAssertEqual(final.songs.map(\.song.filePath), ["/songs/song-500.mp3"])
        XCTAssertEqual(final.songs.map(\.song.serverPlayCount), [500])
        XCTAssertNil(final.nextOffset)

        let offsets: [String] = SubsonicServerScanURLProtocol.requests(host: host).compactMap { request -> String? in
            guard let url = request.url, url.path == "/rest/search3.view" else { return nil }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "songOffset" })?
                .value
        }
        XCTAssertEqual(offsets, ["0", "500"])
    }

    func testFailedServerScanCannotAuthorizeCatalogSnapshot() async throws {
        let host = "server-failed-scan.invalid"
        SubsonicServerScanURLProtocol.configure(host: host, mode: .failedScanStatus)
        let (source, session) = makeSource(host: host)
        defer { session.invalidateAndCancel() }

        do {
            _ = try await source.stableSongCatalogRevision()
            XCTFail("Expected failed server scan to reject the catalogue snapshot")
        } catch let sourceError as SourceError {
            guard case .connectionFailed(let detail) = sourceError else {
                return XCTFail("Unexpected source error: \(sourceError)")
            }
            XCTAssertTrue(detail.contains("scanner stopped"))
        }
    }

    private func makeSource(host: String) -> (SubsonicSource, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubsonicServerScanURLProtocol.self]
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

private final class SubsonicServerScanURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Equatable {
        case success
        case applicationPermissionDenied
        case applicationAuthenticationFailure
        case applicationUnsupported
        case pagedCatalog
        case failedScanStatus
        case httpStatus(Int)
        case urlError(URLError.Code)
    }

    private struct State {
        var mode: Mode
        var requests: [URLRequest] = []
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

        if url.path == "/rest/ping.view" {
            respond(json: #"{"subsonic-response":{"status":"ok","type":"navidrome","openSubsonic":true}}"#)
            return
        }
        if url.path == "/rest/getScanStatus.view" {
            switch state.mode {
            case .pagedCatalog:
                respond(json: #"{"subsonic-response":{"status":"ok","scanStatus":{"scanning":false,"count":501,"lastScan":"2026-08-31T04:00:00Z"}}}"#)
                return
            case .failedScanStatus:
                respond(json: #"{"subsonic-response":{"status":"ok","scanStatus":{"scanning":false,"count":500,"lastScan":"2026-08-31T04:00:00Z","error":"scanner stopped after an I/O failure"}}}"#)
                return
            default:
                break
            }
        }
        if url.path == "/rest/search3.view", state.mode == .pagedCatalog {
            let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "songOffset" })?
                .value
                .flatMap(Int.init) ?? 0
            let range = offset == 0 ? 0..<500 : 500..<501
            let songs = range.map { index in
                #"{"id":"song-\#(index)","title":"Song \#(index)","suffix":"mp3","path":"Artist/Album/Song \#(index).mp3","size":1024,"duration":180,"playCount":\#(index)}"#
            }.joined(separator: ",")
            respond(json: #"{"subsonic-response":{"status":"ok","searchResult3":{"song":[\#(songs)]}}}"#)
            return
        }
        guard url.path == "/rest/startScan.view" else {
            fail(.unsupportedURL)
            return
        }
        switch state.mode {
        case .success:
            respond(json: #"{"subsonic-response":{"status":"ok","scanStatus":{"scanning":true,"count":42,"lastScan":"2026-08-31T04:00:00Z"}}}"#)
        case .applicationPermissionDenied:
            respond(json: failedResponse(code: 50, message: "User is not authorized for the given operation"))
        case .applicationAuthenticationFailure:
            respond(json: failedResponse(code: 40, message: "Wrong credentials"))
        case .applicationUnsupported:
            respond(json: failedResponse(code: 0, message: "Unknown method startScan"))
        case .pagedCatalog, .failedScanStatus:
            fail(.unsupportedURL)
        case .httpStatus(let statusCode):
            respond(statusCode: statusCode, json: "{}")
        case .urlError(let code):
            fail(code)
        }
    }

    override func stopLoading() {}

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
            fail(.cannotParseResponse)
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
