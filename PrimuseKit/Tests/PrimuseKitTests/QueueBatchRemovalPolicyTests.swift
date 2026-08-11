import Testing
@testable import PrimuseKit

@Suite("Queue batch removal")
struct QueueBatchRemovalPolicyTests {
    @Test("Unrelated removals leave the queue untouched")
    func unrelatedRemovalIsUnchanged() {
        let plan = QueueBatchRemovalPolicy.plan(
            queueSongIDs: ["a", "b", "c"],
            currentIndex: 1,
            currentSongID: "b",
            removingSongIDs: ["outside"]
        )

        #expect(plan == QueueBatchRemovalPlan(
            retainedIndices: [0, 1, 2],
            action: .unchanged
        ))
    }

    @Test("Removing rows before the active song preserves its queue position")
    func retainedCurrentSongGetsAdjustedIndex() {
        let plan = QueueBatchRemovalPolicy.plan(
            queueSongIDs: ["a", "b", "c", "d"],
            currentIndex: 2,
            currentSongID: "c",
            removingSongIDs: ["a", "b"]
        )

        #expect(plan == QueueBatchRemovalPlan(
            retainedIndices: [2, 3],
            action: .replaceQueue(startAt: 0)
        ))
    }

    @Test("Consecutive selected songs are skipped before source deletion")
    func consecutiveRemovedSongsAdvanceToSafeReplacement() {
        let plan = QueueBatchRemovalPolicy.plan(
            queueSongIDs: ["a", "b", "c", "d"],
            currentIndex: 0,
            currentSongID: "a",
            removingSongIDs: ["a", "b", "c"]
        )

        #expect(plan == QueueBatchRemovalPlan(
            retainedIndices: [3],
            action: .playReplacement(startAt: 0)
        ))
    }

    @Test("Removing the tail wraps to the first retained song")
    func removedTailWrapsToFirstRetainedSong() {
        let plan = QueueBatchRemovalPolicy.plan(
            queueSongIDs: ["a", "b", "c"],
            currentIndex: 2,
            currentSongID: "c",
            removingSongIDs: ["c"]
        )

        #expect(plan == QueueBatchRemovalPlan(
            retainedIndices: [0, 1],
            action: .playReplacement(startAt: 0)
        ))
    }

    @Test("Removing the complete active queue stops playback")
    func completeRemovalStopsPlayback() {
        let plan = QueueBatchRemovalPolicy.plan(
            queueSongIDs: ["a", "b"],
            currentIndex: 0,
            currentSongID: "a",
            removingSongIDs: ["a", "b"]
        )

        #expect(plan == QueueBatchRemovalPlan(
            retainedIndices: [],
            action: .stopAndClearQueue
        ))
    }

    @Test("An independent active song survives clearing removed queue rows")
    func activeSongOutsideQueueKeepsPlaying() {
        let plan = QueueBatchRemovalPolicy.plan(
            queueSongIDs: ["a", "b"],
            currentIndex: 1,
            currentSongID: "outside",
            removingSongIDs: ["a", "b"]
        )

        #expect(plan == QueueBatchRemovalPlan(
            retainedIndices: [],
            action: .replaceQueue(startAt: 0)
        ))
    }

    @Test("Repeated song IDs keep the active occurrence as the anchor")
    func repeatedSongUsesCurrentOccurrence() {
        let plan = QueueBatchRemovalPolicy.plan(
            queueSongIDs: ["same", "remove", "same", "last"],
            currentIndex: 2,
            currentSongID: "same",
            removingSongIDs: ["remove"]
        )

        #expect(plan == QueueBatchRemovalPlan(
            retainedIndices: [0, 2, 3],
            action: .replaceQueue(startAt: 1)
        ))
    }
}
