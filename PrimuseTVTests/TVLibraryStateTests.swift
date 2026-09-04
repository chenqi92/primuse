#if os(tvOS)
import CryptoKit
import Foundation
import PrimuseKit
import XCTest
@testable import PrimuseTV

@MainActor
final class TVLibraryStateTests: XCTestCase {
    @MainActor
    private final class RecoveryProbe {
        var unavailable = true
    }
    private struct EmptyDirectoryLister: TVDirectoryLister {
        func list(_ path: String) async throws -> [TVDirEntry] { [] }
    }

    private actor CommitGate {
        private(set) var entered = false
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }

    private actor PausedDirectoryLister: TVDirectoryLister {
        private(set) var reachedChild = false

        func list(_ path: String) async throws -> [TVDirEntry] {
            if path == "/" {
                return (0..<25).map {
                    TVDirEntry(name: "song-\($0).mp3", isDir: false, size: 1_000,
                               path: "/song-\($0).mp3")
                } + [TVDirEntry(name: "child", isDir: true, size: 0, path: "/child")]
            }
            reachedChild = true
            try await Task.sleep(for: .seconds(30))
            return []
        }
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let defaults: UserDefaults
        let defaultsName: String
        let sources: SourcesStore
        let library: MusicLibrary
        let source: MusicSource

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("TVLibraryStateTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defaultsName = "TVLibraryStateTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: defaultsName)!
            sources = SourcesStore(storageDirectoryURL: directory)
            library = MusicLibrary(storageDirectory: directory)
            source = MusicSource(id: UUID().uuidString, name: "Fixture", type: .local)
            try sources.addDurably(source)
        }

        func song(_ id: String) -> Song {
            Song(id: id, title: "Track \(id)", fileFormat: .mp3,
                 filePath: "/Music/\(id).mp3", sourceID: source.id)
        }

        func store(scanPersistence: @escaping @MainActor @Sendable (MusicLibrary) async -> Result<Void, AppleTVTransferFailure> = {
            await $0.persistNowAndWait()
        }) -> TVStore {
            TVStore(sourcesStore: sources, library: library, defaults: defaults,
                    sessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
                    scanPersistence: scanPersistence)
        }

