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
        for index: SourceSyncIndex in [[:], ["42": stale]] {
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
        try await assertReplacementIndex(providerKeys: nil)
    }

    func test115ReplacementPersistsFileIDsWhileTheRowUsesPickCodes() async throws {
        try await assertReplacementIndex(providerKeys: ("2301", "2302"))
    }

    private func assertReplacementIndex(providerKeys: (old: String, new: String)?) async throws {
        let oldKey = providerKeys?.old ?? "42"
        let newKey = providerKeys?.new ?? "99"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("Primuse")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let original = Song(id: "kept-id", title: "Original", fileFormat: .mp3,
                            filePath: "42", sourceID: "source", fileSize: 123, revision: "before")
        let other = song("other")
        let index = SourceSyncIndexedItem(stableKey: oldKey, path: "42", displayName: "Song.mp3",
                                         parentPath: "0", isDirectory: false, songIDs: [original.id],
                                         size: 123, modifiedDate: nil, revision: "before")
        let state = SourceSyncState(sourceID: "source", scopeFingerprint: "fixture", index: [oldKey: index])
        let checkpoint = ScanCheckpoint(phase: .scanning, intent: .fullScan, directories: ["0"],
                                        songs: [original], totalCount: 1, currentFile: "Song.mp3", updatedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(["source": state]).write(to: storage.appendingPathComponent("source-sync-states.json"))
        try encoder.encode(["source": checkpoint]).write(to: storage.appendingPathComponent("scan-checkpoints.json"))
        let fileManager = FolderPlaylistTestFileManager(root: root)
        let scan = ScanService(fileManager: fileManager)
        scan.automaticScansAllowed = { true }
        await scan.whenStartupStateReady()
        XCTAssertTrue(scan.hasResumableScanWork)
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        library.addSongs([original, other], affectedSourceIDs: ["source"])
        await library.waitForPendingIndex()
        var updated = original
        updated.filePath = "99"
        updated.fileSize = 456
        updated.revision = "after"
        try await scan.recordMetadataFileReplacement(original: original, updated: updated, in: library, providerKeys: providerKeys)
        XCTAssertEqual(library.song(id: original.id)?.filePath, "99")
        XCTAssertNotNil(library.song(id: other.id), "Retargeting one row must not prune the source")
        let reopened = ScanService(fileManager: fileManager)
        reopened.automaticScansAllowed = { true }
        await reopened.whenStartupStateReady()
        XCTAssertFalse(reopened.hasResumableScanWork)
        let persistedIndex = reopened.libraryFolderSyncIndex(for: "source")
        XCTAssertNil(persistedIndex[oldKey])
        XCTAssertEqual(persistedIndex[newKey]?.songIDs, [original.id])
        XCTAssertEqual(persistedIndex[newKey]?.displayName, "Song.mp3")
        XCTAssertEqual(persistedIndex[newKey]?.revision, "after")
        XCTAssertEqual(persistedIndex[newKey]?.path, "99")
        if providerKeys != nil {
            let remote = RemoteFileItem(name: "Song.mp3", path: "99", isDirectory: false, size: 456,
                                        modifiedDate: nil, revision: "after", providerID: newKey, parentPath: "0")
            let connector = FolderPlaylistTestConnector(missingPaths: [], listings: ["0": [remote]])
            let scanner = ConnectorScanner(connector: connector, sourceID: "source")
            let refreshed = try await scanner.reconcileChangedDirectories(
                ["0"], deletedStableKeys: [], existingSongs: [updated], existingIndex: persistedIndex, scanEpoch: 2
            )
            XCTAssertEqual(refreshed.songs.map(\.id), [original.id])
        }
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
                directories: ["/Music"], existingSongs: [first, nested, removedSibling],
                identityIndex: SourceSyncIndex(index)
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
            fixture.scan.automaticScansAllowed = { true }
            await fixture.scan.whenStartupStateReady()
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
            existingSongs: [song("removed"), song("kept")], existingIndex: SourceSyncIndex(index), scanEpoch: 2
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

    func testFolderRescanReconcilesOnlyThatFolderAndItsSubfolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderRescan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = MusicSource(id: "source", name: "NAS", type: .webdav, extraConfig: "[\"/Music\"]")
        func dir(_ path: String) -> RemoteFileItem {
            RemoteFileItem(name: (path as NSString).lastPathComponent, path: path,
                           isDirectory: true, size: 0, modifiedDate: nil)
        }
        func file(_ path: String) -> RemoteFileItem {
            RemoteFileItem(name: (path as NSString).lastPathComponent, path: path,
                           isDirectory: false, size: 1_000, modifiedDate: Date(timeIntervalSince1970: 1_700_000_000))
        }
        let connector = FolderRescanTestConnector(listings: [
            "/Music": [dir("/Music/A"), dir("/Music/B")],
            "/Music/A": [file("/Music/A/a1.mp3"), dir("/Music/A/Disc")],
            "/Music/A/Disc": [file("/Music/A/Disc/d1.mp3")],
            "/Music/B": [file("/Music/B/b1.mp3")],
        ])
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let scan = ScanService(
            fileManager: FolderPlaylistTestFileManager(root: root), connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) }
        )
        let manager = SourceManager(sourcesProvider: { [] })
        XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
        await scan.waitForActiveScansToComplete()
        XCTAssertEqual(Set(library.songs.map(\.filePath)),
                       ["/Music/A/a1.mp3", "/Music/A/Disc/d1.mp3", "/Music/B/b1.mp3"])
        let a1 = try XCTUnwrap(library.songs.first { $0.filePath == "/Music/A/a1.mp3" })
        let b1 = try XCTUnwrap(library.songs.first { $0.filePath == "/Music/B/b1.mp3" })

        // On the server: A gains a song and a new subfolder and loses Disc;
        // B, outside the folder being rescanned, gains a song too.
        await connector.replaceListings([
            "/Music": [dir("/Music/A"), dir("/Music/B")],
            "/Music/A": [file("/Music/A/a1.mp3"), file("/Music/A/a2.mp3"), dir("/Music/A/NewDisc")],
            "/Music/A/NewDisc": [file("/Music/A/NewDisc/n1.mp3")],
            "/Music/B": [file("/Music/B/b1.mp3"), file("/Music/B/b2.mp3")],
        ])
        XCTAssertTrue(scan.rescanFolder(
            of: source,
            request: SourceFolderRescanRequest(anchorSongID: a1.id, levelsAbove: 0),
            sourceManager: manager, library: library, sourceStore: store
        ))
        await scan.waitForActiveScansToComplete()

        XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
        XCTAssertEqual(Set(library.songs.map(\.filePath)),
                       ["/Music/A/a1.mp3", "/Music/A/a2.mp3", "/Music/A/NewDisc/n1.mp3", "/Music/B/b1.mp3"])
        XCTAssertEqual(library.songs.first { $0.filePath == "/Music/A/a1.mp3" }?.id, a1.id)
        XCTAssertEqual(library.songs.first { $0.filePath == "/Music/B/b1.mp3" }?.id, b1.id)
        let listed = await connector.listedPaths
        XCTAssertEqual(listed, ["/Music/A", "/Music/A/NewDisc"])

        var rereadIDs = Set<String>()
        scan.folderTagRereadHandler = { ids, sourceID, _ in
            XCTAssertEqual(sourceID, source.id)
            rereadIDs = Set(ids)
            return MetadataTagRereadProgress(total: ids.count)
        }
        XCTAssertTrue(scan.rescanFolder(
            of: source, request: SourceFolderRescanRequest(directoryCandidates: ["/Music/A", "/Music"]),
            mode: .deep, sourceManager: manager, library: library, sourceStore: store
        ))
        await scan.waitForActiveScansToComplete()
        XCTAssertEqual(rereadIDs, Set(library.songs.filter { $0.filePath.hasPrefix("/Music/A/") }.map(\.id)))
        XCTAssertFalse(rereadIDs.contains(b1.id))
    }

    /// 扫描提交后(扫描后的维护里)重算文件夹歌单的成员:曲库目录可读时在跟上的目录上算,
    /// 与按整库歌曲算的一样;目录没开时按整库歌曲算。
    func testCommittedScanRefreshesFolderPlaylistOnTheCatalog() async throws {
        try await runCommittedScanRefresh(catalog: true)
    }

    func testCommittedScanRefreshesFolderPlaylistInMemory() async throws {
        try await runCommittedScanRefresh(catalog: false)
    }

    private func runCommittedScanRefresh(catalog: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderPlaylistCatalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MusicSource(id: "source", name: "NAS", type: .webdav, extraConfig: "[\"/Music\"]")
        func dir(_ path: String) -> RemoteFileItem {
            RemoteFileItem(name: (path as NSString).lastPathComponent, path: path,
                           isDirectory: true, size: 0, modifiedDate: nil)
        }
        func file(_ path: String) -> RemoteFileItem {
            RemoteFileItem(name: (path as NSString).lastPathComponent, path: path,
                           isDirectory: false, size: 1_000, modifiedDate: Date(timeIntervalSince1970: 1_700_000_000))
        }
        let connector = FolderRescanTestConnector(listings: [
            "/Music": [dir("/Music/A"), dir("/Music/B")],
            "/Music/A": [file("/Music/A/a1.mp3"), dir("/Music/A/Disc")],
            "/Music/A/Disc": [file("/Music/A/Disc/d1.mp3")],
            "/Music/B": [file("/Music/B/b1.mp3")],
        ])
        let library = MusicLibrary(
            storageDirectory: root.appendingPathComponent("library"), catalogMirroring: catalog ? .enabled(startDelay: .zero) : .disabled
        )
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let scan = ScanService(
            fileManager: FolderPlaylistTestFileManager(root: root), connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) }
        )
        let manager = SourceManager(sourcesProvider: { [] })
        XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
        await scan.waitForActiveScansToComplete()
        if catalog {
            await library.waitForCatalogMirror()
            XCTAssertNotNil(library.readableCatalogReader)
        }
        let bound = library.songs.filter { $0.filePath.hasPrefix("/Music/A/") }.map(\.id)
        let playlist = library.createFolderPlaylist(
            name: "A", nodeID: LibraryFolderNodeID(sourceID: source.id, kind: .folder, normalizedRelativePath: "/music/a"),
            cloudAccountID: nil, songIDs: bound
        )

        // A 多了一首和一个子文件夹,少了 Disc;B 也多了一首。
        await connector.replaceListings([
            "/Music": [dir("/Music/A"), dir("/Music/B")],
            "/Music/A": [file("/Music/A/a1.mp3"), file("/Music/A/a2.mp3"), dir("/Music/A/NewDisc")],
            "/Music/A/NewDisc": [file("/Music/A/NewDisc/n1.mp3")],
            "/Music/B": [file("/Music/B/b1.mp3"), file("/Music/B/b2.mp3")],
        ])
        XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
        await scan.waitForActiveScansToComplete()
        XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
        // 成员在扫描后的维护里重算,等它跑完。
        var expected: [String]?
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            await library.waitForPendingIndex()
            expected = FolderPlaylistMembershipPolicy.memberships(
                bindings: library.folderPlaylistBindings(for: source), source: source, songs: library.songs, syncIndex: nil
            )[playlist.id]
            if library.rawSongIDs(forPlaylist: playlist.id) == expected { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(library.rawSongIDs(forPlaylist: playlist.id), expected)
        XCTAssertEqual(Set(library.songs(forPlaylist: playlist.id).map(\.filePath)),
                       ["/Music/A/a1.mp3", "/Music/A/a2.mp3", "/Music/A/NewDisc/n1.mp3"])
        await library.stopCatalogMirror()
    }

    /// 深度影子校验时,重扫走查问「这个源扫描开始时已有的歌」的每一处,曲库目录的答案与数组的相同。
    func testRescanExistingSongLookupsMatchOnTheCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ScanLookupShadow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MusicSource(id: "source", name: "NAS", type: .webdav, extraConfig: "[\"/Music\"]")
        func dir(_ path: String) -> RemoteFileItem {
            RemoteFileItem(name: (path as NSString).lastPathComponent, path: path,
                           isDirectory: true, size: 0, modifiedDate: nil)
        }
        func file(_ path: String, size: Int64 = 1_000) -> RemoteFileItem {
            RemoteFileItem(name: (path as NSString).lastPathComponent, path: path,
                           isDirectory: false, size: size, modifiedDate: Date(timeIntervalSince1970: 1_700_000_000))
        }
        let connector = FolderRescanTestConnector(listings: [
            "/Music": [dir("/Music/A"), dir("/Music/B"), file("/Music/top.mp3")],
            "/Music/A": [file("/Music/A/a1.mp3"), file("/Music/A/a3.mp3"), dir("/Music/A/Disc")],
            "/Music/A/Disc": [file("/Music/A/Disc/d1.mp3"), file("/Music/A/Disc/d2.mp3")],
            "/Music/B": [file("/Music/B/b1.mp3")],
        ])
        let library = MusicLibrary(
            storageDirectory: root.appendingPathComponent("library"), catalogMirroring: .enabled(startDelay: .zero)
        )
        library.catalogShadowModeOverride = .deep
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let scan = ScanService(
            fileManager: FolderPlaylistTestFileManager(root: root), connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) }
        )
        let manager = SourceManager(sourcesProvider: { [] })
        XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
        await scan.waitForActiveScansToComplete()
        await library.waitForPendingIndex()
        await library.waitForCatalogMirror()
        XCTAssertNil(scan.lastExistingLookupShadowReports[source.id], "the first scan has no existing songs")

        // 加歌、删一个子文件夹、一首改了大小、B 多一首。
        await connector.replaceListings([
            "/Music": [dir("/Music/A"), dir("/Music/B"), file("/Music/top.mp3")],
            "/Music/A": [file("/Music/A/a1.mp3"), file("/Music/A/a2.mp3"), file("/Music/A/a3.mp3", size: 2_000),
                         dir("/Music/A/NewDisc")],
            "/Music/A/NewDisc": [file("/Music/A/NewDisc/n1.mp3")],
            "/Music/B": [file("/Music/B/b1.mp3"), file("/Music/B/b2.mp3")],
        ])
        XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
        await scan.waitForActiveScansToComplete()
        var report = try XCTUnwrap(scan.lastExistingLookupShadowReports[source.id])
        XCTAssertGreaterThan(report.lookups, 5)
        XCTAssertEqual(report.mismatches, 0, report.logLine)
        XCTAssertEqual(report.failures, 0, report.logLine)

        // 再挪一首到别的文件夹、删掉 top:走查已经提交过一轮,目录与内存同步后再比。
        await library.waitForPendingIndex()
        await library.waitForCatalogMirror()
        await connector.replaceListings([
            "/Music": [dir("/Music/A"), dir("/Music/B")],
            "/Music/A": [file("/Music/A/a1.mp3"), file("/Music/A/a3.mp3", size: 2_000), dir("/Music/A/NewDisc")],
            "/Music/A/NewDisc": [file("/Music/A/NewDisc/n1.mp3")],
            "/Music/B": [file("/Music/B/b1.mp3"), file("/Music/B/b2.mp3"), file("/Music/B/a2.mp3")],
        ])
        XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
        await scan.waitForActiveScansToComplete()
        report = try XCTUnwrap(scan.lastExistingLookupShadowReports[source.id])
        XCTAssertGreaterThan(report.lookups, 5)
        XCTAssertEqual(report.mismatches, 0, report.logLine)
        XCTAssertEqual(report.failures, 0, report.logLine)
        XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
        await library.stopCatalogMirror()
    }

    func testFullLocalFolderScanReadsChangedTagsWithSameSizeAndTimestamp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("Music")
        let disc = music.appendingPathComponent("Album/Disc")
        try FileManager.default.createDirectory(at: disc, withIntermediateDirectories: true)
        let track = disc.appendingPathComponent("Track.mp3")
        let other = music.appendingPathComponent("Other.mp3")
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        func writeTitle(_ title: String, to url: URL) throws {
            let text = Data([0]) + Data(title.utf8)
            let frame = Data("TIT2".utf8) + Data([0, 0, 0, UInt8(text.count), 0, 0]) + text
            let header = Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, UInt8(frame.count)])
            let audioFrame = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0, count: 413)
            var data = header + frame
            for _ in 0..<100 { data.append(audioFrame) }
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        }
        try writeTitle("Amber", to: track)
        try writeTitle("Amber", to: other)
        let source = MusicSource(id: UUID().uuidString, name: "Music", type: .local, basePath: music.path)
        let connector = LocalFileSource(sourceID: source.id, basePath: music)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("Library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("Sources"))
        store.add(source)
        let scan = ScanService(
            fileManager: FolderPlaylistTestFileManager(root: root), connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) }
        )
        let backfill = MetadataBackfillService(
            library: library, sourceManager: manager, backfillableSourceIDs: { [source.id] },
            bareOnlySourceIDs: { [source.id] },
            directFileSourceIDs: { [source.id] }, storageDirectory: root.appendingPathComponent("Backfill")
        )
        backfill.automaticWorkIsAllowed = { false }
        defer { backfill.stop() }
        scan.folderTagRereadHandler = backfill.rereadTags(songIDs:expectedSourceID:progress:)
        XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
        await scan.waitForActiveScansToComplete()
        let song = try XCTUnwrap(library.songs.first { $0.filePath == "/Album/Disc/Track.mp3" })
        let sibling = try XCTUnwrap(library.songs.first { $0.filePath == "/Other.mp3" })
        for id in [song.id, sibling.id] {
            guard case .completed = await backfill.rereadTags(songID: id) else { return XCTFail("Initial tag read") }
            XCTAssertEqual(library.storedSong(id: id)?.title, "Amber")
        }
        try writeTitle("Cedar", to: track)
        try writeTitle("Cedar", to: other)
        // Model a provider whose entire file revision stayed unchanged. On a
        // local volume ctime normally reveals this edit even in automatic mode.
        var stale = try XCTUnwrap(library.storedSong(id: song.id))
        stale.revision = try await connector.metadataWritebackState(for: stale.filePath).revision
        library.replaceSong(stale)
        for (mode, expectedTitle) in [(SourceSyncMode.automatic, "Amber"), (.deep, "Cedar")] {
            XCTAssertTrue(scan.rescanFolder(
                of: source, request: .init(directoryCandidates: ["/Album", "/"]), mode: mode,
                sourceManager: manager, library: library, sourceStore: store
            ))
            await scan.waitForActiveScansToComplete()
            XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
            XCTAssertEqual(library.storedSong(id: song.id)?.title, expectedTitle)
            XCTAssertEqual(library.storedSong(id: sibling.id)?.title, "Amber")
        }
    }

    func testFolderRescanKeepsTagsReadFromUnchangedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FolderRescanTags-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MusicSource(id: "source", name: "NAS", type: .webdav, extraConfig: "[\"/Books\"]")
        let book = RemoteFileItem(name: "Novel", path: "/Books/Novel", isDirectory: true, size: 0, modifiedDate: nil)
        func chapter(_ name: String, size: Int64 = 1_000) -> RemoteFileItem {
            RemoteFileItem(name: name, path: "/Books/Novel/" + name, isDirectory: false,
                           size: size, modifiedDate: Date(timeIntervalSince1970: 1_700_000_000))
        }
        let connector = FolderRescanTestConnector(listings: [
            "/Books": [book],
            "/Books/Novel": [chapter("Chapter-001.mp3"), chapter("Chapter-002.mp3")],
        ])
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let scan = ScanService(
            fileManager: FolderPlaylistTestFileManager(root: root), connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) }
        )
        let manager = SourceManager(sourcesProvider: { [] })
        XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
        await scan.waitForActiveScansToComplete()
        // What the backfill reads from each file's tags.
        library.replaceSongs(library.songs.map { song in
            var song = song
            song.title = "Tagged " + song.title
            song.albumTitle = "Tagged Book"
            song.trackNumber = 7
            song.duration = 30
            return song
        })
        await library.waitForPendingIndex()
        let first = try XCTUnwrap(library.songs.first { $0.filePath == "/Books/Novel/Chapter-001.mp3" })
        let second = try XCTUnwrap(library.songs.first { $0.filePath == "/Books/Novel/Chapter-002.mp3" })

        // Chapter 2 was replaced on the server; chapter 1 is untouched.
        await connector.replaceListings([
            "/Books": [book],
            "/Books/Novel": [chapter("Chapter-001.mp3"), chapter("Chapter-002.mp3", size: 2_000)],
        ])
        XCTAssertTrue(scan.rescanFolder(
            of: source,
            request: SourceFolderRescanRequest(anchorSongID: first.id, levelsAbove: 0),
            sourceManager: manager, library: library, sourceStore: store
        ))
        await scan.waitForActiveScansToComplete()

        XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
        let kept = try XCTUnwrap(library.storedSong(id: first.id))
        XCTAssertEqual(kept.title, first.title)
        XCTAssertEqual(kept.albumTitle, "Tagged Book")
        XCTAssertEqual(kept.trackNumber, 7)
        XCTAssertEqual(kept.duration, 30)
        let replaced = try XCTUnwrap(library.storedSong(id: second.id))
        XCTAssertEqual(replaced.fileSize, 2_000)
        XCTAssertEqual(replaced.duration, 0, "A replaced file is read again")
        XCTAssertNil(replaced.albumTitle)
    }

    func testDirectoryPickerRescanStartsAtTheNamedFolderEvenBeforeDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PickerRescan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = MusicSource(id: "source", name: "NAS", type: .webdav, extraConfig: "[\"/Music\"]")
        func dir(_ path: String) -> RemoteFileItem {
            RemoteFileItem(name: (path as NSString).lastPathComponent, path: path,
                           isDirectory: true, size: 0, modifiedDate: nil)
        }
        func file(_ path: String) -> RemoteFileItem {
            RemoteFileItem(name: (path as NSString).lastPathComponent, path: path,
                           isDirectory: false, size: 1_000, modifiedDate: Date(timeIntervalSince1970: 1_700_000_000))
        }
        let connector = FolderRescanTestConnector(listings: [
            "/Music": [dir("/Music/A"), dir("/Music/B")],
            "/Music/A": [file("/Music/A/a1.mp3"), dir("/Music/A/Disc")],
            "/Music/A/Disc": [file("/Music/A/Disc/d1.mp3")],
            "/Music/B": [file("/Music/B/b1.mp3")],
        ])
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let scan = ScanService(
            fileManager: FolderPlaylistTestFileManager(root: root), connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) }
        )
        let manager = SourceManager(sourcesProvider: { [] })
        XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
        await scan.waitForActiveScansToComplete()

        // 选目录页「已包含」的 Disc 行：目录本身在前，再是浏览经过的上级。
        await connector.replaceListings([
            "/Music": [dir("/Music/A"), dir("/Music/B")],
            "/Music/A": [file("/Music/A/a1.mp3"), dir("/Music/A/Disc")],
            "/Music/A/Disc": [file("/Music/A/Disc/d1.mp3"), file("/Music/A/Disc/d2.mp3")],
            "/Music/B": [file("/Music/B/b1.mp3"), file("/Music/B/b2.mp3")],
        ])
        XCTAssertTrue(scan.rescanFolder(
            of: source,
            request: SourceFolderRescanRequest(directoryCandidates: ["/Music/A/Disc", "/Music/A", "/Music", "/"]),
            sourceManager: manager, library: library, sourceStore: store
        ))
        await scan.waitForActiveScansToComplete()
        XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
        var listed = await connector.listedPaths
        XCTAssertEqual(listed, ["/Music/A/Disc"])
        XCTAssertEqual(Set(library.songs.map(\.filePath)),
                       ["/Music/A/a1.mp3", "/Music/A/Disc/d1.mp3", "/Music/A/Disc/d2.mp3", "/Music/B/b1.mp3"])

        // 新目录和它的平级目录同时变化。只点 CD2，另两个目录的变更留给以后扫描。
        await connector.replaceListings([
            "/Music": [dir("/Music/A"), dir("/Music/B")],
            "/Music/A": [file("/Music/A/a1.mp3"), dir("/Music/A/Disc"), dir("/Music/A/CD2"), file("/Music/A/unsolicited.mp3")],
            "/Music/A/Disc": [file("/Music/A/Disc/d1.mp3"), file("/Music/A/Disc/d2.mp3")],
            "/Music/A/CD2": [file("/Music/A/CD2/n1.mp3")],
            "/Music/B": [file("/Music/B/b1.mp3"), file("/Music/B/b2.mp3")],
        ])
        XCTAssertTrue(scan.rescanFolder(
            of: source,
            request: SourceFolderRescanRequest(directoryCandidates: ["/Music/A/CD2", "/Music/A", "/Music", "/"]),
            sourceManager: manager, library: library, sourceStore: store
        ))
        await scan.waitForActiveScansToComplete()
        XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
        listed = await connector.listedPaths
        XCTAssertEqual(listed, ["/Music/A/CD2"])
        XCTAssertEqual(Set(library.songs.map(\.filePath)), [
            "/Music/A/a1.mp3", "/Music/A/Disc/d1.mp3", "/Music/A/Disc/d2.mp3",
            "/Music/A/CD2/n1.mp3", "/Music/B/b1.mp3",
        ])
    }

    func testFirstFolderRescanLeavesOtherSongsAndPausedFullScanUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("Primuse")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let source = MusicSource(id: "source", name: "Drive", type: .pan115, extraConfig: "[\"music-id\"]")
        let outside = Song(id: "already-present", title: "Outside", fileFormat: .mp3,
                           filePath: "sibling-song-id", sourceID: source.id)
        let staged = Song(id: "pending-song", title: "Staged", fileFormat: .mp3,
                          filePath: "new-sibling-id", sourceID: source.id)
        let checkpoint = ScanCheckpoint(
            phase: .scanning, intent: .fullScan, directories: ["music-id"], songs: [staged], totalCount: 9,
            currentFile: "Staged", updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            scopeFingerprint: ScanService.scopeFingerprint(for: source, directories: ["music-id"]),
            isPausedByUser: true
        )
        let checkpointURL = storage.appendingPathComponent("scan-checkpoints.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let checkpointData = try encoder.encode([source.id: checkpoint])
        try checkpointData.write(to: checkpointURL)
        let connector = FolderPlaylistTestConnector(missingPaths: [], listings: [
            "album-id": [RemoteFileItem(name: "Disc", path: "disc-id", isDirectory: true, size: 0,
                                        modifiedDate: nil, providerID: "disc-id", parentPath: "album-id")],
            "disc-id": [RemoteFileItem(name: "Track.mp3", path: "track-id", isDirectory: false, size: 42,
                                       modifiedDate: nil, providerID: "track-id", parentPath: "disc-id")]
        ], pausedPaths: ["album-id"])
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        library.addSongs([outside], affectedSourceIDs: [source.id])
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let scan = ScanService(
            fileManager: FolderPlaylistTestFileManager(root: root), connectorProvider: { _ in connector },
            diagnosticProvider: { source, directories in
                XCTAssertEqual(directories, ["album-id"])
                return SourceDiagnosticReport(source: source, startedAt: Date(), checks: [])
            }
        )
        scan.automaticScansAllowed = { true }
        await scan.whenStartupStateReady()
        XCTAssertEqual(scan.scanStates[source.id]?.canResume, true)
        XCTAssertFalse(scan.hasResumableScanWork)
        XCTAssertTrue(scan.rescanFolder(
            of: source, request: SourceFolderRescanRequest(directoryCandidates: ["album-id", "music-id", "/"]),
            sourceManager: SourceManager(sourcesProvider: { [] }), library: library, sourceStore: store
        ))
        let deadline = Date().addingTimeInterval(5)
        while await !connector.isWaiting, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let isWaiting = await connector.isWaiting
        XCTAssertTrue(isWaiting)
        let imported = Song(id: "another-import", title: "Imported", fileFormat: .mp3,
                            filePath: "other-import-id", sourceID: source.id)
        var updated = outside
        updated.title = "Edited during scan"
        library.replaceSongs([updated])
        library.addSongs([imported], affectedSourceIDs: [source.id], pruneMissingSongs: false)
        await connector.release()
        await scan.waitForActiveScansToComplete()

        let listed = await connector.listedPaths
        XCTAssertEqual(listed, ["album-id", "disc-id"])
        XCTAssertEqual(Set(library.songs.map(\.filePath)), [outside.filePath, imported.filePath, "track-id"])
        XCTAssertEqual(library.song(id: outside.id)?.title, updated.title)
        XCTAssertEqual(store.source(id: source.id)?.songCount, 3)
        XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
        XCTAssertEqual(scan.scanStates[source.id]?.canResume, true)
        XCTAssertEqual(scan.scanStates[source.id]?.totalCount, 9)
        XCTAssertEqual(try Data(contentsOf: checkpointURL), checkpointData)
    }

    func testFolderRescanOfARemovedFolderWalksUpFromASong() async throws {
        let index = Dictionary(uniqueKeysWithValues: [
            indexed("/Music/A", parent: "/Music", directory: true),
            indexed("/Music/A/Disc", parent: "/Music/A", directory: true),
            indexed("/Music/A/Disc/d1.mp3", parent: "/Music/A/Disc"),
        ].map { ($0.stableKey, $0) })
        XCTAssertEqual(
            SourceSyncSubtreePolicy.directory(containingSongID: "/Music/A/Disc/d1.mp3", levelsAbove: 1, in: index),
            "/Music/A"
        )
    }

    /// Yandex Disk 一阵 PROPFIND 之后对列目录回 429: 连接器等过 Retry-After 仍被限流时,
    /// 扫描要停下并把没列的目录全部留给续扫, 而不是逐个撞成失败。503 仍按单个目录失败处理。
    func testRateLimitedListingStopsTheWalkAndKeepsRemainingDirectoriesForResume() async throws {
        let children = ["A", "B", "C", "D"].map {
            RemoteFileItem(name: $0, path: "/Music/\($0)", isDirectory: true, size: 0, modifiedDate: nil)
        }
        for statusCode in [429, 503] {
            let connector = RateLimitedListingTestConnector(
                listings: ["/Music": children],
                failingPath: "/Music/B",
                statusCode: statusCode
            )
            let scanner = ConnectorScanner(connector: connector, sourceID: "source")
            var final: ConnectorScanner.ScanUpdate?
            do {
                for try await update in await scanner.scan(directories: ["/Music"]) {
                    final = update
                }
                XCTFail("A failed directory must surface as a scan failure")
            } catch let error as RemoteDirectoryHTTPStatusError {
                XCTAssertEqual(error.statusCode, statusCode)
            }
            let listed = await connector.listedPaths
            let pending = Set(try XCTUnwrap(final?.resumeState?.pendingDirectories))
            if statusCode == 429 {
                XCTAssertEqual(listed, ["/Music", "/Music/A", "/Music/B"])
                XCTAssertEqual(pending, ["/Music/B", "/Music/C", "/Music/D"])
            } else {
                XCTAssertEqual(listed, ["/Music", "/Music/A", "/Music/B", "/Music/C", "/Music/D"])
                XCTAssertEqual(pending, ["/Music/B"])
            }
        }
    }

    // MARK: 一轮走查少了一大批

    /// 共享文件夹还在、底下的硬盘没挂上：目录列出来是空的，和真删了读起来一样。
    func testWalkThatLosesMostSongsKeepsThemUntilRepeatedScansConfirm() async throws {
        let fixture = try makeSwitchableWalkFixture(trackCount: 60)
        try await fixture.scanOnce()
        XCTAssertEqual(fixture.songCount, 60)

        await fixture.connector.setTrackCount(0)
        for pass in 1...2 {
            try await fixture.scanOnce()
            XCTAssertEqual(fixture.songCount, 60, "pass \(pass) must keep the songs")
            XCTAssertNotNil(fixture.scan.scanStates[fixture.source.id]?.reconciliationMessage)
        }
        try await fixture.scanOnce()
        XCTAssertEqual(fixture.songCount, 0)
        XCTAssertNil(fixture.scan.scanStates[fixture.source.id]?.reconciliationMessage)
    }

    func testSongsThatComeBackClearTheHeldEvidence() async throws {
        let fixture = try makeSwitchableWalkFixture(trackCount: 60)
        try await fixture.scanOnce()
        await fixture.connector.setTrackCount(0)
        try await fixture.scanOnce()
        try await fixture.scanOnce()
        XCTAssertEqual(fixture.songCount, 60)

        await fixture.connector.setTrackCount(60)
        try await fixture.scanOnce()
        XCTAssertNil(fixture.scan.scanStates[fixture.source.id]?.reconciliationMessage)

        // The drive drops out again: the count starts over instead of
        // finishing the earlier, interrupted run of witnesses.
        await fixture.connector.setTrackCount(0)
        try await fixture.scanOnce()
        try await fixture.scanOnce()
        XCTAssertEqual(fixture.songCount, 60)
    }

    func testOrdinaryDeletionStillRemovesOnTheFirstScan() async throws {
        let fixture = try makeSwitchableWalkFixture(trackCount: 60)
        try await fixture.scanOnce()
        await fixture.connector.setTrackCount(55)
        try await fixture.scanOnce()
        XCTAssertEqual(fixture.songCount, 55)
        XCTAssertNil(fixture.scan.scanStates[fixture.source.id]?.reconciliationMessage)
    }

    // MARK: 文件走查只交遇到的 id 与改过的行

    /// 文件走查的提交不再带整份终态快照:只交这一轮遇到的歌的 id 和改过的行。结果要和原来把整份快照
    /// 交给资料库剪枝的提交一样。一边是 ScanService 扫出来的资料库,一边照原来的做法维护一份对照
    /// (直接跑走查,拿整份快照 `addSongs`);加歌、删歌、改大小、挪文件夹、删文件夹、本机隐藏的 CUE 分轨、
    /// 带着断点行续扫之后,两边这个源的歌逐项相同(新歌的加入时间除外),本机隐藏的行也相同。
    /// 这一遍开着影子比对:走查照旧带上整份快照,`ScanFileWalkCommitShadow` 对一遍新提交,不能有不一致。
    func testFileWalkCommitMatchesWholeSnapshotCommit() async throws {
        try await runFileWalkCommitScenario(shadow: true)
    }

    /// 同一套情形,走查不带整份快照(发布版的样子)。
    func testFileWalkCommitWithoutSnapshotMatchesWholeSnapshotCommit() async throws {
        try await runFileWalkCommitScenario(shadow: false)
    }

    private func runFileWalkCommitScenario(shadow: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileWalkCommit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MusicSource(id: "walk-\(UUID().uuidString)", name: "NAS", type: .webdav, extraConfig: "[\"/Music\"]")
        func dir(_ path: String) -> RemoteFileItem {
            RemoteFileItem(name: (path as NSString).lastPathComponent, path: path,
                           isDirectory: true, size: 0, modifiedDate: nil)
        }
        func file(_ path: String, size: Int64 = 1_000) -> RemoteFileItem {
            RemoteFileItem(name: (path as NSString).lastPathComponent, path: path,
                           isDirectory: false, size: size, modifiedDate: Date(timeIntervalSince1970: 1_700_000_000))
        }
        let cue = Data("""
        FILE "image.flac" WAVE
          TRACK 01 AUDIO
            TITLE "First Light"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Evening Walk"
            INDEX 01 03:00:00
        """.utf8)
        let image = [file("/Music/B/image.flac", size: 50_000), file("/Music/B/image.cue", size: Int64(cue.count))]
        let connector = FileWalkScenarioConnector(sourceID: source.id, listings: [
            "/Music": [dir("/Music/A"), dir("/Music/B"), file("/Music/top.flac")],
            "/Music/A": [file("/Music/A/a1.flac"), file("/Music/A/a3.flac"), dir("/Music/A/Disc")],
            "/Music/A/Disc": [file("/Music/A/Disc/d1.flac"), file("/Music/A/Disc/d2.flac")],
            "/Music/B": [file("/Music/B/b1.flac")] + image,
        ], contents: ["/Music/B/image.cue": cue])

        // 被比的一边:ScanService 扫出来的资料库。
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let manager = SourceManager(sourcesProvider: { [] })
        let fileManager = FolderPlaylistTestFileManager(root: root)
        func makeScanService() -> ScanService {
            let service = ScanService(
                fileManager: fileManager, connectorProvider: { _ in connector },
                diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) }
            )
            service.fileWalkCommitShadowOverride = shadow
            return service
        }
        var scan = makeScanService()
        func scanSubject(_ step: String) async throws {
            XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store), step)
            await scan.waitForActiveScansToComplete()
            await library.waitForPendingIndex()
            XCTAssertNil(scan.scanStates[source.id]?.failureMessage, step)
            XCTAssertFalse(scan.scanStates[source.id]?.canResume == true, step)
            if shadow {
                let report = try XCTUnwrap(scan.lastFileWalkCommitShadowReports[source.id], step)
                XCTAssertGreaterThan(report.lookups, 0, step)
                XCTAssertEqual(report.mismatches, 0, "\(step): \(report.logLine)")
            } else {
                XCTAssertNil(scan.lastFileWalkCommitShadowReports[source.id], step)
            }
        }

        // 对照的一边:原来的提交。走查交出整份终态快照,和库里不一样就整份交给 `addSongs` 剪枝;
        // 续扫时先把断点行回灌进库(`scanSource` 的做法),再把它们排在已有的歌前面交给走查。
        let reference = MusicLibrary(storageDirectory: root.appendingPathComponent("reference"))
        var referenceIndex = SourceSyncIndex()
        func hiddenSegments(_ library: MusicLibrary) -> [Song] {
            library.locallyRemovedEntries(forSourceID: source.id).map(\.song)
                .filter { SourceFileDeletionPolicy.isFileSegment($0) }
        }
        func scanReference(resuming checkpoint: ScanCheckpoint? = nil) async throws {
            let resumeRows = checkpoint?.songs ?? []
            let seed = resumeRows.filter { row in
                guard let existing = reference.song(id: row.id) else { return true }
                return ScanService.resumeSeedNeedsUpdate(checkpointRow: row, libraryRow: existing)
            }
            if !seed.isEmpty {
                reference.addSongs(seed, affectedSourceIDs: [source.id], notifyRemovals: false, pruneMissingSongs: false)
            }
            let resumeIDs = Set(resumeRows.map(\.id))
            let known = reference.songs.filter { $0.sourceID == source.id } + hiddenSegments(reference)
            let existing = resumeRows + known.filter { !resumeIDs.contains($0.id) }
            let scanner = ConnectorScanner(connector: connector, sourceID: source.id)
            var snapshot: [Song] = []
            let updates = await scanner.scan(
                directories: ["/Music"], existingSongs: existing,
                resumeState: checkpoint?.directoryState, identityIndex: referenceIndex
            )
            for try await update in updates where update.carriesFullSnapshot {
                snapshot = update.songs
            }
            referenceIndex = await scanner.syncIndexSnapshot()
            if SourceCatalogSnapshotPolicy.hasChanges(
                existing: reference.songs.filter { $0.sourceID == source.id }, candidate: snapshot
            ) {
                reference.addSongs(snapshot, affectedSourceIDs: [source.id])
            }
            await reference.waitForPendingIndex()
        }

        func rows(_ library: MusicLibrary) -> [String: Song] {
            var rows: [String: Song] = [:]
            for var song in library.songs where song.sourceID == source.id {
                song.dateAdded = .distantPast
                rows[song.id] = song
            }
            return rows
        }
        func paths(_ library: MusicLibrary) -> Set<String> {
            Set(library.songs.filter { $0.sourceID == source.id && !$0.isCueTrack }.map(\.filePath))
        }
        func assertSame(_ step: String) {
            let subject = rows(library)
            let expected = rows(reference)
            XCTAssertEqual(Set(subject.keys), Set(expected.keys), step)
            for (id, row) in expected where subject[id] != nil {
                XCTAssertEqual(subject[id], row, "\(step): \(row.filePath)")
            }
            XCTAssertEqual(library.locallyRemovedSongIDs(forSourceID: source.id),
                           reference.locallyRemovedSongIDs(forSourceID: source.id), step)
        }
        func scanBoth(_ step: String) async throws {
            try await scanSubject(step)
            try await scanReference()
            assertSame(step)
        }
        /// 像补读那样给一首歌写上标签(两边写的一样)。
        func tag(_ path: String) throws {
            for target in [library, reference] {
                var song = try XCTUnwrap(target.songs.first { $0.sourceID == source.id && $0.filePath == path })
                song.duration = 180
                song.artistName = "Tagged"
                target.replaceSongs([song])
            }
        }

        try await scanBoth("first scan")
        XCTAssertEqual(paths(library), ["/Music/top.flac", "/Music/A/a1.flac", "/Music/A/a3.flac", "/Music/A/Disc/d1.flac",
                                        "/Music/A/Disc/d2.flac", "/Music/B/b1.flac"])
        XCTAssertEqual(library.songs.filter(\.isCueTrack).count, 2)
        try tag("/Music/A/a1.flac")
        try tag("/Music/A/a3.flac")
        try tag("/Music/B/b1.flac")

        try await scanBoth("unchanged rescan")
        XCTAssertEqual(library.songs.first { $0.filePath == "/Music/A/a1.flac" }?.duration, 180)

        // 加歌、一首改了大小、删一个子文件夹换一个新的、B 多一首。
        await connector.replaceListings([
            "/Music": [dir("/Music/A"), dir("/Music/B"), file("/Music/top.flac")],
            "/Music/A": [file("/Music/A/a1.flac"), file("/Music/A/a2.flac"), file("/Music/A/a3.flac", size: 2_000),
                         dir("/Music/A/NewDisc")],
            "/Music/A/NewDisc": [file("/Music/A/NewDisc/n1.flac")],
            "/Music/B": [file("/Music/B/b1.flac"), file("/Music/B/b2.flac")] + image,
        ])
        try await scanBoth("added, resized, folder replaced")
        XCTAssertEqual(paths(library), ["/Music/top.flac", "/Music/A/a1.flac", "/Music/A/a2.flac", "/Music/A/a3.flac",
                                        "/Music/A/NewDisc/n1.flac", "/Music/B/b1.flac", "/Music/B/b2.flac"])
        XCTAssertEqual(library.songs.first { $0.filePath == "/Music/A/a1.flac" }?.duration, 180)
        XCTAssertEqual(library.songs.first { $0.filePath == "/Music/A/a3.flac" }?.duration, 0)
        XCTAssertEqual(library.songs.first { $0.filePath == "/Music/A/a3.flac" }?.fileSize, 2_000)

        // 挪一首到别的文件夹、删掉 top。
        await connector.replaceListings([
            "/Music": [dir("/Music/A"), dir("/Music/B")],
            "/Music/A": [file("/Music/A/a1.flac"), file("/Music/A/a3.flac", size: 2_000), dir("/Music/A/NewDisc")],
            "/Music/A/NewDisc": [file("/Music/A/NewDisc/n1.flac")],
            "/Music/B": [file("/Music/B/b1.flac"), file("/Music/B/b2.flac"), file("/Music/B/a2.flac")] + image,
        ])
        try await scanBoth("moved and removed")
        XCTAssertEqual(paths(library), ["/Music/A/a1.flac", "/Music/A/a3.flac", "/Music/A/NewDisc/n1.flac",
                                        "/Music/B/b1.flac", "/Music/B/b2.flac", "/Music/B/a2.flac"])

        // 本机隐藏一条 CUE 分轨(源文件留着):重扫不把它带回来,保留的记录也还在。
        let hiddenTrack = try XCTUnwrap(library.songs.first { $0.isCueTrack && $0.trackNumber == 2 })
        let visibleTrack = try XCTUnwrap(library.songs.first { $0.isCueTrack && $0.trackNumber == 1 })
        try library.removeSongsFromThisDevice([hiddenTrack])
        try reference.removeSongsFromThisDevice([try XCTUnwrap(reference.song(id: hiddenTrack.id))])
        try await scanBoth("hidden CUE segment, unchanged rescan")
        XCTAssertEqual(library.songs.filter(\.isCueTrack).map(\.id), [visibleTrack.id])
        XCTAssertEqual(library.locallyRemovedSongIDs(forSourceID: source.id), [hiddenTrack.id])

        await connector.setListing("/Music/B", [file("/Music/B/b1.flac"), file("/Music/B/b2.flac"), file("/Music/B/a2.flac"),
                                                file("/Music/B/b3.flac")] + image)
        try await scanBoth("hidden CUE segment, another file added")
        XCTAssertEqual(library.songs.filter(\.isCueTrack).map(\.id), [visibleTrack.id])
        XCTAssertEqual(library.locallyRemovedSongIDs(forSourceID: source.id), [hiddenTrack.id])

        // 镜像没了:看得见的那条分轨删掉,隐藏那条的保留记录也清掉。
        await connector.setListing("/Music/B", [file("/Music/B/b1.flac"), file("/Music/B/b2.flac"), file("/Music/B/a2.flac"),
                                                file("/Music/B/b3.flac")])
        try await scanBoth("CUE image removed")
        XCTAssertTrue(library.songs.filter(\.isCueTrack).isEmpty)
        XCTAssertTrue(library.locallyRemovedSongIDs(forSourceID: source.id).isEmpty)

        // 带着断点行续扫。扫描在 B 没列完时被杀掉:A 里改过的一首和 C 里的新歌读到了、还没入库,
        // 断点里是这几行和走查进度。重开后接着走 B。
        let checkpointURL = root.appendingPathComponent("Primuse/scan-checkpoints.json")
        func interruptedWalk() async throws -> (rows: [Song], state: SourceScanResumeState) {
            let scanner = ConnectorScanner(connector: connector, sourceID: source.id)
            var rows: [Song] = []
            var state: SourceScanResumeState?
            await connector.setFailing(["/Music/B"])
            let existing = library.songs.filter { $0.sourceID == source.id } + hiddenSegments(library)
            let updates = await scanner.scan(directories: ["/Music"], existingSongs: existing, identityIndex: referenceIndex)
            do {
                for try await update in updates {
                    rows.append(contentsOf: await scanner.takePendingChangedSongs())
                    if let resumeState = update.resumeState { state = resumeState }
                }
                XCTFail("the walk must stop at the failing folder")
            } catch {}
            rows.append(contentsOf: await scanner.takePendingChangedSongs())
            await connector.setFailing([])
            return (rows, try XCTUnwrap(state))
        }
        /// 把断点写到盘上,像重开 App 那样换一个 ScanService 读回来;返回它读到的断点。
        func relaunch(rows: [Song], state: SourceScanResumeState?) async throws -> ScanCheckpoint {
            await scan.waitForActiveScansToComplete()
            let scope = ScanService.scopeFingerprint(for: store.source(id: source.id) ?? source, directories: ["/Music"])
            try ScanCheckpointFileStore.writeSnapshot([source.id: ScanCheckpoint(
                phase: .scanning, intent: .fullScan, directories: ["/Music"], songs: rows,
                scannedSongCount: rows.count, totalCount: 0, currentFile: "",
                updatedAt: Date().addingTimeInterval(-3_600),
                scopeFingerprint: scope, directoryState: state
            )], to: checkpointURL)
            scan = makeScanService()
            await scan.whenStartupStateReady()
            return try XCTUnwrap(ScanCheckpointFileStore.load(from: checkpointURL)[source.id])
        }

        await connector.replaceListings([
            "/Music": [dir("/Music/A"), dir("/Music/B"), dir("/Music/C")],
            "/Music/A": [file("/Music/A/a1.flac", size: 3_000), file("/Music/A/a3.flac", size: 2_000), dir("/Music/A/NewDisc")],
            "/Music/A/NewDisc": [file("/Music/A/NewDisc/n1.flac")],
            "/Music/B": [file("/Music/B/b1.flac"), file("/Music/B/b2.flac"), file("/Music/B/a2.flac"),
                         file("/Music/B/b3.flac"), file("/Music/B/b4.flac")],
            "/Music/C": [file("/Music/C/c1.flac"), file("/Music/C/c2.flac")],
        ])
        var interrupted = try await interruptedWalk()
        XCTAssertEqual(Set(interrupted.rows.map(\.filePath)), ["/Music/A/a1.flac", "/Music/C/c1.flac", "/Music/C/c2.flac"])
        XCTAssertEqual(interrupted.state.pendingDirectories, ["/Music/B"])
        var checkpoint = try await relaunch(rows: interrupted.rows, state: interrupted.state)
        let listedBeforeResume = await connector.listedPaths.count
        // 续扫正列着 B 又被停掉:上一轮带回来的行这时还没随提交入库,得照样留在断点里。
        await connector.holdNextListing(of: "/Music/B")
        XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
        let holdDeadline = Date().addingTimeInterval(10)
        while await !connector.isHolding, Date() < holdDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let isHolding = await connector.isHolding
        XCTAssertTrue(isHolding)
        try await Task.sleep(for: .milliseconds(300))
        scan.cancelScan(for: source.id)
        await connector.releaseListing()
        await scan.waitForActiveScansToComplete()
        var rewritten: ScanCheckpoint?
        let rewriteDeadline = Date().addingTimeInterval(5)
        repeat {
            rewritten = ScanCheckpointFileStore.load(from: checkpointURL)[source.id]
            if let rewritten, rewritten.updatedAt > checkpoint.updatedAt { break }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < rewriteDeadline
        XCTAssertTrue(
            Set(try XCTUnwrap(rewritten).songs.map(\.filePath)).isSuperset(of: interrupted.rows.map(\.filePath)),
            "rows carried by the checkpoint stay in it until they are committed"
        )
        try await scanSubject("resumed with checkpoint rows")
        let listedByResume = await connector.listedPaths.dropFirst(listedBeforeResume)
        XCTAssertEqual(Array(listedByResume), ["/Music/B", "/Music/B"], "the resumed walks only list the unfinished folder")
        try await scanReference(resuming: checkpoint)
        assertSame("resumed with checkpoint rows")
        XCTAssertEqual(paths(library), ["/Music/A/a1.flac", "/Music/A/a3.flac", "/Music/A/NewDisc/n1.flac", "/Music/B/b1.flac",
                                        "/Music/B/b2.flac", "/Music/B/a2.flac", "/Music/B/b3.flac", "/Music/B/b4.flac",
                                        "/Music/C/c1.flac", "/Music/C/c2.flac"])
        XCTAssertEqual(library.songs.first { $0.filePath == "/Music/A/a1.flac" }?.fileSize, 3_000)

        // 断点里只有行、走查进度用不上(从头走):其中一首的文件在重开前没了,它不能被带回资料库。
        await connector.setListing("/Music/A", [file("/Music/A/a1.flac", size: 3_000), file("/Music/A/a3.flac", size: 2_000),
                                                file("/Music/A/a5.flac"), dir("/Music/A/NewDisc")])
        await connector.setListing("/Music/C", [file("/Music/C/c1.flac"), file("/Music/C/c2.flac"), file("/Music/C/c3.flac")])
        interrupted = try await interruptedWalk()
        XCTAssertEqual(Set(interrupted.rows.map(\.filePath)), ["/Music/A/a5.flac", "/Music/C/c3.flac"])
        await connector.setListing("/Music/A", [file("/Music/A/a1.flac", size: 3_000), file("/Music/A/a3.flac", size: 2_000),
                                                dir("/Music/A/NewDisc")])
        checkpoint = try await relaunch(rows: interrupted.rows, state: nil)
        try await scanSubject("resumed from the roots with a stale checkpoint row")
        try await scanReference(resuming: checkpoint)
        assertSame("resumed from the roots with a stale checkpoint row")
        XCTAssertFalse(paths(library).contains("/Music/A/a5.flac"))
        XCTAssertTrue(paths(library).contains("/Music/C/c3.flac"))

        try await scanBoth("unchanged rescan after the resumed scans")
    }

    /// 扫描途中别处给这个源加了一行(走查没遇到它):这一轮没有别的变化也照样提交,把它剪掉,
    /// 和原来拿整份快照比出「歌数不一样」时相同。没有这种事的重扫不提交。
    func testRowAddedDuringAnUnchangedWalkIsStillPruned() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileWalkCount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = MusicSource(id: "walk-\(UUID().uuidString)", name: "NAS", type: .webdav, extraConfig: "[\"/Music\"]")
        let tracks = ["/Music/t1.mp3", "/Music/t2.mp3"].map {
            RemoteFileItem(name: ($0 as NSString).lastPathComponent, path: $0, isDirectory: false, size: 1_000,
                           modifiedDate: Date(timeIntervalSince1970: 1_700_000_000))
        }
        let connector = FileWalkScenarioConnector(sourceID: source.id, listings: ["/Music": tracks])
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let manager = SourceManager(sourcesProvider: { [] })
        for shadow in [true, false] {
            let scan = ScanService(
                fileManager: FolderPlaylistTestFileManager(root: root), connectorProvider: { _ in connector },
                diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) }
            )
            scan.fileWalkCommitShadowOverride = shadow
            var completions: [SourceScanLifecycleCompletion] = []
            scan.successfulSourceScanHandler = { _, completion in completions.append(completion) }
            XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
            await scan.waitForActiveScansToComplete()
            XCTAssertEqual(Set(library.songs.map(\.filePath)), ["/Music/t1.mp3", "/Music/t2.mp3"])

            XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
            await scan.waitForActiveScansToComplete()
            XCTAssertEqual(completions.last, .committedNoChanges, "shadow=\(shadow)")

            await connector.holdNextListing(of: "/Music")
            XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
            let deadline = Date().addingTimeInterval(10)
            while await !connector.isHolding, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let isHolding = await connector.isHolding
            XCTAssertTrue(isHolding)
            let stray = Song(id: "stray-\(shadow)", title: "Stray", fileFormat: .mp3,
                             filePath: "/Music/stray.mp3", sourceID: source.id)
            library.addSongs([stray], affectedSourceIDs: [source.id], notifyRemovals: false, pruneMissingSongs: false)
            XCTAssertNotNil(library.storedSong(id: stray.id))
            await connector.releaseListing()
            await scan.waitForActiveScansToComplete()
            XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
            XCTAssertEqual(completions.last, .committedSnapshot, "shadow=\(shadow)")
            XCTAssertEqual(Set(library.songs.map(\.filePath)), ["/Music/t1.mp3", "/Music/t2.mp3"], "shadow=\(shadow)")
            if shadow {
                XCTAssertEqual(scan.lastFileWalkCommitShadowReports[source.id]?.mismatches, 0)
            }
        }
    }

    private struct SwitchableWalkFixture {
        let source: MusicSource
        let connector: SwitchableListingConnector
        let scan: ScanService
        let library: MusicLibrary
        let store: SourcesStore
        let manager: SourceManager

        @MainActor var songCount: Int { library.songs.filter { $0.sourceID == source.id }.count }

        @MainActor func scanOnce() async throws {
            let started = scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store)
            XCTAssertTrue(started)
            await scan.waitForActiveScansToComplete()
            await library.waitForPendingIndex()
            XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
        }
    }

    private func makeSwitchableWalkFixture(trackCount: Int) throws -> SwitchableWalkFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WalkConfirm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = MusicSource(id: "source", name: "NAS", type: .smb, extraConfig: "[\"/Music\"]")
        let connector = SwitchableListingConnector(trackCount: trackCount)
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let scan = ScanService(
            fileManager: FolderPlaylistTestFileManager(root: root), connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) }
        )
        return SwitchableWalkFixture(source: source, connector: connector, scan: scan,
                                     library: library, store: store, manager: SourceManager(sourcesProvider: { [] }))
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
    private(set) var listedPaths: [String] = []
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
        listedPaths.append(path)
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

