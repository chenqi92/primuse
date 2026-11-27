import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// #166: a music queue that runs out keeps going with similar songs, shown
/// under the autoplay divider; the listener's own additions play first.
final class AutoContinuationPlayerTests: XCTestCase {
    private var cleanups: [() -> Void] = []

    override func tearDown() {
        cleanups.forEach { $0() }
        cleanups = []
        super.tearDown()
    }

    private func song(_ id: String, artist: String, album: String, genre: String, track: Int) -> Song {
        Song(
            id: id, title: "Song \(id)", albumID: "album-\(album)", albumTitle: album, artistName: artist,
            trackNumber: track, duration: 200, fileFormat: .flac,
            filePath: "/\(artist)/\(album)/\(id).flac", sourceID: "local-source", genre: genre, year: 2001
        )
    }

    private var library: [Song] {
        var songs: [Song] = []
        for track in 0..<7 { songs.append(song("faye\(track)", artist: "Faye", album: "Blue", genre: "Jazz", track: track + 1)) }
        for track in 0..<7 { songs.append(song("faye-b\(track)", artist: "Faye", album: "Green", genre: "Jazz", track: track + 1)) }
        for index in 0..<30 { songs.append(song("rock\(index)", artist: "Band \(index % 6)", album: "Loud \(index % 6)", genre: "Rock", track: index)) }
        return songs
    }

    @MainActor
    private func makePlayer() async throws -> AudioPlayerService {
        let suite = "auto-continuation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        cleanups.append {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let songs = library
        let musicLibrary = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"))
        musicLibrary.addSongs(songs, affectedSourceIDs: ["local-source"])
        for _ in 0..<500 where musicLibrary.unobservedVisibleSong(id: songs.last!.id) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(musicLibrary.unobservedVisibleSong(id: songs.last!.id))
        let player = AudioPlayerService(
            library: musicLibrary,
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Queue tests must not start audio") }
        )
        player.shuffleEnabled = false
        player.repeatMode = .off
        return player
    }

    @MainActor
    private func continueQueue(_ player: AudioPlayerService) async {
        player.scheduleAutoContinuationIfNeeded()
        await player.autoContinuationTask?.value
    }

    @MainActor
    func testOneSongQueueIsFollowedBySimilarSongsUnderAutoplay() async throws {
        let player = try await makePlayer()
        let seed = try XCTUnwrap(player.library?.unobservedVisibleSong(id: "faye0"))
        player.setQueue([seed], startAt: 0)
        XCTAssertEqual(player.autoContinuationDecision, .similarSongs)

        await continueQueue(player)

        let added = Array(player.queueEntries.dropFirst())
        XCTAssertFalse(added.isEmpty)
        XCTAssertLessThanOrEqual(added.count, QueueContinuationPolicy.batchSize)
        XCTAssertTrue(added.allSatisfy { player.isAutoContinuationEntry($0) })
        XCTAssertFalse(added.contains { $0.song.id == seed.id })
        XCTAssertEqual(Set(added.map(\.song.id)).count, added.count)
        // The most similar come first: the same artist, then variety.
        XCTAssertEqual(added.first?.song.artistName, "Faye")
        XCTAssertLessThanOrEqual(added.filter { $0.song.albumTitle == "Blue" }.count, 3)
        XCTAssertLessThanOrEqual(added.filter { $0.song.artistName == "Faye" }.count, 5)

        let upNext = QueueContinuationPolicy.splitUpcoming(player.upcomingQueueEntries) {
            player.isAutoContinuationEntry($0.entry)
        }
        XCTAssertTrue(upNext.queued.isEmpty)
        XCTAssertEqual(upNext.autoplay.count, added.count)

        // Songs the listener queues play before the autoplay songs.
        let extra = try XCTUnwrap(player.library?.unobservedVisibleSong(id: "rock29"))
        player.appendToQueue([extra])
        XCTAssertEqual(player.queuedSong(at: 1)?.id, extra.id)
        XCTAssertFalse(player.isAutoContinuationEntry(player.queueEntries[1]))

        // The queue has songs ahead now: nothing more is added.
        player.scheduleAutoContinuationIfNeeded()
        XCTAssertNil(player.autoContinuationTask)
    }

    @MainActor
    func testQueueEndsAsBeforeWhenSwitchedOffRepeatingOrShuffling() async throws {
        let player = try await makePlayer()
        let seed = try XCTUnwrap(player.library?.unobservedVisibleSong(id: "faye0"))
        player.setQueue([seed], startAt: 0)

        player.playbackSettings.autoContinueSimilarEnabled = false
        player.scheduleAutoContinuationIfNeeded()
        XCTAssertNil(player.autoContinuationTask)

        player.playbackSettings.autoContinueSimilarEnabled = true
        player.repeatMode = .all
        player.scheduleAutoContinuationIfNeeded()
        XCTAssertNil(player.autoContinuationTask)

        // Shuffle keeps its own library continuation.
        player.shuffleEnabled = true
        player.repeatMode = .off
        XCTAssertEqual(player.autoContinuationDecision, .shuffleFromLibrary)
        player.scheduleAutoContinuationIfNeeded()
        XCTAssertNil(player.autoContinuationTask)
        XCTAssertEqual(player.queueCount, 1)
    }

