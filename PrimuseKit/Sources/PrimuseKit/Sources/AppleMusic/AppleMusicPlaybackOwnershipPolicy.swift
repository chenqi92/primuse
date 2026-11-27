import Foundation

/// Keeps Primuse's dormant AVAudioSession notifications from overriding the
/// system-owned MusicKit transport during local/Apple Music queue handoffs.
public enum AppleMusicAudioSessionInterruptionPolicy {
    /// A pending request has normally produced no audio and is cancelled
    /// instead. Once MusicKit holds its queue and is starting, the
    /// interruption is that start taking the route from the dormant local
    /// session, and cancelling would stop the song as it begins.
    public static func shouldDeferToSystemTransport(
        hasActivePlaybackRequest: Bool,
        requestIsPending: Bool,
        systemStartIsInFlight: Bool = false
    ) -> Bool {
        hasActivePlaybackRequest && (!requestIsPending || systemStartIsInFlight)
    }

    public static func shouldClearSuppression(
        isPlaying: Bool,
        madeProgress: Bool
    ) -> Bool {
        isPlaying && madeProgress
    }
}

/// Whether an Apple Music start that failed may move on to the next song, as
/// a broken local file does. Authorization and subscription failures stay on
/// the song: every Apple Music entry would fail the same way. Skips are
/// bounded so an outage cannot walk an all-Apple-Music queue indefinitely.
public struct AppleMusicStartFailureSkipPolicy: Equatable, Sendable {
    public static let maximumSkips = 5
    public static let window: TimeInterval = 180

    private var recentSkipTimes: [TimeInterval] = []

    public init() {}

    /// `uptime` is a monotonic clock reading in seconds.
    public mutating func shouldSkip(failureStopsSource: Bool, at uptime: TimeInterval) -> Bool {
        guard !failureStopsSource else { return false }
        recentSkipTimes.removeAll { uptime - $0 >= Self.window }
        guard recentSkipTimes.count < Self.maximumSkips else { return false }
        recentSkipTimes.append(uptime)
        return true
    }

    /// A start that succeeded ends the run of failures.
    public mutating func recordStart() {
        guard !recentSkipTimes.isEmpty else { return }
        recentSkipTimes.removeAll()
    }
}

/// Keeps playback-owner transitions consistent without depending on any Apple
/// framework types. A pending Apple Music request already owns the upcoming
/// audio session even before its song has reached the shared now-playing UI.
public enum AppleMusicPlaybackOwnershipPolicy {
    /// Every local playback entry point must await a renderer Stop that was
    /// detached for an Apple Music handoff. Looking only at the visible cast
    /// controller is insufficient because it is nil while Stop is in flight.
    public static func shouldAwaitCastingHandoff(
        isLocalPlayback: Bool,
        hasPendingHandoff: Bool
    ) -> Bool {
        isLocalPlayback && hasPendingHandoff
    }

    public static func canStartCasting(
        isAppleMusicMode: Bool,
        hasActivePlaybackRequest: Bool
    ) -> Bool {
        !isAppleMusicMode && !hasActivePlaybackRequest
    }

    /// Local decoder callbacks need a fresh generation at end-of-track. Apple
    /// Music natural-end callbacks are already request-scoped, and retaining
    /// their token keeps the state mirror alive for replay from the stopped UI.
    public static func shouldInvalidatePlayIDAtTrackEnd(
        isAppleMusicMode: Bool,
        hasActivePlaybackRequest: Bool
    ) -> Bool {
        !isAppleMusicMode && !hasActivePlaybackRequest
    }
}
