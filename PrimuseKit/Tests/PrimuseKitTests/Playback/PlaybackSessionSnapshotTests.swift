import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playback session persistence")
struct PlaybackSessionSnapshotTests {
    @Test("Music snapshots from older versions decode without media metadata")
    func decodesLegacyMusicSnapshot() throws {
        let snapshot = makeSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["radioStation", "radioStationOrderIDs", "podcastQueue"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(
            PlaybackSessionSnapshot.self, from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded == snapshot)
    }

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

    @Test("Natural queue tail preserves the player selection and full queue")
    func naturalQueueTailRemainsRestorable() throws {
        var snapshot = makeSnapshot()
        snapshot.currentTime = snapshot.duration
        snapshot.isAtTrackEnd = true

        let plan = try #require(PlaybackSessionRestorationPolicy.plan(
            snapshot: snapshot,
            availableSongIDs: Set(snapshot.queueSongIDs)
        ))

        #expect(plan.queueSongIDs == snapshot.queueSongIDs)
        #expect(plan.currentIndex == snapshot.currentIndex)
        #expect(plan.queueSongIDs[plan.currentIndex] == snapshot.currentSongID)
        #expect(plan.isAtTrackEnd)
        #expect(!plan.shouldStartPlayback)
    }

    @Test("Near-start launch jitter restarts instead of exact-seek recovery")
    func nearStartProgressRestartsFromBeginning() throws {
        var snapshot = makeSnapshot()
        snapshot.currentTime = 0.27698302268981934

        let plan = try #require(PlaybackSessionRestorationPolicy.plan(
            snapshot: snapshot,
            availableSongIDs: Set(snapshot.queueSongIDs)
        ))

        #expect(plan.currentTime == 0)
    }

    @Test("Meaningful launch progress remains resumable")
    func meaningfulProgressIsPreserved() throws {
        var snapshot = makeSnapshot()
        snapshot.currentTime = PlaybackSessionRestorationPolicy.minimumMeaningfulResumeTime + 0.001

        let plan = try #require(PlaybackSessionRestorationPolicy.plan(
            snapshot: snapshot,
            availableSongIDs: Set(snapshot.queueSongIDs)
        ))

        #expect(plan.currentTime == snapshot.currentTime)
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

    @Test("Launch autoplay waits for foreground restoration and runs only once")
    func launchAutoplayWaitsForForegroundRestoreAndOnlyRunsOnce() throws {
        var lifecycle = PlaybackSessionRestoreLifecycle()
        let decision1 = lifecycle.takeLaunchAutoplayDecision(enabled: true, isForeground: true, canResume: true)
        #expect(!decision1)
        let started = lifecycle.begin()
        let token = try #require(started)
        let decision2 = lifecycle.takeLaunchAutoplayDecision(enabled: true, isForeground: true, canResume: true)
        #expect(!decision2)
        lifecycle.complete(token: token)
        let decision3 = lifecycle.takeLaunchAutoplayDecision(enabled: true, isForeground: false, canResume: true)
        #expect(!decision3)
        let decision4 = lifecycle.takeLaunchAutoplayDecision(enabled: true, isForeground: true, canResume: true)
        #expect(decision4)
        let decision5 = lifecycle.takeLaunchAutoplayDecision(enabled: true, isForeground: true, canResume: true)
        #expect(!decision5)
    }

    @Test(arguments: ["disabled", "empty", "otherAudio", "pauseDuringRestore", "pauseAfterRestore", "playDuringRestore", "playAfterRestore"])
    func launchAutoplayRespectsPreferencesAndTransport(_ reason: String) throws {
        var lifecycle = PlaybackSessionRestoreLifecycle()
        let started = lifecycle.begin()
        let token = try #require(started)
        if reason == "pauseDuringRestore" { lifecycle.completeForPauseOrStopIntent() }
        if reason == "playDuringRestore" { lifecycle.supersedeForPlaybackIntent() }
        lifecycle.complete(token: token)
        if reason == "pauseAfterRestore" { lifecycle.completeForPauseOrStopIntent() }
        if reason == "playAfterRestore" { lifecycle.supersedeForPlaybackIntent() }
        if reason.hasPrefix("play") { lifecycle.didPersistCurrentSession() }
        let decision6 = lifecycle.takeLaunchAutoplayDecision(
            enabled: reason != "disabled", isForeground: true,
            canResume: reason != "empty", otherAudioIsPlaying: reason == "otherAudio"
        )
        #expect(!decision6)
        let decision7 = lifecycle.takeLaunchAutoplayDecision(enabled: true, isForeground: true, canResume: true)
        #expect(!decision7)
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