/// `/Music` lists the first `trackCount` tracks; the count can change between scans.
private actor SwitchableListingConnector: MusicSourceConnector {
    let sourceID = "source"
    private var trackCount: Int

    init(trackCount: Int) { self.trackCount = trackCount }
    func setTrackCount(_ count: Int) { trackCount = count }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard path == "/Music" else { return [] }
        return (0..<trackCount).map {
            RemoteFileItem(name: "Track \($0).mp3", path: "/Music/Track \($0).mp3",
                           isDirectory: false, size: Int64(1_000 + $0), modifiedDate: nil)
        }
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

private actor FolderRescanTestConnector: MusicSourceConnector {
    let sourceID = "source"
    private var listings: [String: [RemoteFileItem]]
    private(set) var listedPaths: [String] = []

    init(listings: [String: [RemoteFileItem]]) { self.listings = listings }

    func replaceListings(_ listings: [String: [RemoteFileItem]]) {
        self.listings = listings
        listedPaths = []
    }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        listedPaths.append(path)
        guard let items = listings[path] else { throw SourceError.pathNotFound(path) }
        return items
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        .init { $0.finish() }
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }
}

/// 可以改的文件树:目录列表、文件内容(CUE)、列不出来的目录,以及把某个目录的下一次列表扣住。
private actor FileWalkScenarioConnector: MusicSourceConnector {
    nonisolated let sourceID: String
    private var listings: [String: [RemoteFileItem]]
    private let contents: [String: Data]
    private var failing: Set<String> = []
    private var heldPath: String?
    private(set) var isHolding = false
    private(set) var listedPaths: [String] = []

    init(sourceID: String, listings: [String: [RemoteFileItem]], contents: [String: Data] = [:]) {
        self.sourceID = sourceID
        self.listings = listings
        self.contents = contents
    }

    func replaceListings(_ listings: [String: [RemoteFileItem]]) { self.listings = listings }
    func setListing(_ path: String, _ items: [RemoteFileItem]) { listings[path] = items }
    func setFailing(_ paths: Set<String>) { failing = paths }
    func holdNextListing(of path: String) { heldPath = path }
    func releaseListing() { heldPath = nil }

    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        listedPaths.append(path)
        if heldPath == path {
            isHolding = true
            while heldPath == path { try await Task.sleep(for: .milliseconds(10)) }
            isHolding = false
        }
        if failing.contains(path) { throw HTTPResponseFailure(statusCode: 500) }
        guard let items = listings[path] else { throw SourceError.pathNotFound(path) }
        return items
    }
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard let data = contents[path] else { throw SourceError.fileNotFound(path) }
        return data
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        .init { $0.finish() }
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }
}

