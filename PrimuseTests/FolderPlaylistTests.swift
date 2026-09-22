import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class FolderPlaylistTests: XCTestCase {
    func testRescanRepairsArtistDuplicatedTitleWithoutChangingFileOrUserEdits() async throws {
        let item = RemoteFileItem(
            name: "走在冷风中 (Live) - 刘思涵.mp3", path: "12345678",
            isDirectory: false, size: 9765573, modifiedDate: nil, providerID: "12345678",
            parentPath: "0"
        )
        let connector = FolderPlaylistTestConnector(missingPaths: [], listings: ["0": [item]])
        let scanner = ConnectorScanner(connector: connector, sourceID: "source")
        var initial: [Song] = []
        for try await update in await scanner.scan(directories: ["0"]) {
            initial = update.songs
        }
        var original = try XCTUnwrap(initial.first)
        let index = await scanner.syncIndexSnapshot()
        original.title = "刘思涵"
        original.artistName = "刘思涵"
        original.duration = 214.9
        original.titlePinyin = "liu si han"
        for userEdited in [false, true] {
            original.userMetadataEditedAt = userEdited ? Date() : nil
            var rescanned: [Song] = []
            for try await update in await scanner.scan(
                directories: ["0"], existingSongs: [original], identityIndex: index
            ) {
                rescanned = update.songs
            }
            let song = try XCTUnwrap(rescanned.first)
            XCTAssertEqual(song.title, userEdited ? "刘思涵" : "走在冷风中 (Live)")
            XCTAssertEqual(song.artistName, "刘思涵")
            XCTAssertEqual(song.id, original.id)
            XCTAssertEqual(song.filePath, "12345678")
            if !userEdited { XCTAssertNil(song.titlePinyin) }
        }
        original.userMetadataEditedAt = nil
        let incremental = try await scanner.reconcileChangedDirectories(
            ["0"], deletedStableKeys: [], existingSongs: [original], existingIndex: index,
            scanEpoch: 1
        )
        let updated = try XCTUnwrap(incremental.songs.first)
        XCTAssertEqual(updated.title, "走在冷风中 (Live)")
        XCTAssertEqual(updated.artistName, "刘思涵")
        XCTAssertEqual(updated.duration, 214.9)
        XCTAssertEqual(updated.id, original.id)
    }

    func testRescanRetainsSongIDAfterCloudFileReplacementWithoutCommittedIndex() async throws {
        let item = RemoteFileItem(name: "Track.mp3", path: "99", isDirectory: false,
                                  size: 456, modifiedDate: nil, revision: "new", providerID: "99", parentPath: "0")
        let connector = FolderPlaylistTestConnector(missingPaths: [], listings: ["0": [item]])
        let scanner = ConnectorScanner(connector: connector, sourceID: "source")
        var original = Song(id: "original-id", title: "Edited title", fileFormat: .mp3,
                            filePath: "99", sourceID: "source", fileSize: 456, revision: "new")
        original.userMetadataEditedAt = Date()
        let stale = SourceSyncIndexedItem(stableKey: "42", path: "42", displayName: "Track.mp3",
                                          parentPath: "0", isDirectory: false, songIDs: [original.id],
                                          size: 123, modifiedDate: nil, revision: "old")
        for index in [[:], ["42": stale]] {
            var final: [Song] = []
            for try await update in await scanner.scan(directories: ["0"], existingSongs: [original], identityIndex: index) {
                final = update.songs
            }
            XCTAssertEqual(final.map(\.id), [original.id])
            XCTAssertEqual(final.first?.filePath, "99")
            XCTAssertEqual(final.first?.title, "Edited title")
            let incremental = try await scanner.reconcileChangedDirectories(
                ["0"], deletedStableKeys: [], existingSongs: [original], existingIndex: index, scanEpoch: 1
            )
            XCTAssertEqual(incremental.songs.map(\.id), [original.id])
            XCTAssertEqual(incremental.songs.first?.filePath, "99")
        }
    }

    func testMetadataReplacementPersistsIndexAndDiscardsOldScanCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("Primuse")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let original = Song(id: "kept-id", title: "Original", fileFormat: .mp3,
                            filePath: "42", sourceID: "source", fileSize: 123, revision: "before")
        let other = song("other")
        let index = SourceSyncIndexedItem(stableKey: "42", path: "42", displayName: "Song.mp3",
                                         parentPath: "0", isDirectory: false, songIDs: [original.id],
                                         size: 123, modifiedDate: nil, revision: "before")
        let state = SourceSyncState(sourceID: "source", scopeFingerprint: "fixture", index: ["42": index])
        let checkpoint = ScanCheckpoint(phase: .scanning, intent: .fullScan, directories: ["0"],
                                        songs: [original], totalCount: 1, currentFile: "Song.mp3", updatedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(["source": state]).write(to: storage.appendingPathComponent("source-sync-states.json"))
        try encoder.encode(["source": checkpoint]).write(to: storage.appendingPathComponent("scan-checkpoints.json"))
        let fileManager = FolderPlaylistTestFileManager(root: root)
        let scan = ScanService(fileManager: fileManager)
        XCTAssertTrue(scan.hasResumableScanWork)
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        library.addSongs([original, other], affectedSourceIDs: ["source"])
        await library.waitForPendingIndex()
        var updated = original
        updated.filePath = "99"
        updated.fileSize = 456
        updated.revision = "after"
        try await scan.recordMetadataFileReplacement(original: original, updated: updated, in: library)
        XCTAssertEqual(library.song(id: original.id)?.filePath, "99")
        XCTAssertNotNil(library.song(id: other.id), "Retargeting one row must not prune the source")
        let reopened = ScanService(fileManager: fileManager)
        XCTAssertFalse(reopened.hasResumableScanWork)
        let persistedIndex = reopened.libraryFolderSyncIndex(for: "source")
        XCTAssertNil(persistedIndex["42"])
        XCTAssertEqual(persistedIndex["99"]?.songIDs, [original.id])
        XCTAssertEqual(persistedIndex["99"]?.displayName, "Song.mp3")
        XCTAssertEqual(persistedIndex["99"]?.revision, "after")
    }

    func testMissingChildPreservesSongsWithoutCompleteIdentityIndex() async throws {
        let directory = SourceSyncIndexedItem(
            stableKey: "path:/Music/Live", path: "/Music/Live", parentPath: "/Music",
            isDirectory: true, size: 0, modifiedDate: nil, revision: nil
        )
        let first = song("first")
        let nested = Song(id: "nested", title: "Nested", fileFormat: .mp3,
                          filePath: "/Music/Live/Disc/Track.mp3", sourceID: "source")
        let removedSibling = Song(id: "sibling", title: "Sibling", fileFormat: .mp3,
                                 filePath: "/Music/Lively/Track.mp3", sourceID: "source")
        for index in [[:], [directory.stableKey: directory]] {
            let connector = FolderPlaylistTestConnector(
                missingPaths: ["/Music/Live"],
                listings: ["/Music": [RemoteFileItem(name: "Live", path: "/Music/Live",
                                                   isDirectory: true, size: 0, modifiedDate: nil)]]
            )
            let scanner = ConnectorScanner(connector: connector, sourceID: "source")
            var final: ConnectorScanner.ScanUpdate?
            for try await update in await scanner.scan(
                directories: ["/Music"], existingSongs: [first, nested, removedSibling], identityIndex: index
            ) {
                final = update
            }
            let result = try XCTUnwrap(final)
            XCTAssertEqual(Set(result.songs.map(\.id)), [first.id, nested.id])
            XCTAssertEqual(result.resumeState?.pendingDirectories, [])
            XCTAssertEqual(result.resumeState?.encounteredSongIDs, [first.id, nested.id])
        }
    }

    func testMissingRootPreservesLibraryWithoutAutomaticResume() async throws {
        let fixture = try makeDirectoryScanFixture(missingPaths: ["/Music"])
        let track = song("kept")
        fixture.library.addSongs([track], affectedSourceIDs: [fixture.source.id])
        await fixture.library.waitForPendingIndex()
        let playlist = fixture.library.createPlaylist(name: "Saved", songIDs: [track.id])
        XCTAssertTrue(fixture.start())
        await fixture.scan.waitForActiveScansToComplete()
        XCTAssertNotNil(fixture.scan.scanStates[fixture.source.id]?.failureMessage)
        XCTAssertEqual(fixture.library.songs.map(\.id), [track.id])
        XCTAssertEqual(fixture.library.rawSongIDs(forPlaylist: playlist.id), [track.id])
        XCTAssertFalse(fixture.scan.scanStates[fixture.source.id]?.canResume ?? true)
        XCTAssertFalse(fixture.scan.hasResumableScanWork)
        for _ in 0..<2 {
            fixture.resume()
            await fixture.scan.waitForActiveScansToComplete()
        }
        let automaticListCount = await fixture.connector.listCount
        XCTAssertEqual(automaticListCount, 1)
        XCTAssertTrue(fixture.start())
        await fixture.scan.waitForActiveScansToComplete()
        let manualListCount = await fixture.connector.listCount
        XCTAssertEqual(manualListCount, 2)
    }

    func testCancellingScanUsesCurrentCheckpointForResumeEligibility() async throws {
        for discardCheckpoint in [false, true] {
            let fixture = try makeDirectoryScanFixture(missingPaths: [], pausedPaths: ["/Music"])
            fixture.library.addSongs([song("kept")], affectedSourceIDs: [fixture.source.id])
            XCTAssertTrue(fixture.start())
            let deadline = Date().addingTimeInterval(5)
            while await !fixture.connector.isWaiting, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let isWaiting = await fixture.connector.isWaiting
            XCTAssertTrue(isWaiting)
            if discardCheckpoint { fixture.scan.removeCheckpoint(for: fixture.source.id) }
            fixture.scan.cancelScan(for: fixture.source.id)
            XCTAssertEqual(fixture.scan.scanStates[fixture.source.id]?.canResume, !discardCheckpoint)
            XCTAssertEqual(fixture.scan.hasResumableScanWork, !discardCheckpoint)
            await fixture.connector.release()
        }
    }

    func testIncrementalDirectoryDeletionPrunesNestedSongsAndSkipsConfirmedMissingPaths() async throws {
        let items = [indexed("root", parent: nil, directory: true),
                     indexed("gone", parent: "root", directory: true),
                     indexed("nested", parent: "gone", directory: true),
                     indexed("removed", parent: "nested"),
                     indexed("kept", parent: "other")]
        let index = Dictionary(uniqueKeysWithValues: items.map { ($0.stableKey, $0) })
        let connector = FolderPlaylistTestConnector(missingPaths: ["nested"])
        let scanner = ConnectorScanner(connector: connector, sourceID: "source")
        let result = try await scanner.reconcileChangedDirectories(
            ["root", "nested"], deletedStableKeys: ["gone"],
            existingSongs: [song("removed"), song("kept")], existingIndex: index, scanEpoch: 2
        )
        XCTAssertEqual(result.songs.map(\.id), ["kept"])
        XCTAssertEqual(Set(result.index.keys), ["root", "kept"])
    }

    func testFailedDirectoryListingDoesNotYieldAnEmptyReconciliation() async throws {
        let connector = FolderPlaylistTestConnector(missingPaths: ["unconfirmed"])
        let scanner = ConnectorScanner(connector: connector, sourceID: "source")
        let track = indexed("kept", parent: "unconfirmed")
        do {
            _ = try await scanner.reconcileChangedDirectories(
                ["unconfirmed"], deletedStableKeys: [], existingSongs: [song("kept")],
                existingIndex: ["kept": track], scanEpoch: 2
            )
            XCTFail("An unconfirmed missing path must fail rather than clear the library")
        } catch SourceError.pathNotFound { }
    }

    func testFolderPlaylistPersistsAndReconcilesWhileOrdinaryPlaylistStaysStatic() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseFolderPlaylist-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let source = MusicSource(id: "source", name: "NAS", type: .webdav, extraConfig: "[\"/Music\"]")
        let first = song("first")
        let second = song("second")
        library.addSongs([first, second], affectedSourceIDs: [source.id])
        await library.waitForPendingIndex()
        let nodeID = LibraryFolderNodeID(sourceID: source.id, kind: .folder, normalizedRelativePath: "/music/live")
        let playlist = library.createFolderPlaylist(
            name: "Live", nodeID: nodeID, cloudAccountID: nil, songIDs: [first.id]
        )
        let repeated = library.createFolderPlaylist(
            name: "Live", nodeID: nodeID, cloudAccountID: nil, songIDs: [first.id]
        )
        XCTAssertEqual(repeated.id, playlist.id)
        let ordinary = library.createPlaylist(name: "Static", songIDs: [first.id])
        let bindings = library.folderPlaylistBindings(for: source)
        let refreshed = FolderPlaylistMembershipPolicy.memberships(
            bindings: bindings, source: source, songs: [first, second], syncIndex: nil
        )
        library.applyFolderPlaylistMemberships(refreshed, expectedBindings: bindings)
        XCTAssertEqual(Set(library.songs(forPlaylist: playlist.id).map(\.id)), [first.id, second.id])
        XCTAssertEqual(library.songs(forPlaylist: ordinary.id).map(\.id), [first.id])
        library.remove(songID: first.id, fromPlaylist: playlist.id)
        library.replacePlaylistSongs(playlistID: playlist.id, songIDs: [])
        XCTAssertEqual(library.songs(forPlaylist: playlist.id).count, 2)

        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("Folder binding and membership must finish persistence")
        }
        let restored = MusicLibrary(storageDirectory: directory)
        await restored.waitForPendingIndex()
        XCTAssertEqual(restored.playlist(id: playlist.id)?.folderBinding, playlist.folderBinding)
        XCTAssertEqual(Set(restored.songs(forPlaylist: playlist.id).map(\.id)), [first.id, second.id])

        restored.applyFolderPlaylistMemberships([playlist.id: []], expectedBindings: [:])
        XCTAssertEqual(restored.songs(forPlaylist: playlist.id).count, 2, "A stale binding cannot publish")
        let previousMemberships = [playlist.id: restored.rawSongIDs(forPlaylist: playlist.id)]
        let revisionBeforeDeletion = try XCTUnwrap(restored.playlist(id: playlist.id)?.syncRevision)
        restored.addSongs([second], affectedSourceIDs: [source.id])
        await restored.waitForPendingIndex()
        restored.applyFolderPlaylistMemberships(
            [playlist.id: [second.id]], expectedBindings: bindings, previousMemberships: previousMemberships
        )
        XCTAssertGreaterThan(try XCTUnwrap(restored.playlist(id: playlist.id)?.syncRevision), revisionBeforeDeletion,
                             "Deletion must publish even when library pruning already removed the song ID")
        restored.applyFolderPlaylistMemberships([playlist.id: []], expectedBindings: bindings)
        XCTAssertTrue(restored.songs(forPlaylist: playlist.id).isEmpty)
        XCTAssertEqual(restored.playlist(id: playlist.id)?.folderBinding, playlist.folderBinding)
        guard case .success = await restored.persistNowAndWait() else {
            return XCTFail("An authoritative empty directory must persist without deleting its playlist")
        }
    }

    private func song(_ id: String) -> Song {
        Song(id: id, title: id, fileFormat: .mp3, filePath: "/Music/Live/\(id).mp3", sourceID: "source")
    }

    private func indexed(_ key: String, parent: String?, directory: Bool = false) -> SourceSyncIndexedItem {
        SourceSyncIndexedItem(stableKey: key, path: key, parentPath: parent,
                             isDirectory: directory, songIDs: directory ? [] : [key],
                             size: 0, modifiedDate: nil, revision: nil)
    }

    private struct DirectoryScanFixture {
        let source: MusicSource
        let connector: FolderPlaylistTestConnector
        let scan: ScanService
        let library: MusicLibrary
        let store: SourcesStore
        let manager: SourceManager

        @MainActor func start() -> Bool {
            scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store)
        }

        @MainActor func resume() {
            scan.resumePendingScans(sourceManager: manager, library: library, sourceStore: store, scraperService: nil)
        }
    }

    private func makeDirectoryScanFixture(
        missingPaths: Set<String>, pausedPaths: Set<String> = []
    ) throws -> DirectoryScanFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DirectoryScan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = MusicSource(id: "source", name: "NAS", type: .webdav, extraConfig: "[\"/Music\"]")
        let connector = FolderPlaylistTestConnector(missingPaths: missingPaths, pausedPaths: pausedPaths)
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let scan = ScanService(
            fileManager: FolderPlaylistTestFileManager(root: root), connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) }
        )
        return DirectoryScanFixture(source: source, connector: connector, scan: scan,
                                    library: library, store: store, manager: SourceManager(sourcesProvider: { [] }))
    }
}

private actor FolderPlaylistTestConnector: MusicSourceConnector {
    let sourceID = "source"
    let missingPaths: Set<String>
    let listings: [String: [RemoteFileItem]]
    let pausedPaths: Set<String>
    private(set) var listCount = 0
    private(set) var isWaiting = false
    private var released = false

    init(missingPaths: Set<String>, listings: [String: [RemoteFileItem]] = [:], pausedPaths: Set<String> = []) {
        self.missingPaths = missingPaths; self.listings = listings; self.pausedPaths = pausedPaths
    }
    func release() { released = true }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        listCount += 1
        if pausedPaths.contains(path) {
            isWaiting = true
            while !released { try await Task.sleep(for: .milliseconds(10)) }
        }
        if missingPaths.contains(path) { throw SourceError.pathNotFound(path) }
        return listings[path] ?? []
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        .init { $0.finish() }
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }
}

private final class FolderPlaylistTestFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
}
