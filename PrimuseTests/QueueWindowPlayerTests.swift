import Foundation
import Observation
import os
import PrimuseKit
import XCTest
@testable import Primuse

/// A very large play request installs a window and tops it up from the rest of
/// the request as playback nears the window's end.
final class QueueWindowPlayerTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups = []
        super.tearDown()
    }

    private func songs(_ count: Int) -> [Song] {
        (0..<count).map {
            Song(id: "s\($0)", title: "Song \($0)", duration: 180, fileFormat: .flac,
                 filePath: "/music/\($0).flac", sourceID: "local-source")
        }
    }

    @MainActor
    private func makePlayer(librarySongs: [Song], startsPreparing: Bool = false, includesLibrary: Bool = true,
                            sessionDirectory: URL? = nil) async throws -> AudioPlayerService {
        let suite = "queue-window-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanups.append {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let libraryDirectory = directory.appendingPathComponent("library")
        let library: MusicLibrary
        if startsPreparing {
            try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            let store = try IncrementalSongStore(path: libraryDirectory.appendingPathComponent("library-songs.sqlite").path)
            try store.replaceAll(with: librarySongs)
            try store.markMigrationCompleted(version: 10)
            library = MusicLibrary.makePreparing(storageDirectory: libraryDirectory)
        } else {
            library = MusicLibrary(storageDirectory: libraryDirectory)
        }
        if !startsPreparing, !librarySongs.isEmpty {
            library.addSongs(librarySongs, affectedSourceIDs: ["local-source"])
            for _ in 0..<500 where library.unobservedVisibleSong(id: librarySongs.last!.id) == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(library.unobservedVisibleSong(id: librarySongs.last!.id))
        }
        let sessionDirectory = sessionDirectory ?? directory
        let musicMemory = MusicSessionMemoryStore(
            defaults: defaults, url: sessionDirectory.appendingPathComponent("music-memory.json")
        )
        addTeardownBlock { @MainActor in await musicMemory.waitForPendingPersistence() }
        return AudioPlayerService(
            library: includesLibrary ? library : nil,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: sessionDirectory.appendingPathComponent("session.json")),
            musicSessionMemoryStore: musicMemory,
            queueBookmarkStore: QueueBookmarkStore(directory: sessionDirectory.appendingPathComponent("bookmarks")),
            activateAudioSession: { _ in XCTFail("Queue tests must not start audio") }
        )
    }

    @MainActor
    func testBookmarkRestoresDuplicateOccurrenceAndExactShuffleCheckpointAfterQueueEdits() async throws {
        let catalog = songs(5)
        let player = try await makePlayer(librarySongs: catalog)
        player.setQueue([catalog[0], catalog[1], catalog[0], catalog[2]], startAt: 2)
        player.currentSong = catalog[0]
        player.currentTime = 64
        player.shuffleEnabled = true
        player.shuffledIndices = [1, 2, 0, 3]
        player.shufflePosition = 1
        player.pendingNextShuffleIndices = [3, 0, 2, 1]
        await player.toggleCurrentQueueBookmark()
        let id = player.queueIdentity
        XCTAssertTrue(player.isCurrentQueueBookmarked)
        player.appendToQueue([catalog[4]])
        player.currentTime = 100
        player.setQueue([catalog[3]])
        player.currentSong = catalog[3]
        XCTAssertFalse(player.isCurrentQueueBookmarked)
        let restored = await player.resumeQueueBookmark(id, startPlayback: false)
        XCTAssertTrue(restored)
        XCTAssertEqual(player.queue.map(\.id), ["s0", "s1", "s0", "s2"])
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertEqual(player.currentTime, 64)
        XCTAssertEqual(player.shuffledIndices, [1, 2, 0, 3])
        XCTAssertEqual(player.shufflePosition, 1)
        XCTAssertEqual(player.pendingNextShuffleIndices, [3, 0, 2, 1])
        XCTAssertEqual(player.queueIdentity, id)
        XCTAssertTrue(player.isCurrentQueueBookmarked)
        await player.toggleCurrentQueueBookmark()
        XCTAssertTrue(player.queueBookmarkStore.bookmarks.isEmpty)
    }

    @MainActor
    func testBookmarksKeepIndependentLargeQueueContinuationsAcrossRestart() async throws {
        let catalog = songs(2_500)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        cleanups.append { try? FileManager.default.removeItem(at: directory) }
        let player = try await makePlayer(librarySongs: catalog, sessionDirectory: directory)
        let order = player.shufflePlayOrder(catalog)
        player.shuffleEnabled = true
        player.setQueue(order, startAt: 1_200)
        player.currentSong = order[1_200]
        player.currentTime = 35
        let expected = player.queue.map(\.id)
        let expectedShuffle = player.shuffledIndices
        let expectedPosition = player.shufflePosition
        let continuation = player.queueContinuation
        await player.toggleCurrentQueueBookmark()
        let firstID = player.queueIdentity
        player.setQueue([catalog[8], catalog[9]])
        player.currentSong = catalog[8]
        await player.toggleCurrentQueueBookmark()
        XCTAssertEqual(player.queueBookmarkStore.bookmarks.count, 2)
        let reloaded = try await makePlayer(librarySongs: catalog, sessionDirectory: directory)
        await reloaded.queueBookmarkStore.whenReady()
        XCTAssertEqual(reloaded.queueBookmarkStore.bookmarks.count, 2)
        let restored = await reloaded.resumeQueueBookmark(firstID, startPlayback: false)
        XCTAssertTrue(restored)
        XCTAssertEqual(reloaded.queue.map(\.id), expected)
        XCTAssertEqual(reloaded.queueContinuation, continuation)
        XCTAssertEqual(reloaded.shuffledIndices, expectedShuffle)
        XCTAssertEqual(reloaded.shufflePosition, expectedPosition)
        XCTAssertEqual(reloaded.currentTime, 35)
        XCTAssertTrue(reloaded.isCurrentQueueBookmarked)
    }

    @MainActor
    func testColdLaunchKeepsBookmarkIdentityWithoutChangingSavedCheckpoint() async throws {
        let catalog = songs(3)
        let player = try await makePlayer(librarySongs: catalog)
        player.setQueue(catalog, startAt: 1)
        player.currentSong = catalog[1]
        player.currentTime = 20
        await player.toggleCurrentQueueBookmark()
        let id = player.queueIdentity
        player.currentTime = 55
        player.persistPlaybackSession(flushImmediately: true)
        let reloaded = try await makePlayer(librarySongs: catalog,
                                           sessionDirectory: player.playbackSessionStore.url.deletingLastPathComponent())
        await reloaded.restorePlaybackSessionIfAvailable(startupSourceIDs: ["local-source"])
        await reloaded.queueBookmarkStore.whenReady()
        XCTAssertEqual(reloaded.currentTime, 55)
        XCTAssertEqual(reloaded.queueIdentity, id)
        XCTAssertTrue(reloaded.isCurrentQueueBookmarked)
        let checkpoint = try await reloaded.queueBookmarkStore.memory(id: id)
        XCTAssertEqual(checkpoint.snapshot.currentTime, 20)
    }

    @MainActor
    func testColdRememberedQueueIsActionableAndRestoresTheSelectedOccurrenceBeforePublication() async throws {
        var catalog = songs(5)
        catalog[1].sourceID = "disabled"
        let player = try await makePlayer(librarySongs: catalog, startsPreparing: true)
        let library = try XCTUnwrap(player.library)
        library.updateDisabledSourceIDs(["disabled"])
        player.setQueue([catalog[0]])
        player.currentSong = catalog[0]
        let identity = UUID()
        let snapshot = PlaybackSessionSnapshot(queueSongIDs: ["s2", "s1", "s2", "missing", "s4"], currentSongID: "s2",
            currentIndex: 2, currentTime: 42, duration: 180, wasPlaying: false, shuffleEnabled: true,
            shuffledIndices: [1, 2, 4, 0, 3], shufflePosition: 1, repeatMode: .all, isAtTrackEnd: false,
            queueIdentity: identity)
        player.musicSessionMemoryStore.save(.init(snapshot: snapshot, title: "Two", songID: "s2", sourceID: "local-source",
                                                 savedAt: Date()))
        XCTAssertNil(ListeningIntentService.shared.resumeSongCount(player: player))
        await player.musicSessionMemoryStore.waitForStartupResumeTarget()
        XCTAssertTrue(player.hasPlayableRememberedMusicSession)
        XCTAssertEqual(ListeningIntentService.shared.resumeSongCount(player: player), 3)
        let restored = await player.resumeMusicSession(startPlayback: false)
        XCTAssertTrue(restored)
        XCTAssertFalse(library.isReady)
        XCTAssertEqual(player.queue.map(\.id), ["s2", "s1", "s2", "s4"])
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertEqual(player.currentTime, 42)
        XCTAssertEqual(player.shuffledIndices, [1, 2, 3, 0])
        XCTAssertEqual(player.shufflePosition, 1)
        XCTAssertEqual(player.queueIdentity, identity)
        XCTAssertEqual(player.repeatMode, .all)
    }

    @MainActor
    func testColdResumeUsesInstalledQueueOnlyAfterCheckingTheSavedSongs() async throws {
        var catalog = songs(3)
        catalog[2].sourceID = "disabled"
        let player = try await makePlayer(librarySongs: catalog, startsPreparing: true)
        let library = try XCTUnwrap(player.library)
        library.updateDisabledSourceIDs(["disabled"])
        player.setQueue(Array(catalog.prefix(2)))
        player.currentSong = catalog[0]
        let store = player.musicSessionMemoryStore
        await store.waitForStartupResumeTarget()
        let intents = ListeningIntentService.shared
        XCTAssertEqual(intents.resumeSongCount(player: player), 2)

        let snapshot = PlaybackSessionSnapshot(queueSongIDs: ["s2"], currentSongID: "s2", currentIndex: 0,
            currentTime: 45, duration: 180, wasPlaying: false, shuffleEnabled: false, shuffledIndices: [],
            shufflePosition: 0, repeatMode: .off, isAtTrackEnd: false)
        store.save(.init(snapshot: snapshot, title: "Song 2", songID: "s2", sourceID: "disabled", savedAt: Date()))
        XCTAssertNil(intents.resumeSongCount(player: player))
        await store.waitForStartupResumeTarget()
        XCTAssertEqual(intents.resumeSongCount(player: player), 2)
        XCTAssertFalse(library.isReady)
    }

    @MainActor
    func testColdRefillKeepsTheCurrentSongAndDoesNotOverwriteANewerQueue() async throws {
        let catalog = songs(750)
        let player = try await makePlayer(librarySongs: catalog, startsPreparing: true)
        let library = try XCTUnwrap(player.library)
        for scope: Set<String>? in [nil, ["local-source"]] {
            player.setQueue(Array(catalog.prefix(12)), startAt: 9)
            player.currentSong = catalog[9]
            player.currentTime = 28
            player.setQueueContinuation(.init(requestedIDs: catalog.map(\.id), window: 0..<12, musicSourceIDs: scope))
            player.refillQueueFromContinuationIfNeeded()
            await player.queueContinuationReadTask?.value
            XCTAssertEqual(player.queueCount, 12 + QueueWindowPolicy.refillBatch)
            XCTAssertEqual(player.queuedSong(at: 12)?.id, catalog[12].id)
            XCTAssertEqual(player.currentIndex, 9)
            XCTAssertEqual(player.currentTime, 28)
            player.currentIndex = player.queueCount - 1
            player.refillQueueFromContinuationIfNeeded()
            let obsolete = player.queueContinuationReadTask
            player.setQueue([catalog[3]])
            await obsolete?.value
            XCTAssertEqual(player.queue.map(\.id), [catalog[3].id])
            XCTAssertNil(player.queueContinuation)
        }
        XCTAssertFalse(library.isReady)
    }

    @MainActor
    func testBookmarkSkipsUnavailableCurrentSongInSavedShuffleOrder() async throws {
        var catalog = songs(5)
        catalog[0].sourceID = "unavailable"
        let player = try await makePlayer(librarySongs: catalog)
        player.setQueue(catalog)
        player.currentSong = catalog[0]
        player.shuffleEnabled = true
        player.shuffledIndices = [2, 0, 4, 1, 3]
        player.shufflePosition = 1
        await player.toggleCurrentQueueBookmark()
        let id = player.queueIdentity
        player.library?.updateDisabledSourceIDs(["unavailable"])
        let restored = await player.resumeQueueBookmark(id, startPlayback: false)
        XCTAssertTrue(restored)
        XCTAssertEqual(player.currentSong?.id, "s4")
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertTrue(player.isCurrentQueueBookmarked)
    }

    @MainActor
    func testRecentMusicQueueSurvivesSingleSongsAndAutoplay() async throws {
        let catalog = songs(8)
        let player = try await makePlayer(librarySongs: catalog)
        player.setQueue(Array(catalog.prefix(4)), startAt: 1)
        player.currentSong = catalog[1]
        player.currentTime = 47
        player.shuffleEnabled = false
        player.insertNextInQueue([catalog[6]])
        XCTAssertTrue(player.removeUpcomingQueueEntry(.init(queueEntryID: player.queueEntries[3].id, roundOffset: 0)))
        XCTAssertTrue(player.moveUpcomingQueueEntry(
            .init(queueEntryID: player.queueEntries[3].id, roundOffset: 0),
            over: .init(queueEntryID: player.queueEntries[2].id, roundOffset: 0)
        ))
        player.persistPlaybackSession()
        let adjusted = player.queue.map(\.id)
        XCTAssertEqual(adjusted, [catalog[0].id, catalog[1].id, catalog[3].id, catalog[6].id])

        player.setQueue([catalog[7]], startAt: 0)
        player.currentSong = catalog[7]
        player.currentTime = 0
        // Automatic recommendations add songs without becoming a new user queue.
        player.queueEntries.append(contentsOf: [catalog[4], catalog[5]].map { QueueEntry(song: $0) })
        player.persistPlaybackSession()
        XCTAssertFalse(player.remembersMusicQueue)
        XCTAssertEqual(player.musicSessionMemoryStore.memory?.snapshot.queueSongIDs, adjusted)
        XCTAssertEqual(player.musicSessionMemoryStore.memory?.snapshot.currentTime, 47)

        let restored = await player.resumeMusicSession(startPlayback: false)
        XCTAssertTrue(restored)
        XCTAssertEqual(player.queue.map(\.id), adjusted)
        XCTAssertEqual(player.currentSong?.id, catalog[1].id)
        XCTAssertEqual(player.currentTime, 47)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.musicSessionMemoryStore.memory)
    }

    @MainActor
    func testRecentMusicQueueKeepsDuplicateOccurrenceAndShuffleTraversal() async throws {
        let catalog = songs(5)
        let player = try await makePlayer(librarySongs: catalog)
        let queue = [catalog[0], catalog[1], catalog[0], catalog[2]]
        player.setQueue(queue, startAt: 2)
        player.currentSong = catalog[0]
        player.currentTime = 62
        player.shuffleEnabled = true
        player.repeatMode = .all
        player.shuffledIndices = [1, 3, 2, 0]
        player.shufflePosition = 2
        player.pendingNextShuffleIndices = [2, 0, 3, 1]
        player.setQueue([catalog[4]], startAt: 0)
        player.currentSong = catalog[4]

        let restored = await player.resumeMusicSession(startPlayback: false)
        XCTAssertTrue(restored)
        XCTAssertEqual(player.queue.map(\.id), queue.map(\.id))
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertEqual(player.shuffledIndices, [1, 3, 2, 0])
        XCTAssertEqual(player.shufflePosition, 2)
        XCTAssertEqual(player.pendingNextShuffleIndices, [2, 0, 3, 1])
        XCTAssertEqual(player.repeatMode, .all)
        XCTAssertEqual(player.currentTime, 62)
    }

    @MainActor
    func testSwitchingAndResumingMusicQueuesSwapsTheirOwnProgress() async throws {
        let catalog = songs(6)
        let player = try await makePlayer(librarySongs: catalog)
        let first = Array(catalog.prefix(3))
        let second = [catalog[1], catalog[3], catalog[5]]
        player.setQueue(first, startAt: 1)
        player.currentSong = catalog[1]
        player.currentTime = 47
        player.persistPlaybackSession(flushImmediately: true)
        XCTAssertNil(player.musicSessionMemoryStore.memory)

        // Switching lists can keep the same song and transport.
        player.setQueue(second, startAt: 0)
        let left = try XCTUnwrap(player.musicSessionMemoryStore.memory)
        XCTAssertEqual(left.snapshot.queueSongIDs, first.map(\.id))
        XCTAssertEqual(left.snapshot.currentIndex, 1)
        XCTAssertEqual(left.snapshot.currentTime, 47)
        player.setQueue(second, startAt: 2)
        player.currentSong = catalog[5]
        player.currentTime = 83
        player.persistPlaybackSession(flushImmediately: true)
        XCTAssertEqual(player.musicSessionMemoryStore.memory, left)
        XCTAssertEqual(try player.playbackSessionStore.load()?.currentTime, 83)

        let restoredFirst = await player.resumeMusicSession(startPlayback: false)
        XCTAssertTrue(restoredFirst)
        XCTAssertEqual(player.queue.map(\.id), first.map(\.id))
        XCTAssertEqual(player.currentIndex, 1)
        XCTAssertEqual(player.currentTime, 47)
        let previous = try XCTUnwrap(player.musicSessionMemoryStore.memory)
        XCTAssertEqual(previous.snapshot.queueSongIDs, second.map(\.id))
        XCTAssertEqual(previous.snapshot.currentIndex, 2)
        XCTAssertEqual(previous.snapshot.currentTime, 83)
        let restoredSecond = await player.resumeMusicSession(startPlayback: false)
        XCTAssertTrue(restoredSecond)
        XCTAssertEqual(player.queue.map(\.id), second.map(\.id))
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertEqual(player.currentTime, 83)
    }

    @MainActor
    func testRecentLargeMusicQueueKeepsEditedWindowAndContinuationAcrossRelaunch() async throws {
        let catalog = songs(2_500)
        let player = try await makePlayer(librarySongs: catalog)
        player.setQueue(catalog, startAt: 1_200)
        player.currentSong = catalog[1_200]
        player.currentTime = 38
        player.shuffleEnabled = false
        player.repeatMode = .off
        player.insertNextInQueue([catalog[2_400]])
        let adjusted = player.queue.map(\.id)
        let continuation = try XCTUnwrap(player.queueContinuation)
        player.setQueue([catalog[2]], startAt: 0)
        player.currentSong = catalog[2]
        await player.musicSessionMemoryStore.waitForPendingPersistence()
        let memory = try XCTUnwrap(player.musicSessionMemoryStore.memory)
        XCTAssertEqual(memory.continuation, continuation)
        XCTAssertEqual(memory.snapshot.queueSongIDs, adjusted)

        let restoredPlayer = try await makePlayer(librarySongs: catalog)
        let url = player.playbackSessionStore.url.deletingLastPathComponent().appendingPathComponent("music-memory.json")
        let reloaded = MusicSessionMemoryStore(defaults: try XCTUnwrap(UserDefaults(suiteName: "reload-" + UUID().uuidString)), url: url)
        await reloaded.waitForPendingPersistence()
        restoredPlayer.musicSessionMemoryStore.save(try XCTUnwrap(reloaded.memory))
        let restored = await restoredPlayer.resumeMusicSession(startPlayback: false)
        XCTAssertTrue(restored)
        XCTAssertEqual(restoredPlayer.queue.map(\.id), adjusted)
        XCTAssertEqual(restoredPlayer.currentTime, 38)
        XCTAssertEqual(restoredPlayer.queueContinuation, continuation)
        XCTAssertLessThan(restoredPlayer.queueCount, catalog.count)
        var remainder = continuation
        XCTAssertFalse(remainder.takeNext(maxCount: catalog.count, repeatsAll: false).contains(catalog[2_400].id))
    }

    @MainActor
    func testSingleSongAutoplayRemainsExcludedAfterColdRestore() async throws {
        let catalog = songs(6)
        let player = try await makePlayer(librarySongs: catalog)
        let memorySnapshot = PlaybackSessionSnapshot(
            queueSongIDs: [catalog[4].id, catalog[5].id], currentSongID: catalog[4].id,
            currentIndex: 0, currentTime: 24, duration: 180, wasPlaying: false,
            shuffleEnabled: false, shuffledIndices: [], shufflePosition: 0,
            repeatMode: .off, isAtTrackEnd: false, remembersMusicQueue: true
        )
        let memory = MusicSessionMemoryStore.Memory(snapshot: memorySnapshot, title: catalog[4].title,
            songID: catalog[4].id, sourceID: catalog[4].sourceID, savedAt: Date())
        player.musicSessionMemoryStore.save(memory)
        try player.playbackSessionStore.save(.init(
            queueSongIDs: Array(catalog.prefix(4)).map(\.id), currentSongID: catalog[0].id,
            currentIndex: 0, currentTime: 17, duration: 180, wasPlaying: false,
            shuffleEnabled: false, shuffledIndices: [], shufflePosition: 0,
            repeatMode: .off, isAtTrackEnd: false, remembersMusicQueue: false
        ))
        await player.restorePlaybackSessionIfAvailable(startupSourceIDs: ["local-source"])
        player.persistPlaybackSession()
        XCTAssertFalse(player.remembersMusicQueue)
        XCTAssertEqual(player.musicSessionMemoryStore.memory, memory)
        XCTAssertEqual(player.queueCount, 4)
    }

    @MainActor
    func testRecentMusicQueueIsNotReplacedByPodcastQueue() async throws {
        let catalog = songs(3)
        let player = try await makePlayer(librarySongs: catalog)
        player.setQueue(catalog, startAt: 1)
        player.currentSong = catalog[1]
        player.currentTime = 29
        player.persistPlaybackSession()
        let episodes = (0..<2).map { index in
            Song(id: "podcast:recent-memory-\(index)", title: "Episode \(index)", duration: 300,
                 fileFormat: .mp3, filePath: "/episode/\(index).mp3", sourceID: PodcastPlaybackSong.sourceID)
        }
        player.setQueue(episodes, startAt: 0)
        player.currentSong = episodes[0]
        player.persistPlaybackSession()
        XCTAssertFalse(player.remembersMusicQueue)
        XCTAssertEqual(player.musicSessionMemoryStore.memory?.snapshot.queueSongIDs, catalog.map(\.id))
        XCTAssertEqual(player.musicSessionMemoryStore.memory?.snapshot.currentTime, 29)
    }

    @MainActor
    func testRelaunchKeepsPreviousQueueSeparateFromActiveSession() async throws {
        let catalog = songs(3)
        let player = try await makePlayer(librarySongs: catalog)
        player.setQueue(Array(catalog.prefix(2)), startAt: 0)
        player.currentSong = catalog[0]
        player.currentTime = 10
        player.setQueue(Array(catalog.suffix(2)), startAt: 1)
        player.currentSong = catalog[2]
        await player.musicSessionMemoryStore.waitForPendingPersistence()
        let url = player.playbackSessionStore.url.deletingLastPathComponent().appendingPathComponent("music-memory.json")
        let before = try Data(contentsOf: url)
        for time in 11...30 {
            player.currentTime = Double(time)
            player.persistPlaybackSession()
        }
        await player.musicSessionMemoryStore.waitForPendingPersistence()
        XCTAssertEqual(try Data(contentsOf: url), before)
        player.persistPlaybackSession(flushImmediately: true)
        let saved = try XCTUnwrap(player.musicSessionMemoryStore.memory)
        XCTAssertEqual(saved.snapshot.currentTime, 10)
        let restored = try await makePlayer(librarySongs: catalog, sessionDirectory: url.deletingLastPathComponent())
        await restored.restorePlaybackSessionIfAvailable(startupSourceIDs: ["local-source"])
        await restored.musicSessionMemoryStore.waitForPendingPersistence()
        XCTAssertEqual(restored.queue.map(\.id), catalog.suffix(2).map(\.id))
        XCTAssertEqual(restored.currentTime, 30)
        XCTAssertEqual(restored.musicSessionMemoryStore.memory, saved)
    }

    @MainActor
    func testLegacyActiveQueueIsDiscardedInEitherLoadOrder() async throws {
        let catalog = songs(3)
        let player = try await makePlayer(librarySongs: catalog)
        player.setQueue(catalog, startAt: 1)
        player.currentSong = catalog[1]
        player.currentTime = 21
        player.persistPlaybackSession(flushImmediately: true)
        let snapshot = try XCTUnwrap(player.playbackSessionStore.load())
        let memory = MusicSessionMemoryStore.Memory(snapshot: snapshot, title: catalog[1].title,
            songID: catalog[1].id, sourceID: catalog[1].sourceID, savedAt: Date())
        let directory = player.playbackSessionStore.url.deletingLastPathComponent()
        for loadFirst in [false, true] {
            let url = directory.appendingPathComponent("legacy-memory.json")
            try JSONEncoder().encode(memory).write(to: url)
            let store = MusicSessionMemoryStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)),
                                                url: url)
            if loadFirst { await store.waitForPendingPersistence() }
            store.excludeActiveQueue(catalog.map(\.id))
            await store.waitForPendingPersistence()
            XCTAssertNil(store.memory)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @MainActor
    func testRestoresSavedQueueBeforeFullLibraryAndPreservesNewUserQueue() async throws {
        let catalog = songs(2_500)
        let player = try await makePlayer(librarySongs: catalog, startsPreparing: true)
        let library = try XCTUnwrap(player.library)
        let ids = [catalog[2_400].id, catalog[17].id, "deleted", catalog[1_200].id]
        try player.playbackSessionStore.save(.init(
            queueSongIDs: ids, currentSongID: ids[1], currentIndex: 1,
            currentTime: 47, duration: 180, wasPlaying: true, shuffleEnabled: false,
            shuffledIndices: [], shufflePosition: 0, repeatMode: .off, isAtTrackEnd: false
        ))
        await player.restorePlaybackSessionIfAvailable(startupSourceIDs: ["local-source"])
        XCTAssertFalse(library.isReady)
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertEqual(player.currentSong?.id, catalog[17].id)
        XCTAssertEqual(player.currentTime, 47)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.queueCount, 3)
        XCTAssertEqual(player.queuedSong(at: 0)?.id, catalog[2_400].id)
        player.setQueue([catalog[42]], startAt: 0)
        await player.restorePlaybackSessionIfAvailable(startupSourceIDs: ["local-source"])
        XCTAssertEqual(player.queuedSong(at: 0)?.id, catalog[42].id)
    }

    @MainActor
    func testReadyLibraryRestoreKeepsTheSelectedDuplicateAndSkipsHiddenAndMissingSongs() async throws {
        var catalog = songs(2_501)
        catalog[1].sourceID = "hidden"
        let player = try await makePlayer(librarySongs: catalog)
        let library = try XCTUnwrap(player.library)
        library.updateDisabledSourceIDs(["hidden"])
        XCTAssertNil(library.unobservedVisibleSong(id: catalog[1].id))

        let tail = try XCTUnwrap(catalog.last).id
        let ids = [tail, catalog[1].id, "missing", catalog[0].id, tail]
        try player.playbackSessionStore.save(.init(
            queueSongIDs: ids, currentSongID: tail, currentIndex: 4,
            currentTime: 47, duration: 180, wasPlaying: true, shuffleEnabled: false,
            shuffledIndices: [], shufflePosition: 0, repeatMode: .off, isAtTrackEnd: false
        ))
        await player.restorePlaybackSessionIfAvailable()

        XCTAssertEqual(player.queue.map(\.id), [tail, catalog[0].id, tail])
        XCTAssertEqual(player.currentIndex, 2)
        XCTAssertEqual(player.currentTime, 47)
        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    private func restorePausedAppleMusicQueue(at time: TimeInterval) async throws -> AudioPlayerService {
        let savedCatalog = AppleMusicCatalogPlaybackMemory.shared.songs()
        addTeardownBlock { @MainActor in
            AppleMusicCatalogPlaybackMemory.shared.remember(savedCatalog)
        }
        let sourceID = AppleMusicLibraryIdentity.sourceID
        let catalog = (0..<649).map { index in
            Song(id: "restored-am-\(index)", title: "Track \(index)", duration: 180, fileFormat: .m4a,
                 filePath: "fixture-\(index)", sourceID: sourceID)
        }
        let player = try await makePlayer(librarySongs: catalog, startsPreparing: true)
        try player.playbackSessionStore.save(.init(
            queueSongIDs: catalog.map(\.id), currentSongID: catalog[14].id, currentIndex: 14,
            currentTime: time, duration: 180, wasPlaying: false, shuffleEnabled: false,
            shuffledIndices: [], shufflePosition: 0, repeatMode: .off, isAtTrackEnd: false
        ))
        await player.restorePlaybackSessionIfAvailable(startupSourceIDs: [sourceID])
        XCTAssertEqual(player.queueCount, catalog.count)
        XCTAssertEqual(player.currentIndex, 14)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.activeAppleMusicRequestID)
        return player
    }

    @MainActor
    func testNextFromRestoredAppleMusicQueueBeforePressingPlay() async throws {
        let player = try await restorePausedAppleMusicQueue(at: 0)
        defer { player.stop() }
        let advanced = await player.next()
        XCTAssertTrue(advanced)
        XCTAssertEqual(player.currentIndex, 15)
        XCTAssertEqual(player.currentSong?.id, "restored-am-15")
        XCTAssertNotNil(player.activeAppleMusicRequestID)
    }

    @MainActor
    func testPreviousFromRestoredAppleMusicQueueRestartsThenSkipsBeforePressingPlay() async throws {
        let player = try await restorePausedAppleMusicQueue(at: 47)
        defer { player.stop() }
        let restarted = await player.previous()
        XCTAssertTrue(restarted)
        XCTAssertEqual(player.currentIndex, 14)
        XCTAssertEqual(player.currentTime, 0)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.activeAppleMusicRequestID)

        let movedBack = await player.previous()
        XCTAssertTrue(movedBack)
        XCTAssertEqual(player.currentIndex, 13)
        XCTAssertEqual(player.currentSong?.id, "restored-am-13")
        XCTAssertNotNil(player.activeAppleMusicRequestID)
    }

    @MainActor
    func testStartupRestorationDoesNotRestoreRemovedSource() async throws {
        let song = songs(1)[0]
        let player = try await makePlayer(librarySongs: [song], startsPreparing: true)
        try player.playbackSessionStore.save(.init(
            queueSongIDs: [song.id], currentSongID: song.id, currentIndex: 0,
            currentTime: 0, duration: 180, wasPlaying: false, shuffleEnabled: false,
            shuffledIndices: [], shufflePosition: 0, repeatMode: .off, isAtTrackEnd: false
        ))
        await player.restorePlaybackSessionIfAvailable(startupSourceIDs: [])
        XCTAssertNil(player.currentSong)
        XCTAssertEqual(player.queueCount, 0)
        XCTAssertFalse(try XCTUnwrap(player.library).isReady)
    }

    @MainActor
    func testRadioSessionReplacesMusicAndRestoresPausedWithoutLibrary() async throws {
        let previousMusicMemory = MusicSessionMemoryStore.shared.memory
        defer {
            if let previousMusicMemory { MusicSessionMemoryStore.shared.save(previousMusicMemory) }
            else { MusicSessionMemoryStore.shared.clear() }
        }
        let player = try await makePlayer(librarySongs: [])
        let music = songs(1)[0]
        player.currentSong = music
        player.persistPlaybackSession(flushImmediately: true)
        let stations = [
            RadioStation(name: "First", streamURL: "https://radio.invalid/first.mp3"),
            RadioStation(name: "Second", streamURL: "https://radio.invalid/second.aac", streamFormat: .aac)
        ]
        player.playbackKind = .liveRadio
        player.currentRadioStation = stations[1]
        player.radioStationOrder = stations
        player.currentSong = stations[1].playbackSong
        player.currentTime = 124
        player.persistPlaybackSession(flushImmediately: true)

        let restored = try await makePlayer(librarySongs: [], includesLibrary: false)
        try Data(contentsOf: player.playbackSessionStore.url).write(to: restored.playbackSessionStore.url)
        await restored.restorePlaybackSessionIfAvailable(radioStations: stations)

        XCTAssertEqual(restored.currentRadioStation?.id, stations[1].id)
        XCTAssertEqual(restored.currentSong?.title, "Second")
        XCTAssertTrue(restored.hasCurrentSong)
        XCTAssertTrue(restored.isLiveRadio)
        XCTAssertTrue(restored.canSwitchRadioStation)
        XCTAssertEqual(restored.radioStationOrder.map(\.id), stations.map(\.id))
        XCTAssertEqual(restored.radioStreamFormat, .aac)
        XCTAssertFalse(restored.isPlaying)
        XCTAssertFalse(restored.isLoading)
        XCTAssertFalse(restored.playbackCapabilities.canSeek)
        XCTAssertEqual(restored.currentTime, 0)
        XCTAssertEqual(restored.queueCount, 0)
        XCTAssertEqual(restored.playbackSessionRestoreLifecycle.phase, .completed)
        assertLaunchAutoplayChoices(restored)
    }

    @MainActor
    func testDeletedAndDisabledRadioStationsAreNotRestored() async throws {
        for deleted in [false, true] {
            let station = RadioStation(name: "Server radio", streamURL: "",
                                       sourceID: "removed-source", serverStationID: "station",
                                       sourcePlaybackPath: "/radio/station")
            let player = try await makePlayer(librarySongs: [])
            player.playbackKind = .liveRadio
            player.currentRadioStation = station
            player.currentSong = station.playbackSong
            player.persistPlaybackSession(flushImmediately: true)
            let restored = try await makePlayer(librarySongs: [])
            try Data(contentsOf: player.playbackSessionStore.url).write(to: restored.playbackSessionStore.url)
            var latest = station
            latest.isDeleted = deleted
            await restored.restorePlaybackSessionIfAvailable(
                startupSourceIDs: deleted ? ["removed-source"] : [], radioStations: [latest]
            )
            XCTAssertNil(restored.currentSong)
            XCTAssertFalse(restored.hasCurrentSong)
        }
    }

    @MainActor
    func testPodcastSessionKeepsCurrentEpisodeBeyondFirstHundredAndAppendedQueue() async throws {
        let episodes = (0..<130).map { index in
            PodcastPlaybackSong.song(for: PodcastEpisode(
                id: "podcast:\(UUID().uuidString)", showID: "restore-show", guid: "\(index)",
                title: "Episode \(index)", duration: 1_800,
                enclosureURL: URL(string: "https://podcast.invalid/\(index).mp3")!, firstSeenAt: Date()
            ), show: nil)
        }
        let player = try await makePlayer(librarySongs: [])
        player.setQueue(Array(episodes.prefix(120)), startAt: 110)
        player.currentSong = episodes[110]
        player.appendToQueue(Array(episodes.suffix(10)))
        player.currentTime = 345
        player.duration = 1_800
        player.persistPlaybackSession(flushImmediately: true)

        let restored = try await makePlayer(librarySongs: [], startsPreparing: true)
        try Data(contentsOf: player.playbackSessionStore.url).write(to: restored.playbackSessionStore.url)
        await restored.restorePlaybackSessionIfAvailable()

        XCTAssertFalse(try XCTUnwrap(restored.library).isReady)
        XCTAssertEqual(restored.currentSong?.id, episodes[110].id)
        XCTAssertEqual(restored.currentTime, 345)
        XCTAssertEqual(restored.queueCount, 130)
        XCTAssertEqual(restored.queue.map(\.id), player.queue.map(\.id))
        XCTAssertTrue(restored.currentItemIsSpokenWord)
        XCTAssertTrue(restored.hasCurrentSong)
        XCTAssertFalse(restored.isPlaying)
        XCTAssertEqual(restored.pendingRecoveryTime, 345)
        XCTAssertTrue(restored.needsPlaybackRecovery)
        XCTAssertEqual(restored.playbackSessionRestoreLifecycle.phase, .completed)
        assertLaunchAutoplayChoices(restored)
    }

    @MainActor
    func testAudiobookAndLocalPodcastRestoreChapterAndPositionBeforeLibraryReady() async throws {
        for genre in ["Audiobook", "Podcast"] {
            var chapters = songs(3)
            for index in chapters.indices { chapters[index].genre = genre }
            let player = try await makePlayer(librarySongs: [])
            player.setQueue(chapters, startAt: 1)
            player.currentSong = chapters[1]
            player.currentTime = 76
            player.duration = 180
            player.persistPlaybackSession(flushImmediately: true)
            let restored = try await makePlayer(librarySongs: chapters, startsPreparing: true)
            try Data(contentsOf: player.playbackSessionStore.url).write(to: restored.playbackSessionStore.url)
            await restored.restorePlaybackSessionIfAvailable(startupSourceIDs: ["local-source"])

            XCTAssertFalse(try XCTUnwrap(restored.library).isReady)
            XCTAssertEqual(restored.currentSong?.id, chapters[1].id)
            XCTAssertEqual(restored.currentIndex, 1)
            XCTAssertEqual(restored.currentTime, 76)
            XCTAssertEqual(restored.pendingRecoveryTime, 76)
            XCTAssertTrue(restored.currentItemIsSpokenWord)
            XCTAssertTrue(restored.hasCurrentSong)
            XCTAssertFalse(restored.isPlaying)
            XCTAssertEqual(restored.queue.map(\.id), chapters.map(\.id))
            assertLaunchAutoplayChoices(restored)
        }
    }

    @MainActor
    private func assertLaunchAutoplayChoices(_ player: AudioPlayerService) {
        let restoredLifecycle = player.playbackSessionRestoreLifecycle
        XCTAssertFalse(player.takeRestoredSessionAutoplayDecision(enabled: false, isForeground: true))
        player.playbackSessionRestoreLifecycle = restoredLifecycle
        XCTAssertFalse(player.takeRestoredSessionAutoplayDecision(enabled: true, isForeground: false))
        XCTAssertTrue(player.takeRestoredSessionAutoplayDecision(enabled: true, isForeground: true))
        XCTAssertFalse(player.takeRestoredSessionAutoplayDecision(enabled: true, isForeground: true))
        player.playbackSessionRestoreLifecycle = restoredLifecycle
        player.registerPauseOrStopIntent()
        XCTAssertFalse(player.takeRestoredSessionAutoplayDecision(enabled: true, isForeground: true))
    }

    @MainActor
    func testPlaybackPresenceDoesNotInvalidateChromeOnTrackOrMetadataChanges() async throws {
        let player = try await makePlayer(librarySongs: [])
        let changes = OSAllocatedUnfairLock(initialState: 0)
        func observePresence() {
            withObservationTracking {
                _ = player.hasCurrentSong
            } onChange: {
                changes.withLock { $0 += 1 }
            }
        }

        XCTAssertFalse(player.hasCurrentSong)
        observePresence()
        player.currentSong = songs(2)[0]
        XCTAssertTrue(player.hasCurrentSong)
        XCTAssertEqual(changes.withLock { $0 }, 1)

        observePresence()
        player.currentSong = songs(2)[1]
        var updated = try XCTUnwrap(player.currentSong)
        updated.title = "Updated title"
        player.currentSong = updated
        XCTAssertTrue(player.hasCurrentSong)
        XCTAssertEqual(changes.withLock { $0 }, 1)

        player.currentSong = nil
        XCTAssertFalse(player.hasCurrentSong)
        XCTAssertEqual(changes.withLock { $0 }, 2)
        observePresence()
        player.currentSong = nil
        XCTAssertEqual(changes.withLock { $0 }, 2)
    }

    @MainActor
    func testRestoringPausedSessionReplacesStalePlayingWidgetSnapshot() async throws {
        let shared = try XCTUnwrap(UserDefaults(suiteName: PrimuseConstants.appGroupIdentifier))
        let keys = [PrimuseConstants.widgetSyncEnabledKey, PrimuseConstants.widgetNowPlayingEnabledKey,
                    PrimuseConstants.widgetLyricsEnabledKey, PrimuseConstants.widgetRecentAlbumsEnabledKey,
                    PrimuseConstants.widgetSharedDataScopeKey, PrimuseConstants.playbackStateKey,
                    PrimuseConstants.lyricsSnapshotKey]
        let savedDefaults = keys.map { ($0, shared.object(forKey: $0)) }
        let coverURL = try XCTUnwrap(FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        )).appendingPathComponent("widget_cover.png")
        let savedCover = try? Data(contentsOf: coverURL)
        defer {
            for (key, value) in savedDefaults { shared.set(value, forKey: key) }
            if let savedCover { try? savedCover.write(to: coverURL, options: .atomic) }
        }
        shared.set(true, forKey: PrimuseConstants.widgetSyncEnabledKey)
        shared.set(true, forKey: PrimuseConstants.widgetNowPlayingEnabledKey)
        shared.set(true, forKey: PrimuseConstants.widgetRecentAlbumsEnabledKey)
        shared.set(false, forKey: PrimuseConstants.widgetLyricsEnabledKey)
        shared.set(WidgetSharedDataScope.titleArtistCoverProgress.rawValue,
                   forKey: PrimuseConstants.widgetSharedDataScopeKey)

        let song = Song(id: "restored-widget-\(UUID().uuidString)", title: "Restored song",
                        duration: 180, fileFormat: .flac,
                        filePath: "/music/restored.flac", sourceID: "local-source")
        let player = try await makePlayer(librarySongs: [song])
        try player.playbackSessionStore.save(.init(
            queueSongIDs: [song.id], currentSongID: song.id, currentIndex: 0,
            currentTime: 47, duration: 180, wasPlaying: true, shuffleEnabled: false,
            shuffledIndices: [], shufflePosition: 0, repeatMode: .off, isAtTrackEnd: false
        ))
        PlaybackState(currentSongID: song.id, isPlaying: true, currentTime: 30, duration: 180,
                      updatedAt: Date().addingTimeInterval(-60)).save()

        let restoreStartedAt = Date()
        await player.restorePlaybackSessionIfAvailable()

        XCTAssertFalse(player.isPlaybackActive)
        XCTAssertEqual(player.currentSong?.id, song.id)
        XCTAssertTrue(player.hasCurrentSong)
        XCTAssertEqual(player.currentTime, 47)
        let widget = try XCTUnwrap(PlaybackState.load())
        XCTAssertEqual(widget.currentSongID, song.id)
        XCTAssertFalse(widget.isPlaying, "A cold restore must replace the previous process's playing state")
        XCTAssertEqual(widget.currentTime, 47)
        XCTAssertEqual(widget.duration, 180)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(widget.updatedAt), restoreStartedAt)
    }

    @MainActor
    func testLargeRequestInstallsAWindowAroundTheSelectedSong() async throws {
        let request = songs(2_500)
        let player = try await makePlayer(librarySongs: [])
        player.setQueue(request, startAt: 1_200)

        XCTAssertEqual(player.queueCount, QueueWindowPolicy.windowLimit)
        XCTAssertEqual(player.queuedSong(at: player.currentIndex)?.id, "s1200")
        XCTAssertEqual(player.currentIndex, QueueWindowPolicy.leadingHistory)
        XCTAssertEqual(player.queueContinuation?.requestedIDs.count, 2_500)

        player.setQueue(Array(request.prefix(10)), startAt: 0)
        XCTAssertEqual(player.queueCount, 10)
        XCTAssertNil(player.queueContinuation)
    }

    @MainActor
    func testWholeLibraryRequestIsPlannedFromTheVisibleLookup() async throws {
        let request = songs(2_500)
        let player = try await makePlayer(librarySongs: request)
        let library = try XCTUnwrap(player.library)
        let lookup = library.visibleSongLookup()
        let prepared = LargeQueueRequestPlanner.plan(
            ids: request.map(\.id) + ["missing"],
            startIndex: 0,
            order: .shuffled,
            includes: { lookup.contains(id: $0, playableOnly: true) },
            resolve: { lookup.song(id: $0) }
        )
        XCTAssertEqual(prepared?.items.count, QueueWindowPolicy.windowLimit)
        XCTAssertEqual(prepared?.selectedIndex, 0)
        XCTAssertEqual(prepared?.continuation?.requestedIDs.count, 2_500)
        XCTAssertEqual(Set(prepared?.continuation?.requestedIDs ?? []), Set(request.map(\.id)))
    }

    @MainActor
    func testSingleSourceListsMatchTheVisibleLibrary() async throws {
        let request = songs(40)
        let player = try await makePlayer(librarySongs: request)
        let library = try XCTUnwrap(player.library)
        let visibleIDs = library.visibleSongs.map(\.id)
        XCTAssertEqual(library.visibleSongs(forSourceID: "local-source").map(\.id), visibleIDs)
        XCTAssertEqual(library.playableSongs(forSourceID: "local-source").map(\.id), visibleIDs)
        XCTAssertTrue(library.sourceIDsWithPlayableSongs.contains("local-source"))
    }

    @MainActor
    func testRefillAppendsTheNextSongsInOrderNearTheEndOfTheWindow() async throws {
        let request = songs(2_500)
        let player = try await makePlayer(librarySongs: request)
        player.setQueue(request, startAt: 0)
        player.shuffleEnabled = false
        player.repeatMode = .off
        XCTAssertEqual(player.queueCount, 1_000)

        // Plenty left ahead: nothing to do.
        player.currentIndex = 500
        player.refillQueueFromContinuationIfNeeded()
        XCTAssertEqual(player.queueCount, 1_000)

        player.currentIndex = 850
        player.refillQueueFromContinuationIfNeeded()
        XCTAssertEqual(player.queueCount, 1_000 + QueueWindowPolicy.refillBatch)
        XCTAssertEqual(player.queuedSong(at: 1_000)?.id, "s1000")
        XCTAssertEqual(player.queuedSong(at: 1_499)?.id, "s1499")

        player.currentIndex = 1_400
        player.refillQueueFromContinuationIfNeeded()
        player.currentIndex = 1_900
        player.refillQueueFromContinuationIfNeeded()
        XCTAssertEqual(player.queue.map(\.id), request.map(\.id))
        XCTAssertNil(player.queueContinuation, "a fully handed-out request without repeat is done")
    }

    @MainActor
    func testChoosingShuffleLeavesEachTrackStopsEvenWhenShuffleWasAlreadyEnabled() async throws {
        let request = songs(3)
        let player = try await makePlayer(librarySongs: request)
        player.setQueue(request, startAt: 0)
        for stop in [RepeatBehavior.playOnce, .trackByTrack] {
            for alreadyShuffled in [false, true] {
                player.shuffleEnabled = alreadyShuffled
                player.repeatBehavior = stop
                XCTAssertTrue(player.holdsQueueAtCurrentTrackEnd)
                player.shuffleEnabled = true
                XCTAssertTrue(player.shuffleEnabled)
                XCTAssertEqual(player.repeatBehavior, .off)
                XCTAssertFalse(player.holdsQueueAtCurrentTrackEnd)
                XCTAssertNotNil(player.nextSongInQueue())
                XCTAssertFalse(player.stopForTrackEndIfNeeded())
            }
        }
        player.repeatBehavior = .all
        player.shuffleEnabled = false
        XCTAssertEqual(player.repeatBehavior, .all)
        XCTAssertFalse(player.shuffleEnabled)

        for protectedUpdate in 0..<3 {
            player.repeatBehavior = .trackByTrack
            player.isRestoringPlaybackSession = protectedUpdate == 0
            player.isApplyingListeningPlayMode = protectedUpdate == 1
            player.isMirroringFromAppleMusic = protectedUpdate == 2
            player.shuffleEnabled = true
            XCTAssertEqual(player.repeatBehavior, .trackByTrack, "Restoring or mirroring must preserve explicit per-track stops")
            player.isRestoringPlaybackSession = false
            player.isApplyingListeningPlayMode = false
            player.isMirroringFromAppleMusic = false
        }
    }

    @MainActor
    func testEachTrackStopsKeepDifferentResumeTargetsInSequentialAndShuffleOrder() async throws {
        let request = songs(3)
        let player = try await makePlayer(librarySongs: request)
        for shuffled in [false, true] {
            for behavior in [RepeatBehavior.playOnce, .trackByTrack] {
                player.setQueue(request, startAt: 0)
                player.currentSong = request[0]
                player.shuffleEnabled = shuffled
                player.repeatBehavior = behavior
                let expectedID = behavior == .playOnce ? request[0].id : player.nextSongInQueue()?.id
                XCTAssertTrue(player.stopForTrackEndIfNeeded())
                XCTAssertFalse(player.isPlaying)
                XCTAssertTrue(player.isAtTrackEnd)
                XCTAssertEqual(player.currentSong?.id, expectedID)
                XCTAssertEqual(player.repeatBehavior, behavior)
            }
        }
    }

    @MainActor
    func testShuffleRefillExtendsTheOrderWithoutReplayingTheHeardPart() async throws {
        let request = songs(2_000)
        let player = try await makePlayer(librarySongs: request)
        player.setQueue(request, startAt: 0)
        // The listening-space play mode may have set shuffle either way.
        player.shuffleEnabled = false
        player.shuffleEnabled = true
        XCTAssertEqual(player.shuffledIndices.count, 1_000)

        player.shufflePosition = 900
        player.currentIndex = player.shuffledIndices[900]
        let heardAndCurrent = Array(player.shuffledIndices[...900])
        player.refillQueueFromContinuationIfNeeded()

        XCTAssertEqual(player.queueCount, 1_500)
        XCTAssertEqual(Array(player.shuffledIndices[...900]), heardAndCurrent)
        XCTAssertEqual(Set(player.shuffledIndices), Set(0..<1_500))
        XCTAssertEqual(player.shuffledIndices.count, 1_500)
        XCTAssertEqual(Set(player.shuffledIndices[1_000...]), Set(1_000..<1_500))
    }

    @MainActor
    func testShufflePreferenceKeepsTheCurrentSongFirstAndFavorsLeastPlayed() async throws {
        // 前 20 首服务器上各播过 50 次, 后 20 首没播过。
        var request = songs(40)
        for index in 0..<20 { request[index].serverPlayCount = 50 }
        let player = try await makePlayer(librarySongs: request)
        player.playbackSettings.shufflePreference = .rareSongs
        player.setQueue(request, startAt: 5)
        player.shuffleEnabled = false
        player.shuffleEnabled = true

        XCTAssertEqual(player.shuffledIndices.first, 5, "the playing song stays first")
        XCTAssertEqual(player.shufflePosition, 0)
        XCTAssertNil(player.pendingNextShuffleIndices)
        XCTAssertEqual(player.shuffledIndices.count, 40)
        XCTAssertEqual(Set(player.shuffledIndices), Set(0..<40))
        // 权重 1 对 1/51: 接下来的 19 首几乎都是没播过的那一半。
        let upcoming = player.shuffledIndices.dropFirst().prefix(19)
        XCTAssertGreaterThanOrEqual(upcoming.filter { $0 >= 20 }.count, 15)

        let order = player.shufflePlayOrder(request)
        XCTAssertEqual(Set(order.map(\.id)), Set(request.map(\.id)))
        XCTAssertEqual(order.count, request.count)
    }

    @MainActor
    func testRebuildingTheCurrentQueueKeepsTheContinuationAndClearingDropsIt() async throws {
        let request = songs(3_000)
        let player = try await makePlayer(librarySongs: [])
        player.setQueue(request, startAt: 0)
        let continuation = try XCTUnwrap(player.queueContinuation)

        let withoutOne = player.queue.filter { $0.id != "s5" }
        player.setQueue(withoutOne, startAt: 0, keepsContinuation: true)
        XCTAssertEqual(player.queueContinuation, continuation)
        XCTAssertEqual(player.queueCount, 999)

        player.clearQueue()
        XCTAssertNil(player.queueContinuation)
    }

    /// 封面流(#191)两侧与连按上一首 / 下一首走同一条路：顺序播放按队列，随机按本轮顺序；往回走到队首就停。
    @MainActor
    func testAlbumFlowNeighboursFollowTheTraversalOrder() async throws {
        let request = songs(8)
        let player = try await makePlayer(librarySongs: request)
        player.setQueue(request, startAt: 3)
        player.shuffleEnabled = false
        player.repeatMode = .off

        let ordered = player.albumFlowNeighbors(perSide: 3)
        XCTAssertEqual(ordered.before.map(\.song.id), ["s2", "s1", "s0"])
        XCTAssertEqual(ordered.after.map(\.song.id), ["s4", "s5", "s6"])
        XCTAssertEqual(ordered.centerID, player.queueEntries[3].id.uuidString)
        XCTAssertEqual(ordered.itemID(at: 1), player.queueEntries[4].id.uuidString)

        player.currentIndex = 0
        XCTAssertTrue(player.albumFlowNeighbors(perSide: 3).before.isEmpty, "the left side does not wrap to the end")
        player.repeatMode = .all
        player.currentIndex = 7
        XCTAssertTrue(player.albumFlowNeighbors(perSide: 3).after.isEmpty, "the right side stays within this round")
        player.repeatMode = .off

        player.currentIndex = 0
        player.shuffleEnabled = true
        let upcoming = player.upcomingQueueTraversalTargets(
            maximumCount: 3,
            respectsRepeatOne: false,
            wrapsAtEnd: false
        )
        player.applyQueueTraversalTarget(try XCTUnwrap(upcoming.last))
        let round = player.shuffledIndices
        let position = try XCTUnwrap(player.shuffleAnchorPosition)
        let shuffled = player.albumFlowNeighbors(perSide: 3)
        XCTAssertEqual(
            shuffled.before.map(\.song.id),
            (0..<position).reversed().prefix(3).map { request[round[$0]].id }
        )
        XCTAssertEqual(
            shuffled.after.map(\.song.id),
            round.dropFirst(position + 1).prefix(3).map { request[$0].id }
        )
        XCTAssertEqual(
            player.previousQueueTraversalTargets(maximumCount: 1).first?.queueIndex,
            player.previousQueueTraversalTarget()?.queueIndex,
            "the first card on the left is where previous goes"
        )
    }

    @MainActor
    func testFullScanPruneRemovesStaleSongsFromQueueContinuationAndRememberedMemory() async throws {
        let catalog = songs(5)
        let otherSong = Song(
            id: "other-1",
            title: "Other Source Track",
            duration: 180,
            fileFormat: .flac,
            filePath: "/other/1.flac",
            sourceID: "other-source"
        )
        let player = try await makePlayer(librarySongs: catalog)
        let library = try XCTUnwrap(player.library)
        library.addSongs([otherSong], affectedSourceIDs: ["other-source"])
        await library.waitForPendingIndex()

        // Save a remembered music queue containing songs that will later disappear.
        player.setQueue([catalog[0], catalog[1], catalog[2]], startAt: 0)
        player.currentSong = catalog[0]
        player.currentTime = 24
        player.rememberCurrentMusicQueue()
        XCTAssertEqual(player.musicSessionMemoryStore.memory?.snapshot.queueSongIDs, ["s0", "s1", "s2"])

        // Install an active queue with a stale pre-existing song + continuation + other-source song.
        let preExistingStale = Song(
            id: "stale-ghost",
            title: "Ghost",
            duration: 180,
            fileFormat: .flac,
            filePath: "/music/ghost.flac",
            sourceID: "local-source"
        )
        player.setQueue([preExistingStale, catalog[0], catalog[3], otherSong], startAt: 1)
        player.stagePausedHandoff(song: catalog[0], at: 15)
        player.setQueueContinuation(QueueContinuation(
            requestedIDs: ["s0", "s1", "s3", "s4", "stale-ghost"],
            window: 0..<2
        ))

        // Full scan of local-source keeps only s3 and s4 (prunes s0, s1, s2, plus sweeps stale-ghost).
        library.addSongs(
            [catalog[3], catalog[4]],
            affectedSourceIDs: ["local-source"],
            notifyRemovals: true,
            pruneMissingSongs: true
        )
        await player.waitForLibraryReconciliation()

        XCTAssertEqual(player.queue.map(\.id), ["s3", "other-1"])
        XCTAssertEqual(player.currentSong?.id, "s3")
        XCTAssertEqual(player.queueContinuation?.requestedIDs, ["s3", "s4"])
        XCTAssertNil(player.musicSessionMemoryStore.memory, "Remembered queue whose songs were all removed must be cleared")

        // Now prune all remaining local-source songs when only local-source songs remain in the queue:
        // queue must stop and clear WITHOUT re-saving deleted songs into musicSessionMemoryStore.
        player.setQueue([catalog[3], catalog[4]], startAt: 0)
        player.stagePausedHandoff(song: catalog[3], at: 10)
        library.addSongs(
            [],
            affectedSourceIDs: ["local-source"],
            notifyRemovals: true,
            pruneMissingSongs: true
        )
        await player.waitForLibraryReconciliation()

        XCTAssertTrue(player.queue.isEmpty)
        XCTAssertNil(player.currentSong)
        XCTAssertNil(player.queueContinuation)
        XCTAssertNil(player.musicSessionMemoryStore.memory)
    }

    @MainActor
    func testServerFilePathRefreshPersistsPathAndBareMergePreservesServerPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerFilePathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cleanups.append { try? FileManager.default.removeItem(at: directory) }

        let library = MusicLibrary(storageDirectory: directory)
        await library.whenReady()
        let source = MusicSource(
            id: "srv-path-source",
            name: "Navidrome",
            type: .navidrome,
            host: "music.example.com",
            port: 443,
            useSsl: true,
            username: "tester"
        )
        let existing = Song(
            id: "srv-song-1",
            title: "Track One",
            duration: 215,
            fileFormat: .flac,
            filePath: "/songs/42.flac",
            sourceID: source.id,
            bitRate: 1_024
        )
        library.addSongs([existing], affectedSourceIDs: [source.id])
        await library.waitForPendingIndex()
        XCTAssertNil(SongPathPresentationPolicy.displayPath(for: try XCTUnwrap(library.storedSong(id: existing.id)), sourceType: .navidrome))

        // Bare-row merge with mergeServerCatalogRows: false must still adopt incoming serverFilePath.
        let bareWithPath = Song(
            id: existing.id,
            title: existing.title,
            duration: 0,
            fileFormat: .flac,
            filePath: existing.filePath,
            sourceID: source.id,
            serverFilePath: "42.flac"
        )
        library.addSongs([bareWithPath], affectedSourceIDs: [source.id], mergeServerCatalogRows: false)
        XCTAssertEqual(library.storedSong(id: existing.id)?.serverFilePath, "42.flac")

        // On-demand server path refresh upgrades bare filename to full server path and persists into MusicLibrary.
        let manager = SourceManager(sourcesProvider: { [source] })
        let stub = StubServerSongPathConnector(sourceID: source.id, resolvedPath: "/music/Artist/Album/01 - Track One.flac")
        let resolved = await manager.refreshServerFilePath(
            for: try XCTUnwrap(library.storedSong(id: existing.id)),
            in: library,
            source: source,
            connectorOverride: stub
        )
        XCTAssertEqual(resolved, "/music/Artist/Album/01 - Track One.flac")
        XCTAssertEqual(library.storedSong(id: existing.id)?.serverFilePath, "/music/Artist/Album/01 - Track One.flac")
        let fetchCount = await stub.fetchCount
        XCTAssertEqual(fetchCount, 1)

        // Second call sees full path with "/" and skips network.
        let cached = await manager.refreshServerFilePath(
            for: try XCTUnwrap(library.storedSong(id: existing.id)),
            in: library,
            source: source,
            connectorOverride: stub
        )
        XCTAssertEqual(cached, "/music/Artist/Album/01 - Track One.flac")
        let fetchCountAfter = await stub.fetchCount
        XCTAssertEqual(fetchCountAfter, 1)

        // FnMusic /track/metadata extraction prefers audioSpec.path and rejects online tracks.
        let fnPayload: [String: Any] = [
            "track": ["guid": "g1", "filename": "01.flac", "is_online": false],
            "audioSpec": ["path": "/vol1/1000/Music/Album/01.flac"],
        ]
        XCTAssertEqual(
            FnMusicAPI.extractTrackServerFilePath(from: fnPayload, expectedGUID: "g1"),
            "/vol1/1000/Music/Album/01.flac"
        )
        let fnOnlinePayload: [String: Any] = [
            "track": ["guid": "g2", "is_online": true],
            "audioSpec": ["path": "/vol1/1000/Music/Online.flac"],
        ]
        XCTAssertNil(FnMusicAPI.extractTrackServerFilePath(from: fnOnlinePayload, expectedGUID: "g2"))
    }
}

private actor StubServerSongPathConnector: ServerSongPathProvidingConnector {
    let sourceID: String
    let resolvedPath: String?
    private(set) var fetchCount = 0

    init(sourceID: String, resolvedPath: String?) {
        self.sourceID = sourceID
        self.resolvedPath = resolvedPath
    }

    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func streamingURL(for path: String) async throws -> URL? { nil }
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data { Data() }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func imageURL(for path: String) async throws -> URL? { nil }

    func fetchServerFilePath(for path: String) async throws -> String? {
        fetchCount += 1
        return resolvedPath
    }
}
