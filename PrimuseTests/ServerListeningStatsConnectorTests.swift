import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class ServerListeningStatsConnectorTests: XCTestCase {
    func testCredentialFailureIsNotMisreportedAsUnsupportedCapability() async {
        let connector = CredentialUnavailableSourceConnector(
            sourceID: "stats-credential-failure",
            failure: .failed(-1)
        )

        do {
            _ = try await connector.fetchServerListeningStats()
            XCTFail("Expected credential failure")
        } catch SourceError.credentialUnavailable(_) {
            // Expected: a supported service remains supported while its credential is unavailable.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingRouteIsNotMisreportedAsUnsupportedCapability() async {
        let connector = NoAvailableConnectionSourceConnector(
            sourceID: "stats-missing-route"
        )

        do {
            _ = try await connector.fetchServerListeningStats()
            XCTFail("Expected route failure")
        } catch SourceError.connectionFailed(_) {
            // Expected: route selection remains a recoverable connection failure.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGenericSubsonicReadsAggregateStatisticsFromLegacyAlbumWalk() async throws {
        try await assertSubsonicStatistics(
            sourceType: .subsonic,
            host: "stats-subsonic.invalid",
            serverType: "subsonic",
            openSubsonic: false,
            expectedCatalogPath: "/rest/getAlbumList2.view"
        )
    }

    func testNavidromeReadsAggregateStatisticsFromSearch3() async throws {
        try await assertSubsonicStatistics(
            sourceType: .navidrome,
            host: "stats-navidrome.invalid",
            serverType: "navidrome",
            openSubsonic: false,
            expectedCatalogPath: "/rest/search3.view"
        )
    }

    func testAirsonicReadsAggregateStatisticsFromLegacyAlbumWalk() async throws {
        try await assertSubsonicStatistics(
            sourceType: .airsonic,
            host: "stats-airsonic.invalid",
            serverType: "airsonic",
            openSubsonic: false,
            expectedCatalogPath: "/rest/getAlbumList2.view"
        )
    }

    func testGonicReadsAggregateStatisticsFromOpenSubsonicSearch3() async throws {
        try await assertSubsonicStatistics(
            sourceType: .gonic,
            host: "stats-gonic.invalid",
            serverType: "gonic",
            openSubsonic: true,
            expectedCatalogPath: "/rest/search3.view"
        )
    }

    func testJellyfinReadsAccountScopedUserDataCounters() async throws {
        try await assertJellyfinFamilyStatistics(kind: .jellyfin)
    }

    func testEmbyReadsAccountScopedUserDataCounters() async throws {
        try await assertJellyfinFamilyStatistics(kind: .emby)
    }

    func testPlexUsesTimestampedHistoryWithoutInventingDuration() async throws {
        let source = makeMediaSource(kind: .plex) { request in
            switch request.url?.path {
            case "", "/":
                return try Self.response(request, json: #"{"MediaContainer":{"machineIdentifier":"machine-1","apiVersion":"1.0"}}"#)
            case "/library/sections":
                return try Self.response(request, json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Music","type":"artist"}]}}"#)
            case "/status/sessions/history/all":
                guard request.value(forHTTPHeaderField: "X-Plex-Container-Start") == "0",
                      request.value(forHTTPHeaderField: "X-Plex-Container-Size") == "200" else {
                    throw FixtureError.invalidRequest
                }
                return try Self.response(request, json: #"{"MediaContainer":{"size":2,"totalSize":2,"offset":0,"Metadata":[{"historyKey":"/status/sessions/history/11","ratingKey":"track-1","title":"One","parentTitle":"Album","grandparentTitle":"Artist","type":"track","viewedAt":1787688000,"accountID":42},{"historyKey":"/status/sessions/history/12","ratingKey":2,"title":"Two","parentTitle":"Album","grandparentTitle":"Artist","type":"track","viewedAt":"1787601600","accountID":"42"}]}}"#)
            default:
                throw FixtureError.invalidRequest
            }
        }

        let payload = try await source.fetchServerListeningStats()
        XCTAssertEqual(payload.temporalDetail, .events)
        XCTAssertEqual(payload.durationAvailability, .unavailable)
        XCTAssertEqual(payload.events.map(\.remoteTrackID), ["track-1", "2"])
        XCTAssertTrue(payload.events.allSatisfy { $0.listenedSeconds == nil })
        XCTAssertTrue(payload.tracks.isEmpty)
    }

    func testPlexFallsBackToAggregateOnlyWhenHistoryEndpointIsUnavailable() async throws {
        let paths = LockedValues<String>()
        let source = makeMediaSource(kind: .plex) { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "", "/":
                return try Self.response(request, json: #"{"MediaContainer":{"machineIdentifier":"machine-1"}}"#)
            case "/library/sections":
                return try Self.response(request, json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Music","type":"artist"}]}}"#)
            case "/status/sessions/history/all":
                return try Self.response(request, statusCode: 404, json: "{}")
            case "/library/sections/1/all":
                return try Self.response(request, json: #"{"MediaContainer":{"totalSize":1,"Metadata":[{"ratingKey":"track-1","title":"One","grandparentTitle":"Artist","parentTitle":"Album","viewCount":7,"lastViewedAt":1787688000}]}}"#)
            default:
                throw FixtureError.invalidRequest
            }
        }

        let payload = try await source.fetchServerListeningStats()
        XCTAssertEqual(payload.temporalDetail, .aggregate)
        XCTAssertEqual(payload.tracks.first?.playCount, 7)
        XCTAssertNotNil(payload.tracks.first?.lastPlayedAt)
        XCTAssertTrue(paths.values.contains("/library/sections/1/all"))
    }

    func testPlexDoesNotFallbackForServerFailure() async throws {
        let paths = LockedValues<String>()
        let source = makeMediaSource(kind: .plex) { request in
            let path = request.url?.path ?? ""
            paths.append(path)
            switch path {
            case "", "/":
                return try Self.response(request, json: #"{"MediaContainer":{"machineIdentifier":"machine-1"}}"#)
            case "/library/sections":
                return try Self.response(request, json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Music","type":"artist"}]}}"#)
            case "/status/sessions/history/all":
                return try Self.response(request, statusCode: 500, json: "{}")
            default:
                throw FixtureError.invalidRequest
            }
        }

        do {
            _ = try await source.fetchServerListeningStats()
            XCTFail("Expected server failure")
        } catch {
            // Expected: a server failure must not trigger aggregate fallback.
        }
        XCTAssertTrue(paths.values.contains("/status/sessions/history/all"))
        XCTAssertFalse(paths.values.contains("/library/sections/1/all"))
    }

    func testPlexRejectsHistoryThatMixesAccounts() async throws {
        let source = makeMediaSource(kind: .plex) { request in
            switch request.url?.path {
            case "", "/":
                return try Self.response(request, json: #"{"MediaContainer":{"machineIdentifier":"machine-1"}}"#)
            case "/library/sections":
                return try Self.response(request, json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Music","type":"artist"}]}}"#)
            case "/status/sessions/history/all":
                return try Self.response(request, json: #"{"MediaContainer":{"totalSize":2,"offset":0,"Metadata":[{"historyKey":"h1","ratingKey":"1","title":"One","type":"track","viewedAt":1787688000,"accountID":1},{"historyKey":"h2","ratingKey":"2","title":"Two","type":"track","viewedAt":1787601600,"accountID":2}]}}"#)
            default:
                throw FixtureError.invalidRequest
            }
        }

        do {
            _ = try await source.fetchServerListeningStats()
            XCTFail("Expected account ambiguity")
        } catch let error as ServerListeningStatsConnectorError {
            XCTAssertEqual(error, .accountAmbiguous)
        }
    }

    func testPlexRetriesMovingHistoryThenFailsWithoutPublishingPartialData() async throws {
        let historyRequests = LockedCounter()
        let source = makeMediaSource(kind: .plex) { request in
            switch request.url?.path {
            case "", "/":
                return try Self.response(request, json: #"{"MediaContainer":{"machineIdentifier":"machine-1"}}"#)
            case "/library/sections":
                return try Self.response(request, json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Music","type":"artist"}]}}"#)
            case "/status/sessions/history/all":
                historyRequests.increment()
                let start = request.value(forHTTPHeaderField: "X-Plex-Container-Start")
                if start == "0" {
                    return try Self.response(request, json: #"{"MediaContainer":{"totalSize":2,"offset":0,"Metadata":[{"historyKey":"h1","ratingKey":"1","title":"One","type":"track","viewedAt":1787688000,"accountID":1}]}}"#)
                }
                return try Self.response(request, json: #"{"MediaContainer":{"totalSize":3,"offset":1,"Metadata":[{"historyKey":"h2","ratingKey":"2","title":"Two","type":"track","viewedAt":1787601600,"accountID":1}]}}"#)
            default:
                throw FixtureError.invalidRequest
            }
        }

        do {
            _ = try await source.fetchServerListeningStats()
            XCTFail("Expected moving history to fail")
        } catch let error as ServerListeningStatsConnectorError {
            XCTAssertEqual(error, .historyChangedDuringPagination)
        }
        XCTAssertEqual(historyRequests.value, 4)
    }

    func testConnectorCancellationPropagatesWithoutFallback() async throws {
        let source = makeMediaSource(kind: .plex) { request in
            switch request.url?.path {
            case "", "/":
                return try Self.response(request, json: #"{"MediaContainer":{"machineIdentifier":"machine-1"}}"#)
            case "/library/sections":
                return try Self.response(request, json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Music","type":"artist"}]}}"#)
            case "/status/sessions/history/all":
                throw CancellationError()
            default:
                throw FixtureError.invalidRequest
            }
        }

        do {
            _ = try await source.fetchServerListeningStats()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation must not be translated into an empty snapshot.
        }
    }

    private func assertSubsonicStatistics(
        sourceType: MusicSourceType,
        host: String,
        serverType: String,
        openSubsonic: Bool,
        expectedCatalogPath: String
    ) async throws {
        SubsonicStatsURLProtocol.configure(
            host: host,
            serverType: serverType,
            openSubsonic: openSubsonic
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubsonicStatsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let source = SubsonicSource(
            sourceID: host,
            sourceType: sourceType,
            host: host,
            port: nil,
            useSsl: true,
            basePath: nil,
            username: "stats-user",
            password: "stats-password",
            session: session
        )

        let payload = try await source.fetchServerListeningStats()
        XCTAssertEqual(payload.temporalDetail, .aggregate)
        XCTAssertEqual(payload.tracks.count, 1)
        XCTAssertEqual(payload.tracks.first?.playCount, 5)
        XCTAssertEqual(payload.tracks.first?.title, "Server Song")
        XCTAssertNotNil(payload.tracks.first?.lastPlayedAt)
        XCTAssertTrue(SubsonicStatsURLProtocol.paths(host: host).contains(expectedCatalogPath))
    }

    private func assertJellyfinFamilyStatistics(kind: MediaServerSource.Kind) async throws {
        let source = makeMediaSource(kind: kind) { request in
            switch request.url?.path {
            case "/Users/Me":
                return try Self.response(request, json: #"{"Id":"user-1"}"#)
            case "/Users/user-1/Views":
                return try Self.response(request, json: #"{"Items":[{"Id":"library-1","Name":"Music","CollectionType":"music","ChildCount":1}]}"#)
            case "/Users/user-1/Items":
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                guard query?.first(where: { $0.name == "EnableUserData" })?.value == "true",
                      query?.first(where: { $0.name == "Fields" })?.value?.contains("UserData") == true else {
                    throw FixtureError.invalidRequest
                }
                return try Self.response(request, json: #"{"Items":[{"Id":"track-1","Name":"Server Song","Album":"Album","AlbumArtist":"Artist","Artists":["Artist"],"UserData":{"PlayCount":4,"LastPlayedDate":"2026-08-25T12:00:00.000Z"}}],"TotalRecordCount":1}"#)
            default:
                throw FixtureError.invalidRequest
            }
        }

        let payload = try await source.fetchServerListeningStats()
        XCTAssertEqual(payload.temporalDetail, .aggregate)
        XCTAssertEqual(payload.tracks.first?.playCount, 4)
        XCTAssertEqual(payload.tracks.first?.artist, "Artist")
        XCTAssertNotNil(payload.tracks.first?.lastPlayedAt)
        XCTAssertTrue(payload.events.isEmpty)
    }

    private func makeMediaSource(
        kind: MediaServerSource.Kind,
        loader: @escaping MediaServerSource.RequestDataLoader
    ) -> MediaServerSource {
        MediaServerSource(
            sourceID: "stats-\(kind)",
            kind: kind,
            host: "stats-media.invalid",
            port: nil,
            useSsl: true,
            basePath: nil,
            username: "stats-user",
            secret: "stats-token",
            authType: .apiKey,
            requestDataLoader: loader
        )
    }

    nonisolated private static func response(
        _ request: URLRequest,
        statusCode: Int = 200,
        json: String
    ) throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (Data(json.utf8), response)
    }
}

private enum FixtureError: Error {
    case invalidRequest
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class LockedValues<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []

    var values: [Element] {
        lock.withLock { storage }
    }

    func append(_ value: Element) {
        lock.withLock { storage.append(value) }
    }
}

private final class SubsonicStatsURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Configuration {
        let serverType: String
        let openSubsonic: Bool
        var paths: [String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var configurations: [String: Configuration] = [:]

    static func configure(host: String, serverType: String, openSubsonic: Bool) {
        lock.withLock {
            configurations[host] = Configuration(
                serverType: serverType,
                openSubsonic: openSubsonic,
                paths: []
            )
        }
    }

    static func paths(host: String) -> [String] {
        lock.withLock { configurations[host]?.paths ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            fail(.badURL)
            return
        }
        guard let configuration = Self.lock.withLock({ () -> Configuration? in
            guard var configuration = Self.configurations[host] else { return nil }
            configuration.paths.append(url.path)
            Self.configurations[host] = configuration
            return configuration
        }) else {
            fail(.cannotFindHost)
            return
        }

        switch url.path {
        case "/rest/ping.view":
            respond(json: #"{"subsonic-response":{"status":"ok","type":"\#(configuration.serverType)","openSubsonic":\#(configuration.openSubsonic)}}"#)
        case "/rest/search3.view":
            respond(json: #"{"subsonic-response":{"status":"ok","searchResult3":{"song":[\#(songJSON)]}}}"#)
        case "/rest/getAlbumList2.view":
            respond(json: #"{"subsonic-response":{"status":"ok","albumList2":{"album":[{"id":"album-1","name":"Album"}]}}}"#)
        case "/rest/getAlbum.view":
            respond(json: #"{"subsonic-response":{"status":"ok","album":{"song":[\#(songJSON)]}}}"#)
        default:
            fail(.unsupportedURL)
        }
    }

    override func stopLoading() {}

    private var songJSON: String {
        #"{"id":"song-1","title":"Server Song","artist":"Artist","album":"Album","playCount":5,"played":"2026-08-25T12:00:00.000Z","suffix":"flac","duration":180}"#
    }

    private func respond(json: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
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
