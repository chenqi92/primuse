import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// Emby / Jellyfin servers whose reported `TotalRecordCount` is not the whole
/// story: capped below the real count, exactly a page multiple, or answered
/// past the end by clamping the offset back.
final class MediaServerCatalogTotalTests: XCTestCase {
    func testCompleteWalkReadsPastAnUnderstatedTotal() async throws {
        let server = FakeCatalogServer(libraries: [.init(id: "music", type: "music", count: 1_200)])
        server.reportedTotalCap = 1_000
        let source = server.makeSource()

        let ids = try await scanAll(source)

        XCTAssertEqual(ids.count, 1_200)
        XCTAssertEqual(Set(ids).count, 1_200)
        let drift = await source.takeCatalogDriftObservation()
        XCTAssertFalse(drift, "walking to the server's own end is a complete walk")
    }

    func testCompleteWalkEndingOnAFullPageConfirmsTheEndOnce() async throws {
        let server = FakeCatalogServer(libraries: [.init(id: "music", type: "music", count: 1_000)])
        let source = server.makeSource()

        let ids = try await scanAll(source)

        XCTAssertEqual(ids.count, 1_000)
        XCTAssertEqual(server.pageRequests(startIndex: 1_000), 1)
        let drift = await source.takeCatalogDriftObservation()
        XCTAssertFalse(drift)
    }

    func testServerThatClampsTheOffsetIsNotReadAsMoreRows() async throws {
        let server = FakeCatalogServer(libraries: [.init(id: "music", type: "music", count: 1_000)])
        server.clampsOutOfRangeOffsets = true
        let source = server.makeSource()

        let ids = try await scanAll(source)
        XCTAssertEqual(ids.count, 1_000)
        let drift = await source.takeCatalogDriftObservation()
        XCTAssertFalse(drift)

        // The paged catalogue's end check has to see through the clamp too.
        let end = try await source.songCatalogPage(from: "/", offset: 1_000)
        XCTAssertTrue(end.itemIDs.isEmpty)
        XCTAssertNil(end.nextOffset)
    }

    func testPagedCatalogueHandsAnUnderstatedTotalToTheCompleteWalk() async throws {
        let server = FakeCatalogServer(libraries: [.init(id: "music", type: "music", count: 1_200)])
        server.reportedTotalCap = 1_000
        let source = server.makeSource()

        let first = try await source.songCatalogPage(from: "/", offset: 0)
        XCTAssertEqual(first.itemIDs.count, 500)
        let second = try await source.songCatalogPage(from: "/", offset: 500)
        XCTAssertEqual(second.nextOffset, 1_000)
        await assertThrows(.unavailable) {
            _ = try await source.songCatalogPage(from: "/", offset: 1_000)
        }
        // This connector no longer pages by that total at all.
        await assertThrows(.unavailable) {
            _ = try await source.songCatalogPage(from: "/", offset: 0)
        }
    }

    func testPagedCatalogueWithAnAccurateTotalEndsOnAnEmptyPage() async throws {
        let server = FakeCatalogServer(libraries: [.init(id: "music", type: "music", count: 1_000)])
        let source = server.makeSource()

        _ = try await source.songCatalogPage(from: "/", offset: 0)
        let end = try await source.songCatalogPage(from: "/", offset: 1_000)

        XCTAssertTrue(end.itemIDs.isEmpty)
        XCTAssertNil(end.nextOffset)
    }

    func testRowAddedAtTheEndDuringTheWalkIsDriftNotAnUnreliableTotal() async throws {
        let server = FakeCatalogServer(libraries: [.init(id: "music", type: "music", count: 1_000)])
        let source = server.makeSource()

        _ = try await source.songCatalogPage(from: "/", offset: 0)
        _ = try await source.songCatalogPage(from: "/", offset: 500)
        server.append(1, to: "music")
        await assertThrows(.snapshotChangedDuringPagination) {
            _ = try await source.songCatalogPage(from: "/", offset: 1_000)
        }

        // Re-measured, the paged catalogue carries on with the new count.
        _ = try await source.stableSongCatalogRevision()
        let reread = try await source.songCatalogPage(from: "/", offset: 1_000)
        XCTAssertEqual(reread.itemIDs, ["music-1000"])
    }

