import AppKit
import AVFoundation
import SwiftUI
import XCTest
import PrimuseKit
@testable import Primuse

@MainActor
final class MacFamilyShareInvitationTests: XCTestCase {
    func testFamilyShareInvitationsAreSupportedByInstalledAppAndDelegate() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CKSharingSupported") as? Bool, true)
        XCTAssertTrue(PrimuseAppDelegate().responds(to:
            #selector(NSApplicationDelegate.application(_:userDidAcceptCloudKitShareWith:))))
    }
}

final class MacDiagnosticsMetricsTests: XCTestCase {
    func testCPUUsesIntervalAndPreservesMultipleCoreUsage() throws {
        let before = MacDiagnosticsMetrics.CPUSample(uptime: 100, cpuSeconds: 40)
        let after = MacDiagnosticsMetrics.CPUSample(uptime: 102, cpuSeconds: 43)
        XCTAssertEqual(try XCTUnwrap(MacDiagnosticsMetrics.cpuUsage(from: before, to: after)), 150, accuracy: 0.001)
        let idle = MacDiagnosticsMetrics.CPUSample(uptime: 104, cpuSeconds: 43)
        XCTAssertEqual(MacDiagnosticsMetrics.cpuUsage(from: after, to: idle), 0)
    }

    func testCPURejectsInvalidIntervalsAndResetCounters() {
        let sample = MacDiagnosticsMetrics.CPUSample(uptime: 100, cpuSeconds: 40)
        XCTAssertNil(MacDiagnosticsMetrics.cpuUsage(from: sample, to: sample))
        XCTAssertNil(MacDiagnosticsMetrics.cpuUsage(from: sample, to: .init(uptime: 99, cpuSeconds: 41)))
        XCTAssertNil(MacDiagnosticsMetrics.cpuUsage(from: sample, to: .init(uptime: 102, cpuSeconds: 1)))
        XCTAssertNil(MacDiagnosticsMetrics.cpuUsage(from: sample, to: .init(uptime: .infinity, cpuSeconds: 41)))
    }

    func testLiveMetricsReadTheCurrentProcess() throws {
        let before = try XCTUnwrap(MacDiagnosticsMetrics.cpuSample())
        XCTAssertGreaterThan(try XCTUnwrap(MacDiagnosticsMetrics.memoryFootprintBytes()), 0)
        let after = try XCTUnwrap(MacDiagnosticsMetrics.cpuSample())
        XCTAssertGreaterThanOrEqual(after.cpuSeconds, before.cpuSeconds)
        XCTAssertGreaterThanOrEqual(after.uptime, before.uptime)
    }
}

@MainActor
final class BackgroundServerEnrichmentTests: XCTestCase {
    func testServerCatalogBatchDoesNotEnterAutomaticScraping() async throws {
        let sources = MusicSourceType.allCases.filter(\.isServerLibrary).map {
            MusicSource(id: $0.rawValue, name: "Fixture", type: $0)
        }
        let songs = (0..<5_000).map { index in
            Song(id: "song-\(index)", title: "Incomplete metadata", fileFormat: .mp3,
                 filePath: "/songs/\(index)", sourceID: sources[index % sources.count].id)
        }
        let reads = SourceReadCounter()
        try await withService(sources: sources, reads: reads) { service, library in
            service.automaticWorkIsAllowed = {
                XCTFail("Server songs must be rejected before automatic scheduling")
                return true
            }
            await service.enqueueBackgroundEnrichment(for: songs, in: library)?.value
            XCTAssertFalse(service.hasPendingBackgroundContinuation)
            XCTAssertFalse(service.isBackgroundEnriching)
        }
        let count = await reads.value
        XCTAssertEqual(count, sources.count, "Resolve source ownership once per source, not per song")
    }

    func testFileSourceStillReachesAutomaticScheduling() async throws {
        let source = MusicSource(id: "webdav-fixture", name: "Fixture", type: .webdav)
        let song = Song(id: "song", title: "Missing tags", fileFormat: .mp3,
                        filePath: "/song.mp3", sourceID: source.id)
        try await withService(sources: [source], reads: SourceReadCounter()) { service, library in
            let admitted = expectation(description: "File source remains eligible")
            admitted.assertForOverFulfill = false
            service.automaticWorkIsAllowed = { admitted.fulfill(); return false }
            let task = service.enqueueBackgroundEnrichment(for: [song], in: library)
            await fulfillment(of: [admitted], timeout: 3)
            task?.cancel()
            await task?.value
            XCTAssertFalse(service.isBackgroundEnriching)
        }
    }

    private func withService(
        sources: [MusicSource], reads: SourceReadCounter,
        body: (MusicScraperService, MusicLibrary) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        await library.whenReady()
        let manager = SourceManager(sourcesProvider: {
            await reads.record()
            return sources
        })
        let service = MusicScraperService(sourceManager: manager, checkpointDirectory: root)
        try await body(service, library)
        await library.waitForPendingIndex()
    }

    private actor SourceReadCounter {
        var value = 0
        func record() { value += 1 }
    }
}

@MainActor
final class SpokenWordResumeSyncTests: XCTestCase {
    private var cleanups: [() -> Void] = []
    private let stamp = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        cleanups.reversed().forEach { $0() }
        cleanups.removeAll()
        super.tearDown()
    }

