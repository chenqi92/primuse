import Foundation
import Testing
@testable import PrimuseKit

@Suite("Gapless successor discard")
struct GaplessSuccessorDiscardPolicyTests {
    private func preparation(
        hasScheduledBuffers: Bool = false,
        isStale: Bool = false,
        queueGeneration: Int = 7
    ) -> GaplessSuccessorDiscardPolicy.PreparationSnapshot {
        GaplessSuccessorDiscardPolicy.PreparationSnapshot(
            hasScheduledBuffers: hasScheduledBuffers,
            isStale: isStale,
            queueGeneration: queueGeneration
        )
    }

    private func feed(
        ownsCurrentPlayback: Bool = true,
        isStale: Bool = false,
        following: GaplessSuccessorDiscardPolicy.PreparationSnapshot?
    ) -> GaplessSuccessorDiscardPolicy.FeedSnapshot {
        GaplessSuccessorDiscardPolicy.FeedSnapshot(
            ownsCurrentPlayback: ownsCurrentPlayback,
            isStale: isStale,
            following: following
        )
    }

    @Test("Only a partially scheduled preparation is marked stale")
    func staleMarkingTracksPartialScheduling() {
        #expect(
            !GaplessSuccessorDiscardPolicy.marksPreparationStale(
                hasScheduledBuffers: false,
                isFullyScheduled: false
            )
        )
        #expect(
            GaplessSuccessorDiscardPolicy.marksPreparationStale(
                hasScheduledBuffers: true,
                isFullyScheduled: false
            )
        )
        #expect(
            !GaplessSuccessorDiscardPolicy.marksPreparationStale(
                hasScheduledBuffers: true,
                isFullyScheduled: true
            )
        )
    }

    @Test("An in-flight preparation with nothing on the node restarts")
    func cleanInFlightRestarts() {
        #expect(
            GaplessSuccessorDiscardPolicy.action(
                inFlight: preparation(),
                feed: nil,
                queueGeneration: 7
            ) == .restartPreparation
        )
    }

    @Test("An in-flight preparation that already scheduled buffers is left to the boundary")
    func scheduledInFlightLeavesToBoundary() {
        #expect(
            GaplessSuccessorDiscardPolicy.action(
                inFlight: preparation(hasScheduledBuffers: true),
                feed: nil,
                queueGeneration: 7
            ) == .leaveToBoundary
        )
    }

    @Test("An already stale in-flight preparation is left to the boundary")
    func staleInFlightLeavesToBoundary() {
        #expect(
            GaplessSuccessorDiscardPolicy.action(
                inFlight: preparation(isStale: true),
                feed: nil,
                queueGeneration: 7
            ) == .leaveToBoundary
        )
    }

    @Test("An in-flight preparation from an older queue generation is left to the boundary")
    func inFlightGenerationMismatchLeavesToBoundary() {
        #expect(
            GaplessSuccessorDiscardPolicy.action(
                inFlight: preparation(queueGeneration: 6),
                feed: nil,
                queueGeneration: 7
            ) == .leaveToBoundary
        )
    }

    @Test("A feed of the audible track re-arms its follow-up")
    func cleanFeedRearmsFollowup() {
        #expect(
            GaplessSuccessorDiscardPolicy.action(
                inFlight: nil,
                feed: feed(following: preparation()),
                queueGeneration: 7
            ) == .rearmFollowup
        )
    }

    @Test("A feed of another play ID is left to the boundary")
    func foreignFeedLeavesToBoundary() {
        #expect(
            GaplessSuccessorDiscardPolicy.action(
                inFlight: nil,
                feed: feed(ownsCurrentPlayback: false, following: preparation()),
                queueGeneration: 7
            ) == .leaveToBoundary
        )
    }

    @Test("A stale feed is left to the boundary")
    func staleFeedLeavesToBoundary() {
        #expect(
            GaplessSuccessorDiscardPolicy.action(
                inFlight: nil,
                feed: feed(isStale: true, following: preparation()),
                queueGeneration: 7
            ) == .leaveToBoundary
        )
    }

    @Test("A following transition that already scheduled buffers is left to the boundary")
    func scheduledFollowingLeavesToBoundary() {
        #expect(
            GaplessSuccessorDiscardPolicy.action(
                inFlight: nil,
                feed: feed(following: preparation(hasScheduledBuffers: true)),
                queueGeneration: 7
            ) == .leaveToBoundary
        )
    }

    @Test("A following transition from an older queue generation is left to the boundary")
    func followingGenerationMismatchLeavesToBoundary() {
        #expect(
            GaplessSuccessorDiscardPolicy.action(
                inFlight: nil,
                feed: feed(following: preparation(queueGeneration: 6)),
                queueGeneration: 7
            ) == .leaveToBoundary
        )
    }

    @Test("A feed without a following transition is left to the boundary")
    func feedWithoutFollowingLeavesToBoundary() {
        #expect(
            GaplessSuccessorDiscardPolicy.action(
                inFlight: nil,
                feed: feed(following: nil),
                queueGeneration: 7
            ) == .leaveToBoundary
        )
    }

    @Test("Nothing in flight and no feed is left to the boundary")
    func nothingToRearmLeavesToBoundary() {
        #expect(
            GaplessSuccessorDiscardPolicy.action(
                inFlight: nil,
                feed: nil,
                queueGeneration: 7
            ) == .leaveToBoundary
        )
    }

    @Test("The in-flight preparation takes precedence over a re-armable feed")
    func inFlightTakesPrecedenceOverFeed() {
        #expect(
            GaplessSuccessorDiscardPolicy.action(
                inFlight: preparation(),
                feed: feed(following: preparation()),
                queueGeneration: 7
            ) == .restartPreparation
        )
    }
}
