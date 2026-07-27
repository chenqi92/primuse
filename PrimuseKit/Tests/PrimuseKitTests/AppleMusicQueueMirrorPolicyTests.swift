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
            primuseOwnsMixedQueue: false,
            snapshotCount: 12
        ))
        #expect(!AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: true,
            primuseOwnsMixedQueue: false,
            snapshotCount: 12
        ))
    }

    @Test("Mixed queues and transient empty snapshots remain Primuse-owned")
    func protectsCanonicalQueue() {
        #expect(!AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: false,
            primuseOwnsMixedQueue: true,
            snapshotCount: 12
        ))
        #expect(!AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: false,
            primuseOwnsMixedQueue: false,
            snapshotCount: 0
        ))
    }

    @Test("Only a current non-empty Apple-Music-only snapshot can apply")
    func acceptsCurrentMusicKitSnapshot() {
        #expect(AppleMusicQueueMirrorPolicy.shouldApplySnapshot(
            sessionGeneration: 5,
            activeGeneration: 5,
            isCancelled: false,
            primuseOwnsMixedQueue: false,
            snapshotCount: 12
        ))
    }
}