    private func fixture() throws -> (URL, UserDefaults) {
        let id = "spoken-resume-\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: id))
        cleanups.append {
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: directory)
        }
        return (directory, defaults)
    }

    private func chapter(_ number: Int, book: String = "book") -> Song {
        Song(id: "\(book)-\(number)", title: "Chapter \(number)", albumTitle: book,
             trackNumber: number, duration: 3_600, fileFormat: .mp3,
             filePath: "/tingreader/books/\(book)/chapters/\(number).mp3", sourceID: "ting", genre: "Audiobook")
    }

    private func progress(at date: Date, position: Double = 600) throws -> TingReaderListeningProgress {
        try XCTUnwrap(TingReaderListeningProgress(json: [
            "book_id": "book", "chapter_id": "100", "position": position, "duration": 3_600,
            "updated_at": ISO8601DateFormatter().string(from: date),
        ]))
    }

    func testUnchangedServerRefreshReconsidersPersistedRemoteChapter() async throws {
        let (directory, defaults) = try fixture()
        let url = directory.appendingPathComponent("progress.json")
        let original = SpokenWordStore(storeURL: url)
        XCTAssertTrue(original.adoptServerProgress(songID: "book-100", position: 600, duration: 3_600,
                                                   isFinished: false, updatedAt: stamp))
        original.persistLocally()
        let restored = SpokenWordStore(storeURL: url)
        XCTAssertEqual(restored.remoteListeningChange(forSongID: "book-100"), stamp)
        let record = try progress(at: stamp)
        let source = MusicSource(id: "ting", name: "Ting", type: .tingReader)
        var reconsiderations = 0
        let sync = TingReaderProgressSyncCoordinator(
            defaults: defaults, store: restored, sources: { [source] }, songs: { _ in [self.chapter(100)] },
            fetch: { _ in [record] }, protectedSongID: { nil },
            didAdopt: { _ in XCTFail("Already persisted progress must not be written again") },
            didFinishAdopting: { reconsiderations += 1 }
        )
        await sync.refresh()
        await sync.refresh(manual: true)
        XCTAssertEqual(reconsiderations, 2)
        XCTAssertEqual(restored.position(forSongID: "book-100")?.position, 600)
        XCTAssertEqual(restored.revision, 0)
    }

    func testLegacyEqualServerProgressRecoversOriginWithoutRewritingPosition() throws {
        let (directory, _) = try fixture()
        let url = directory.appendingPathComponent("progress.json")
        let payload: [String: Any] = [
            "overrides": [String: String](),
            "positions": ["book-100": ["position": 600.0, "duration": 3_600.0,
                                         "updatedAt": stamp.timeIntervalSinceReferenceDate]],
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        let store = SpokenWordStore(storeURL: url)
        XCTAssertNil(store.remoteListeningChange(forSongID: "book-100"))
        XCTAssertFalse(store.adoptServerProgress(songID: "book-100", position: 500, duration: 3_600,
                                                isFinished: false, updatedAt: stamp))
        XCTAssertTrue(store.adoptServerProgress(songID: "book-100", position: 600, duration: 3_600,
                                               isFinished: false, updatedAt: stamp))
        XCTAssertEqual(store.remoteListeningChange(forSongID: "book-100"), stamp)
        XCTAssertEqual(store.position(forSongID: "book-100")?.position, 600)
        XCTAssertEqual(store.revision, 0)
        store.persistLocally()
        XCTAssertEqual(SpokenWordStore(storeURL: url).remoteListeningChange(forSongID: "book-100"), stamp)

        try JSONSerialization.data(withJSONObject: payload).write(to: url)
        let cloudRestored = SpokenWordStore(storeURL: url)
        cloudRestored.mergeCloudState(SpokenWordSyncState(positions: [
            "book-100": .init(value: .init(position: 600, duration: 3_600), stamp: stamp),
        ]))
        XCTAssertEqual(cloudRestored.remoteListeningChange(forSongID: "book-100"), stamp)
        XCTAssertEqual(cloudRestored.revision, 0)
    }

    func testCloudProgressArrivingBeforeOlderServerSnapshotStillReconsidersChapter() async throws {
        let (directory, defaults) = try fixture()
        let url = directory.appendingPathComponent("progress.json")
        let store = SpokenWordStore(storeURL: url)
        store.mergeCloudState(SpokenWordSyncState(positions: [
            "book-100": .init(value: .init(position: 630, duration: 3_600), stamp: stamp),
        ]))
        store.persistLocally()
        let restored = SpokenWordStore(storeURL: url)
        let record = try progress(at: stamp.addingTimeInterval(-30))
        let source = MusicSource(id: "ting", name: "Ting", type: .tingReader)
        var reconsiderations = 0
        let sync = TingReaderProgressSyncCoordinator(
            defaults: defaults, store: restored, sources: { [source] }, songs: { _ in [self.chapter(100)] },
            fetch: { _ in [record] }, protectedSongID: { nil },
            didAdopt: { _ in XCTFail("The older server snapshot must not replace iCloud progress") },
            didFinishAdopting: { reconsiderations += 1 }
        )
        await sync.refresh()
        XCTAssertEqual(reconsiderations, 1)
        XCTAssertEqual(restored.remoteListeningChange(forSongID: "book-100"), stamp)
        XCTAssertEqual(restored.position(forSongID: "book-100")?.position, 630)
    }

    func testLocalDecisionsInvalidateRemoteOriginAcrossRelaunch() throws {
        let (directory, _) = try fixture()
        let url = directory.appendingPathComponent("progress.json")
        let store = SpokenWordStore(storeURL: url)
        let old = Date().addingTimeInterval(-60)
        for id in ["finished", "cleared", "replayed"] {
            store.adoptServerProgress(songID: id, position: 600, duration: 3_600,
                                      isFinished: false, updatedAt: old)
        }
        store.markFinished(true, songIDs: ["finished"])
        store.clearPosition(forSongID: "cleared")
        store.rememberPosition(300, duration: 3_600, forSongID: "replayed")
        store.persistLocally()
        let restored = SpokenWordStore(storeURL: url)
        for id in ["finished", "cleared", "replayed"] {
            XCTAssertNil(restored.remoteListeningChange(forSongID: id))
            XCTAssertFalse(restored.adoptServerProgress(songID: id, position: 600, duration: 3_600,
                                                        isFinished: false, updatedAt: old))
            XCTAssertNil(restored.remoteListeningChange(forSongID: id))
        }
    }

    func testCloudFinishedMarksAndProtectedChaptersDoNotMovePlayer() async throws {
        let (directory, defaults) = try fixture()
        let store = SpokenWordStore(storeURL: directory.appendingPathComponent("progress.json"))
        store.mergeCloudState(SpokenWordSyncState(finished: [
            "book-100": .init(value: true, stamp: stamp),
        ]))
        XCTAssertNil(store.remoteListeningChange(forSongID: "book-100"))
        let source = MusicSource(id: "ting", name: "Ting", type: .tingReader)
        let record = try progress(at: stamp.addingTimeInterval(60))
        let sync = TingReaderProgressSyncCoordinator(
            defaults: defaults, store: store, sources: { [source] }, songs: { _ in [self.chapter(100)] },
            fetch: { _ in [record] }, protectedSongID: { "book-100" },
            didAdopt: { _ in XCTFail("A playing chapter is protected") },
            didFinishAdopting: { XCTFail("No unprotected chapter was refreshed") }
        )
        await sync.refresh()
        XCTAssertNil(store.position(forSongID: "book-100"))
    }

    func testPausedPlayerFollowsRemoteChapterAndKeepsExplicitLocalIntent() async throws {
        let (directory, defaults) = try fixture()
        let book = "resume-fixture-\(UUID().uuidString)"
        let songs = [chapter(95, book: book), chapter(100, book: book)]
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"))
        await library.whenReady()
        library.addSongs(songs)
        await library.waitForPendingIndex()
        let player = AudioPlayerService(
            library: library, playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Following a paused book must remain silent") }
        )
        let selectionKey = "primuse.spokenWord.selectedItem.v1"
        let selection = UserDefaults.standard.object(forKey: selectionKey)
        let modes = ListeningPlayModeStore.shared.ledger
        defer {
            player.isPlaying = false
            player.currentSong = nil
            player.stop()
            for song in songs { SpokenWordStore.shared.clearPosition(forSongID: song.id) }
            SpokenWordStore.shared.persistLocally()
            UserDefaults.standard.set(selection, forKey: selectionKey)
            ListeningPlayModeStore.shared.update { $0 = modes }
        }
        player.setQueue(songs, startAt: 0)
        player.currentSong = songs[0]
        player.spokenWordLocalTouchAt = stamp.addingTimeInterval(-60)
        SpokenWordStore.shared.adoptServerProgress(songID: songs[1].id, position: 600, duration: 3_600,
                                                   isFinished: false, updatedAt: stamp)
        player.isPlaying = true
        player.followSpokenWordBookIfPaused()
        XCTAssertEqual(player.currentSong?.id, songs[0].id)
        player.isPlaying = false
        player.pendingSpokenWordSeekOverride = (songs[0].id, 50)
        player.followSpokenWordBookIfPaused()
        XCTAssertEqual(player.currentSong?.id, songs[0].id)
        player.pendingSpokenWordSeekOverride = nil
        player.spokenWordLocalTouchAt = stamp.addingTimeInterval(60)
        player.followSpokenWordBookIfPaused()
        XCTAssertEqual(player.currentSong?.id, songs[0].id)
        player.spokenWordLocalTouchAt = stamp.addingTimeInterval(-60)
        SpokenWordStore.shared.mergeCloudState(SpokenWordSyncState(positions: [
            songs[1].id: .init(value: .init(position: 630, duration: 3_600), stamp: stamp.addingTimeInterval(120)),
        ]))
        for _ in 0..<50 where player.currentSong?.id != songs[1].id {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(player.currentSong?.id, songs[1].id)
        XCTAssertFalse(player.isPlaying)
        XCTAssertGreaterThanOrEqual(player.currentTime, 620)
        XCTAssertLessThanOrEqual(player.currentTime, 630)
    }
}

@MainActor
final class SpokenWordProgressProjectionTests: XCTestCase {
    func testProgressCompletionAndArchiveReuseChapterQueues() async throws {
        let songs = (0..<4).map { index in
            Song(id: "chapter-\(index)", title: "Chapter \(index + 1)", albumTitle: "Book \(index / 2)",
                 trackNumber: index % 2 + 1, duration: 600, fileFormat: .mp3,
                 filePath: "/book-\(index / 2)/\(index).mp3", sourceID: "fixture")
        }
        let model = SpokenWordBooksModel()
        await model.refresh(songs: songs, positions: [:], finishedAt: [:],
                            inputs: .init(collection: .books, libraryRevision: 1, storeRevision: 0))
        let date = Date(timeIntervalSince1970: 1000)
        await model.refresh(songs: songs, positions: [songs[0].id: .init(position: 120, duration: 600, updatedAt: date)],
                            finishedAt: [:], inputs: .init(collection: .books, libraryRevision: 1, storeRevision: 1))
        let listening = try XCTUnwrap(model.snapshot.nowListening)
        XCTAssertEqual(listening.songs.map(\.id), ["chapter-0", "chapter-1"])
        XCTAssertEqual(listening.book.resumeItem?.position, 120)
        await model.refresh(songs: songs, positions: [:], finishedAt: ["chapter-0": date, "chapter-1": date],
                            archived: [listening.id], inputs: .init(collection: .books, libraryRevision: 1, storeRevision: 2))
        XCTAssertNil(model.snapshot.nowListening)
        XCTAssertEqual(model.snapshot.archived.first?.id, listening.id)
        XCTAssertEqual(model.snapshot.archived.first?.songs, listening.songs)
        XCTAssertTrue(try XCTUnwrap(model.snapshot.archived.first).book.isFinished)
    }

    func testContentRevisionRebuildsGroupsAndClearingDropsCachedBooks() async {
        var song = Song(id: "chapter", title: "Chapter", albumTitle: "Before", duration: 600,
                        fileFormat: .mp3, filePath: "/book/1.mp3", sourceID: "fixture")
        let model = SpokenWordBooksModel()
        await model.refresh(songs: [song], positions: [:], finishedAt: [:],
                            inputs: .init(collection: .books, libraryRevision: 1, storeRevision: 0))
        song.albumTitle = "After"
        song.duration = 900
        await model.refresh(songs: [song], positions: [:], finishedAt: [:],
                            inputs: .init(collection: .books, libraryRevision: 2, storeRevision: 0))
        XCTAssertEqual(model.snapshot.shelf.first?.book.title, "After")
        XCTAssertEqual(model.snapshot.shelf.first?.songs.first?.duration, 900)
        await model.refresh(songs: [], positions: [:], finishedAt: [:],
                            inputs: .init(collection: .books, libraryRevision: 3, storeRevision: 0))
        XCTAssertTrue(model.snapshot.entriesByID.isEmpty)
    }
}

@MainActor
final class ListeningWidgetArtworkCacheTests: XCTestCase {
    func testProgressUpdatesReuseSuccessfulAndMissingArtwork() async {
        let cache = ListeningWidgetArtworkCache<String>(fileExists: { _ in true })
        var reads = 0
        for _ in 0..<80 {
            let hit = await cache.imageName(for: "podcast", identity: "cover") { reads += 1; return "cover.jpg" }
            let miss = await cache.imageName(for: "radio", identity: "remote") { reads += 1; return nil }
            XCTAssertEqual(hit, "cover.jpg")
            XCTAssertNil(miss)
        }
        XCTAssertEqual(reads, 2)
        cache.invalidate()
        let arrived = await cache.imageName(for: "radio", identity: "remote") { reads += 1; return "radio.jpg" }
        XCTAssertEqual(arrived, "radio.jpg")
        XCTAssertEqual(reads, 3)
    }

    func testChangedArtworkAndEvictedExportsAreReloaded() async {
        var exists = true
        let cache = ListeningWidgetArtworkCache<String>(fileExists: { _ in exists })
        var reads = 0
        _ = await cache.imageName(for: "radio", identity: "old") { reads += 1; return "old.jpg" }
        let changed = await cache.imageName(for: "radio", identity: "new") { reads += 1; return "new.jpg" }
        XCTAssertEqual(changed, "new.jpg")
        exists = false
        let restored = await cache.imageName(for: "radio", identity: "new") { reads += 1; return "restored.jpg" }
        XCTAssertEqual(restored, "restored.jpg")
        XCTAssertEqual(reads, 3)
    }

    func testInvalidationDuringLoadCannotRestoreStaleArtwork() async {
        let cache = ListeningWidgetArtworkCache<String>(fileExists: { _ in true })
        let stale = await cache.imageName(for: "radio", identity: "cover") {
            cache.invalidate()
            return "stale.jpg"
        }
        XCTAssertNil(stale)
        let current = await cache.imageName(for: "radio", identity: "cover") { "current.jpg" }
        XCTAssertEqual(current, "current.jpg")
    }

    func testCancelledPublicationDoesNotCacheItsResult() async {
        let cache = ListeningWidgetArtworkCache<String>(fileExists: { _ in true })
        let task = Task { @MainActor in
            await cache.imageName(for: "radio", identity: "cover") {
                withUnsafeCurrentTask { $0?.cancel() }
                return "cancelled.jpg"
            }
        }
        let cancelled = await task.value
        XCTAssertNil(cancelled)
        let next = await cache.imageName(for: "radio", identity: "cover") { "current.jpg" }
        XCTAssertEqual(next, "current.jpg")
    }

    func testRemovedItemsReleaseTheirCachedMisses() async {
        let cache = ListeningWidgetArtworkCache<String>(fileExists: { _ in true })
        _ = await cache.imageName(for: "radio", identity: "cover") { nil }
        cache.retain(ids: [])
        let reintroduced = await cache.imageName(for: "radio", identity: "cover") { "current.jpg" }
        XCTAssertEqual(reintroduced, "current.jpg")
    }

    func testOnlyLocalReferencesUseTheNamedFileCache() {
        XCTAssertFalse(ListeningWidgetPublisher.isLocalCoverReference("https://example.invalid/logo.png"))
        XCTAssertFalse(ListeningWidgetPublisher.isLocalCoverReference("http://example.invalid/favicon.ico"))
        XCTAssertFalse(ListeningWidgetPublisher.isLocalCoverReference("tingreader:cover:book:library:cover.jpg"))
        XCTAssertTrue(ListeningWidgetPublisher.isLocalCoverReference("selected-" + String(repeating: "a", count: 64) + ".jpg"))
        XCTAssertTrue(ListeningWidgetPublisher.isLocalCoverReference("legacy.jpg"))
    }
}

final class ArtworkRefreshClockTests: XCTestCase {
    func testConcurrentCachedReadsResolveTheRefreshPathOnlyOnce() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("server")
        try "1700000000".write(to: url, atomically: true, encoding: .utf8)
        let resolver = RefreshPathProbe(url: url)
        let clock = ArtworkRefreshClock()

        DispatchQueue.concurrentPerform(iterations: 128) { _ in
            XCTAssertEqual(clock.date(for: "server", at: resolver.resolve()).timeIntervalSince1970, 1_700_000_000)
        }
        XCTAssertEqual(resolver.count, 1, "Warm reads must not hash or construct the refresh path again")
    }

    func testAdvancingOneSourceInvalidatesWarmReadsAndPersistsAcrossRestart() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try "1700000000".write(to: first, atomically: true, encoding: .utf8)
        try "1700000001".write(to: second, atomically: true, encoding: .utf8)
        let clock = ArtworkRefreshClock()
        let old = clock.date(for: "first", at: first)
        let unrelated = clock.date(for: "second", at: second)

        clock.advance(for: "first", at: first)

        let updated = clock.date(for: "first", at: first)
        XCTAssertGreaterThan(updated, old)
        XCTAssertEqual(clock.date(for: "second", at: second), unrelated)
        let restored = ArtworkRefreshClock()
        XCTAssertEqual(restored.date(for: "first", at: first).timeIntervalSince1970, updated.timeIntervalSince1970)
        XCTAssertEqual(restored.date(for: "second", at: second), unrelated)
    }

    func testMissingPublicClockIsCachedAndCanBeAdvanced() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = RefreshPathProbe(url: root.appendingPathComponent("nested/public"))
        let clock = ArtworkRefreshClock()
        XCTAssertEqual(clock.date(for: nil, at: resolver.resolve()), .distantPast)
        XCTAssertEqual(clock.date(for: nil, at: resolver.resolve()), .distantPast)
        XCTAssertEqual(resolver.count, 1)

        clock.advance(for: nil, at: resolver.url)

        let updated = clock.date(for: nil, at: resolver.resolve())
        XCTAssertGreaterThan(updated, .distantPast)
        XCTAssertEqual(resolver.count, 1)
        XCTAssertEqual(ArtworkRefreshClock().date(for: nil, at: resolver.url).timeIntervalSince1970, updated.timeIntervalSince1970)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private final class RefreshPathProbe: @unchecked Sendable {
        let url: URL
        private let lock = NSLock()
        private var resolutions = 0
        var count: Int { lock.withLock { resolutions } }
        init(url: URL) { self.url = url }
        func resolve() -> URL {
            lock.withLock { resolutions += 1 }
            return url
        }
    }
}