    func testIdListingCutAtAnUnderstatedTotalNeverReadsTheRestAsDeleted() async throws {
        let server = FakeCatalogServer(libraries: [.init(id: "music", type: "music", count: 1_200)])
        server.reportedTotalCap = 1_000
        var known: [Song] = []
        for try await scanned in try await server.makeSource().scanSongs(from: "/") {
            known.append(scanned.song)
        }
        XCTAssertEqual(known.count, 1_200)

        let source = server.makeSource()
        let marker = ServerCatalogSyncMarker(
            catalogRevision: "an older revision",
            modifiedSince: Date(timeIntervalSince1970: 1_700_000_000),
            itemCount: 1_000
        )
        await assertThrows(.unavailable) {
            _ = try await source.songCatalogChanges(since: marker, knownSongs: known, progress: nil)
        }
    }

    func testMixedLibraryWithItsOwnFoldersIsScanned() async throws {
        let server = FakeCatalogServer(libraries: [
            .init(id: "music", type: "music", count: 3, locations: ["/volume1/Music"]),
            .init(id: "mixed", type: nil, count: 2, locations: ["/volume1/Downloads"]),
            .init(id: "shows", type: "tvshows", count: 4, locations: ["/volume1/TV"]),
        ])
        let ids = try await scanAll(server.makeSource())
        XCTAssertEqual(Set(ids.map { $0.components(separatedBy: "-")[0] }), ["music", "mixed"])
        XCTAssertEqual(ids.count, 5)
    }

    func testMixedLibraryInsideTheMusicFolderIsSkipped() async throws {
        let server = FakeCatalogServer(libraries: [
            .init(id: "music", type: "music", count: 3, locations: ["/volume1/Music"]),
            .init(id: "mixed", type: nil, count: 2, locations: ["/volume1/Music/Live"]),
        ])
        let ids = try await scanAll(server.makeSource())
        XCTAssertEqual(ids.count, 3)
    }

    // MARK: - Helpers

    private func scanAll(_ source: MediaServerSource) async throws -> [String] {
        var ids: [String] = []
        for try await scanned in try await source.scanSongs(from: "/") {
            ids.append((scanned.song.filePath as NSString).lastPathComponent
                .components(separatedBy: ".")[0])
        }
        return ids
    }

    private func assertThrows(
        _ expected: PagedSongCatalogError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as PagedSongCatalogError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}

private final class FakeCatalogServer: @unchecked Sendable {
    struct Library {
        let id: String
        let type: String?
        var count: Int
        var locations: [String] = []

        init(id: String, type: String?, count: Int, locations: [String] = []) {
            self.id = id
            self.type = type
            self.count = count
            self.locations = locations
        }
    }

    private let lock = NSLock()
    private var libraries: [Library]
    private var pageStartIndices: [Int] = []
    private var _reportedTotalCap: Int?
    private var _clampsOutOfRangeOffsets = false
    private let host = "catalog-\(UUID().uuidString.lowercased()).invalid"

    init(libraries: [Library]) {
        self.libraries = libraries
    }

    var reportedTotalCap: Int? {
        get { lock.withLock { _reportedTotalCap } }
        set { lock.withLock { _reportedTotalCap = newValue } }
    }

    var clampsOutOfRangeOffsets: Bool {
        get { lock.withLock { _clampsOutOfRangeOffsets } }
        set { lock.withLock { _clampsOutOfRangeOffsets = newValue } }
    }

    func append(_ rows: Int, to libraryID: String) {
        lock.withLock {
            guard let index = libraries.firstIndex(where: { $0.id == libraryID }) else { return }
            libraries[index].count += rows
        }
    }

    /// Catalogue pages (not the one-row probes) asked for at `startIndex`.
    func pageRequests(startIndex: Int) -> Int {
        lock.withLock { pageStartIndices.filter { $0 == startIndex }.count }
    }

    func makeSource(kind: MediaServerSource.Kind = .emby) -> MediaServerSource {
        MediaServerSource(
            sourceID: host,
            kind: kind,
            host: host,
            port: nil,
            useSsl: true,
            basePath: nil,
            username: "user",
            secret: "token",
            authType: .apiKey,
            requestDataLoader: { [self] request in try self.respond(to: request) }
        )
    }

