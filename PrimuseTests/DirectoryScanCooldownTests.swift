import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PrimuseKit
import XCTest
@testable import Primuse

final class DirectoryScanCooldownTests: XCTestCase {
    @MainActor
    func testMissingBaiduIndexRescansOnlyRequestedSubtreeAndKeepsOtherSongs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var source = MusicSource(id: UUID().uuidString, name: "Baidu", type: .baiduPan)
        source.extraConfig = MusicSource.encodeScannedDirectories(["/Music"], into: nil, type: source.type)
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let songs = ["/Music/A/keep.mp3", "/Music/A/Removed/old.mp3", "/Music/B/other.mp3"].enumerated().map { i, path in
            Song(id: "known-\(i)", title: "Tagged \(i)", duration: 180, fileFormat: .mp3,
                 filePath: path, sourceID: source.id, fileSize: 100)
        }
        library.addSongs(songs)
        let connector = ScopedBaiduRepairConnector(sourceID: source.id)
        let scan = ScanService(fileManager: BaiduRepairFileManager(root: root), connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) })
        let manager = SourceManager(sourcesProvider: { [source] in [source] })
        XCTAssertTrue(scan.rescanFolder(of: source, request: SourceFolderRescanRequest(directoryCandidates: ["/Music/A", "/Music", "/"]),
            sourceManager: manager, library: library, sourceStore: store))
        let deadline = Date().addingTimeInterval(15)
        while scan.scanStates[source.id]?.isScanning == true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        defer { scan.cancelScan(for: source.id) }
        XCTAssertNotNil(store.source(id: source.id)?.lastScannedAt)
        let paths = await connector.listedPaths
        XCTAssertEqual(paths, ["/Music/A"])
        XCTAssertEqual(Set(library.songs.map(\.id)), ["known-0", "known-2"])
        XCTAssertEqual(library.song(id: "known-0")?.title, "Tagged 0")
        XCTAssertEqual(library.song(id: "known-2")?.duration, 180)

        let index = scan.libraryFolderSyncIndex(for: source.id)
        store.update(source.id) { $0.scannedDirectoryDisplayNames = ["/Music": "Display name"] }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(scan.libraryFolderSyncIndex(for: source.id), index)
    }

    @MainActor
    func testCapacityEvictionRetainsInspectionAcrossRestartAndRecoversOnPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MetadataAssetStore(storageDirectory: root.appendingPathComponent("artwork"))
        let data = try artworkData()
        let ids = (0..<200).map { "evicted-\($0)" }
        for id in ids { store.storeCoverSync(data, for: id) }
        let cover = store.expectedCoverFileName(for: ids[0])
        let identifier = try XCTUnwrap(store.coverContentIdentifier(named: cover))
        let content = store.artworkContentDirectoryURL.appendingPathComponent(identifier.replacingOccurrences(of: "sha256:", with: "") + ".jpg")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: content.path)
        let removed = expectation(description: "capacity eviction must not reopen song rows")
        removed.isInverted = true
        let token = NotificationCenter.default.addObserver(forName: .primuseArtworkContentEvicted, object: nil, queue: .main) { _ in removed.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }
        let completed = await store.performScheduledContentMaintenance(maximumArtworkBytes: 1)
        XCTAssertTrue(completed)
        await fulfillment(of: [removed], timeout: 0.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: content.path))

        let relaunched = MetadataAssetStore(storageDirectory: root.appendingPathComponent("artwork"))
        let songs = ids.map { id -> Song in
            var song = Song(id: id, title: "Tagged", duration: 180, fileFormat: .mp3, filePath: "/Music/\(id).mp3", sourceID: "baidu")
            song.artistName = "Artist"
            song.coverArtFileName = store.expectedCoverFileName(for: id)
            return song
        }
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        library.addSongs(songs)
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try JSONEncoder().encode(ids).write(to: state.appendingPathComponent("backfill-title-checked.json"))
        let backfill = MetadataBackfillService(library: library, sourceManager: SourceManager(sourcesProvider: { [] }),
            backfillableSourceIDs: { ["baidu"] }, storageDirectory: state, artworkStore: relaunched)
        defer { backfill.stop() }
        await backfill.reopenSongsWithUnreadableCoverFiles()
        backfill.sourceScanSucceeded(forSourceID: "baidu")
        backfill.refreshStatusSnapshot()
        XCTAssertEqual(backfill.remainingCount(forSource: "baidu"), 0)
        XCTAssertEqual(library.song(id: ids[0])?.coverArtFileName, cover)
        XCTAssertTrue(backfill.needsPlaybackTagRead(songID: ids[0], expectedSourceID: "baidu"))
        XCTAssertTrue(relaunched.isCoverContentEvicted(named: cover))
        relaunched.storeCoverSync(data, for: ids[0])
        XCTAssertEqual(relaunched.readCoverData(named: cover), data)
        XCTAssertFalse(relaunched.isCoverContentEvicted(named: cover))
        XCTAssertFalse(backfill.needsPlaybackTagRead(songID: ids[0], expectedSourceID: "baidu"))
        XCTAssertTrue(relaunched.hasReadableCoverFile(named: store.expectedCoverFileName(for: ids[199])), "One recovered content object repairs every shared reference")
        try FileManager.default.removeItem(at: content)
        XCTAssertFalse(relaunched.isCoverContentEvicted(named: cover), "An accidental loss after recovery must not inherit the old capacity marker")
    }

    @MainActor
    func testLegacyArtworkQueueDefersInspectedRowsButKeepsUnreadMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let ids = (0..<500).map { "legacy-artwork-\($0)" }
        var songs = ids.map { id -> Song in
            var song = Song(id: id, title: "Tagged", duration: 180, fileFormat: .mp3, filePath: "/Music/\(id).mp3", sourceID: "baidu")
            song.artistName = "Artist"
            return song
        }
        songs.append(Song(id: "unread", title: "New", fileFormat: .mp3, filePath: "/Music/new.mp3", sourceID: "baidu"))
        library.addSongs(songs)
        let state = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try JSONEncoder().encode(ids).write(to: state.appendingPathComponent("backfill-title-checked.json"))
        let backfill = MetadataBackfillService(library: library, sourceManager: SourceManager(sourcesProvider: { [] }),
            backfillableSourceIDs: { ["baidu"] }, storageDirectory: state)
        defer { backfill.stop() }
        backfill.refreshStatusSnapshot()
        XCTAssertEqual(backfill.remainingCount(forSource: "baidu"), 1)
        XCTAssertTrue(backfill.needsPlaybackTagRead(songID: ids[0], expectedSourceID: "baidu"))
        XCTAssertTrue(backfill.needsPlaybackTagRead(songID: "unread", expectedSourceID: "baidu"))
        XCTAssertEqual(library.song(id: ids[0])?.duration, 180)
        backfill.stop()
        let persisted = state.appendingPathComponent("backfill-peer-seeds.json")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: persisted.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: persisted.path))
        let relaunched = MetadataBackfillService(library: library, sourceManager: SourceManager(sourcesProvider: { [] }),
            backfillableSourceIDs: { ["baidu"] }, storageDirectory: state)
        defer { relaunched.stop() }
        relaunched.refreshStatusSnapshot()
        XCTAssertEqual(relaunched.remainingCount(forSource: "baidu"), 1)
        XCTAssertTrue(relaunched.needsPlaybackTagRead(songID: ids[0], expectedSourceID: "baidu"))
    }

    private func artworkData() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    func testLargeIncrementalReconciliationPreservesMetadataOutsideActualChanges() async throws {
        var existing: [Song] = []
        var index: [String: SourceSyncIndexedItem] = [:]
        var listings: [String: [RemoteFileItem]] = [:]
        for directory in 0..<40 {
            let parent = "/Music/Album-\(directory)"
            for track in 0..<50 {
                let id = "song-\(directory)-\(track)"
                let path = "\(parent)/Track-\(track).mp3"
                var song = Song(id: id, title: "Tagged \(id)", duration: 180,
                                fileFormat: .mp3, filePath: path, sourceID: "source",
                                fileSize: 1_000, revision: "v1")
                song.artistName = "Tagged artist"
                existing.append(song)
                index[id] = SourceSyncIndexedItem(
                    stableKey: id, path: path, parentPath: parent, isDirectory: false,
                    songIDs: [id], size: 1_000, modifiedDate: nil, revision: "v1"
                )
                listings[parent, default: []].append(RemoteFileItem(
                    name: "Track-\(track).mp3", path: path, isDirectory: false,
                    size: 1_000, modifiedDate: nil, revision: "v1", providerID: id,
                    parentPath: parent
                ))
            }
        }
        let removedID = "song-0-0"
        listings["/Music/Album-0"]?.removeFirst()
        listings["/Music/Album-1", default: []].append(RemoteFileItem(
            name: "New.mp3", path: "/Music/Album-1/New.mp3", isDirectory: false,
            size: 2_000, modifiedDate: nil, revision: "v1", providerID: "new",
            parentPath: "/Music/Album-1"
        ))
        let connector = IncrementalReconciliationTestConnector(listings: listings)
        let scanner = ConnectorScanner(connector: connector, sourceID: "source")
        let result = try await scanner.reconcileChangedDirectories(
            Set((0..<20).map { "/Music/Album-\($0)" }), deletedStableKeys: [removedID],
            existingSongs: existing, existingIndex: index, scanEpoch: 2,
            requiresCompleteListings: true
        )
        let byID = Dictionary(uniqueKeysWithValues: result.songs.map { ($0.id, $0) })
        XCTAssertEqual(byID.count, existing.count)
        XCTAssertNil(byID[removedID])
        for song in existing where song.id != removedID {
            let retained = try XCTUnwrap(byID[song.id])
            XCTAssertEqual(retained.title, song.title)
            XCTAssertEqual(retained.duration, song.duration)
            XCTAssertEqual(retained.artistName, song.artistName)
            XCTAssertEqual(retained.filePath, song.filePath)
        }
        XCTAssertNotNil(result.index["new"])
        XCTAssertNil(result.index[removedID])
        let listed = await connector.listCount
        let fileReads = await connector.fileReadCount
        XCTAssertEqual(listed, 20)
        XCTAssertEqual(fileReads, 0, "Unchanged audio must retain its tags without opening files")
    }

    func testSharedHTTPQuotaStopsAndResumesWithoutDiscardingUnvisitedSongs() async throws {
        let failures = [
            HTTPResponseFailure(statusCode: 429),
            HTTPResponseFailure(statusCode: 503, retryAfter: 3600),
            HTTPResponseFailure(statusCode: 403, retryAfter: 3600),
            HTTPResponseFailure(statusCode: 200, isRateLimited: true),
        ]
        for failure in failures {
            let connector = DirectoryCooldownConnector(failure: failure)
            let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
            let song = Song(id: "kept", title: "Kept", fileFormat: .flac,
                            filePath: "/Music/D/kept.flac", sourceID: connector.sourceID)
            var last: ConnectorScanner.ScanUpdate?
            do {
                for try await update in await scanner.scan(directories: ["/Music"], existingSongs: [song]) {
                    last = update
                }
                XCTFail("A quota must stop the scan")
            } catch let actual as HTTPResponseFailure { XCTAssertEqual(actual.statusCode, failure.statusCode) }
            let listed = await connector.listed
            XCTAssertEqual(listed, ["/Music", "/Music/A", "/Music/B"])
            let checkpoint = try XCTUnwrap(last?.resumeState)
            XCTAssertEqual(Set(checkpoint.pendingDirectories), ["/Music/B", "/Music/C", "/Music/D"])
            XCTAssertEqual(last?.songs.map(\.id), [song.id], "Partial scans cannot delete unvisited songs")

            // A second attempt while still limited must stop at the same
            // directory, leaving all other queued work untouched.
            do {
                for try await update in await scanner.scan(directories: ["/Music"], existingSongs: [song], resumeState: checkpoint) {
                    last = update
                }
                XCTFail("Repeated cooldown must remain resumable")
            } catch is HTTPResponseFailure { }
            let repeated = await connector.listed
            XCTAssertEqual(Array(repeated.dropFirst(listed.count)), ["/Music/B"])

            await connector.allowListings()
            let beforeResume = await connector.listed.count
            for try await update in await scanner.scan(directories: ["/Music"], existingSongs: [song], resumeState: try XCTUnwrap(last?.resumeState)) {
                last = update
            }
            let resumed = await connector.listed
            XCTAssertEqual(Set(resumed.dropFirst(beforeResume)), ["/Music/B", "/Music/C", "/Music/D"])
            XCTAssertEqual(last?.resumeState?.pendingDirectories, [])
        }
    }

    func testOrdinaryHTTPFailureDoesNotPauseUnrelatedDirectories() async throws {
        for status in [400, 403, 404, 500, 503] {
            let connector = DirectoryCooldownConnector(failure: HTTPResponseFailure(statusCode: status))
            let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
            var last: ConnectorScanner.ScanUpdate?
            do {
                for try await update in await scanner.scan(directories: ["/Music"]) { last = update }
                XCTFail("The failed directory must still be reported")
            } catch is HTTPResponseFailure { }
            let listed = await connector.listed
            XCTAssertEqual(listed, ["/Music", "/Music/A", "/Music/B", "/Music/C", "/Music/D"])
            XCTAssertEqual(last?.resumeState?.pendingDirectories, ["/Music/B"])
        }
    }
}