@MainActor
final class LargeVideoMetadataIntegrationTests: XCTestCase {
    private struct Manifest: Decodable {
        struct File: Decodable {
            let path: String
            let size: Int64
            let duration: Double
        }
        let httpPort: Int
        let ftpPort: Int
        let scratchDirectory: String
        let files: [File]
    }

    func testRealLargeVideosOverHTTPRange() async throws {
        try await scanRealVideos(usesFTP: false)
    }

    func testRealLargeVideosOverFTP() async throws {
        try await scanRealVideos(usesFTP: true)
    }

    private func scanRealVideos(usesFTP: Bool) async throws {
        guard let path = ProcessInfo.processInfo.environment["PRIMUSE_LARGE_VIDEO_MANIFEST"] else {
            throw XCTSkip("Set PRIMUSE_LARGE_VIDEO_MANIFEST using large-video-metadata-server.py")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(manifest.files.isEmpty)
        // SQLite connections can outlive an XCTest method. The fixture server
        // owns this directory and removes it only after the test host exits.
        let directory = URL(fileURLWithPath: manifest.scratchDirectory).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourceID = "large-video-\(UUID().uuidString)"
        let source = MusicSource(id: sourceID, name: "Large video fixture", type: usesFTP ? .ftp : .googleDrive)
        let connector = LargeVideoRangeConnector(
            sourceID: sourceID, httpPort: manifest.httpPort, ftpPort: usesFTP ? manifest.ftpPort : nil
        )
        addTeardownBlock { await connector.disconnect() }
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"))
        await library.whenReady()
        let songs = manifest.files.enumerated().map { index, file in
            Song(id: "\(sourceID)-\(index)", title: "Video \(index + 1)", fileFormat: .mp4,
                 filePath: file.path, sourceID: sourceID, fileSize: file.size)
        }
        library.addSongs(songs, affectedSourceIDs: [sourceID])
        await library.waitForPendingIndex()
        let defaults = UserDefaults.standard
        let key = MetadataBackfillExecutionPolicy.readingModeDefaultsKey
        let previous = defaults.object(forKey: key)
        defaults.set(MetadataReadingMode.automatic.rawValue, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let backfill = MetadataBackfillService(
            library: library, sourceManager: manager, backfillableSourceIDs: { [sourceID] },
            offlineReadableSourceIDs: { [sourceID] }
        )
        defer { backfill.stop() }
        let started = Date()
        backfill.refreshStatusSnapshot()
        backfill.start()
        await backfill.waitUntilIdle()
        await library.waitForPendingIndex()
        for (song, file) in zip(songs, manifest.files) {
            XCTAssertGreaterThanOrEqual(file.size, 4_000_000_000)
            let scanned = try XCTUnwrap(library.song(id: song.id))
            XCTAssertEqual(scanned.duration, file.duration, accuracy: 0.1)
            XCTAssertEqual(scanned.fileSize, file.size)
            let backgroundBytes = await connector.byteCount(for: file.path)
            XCTAssertLessThan(backgroundBytes, 65 * 1024 * 1024)
            let result = await backfill.rereadTags(songID: song.id, expectedSourceID: sourceID)
            guard case .completed = result else { return XCTFail("Reread failed: \(result)") }
            XCTAssertEqual(library.song(id: song.id)?.duration ?? 0, file.duration, accuracy: 0.1)
            let totalBytes = await connector.byteCount(for: file.path)
            XCTAssertLessThan(totalBytes, 130 * 1024 * 1024)
            print("LARGE_VIDEO transport=\(usesFTP ? "FTP" : "HTTP") size=\(file.size) duration=\(scanned.duration) scanBytes=\(backgroundBytes) rereadBytes=\(totalBytes - backgroundBytes)")
        }
        let requestsBefore = await connector.requestCount
        backfill.refreshStatusSnapshot()
        XCTAssertEqual(backfill.remainingCount(forSource: sourceID), 0)
        backfill.start()
        await backfill.waitUntilIdle()
        let requestsAfter = await connector.requestCount
        let completeDownloads = await connector.completeDownloads
        XCTAssertEqual(requestsBefore, requestsAfter, "Completed metadata must not be read repeatedly")
        XCTAssertEqual(completeDownloads, 0, "A missing cover in a complete moov must not download the video")
        print("LARGE_VIDEO completed transport=\(usesFTP ? "FTP" : "HTTP") seconds=\(Date().timeIntervalSince(started)) requests=\(requestsAfter) downloads=\(completeDownloads)")
        await connector.disconnect()
        await library.waitForPendingIndex()
        _ = await library.persistNowAndWait()
    }
}

private actor LargeVideoRangeConnector: MusicSourceConnector {
    let sourceID: String
    private let httpPort: Int
    private let ftp: FTPSessionPool?
    private let cloud: CloudDriveHelper
    private var bytes: [String: Int] = [:]
    private(set) var requestCount = 0
    private(set) var completeDownloads = 0

    init(sourceID: String, httpPort: Int, ftpPort: Int?) {
        self.sourceID = sourceID
        self.httpPort = httpPort
        cloud = CloudDriveHelper(sourceID: sourceID)
        ftp = ftpPort.map {
            FTPSessionPool(configuration: .init(host: "127.0.0.1", port: $0, username: "", password: "",
                                           encryption: .none, dataConnectionMode: .passive,
                                           log: { print("LARGE_VIDEO \($0)") }))
        }
    }
    func connect() async throws {}
    func disconnect() async { await ftp?.shutdown() }
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        completeDownloads += 1
        throw SourceError.fileNotFound(path)
    }
    func localURL(for path: String) async throws -> URL {
        completeDownloads += 1
        throw SourceError.fileNotFound(path)
    }
    func fetchRange(path: String, offset: Int64, length: Int64, priority: RangeFetchPriority) async throws -> Data {
        requestCount += 1
        let data: Data
        if let ftp {
            data = try await ftp.withSession { session in
                let size = try await session.size(path) ?? 0
                let plan = FTPTransferPolicy.rangePlan(fileSize: size, requestedOffset: offset, requestedLength: length)
                return try await session.retrieve(path, offset: plan.offset, length: plan.expectedLength)
            }
        } else {
            let url = URL(string: "http://127.0.0.1:\(httpPort)\(path)")!
            data = try await cloud.rangeRequest(url: url, offset: offset, length: length)
        }
        bytes[path, default: 0] += data.count
        return data
    }
    func byteCount(for path: String) -> Int { bytes[path, default: 0] }
}

@MainActor
final class SourceAutomaticScanSchedulingTests: XCTestCase {
    func testAutomaticScansRunSeriallyAndCoalesceRepeatedRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.scan.cancelAllActiveScans() }
        XCTAssertTrue(fixture.start(0))
        XCTAssertFalse(fixture.start(1))
        XCTAssertFalse(fixture.start(1))
        XCTAssertFalse(fixture.start(2))
        try await waitUntil { await fixture.connectors[0].isWaiting }
        let secondStarts = await fixture.connectors[1].starts
        XCTAssertEqual(secondStarts, 0)