    private func respond(to request: URLRequest) throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )
        let body: Any
        switch url.path {
        case "/Users/Me":
            body = ["Id": "user-1"]
        case "/Users/user-1/Views":
            body = ["Items": lock.withLock { libraries }.map { library -> [String: Any] in
                var row: [String: Any] = ["Id": library.id, "Name": library.id]
                if let type = library.type { row["CollectionType"] = type }
                return row
            }]
        case "/Library/VirtualFolders", "/Library/VirtualFolders/Query":
            body = lock.withLock { libraries }.map { ["ItemId": $0.id, "Locations": $0.locations] }
        case "/Users/user-1/Items":
            body = try items(query: query)
        default:
            return try reply(request, status: 404, body: [:])
        }
        return try reply(request, status: 200, body: body)
    }

    private func items(query: [String: String]) throws -> [String: Any] {
        let parentID = try XCTUnwrap(query["ParentId"])
        if query["MinDateLastSaved"] != nil {
            // Nothing changed since the marker.
            return ["Items": [], "TotalRecordCount": 0]
        }
        let start = Int(query["StartIndex"] ?? "0") ?? 0
        let limit = Int(query["Limit"] ?? "100") ?? 100
        return lock.withLock {
            if limit > 1 { pageStartIndices.append(start) }
            let count = libraries.first { $0.id == parentID }?.count ?? 0
            var window = start..<max(start, min(start + limit, count))
            if _clampsOutOfRangeOffsets, start >= count, count > 0 {
                window = max(0, count - limit)..<count
            }
            let rows: [[String: Any]] = window.map { index in
                let id = "\(parentID)-\(String(format: "%04d", index))"
                return ["Id": id, "Name": "Track \(index)", "Path": "/\(parentID)/\(id).mp3"]
            }
            let reported = _reportedTotalCap.map { min($0, count) } ?? count
            return ["Items": rows, "TotalRecordCount": reported]
        }
    }

    private func reply(_ request: URLRequest, status: Int, body: Any) throws -> (Data, URLResponse) {
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (data, response)
    }
}

final class MediaServerPlaylistDescriptionTests: XCTestCase {
    func testMediaServersImportEditAndClearDescriptions() async throws {
        for kind: MediaServerSource.Kind in [.jellyfin, .emby, .plex] {
            let fixture = DescriptionMediaServer(kind: kind)
            let source = fixture.makeSource()
            let imported = try await source.fetchServerPlaylists()
            XCTAssertEqual(imported.playlists.first?.descriptionText, "Remote overview")
            let edited = try await source.updateServerPlaylistDescription(id: "list", description: "简介 & +\n第二行")
            XCTAssertEqual(edited.descriptionText, "简介 & +\n第二行")
            let cleared = try await source.updateServerPlaylistDescription(id: "list", description: "")
            XCTAssertEqual(cleared.descriptionText, "")
            XCTAssertEqual(fixture.writeCount, 2)
            if kind != .plex {
                XCTAssertEqual(fixture.lastWrittenItem?["Name"] as? String, "List")
                XCTAssertEqual(fixture.lastWrittenItem?["Tags"] as? [String], ["Keep me"])
                XCTAssertEqual(fixture.lastWrittenItem?["LockedFields"] as? [String], ["Name"])
            }
            await source.disconnect()
        }
    }

    func testMediaServerUnconfirmedWriteFails() async throws {
        for kind: MediaServerSource.Kind in [.jellyfin, .emby, .plex] {
            let fixture = DescriptionMediaServer(kind: kind, ignoresWrites: true)
            let source = fixture.makeSource()
            do {
                _ = try await source.updateServerPlaylistDescription(id: "list", description: "New")
                XCTFail("Ignored update must not succeed")
            } catch {
                guard case SourceError.connectionFailed = error else {
                    XCTFail("Expected readback mismatch, got \(type(of: error))"); continue
                }
                XCTAssertEqual(fixture.writeCount, 1)
            }
            await source.disconnect()
        }
    }
}