private actor RateLimitedListingTestConnector: MusicSourceConnector {
    let sourceID = "source"
    let listings: [String: [RemoteFileItem]]
    let failingPath: String
    let statusCode: Int
    private(set) var listedPaths: [String] = []

    init(listings: [String: [RemoteFileItem]], failingPath: String, statusCode: Int) {
        self.listings = listings; self.failingPath = failingPath; self.statusCode = statusCode
    }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        listedPaths.append(path)
        if path == failingPath {
            throw RemoteDirectoryHTTPStatusError(service: "WebDAV", statusCode: statusCode)
        }
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

@MainActor
final class PlaylistRenameTests: XCTestCase {
    func testRenameKeepsSongsAndRecordsANewSyncRevision() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimusePlaylistRename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let first = song("first")
        let second = song("second")
        library.addSongs([first, second], affectedSourceIDs: ["source"])
        await library.waitForPendingIndex()

        let playlist = library.createPlaylist(name: "Road Trip", songIDs: [second.id, first.id])
        let revisionBefore = try XCTUnwrap(library.playlist(id: playlist.id)?.syncRevision)

        XCTAssertTrue(library.renamePlaylist(id: playlist.id, to: "  Night Drive  "))

        let renamed = try XCTUnwrap(library.playlist(id: playlist.id))
        XCTAssertEqual(renamed.name, "Night Drive")
        XCTAssertGreaterThan(renamed.syncRevision, revisionBefore)
        XCTAssertEqual(library.songs(forPlaylist: playlist.id).map(\.id), [second.id, first.id])

        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The renamed playlist must finish persistence")
        }
        let restored = MusicLibrary(storageDirectory: directory)
        await restored.waitForPendingIndex()
        XCTAssertEqual(restored.playlist(id: playlist.id)?.name, "Night Drive")
    }

    func testRenameRejectsEmptyNamesAndPlaylistsThatAreNotTheUsers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimusePlaylistRename-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory)
        let track = song("track")
        library.addSongs([track], affectedSourceIDs: ["source"])
        await library.waitForPendingIndex()

        let playlist = library.createPlaylist(name: "Mine", songIDs: [track.id])
        XCTAssertFalse(library.renamePlaylist(id: playlist.id, to: "   "))
        XCTAssertEqual(library.playlist(id: playlist.id)?.name, "Mine")

        let mirrorID = ServerPlaylistIdentity.playlistID(sourceID: "source", serverPlaylistID: "42")
        let mirror = library.ensurePlaylist(id: mirrorID, name: "From Server")
        XCTAssertFalse(MusicLibrary.allowsRename(mirror))
        XCTAssertFalse(library.renamePlaylist(id: mirrorID, to: "Renamed"))
        XCTAssertEqual(library.playlist(id: mirrorID)?.name, "From Server")

        let nodeID = LibraryFolderNodeID(sourceID: "source", kind: .folder, normalizedRelativePath: "/music/live")
        let folder = library.createFolderPlaylist(name: "Live", nodeID: nodeID, cloudAccountID: nil, songIDs: [track.id])
        XCTAssertFalse(library.renamePlaylist(id: folder.id, to: "Renamed"))
        XCTAssertEqual(library.playlist(id: folder.id)?.name, "Live")
    }

    private func song(_ id: String) -> Song {
        Song(id: id, title: id, fileFormat: .flac, filePath: "/Music/\(id).flac", sourceID: "source")
    }
}