        var finished = false
        let drain = Task { await fixture.scan.waitForActiveScansToComplete(); finished = true }
        await fixture.connectors[0].release()
        try await waitUntil { await fixture.connectors[1].isWaiting }
        XCTAssertFalse(finished)
        let thirdStarts = await fixture.connectors[2].starts
        XCTAssertEqual(thirdStarts, 0)
        await fixture.connectors[1].release()
        try await waitUntil { await fixture.connectors[2].isWaiting }
        XCTAssertFalse(finished)
        await fixture.connectors[2].release()
        await drain.value
        XCTAssertTrue(finished)
        for connector in fixture.connectors {
            let starts = await connector.starts
            XCTAssertEqual(starts, 1)
        }
    }

    func testQueuedRefreshRechecksEligibilityWhenItsTurnArrives() async throws {
        let fixture = try Fixture()
        defer { fixture.scan.cancelAllActiveScans() }
        var enabled = true
        XCTAssertTrue(fixture.start(0))
        XCTAssertFalse(fixture.start(1, eligibility: { enabled }))
        enabled = false
        await fixture.connectors[0].release()
        await fixture.scan.waitForActiveScansToComplete()
        let starts = await fixture.connectors[1].starts
        XCTAssertEqual(starts, 0)
    }

    func testCancellingAllScansDoesNotStartQueuedWork() async throws {
        let fixture = try Fixture()
        XCTAssertTrue(fixture.start(0))
        XCTAssertFalse(fixture.start(1))
        try await waitUntil { await fixture.connectors[0].isWaiting }
        fixture.scan.cancelAllActiveScans()
        await fixture.connectors[0].release()
        await fixture.scan.waitForActiveScansToComplete()
        try await Task.sleep(for: .milliseconds(100))
        let starts = await fixture.connectors[1].starts
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(fixture.scan.hasActiveScans)
    }

    func testManualScanSupersedesItsQueuedAutomaticRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.scan.cancelAllActiveScans() }
        XCTAssertTrue(fixture.start(0))
        XCTAssertFalse(fixture.start(1))
        XCTAssertTrue(fixture.start(1, context: .userInitiatedForeground))
        try await waitUntil { await fixture.connectors[1].isWaiting }
        await fixture.connectors[1].release()
        try await waitUntil { fixture.store.source(id: fixture.sources[1].id)?.lastScannedAt != nil }
        await fixture.connectors[0].release()
        await fixture.scan.waitForActiveScansToComplete()
        let starts = await fixture.connectors[1].starts
        XCTAssertEqual(starts, 1)
    }

    func testRefreshIntervalsPersistPerSourceAndKeepLegacyDefaults() throws {
        let fixture = try Fixture()
        let suite = "SourceRefreshSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = MusicSource(id: "server", name: "Server", type: .navidrome)
        fixture.store.add(server)
        defaults.set(Data(#"{"disabledSourceIDs":["server"],"markers":{}}"#.utf8),
                     forKey: "primuse.navidrome-auto-refresh.v1")
        let scraper = MusicScraperService(sourceManager: fixture.manager)
        let player = AudioPlayerService(
            sourceManager: fixture.manager, library: fixture.library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: fixture.root.appendingPathComponent("playback.json")),
            activateAudioSession: { _ in }
        )
        func coordinator() -> ServerCatalogAutoRefreshCoordinator {
            ServerCatalogAutoRefreshCoordinator(
                sourceManager: fixture.manager, scanService: fixture.scan, library: fixture.library,
                sourcesStore: fixture.store, scraperService: scraper, player: player, defaults: defaults
            )
        }
        let first = coordinator()
        XCTAssertFalse(first.isEnabled(for: fixture.sources[0].id))
        XCTAssertFalse(first.isEnabled(for: server.id))
        XCTAssertEqual(first.refreshInterval(for: fixture.sources[0].id), .sixHours)
        first.setRefreshInterval(.oneHour, for: fixture.sources[0].id)
        first.setRefreshInterval(.twentyFourHours, for: fixture.sources[1].id)
        first.setEnabled(true, for: fixture.sources[0].id)
        let reopened = coordinator()
        XCTAssertTrue(reopened.isEnabled(for: fixture.sources[0].id))
        XCTAssertFalse(reopened.isEnabled(for: fixture.sources[1].id))
        XCTAssertFalse(reopened.isEnabled(for: server.id))
        XCTAssertEqual(reopened.refreshInterval(for: fixture.sources[0].id), .oneHour)
        XCTAssertEqual(reopened.refreshInterval(for: fixture.sources[1].id), .twentyFourHours)
        XCTAssertEqual(reopened.refreshInterval(for: fixture.sources[2].id), .sixHours)
    }

    func testNativeBackgroundRefreshUsesTheSelectedIntervalAfterFinalCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PeriodicRefresh-\(UUID().uuidString)")
        let directory = root.appendingPathComponent("Primuse")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var source = MusicSource(id: UUID().uuidString, name: "Drive", type: .dropbox,
                                 extraConfig: "[\"/Music\"]")
        let completedAt = Date(timeIntervalSince1970: 1_000_000)
        source.lastScannedAt = completedAt
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        source = try XCTUnwrap(store.source(id: source.id))
        let state = SourceSyncState(
            sourceID: source.id, scopeFingerprint: ScanService.scopeFingerprint(for: source, directories: ["/Music"]),
            cursors: ["/Music": "committed-cursor"], lastSuccessfulSyncAt: completedAt.addingTimeInterval(-300)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([source.id: state]).write(to: directory.appendingPathComponent("source-sync-states.json"))
        let scan = ScanService(fileManager: AutomaticScanFixtureFileManager(root: root))
        var enabled = false
        scan.automaticRefreshEnabledHandler = { _ in enabled }
        XCTAssertNil(scan.nextPeriodicSyncDate(sourceStore: store))
        enabled = true
        for interval in SourceAutomaticRefreshInterval.allCases {
            scan.automaticRefreshIntervalHandler = { _ in interval }
            XCTAssertEqual(scan.nextPeriodicSyncDate(sourceStore: store), completedAt.addingTimeInterval(interval.timeInterval))
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !(await condition()) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let sources: [MusicSource]
        let connectors: [AutomaticScanFixtureConnector]
        let store: SourcesStore
        let library: MusicLibrary
        let manager: SourceManager
        let scan: ScanService

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("AutomaticScan-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            sources = (0..<3).map {
                MusicSource(id: UUID().uuidString, name: "Source \($0)", type: .webdav,
                            host: "scan.invalid", extraConfig: "[\"/Music\"]")
            }
            let connectors = sources.map { AutomaticScanFixtureConnector(sourceID: $0.id) }
            self.connectors = connectors
            let byID = Dictionary(uniqueKeysWithValues: zip(sources.map(\.id), connectors))
            store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
            for source in sources { store.add(source) }
            library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
            manager = SourceManager(sourcesProvider: { [] })
            scan = ScanService(
                fileManager: AutomaticScanFixtureFileManager(root: root),
                connectorProvider: { byID[$0.id]! },
                diagnosticProvider: { source, _ in
                    SourceDiagnosticReport(source: source, startedAt: Date(), checks: [])
                }
            )
        }

        func start(_ index: Int, context: BaiduSnapshotExecutionContext = .foregroundResume,
                   eligibility: (() -> Bool)? = nil) -> Bool {
            scan.scanSource(sources[index], snapshotExecutionContext: context,
                            sourceManager: manager, library: library, sourceStore: store,
                            requestsContinuedProcessing: false, automaticRefreshIsAllowed: eligibility)
        }
    }
}