private actor DirectoryCooldownConnector: MusicSourceConnector {
    nonisolated let sourceID = "directory-cooldown-" + UUID().uuidString
    private var failure: HTTPResponseFailure?
    private(set) var listed: [String] = []
    init(failure: HTTPResponseFailure) { self.failure = failure }
    func allowListings() { failure = nil }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        listed.append(path)
        if path == "/Music/B", let failure { throw failure }
        guard path == "/Music" else { return [] }
        return ["A", "B", "C", "D"].map {
            RemoteFileItem(name: $0, path: "/Music/\($0)", isDirectory: true, size: 0, modifiedDate: nil)
        }
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}

private actor IncrementalReconciliationTestConnector: MusicSourceConnector {
    nonisolated let sourceID = "source"
    let listings: [String: [RemoteFileItem]]
    private(set) var listCount = 0
    private(set) var fileReadCount = 0

    init(listings: [String: [RemoteFileItem]]) { self.listings = listings }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        listCount += 1
        return listings[path] ?? []
    }
    func localURL(for path: String) async throws -> URL {
        fileReadCount += 1
        throw SourceError.fileNotFound(path)
    }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        fileReadCount += 1
        return .init { $0.finish() }
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }
}

private final class BaiduRepairFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
}

private actor ScopedBaiduRepairConnector: ResumableSnapshotMusicSourceConnector {
    let sourceID: String
    private(set) var listedPaths: [String] = []
    init(sourceID: String) { self.sourceID = sourceID }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        listedPaths.append(path)
        guard path == "/Music/A" else { throw SourceError.pathNotFound(path) }
        return [RemoteFileItem(name: "keep.mp3", path: "/Music/A/keep.mp3", isDirectory: false, size: 100, modifiedDate: nil, providerID: "kept-file")]
    }
    func initialSnapshotMarker(for roots: [String]) async throws -> [String: String] { [:] }
    func snapshotChanges(from state: SourceSyncState, roots: [String], rootIdentities: [SourceSyncRootIdentity],
        resumeState: BaiduSnapshotResumeState?, budget: BaiduSnapshotRefreshBudget,
        progress: @escaping @Sendable (BaiduSnapshotResumeState, SourceSyncTelemetry) async -> Void) async throws -> IncrementalSourceChanges {
        XCTFail("Folder repair must not traverse a whole-source snapshot")
        throw SourceError.fileNotFound("unexpected snapshot")
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}
