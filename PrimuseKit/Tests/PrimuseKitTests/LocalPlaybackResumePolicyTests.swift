import Testing
@testable import PrimuseKit

@Suite("Local playback resume policy")
struct LocalPlaybackResumePolicyTests {
    @Test("A successful configuration restart restores the visible playing state")
    func restoresStateAfterConfigurationRestart() {
        #expect(AudioConfigurationRecoveryPolicy.shouldRestorePlayingState(
            playbackWasIntended: true,
            engineRestarted: true
        ))
        #expect(!AudioConfigurationRecoveryPolicy.shouldRestorePlayingState(
            playbackWasIntended: false,
            engineRestarted: true
        ))
        #expect(!AudioConfigurationRecoveryPolicy.shouldRestorePlayingState(
            playbackWasIntended: true,
            engineRestarted: false
        ))
    }

    @Test("A hardware change remains pending until graph replacement succeeds")
    func tracksHardwareGraphReplacement() {
        var state = AudioHardwareConfigurationRecoveryState()
        #expect(!state.requiresGraphRebuild)

        state.configurationChanged()
        #expect(state.requiresGraphRebuild)

        // A failed rebuild does not acknowledge the pending change.
        #expect(state.requiresGraphRebuild)

        state.graphRebuiltSuccessfully()
        #expect(!state.requiresGraphRebuild)
    }

    @Test("A sustained empty decoded queue rebuilds the active pipeline")
    func rebuildsAfterSustainedUnderflow() {
        #expect(DecodedBufferHealthPolicy.action(
            isPlaying: true,
            hasPreparedAudio: true,
            isLoading: false,
            isTransitioning: false,
            engineIsPlaying: true,
            decoderFinished: false,
            bufferedDuration: 0,
            bufferCount: 0,
            emptyDurationThreshold: 0.05,
            consecutiveUnhealthySamples: 3,
            requiredUnhealthySamples: 3,
            recoveryInProgress: false,
            recoveryAttempts: 0,
            maximumRecoveryAttempts: 2,
            cooldownElapsed: 100,
            minimumCooldown: 8
        ) == .rebuildPipeline)
    }

    @Test("Transient gaps and a healthy queued buffer do not rebuild playback")
    func ignoresTransientAndHealthySamples() {
        #expect(DecodedBufferHealthPolicy.action(
            isPlaying: true,
            hasPreparedAudio: true,
            isLoading: false,
            isTransitioning: false,
            engineIsPlaying: true,
            decoderFinished: false,
            bufferedDuration: 0,
            bufferCount: 0,
            emptyDurationThreshold: 0.05,
            consecutiveUnhealthySamples: 2,
            requiredUnhealthySamples: 3,
            recoveryInProgress: false,
            recoveryAttempts: 0,
            maximumRecoveryAttempts: 2,
            cooldownElapsed: 100,
            minimumCooldown: 8
        ) == .none)
        #expect(DecodedBufferHealthPolicy.action(
            isPlaying: true,
            hasPreparedAudio: true,
            isLoading: false,
            isTransitioning: false,
            engineIsPlaying: true,
            decoderFinished: false,
            bufferedDuration: 0.2,
            bufferCount: 1,
            emptyDurationThreshold: 0.05,
            consecutiveUnhealthySamples: 3,
            requiredUnhealthySamples: 3,
            recoveryInProgress: false,
            recoveryAttempts: 0,
            maximumRecoveryAttempts: 2,
            cooldownElapsed: 100,
            minimumCooldown: 8
        ) == .none)
    }

    @Test("A stopped engine is recovered even while decoded buffers remain")
    func rebuildsStoppedEngine() {
        #expect(DecodedBufferHealthPolicy.action(
            isPlaying: true,
            hasPreparedAudio: true,
            isLoading: false,
            isTransitioning: false,
            engineIsPlaying: false,
            decoderFinished: false,
            bufferedDuration: 4,
            bufferCount: 20,
            emptyDurationThreshold: 0.05,
            consecutiveUnhealthySamples: 3,
            requiredUnhealthySamples: 3,
            recoveryInProgress: false,
            recoveryAttempts: 0,
            maximumRecoveryAttempts: 2,
            cooldownElapsed: 100,
            minimumCooldown: 8
        ) == .rebuildPipeline)
    }

    @Test("Natural EOF, transitions, cooldown, and retry limits suppress recovery")
    func preservesRecoveryBoundaries() {
        func action(
            decoderFinished: Bool = false,
            isTransitioning: Bool = false,
            recoveryInProgress: Bool = false,
            attempts: Int = 0,
            cooldownElapsed: Double = 100
        ) -> DecodedBufferHealthAction {
            DecodedBufferHealthPolicy.action(
                isPlaying: true,
                hasPreparedAudio: true,
                isLoading: false,
                isTransitioning: isTransitioning,
                engineIsPlaying: true,
                decoderFinished: decoderFinished,
                bufferedDuration: 0,
                bufferCount: 0,
                emptyDurationThreshold: 0.05,
                consecutiveUnhealthySamples: 3,
                requiredUnhealthySamples: 3,
                recoveryInProgress: recoveryInProgress,
                recoveryAttempts: attempts,
                maximumRecoveryAttempts: 2,
                cooldownElapsed: cooldownElapsed,
                minimumCooldown: 8
            )
        }

        #expect(action(decoderFinished: true) == .none)
        #expect(action(isTransitioning: true) == .none)
        #expect(action(recoveryInProgress: true) == .none)
        #expect(action(attempts: 2) == .stopPlayback)
        #expect(action(cooldownElapsed: 7.9) == .none)
    }

    @Test("An unprepared engine restarts the current song")
    func restartsAfterPreparationFailure() {
        #expect(LocalPlaybackResumePolicy.action(
            isAtTrackEnd: false,
            needsRecovery: false,
            hasPreparedAudio: false
        ) == .restartCurrentSong)
    }

    @Test("Only prepared audio uses the engine resume path")
    func resumesPreparedAudio() {
        #expect(LocalPlaybackResumePolicy.action(
            isAtTrackEnd: false,
            needsRecovery: false,
            hasPreparedAudio: true
        ) == .resumePreparedAudio)
    }

    @Test("Track-end replay and interruption recovery keep their dedicated paths")
    func preservesExistingRecoverySemantics() {
        #expect(LocalPlaybackResumePolicy.action(
            isAtTrackEnd: true,
            needsRecovery: true,
            hasPreparedAudio: true
        ) == .restartCurrentSong)
        #expect(LocalPlaybackResumePolicy.action(
            isAtTrackEnd: false,
            needsRecovery: true,
            hasPreparedAudio: true
        ) == .recoverFromInterruption)
    }

    @Test("A successful paused seek retargets pending recovery")
    func retargetsRecoveryAfterPausedSeek() {
        #expect(LocalSeekRecoveryPolicy.updateAfterSeek(
            targetTime: 84,
            didSucceed: true,
            shouldStartPlaying: false,
            isRecovery: false,
            needsRecovery: true
        ) == .retarget(84))
    }

    @Test("Failed and cancelled seeks preserve the pending recovery target")
    func preservesRecoveryAfterUnsuccessfulSeek() {
        #expect(LocalSeekRecoveryPolicy.updateAfterSeek(
            targetTime: 84,
            didSucceed: false,
            shouldStartPlaying: false,
            isRecovery: false,
            needsRecovery: true
        ) == .preserve)
    }

    @Test("A playing seek does not rewrite pending recovery")
    func preservesRecoveryDuringPlayingSeek() {
        #expect(LocalSeekRecoveryPolicy.updateAfterSeek(
            targetTime: 84,
            didSucceed: true,
            shouldStartPlaying: true,
            isRecovery: false,
            needsRecovery: true
        ) == .preserve)
    }

    @Test("Explicit recovery seeks retain the existing HFP recovery path")
    func preservesExplicitRecoverySeek() {
        #expect(LocalSeekRecoveryPolicy.updateAfterSeek(
            targetTime: 84,
            didSucceed: true,
            shouldStartPlaying: true,
            isRecovery: true,
            needsRecovery: true
        ) == .preserve)
    }
}
