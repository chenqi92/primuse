import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playback clock safety policy")
struct PlaybackClockSafetyPolicyTests {
    @Test("Stopping and restarting invalidates already enqueued ticks")
    func tickGenerationsRejectStaleCallbacks() {
        var gate = PlaybackClockTickGate()
        let firstGeneration = gate.issue()
        #expect(gate.isCurrent(firstGeneration))

        gate.invalidate()
        #expect(!gate.isCurrent(firstGeneration))

        let restartedGeneration = gate.issue()
        #expect(gate.isCurrent(restartedGeneration))
        #expect(!gate.isCurrent(firstGeneration))
        #expect(!gate.isCurrent(0))
    }

    @Test("Only the node that owns visible audio is selected")
    func readTargetFollowsTransitionOwnership() {
        #expect(PlaybackClockReadPolicy.target(isTransitioning: false) == .primary)
        #expect(PlaybackClockReadPolicy.target(isTransitioning: true) == .incoming)
    }

    @Test("A live cached clock projects by at most one second")
    func frozenProgressBoundsExtrapolation() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000)

        let shortProjection = PlaybackClockFreezePolicy.frozenTime(
            cachedCurrentTime: 42,
            currentTimeAnchor: anchor,
            eventTime: anchor.addingTimeInterval(0.4),
            isAdvancing: true,
            duration: 180
        )
        #expect(abs(shortProjection - 42.4) < 0.000_001)
        #expect(PlaybackClockFreezePolicy.frozenTime(
            cachedCurrentTime: 42,
            currentTimeAnchor: anchor,
            eventTime: anchor.addingTimeInterval(20),
            isAdvancing: true,
            duration: 180
        ) == 43)
    }

    @Test("Paused and out-of-order events preserve the cached sample")
    func frozenProgressDoesNotInventMovement() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(PlaybackClockFreezePolicy.frozenTime(
            cachedCurrentTime: 42,
            currentTimeAnchor: anchor,
            eventTime: anchor.addingTimeInterval(0.8),
            isAdvancing: false,
            duration: 180
        ) == 42)
        #expect(PlaybackClockFreezePolicy.frozenTime(
            cachedCurrentTime: 42,
            currentTimeAnchor: anchor,
            eventTime: anchor.addingTimeInterval(-5),
            isAdvancing: true,
            duration: 180
        ) == 42)
    }

    @Test("Frozen progress sanitizes invalid values and respects duration")
    func frozenProgressSanitizesInputs() {
        let anchor = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(PlaybackClockFreezePolicy.frozenTime(
            cachedCurrentTime: 179.75,
            currentTimeAnchor: anchor,
            eventTime: anchor.addingTimeInterval(0.75),
            isAdvancing: true,
            duration: 180
        ) == 180)
        #expect(PlaybackClockFreezePolicy.frozenTime(
            cachedCurrentTime: .nan,
            currentTimeAnchor: anchor,
            eventTime: anchor.addingTimeInterval(0.5),
            isAdvancing: true,
            duration: 180
        ) == 0)
        #expect(PlaybackClockFreezePolicy.frozenTime(
            cachedCurrentTime: -.infinity,
            currentTimeAnchor: anchor,
            eventTime: Date(timeIntervalSinceReferenceDate: .infinity),
            isAdvancing: true,
            duration: .nan
        ) == 0)
        #expect(PlaybackClockFreezePolicy.frozenTime(
            cachedCurrentTime: -4,
            currentTimeAnchor: anchor,
            eventTime: anchor,
            isAdvancing: false,
            duration: .infinity
        ) == 0)
    }
}