private final class DescriptionMediaServer: @unchecked Sendable {
    let kind: MediaServerSource.Kind
    let ignoresWrites: Bool
    let host = UUID().uuidString.lowercased() + ".invalid"
    private let lock = NSLock()
    private var text = "Remote overview"
    private(set) var writeCount = 0
    private(set) var lastWrittenItem: [String: Any]?
    init(kind: MediaServerSource.Kind, ignoresWrites: Bool = false) {
        self.kind = kind
        self.ignoresWrites = ignoresWrites
    }
    func makeSource() -> MediaServerSource {
        MediaServerSource(sourceID: host, kind: kind, host: host, port: nil, useSsl: true, basePath: nil,
            username: "qa", secret: "token", authType: .apiKey,
            requestDataLoader: { [self] request in try respond(request) })
    }
    func respond(_ request: URLRequest) throws -> (Data, URLResponse) {
        try lock.withLock {
            let url = try XCTUnwrap(request.url)
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
            let query = Dictionary((parts.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            let isWrite = request.httpMethod == "POST" || request.httpMethod == "PUT"
            if isWrite {
                writeCount += 1
                if kind == .plex {
                    XCTAssertEqual(url.path, "/playlists/list")
                    XCTAssertEqual(request.httpMethod, "PUT")
                    XCTAssertEqual(Set(query.keys.filter { !$0.hasPrefix("X-Plex-") }), ["summary"])
                    if !ignoresWrites { text = query["summary"] ?? "" }
                } else {
                    XCTAssertEqual(url.path, "/Items/list")
                    let item = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
                    lastWrittenItem = item
                    if !ignoresWrites { text = item?["Overview"] as? String ?? "" }
                }
            }
            let item: [String: Any] = ["Id": "list", "Name": "List", "Type": "Playlist", "Overview": text,
                "Tags": ["Keep me"], "LockedFields": ["Name"]]
            let plexItem: [String: Any] = ["ratingKey": "list", "title": "List", "playlistType": "audio", "summary": text, "smart": false]
            let body: Any
            switch url.path {
            case "", "/": body = ["MediaContainer": ["machineIdentifier": "server", "version": "1.0"]]
            case "/Users/Me": body = ["Id": "user"]
            case "/Users/user/Views": body = ["Items": []]
            case "/Users/user/Items": body = ["Items": (Int(query["StartIndex"] ?? "0") ?? 0) == 0 ? [item] : [], "TotalRecordCount": 1]
            case "/Items/list", "/Users/user/Items/list": body = item
            case "/Playlists/list/Items": body = ["Items": [], "TotalRecordCount": 0]
            case "/playlists":
                let rows = (Int(query["X-Plex-Container-Start"] ?? "0") ?? 0) == 0 ? [plexItem] : []
                body = ["MediaContainer": ["Metadata": rows, "size": rows.count, "totalSize": 1]]
            case "/playlists/list": body = ["MediaContainer": ["Metadata": [plexItem], "size": 1]]
            case "/playlists/list/items": body = ["MediaContainer": ["Metadata": [], "size": 0, "totalSize": 0]]
            default:
                XCTFail("Unexpected endpoint \(kind): \(url.path)")
                throw URLError(.unsupportedURL)
            }
            return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: url,
                statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
    }
}

@MainActor
final class SubsonicAddedDateTests: XCTestCase {
    func testPagedCatalogUsesServerTrackAndAlbumDates() async throws {
        let (connector, session, host) = makeConnector()
        defer { session.invalidateAndCancel(); AddedDateURLProtocol.remove(host) }
        let page = try await connector.songCatalogPage(from: "/", offset: 0)
        try assertDates(page.songs.map(\.song))
    }

    func testLegacyAlbumWalkUsesAlbumCreatedDate() async throws {
        let (connector, session, host) = makeConnector(legacy: true)
        defer { session.invalidateAndCancel(); AddedDateURLProtocol.remove(host) }
        var songs: [Song] = []
        for try await scanned in try await connector.scanSongs(from: "/") {
            songs.append(scanned.song)
        }
        try assertDates(songs)
    }

    func testMissingAndInvalidDatesFallBackWithoutInventingServerDates() async throws {
        let (connector, session, host) = makeConnector(invalidDates: true)
        defer { session.invalidateAndCancel(); AddedDateURLProtocol.remove(host) }
        let started = Date()
        let page = try await connector.songCatalogPage(from: "/", offset: 0)
        XCTAssertEqual(page.songs.count, 2)
        for scanned in page.songs {
            XCTAssertNil(scanned.song.serverDateAdded)
            XCTAssertNil(scanned.song.serverAlbumDateAdded)
            XCTAssertGreaterThanOrEqual(scanned.song.dateAdded, started)
            XCTAssertLessThanOrEqual(scanned.song.dateAdded, Date())
        }
    }

    func testRescanRepairsExistingLibraryAndPersistsAlbumOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SubsonicAddedDates-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let (connector, session, host) = makeConnector()
        defer { session.invalidateAndCancel(); AddedDateURLProtocol.remove(host) }
        let page = try await connector.songCatalogPage(from: "/", offset: 0)
        let incoming = page.songs.map(\.song)
        let library = MusicLibrary(storageDirectory: root, deferredMaintenanceAllowed: { false })
        let oldRows = incoming.enumerated().map { index, row in
            var old = row
            old.serverDateAdded = nil
            old.serverAlbumDateAdded = nil
            old.dateAdded = Date(timeIntervalSince1970: Double(2_000_000_000 - index))
            old.lyricsText = "Local lyrics"
            return old
        }
        library.addSongs(oldRows, affectedSourceIDs: [host])
        await library.waitForPendingIndex()
        XCTAssertEqual(library.recentlyAddedAlbums().first?.title, "Old album")
        let staging = try PagedSongCatalogStagingStore(path: root.appendingPathComponent("staging.sqlite").path)
        try staging.reset(sourceID: host, stageSessionID: "session", ownerGeneration: 1,
                          replacingStageSessionID: nil, scopeFingerprint: "scope", catalogRevision: "revision")
        _ = try staging.stagePage(sourceID: host, stageSessionID: "session", scopeFingerprint: "scope",
                                  catalogRevision: "revision", offset: 0, nextOffset: nil,
                                  itemIDs: page.itemIDs, songs: incoming, metadataInspectedSongIDs: [],
                                  hierarchyItems: [], addedSongCount: 0)
        let delta = try staging.delta(sourceID: host, existingByID: Dictionary(uniqueKeysWithValues: library.songs.map { ($0.id, $0) }))
        XCTAssertEqual(delta.upserts.count, 2)
        library.addSongs(delta.upserts, affectedSourceIDs: [host], mergeServerCatalogRows: true)
        await library.waitForPendingIndex()
        XCTAssertEqual(library.recentlyAddedAlbums().map(\.title), ["New album", "Old album"])
        for row in incoming {
            XCTAssertEqual(library.song(id: row.id)?.dateAdded, row.serverDateAdded)
            XCTAssertEqual(library.song(id: row.id)?.lyricsText, "Local lyrics")
        }
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Library did not persist")
        }
        let prepared = await MusicLibrary.prepareStartup(disabledSourceIDs: [], storageDirectory: root)
        let reopened = MusicLibrary(storageDirectory: root, preparedStartup: prepared, deferredMaintenanceAllowed: { false })
        XCTAssertEqual(reopened.recentlyAddedAlbums().map(\.title), ["New album", "Old album"])
        let stored = reopened.songs
        reopened.addSongs(incoming, affectedSourceIDs: [host], mergeServerCatalogRows: true)
        await reopened.waitForPendingIndex()
        XCTAssertEqual(reopened.songs, stored, "Reopening then rescanning must be a no-op")
        guard case .success = await reopened.persistNowAndWait() else {
            return XCTFail("Reopened library did not persist")
        }
    }

    private func assertDates(_ songs: [Song]) throws {
        XCTAssertEqual(songs.count, 2)
        let old = try XCTUnwrap(songs.first { $0.title == "Later track" })
        XCTAssertEqual(old.dateAdded, Date(timeIntervalSince1970: 1_704_067_200))
        XCTAssertEqual(old.serverDateAdded, old.dateAdded)
        XCTAssertEqual(old.lastModified?.timeIntervalSince1970 ?? 0, 1_704_067_200.875, accuracy: 0.001)
        XCTAssertEqual(old.serverAlbumDateAdded, Date(timeIntervalSince1970: 1_577_836_800))
        let new = try XCTUnwrap(songs.first { $0.title == "New track" })
        XCTAssertEqual(new.serverDateAdded, Date(timeIntervalSince1970: 1_609_459_200))
        XCTAssertEqual(new.serverAlbumDateAdded, new.serverDateAdded)
    }

    private func makeConnector(legacy: Bool = false, invalidDates: Bool = false) -> (SubsonicSource, URLSession, String) {
        let host = "added-dates-\(UUID().uuidString.lowercased()).invalid"
        AddedDateURLProtocol.register(host, legacy: legacy, invalidDates: invalidDates)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AddedDateURLProtocol.self]
        let session = URLSession(configuration: config)
        let connector = SubsonicSource(sourceID: host, sourceType: .subsonic, host: host, port: nil,
                                       useSsl: true, basePath: nil, username: "qa", password: "qa", session: session)
        return (connector, session, host)
    }
}

