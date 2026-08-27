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

    @Test("Animated artwork requires an active visible hero and system permission")
    func animatedArtworkPolicy() {
        let active = ArtworkAnimationPolicy(
            isEnabled: true,
            presentationRole: .animatedHero,
            isVisible: true,
            isSceneActive: true,
            requiresPlayback: true,
            isPlaying: true,
            reduceMotion: false,
            playAnimatedImages: true,
            isLowPowerModeEnabled: false,
            thermalCondition: .nominal
        )

        #expect(active.shouldAnimate)
        #expect(!policy(active, role: .staticFirstFrame).shouldAnimate)
        #expect(!policy(active, isVisible: false).shouldAnimate)
        #expect(!policy(active, isSceneActive: false).shouldAnimate)
        #expect(!policy(active, isPlaying: false).shouldAnimate)
        #expect(!policy(active, reduceMotion: true).shouldAnimate)
        #expect(!policy(active, playAnimatedImages: false).shouldAnimate)
        #expect(!policy(active, isLowPowerModeEnabled: true).shouldAnimate)
        #expect(!policy(active, thermalCondition: .serious).shouldAnimate)
    }

    @Test("Album detail animation does not depend on audio playback")
    func albumDetailAnimationPolicy() {
        let policy = ArtworkAnimationPolicy(
            isEnabled: true,
            presentationRole: .animatedHero,
            isVisible: true,
            isSceneActive: true,
            requiresPlayback: false,
            isPlaying: false,
            reduceMotion: false,
            playAnimatedImages: true,
            isLowPowerModeEnabled: false,
            thermalCondition: .fair
        )

        #expect(policy.shouldAnimate)
    }

    @Test("Remote animation fetch respects constrained and unmetered policies")
    func animationFetchPolicy() {
        let unmetered = ArtworkAnimationFetchPolicy(
            isEnabled: true,
            presentationRole: .animatedHero,
            isVisible: true,
            isReachable: true,
            isExpensive: false,
            isConstrained: false,
            isOnUnmeteredNetwork: true,
            unmeteredOnly: true,
            isLowPowerModeEnabled: false,
            thermalCondition: .nominal
        )
        #expect(unmetered.shouldFetchRemoteAnimation)

        let constrained = ArtworkAnimationFetchPolicy(
            isEnabled: true,
            presentationRole: .animatedHero,
            isVisible: true,
            isReachable: true,
            isExpensive: false,
            isConstrained: true,
            isOnUnmeteredNetwork: true,
            unmeteredOnly: true,
            isLowPowerModeEnabled: false,
            thermalCondition: .nominal
        )
        #expect(!constrained.shouldFetchRemoteAnimation)

        let cellular = ArtworkAnimationFetchPolicy(
            isEnabled: true,
            presentationRole: .animatedHero,
            isVisible: true,
            isReachable: true,
            isExpensive: true,
            isConstrained: false,
            isOnUnmeteredNetwork: false,
            unmeteredOnly: true,
            isLowPowerModeEnabled: false,
            thermalCondition: .nominal
        )
        #expect(!cellular.shouldFetchRemoteAnimation)
    }

    private func policy(
        _ base: ArtworkAnimationPolicy,
        role: ArtworkPresentationRole? = nil,
        isVisible: Bool? = nil,
        isSceneActive: Bool? = nil,
        isPlaying: Bool? = nil,
        reduceMotion: Bool? = nil,
        playAnimatedImages: Bool? = nil,
        isLowPowerModeEnabled: Bool? = nil,
        thermalCondition: ArtworkThermalCondition? = nil
    ) -> ArtworkAnimationPolicy {
        ArtworkAnimationPolicy(
            isEnabled: base.isEnabled,
            presentationRole: role ?? base.presentationRole,
            isVisible: isVisible ?? base.isVisible,
            isSceneActive: isSceneActive ?? base.isSceneActive,
            requiresPlayback: base.requiresPlayback,
            isPlaying: isPlaying ?? base.isPlaying,
            reduceMotion: reduceMotion ?? base.reduceMotion,
            playAnimatedImages: playAnimatedImages ?? base.playAnimatedImages,
            isLowPowerModeEnabled: isLowPowerModeEnabled ?? base.isLowPowerModeEnabled,
            thermalCondition: thermalCondition ?? base.thermalCondition
        )
    }
}
