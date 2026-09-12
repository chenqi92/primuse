import Foundation

public enum LocalPlaybackResumeAction: Equatable, Sendable {
    case restartCurrentSong
    case recoverFromInterruption
    case resumePreparedAudio
}

public enum LocalSeekRecoveryUpdate: Equatable, Sendable {
    case preserve
    case retarget(TimeInterval)
}

/// A successful manual seek while local playback is paused replaces the
/// prepared buffers but must keep interruption recovery armed. Retargeting the
/// pending time preserves any Bluetooth HFP resume ticket while ensuring the
/// later recovery starts from the position the user selected.
public enum LocalSeekRecoveryPolicy {
    public static func updateAfterSeek(
        targetTime: TimeInterval,
        didSucceed: Bool,
        shouldStartPlaying: Bool,
        isRecovery: Bool,
        needsRecovery: Bool
    ) -> LocalSeekRecoveryUpdate {
        guard didSucceed,
              !shouldStartPlaying,
              !isRecovery,
              needsRecovery else {
            return .preserve
        }
        return .retarget(max(0, targetTime))
    }
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

/// Tracks whether a hardware change invalidated the formats captured by the
/// current AVAudioEngine graph. The flag is cleared only after a replacement
/// graph is built successfully, so a failed attempt remains recoverable.
public struct AudioHardwareConfigurationRecoveryState: Equatable, Sendable {
    public private(set) var requiresGraphRebuild = false

    public init() {}

    public mutating func configurationChanged() {
        requiresGraphRebuild = true
    }

    public mutating func graphRebuiltSuccessfully() {
        requiresGraphRebuild = false
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

/// Bounds the complete-file materialization that playback recovery waits on.
/// A connector that keeps accepting connections but never returns bytes would
/// otherwise hold the visible loading state for the transfer's entire retry
/// budget (minutes) with the transport controls disabled. Any change in the
/// observed offline snapshot counts as activity; a snapshot that stays the
/// same for `stallTimeout` abandons the wait so ordinary failure handling runs.
public struct PlaybackRecoveryMaterializationStallMonitor: Equatable, Sendable {
    public static let defaultStallTimeout: TimeInterval = 45

    public let stallTimeout: TimeInterval
    public private(set) var lastObservedProgress: Double?
    public private(set) var lastObservedIsDownloading: Bool
    public private(set) var lastActivityAt: TimeInterval

    public init(
        startedAt: TimeInterval,
        stallTimeout: TimeInterval = Self.defaultStallTimeout
    ) {
        self.stallTimeout = max(1, stallTimeout)
        lastObservedProgress = nil
        lastObservedIsDownloading = false
        lastActivityAt = startedAt
    }

    /// Records one snapshot observation. Returns `true` once no activity has
    /// been observed for `stallTimeout`.
    public mutating func observe(
        progress: Double?,
        isDownloading: Bool,
        at now: TimeInterval
    ) -> Bool {
        if progress != lastObservedProgress || isDownloading != lastObservedIsDownloading {
            lastObservedProgress = progress
            lastObservedIsDownloading = isDownloading
            lastActivityAt = now
            return false
        }
        return now - lastActivityAt >= stallTimeout
    }
}
