import Testing

@testable import PrimuseKit

@Suite("Karaoke timeline update policy")
struct KaraokeTimelineUpdatePolicyTests {
    @Test("Live lyrics update only the progress mask")
    func liveLyricsUseMaskOnlyTimeline() {
        let plan = KaraokeTimelineUpdatePolicy.plan(
            isLineActive: true,
            isPlaybackActive: true,
            hasFixedPlaybackTime: false,
            reduceMotion: false
        )

        #expect(plan.rendersSyllableProgress)
        #expect(plan.runsTimeline)
        #expect(plan.invalidationScope == .progressMask)
        #expect(plan.minimumInterval == 1.0 / 30.0)
    }

    @Test("Neighboring rows never acquire a playback clock")
    func inactiveRowsStayStatic() {
        let plan = KaraokeTimelineUpdatePolicy.plan(
            isLineActive: false,
            isPlaybackActive: true,
            hasFixedPlaybackTime: false,
            reduceMotion: false
        )

        #expect(!plan.rendersSyllableProgress)
        #expect(!plan.runsTimeline)
        #expect(plan.invalidationScope == .none)
        #expect(plan.minimumInterval == nil)
    }

    @Test("Paused and fixed-time lyrics render one static progress snapshot")
    func frozenLyricsDoNotRunTimeline() {
        let paused = KaraokeTimelineUpdatePolicy.plan(
            isLineActive: true,
            isPlaybackActive: false,
            hasFixedPlaybackTime: false,
            reduceMotion: false
        )
        let fixed = KaraokeTimelineUpdatePolicy.plan(
            isLineActive: true,
            isPlaybackActive: true,
            hasFixedPlaybackTime: true,
            reduceMotion: false
        )

        for plan in [paused, fixed] {
            #expect(plan.rendersSyllableProgress)
            #expect(!plan.runsTimeline)
            #expect(plan.invalidationScope == .none)
            #expect(plan.minimumInterval == nil)
        }
    }

    @Test("Reduce Motion preserves lyric progress at a lower cadence")
    func reduceMotionKeepsProgressWithoutDisplayRateUpdates() {
        let plan = KaraokeTimelineUpdatePolicy.plan(
            isLineActive: true,
            isPlaybackActive: true,
            hasFixedPlaybackTime: false,
            reduceMotion: true
        )

        #expect(plan.rendersSyllableProgress)
        #expect(plan.runsTimeline)
        #expect(plan.invalidationScope == .progressMask)
        #expect(plan.minimumInterval == 0.10)
    }
}
