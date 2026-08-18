import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playback session persistence")
struct PlaybackSessionSnapshotTests {
    @Test("File store round-trips the full shuffle context")
    func roundTripsSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-playback-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        let snapshot = makeSnapshot()

        try store.save(snapshot)

        #expect(try store.load() == snapshot)
        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test("Missing songs are removed without losing shuffle history")
    func filtersUnavailableSongs() throws {
        let snapshot = PlaybackSessionSnapshot(
            queueSongIDs: ["a", "b", "a", "c"],
            currentSongID: "a",
            currentIndex: 2,
            currentTime: 42,
            duration: 180,
            wasPlaying: true,
            shuffleEnabled: true,
            shuffledIndices: [1, 3, 2, 0],
            shufflePosition: 2,
            pendingNextShuffleIndices: [2, 0, 3, 1],
            repeatMode: .all,
            isAtTrackEnd: false
        )

        let plan = try #require(PlaybackSessionRestorationPolicy.plan(
            snapshot: snapshot,
            availableSongIDs: ["a", "c"]
        ))

        #expect(plan.queueSongIDs == ["a", "a", "c"])
        #expect(plan.currentIndex == 1)
        #expect(plan.shuffledIndices == [2, 1, 0])
        #expect(plan.shufflePosition == 1)
        #expect(plan.pendingNextShuffleIndices == [1, 0, 2])
        #expect(plan.currentTime == 42)
        #expect(plan.repeatMode == .all)
        #expect(!plan.shouldStartPlayback)
    }

    @Test("A previously playing snapshot restores paused")
    func playingSnapshotDoesNotAutoPlay() throws {
        var snapshot = makeSnapshot()
        snapshot.wasPlaying = true

        let plan = try #require(PlaybackSessionRestorationPolicy.plan(
            snapshot: snapshot,
            availableSongIDs: Set(snapshot.queueSongIDs)
        ))

        #expect(!plan.shouldStartPlayback)
    }

    @Test("An unavailable current track rejects the stale session")
    func rejectsMissingCurrentTrack() {
        let snapshot = makeSnapshot()

        #expect(PlaybackSessionRestorationPolicy.plan(
            snapshot: snapshot,
            availableSongIDs: ["first", "third"]
        ) == nil)
    }

    @Test("Launch empty state cannot delete the snapshot before restoration")
    func preservesSnapshotUntilRestoreCompletes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-playback-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        let snapshot = makeSnapshot()
        var lifecycle = PlaybackSessionRestoreLifecycle()
        try store.save(snapshot)

        if lifecycle.permitsEmptySessionClear { try store.clear() }
        #expect(try store.load() == snapshot)

        let restoreToken = lifecycle.begin()
        let token = try #require(restoreToken)
        if lifecycle.permitsEmptySessionClear { try store.clear() }
        #expect(try store.load() == snapshot)

        lifecycle.complete(token: token)
        if lifecycle.permitsEmptySessionClear { try store.clear() }
        #expect(try store.load() == nil)
    }

    @Test("A new playback intent invalidates an in-flight restore without discarding its fallback")
    func newPlaybackSupersedesRestore() throws {
        var lifecycle = PlaybackSessionRestoreLifecycle()
        let restoreToken = lifecycle.begin()
        let token = try #require(restoreToken)

        lifecycle.supersedeForPlaybackIntent()

        #expect(!lifecycle.permitsApply(token: token))
        #expect(!lifecycle.permitsEmptySessionClear)
        lifecycle.complete(token: token)
        #expect(lifecycle.phase == .superseded)

        lifecycle.didPersistCurrentSession()
        #expect(lifecycle.phase == .completed)
        #expect(lifecycle.permitsEmptySessionClear)
    }

    @Test("An explicit stop cancels restoration and permits clearing")
    func explicitStopCancelsRestore() throws {
        var lifecycle = PlaybackSessionRestoreLifecycle()
        let restoreToken = lifecycle.begin()
        let token = try #require(restoreToken)

        lifecycle.completeForPauseOrStopIntent()

        #expect(!lifecycle.permitsApply(token: token))
        #expect(lifecycle.phase == .completed)
        #expect(lifecycle.permitsEmptySessionClear)
    }

    @Test("Invalid shuffle bookkeeping falls back to the selected occurrence")
    func repairsInvalidShuffleOrder() throws {
        var snapshot = makeSnapshot()
        snapshot.shuffledIndices = [0, 0, 2]
        snapshot.shufflePosition = 1

        let plan = try #require(PlaybackSessionRestorationPolicy.plan(
            snapshot: snapshot,
            availableSongIDs: Set(snapshot.queueSongIDs)
        ))

        #expect(plan.shuffledIndices == [1, 0, 2])
        #expect(plan.shufflePosition == 0)
        #expect(plan.pendingNextShuffleIndices == [2, 0, 1])
    }

    private func makeSnapshot() -> PlaybackSessionSnapshot {
        PlaybackSessionSnapshot(
            queueSongIDs: ["first", "current", "third"],
            currentSongID: "current",
            currentIndex: 1,
            currentTime: 75,
            duration: 240,
            wasPlaying: false,
            shuffleEnabled: true,
            shuffledIndices: [0, 1, 2],
            shufflePosition: 1,
            pendingNextShuffleIndices: [2, 0, 1],
            repeatMode: .all,
            isAtTrackEnd: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