private actor AutomaticScanFixtureConnector: MusicSourceConnector {
    let sourceID: String
    private(set) var starts = 0
    private(set) var isWaiting = false
    private var released = false
    init(sourceID: String) { self.sourceID = sourceID }
    func release() { released = true }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        starts += 1
        isWaiting = true
        defer { isWaiting = false }
        while !released { try await Task.sleep(for: .milliseconds(10)) }
        return []
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        .init { $0.finish() }
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }
}

private final class AutomaticScanFixtureFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
}

@MainActor
final class MacResourceRegressionTests: XCTestCase {
    func testLocalDownloadActionsAreHiddenWithoutMarkingOriginalsAsDownloaded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SourcesStore(storageDirectoryURL: root)
        let local = MusicSource(id: UUID().uuidString, name: "External disk", type: .local,
                                basePath: "/Volumes/External/Music")
        let remote = MusicSource(id: UUID().uuidString, name: "Remote", type: .webdav)
        try store.addDurably(local)
        try store.addDurably(remote)
        let localSong = Song(id: UUID().uuidString, title: "Local", fileFormat: .flac,
                             filePath: "/track.flac", sourceID: local.id)
        var remoteSong = localSong
        remoteSong.id = UUID().uuidString
        remoteSong.sourceID = remote.id
        let manager = SourceManager(sourcesProvider: { [local, remote] })

