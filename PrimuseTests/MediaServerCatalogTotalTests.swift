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
