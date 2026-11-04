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
    private func makePlayer(librarySongs: [Song], startsPreparing: Bool = false, includesLibrary: Bool = true) async throws -> AudioPlayerService {
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
        return AudioPlayerService(
            library: includesLibrary ? library : nil,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Queue tests must not start audio") }
        )
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
}