@Suite("Playback timeline tracker")
struct PlaybackTimelineTrackerTests {
    @Test("Pre-scheduled consecutive tracks commit their own absolute boundaries")
    func consecutiveTracksKeepMonotonicBoundaries() throws {
        var tracker = PlaybackTimelineTracker()
        let firstBoundaryCandidate = tracker.recordScheduledFrames(1_024)
        let firstBoundary = try #require(firstBoundaryCandidate)
        let secondBoundaryCandidate = tracker.recordScheduledFrames(2_048)
        let secondBoundary = try #require(secondBoundaryCandidate)
        let thirdBoundaryCandidate = tracker.recordScheduledFrames(512)
        let thirdBoundary = try #require(thirdBoundaryCandidate)
        let firstCommit = tracker.commitBoundary(firstBoundary)
        let secondCommit = tracker.commitBoundary(secondBoundary)
        let thirdCommit = tracker.commitBoundary(thirdBoundary)
        let duplicateCommit = tracker.commitBoundary(firstBoundary)

        #expect(firstBoundary.frameCursor == 1_024)
        #expect(secondBoundary.frameCursor == 3_072)
        #expect(thirdBoundary.frameCursor == 3_584)
        #expect(firstCommit == 1_024)
        #expect(secondCommit == 3_072)
        #expect(thirdCommit == 3_584)
        #expect(duplicateCommit == nil)
    }

    @Test("A delayed older boundary cannot move the committed cursor backwards")
    func outOfOrderBoundariesStayMonotonic() throws {
        var tracker = PlaybackTimelineTracker()
        let olderBoundaryCandidate = tracker.recordScheduledFrames(1_024)
        let olderBoundary = try #require(olderBoundaryCandidate)
        let newerBoundaryCandidate = tracker.recordScheduledFrames(2_048)
        let newerBoundary = try #require(newerBoundaryCandidate)

        #expect(tracker.commitBoundary(newerBoundary) == 3_072)
        #expect(tracker.commitBoundary(olderBoundary) == nil)
        #expect(tracker.committedBoundaryFrameCursor == 3_072)
    }

    @Test("Reset invalidates old callbacks and restarts the frame cursor")
    func resetRejectsOldBoundaryTokens() throws {
        var tracker = PlaybackTimelineTracker()
        let oldBoundaryCandidate = tracker.recordScheduledFrames(4_096)
        let oldBoundary = try #require(oldBoundaryCandidate)

        tracker.reset()

        #expect(tracker.scheduledFrameCursor == 0)
        let staleCommit = tracker.commitBoundary(oldBoundary)
        #expect(staleCommit == nil)
        let newBoundaryCandidate = tracker.recordScheduledFrames(512)
        let newBoundary = try #require(newBoundaryCandidate)
        let newCommit = tracker.commitBoundary(newBoundary)
        #expect(newBoundary.generation != oldBoundary.generation)
        #expect(newBoundary.frameCursor == 512)
        #expect(newCommit == 512)
    }

    @Test("Independent physical-node timelines reject each other's tokens")
    func nodeTimelinesDoNotShareTokenIdentity() throws {
        var primaryTracker = PlaybackTimelineTracker()
        var incomingTracker = PlaybackTimelineTracker()
        let primaryBoundaryCandidate = primaryTracker.recordScheduledFrames(2_048)
        let primaryBoundary = try #require(primaryBoundaryCandidate)
        let incomingBoundaryCandidate = incomingTracker.recordScheduledFrames(2_048)
        let incomingBoundary = try #require(incomingBoundaryCandidate)

        let primaryRejectsIncoming = primaryTracker.commitBoundary(incomingBoundary)
        let incomingRejectsPrimary = incomingTracker.commitBoundary(primaryBoundary)
        let primaryCommit = primaryTracker.commitBoundary(primaryBoundary)
        let incomingCommit = incomingTracker.commitBoundary(incomingBoundary)

        #expect(primaryRejectsIncoming == nil)
        #expect(incomingRejectsPrimary == nil)
        #expect(primaryCommit == 2_048)
        #expect(incomingCommit == 2_048)
    }

