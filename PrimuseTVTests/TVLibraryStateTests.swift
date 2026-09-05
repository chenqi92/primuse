#if os(tvOS)
import CryptoKit
import Foundation
import PrimuseKit
import XCTest
import UIKit
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

    private func artworkStore(_ fixture: Fixture, name: String) -> MetadataAssetStore {
        MetadataAssetStore(storageDirectory: fixture.directory.appendingPathComponent(name))
    }

    private func artworkSnapshot(_ songs: [Song]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.data(withJSONObject: [
            "songs": JSONSerialization.jsonObject(with: encoder.encode(songs)),
            "playlists": []
        ])
    }

    private func artworkImage() throws -> Data {
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData())
    }

    func testPortableArtworkRestoresSongAndAlbumCoversWithContentDeduplication() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sender = artworkStore(fixture, name: "sender")
        let receiver = artworkStore(fixture, name: "receiver")
        var first = fixture.song("first")
        first.albumID = "album"
        var second = fixture.song("second")
        second.albumID = "album"
        let original = try artworkImage()
        sender.storeCoverSync(original, for: first.id)
        sender.storeCoverSync(original, for: second.id)
        _ = await sender.storeAlbumCover(original, forAlbumID: "album")
        let transfer = try XCTUnwrap(MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(
            artworkSnapshot([first, second]), assetStore: sender
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: transfer.data) as? [String: Any])
        XCTAssertEqual((object["cachedArtworkAssets"] as? [String: String])?.count, 1)
        XCTAssertEqual((object["artworkCacheReferences"] as? [String: String])?.count, 3)
        MusicLibrary.restorePortableArtworkAssets(from: transfer.data, assetStore: receiver)
        let firstCover = try XCTUnwrap(receiver.readCoverData(named: receiver.expectedCoverFileName(for: first.id)))
        XCTAssertNotNil(UIImage(data: firstCover))
        XCTAssertEqual(firstCover, receiver.readCoverData(named: receiver.expectedCoverFileName(for: second.id)))
        let albumCover = await receiver.cachedAlbumCover(forAlbumID: "album")
        XCTAssertEqual(firstCover, albumCover)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: receiver.customArtworkDirectoryURL.path).isEmpty)
    }

    func testPortableArtworkFiltersDeviceLocalCoversBeforeCloudExport() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sender = artworkStore(fixture, name: "sender")
        let local = fixture.song("local-only")
        let remoteSource = MusicSource(id: "remote", name: "Remote", type: .smb)
        var remote = fixture.song("remote-song")
        remote.sourceID = remoteSource.id
        sender.storeCoverSync(try artworkImage(), for: local.id)
        let transfer = try XCTUnwrap(MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(
            artworkSnapshot([local, remote]), cloudSources: [fixture.source, remoteSource], assetStore: sender
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: transfer.data) as? [String: Any])
        XCTAssertEqual((object["songs"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, [remote.id])
        XCTAssertNil(object["cachedArtworkAssets"])
        XCTAssertNil(object["artworkCacheReferences"])
    }

    func testPortableArtworkBudgetDoesNotDiscardLibraryMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let sender = artworkStore(fixture, name: "sender")
        let song = fixture.song("budget")
        sender.storeCoverSync(try artworkImage(), for: song.id)
        let transfer = try XCTUnwrap(MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(
            artworkSnapshot([song]), assetStore: sender, maximumArtworkBytes: 0
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: transfer.data) as? [String: Any])
        XCTAssertEqual((object["songs"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(object["cachedArtworkAssets"])
        XCTAssertLessThan(transfer.data.count, 60 * 1024 * 1024)
    }

    func testPortableArtworkRejectsCorruptContentAndUnrelatedReferences() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let receiver = artworkStore(fixture, name: "receiver")
        let song = fixture.song("valid")
        let data = try artworkImage()
        let contentID = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: artworkSnapshot([song])) as? [String: Any])
        let name = receiver.expectedCoverFileName(for: song.id)
        let otherName = receiver.expectedCoverFileName(for: "unrelated")
        snapshot["artworkCacheReferences"] = [name: contentID, otherName: contentID, "../escape.jpg": contentID]
        snapshot["cachedArtworkAssets"] = [contentID: Data("invalid".utf8).base64EncodedString()]
        MusicLibrary.restorePortableArtworkAssets(from: try JSONSerialization.data(withJSONObject: snapshot), assetStore: receiver)
        XCTAssertNil(receiver.readCoverData(named: name))
        snapshot["cachedArtworkAssets"] = [contentID: data.base64EncodedString()]
        MusicLibrary.restorePortableArtworkAssets(from: try JSONSerialization.data(withJSONObject: snapshot), assetStore: receiver)
        XCTAssertEqual(receiver.readCoverData(named: name), data)
        XCTAssertNil(receiver.readCoverData(named: otherName))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiver.artworkDirectoryURL.deletingLastPathComponent().appendingPathComponent("escape.jpg").path))
    }

    func testAlbumArtworkPrefersSongWithSourceCoverReference() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var withoutCover = fixture.song("first-track")
        withoutCover.albumTitle = "Artwork Album"
        withoutCover.artistName = "Artwork Artist"
        var withCover = fixture.song("source-cover")
        withCover.albumTitle = "Artwork Album"
        withCover.artistName = "Artwork Artist"
        withCover.coverArtFileName = "https://example.com/album.jpg"
        fixture.library.addSongs([withoutCover, withCover])
        await fixture.library.waitForPendingIndex()
        let albumID = try XCTUnwrap(fixture.library.song(id: withCover.id)?.albumID)
        XCTAssertEqual(fixture.library.preferredArtworkSong(forAlbumID: albumID)?.id, withCover.id)
    }

    func testPreviousTrackShortcutSkipsEvenAfterPlaybackHasAdvanced() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.library.addSongs([fixture.song("first"), fixture.song("second")])
        await fixture.library.waitForPendingIndex()
        let store = fixture.store()
        store.reload()
        let first = try XCTUnwrap(store.song("first"))
        let second = try XCTUnwrap(store.song("second"))
        store.play(second)
        store.engine.prepareForSelection(startAt: 20)
        XCTAssertEqual(store.currentTime, 20)
        store.previous(restartCurrentIfNeeded: false)
        XCTAssertEqual(store.nowPlaying.songID, first.id)
        store.engine.stop()
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

    func testPlaybackRecordAppearsInTVRecentlyPlayedInNewestOrder() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        store.reload()
        let songs = [fixture.song("first"), fixture.song("second")]
        fixture.library.addSongs(songs, pruneMissingSongs: false)
        await fixture.library.waitForPendingIndex()
        for _ in 0..<100 where store.song("first") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.song("first"))

        let historyChange = expectation(description: "TV observes recent playback change")
        withObservationTracking {
            _ = store.recentlyPlayed.map(\.id)
        } onChange: {
            historyChange.fulfill()
        }

        fixture.library.recordPlayback(of: "first")
        fixture.library.recordPlayback(of: "second")

        await fulfillment(of: [historyChange], timeout: 1)
        XCTAssertEqual(fixture.library.recentlyPlayedSongs(limit: 2).map(\.id), ["second", "first"])
        XCTAssertEqual(store.recentlyPlayed.map(\.id), ["second", "first"])
    }

    func testSyntheticOwnedWAVPlaybackRecordsRecentlyPlayed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let source = MusicSource(
            id: TVLocalTransferSource.sourceID,
            name: "Synthetic playback",
            type: .local,
            basePath: TVLocalTransferSource.root.path,
            extraConfig: MusicSource.encodeScannedDirectories(["/"], into: nil, type: .local)
        )
        try fixture.sources.addDurably(source)
        let fileName = "TVLibraryStateTests-\(UUID().uuidString).wav"
        let fileURL = TVLocalTransferSource.root.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(
            at: TVLocalTransferSource.root,
            withIntermediateDirectories: true
        )
        try waveFixture(duration: 2).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var song = fixture.song("synthetic-playback")
        song.sourceID = source.id
        song.filePath = "/\(fileName)"
        song.fileFormat = .wav
        let fileValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        song.fileSize = Int64(fileValues.fileSize ?? 0)
        let store = fixture.store()
        store.reload()
        fixture.library.addSongs([song], pruneMissingSongs: false)
        await fixture.library.waitForPendingIndex()
        for _ in 0..<100 where store.song(song.id) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.song(song.id))
        XCTAssertTrue(store.playResolvedQueue(songIDs: [song.id], shuffled: false))

        let deadline = Date().addingTimeInterval(8)
        var reachedPlaybackProgress = false
        while Date() < deadline {
            if store.engine.currentTime > 0 {
                reachedPlaybackProgress = true
                break
            }
            if case .failed(let message) = store.engine.status {
                XCTFail("Synthetic WAV playback failed: \(message)")
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(reachedPlaybackProgress)
        while fixture.library.recentlyPlayedSongs(limit: 1).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(fixture.library.recentlyPlayedSongs(limit: 1).map(\.id), [song.id])
        XCTAssertEqual(store.recentlyPlayed.map(\.id), [song.id])
        store.engine.stop()
    }

    func testToggleLikedWithTenThousandSongsRecordsSynchronousRefreshCost() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        store.reload()
        let songs = (0..<10_000).map { index -> Song in
            var song = fixture.song("bulk-\(index)")
            song.filePath = "/Music/bulk-\(index).mp3"
            return song
        }
        fixture.library.addSongs(songs, pruneMissingSongs: false)
        await fixture.library.waitForPendingIndex()
        let deadline = Date().addingTimeInterval(5)
        while store.songs.count != songs.count, Date() < deadline {
            await Task.yield()
        }
        XCTAssertEqual(store.songs.count, songs.count)

        let likedIDs = (0..<5_000).map { "bulk-\($0)" }
        let revisionAfterLoad = store.recommendationRevision
        fixture.library.replaceLikedSongs(
            fromSourceID: fixture.source.id,
            with: likedIDs
        )
        for _ in 0..<500 where store.recommendationRevision == revisionAfterLoad {
            await Task.yield()
        }
        XCTAssertEqual(likedIDs.count, fixture.library.rawSongIDs(forPlaylist: MusicLibrary.likedSongsPlaylistID).count)

        let revisionBefore = store.recommendationRevision
        let clock = ContinuousClock()
        let start = clock.now
        store.toggleLiked("bulk-5000")
        let elapsed = start.duration(to: clock.now)
        let synchronousRevisionDelta = store.recommendationRevision - revisionBefore

        var eventualRevision = store.recommendationRevision
        for _ in 0..<100 {
            await Task.yield()
            eventualRevision = max(eventualRevision, store.recommendationRevision)
        }
        let eventualRevisionDelta = eventualRevision - revisionBefore
        print("TV 10K toggleLiked elapsed=\(elapsed), synchronousRevisionDelta=\(synchronousRevisionDelta), eventualRevisionDelta=\(eventualRevisionDelta)")

        XCTAssertTrue(store.isLiked("bulk-5000"))
        XCTAssertGreaterThanOrEqual(synchronousRevisionDelta, 1)
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

    func testReceivedMusicOwnershipIsLimitedToThisTVContainer() throws {
        let sourceID = TVLocalTransferSource.sourceID
        let currentRoot = TVLocalTransferSource.root.standardizedFileURL.path
        let owned = MusicSource(id: sourceID, name: "Received", type: .local, basePath: currentRoot)
        XCTAssertTrue(TVLocalTransferSource.isOwned(owned))
        XCTAssertNotNil(TVPlaybackCoordinator.makeDirectReader(
            source: owned, filePath: "/Album/song.mp3", credential: nil
        ))

        var components = currentRoot.split(separator: "/").map(String.init)
        XCTAssertGreaterThanOrEqual(components.count, 5)
        components[components.count - 5] = "84A53263-830F-49AF-8B0F-6F0442C8F9D1"
        let migratedRoot = "/" + components.joined(separator: "/")
        var migrated = owned
        migrated.basePath = migratedRoot
        XCTAssertTrue(TVLocalTransferSource.isOwned(migrated))

        var foreign = owned
        foreign.id = "phone-local-source"
        foreign.basePath = "/private/var/mobile/Containers/Data/Application/31F463AE-70DC-4B0D-8162-A21A391C4520/Documents/LocalMusic"
        XCTAssertFalse(TVLocalTransferSource.isOwned(foreign))
        XCTAssertNil(TVPlaybackCoordinator.makeDirectReader(
            source: foreign, filePath: "/Album/song.mp3", credential: nil
        ))

        var wrongID = owned
        wrongID.id = UUID().uuidString
        XCTAssertFalse(TVLocalTransferSource.isOwned(wrongID))
        var subdirectory = owned
        subdirectory.basePath = currentRoot + "/Album"
        XCTAssertFalse(TVLocalTransferSource.isOwned(subdirectory))
        var wrongType = owned
        wrongType.type = .smb
        XCTAssertFalse(TVLocalTransferSource.isOwned(wrongType))
    }

    func testReceivedMusicAdaptersListAndReadOnlyInsideManagedRoot() async throws {
        let folderName = "TV Transfer QA \(UUID().uuidString)"
        let folder = TVLocalTransferSource.root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data((0..<128).map(UInt8.init))
        let audio = folder.appendingPathComponent("Live & 中文.mp3")
        try bytes.write(to: audio)
        try Data([7]).write(to: folder.appendingPathComponent(".hidden.mp3"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("linked.mp3"), withDestinationURL: audio
        )

        let lister = TVLocalDirectoryLister()
        let rootEntries = try await lister.list("/")
        XCTAssertTrue(rootEntries.contains { $0.isDir && $0.path == "/\(folderName)" })
        let entries = try await lister.list("/\(folderName)")
        XCTAssertEqual(entries.map(\.name), ["Live & 中文.mp3"])

        let reader = TVLocalByteRangeReader(filePath: "/\(folderName)/Live & 中文.mp3")
        let length = try await reader.contentLength()
        let slice = try await reader.read(offset: 17, length: 23)
        XCTAssertEqual(length, Int64(bytes.count))
        XCTAssertEqual(slice, bytes.subdata(in: 17..<40))
        await reader.close()
        XCTAssertThrowsError(try TVLocalTransferSource.url(for: "../outside.mp3"))
        XCTAssertThrowsError(try TVLocalTransferSource.url(for: "/\(folderName)/linked.mp3"))
    }

    func testReceivedMusicScanAddsThenPrunesDeletedFile() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store()
        store.reload()
        let source = try store.prepareTransferSource()
        let folderName = "TV Scan QA \(UUID().uuidString)"
        let folder = TVLocalTransferSource.root.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("Transferred.wav")
        try waveFixture().write(to: audio)
        let path = "/\(folderName)/Transferred.wav"
        let songID = TVScanPipelinePolicy.songID(sourceID: source.id, path: path)

        let added = await store.runScan(source: source, lister: TVLocalDirectoryLister(), dirs: ["/"])
        XCTAssertTrue(added)
        XCTAssertEqual(store.scanner.phase, .done)
        XCTAssertNotNil(fixture.library.song(id: songID))
        XCTAssertEqual(fixture.library.song(id: songID)?.filePath, path)

        try FileManager.default.removeItem(at: audio)
        let pruned = await store.runScan(source: source, lister: TVLocalDirectoryLister(), dirs: ["/"])
        XCTAssertTrue(pruned)
        XCTAssertEqual(store.scanner.phase, .done)
        XCTAssertNil(fixture.library.song(id: songID))
        XCTAssertNil(store.song(songID))
    }

    private func waveFixture(duration: TimeInterval = 0.1) -> Data {
        let samples = Data(repeating: 0, count: Int(8_000 * duration) * 2)
        var data = Data()
        func ascii(_ value: String) { data.append(contentsOf: value.utf8) }
        func littleEndian<T: FixedWidthInteger>(_ value: T) {
            var encoded = value.littleEndian
            Swift.withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
        }
        ascii("RIFF")
        littleEndian(UInt32(36 + samples.count))
        ascii("WAVEfmt ")
        littleEndian(UInt32(16))
        littleEndian(UInt16(1))
        littleEndian(UInt16(1))
        littleEndian(UInt32(8_000))
        littleEndian(UInt32(16_000))
        littleEndian(UInt16(2))
        littleEndian(UInt16(16))
        ascii("data")
        littleEndian(UInt32(samples.count))
        data.append(samples)
        return data
    }
}
#endif
