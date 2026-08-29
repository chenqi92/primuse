import Testing
@testable import PrimuseKit

@Suite("Crossfade playback clock policy")
struct CrossfadePlaybackClockPolicyTests {
    @Test("Committed overlap follows the incoming node and records progress")
    func overlapUsesIncomingClock() {
        let decision = CrossfadePlaybackClockPolicy.decision(
            currentTime: 1.25,
            primaryNodeTime: 238.5,
            incomingNodeTime: 1.5,
            isTransitioning: true
        )

        #expect(decision.visibleTime == 1.5)
        #expect(decision.shouldRecordListeningProgress)
        #expect(!decision.shouldRunTrackEndWatchdog)
    }

    @Test("Incoming clock stays monotonic across overlap and node swap")
    func overlapAndSwapStayContinuous() throws {
        var visibleTime = 0.0
        for incomingTime in [0.4, 0.9, 0.85, 1.4] {
            let decision = CrossfadePlaybackClockPolicy.decision(
                currentTime: visibleTime,
                primaryNodeTime: 240 + incomingTime,
                incomingNodeTime: incomingTime,
                isTransitioning: true
            )
            visibleTime = try #require(decision.visibleTime)
        }

        #expect(visibleTime == 1.4)
        let afterSwap = CrossfadePlaybackClockPolicy.decision(
            currentTime: visibleTime,
            primaryNodeTime: 1.45,
            incomingNodeTime: nil,
            isTransitioning: false
        )
        #expect(afterSwap.visibleTime == 1.45)
        #expect(afterSwap.shouldRunTrackEndWatchdog)
    }

    @Test("Missing transition samples preserve interpolation without false ticks")
    func missingIncomingSampleDoesNotResetClock() {
        let invalidSamples: [Double?] = [nil, Double.nan, Double.infinity]
        for sample in invalidSamples {
            let decision = CrossfadePlaybackClockPolicy.decision(
                currentTime: 2,
                primaryNodeTime: 242,
                incomingNodeTime: sample,
                isTransitioning: true
            )
            #expect(decision.visibleTime == nil)
            #expect(!decision.shouldRecordListeningProgress)
            #expect(!decision.shouldRunTrackEndWatchdog)
        }
    }

    @Test("Primary clock can move backwards after an explicit seek")
    func primaryClockRemainsAuthoritativeAfterSeek() {
        let decision = CrossfadePlaybackClockPolicy.decision(
            currentTime: 90,
            primaryNodeTime: 12,
            incomingNodeTime: 4,
            isTransitioning: false
        )

        #expect(decision.visibleTime == 12)
        #expect(decision.shouldRecordListeningProgress)
        #expect(decision.shouldRunTrackEndWatchdog)
    }
}