    @Test("Seek progress stays separate from the scheduled-frame coordinate")
    func seekDoesNotPolluteBoundaryCursor() throws {
        let seekFramePosition: Int64 = 48_000 * 75
        let remainingFrameCount: Int64 = 48_000 * 105
        let seekSampleTimeOffset = -seekFramePosition
        var tracker = PlaybackTimelineTracker()
        tracker.reset()

        let boundaryCandidate = tracker.recordScheduledFrames(remainingFrameCount)
        let boundary = try #require(boundaryCandidate)
        let committedBoundary = tracker.commitBoundary(boundary)
        let visibleFramesAtBoundary = boundary.frameCursor - seekSampleTimeOffset

        #expect(boundary.frameCursor == remainingFrameCount)
        #expect(committedBoundary == remainingFrameCount)
        #expect(visibleFramesAtBoundary == 48_000 * 180)
    }

    @Test("Seek followed by consecutive gapless tracks keeps one absolute cursor")
    func seekThenConsecutiveTracksAccumulateRemainingFrames() throws {
        let seekFramePosition: Int64 = 48_000 * 75
        let remainingFrameCount: Int64 = 48_000 * 105
        let nextTrackFrames: Int64 = 48_000 * 180
        var tracker = PlaybackTimelineTracker()
        tracker.reset()

        let firstBoundaryCandidate = tracker.recordScheduledFrames(remainingFrameCount)
        let firstBoundary = try #require(firstBoundaryCandidate)
        let secondBoundaryCandidate = tracker.recordScheduledFrames(nextTrackFrames)
        let secondBoundary = try #require(secondBoundaryCandidate)

        #expect(tracker.commitBoundary(firstBoundary) == remainingFrameCount)
        #expect(tracker.commitBoundary(secondBoundary) == remainingFrameCount + nextTrackFrames)
        #expect(firstBoundary.frameCursor - (-seekFramePosition) == 48_000 * 180)
        #expect(secondBoundary.frameCursor - firstBoundary.frameCursor == nextTrackFrames)
    }

    @Test("Swapping physical-node trackers preserves only the incoming timeline")
    func swappedTrackersKeepIncomingTokensValid() throws {
        var primaryTracker = PlaybackTimelineTracker()
        var incomingTracker = PlaybackTimelineTracker()
        let outgoingBoundaryCandidate = primaryTracker.recordScheduledFrames(1_024)
        let outgoingBoundary = try #require(outgoingBoundaryCandidate)
        let incomingBoundaryCandidate = incomingTracker.recordScheduledFrames(2_048)
        let incomingBoundary = try #require(incomingBoundaryCandidate)

        swap(&primaryTracker, &incomingTracker)
        incomingTracker.reset()

        #expect(primaryTracker.commitBoundary(incomingBoundary) == 2_048)
        #expect(incomingTracker.commitBoundary(outgoingBoundary) == nil)
    }

    @Test("Invalid frame counts, overflow, and future tokens cannot corrupt state")
    func rejectsInvalidTimelineUpdates() throws {
        var tracker = PlaybackTimelineTracker()
        let zeroCountResult = tracker.recordScheduledFrames(0)
        let negativeCountResult = tracker.recordScheduledFrames(-1)
        #expect(zeroCountResult == nil)
        #expect(negativeCountResult == nil)
        #expect(tracker.scheduledFrameCursor == 0)

        var futureTracker = tracker
        let futureBoundaryCandidate = futureTracker.recordScheduledFrames(2_048)
        let futureBoundary = try #require(futureBoundaryCandidate)
        let futureCommit = tracker.commitBoundary(futureBoundary)
        #expect(futureCommit == nil)

        let maximumBoundaryCandidate = tracker.recordScheduledFrames(Int64.max)
        let maximumBoundary = try #require(maximumBoundaryCandidate)
        let overflowResult = tracker.recordScheduledFrames(1)
        let maximumCommit = tracker.commitBoundary(maximumBoundary)
        #expect(overflowResult == nil)
        #expect(tracker.scheduledFrameCursor == Int64.max)
        #expect(maximumCommit == Int64.max)
    }
}