        func payload(songs: [Song], sources: [MusicSource]? = nil) throws -> LANSyncPayload {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let rows = try JSONSerialization.jsonObject(with: encoder.encode(songs))
            let snapshot = try JSONSerialization.data(withJSONObject: ["songs": rows, "playlists": []])
            return LANSyncPayload(
                libraryGz: LibrarySnapshotSync.gzip(snapshot),
                sourcesGz: LibrarySnapshotSync.gzip(try encoder.encode(sources ?? [source])),
                credentials: CredentialBundle()
            )
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: defaultsName)
            // SQLite handles can outlive the test's lexical scope because
            // derived-cache writes are asynchronous; let the sandbox reap tmp.
        }
    }

    func testLikesSurviveLibraryRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("liked")])
        _ = await fixture.library.persistNowAndWait()
        let store = fixture.store()
        store.reload()
        store.toggleLiked("liked")
        _ = await fixture.library.persistNowAndWait()

        let restarted = MusicLibrary(storageDirectory: fixture.directory)
        XCTAssertTrue(restarted.isLiked(songID: "liked"))
        XCTAssertTrue(store.normalPlaylists.contains { $0.kind == .liked && $0.count == 1 })
    }

    func testLocalSourceRemovalRetainsSharedRecordAndRestoresSongs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("kept")])
        _ = await fixture.library.persistNowAndWait()
        let store = fixture.store()
        store.reload()
        store.deleteSource(fixture.source.id)

        XCTAssertEqual(fixture.sources.source(id: fixture.source.id)?.isDeleted, false)
        XCTAssertNotNil(fixture.library.song(id: "kept"))
        XCTAssertNil(store.song("kept"))
        let restarted = fixture.store()
        restarted.reload()
        XCTAssertFalse(restarted.sources.contains { $0.id == fixture.source.id })
        restarted.restoreSource(fixture.source.id)
        await fixture.library.waitForPendingIndex()
        XCTAssertNotNil(restarted.song("kept"))
    }

    func testNormalReloadKeepsCanonicalIncrementalSongs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("old")])
        _ = await fixture.library.persistNowAndWait()
        fixture.library.addSongs([fixture.song("new")], pruneMissingSongs: false)
        _ = await fixture.library.persistIncrementalNowAndWait()

        let store = fixture.store()
        store.reload()
        XCTAssertEqual(Set(store.songs.map(\.id)), ["old", "new"])
    }

    func testPublishedIndexRefreshesTVWithoutManualReload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        store.reload()
        fixture.library.addSongs([fixture.song("first")], pruneMissingSongs: false)
        await fixture.library.waitForPendingIndex()
        for _ in 0..<100 where store.song("first") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.song("first"))

        fixture.library.addSongs([fixture.song("second")], pruneMissingSongs: false)
        await fixture.library.waitForPendingIndex()
        for _ in 0..<100 where store.song("second") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Set(store.songs.map(\.id)), ["first", "second"])
        _ = await fixture.library.persistNowAndWait()
    }

    func testScannerPublishesBeforeEnumerationFinishesAndCancellationDoesNotPrune() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("previously-scanned")])
        _ = await fixture.library.persistNowAndWait()
        let store = fixture.store()
        store.reload()
        let lister = PausedDirectoryLister()
        let scan = Task { await store.runScan(source: fixture.source, lister: lister, dirs: ["/"]) }
        let deadline = Date().addingTimeInterval(8)
        while !(await lister.reachedChild), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reachedChild = await lister.reachedChild
        XCTAssertTrue(reachedChild)
        XCTAssertGreaterThanOrEqual(store.songs.count, 21)
        XCTAssertEqual(store.scanner.phase, .scanning)
        let firstID = TVScanPipelinePolicy.songID(sourceID: fixture.source.id, path: "/song-0.mp3")
        XCTAssertNotNil(store.song(firstID))
        let restartWhileScanning = MusicLibrary(storageDirectory: fixture.directory)
        XCTAssertNotNil(restartWhileScanning.song(id: firstID))
        store.cancelScan(sourceID: fixture.source.id)
        _ = await scan.value
        XCTAssertNotEqual(store.scanner.phase, .done)
        XCTAssertNotNil(fixture.library.song(id: "previously-scanned"))
        XCTAssertEqual(store.songs.count, 26)
        XCTAssertNil(fixture.sources.source(id: fixture.source.id)?.lastScannedAt)
        _ = await fixture.library.persistNowAndWait()
    }

    func testSourceChangeDuringFinalPersistenceCannotMarkScanComplete() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let gate = CommitGate()
        let store = fixture.store { library in
            await gate.wait()
            return await library.persistNowAndWait()
        }
        store.reload()
        let scan = Task {
            await store.runScan(source: fixture.source, lister: EmptyDirectoryLister(), dirs: ["/"])
        }
        let deadline = Date().addingTimeInterval(8)
        while !(await gate.entered), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let entered = await gate.entered
        XCTAssertTrue(entered)
        try fixture.sources.updateLocalDurably(fixture.source.id) { $0.host = "changed.example.invalid" }
        await gate.release()
        _ = await scan.value
        XCTAssertNil(fixture.sources.source(id: fixture.source.id)?.lastScannedAt)
        XCTAssertEqual(store.scanner.phase, .idle)
        XCTAssertNil(store.activeScanSourceID)
    }

    func testCompletedCheckpointWithinPersistedSecondCannotSkipFutureFiles() {
        let scanned = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(TVStore.canResumeScanCheckpoint(
            lastScannedAt: scanned, checkpointModifiedAt: scanned.addingTimeInterval(0.75)))
        XCTAssertTrue(TVStore.canResumeScanCheckpoint(
            lastScannedAt: scanned, checkpointModifiedAt: scanned.addingTimeInterval(2)))
        XCTAssertFalse(TVStore.canResumeScanCheckpoint(lastScannedAt: nil, checkpointModifiedAt: nil))
    }

    func testCancelDuringFinalPruningRestoresOldSongAndLikesDurably() async throws {
        try await assertFinalPruningRollback(changesAuthentication: false)
    }

    func testAuthenticationChangeDuringFinalPruningRestoresOldSongAndLikesDurably() async throws {
        try await assertFinalPruningRollback(changesAuthentication: true)
    }

    private func assertFinalPruningRollback(changesAuthentication: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("old-liked")])
        fixture.library.toggleLiked(songID: "old-liked")
        _ = await fixture.library.persistNowAndWait()
        let gate = CommitGate()
        let store = fixture.store { library in
            await gate.wait()
            return await library.persistNowAndWait()
        }
        store.reload()
        let scan = Task {
            await store.runScan(source: fixture.source, lister: EmptyDirectoryLister(), dirs: ["/"])
        }
        let deadline = Date().addingTimeInterval(8)
        while !(await gate.entered), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let entered = await gate.entered
        XCTAssertTrue(entered)
        if changesAuthentication {
            try fixture.sources.updateLocalDurably(fixture.source.id) { $0.username = "another-user" }
        } else {
            store.cancelScan(sourceID: fixture.source.id)
        }
        await gate.release()
        _ = await scan.value
        XCTAssertEqual(store.scanner.phase, .idle)
        XCTAssertNil(fixture.sources.source(id: fixture.source.id)?.lastScannedAt)
        XCTAssertNotNil(fixture.library.song(id: "old-liked"))
        XCTAssertTrue(fixture.library.isLiked(songID: "old-liked"))
        let restarted = MusicLibrary(storageDirectory: fixture.directory)
        XCTAssertNotNil(restarted.song(id: "old-liked"))
        XCTAssertTrue(restarted.isLiked(songID: "old-liked"))
    }

    func testFailedFinalPruningRestoresOldSongAndLikesDurably() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("old-liked")])
        fixture.library.toggleLiked(songID: "old-liked")
        _ = await fixture.library.persistNowAndWait()
        let store = fixture.store { _ in .failure(.snapshotPreparationFailed) }
        store.reload()
        _ = await store.runScan(source: fixture.source, lister: EmptyDirectoryLister(), dirs: ["/"])
        XCTAssertNotEqual(store.scanner.phase, .done)
        XCTAssertNil(fixture.sources.source(id: fixture.source.id)?.lastScannedAt)
        let restarted = MusicLibrary(storageDirectory: fixture.directory)
        XCTAssertNotNil(restarted.song(id: "old-liked"))
        XCTAssertTrue(restarted.isLiked(songID: "old-liked"))
    }

    func testRecoveryFailureBlocksMutationsUntilRecoverySucceeds() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("kept")])
        _ = await fixture.library.persistNowAndWait()
        let probe = RecoveryProbe()
        let store = TVStore(
            sourcesStore: fixture.sources, library: fixture.library, defaults: fixture.defaults,
            sessionStore: PlaybackSessionStore(url: fixture.directory.appendingPathComponent("session.json")),
            snapshotRecovery: {
                if probe.unavailable { throw CocoaError(.fileReadUnknown) }
                return false
            }
        )
        let firstRecovery = await store.retryPendingSnapshotImport()
        XCTAssertFalse(firstRecovery)
        store.toggleLiked("kept")
        store.setSourceEnabled(fixture.source.id, false)
        XCTAssertFalse(fixture.library.isLiked(songID: "kept"))
        XCTAssertEqual(fixture.sources.source(id: fixture.source.id)?.isEnabled, true)
        let otpResult = await store.login2FA(sourceID: fixture.source.id, otp: "000000")
        XCTAssertEqual(otpResult, PMString("ext.tv.persistence.failed"))
        XCTAssertFalse(store.saveManualCredential(sourceID: fixture.source.id, username: "test", password: "test"))
        let admitted = await store.runScan(source: fixture.source, lister: EmptyDirectoryLister(), dirs: ["/"])
        XCTAssertFalse(admitted)
        probe.unavailable = false
        let recovered = await store.retryPendingSnapshotImport()
        XCTAssertTrue(recovered)
        store.toggleLiked("kept")
        _ = await fixture.library.persistNowAndWait()
        XCTAssertTrue(MusicLibrary(storageDirectory: fixture.directory).isLiked(songID: "kept"))
    }

    func testDegradedSourcesCannotBecomeValidSnapshotBaseline() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let url = fixture.directory.appendingPathComponent("sources.json")
        let damaged = Data("not-valid-json".utf8)
        try damaged.write(to: url, options: .atomic)
        let degraded = SourcesStore(storageDirectoryURL: fixture.directory)
        XCTAssertFalse(degraded.hasCompleteSnapshot)
        XCTAssertThrowsError(try degraded.validatedSourcesForSnapshot())
        XCTAssertThrowsError(try degraded.addDurably(fixture.source))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        let store = TVStore(sourcesStore: degraded, library: fixture.library, defaults: fixture.defaults,
                            sessionStore: PlaybackSessionStore(url: fixture.directory.appendingPathComponent("session.json")))
        let installed = await store.applyLANPayload(try fixture.payload(songs: []))
        XCTAssertFalse(installed)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testLegacyIdentityMigrationPreservesLikes() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var legacy = fixture.song("legacy")
        legacy.id = SHA256.hash(data: Data("\(legacy.sourceID):\(legacy.filePath)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        fixture.library.addSongs([legacy])
        fixture.library.toggleLiked(songID: legacy.id)
        _ = await fixture.library.persistNowAndWait()
        let store = fixture.store()
        store.reload()
        let canonical = String(legacy.id.prefix(32))
        XCTAssertNotNil(store.song(canonical))
        XCTAssertNil(store.song(legacy.id))
        XCTAssertTrue(store.isLiked(canonical))
        _ = await fixture.library.persistNowAndWait()
        let restarted = MusicLibrary(storageDirectory: fixture.directory)
        XCTAssertNotNil(restarted.song(id: canonical))
        XCTAssertTrue(restarted.isLiked(songID: canonical))
    }

    func testSnapshotFailureRollsBackLibrarySourcesAndCredentialReferenceTogether() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("old")])
        _ = await fixture.library.persistNowAndWait()
        let libraryURL = fixture.directory.appendingPathComponent("library-cache.json")
        let sourcesURL = fixture.directory.appendingPathComponent("sources.json")
        let referenceURL = fixture.directory.appendingPathComponent("paired-credential-reference.json")
        let oldLibrary = try Data(contentsOf: libraryURL)
        let oldSources = try Data(contentsOf: sourcesURL)
        let oldReference = try JSONEncoder().encode(UUID())
        try oldReference.write(to: referenceURL, options: .atomic)
        var writes = 0
        XCTAssertFalse(LibrarySnapshotSync.shared.installTVPayload(
            try fixture.payload(songs: [fixture.song("incoming")]),
            credentialReference: try JSONEncoder().encode(UUID()),
            destinationDirectory: fixture.directory,
            fileWriter: { data, url in
                writes += 1
                if writes == 3 { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            }
        ))
        XCTAssertEqual(try Data(contentsOf: libraryURL), oldLibrary)
        XCTAssertEqual(try Data(contentsOf: sourcesURL), oldSources)
        XCTAssertEqual(try Data(contentsOf: referenceURL), oldReference)
        XCTAssertFalse(try LibrarySnapshotSync.recoverTVSnapshot(directory: fixture.directory))
    }

    func testCommittedSnapshotRecoversBeforeSQLiteImportAndRetainsLocalSongs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let local = fixture.song("tv-only")
        fixture.library.addSongs([local])
        _ = await fixture.library.persistNowAndWait()
        XCTAssertTrue(LibrarySnapshotSync.shared.installTVPayload(
            try fixture.payload(songs: [fixture.song("incoming")]), credentialReference: nil,
            preservingSongs: [local], destinationDirectory: fixture.directory
        ))
        XCTAssertTrue(try LibrarySnapshotSync.recoverTVSnapshot(directory: fixture.directory))
        let recovered = MusicLibrary(storageDirectory: fixture.directory, preferExternalSnapshot: true)
        XCTAssertEqual(Set(recovered.songs.map(\.id)), ["incoming", "tv-only"])
        _ = await recovered.persistNowAndWait()
        try LibrarySnapshotSync.finishTVSnapshotImport(directory: fixture.directory)
        let restarted = MusicLibrary(storageDirectory: fixture.directory)
        XCTAssertEqual(Set(restarted.songs.map(\.id)), ["incoming", "tv-only"])
        XCTAssertFalse(try LibrarySnapshotSync.recoverTVSnapshot(directory: fixture.directory))
    }

    func testIncompleteSnapshotCannotReplaceExistingLibrary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("kept")])
        _ = await fixture.library.persistNowAndWait()
        let libraryURL = fixture.directory.appendingPathComponent("library-cache.json")
        let before = try Data(contentsOf: libraryURL)
        var payload = try fixture.payload(songs: [fixture.song("incoming")])
        payload.sourcesGz = nil
        XCTAssertFalse(LibrarySnapshotSync.shared.installTVPayload(
            payload, credentialReference: nil, destinationDirectory: fixture.directory
        ))
        XCTAssertEqual(try Data(contentsOf: libraryURL), before)
    }

    func testSnapshotPreservesLocalLikedMembership() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let track = fixture.song("liked-on-tv")
        fixture.library.addSongs([track])
        fixture.library.toggleLiked(songID: track.id)
        _ = await fixture.library.persistNowAndWait()
        XCTAssertTrue(LibrarySnapshotSync.shared.installTVPayload(
            try fixture.payload(songs: [track]), credentialReference: nil,
            destinationDirectory: fixture.directory
        ))
        let imported = MusicLibrary(storageDirectory: fixture.directory, preferExternalSnapshot: true)
        XCTAssertTrue(imported.isLiked(songID: track.id))
        _ = await imported.persistNowAndWait()
        try LibrarySnapshotSync.finishTVSnapshotImport(directory: fixture.directory)
    }

    func testSQLiteImportFailureIsNotReportedAsPersistenceSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("old")])
        _ = await fixture.library.persistNowAndWait()
        XCTAssertTrue(LibrarySnapshotSync.shared.installTVPayload(
            try fixture.payload(songs: [fixture.song("incoming")]), credentialReference: nil,
            destinationDirectory: fixture.directory
        ))
        let failing = MusicLibrary(
            storageDirectory: fixture.directory, preferExternalSnapshot: true,
            songStoreSnapshotWriter: { _, _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        )
        if case .success = await failing.persistNowAndWait() { XCTFail("Failed SQLite import must not acknowledge persistence") }
        let database = try IncrementalSongStore(path: fixture.directory.appendingPathComponent("library-songs.sqlite").path)
        XCTAssertEqual(Set(try database.loadSongs().map(\.id)), ["old"])
        XCTAssertTrue(try LibrarySnapshotSync.recoverTVSnapshot(directory: fixture.directory))
        let recovered = MusicLibrary(storageDirectory: fixture.directory, preferExternalSnapshot: true)
        _ = await recovered.persistNowAndWait()
        XCTAssertEqual(Set(try database.loadSongs().map(\.id)), ["incoming"])
        XCTAssertFalse(try LibrarySnapshotSync.recoverTVSnapshot(directory: fixture.directory))
    }

    func testAlreadyImportedMarkerCannotOverwriteSubsequentChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("old")])
        _ = await fixture.library.persistNowAndWait()
        XCTAssertTrue(LibrarySnapshotSync.shared.installTVPayload(
            try fixture.payload(songs: [fixture.song("incoming")]), credentialReference: nil,
            destinationDirectory: fixture.directory
        ))
        let imported = MusicLibrary(storageDirectory: fixture.directory, preferExternalSnapshot: true)
        _ = await imported.persistNowAndWait()
        // Leave the pending file behind, as after an interrupted/failed unlink.
        imported.addSongs([fixture.song("later")], pruneMissingSongs: false)
        imported.toggleLiked(songID: "later")
        _ = await imported.persistNowAndWait()
        XCTAssertFalse(try LibrarySnapshotSync.recoverTVSnapshot(directory: fixture.directory))
        let restarted = MusicLibrary(storageDirectory: fixture.directory)
        XCTAssertEqual(Set(restarted.songs.map(\.id)), ["incoming", "later"])
        XCTAssertTrue(restarted.isLiked(songID: "later"))
    }

    func testCorruptLocalSourcesFailClosedWithoutErasingSongs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("kept")])
        _ = await fixture.library.persistNowAndWait()
        let libraryURL = fixture.directory.appendingPathComponent("library-cache.json")
        let before = try Data(contentsOf: libraryURL)
        let sourcesURL = fixture.directory.appendingPathComponent("sources.json")
        try Data("invalid-json".utf8).write(to: sourcesURL, options: .atomic)
        XCTAssertFalse(LibrarySnapshotSync.shared.installTVPayload(
            try fixture.payload(songs: [fixture.song("incoming")]), credentialReference: nil,
            destinationDirectory: fixture.directory
        ))
        XCTAssertEqual(try Data(contentsOf: libraryURL), before)
        XCTAssertEqual(try Data(contentsOf: sourcesURL), Data("invalid-json".utf8))
    }

    func testTurningShuffleOffRestoresCanonicalDuplicateOccurrence() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("a"), fixture.song("b"), fixture.song("c")])
        _ = await fixture.library.persistNowAndWait()
        let snapshot = PlaybackSessionSnapshot(
            queueSongIDs: ["a", "b", "a", "c"], currentSongID: "a", currentIndex: 2,
            currentTime: 40, duration: 200, wasPlaying: false, shuffleEnabled: true,
            shuffledIndices: [1, 2, 3, 0], shufflePosition: 1, repeatMode: .off,
            isAtTrackEnd: false
        )
        try PlaybackSessionStore(url: fixture.directory.appendingPathComponent("session.json")).save(snapshot)
        let store = fixture.store()
        store.reload()
        XCTAssertEqual(store.queueSongIDs, ["b", "a", "c", "a"])
        store.toggleShuffle()
        XCTAssertEqual(store.queueSongIDs, ["a", "b", "a", "c"])
        XCTAssertEqual(store.queueUpNextIDs, ["c"])
        await store.persistForLifecycle()
    }
}
#endif
