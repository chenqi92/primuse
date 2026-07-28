import Testing
@testable import PrimuseKit

@Suite("Apple Music queue mirror policy")
struct AppleMusicQueueMirrorPolicyTests {
    @Test("Cancelled or superseded mirrors cannot replace a newer queue")
    func rejectsStaleMirrorSessions() {
        #expect(!AppleMusicQueueMirrorPolicy.isActiveSession(
            sessionGeneration: 4,
            activeGeneration: 5,
            isCancelled: false
        ))
        #expect(!AppleMusicQueueMirrorPolicy.isActiveSession(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: true
        ))
        #expect(!AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 4,
            activeGeneration: 5,
            isCancelled: false,
            primuseOwnsCanonicalQueue: false,
            snapshotCount: 12
        ))
        #expect(!AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: true,
            primuseOwnsCanonicalQueue: false,
            snapshotCount: 12
        ))
    }

    @Test("Mixed queues and transient empty snapshots remain Primuse-owned")
    func protectsCanonicalQueue() {
        #expect(!AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: false,
            primuseOwnsCanonicalQueue: true,
            snapshotCount: 12
        ))
        #expect(!AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: false,
            primuseOwnsCanonicalQueue: false,
            snapshotCount: 0
        ))
    }

    @Test("Only a current non-empty Apple-Music-only snapshot can apply")
    func acceptsCurrentMusicKitSnapshot() {
        #expect(AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: false,
            primuseOwnsCanonicalQueue: false,
            snapshotCount: 12
        ))
    }
}

@Suite("Apple Music queue ownership policy")
struct AppleMusicQueueOwnershipPolicyTests {
    @Test("Every explicit Primuse queue remains canonical")
    func keepsPureAndMixedQueuesPrimuseManaged() {
        #expect(AppleMusicQueueOwnershipPolicy.shouldUsePrimuseQueue(
            selectedQueueEntryMatches: true
        ))
        #expect(!AppleMusicQueueOwnershipPolicy.shouldUsePrimuseQueue(
            selectedQueueEntryMatches: false
        ))
    }
}

@Suite("Apple Music playback-end policy")
struct AppleMusicPlaybackEndPolicyTests {
    @Test("A paused track still ends when MusicKit resets its current time")
    func recognizesPausedEndAfterTimeReset() {
        let nearEnd = AppleMusicPlaybackEndPolicy.isNearEnd(
            duration: 240,
            playbackTime: 0,
            furthestObservedTime: 238.5
        )

        #expect(nearEnd)
        #expect(AppleMusicPlaybackEndPolicy.shouldAdvance(
            hasObservedActivePlayback: true,
            isStopped: false,
            isPaused: true,
            wasPausedByUser: false,
            isPlaybackInterrupted: false,
            isNearEnd: nearEnd,
            stalledNearEndSampleCount: 0,
            stallSampleThreshold: 6
        ))
    }

    @Test("A frozen playing clock eventually advances")
    func recognizesFrozenPlayingEnd() {
        let nearEnd = AppleMusicPlaybackEndPolicy.isNearEnd(
            duration: 180,
            playbackTime: 178,
            furthestObservedTime: 178
        )

        #expect(nearEnd)
        #expect(!AppleMusicPlaybackEndPolicy.shouldAdvance(
            hasObservedActivePlayback: true,
            isStopped: false,
            isPaused: false,
            wasPausedByUser: false,
            isPlaybackInterrupted: false,
            isNearEnd: nearEnd,
            stalledNearEndSampleCount: 5,
            stallSampleThreshold: 6
        ))
        #expect(AppleMusicPlaybackEndPolicy.shouldAdvance(
            hasObservedActivePlayback: true,
            isStopped: false,
            isPaused: false,
            wasPausedByUser: false,
            isPlaybackInterrupted: false,
            isNearEnd: nearEnd,
            stalledNearEndSampleCount: 6,
            stallSampleThreshold: 6
        ))
    }

    @Test("User pauses and non-terminal stalls never advance")
    func rejectsManualPauseAndEarlyStall() {
        #expect(!AppleMusicPlaybackEndPolicy.shouldAdvance(
            hasObservedActivePlayback: true,
            isStopped: false,
            isPaused: true,
            wasPausedByUser: true,
            isPlaybackInterrupted: false,
            isNearEnd: true,
            stalledNearEndSampleCount: 0,
            stallSampleThreshold: 6
        ))
        #expect(!AppleMusicPlaybackEndPolicy.isNearEnd(
            duration: 180,
            playbackTime: 120,
            furthestObservedTime: 120
        ))
    }

    @Test("An audio-session interruption never advances near the end")
    func rejectsInterruptedPauseOrFrozenClock() {
        #expect(!AppleMusicPlaybackEndPolicy.shouldAdvance(
            hasObservedActivePlayback: true,
            isStopped: false,
            isPaused: true,
            wasPausedByUser: false,
            isPlaybackInterrupted: true,
            isNearEnd: true,
            stalledNearEndSampleCount: 12,
            stallSampleThreshold: 6
        ))
        #expect(!AppleMusicPlaybackEndPolicy.shouldAdvance(
            hasObservedActivePlayback: true,
            isStopped: true,
            isPaused: false,
            wasPausedByUser: false,
            isPlaybackInterrupted: true,
            isNearEnd: true,
            stalledNearEndSampleCount: 12,
            stallSampleThreshold: 6
        ))
    }
}
