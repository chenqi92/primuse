public struct NowPlayingPlaybackProjection: Equatable, Sendable {
    public var playbackRate: Double
    public var playCommandEnabled: Bool
    public var pauseCommandEnabled: Bool

    public init(
        playbackRate: Double,
        playCommandEnabled: Bool,
        pauseCommandEnabled: Bool
    ) {
        self.playbackRate = playbackRate
        self.playCommandEnabled = playCommandEnabled
        self.pauseCommandEnabled = pauseCommandEnabled
    }
}

/// Keeps the system play/pause affordance derived from the same state as the
/// in-app controls. A zero playback rate is the portable paused signal used by
/// iOS, while command availability prevents stale, non-idempotent actions.
public enum NowPlayingPlaybackProjectionPolicy {
    public static func projection(
        hasCurrentItem: Bool,
        isPlaying: Bool,
        isLoading: Bool = false,
        preferredPlaybackRate: Double
    ) -> NowPlayingPlaybackProjection {
        guard hasCurrentItem else {
            return NowPlayingPlaybackProjection(
                playbackRate: 0,
                playCommandEnabled: false,
                pauseCommandEnabled: false
            )
        }

        let safeRate = preferredPlaybackRate.isFinite && preferredPlaybackRate > 0
            ? preferredPlaybackRate
            : 1
        return NowPlayingPlaybackProjection(
            playbackRate: isPlaying ? safeRate : 0,
            playCommandEnabled: !isPlaying,
            pauseCommandEnabled: isPlaying
        )
    }
}

/// Keeps user playback intent separate from transient engine/UI state. System
/// interruptions may only resume the exact item/generation that was actively
/// playing when the interruption began. Any later user action invalidates the
/// pending ticket, so delayed callbacks cannot revive stale playback.
public struct PlaybackInterruptionResumePolicy: Equatable, Sendable {
    private struct Ticket: Equatable, Sendable {
        var intentGeneration: UInt64
        var itemID: String
    }

    public private(set) var playbackIsIntended: Bool
    private var intentGeneration: UInt64
    private var pendingTicket: Ticket?

    public init(playbackIsIntended: Bool = false) {
        self.playbackIsIntended = playbackIsIntended
        intentGeneration = 0
        pendingTicket = nil
    }

    public var isAwaitingInterruptionEnd: Bool {
        pendingTicket != nil
    }

    public mutating func registerPlayIntent() {
        advanceGeneration()
        playbackIsIntended = true
        pendingTicket = nil
    }

    public mutating func registerPauseOrStopIntent() {
        advanceGeneration()
        playbackIsIntended = false
        pendingTicket = nil
    }

    /// Queue/item/route replacement is a new generation even if playback is
    /// expected to continue. It must invalidate an older interruption ticket.
    public mutating func invalidatePendingResumePreservingIntent() {
        advanceGeneration()
        pendingTicket = nil
    }

    public mutating func interruptionBegan(
        wasActuallyPlaying: Bool,
        currentItemID: String?
    ) {
        guard playbackIsIntended,
              wasActuallyPlaying,
              let currentItemID,
              !currentItemID.isEmpty else {
            pendingTicket = nil
            return
        }
        pendingTicket = Ticket(
            intentGeneration: intentGeneration,
            itemID: currentItemID
        )
    }

    /// Returns `true` exactly once when system permission, user intent, item
    /// identity and playback generation all still match the interruption.
    public mutating func interruptionEnded(
        systemShouldResume: Bool,
        currentItemID: String?
    ) -> Bool {
        guard let ticket = pendingTicket else { return false }
        pendingTicket = nil

        guard systemShouldResume,
              playbackIsIntended,
              ticket.intentGeneration == intentGeneration,
              ticket.itemID == currentItemID else {
            if ticket.intentGeneration == intentGeneration {
                advanceGeneration()
                playbackIsIntended = false
            }
            return false
        }
        return true
    }

    private mutating func advanceGeneration() {
        intentGeneration &+= 1
    }
}

public enum RemotePlayCommandAction: Equatable, Sendable {
    case noActionableItem
    case alreadyPlaying
    case awaitInFlightRequest
    case retryLoadingPlayback
    case resume
}

public enum RemotePlayCommandPolicy {
    public static func action(
        hasCurrentItem: Bool,
        isPlaybackActuallyActive: Bool,
        isLoading: Bool,
        playbackIsIntended: Bool
    ) -> RemotePlayCommandAction {
        guard hasCurrentItem else { return .noActionableItem }
        if isPlaybackActuallyActive { return .alreadyPlaying }
        if isLoading {
            return playbackIsIntended ? .awaitInFlightRequest : .retryLoadingPlayback
        }
        return .resume
    }
}
