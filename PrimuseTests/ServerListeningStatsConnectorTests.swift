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

    func testEmbyScanUsesDeclaredLibraryFoldersWithoutChangingPlaybackIdentity() async throws {
        let source = makeMediaSource(kind: .emby) { request in
            switch request.url?.path {
            case "/Users/Me":
                return try Self.response(request, json: #"{"Id":"user-1"}"#)
            case "/Users/user-1/Views":
                return try Self.response(
                    request,
                    json: #"{"Items":[{"Id":"library-1","Name":"Music","CollectionType":"music","ChildCount":1}]}"#
                )
            case "/Library/VirtualFolders/Query":
                return try Self.response(
                    request,
                    json: #"{"Items":[{"ItemId":"library-1","Name":"Music","Locations":["/srv/media/music"]}],"TotalRecordCount":1}"#
                )
            case "/Users/user-1/Items":
                return try Self.response(
                    request,
                    json: #"{"Items":[{"Id":"track-1","Name":"Track","Album":"Album","AlbumId":"album-1","AlbumArtist":"Artist","AlbumArtists":[{"Name":"Artist","Id":"artist-1"}],"Artists":["Artist"],"Path":"/srv/media/music/Artist/Album/Track.flac","MediaSources":[{"Size":123}],"MediaStreams":[{"Type":"Audio","Codec":"flac"}]}],"TotalRecordCount":1}"#
                )
            default:
                throw FixtureError.invalidRequest
            }
        }

        let stream = try await source.scanSongs(from: "/")
        var songs: [ConnectorScannedSong] = []
        for try await song in stream {
            songs.append(song)
        }

        let scanned = try XCTUnwrap(songs.first)
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(scanned.song.filePath, "/items/track-1.flac")
        XCTAssertEqual(
            scanned.providerHierarchyItems.filter(\.isDirectory).compactMap(\.displayName),
            ["Music", "Artist", "Album"]
        )
        XCTAssertFalse(scanned.providerHierarchyItems.contains {
            $0.path.contains("/srv/") || ($0.displayName?.contains("/srv/") == true)
        })
    }

    func testPlexScanUsesNativeSectionArtistAlbumTaxonomy() async throws {
        let source = makeMediaSource(kind: .plex) { request in
            switch request.url?.path {
            case "", "/":
                return try Self.response(
                    request,
                    json: #"{"MediaContainer":{"machineIdentifier":"machine-1","apiVersion":"1.0"}}"#
                )
            case "/library/sections":
                return try Self.response(
                    request,
                    json: #"{"MediaContainer":{"Directory":[{"key":"1","title":"Plex Music","type":"artist","Location":[{"id":1,"path":"/srv/plex/music"}]}]}}"#
                )
            case "/library/sections/1/all":
                return try Self.response(
                    request,
                    json: #"{"MediaContainer":{"totalSize":1,"Metadata":[{"ratingKey":"track-1","title":"Track","grandparentRatingKey":"artist-1","grandparentTitle":"Catalog Artist","parentRatingKey":"album-1","parentTitle":"Catalog Album","Media":[{"container":"flac","Part":[{"file":"/srv/plex/music/Physical Artist/Physical Album/Track.flac","size":456}]}]}]}}"#
                )
            default:
                throw FixtureError.invalidRequest
            }
        }

        let stream = try await source.scanSongs(from: "/")
        var songs: [ConnectorScannedSong] = []
        for try await song in stream {
            songs.append(song)
        }

        let scanned = try XCTUnwrap(songs.first)
        XCTAssertEqual(songs.count, 1)
        XCTAssertEqual(scanned.song.filePath, "/items/track-1.flac")
        XCTAssertEqual(
            scanned.providerHierarchyItems.filter(\.isDirectory).compactMap(\.displayName),
            ["Plex Music", "Catalog Artist", "Catalog Album"]
        )
        XCTAssertFalse(scanned.providerHierarchyItems.contains {
            $0.path.contains("/srv/") || ($0.displayName?.contains("Physical Artist") == true)
        })
    }

    func testEmbyCatalogAlbumArtistDoesNotInheritTrackArtistIdentity() async throws {
        let source = makeMediaSource(kind: .emby) { request in
            switch request.url?.path {
            case "/Users/Me":
                return try Self.response(request, json: #"{"Id":"user-1"}"#)
            case "/Users/user-1/Views":
                return try Self.response(
                    request,
                    json: #"{"Items":[{"Id":"library-1","Name":"Music","CollectionType":"music","ChildCount":2}]}"#
                )
            case "/Library/VirtualFolders/Query":
                return try Self.response(
                    request,
                    json: #"{"Items":[{"ItemId":"library-1","Locations":["/srv/media/music"]}],"TotalRecordCount":1}"#
                )
            case "/Users/user-1/Items":
                return try Self.response(
                    request,
                    json: #"{"Items":[{"Id":"track-1","Name":"First","Album":"Compilation","AlbumId":"album-1","AlbumArtist":"Various Artists","AlbumArtists":[{"Name":"Conflicting Catalog Artist"}],"ArtistItems":[{"Name":"Singer One","Id":"artist-1"}],"Artists":["Singer One"],"Path":"/outside/library/First.flac","MediaStreams":[{"Type":"Audio","Codec":"flac"}]},{"Id":"track-2","Name":"Second","Album":"Compilation","AlbumId":"album-1","AlbumArtist":"Various Artists","AlbumArtists":[{"Name":"Conflicting Catalog Artist"}],"ArtistItems":[{"Name":"Singer Two","Id":"artist-2"}],"Artists":["Singer Two"],"Path":"/outside/library/Second.flac","MediaStreams":[{"Type":"Audio","Codec":"flac"}]}],"TotalRecordCount":2}"#
                )
            default:
                throw FixtureError.invalidRequest
            }
        }

        let stream = try await source.scanSongs(from: "/")
        var songs: [ConnectorScannedSong] = []
        for try await song in stream {
            songs.append(song)
        }

        XCTAssertEqual(songs.count, 2)
        let firstDirectories = try XCTUnwrap(songs.first).providerHierarchyItems.filter(\.isDirectory)
        let secondDirectories = try XCTUnwrap(songs.last).providerHierarchyItems.filter(\.isDirectory)
        XCTAssertEqual(firstDirectories.compactMap(\.displayName), ["Music", "Various Artists", "Compilation"])
        XCTAssertEqual(secondDirectories.compactMap(\.displayName), ["Music", "Various Artists", "Compilation"])
        XCTAssertEqual(firstDirectories.map(\.path), secondDirectories.map(\.path))
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

final class ServerLibraryFolderHierarchyTests: XCTestCase {
    func testProviderHierarchySelectionPrefersDeepestPlacementDeterministically() {
        let shallow = providerHierarchyFixture(
            root: "root-b",
            folders: ["all"],
            songID: "song"
        )
        let deep = providerHierarchyFixture(
            root: "root-c",
            folders: ["artists", "album"],
            songID: "song"
        )
        let equallyDeepButCanonical = providerHierarchyFixture(
            root: "root-a",
            folders: ["artists", "album"],
            songID: "song"
        )

        XCTAssertTrue(ConnectorProviderHierarchySelectionPolicy.prefers(
            candidate: deep,
            over: shallow
        ))
        XCTAssertTrue(ConnectorProviderHierarchySelectionPolicy.prefers(
            candidate: equallyDeepButCanonical,
            over: deep
        ))
        XCTAssertFalse(ConnectorProviderHierarchySelectionPolicy.prefers(
            candidate: deep,
            over: equallyDeepButCanonical
        ))
    }

    func testDeclaredLibraryRootBuildsRelativeFoldersWithoutExposingServerPath() throws {
        let location = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "jellyfin:library:music",
            rootDisplayName: "Music",
            providerFilePath: "/srv/media/music/Artist/Album/track.flac",
            declaredLibraryRoots: ["/srv/media/music"],
            fallbackComponents: []
        )
        XCTAssertEqual(location.components.map(\.displayName), ["Artist", "Album"])

        let song = Song(
            id: "song-1",
            title: "Track",
            fileFormat: .flac,
            filePath: "/items/song-1.flac",
            sourceID: "server"
        )
        let scanned = ConnectorScannedSong(
            song: song,
            displayName: "Track.flac",
            titleMetadataInspected: true,
            folderLocation: location
        )
        let directories = scanned.providerHierarchyItems.filter(\.isDirectory)
        let songItem = try XCTUnwrap(scanned.providerHierarchyItems.last)

        XCTAssertEqual(directories.compactMap(\.displayName), ["Music", "Artist", "Album"])
        XCTAssertEqual(songItem.path, song.filePath)
        XCTAssertEqual(songItem.parentPath, directories.last?.path)
        XCTAssertFalse(scanned.providerHierarchyItems.contains {
            $0.path.contains("/srv/") || ($0.displayName?.contains("/srv/") == true)
        })
    }

    func testOpaqueServerPathUsesNativeCatalogHierarchy() {
        let location = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "plex:library:1",
            rootDisplayName: "Music",
            providerFilePath: "/private/mount/Artist/Album/track.flac",
            declaredLibraryRoots: ["/different/root"],
            fallbackComponents: [
                ConnectorLibraryFolderComponent(
                    stableID: "artist:42",
                    displayName: "Server Artist"
                ),
                ConnectorLibraryFolderComponent(
                    stableID: "album:84",
                    displayName: "Server Album"
                ),
            ]
        )

        XCTAssertEqual(location.components.map(\.stableID), ["artist:42", "album:84"])
        XCTAssertEqual(location.components.map(\.displayName), ["Server Artist", "Server Album"])
    }

    func testIdenticalRelativeFoldersFromDifferentDeclaredRootsRemainDistinct() throws {
        let first = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "jellyfin:library:music",
            rootDisplayName: "Music",
            providerFilePath: "/srv/primary/Artist/Album/first.flac",
            declaredLibraryRoots: ["/srv/primary", "/srv/archive"],
            fallbackComponents: []
        )
        let second = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "jellyfin:library:music",
            rootDisplayName: "Music",
            providerFilePath: "/srv/archive/Artist/Album/second.flac",
            declaredLibraryRoots: ["/srv/primary", "/srv/archive"],
            fallbackComponents: []
        )

        XCTAssertEqual(first.components.map(\.displayName), second.components.map(\.displayName))
        XCTAssertNotEqual(first.components.map(\.stableID), second.components.map(\.stableID))

        let firstSong = Song(
            id: "first",
            title: "First",
            fileFormat: .flac,
            filePath: "/items/first.flac",
            sourceID: "server"
        )
        let secondSong = Song(
            id: "second",
            title: "Second",
            fileFormat: .flac,
            filePath: "/items/second.flac",
            sourceID: "server"
        )
        let firstFolders = ConnectorLibraryFolderHierarchy.indexedItems(
            for: firstSong,
            displayName: "First.flac",
            location: first
        ).filter(\.isDirectory)
        let secondFolders = ConnectorLibraryFolderHierarchy.indexedItems(
            for: secondSong,
            displayName: "Second.flac",
            location: second
        ).filter(\.isDirectory)

        XCTAssertEqual(firstFolders.first?.path, secondFolders.first?.path)
        XCTAssertNotEqual(firstFolders.dropFirst().map(\.path), secondFolders.dropFirst().map(\.path))
    }

    func testUnsafeOrCaseMismatchedPOSIXPathsUseCatalogFallback() {
        let fallback = [
            ConnectorLibraryFolderComponent(
                stableID: "artist:catalog",
                displayName: "Catalog Artist"
            ),
        ]
        let caseMismatch = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "emby:library:music",
            rootDisplayName: "Music",
            providerFilePath: "/srv/Music/Artist/Album/track.flac",
            declaredLibraryRoots: ["/srv/music"],
            fallbackComponents: fallback
        )
        let traversal = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "emby:library:music",
            rootDisplayName: "Music",
            providerFilePath: "/srv/music/Artist/../private/track.flac",
            declaredLibraryRoots: ["/srv/music"],
            fallbackComponents: fallback
        )
        let encodedTraversal = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "emby:library:music",
            rootDisplayName: "Music",
            providerFilePath: "/srv/music/Artist/%2e%2e/private/track.flac",
            declaredLibraryRoots: ["/srv/music"],
            fallbackComponents: fallback
        )

        XCTAssertEqual(caseMismatch.components, fallback)
        XCTAssertEqual(traversal.components, fallback)
        XCTAssertEqual(encodedTraversal.components, fallback)
    }

    func testWindowsLibraryRootsMatchCaseInsensitively() {
        let location = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "emby:library:music",
            rootDisplayName: "Music",
            providerFilePath: #"C:\MUSIC\Artist\Album\track.flac"#,
            declaredLibraryRoots: ["c:/music"],
            fallbackComponents: []
        )

        XCTAssertEqual(location.components.map(\.displayName), ["Artist", "Album"])
    }

    func testUNCLibraryRootsMatchCaseInsensitivelyWithoutExposingShare() {
        let location = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "emby:library:music",
            rootDisplayName: "Music",
            providerFilePath: #"\\NAS\Music\Artist\Album\track.flac"#,
            declaredLibraryRoots: [#"\\nas\music"#],
            fallbackComponents: []
        )

        XCTAssertEqual(location.components.map(\.displayName), ["Artist", "Album"])
        XCTAssertFalse(location.components.contains { $0.displayName.contains("NAS") })
    }

    func testProviderDisplayNamesKeepNativePunctuationAndDistinctAccents() {
        let location = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "plex:library:1",
            rootDisplayName: "Music #1",
            providerFilePath: nil,
            fallbackComponents: [
                ConnectorLibraryFolderComponent(
                    stableID: "artist:c-sharp",
                    displayName: "C# / AC/DC"
                ),
                ConnectorLibraryFolderComponent(
                    stableID: "album:question",
                    displayName: "What? Hits"
                ),
            ]
        )

        XCTAssertEqual(location.rootDisplayName, "Music #1")
        XCTAssertEqual(location.components.map(\.displayName), ["C# / AC/DC", "What? Hits"])
        XCTAssertNotEqual(
            ConnectorLibraryFolderHierarchy.stableNameIdentity("Beyoncé"),
            ConnectorLibraryFolderHierarchy.stableNameIdentity("Beyonce")
        )
    }

    func testUPnPCanonicalPlacementPrefersDeepestThenStableIdentity() {
        let shallow = [
            ConnectorLibraryFolderComponent(stableID: "all", displayName: "All Music"),
        ]
        let deep = [
            ConnectorLibraryFolderComponent(stableID: "artists", displayName: "Artists"),
            ConnectorLibraryFolderComponent(stableID: "artist:1", displayName: "Artist"),
            ConnectorLibraryFolderComponent(stableID: "album:1", displayName: "Album"),
        ]
        let sameDepthEarlier = [
            ConnectorLibraryFolderComponent(stableID: "albums", displayName: "Albums"),
        ]

        XCTAssertTrue(UPnPCanonicalFolderPlacementPolicy.prefers(candidate: deep, over: shallow))
        XCTAssertFalse(UPnPCanonicalFolderPlacementPolicy.prefers(candidate: shallow, over: deep))
        XCTAssertTrue(
            UPnPCanonicalFolderPlacementPolicy.prefers(
                candidate: sameDepthEarlier,
                over: shallow
            )
        )
    }

    func testRelativeProviderPathRequiresConnectorOptIn() {
        let fallback = [
            ConnectorLibraryFolderComponent(
                stableID: "artist:server-id",
                displayName: "Catalog Artist"
            ),
        ]
        let rejected = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "subsonic:library",
            rootDisplayName: "Subsonic",
            providerFilePath: "Path Artist/Path Album/track.flac",
            acceptsProviderRelativePath: false,
            fallbackComponents: fallback
        )
        let accepted = ConnectorLibraryFolderHierarchy.location(
            rootStableID: "subsonic:library",
            rootDisplayName: "Subsonic",
            providerFilePath: "Path Artist/Path Album/track.flac",
            acceptsProviderRelativePath: true,
            fallbackComponents: fallback
        )

        XCTAssertEqual(rejected.components.map(\.displayName), ["Catalog Artist"])
        XCTAssertEqual(accepted.components.map(\.displayName), ["Path Artist", "Path Album"])
    }

    func testProviderHierarchyPlacesOpaqueSongInNativeAlbum() throws {
        let song = Song(
            id: "plex-song",
            title: "Track",
            fileFormat: .m4a,
            filePath: "/items/opaque-track-id.m4a",
            sourceID: "plex"
        )
        let scanned = ConnectorScannedSong(
            song: song,
            displayName: "Track.m4a",
            titleMetadataInspected: true,
            folderLocation: ConnectorLibraryFolderHierarchy.location(
                rootStableID: "plex:library:1",
                rootDisplayName: "Plex Music",
                providerFilePath: nil,
                fallbackComponents: [
                    ConnectorLibraryFolderComponent(
                        stableID: "artist:10",
                        displayName: "Artist"
                    ),
                    ConnectorLibraryFolderComponent(
                        stableID: "album:20",
                        displayName: "Album"
                    ),
                ]
            )
        )
        let indexedRoot = try XCTUnwrap(scanned.providerHierarchyItems.first)
        let hierarchy = LibraryFolderProviderHierarchy(
            roots: [
                LibraryFolderProviderRootDescriptor(
                    path: indexedRoot.path,
                    displayName: indexedRoot.displayName
                ),
            ],
            items: scanned.providerHierarchyItems.map {
                LibraryFolderProviderItemDescriptor(
                    path: $0.path,
                    displayName: $0.displayName,
                    parentPath: $0.parentPath,
                    isDirectory: $0.isDirectory
                )
            }
        )
        let source = LibraryFolderSourceDescriptor(
            sourceID: "plex",
            displayName: "Plex",
            scanRoots: [indexedRoot.path],
            pathSemantics: .opaque,
            providerHierarchy: hierarchy
        )
        let index = LibraryFolderIndexBuilder.build(sources: [source], songs: [song])
        let sourceNode = try XCTUnwrap(index.sourceNode(for: "plex"))
        let root = try XCTUnwrap(index.children(of: sourceNode.id).first { $0.kind == .scanRoot })
        let artist = try XCTUnwrap(index.children(of: root.id).first { $0.displayName == "Artist" })
        let album = try XCTUnwrap(index.children(of: artist.id).first { $0.displayName == "Album" })

        XCTAssertEqual(root.displayName, "Plex Music")
        XCTAssertEqual(index.directSongIDs(in: album.id), [song.id])
        XCTAssertFalse(index.children(of: sourceNode.id).contains { $0.kind == .uncategorized })
    }

    private func providerHierarchyFixture(
        root: String,
        folders: [String],
        songID: String
    ) -> [SourceSyncIndexedItem] {
        var items = [
            SourceSyncIndexedItem(
                stableKey: "hierarchy-root:\(root)",
                path: root,
                displayName: root,
                parentPath: nil,
                isDirectory: true,
                size: 0,
                modifiedDate: nil,
                revision: nil
            ),
        ]
        var parent = root
        for (offset, folder) in folders.enumerated() {
            let path = "\(root)/\(offset)-\(folder)"
            items.append(
                SourceSyncIndexedItem(
                    stableKey: "hierarchy-folder:\(path)",
                    path: path,
                    displayName: folder,
                    parentPath: parent,
                    isDirectory: true,
                    size: 0,
                    modifiedDate: nil,
                    revision: nil
                )
            )
            parent = path
        }
        items.append(
            SourceSyncIndexedItem(
                stableKey: "hierarchy-song:\(songID)",
                path: "/items/\(songID)",
                displayName: songID,
                parentPath: parent,
                isDirectory: false,
                songIDs: [songID],
                size: 0,
                modifiedDate: nil,
                revision: nil
            )
        )
        return items
    }
}