private final class AddedDateURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixtures: [String: (legacy: Bool, invalidDates: Bool)] = [:]
    static func register(_ host: String, legacy: Bool, invalidDates: Bool) {
        lock.withLock { fixtures[host] = (legacy, invalidDates) }
    }
    static func remove(_ host: String) { _ = lock.withLock { fixtures.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.lock.withLock({ Self.fixtures[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ name: String) -> String? { params.first { $0.name == name }?.value }
        var albums: [[String: Any]] = [
            ["id": "old", "name": "Old album", "created": "2020-01-01T00:00:00Z"],
            ["id": "new", "name": "New album", "created": "2021-01-01T00:00:00Z"]
        ]
        var songs: [[String: Any]] = [
            ["id": "old-track", "title": "Later track", "albumId": "old", "album": "Old album",
             "artist": "Artist", "duration": 180, "suffix": "flac", "created": "2024-01-01T00:00:00.875Z"],
            ["id": "new-track", "title": "New track", "albumId": "new", "album": "New album",
             "artist": "Artist", "duration": 180, "suffix": "flac", "created": "2021-01-01T08:00:00+08:00"]
        ]
        if fixture.invalidDates {
            albums[0]["created"] = nil; albums[1]["created"] = "invalid"
            songs[0]["created"] = nil; songs[1]["created"] = "invalid"
        }
        var body: [String: Any] = ["status": "ok"]
        switch url.lastPathComponent {
        case "ping.view":
            body["type"] = fixture.legacy ? "subsonic" : "navidrome"
            body["openSubsonic"] = !fixture.legacy
        case "getAlbumList2.view":
            body["albumList2"] = ["album": param("offset") == "0" ? albums : []]
        case "search3.view":
            body["searchResult3"] = ["song": param("songOffset") == "0" ? songs : []]
        case "getAlbum.view":
            body["album"] = ["id": param("id") ?? "", "song": songs.filter { $0["albumId"] as? String == param("id") }]
        default:
            body = ["status": "failed", "error": ["code": 70, "message": "Unsupported fixture method"]]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["subsonic-response": body])
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MediaServerAddedDateTests: XCTestCase {
    func testFullAndPagedCatalogsUseServerAddedDates() async throws {
        for kind: MediaServerSource.Kind in [.jellyfin, .emby, .plex] {
            let source = AddedDateMediaServer.makeSource(kind: kind)
            var full: [Song] = []
            for try await row in try await source.scanSongs(from: "/") { full.append(row.song) }
            let paged = try await source.songCatalogPage(from: "/", offset: 0).songs.map(\.song)
            for songs in [full, paged] {
                XCTAssertEqual(songs.count, 3)
                XCTAssertEqual(songs[0].serverDateAdded, Date(timeIntervalSince1970: 1_600_000_000))
                XCTAssertEqual(songs[1].serverDateAdded, Date(timeIntervalSince1970: 1_700_000_000))
                XCTAssertEqual(songs[0].dateAdded, songs[0].serverDateAdded)
                XCTAssertEqual(songs[1].dateAdded, songs[1].serverDateAdded)
                XCTAssertNil(songs[2].serverDateAdded)
                XCTAssertGreaterThan(songs[2].dateAdded, Date(timeIntervalSince1970: 1_700_000_000))
            }
            await source.disconnect()
        }
    }

    func testScannerRepairsDatesForUnchangedAndReplacedRowsIncludingManualEdits() async throws {
        for edited in [false, true] {
            for replaced in [false, true] {
                let source = AddedDateMediaServer.makeSource(kind: .plex)
                let rows = try await source.songCatalogPage(from: "/", offset: 0).songs.map(\.song)
                let firstImport = Date(timeIntervalSince1970: 1_800_000_000)
                let existing = rows.map { incoming -> Song in
                    var row = incoming
                    row.serverDateAdded = nil
                    row.dateAdded = firstImport
                    if edited {
                        row.title = "My title"
                        row.userMetadataEditedAt = firstImport
                    }
                    if replaced { row.fileSize = 999 }
                    row.lyricsText = "Cached lyrics"
                    return row
                }
                let scanner = ConnectorScanner(connector: source, sourceID: "added-dates")
                var final: ConnectorScanner.ScanUpdate?
                for try await update in await scanner.scan(directories: ["/"], existingSongs: existing) {
                    final = update
                }
                let songs = try XCTUnwrap(final?.songs)
                XCTAssertEqual(songs.count, 3)
                for (index, incoming) in rows.enumerated() {
                    let song = try XCTUnwrap(songs.first { $0.id == incoming.id })
                    XCTAssertEqual(song.dateAdded, incoming.serverDateAdded ?? firstImport)
                    XCTAssertEqual(song.serverDateAdded, incoming.serverDateAdded)
                    if edited { XCTAssertEqual(song.title, "My title") }
                    if !edited && !replaced { XCTAssertEqual(song.lyricsText, existing[index].lyricsText) }
                }
                let changed = await scanner.takePendingChangedSongs()
                XCTAssertTrue(changed.contains { $0.id == rows[0].id })
                await source.disconnect()
            }
        }
    }
}

private enum AddedDateMediaServer {
    static func makeSource(kind: MediaServerSource.Kind) -> MediaServerSource {
        MediaServerSource(sourceID: "added-dates", kind: kind, host: "added-dates.invalid",
                          port: nil, useSsl: true, basePath: nil, username: "user", secret: "fixture",
                          authType: .apiKey, requestDataLoader: { request in
            let url = try XCTUnwrap(request.url)
            let query = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
            let body: Any
            switch url.path {
            case "", "/":
                body = ["MediaContainer": ["machineIdentifier": "fixture"]]
            case "/library/sections":
                body = ["MediaContainer": ["Directory": [["key": "music", "title": "Music", "type": "artist"]]]]
            case "/Users/Me":
                body = ["Id": "user"]
            case "/Users/user/Views":
                body = ["Items": [["Id": "music", "Name": "Music", "CollectionType": "music"]]]
            case "/Library/VirtualFolders", "/Library/VirtualFolders/Query":
                body = [["ItemId": "music", "Locations": ["/music"]]]
            case "/library/sections/music/all", "/Users/user/Items":
                let start = Int(query["StartIndex"] ?? query["X-Plex-Container-Start"] ?? "0") ?? 0
                let limit = Int(query["Limit"] ?? query["X-Plex-Container-Size"] ?? "500") ?? 500
                let rows: [[String: Any]] = (0..<3).map { index in
                    let name = "Track \(index)"
                    if kind == .plex {
                        var row: [String: Any] = ["ratingKey": String(index), "title": name, "type": "track",
                            "parentTitle": "Album \(index)", "grandparentTitle": "Artist",
                            "Media": [["container": "mp3", "Part": [["key": "/audio/\(index).mp3", "file": "/music/\(index).mp3", "size": 100]]]]]
                        if index < 2 { row["addedAt"] = String(1_600_000_000 + index * 100_000_000) }
                        else { row["addedAt"] = 0 }
                        return row
                    }
                    var row: [String: Any] = ["Id": String(index), "Name": name, "Path": "/music/\(index).mp3", "Size": 100]
                    if index < 2 {
                        row["DateCreated"] = index == 0 ? "2020-09-13T12:26:40.123Z" : "2023-11-15T06:13:20+08:00"
                    }
                    return row
                }
                let page = Array(rows.dropFirst(start).prefix(limit))
                if kind == .plex {
                    body = ["MediaContainer": ["Metadata": page, "totalSize": 3, "size": page.count, "offset": start]]
                } else { body = ["Items": page, "TotalRecordCount": 3] }
            default:
                throw URLError(.unsupportedURL)
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                       headerFields: ["Content-Type": "application/json"]))
            return (try JSONSerialization.data(withJSONObject: body), response)
        })
    }
}
