import Foundation

public enum LocalPlaybackResumeAction: Equatable, Sendable {
    case restartCurrentSong
    case recoverFromInterruption
    case resumePreparedAudio
}

/// Synchronizes the observable player state only after the audio engine has
/// already restarted successfully. It never decides whether an interruption
/// should resume, so phone calls and Siri retain the system policy.
public enum AudioConfigurationRecoveryPolicy {
    public static func shouldRestorePlayingState(
        playbackWasIntended: Bool,
        engineRestarted: Bool
    ) -> Bool {
        playbackWasIntended && engineRestarted
    }
}

public enum DecodedBufferHealthAction: Equatable, Sendable {
    case none
    case rebuildPipeline
    case stopPlayback
}

/// Decides whether a local decoded-audio pipeline has genuinely stopped
/// feeding the output node. Requiring consecutive unhealthy samples filters
/// the normal hand-off between two PCM buffers; finished decoders are left to
/// their final-buffer completion and track-end watchdog.
public enum DecodedBufferHealthPolicy {
    public static func action(
        isPlaying: Bool,
        hasPreparedAudio: Bool,
        isLoading: Bool,
        isTransitioning: Bool,
        engineIsPlaying: Bool,
        decoderFinished: Bool,
        bufferedDuration: TimeInterval,
        bufferCount: Int,
        emptyDurationThreshold: TimeInterval,
        consecutiveUnhealthySamples: Int,
        requiredUnhealthySamples: Int,
        recoveryInProgress: Bool,
        recoveryAttempts: Int,
        maximumRecoveryAttempts: Int,
        cooldownElapsed: TimeInterval,
        minimumCooldown: TimeInterval
    ) -> DecodedBufferHealthAction {
        guard isPlaying,
              hasPreparedAudio,
              !isLoading,
              !isTransitioning,
              !decoderFinished,
              !recoveryInProgress,
              cooldownElapsed >= minimumCooldown else {
            return .none
        }

        let queueIsEmpty = bufferCount <= 0
            && bufferedDuration <= max(0, emptyDurationThreshold)
        guard !engineIsPlaying || queueIsEmpty else { return .none }
        guard consecutiveUnhealthySamples >= max(1, requiredUnhealthySamples) else {
            return .none
        }
        if recoveryAttempts >= max(0, maximumRecoveryAttempts) {
            return .stopPlayback
        }
        return .rebuildPipeline
    }
}

/// A selected queue row is not proof that the local audio engine has decoded
/// and scheduled audio. Retrying after URL/authentication failure must rebuild
/// the pipeline instead of marking an empty player node as playing.
public enum LocalPlaybackResumePolicy {
    public static func action(
        isAtTrackEnd: Bool,
        needsRecovery: Bool,
        hasPreparedAudio: Bool
    ) -> LocalPlaybackResumeAction {
        if isAtTrackEnd {
            return .restartCurrentSong
        }
        if needsRecovery {
            return .recoverFromInterruption
        }
        return hasPreparedAudio ? .resumePreparedAudio : .restartCurrentSong
    }
}
