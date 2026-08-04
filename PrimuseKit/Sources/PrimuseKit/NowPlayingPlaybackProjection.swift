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

        if isLoading {
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