    @MainActor
    func testATopUpStartedBeforeShuffleWasTurnedOnAddsNothing() async throws {
        let player = try await makePlayer()
        let seed = try XCTUnwrap(player.library?.unobservedVisibleSong(id: "faye0"))
        player.setQueue([seed], startAt: 0)
        player.scheduleAutoContinuationIfNeeded()
        XCTAssertNotNil(player.autoContinuationTask)
        player.shuffleEnabled = true
        await player.autoContinuationTask?.value
        XCTAssertTrue(player.autoContinuationEntryIDs.isEmpty)
    }

    @MainActor
    func testANewQueueDropsTheAutoplayMarks() async throws {
        let player = try await makePlayer()
        let seed = try XCTUnwrap(player.library?.unobservedVisibleSong(id: "faye0"))
        player.setQueue([seed], startAt: 0)
        await continueQueue(player)
        XCTAssertFalse(player.autoContinuationEntryIDs.isEmpty)

        let other = try XCTUnwrap(player.library?.unobservedVisibleSong(id: "rock0"))
        player.setQueue([other, seed], startAt: 0)
        XCTAssertTrue(player.autoContinuationEntryIDs.isEmpty)
        XCTAssertEqual(player.autoContinuationDecision, QueueContinuationPolicy.Decision.none)
    }

    /// 歌曲模型放掉之后(P3 步骤 6c):队列后面还有歌时,相似续播和随机续歌都不要歌曲模型;放到最后一首才要,
    /// 只要一次占用。等到模型之前不往队列里加歌,也不把这一首记成「找不到相似的」(空数组不是答案)。
    /// 模型在内存里时两样照旧。
    @MainActor
    func testQueueEndAsksForTheSongModelOnceAndNothingBeforeIt() async throws {
        let player = try await makePlayer()
        let library = try XCTUnwrap(player.library)
        let first = try XCTUnwrap(library.unobservedVisibleSong(id: "faye0"))
        let second = try XCTUnwrap(library.unobservedVisibleSong(id: "faye1"))
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        func holds() -> [MusicLibrary.SongModelHoldReason] {
            (MusicLibrary.songModelHoldRequestsForTesting ?? [])
                .filter { $0.library == ObjectIdentifier(library) }
                .map(\.reason)
        }

        // 模型在内存里:相似续播在最后一首时占用一次(立刻拿到),随机续歌直接续、不经占用。
        player.setQueue([first], startAt: 0)
        await continueQueue(player)
        XCTAssertGreaterThan(player.queueCount, 1)
        XCTAssertEqual(holds(), [.playbackContinuation])
        player.setQueue([first], startAt: 0)
        // 随机续歌只接着音乐续:要有正在放的这一首才认得出是音乐。
        player.currentSong = first
        player.shuffleEnabled = true
        let extendedWhileLoaded = await player.extendExhaustedShuffleHoldingTheSongModel()
        XCTAssertTrue(extendedWhileLoaded)
        XCTAssertGreaterThan(player.queueCount, 1)
        XCTAssertEqual(holds(), [.playbackContinuation])

        MusicLibrary.songModelHoldRequestsForTesting = []
        library.dropSongModelForMeasurement(includingCollections: true)
        XCTAssertFalse(library.isReady)

        // 后面还有歌:两样都什么也不要。
        player.shuffleEnabled = false
        player.setQueue([first, second], startAt: 0)
        player.scheduleAutoContinuationIfNeeded()
        XCTAssertNil(player.autoContinuationTask)
        player.shuffleEnabled = true
        player.setQueue([first, second], startAt: 0)
        player.currentSong = first
        let extendedEarly = await player.extendExhaustedShuffleHoldingTheSongModel()
        XCTAssertFalse(extendedEarly)
        XCTAssertFalse(player.extendExhaustedShuffleFromLibrary(), "the direct call reads no empty array as an answer")
        XCTAssertEqual(player.queueCount, 2)
        XCTAssertEqual(holds(), [])

        // 随机放到了最后一首:占用一次,等不到模型就挂着,队列不动。
        player.setQueue([first], startAt: 0)
        player.currentSong = first
        let extending = Task { @MainActor in _ = await player.extendExhaustedShuffleHoldingTheSongModel() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(holds(), [.playbackContinuation])
        XCTAssertEqual(player.queueCount, 1)
        extending.cancel()

        // 相似续播放到了最后一首:同样只占用一次;没等到模型,这一首不算死胡同。
        MusicLibrary.songModelHoldRequestsForTesting = []
        player.shuffleEnabled = false
        player.setQueue([first], startAt: 0)
        XCTAssertEqual(player.autoContinuationDecision, .similarSongs)
        player.scheduleAutoContinuationIfNeeded()
        XCTAssertNotNil(player.autoContinuationTask)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(holds(), [.playbackContinuation])
        player.scheduleAutoContinuationIfNeeded()
        XCTAssertEqual(holds(), [.playbackContinuation], "one pending top-up, one hold")
        XCTAssertEqual(player.queueCount, 1)
        XCTAssertNil(player.autoContinuationDeadEndEntryID, "an unloaded library is not a dead end")
        player.resetAutoContinuation()
    }
}
