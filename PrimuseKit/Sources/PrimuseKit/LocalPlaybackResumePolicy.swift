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

public enum RemotePlaybackBufferingAction: Equatable, Sendable {
    case none
    case begin
    case wait
    case resume
    case stop
}

/// An empty remote PCM queue can mean the decoder is still waiting for a
/// Range response. Keep that request alive instead of downloading the entire
/// source file, which may contain many CUE tracks.
public enum RemotePlaybackBufferingPolicy {
    public static let maximumWait: TimeInterval = 30

    public static func action(
        isEligible: Bool,
        engineIsPlaying: Bool,
        decoderFinished: Bool,
        bufferedDuration: TimeInterval,
        bufferCount: Int,
        bufferingElapsed: TimeInterval?,
        producerIsBackpressured: Bool = false
    ) -> RemotePlaybackBufferingAction {
        guard isEligible else { return .none }
        guard let elapsed = bufferingElapsed else {
            return engineIsPlaying && !decoderFinished && bufferCount == 0
                && bufferedDuration <= 0.05 ? .begin : .none
        }
        // The final buffer is scheduled outside the gate. A finished decoder
        // must be allowed to play that tail even when its snapshot is empty.
        if decoderFinished { return .resume }
        // Byte/count limits may prevent high-rate audio from accumulating a
        // whole second. Do not deadlock a paused node behind that backpressure.
        if bufferCount > 0, bufferedDuration > 0,
           bufferedDuration >= 1 || producerIsBackpressured {
            return .resume
        }
        return elapsed >= maximumWait ? .stop : .wait
    }
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

    /// Treats an external wait that legitimately blocks the transfer, such as a
    /// certificate prompt awaiting the user, as activity.
    public mutating func recordActivity(at now: TimeInterval) {
        lastActivityAt = now
    }
}

/// A pause only stops the player node: the decoder, the buffers it already
/// scheduled and the output graph stay where they were. Playing them again is
/// instant, while rebuilding means resolving the address again and, for a
/// network source, waiting for the stream to answer. Anything that may have
/// disturbed that pipeline since the pause sends Play back to the rebuild.
public enum PausedPipelineResumePolicy {
    /// After this long a network address or session may have expired, and the
    /// rebuild costs little next to how long playback was stopped.
    public static let maximumPauseDuration: TimeInterval = 10 * 60

    public struct Evidence: Equatable, Sendable {
        /// Same play generation and item as at the pause, with no
        /// interruption or hardware change reported since.
        public var pipelineIsUnchanged: Bool
        /// Recovery was already needed before this pause (an interruption, a
        /// failed start); the pause did not create that need.
        public var recoveryWasArmedBeforePause: Bool
        public var pausedFor: TimeInterval
        public var hasPreparedAudio: Bool
        public var isAtTrackEnd: Bool
        public var isLoading: Bool
        public var isTransitioning: Bool
        public var outputGraphNeedsRebuild: Bool
        /// The last buffer was handed to the node before the pause. Its
        /// end-of-track callback carries the ticket the pause retired, so the
        /// song would end without moving on.
        public var finalBufferAlreadyScheduled: Bool
        public var decoderIsAlive: Bool

        public init(
            pipelineIsUnchanged: Bool,
            recoveryWasArmedBeforePause: Bool,
            pausedFor: TimeInterval,
            hasPreparedAudio: Bool,
            isAtTrackEnd: Bool,
            isLoading: Bool,
            isTransitioning: Bool,
            outputGraphNeedsRebuild: Bool,
            finalBufferAlreadyScheduled: Bool,
            decoderIsAlive: Bool
        ) {
            self.pipelineIsUnchanged = pipelineIsUnchanged
            self.recoveryWasArmedBeforePause = recoveryWasArmedBeforePause
            self.pausedFor = pausedFor
            self.hasPreparedAudio = hasPreparedAudio
            self.isAtTrackEnd = isAtTrackEnd
            self.isLoading = isLoading
            self.isTransitioning = isTransitioning
            self.outputGraphNeedsRebuild = outputGraphNeedsRebuild
            self.finalBufferAlreadyScheduled = finalBufferAlreadyScheduled
            self.decoderIsAlive = decoderIsAlive
        }
    }

    public static func canResumeInPlace(_ evidence: Evidence) -> Bool {
        evidence.pipelineIsUnchanged
            && !evidence.recoveryWasArmedBeforePause
            && evidence.pausedFor >= 0
            && evidence.pausedFor <= maximumPauseDuration
            && evidence.hasPreparedAudio
            && !evidence.isAtTrackEnd
            && !evidence.isLoading
            && !evidence.isTransitioning
            && !evidence.outputGraphNeedsRebuild
            && !evidence.finalBufferAlreadyScheduled
            && evidence.decoderIsAlive
    }
}

/// A start, seek or resume waits for its first decoded buffer with the
/// transport controls showing a spinner. A source that keeps delivering bytes,
/// however slowly, is still working; one that has delivered nothing for
/// `stallTimeout` will not, and holding the spinner longer only hides that.
public enum SeekFirstBufferStallPolicy {
    public static let stallTimeout: TimeInterval = 35

    public static func hasStalled(
        startedAt: TimeInterval,
        lastTransferAt: TimeInterval?,
        now: TimeInterval,
        timeout: TimeInterval = stallTimeout
    ) -> Bool {
        let lastActivity = max(startedAt, lastTransferAt ?? startedAt)
        return now - lastActivity >= max(1, timeout)
    }
}

/// Background transfers stop as soon as conditions turn against them but start
/// again only once conditions have stayed good for a while. A Wi-Fi path that
/// keeps flipping between metered and unmetered, or playback that buffers at
/// every start, otherwise cancels each transfer before its first chunk lands
/// and starts it again seconds later, over and over.
public struct TransferConditionSettleGate: Equatable, Sendable {
    public static let defaultSettleInterval: TimeInterval = 20

    public let settleInterval: TimeInterval
    public private(set) var isAllowed: Bool
    public private(set) var settledAt: TimeInterval?

    /// Conditions already good at launch need no settling.
    public init(allowed: Bool, settleInterval: TimeInterval = Self.defaultSettleInterval) {
        self.settleInterval = max(0, settleInterval)
        isAllowed = allowed
        settledAt = nil
    }

    public mutating func observe(allowed: Bool, now: TimeInterval) {
        if allowed, !isAllowed {
            settledAt = now + settleInterval
        } else if !allowed {
            settledAt = nil
        }
        isAllowed = allowed
    }

    public func allowsStart(now: TimeInterval) -> Bool {
        isAllowed && (settledAt.map { now >= $0 } ?? true)
    }

    /// How long until transfers may start, or nil when they may start now or
    /// are blocked by the conditions themselves.
    public func remainingSettle(now: TimeInterval) -> TimeInterval? {
        guard isAllowed, let settledAt, now < settledAt else { return nil }
        return settledAt - now
    }
}
