import Foundation
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
    private func makePlayer(librarySongs: [Song]) async throws -> AudioPlayerService {
        let suite = "queue-window-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        cleanups.append {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"))
        if !librarySongs.isEmpty {
            library.addSongs(librarySongs, affectedSourceIDs: ["local-source"])
            for _ in 0..<500 where library.unobservedVisibleSong(id: librarySongs.last!.id) == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(library.unobservedVisibleSong(id: librarySongs.last!.id))
        }
        return AudioPlayerService(
            library: library,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Queue tests must not start audio") }
        )
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
}
