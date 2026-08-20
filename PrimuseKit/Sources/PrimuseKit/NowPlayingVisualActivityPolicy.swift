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