        func menuHeight(_ song: Song, snapshot: OfflineAudioCacheSnapshot = .notCached) -> CGFloat {
            let host = NSHostingView(rootView: SongOfflineActionButtons(song: song, snapshot: snapshot)
                .environment(store)
                .environment(manager)
                .fixedSize())
            return host.fittingSize.height
        }

        XCTAssertEqual(menuHeight(localSong), 0, "Uncached local originals must not offer Download")
        XCTAssertGreaterThan(menuHeight(remoteSong), 0, "Remote files must retain their Download action")
        var stream = localSong
        stream.filePath = "/remote.strm"
        XCTAssertGreaterThan(menuHeight(stream), 0, "A local descriptor can point to remote audio")
        XCTAssertEqual(store.downloadableSongs(in: [localSong, remoteSong]).map(\.id), [remoteSong.id])
        XCTAssertTrue(store.downloadableSongs(in: [localSong]).isEmpty)
        // Existing explicit copies can still be removed; hiding Download must
        // not relabel or delete local originals or their cache records.
        let pinned = OfflineAudioCacheSnapshot(state: .pinned, progress: nil, byteCount: 128, errorMessage: nil)
        XCTAssertGreaterThan(menuHeight(localSong, snapshot: pinned), 0)
        XCTAssertFalse(manager.offlineAudioSnapshotEntry(for: localSong).snapshot.isDownloaded)
        store.updateLocal(remote.id) { $0.isEnabled = false }
        XCTAssertEqual(menuHeight(remoteSong), 0)
        XCTAssertTrue(store.downloadableSongs(in: [localSong, remoteSong]).isEmpty)
    }

    func testCacheCompletionDoesNotEnumerateLibraryAndUpdatesAllRowsSharingAFile() async throws {
        let source = MusicSource(id: UUID().uuidString, name: "Cache fixture", type: .navidrome)
        let first = Song(id: UUID().uuidString, title: "First", fileFormat: .flac,
                         filePath: "/fixture.flac", sourceID: source.id, fileSize: 128)
        var second = first
        second.id = UUID().uuidString
        var libraryReads = 0
        let manager = SourceManager(sourcesProvider: { [source] }, songsProvider: {
            libraryReads += 1
            return [first, second]
        })
        try await waitUntilAsync { await manager.prepareAutomaticOfflineDownload(song: first, forceRedownload: false) }
        defer { manager.deleteLocalCaches(for: [first, second]) }
        await manager.prepareOfflineAudioSnapshots(for: [first, second])
        let firstEntry = manager.offlineAudioSnapshotEntry(for: first)
        let secondEntry = manager.offlineAudioSnapshotEntry(for: second)
        let url = manager.cacheURL(for: first)
        let path = source.id + "/" + url.lastPathComponent
        let readsBeforeCompletion = libraryReads
        try Data(repeating: 7, count: 128).write(to: url)
        await AudioCacheManager.shared.recordAccess(path: path)
        try await waitUntilAsync { firstEntry.snapshot.isDownloaded && secondEntry.snapshot.isDownloaded }
        XCTAssertEqual(libraryReads, readsBeforeCompletion, "A cache notification must not scan the song library")
        await AudioCacheManager.shared.removeEntry(path: path)
        try await waitUntilAsync { !firstEntry.snapshot.isDownloaded && !secondEntry.snapshot.isDownloaded }
        XCTAssertEqual(libraryReads, readsBeforeCompletion)
    }

    func testCacheNotificationsFollowSongRenames() async throws {
        let source = MusicSource(id: UUID().uuidString, name: "Rename fixture", type: .navidrome)
        let previous = Song(id: UUID().uuidString, title: "Track", fileFormat: .flac,
                            filePath: "/before.flac", sourceID: source.id, fileSize: 128)
        var current = previous
        let manager = SourceManager(sourcesProvider: { [source] }, songsProvider: { [current] })
        try await waitUntilAsync { await manager.prepareAutomaticOfflineDownload(song: previous, forceRedownload: false) }
        await manager.ensureOfflineAudioSnapshot(for: previous)
        let entry = manager.offlineAudioSnapshotEntry(for: previous)
        _ = manager.cacheURL(for: previous)
        current.filePath = "/after.flac"
        defer { manager.deleteLocalCaches(for: [previous, current]) }
        NotificationCenter.default.post(name: .primuseSongLocationChanged, object: nil,
                                        userInfo: ["previousSongs": [previous], "songs": [current]])
        try await Task.sleep(for: .milliseconds(100))
        let url = manager.audioCacheTargetURL(for: current)
        try Data(repeating: 9, count: 128).write(to: url)
        await AudioCacheManager.shared.recordAccess(path: source.id + "/" + url.lastPathComponent)
        try await waitUntilAsync { entry.snapshot.isDownloaded }
    }

    func testUnrelatedCacheNotificationDoesNotReadLibrary() async throws {
        var reads = 0
        let manager = SourceManager(sourcesProvider: { [] }, songsProvider: { reads += 1; return [] })
        // Let initial source validation finish before isolating the notification.
        try await Task.sleep(for: .milliseconds(150))
        let before = reads
        NotificationCenter.default.post(name: .primuseAudioCacheFilesDidChange, object: nil,
                                        userInfo: ["paths": [UUID().uuidString + "/unknown.flac"]])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(reads, before)
        withExtendedLifetime(manager) {}
    }

    func testUnavailableBookmarkFailsClosedWithoutFallingBackToBasePath() async throws {
        let sourceID = UUID().uuidString
        let key = "primuse.localBookmark." + sourceID
        UserDefaults.standard.set(Data([0, 1, 2]), forKey: key)
        defer { LocalBookmarkStore.remove(sourceID: sourceID) }
        let connector = LocalFileSource(sourceID: sourceID, basePath: FileManager.default.temporaryDirectory)
        do {
            _ = try await connector.localURL(for: "/")
            XCTFail("A corrupt bookmark cannot grant access through the fallback directory")
        } catch SourceError.credentialUnavailable { }
    }

    func testLocalConnectorLazilyResolvesBeforeListingWithoutAnExplicitConnect() async throws {
        let sourceID = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(sourceID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("fixture.txt"))
        defer { try? FileManager.default.removeItem(at: root); LocalBookmarkStore.remove(sourceID: sourceID) }
        try LocalBookmarkStore.save(sourceID: sourceID, url: root)
        let connector = LocalFileSource(sourceID: sourceID, basePath: root.appendingPathComponent("incorrect-fallback"))
        let files = try await connector.listFiles(at: "/")
        XCTAssertEqual(files.map(\.name), ["fixture.txt"])
    }

    func testKaraokeAudioUnitLoadsInsideApplicationSandbox() throws {
        let control = KaraokeRenderControl()
        let node = try XCTUnwrap(KaraokeVocalReducerUnit.makeNode(control: control))
        let unit = try XCTUnwrap(node.auAudioUnit as? KaraokeVocalReducerUnit)
        XCTAssertTrue(unit.control === control)
        try unit.allocateRenderResources()
        unit.deallocateRenderResources()
    }

    private func waitUntilAsync(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
final class PlayerLyricsColorRenderingTests: XCTestCase {
    private struct Sample: View {
        var colors = PlayerLyricsColors()
        var active = true
        var direction: LayoutDirection = .leftToRight
        var body: some View {
            Rectangle().fill(colors.style(defaultColor: .white, isActive: active, layoutDirection: direction))
        }
    }

    func testCustomColorUsesSharedStorageAndLeavesInactiveLyricsUnchanged() throws {
        try withDefaults { defaults in
            defaults.set("custom", forKey: PlayerAppearancePreferences.lyricsColorModeKey)
            defaults.set(" #ff0000 ", forKey: PlayerAppearancePreferences.customLyricsColorHexKey)
            let active = try render(Sample(), defaults: defaults)
            XCTAssertGreaterThan(active[0], 240)
            XCTAssertLessThan(active[1], 10)
            let inactive = try render(Sample(active: false), defaults: defaults)
            XCTAssertGreaterThan(inactive[0], 240)
            XCTAssertGreaterThan(inactive[1], 240)
            XCTAssertGreaterThan(inactive[2], 240)
        }
    }

    func testInvalidModeAndColorUseReadableDefaults() throws {
        try withDefaults { defaults in
            defaults.set("unknown", forKey: PlayerAppearancePreferences.lyricsColorModeKey)
            let original = try render(Sample(), defaults: defaults)
            XCTAssertGreaterThan(original[0], 240)
            XCTAssertGreaterThan(original[1], 240)
            defaults.set("custom", forKey: PlayerAppearancePreferences.lyricsColorModeKey)
            defaults.set("invalid", forKey: PlayerAppearancePreferences.customLyricsColorHexKey)
            let fallback = try render(Sample(), defaults: defaults)
            defaults.set(PlayerAppearancePreferences.defaultCustomLyricsColorHex,
                         forKey: PlayerAppearancePreferences.customLyricsColorHexKey)
            XCTAssertEqual(fallback, try render(Sample(), defaults: defaults))
        }
    }

    func testGradientFollowsWritingDirection() throws {
        try withDefaults { defaults in
            defaults.set("gradient", forKey: PlayerAppearancePreferences.lyricsColorModeKey)
            defaults.set("FF0000", forKey: PlayerAppearancePreferences.gradientLyricsStartColorHexKey)
            defaults.set("0000FF", forKey: PlayerAppearancePreferences.gradientLyricsEndColorHexKey)
            let ltr = try render(Sample(), defaults: defaults)
            let rtl = try render(Sample(direction: .rightToLeft), defaults: defaults)
            XCTAssertGreaterThan(Int(ltr[0]), Int(ltr[2]) + 100)
            XCTAssertGreaterThan(Int(ltr[63 * 4 + 2]), Int(ltr[63 * 4]) + 100)
            XCTAssertGreaterThan(Int(rtl[2]), Int(rtl[0]) + 100)
            XCTAssertGreaterThan(Int(rtl[63 * 4]), Int(rtl[63 * 4 + 2]) + 100)
        }
    }


    func testMacColorPickerPersistsSRGBHex() throws {
        var stored = "FFFFFF"
        let binding = PlayerLyricsColors.binding(Binding(get: { stored }, set: { stored = $0 }), fallback: "FFFFFF")
        binding.wrappedValue = Color(.sRGB, red: 1, green: 0.5, blue: 0, opacity: 1)
        XCTAssertEqual(stored, "FF8000")
    }

    func testMacSearchFindsLyricColorControls() {
        for id in ["lyrics.colorMode", "lyrics.customColor", "lyrics.gradientStart", "lyrics.gradientEnd"] {
            XCTAssertEqual(SettingsCatalog.byID[id]?.macPage, .lyrics)
        }
    }

    func testColorSettingsPreview() throws {
        try withDefaults { defaults in
            defaults.set("gradient", forKey: PlayerAppearancePreferences.lyricsColorModeKey)
            let content = VStack(spacing: 0) { MacLyricsColorSettings() }
                .padding(24).frame(width: 680).background(Color(nsColor: .windowBackgroundColor))
                .defaultAppStorage(defaults).environment(\.colorScheme, .light)
            let host = NSHostingView(rootView: content)
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "MacLyricsColorSettings"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "PlayerLyricsColorRenderingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func render<V: View>(_ view: V, defaults: UserDefaults) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: 64, height: 32)
            .defaultAppStorage(defaults).environment(\.colorScheme, .light))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: 64 * 32 * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 64, height: 32,
                bitsPerComponent: 8, bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 32))
        }
        return pixels
    }
}
