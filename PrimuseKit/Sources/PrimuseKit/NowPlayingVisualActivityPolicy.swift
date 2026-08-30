import Foundation

/// Pure policy for deciding whether high-frequency Now Playing visuals may run.
/// Audio playback and its background bookkeeping are deliberately outside this policy.
public struct NowPlayingVisualActivityPolicy: Equatable, Sendable {
    public let isSceneActive: Bool
    public let isPlaying: Bool
    public let usesRealtimeSpectrum: Bool
    public let reduceMotion: Bool

    public init(
        isSceneActive: Bool,
        isPlaying: Bool,
        usesRealtimeSpectrum: Bool,
        reduceMotion: Bool
    ) {
        self.isSceneActive = isSceneActive
        self.isPlaying = isPlaying
        self.usesRealtimeSpectrum = usesRealtimeSpectrum
        self.reduceMotion = reduceMotion
    }

    public var shouldRunVisualizer: Bool {
        isSceneActive && isPlaying && usesRealtimeSpectrum
    }

    public var shouldRunStageClock: Bool {
        isSceneActive && isPlaying
    }

    public var shouldAnimateStage: Bool {
        shouldRunStageClock && !reduceMotion
    }

    public var shouldPollLyrics: Bool {
        isSceneActive && isPlaying
    }

    public var shouldRunWordTimeline: Bool {
        shouldPollLyrics && !reduceMotion
    }
}

public enum KaraokeTimelineInvalidationScope: Equatable, Sendable {
    case none
    case progressMask
}

public struct KaraokeTimelineUpdatePlan: Equatable, Sendable {
    public let rendersSyllableProgress: Bool
    public let runsTimeline: Bool
    public let invalidationScope: KaraokeTimelineInvalidationScope
    public let minimumInterval: TimeInterval?

    public init(
        rendersSyllableProgress: Bool,
        runsTimeline: Bool,
        invalidationScope: KaraokeTimelineInvalidationScope,
        minimumInterval: TimeInterval?
    ) {
        self.rendersSyllableProgress = rendersSyllableProgress
        self.runsTimeline = runsTimeline
        self.invalidationScope = invalidationScope
        self.minimumInterval = minimumInterval
    }
}

/// Keeps the playback clock out of lyric measurement and row placement.
/// A live line may invalidate its progress mask, while inactive and frozen
/// lines remain static snapshots.
public enum KaraokeTimelineUpdatePolicy {
    public static func plan(
        isLineActive: Bool,
        isPlaybackActive: Bool,
        hasFixedPlaybackTime: Bool,
        reduceMotion: Bool
    ) -> KaraokeTimelineUpdatePlan {
        guard isLineActive else {
            return KaraokeTimelineUpdatePlan(
                rendersSyllableProgress: false,
                runsTimeline: false,
                invalidationScope: .none,
                minimumInterval: nil
            )
        }

        guard isPlaybackActive, !hasFixedPlaybackTime else {
            return KaraokeTimelineUpdatePlan(
                rendersSyllableProgress: true,
                runsTimeline: false,
                invalidationScope: .none,
                minimumInterval: nil
            )
        }

        return KaraokeTimelineUpdatePlan(
            rendersSyllableProgress: true,
            runsTimeline: true,
            invalidationScope: .progressMask,
            minimumInterval: reduceMotion ? 0.10 : 1.0 / 30.0
        )
    }
}
