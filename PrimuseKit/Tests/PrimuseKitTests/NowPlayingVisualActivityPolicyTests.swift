import Testing
@testable import PrimuseKit

@Suite("Now Playing visual activity policy")
struct NowPlayingVisualActivityPolicyTests {
    @Test("Active playback enables all requested visual work")
    func activePlayback() {
        let policy = NowPlayingVisualActivityPolicy(
            isSceneActive: true,
            isPlaying: true,
            usesRealtimeSpectrum: true,
            reduceMotion: false
        )

        #expect(policy.shouldRunVisualizer)
        #expect(policy.shouldRunStageClock)
        #expect(policy.shouldAnimateStage)
        #expect(policy.shouldPollLyrics)
        #expect(policy.shouldRunWordTimeline)
    }

    @Test("Inactive scenes stop every visual clock without changing playback")
    func inactiveScene() {
        let policy = NowPlayingVisualActivityPolicy(
            isSceneActive: false,
            isPlaying: true,
            usesRealtimeSpectrum: true,
            reduceMotion: false
        )

        #expect(!policy.shouldRunVisualizer)
        #expect(!policy.shouldRunStageClock)
        #expect(!policy.shouldAnimateStage)
        #expect(!policy.shouldPollLyrics)
        #expect(!policy.shouldRunWordTimeline)
        #expect(policy.isPlaying)
    }

    @Test("Paused playback keeps the scene active but stops playback visuals")
    func pausedPlayback() {
        let policy = NowPlayingVisualActivityPolicy(
            isSceneActive: true,
            isPlaying: false,
            usesRealtimeSpectrum: true,
            reduceMotion: false
        )

        #expect(!policy.shouldRunVisualizer)
        #expect(!policy.shouldRunStageClock)
        #expect(!policy.shouldPollLyrics)
        #expect(!policy.shouldRunWordTimeline)
    }

    @Test("Non-spectrum effects do not acquire the visualizer")
    func effectWithoutSpectrum() {
        let policy = NowPlayingVisualActivityPolicy(
            isSceneActive: true,
            isPlaying: true,
            usesRealtimeSpectrum: false,
            reduceMotion: false
        )

        #expect(!policy.shouldRunVisualizer)
        #expect(policy.shouldRunStageClock)
        #expect(policy.shouldPollLyrics)
    }

    @Test("Reduce Motion retains position clocks but removes motion timelines")
    func reduceMotion() {
        let policy = NowPlayingVisualActivityPolicy(
            isSceneActive: true,
            isPlaying: true,
            usesRealtimeSpectrum: true,
            reduceMotion: true
        )

        #expect(policy.shouldRunVisualizer)
        #expect(policy.shouldRunStageClock)
        #expect(!policy.shouldAnimateStage)
        #expect(policy.shouldPollLyrics)
        #expect(!policy.shouldRunWordTimeline)
    }

    @Test("Visual work resumes from policy state after scene reactivation")
    func sceneReactivation() {
        let active = NowPlayingVisualActivityPolicy(
            isSceneActive: true,
            isPlaying: true,
            usesRealtimeSpectrum: true,
            reduceMotion: false
        )
        let inactive = NowPlayingVisualActivityPolicy(
            isSceneActive: false,
            isPlaying: true,
            usesRealtimeSpectrum: true,
            reduceMotion: false
        )

        #expect(active.shouldRunVisualizer)
        #expect(!inactive.shouldRunVisualizer)
        #expect(active.shouldRunVisualizer)
        #expect(active.shouldPollLyrics)
    }
}
