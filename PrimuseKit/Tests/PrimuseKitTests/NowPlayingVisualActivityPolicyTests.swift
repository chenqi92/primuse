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

    @Test("Artwork ambient motion uses a bounded low-frequency clock")
    func artworkAmbientMotion() {
        let policy = ambientPolicy(paletteVibrancy: 0.75)

        #expect(policy.shouldAnimate)
        #expect(policy.minimumInterval == 1.0 / 12.0)
        #expect(policy.cycleDuration >= 24)
        #expect(policy.cycleDuration <= 30)
        #expect(policy.motionAmplitude > 0.018)
        #expect(policy.motionAmplitude <= 0.034)
    }

    @Test("Ambient motion stops without changing its static palette")
    func artworkAmbientMotionStopsWhenNotPresented() {
        let active = ambientPolicy()

        #expect(!ambientPolicy(active, isVisible: false).shouldAnimate)
        #expect(!ambientPolicy(active, isSceneActive: false).shouldAnimate)
        #expect(!ambientPolicy(active, isPlaying: false).shouldAnimate)
        #expect(!ambientPolicy(active, hasArtworkPalette: false).shouldAnimate)
        #expect(!ambientPolicy(active, isAmbientVisible: false).shouldAnimate)
        #expect(ambientPolicy(active, isPlaying: false).minimumInterval == nil)
        #expect(ambientPolicy(active, isPlaying: false).motionAmplitude > 0)
        #expect(ambientPolicy(active, isAmbientVisible: false).motionAmplitude == 0)
    }

    @Test("Ambient motion honors accessibility, power, and thermal limits")
    func artworkAmbientMotionResourceLimits() {
        let active = ambientPolicy()

        #expect(!ambientPolicy(active, reduceMotion: true).shouldAnimate)
        #expect(!ambientPolicy(active, isLowPowerModeEnabled: true).shouldAnimate)
        #expect(!ambientPolicy(active, thermalCondition: .serious).shouldAnimate)
        #expect(!ambientPolicy(active, thermalCondition: .critical).shouldAnimate)
    }

    @Test("Fair thermal conditions lower ambient update frequency without shifting the field")
    func artworkAmbientMotionFairThermalTier() {
        let nominal = ambientPolicy(paletteVibrancy: 1)
        let fair = ambientPolicy(nominal, thermalCondition: .fair)

        #expect(fair.shouldAnimate)
        #expect(fair.minimumInterval == 1.0 / 8.0)
        #expect(fair.motionAmplitude == nominal.motionAmplitude)
    }

    @Test("Dark ambient overlay bounds bright artwork and increases contrast on request")
    func artworkAmbientContrastProtection() {
        let normal = NowPlayingAmbientLegibilityPolicy.darkOverlay(
            paletteLuminance: 0.78,
            primaryOpacity: 0.88,
            secondaryOpacity: 0.62,
            usesIncreasedContrast: false
        )
        let increased = NowPlayingAmbientLegibilityPolicy.darkOverlay(
            paletteLuminance: 0.78,
            primaryOpacity: 0.88,
            secondaryOpacity: 0.62,
            usesIncreasedContrast: true
        )

        let afterPrimary = 0.012 * (1 - 0.88) + 0.78 * 0.88
        let estimatedField = afterPrimary * (1 - 0.62) + 0.78 * 0.62
        let protectedField = estimatedField * (1 - normal.topOpacity)
        let secondaryLabel = 0.72 + protectedField * 0.28
        let secondaryLabelContrast = (secondaryLabel + 0.05) / (protectedField + 0.05)
        #expect(protectedField <= 0.126)
        #expect(secondaryLabelContrast >= 4.5)
        #expect(increased.topOpacity > normal.topOpacity)
        #expect(normal.bottomOpacity >= normal.topOpacity)
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

    private func ambientPolicy(
        hasArtworkPalette: Bool = true,
        isAmbientVisible: Bool = true,
        isVisible: Bool = true,
        isSceneActive: Bool = true,
        isPlaying: Bool = true,
        reduceMotion: Bool = false,
        isLowPowerModeEnabled: Bool = false,
        thermalCondition: ArtworkThermalCondition = .nominal,
        paletteVibrancy: Double = 0.6
    ) -> NowPlayingAmbientMotionPolicy {
        NowPlayingAmbientMotionPolicy(
            hasArtworkPalette: hasArtworkPalette,
            isAmbientVisible: isAmbientVisible,
            isVisible: isVisible,
            isSceneActive: isSceneActive,
            isPlaying: isPlaying,
            reduceMotion: reduceMotion,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            thermalCondition: thermalCondition,
            paletteVibrancy: paletteVibrancy
        )
    }

    private func ambientPolicy(
        _ base: NowPlayingAmbientMotionPolicy,
        hasArtworkPalette: Bool? = nil,
        isAmbientVisible: Bool? = nil,
        isVisible: Bool? = nil,
        isSceneActive: Bool? = nil,
        isPlaying: Bool? = nil,
        reduceMotion: Bool? = nil,
        isLowPowerModeEnabled: Bool? = nil,
        thermalCondition: ArtworkThermalCondition? = nil,
        paletteVibrancy: Double? = nil
    ) -> NowPlayingAmbientMotionPolicy {
        ambientPolicy(
            hasArtworkPalette: hasArtworkPalette ?? base.hasArtworkPalette,
            isAmbientVisible: isAmbientVisible ?? base.isAmbientVisible,
            isVisible: isVisible ?? base.isVisible,
            isSceneActive: isSceneActive ?? base.isSceneActive,
            isPlaying: isPlaying ?? base.isPlaying,
            reduceMotion: reduceMotion ?? base.reduceMotion,
            isLowPowerModeEnabled: isLowPowerModeEnabled ?? base.isLowPowerModeEnabled,
            thermalCondition: thermalCondition ?? base.thermalCondition,
            paletteVibrancy: paletteVibrancy ?? base.paletteVibrancy
        )
    }
}
