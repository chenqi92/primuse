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

/// Controls the decorative, cover-driven color field used by the standard
/// Now Playing screen. It is deliberately separate from playback so a paused,
/// hidden, power-constrained, or thermally constrained app never keeps a
/// decorative timeline alive.
public struct NowPlayingAmbientMotionPolicy: Equatable, Sendable {
    public let hasArtworkPalette: Bool
    public let isAmbientVisible: Bool
    public let isVisible: Bool
    public let isSceneActive: Bool
    public let isPlaying: Bool
    public let reduceMotion: Bool
    public let isLowPowerModeEnabled: Bool
    public let thermalCondition: ArtworkThermalCondition
    public let paletteVibrancy: Double

    public init(
        hasArtworkPalette: Bool,
        isAmbientVisible: Bool,
        isVisible: Bool,
        isSceneActive: Bool,
        isPlaying: Bool,
        reduceMotion: Bool,
        isLowPowerModeEnabled: Bool,
        thermalCondition: ArtworkThermalCondition,
        paletteVibrancy: Double
    ) {
        self.hasArtworkPalette = hasArtworkPalette
        self.isAmbientVisible = isAmbientVisible
        self.isVisible = isVisible
        self.isSceneActive = isSceneActive
        self.isPlaying = isPlaying
        self.reduceMotion = reduceMotion
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalCondition = thermalCondition
        self.paletteVibrancy = min(max(paletteVibrancy, 0), 1)
    }

    public var shouldAnimate: Bool {
        hasArtworkPalette
            && isAmbientVisible
            && isVisible
            && isSceneActive
            && isPlaying
            && !reduceMotion
            && !isLowPowerModeEnabled
            && thermalCondition.permitsAnimation
    }

    /// The field moves slowly enough that 8–12 updates per second remain
    /// visually continuous while avoiding another display-rate render loop.
    public var minimumInterval: TimeInterval? {
        guard shouldAnimate else { return nil }
        return thermalCondition == .fair ? 1.0 / 8.0 : 1.0 / 12.0
    }

    public var cycleDuration: TimeInterval {
        30 - 6 * paletteVibrancy
    }

    /// Normalized center displacement. Muted covers stay almost still while
    /// vivid palettes can travel up to roughly 3.4% of the viewport.
    public var motionAmplitude: Double {
        guard hasArtworkPalette, isAmbientVisible, !reduceMotion else { return 0 }
        return 0.018 + 0.016 * paletteVibrancy
    }
}

public struct NowPlayingAmbientDarkOverlay: Equatable, Sendable {
    public let topOpacity: Double
    public let middleOpacity: Double
    public let bottomOpacity: Double

    public init(topOpacity: Double, middleOpacity: Double, bottomOpacity: Double) {
        self.topOpacity = topOpacity
        self.middleOpacity = middleOpacity
        self.bottomOpacity = bottomOpacity
    }
}

/// Keeps white player chrome legible over the brightest possible overlap of
/// the two artwork-driven color fields. The estimate is intentionally
/// conservative: both fields are treated as if their brightest centers meet.
public enum NowPlayingAmbientLegibilityPolicy {
    public static func darkOverlay(
        paletteLuminance: Double,
        primaryOpacity: Double,
        secondaryOpacity: Double,
        usesIncreasedContrast: Bool
    ) -> NowPlayingAmbientDarkOverlay {
        let luminance = clamp(paletteLuminance)
        let primary = clamp(primaryOpacity)
        let secondary = clamp(secondaryOpacity)
        let baseLuminance = 0.012
        let afterPrimary = baseLuminance * (1 - primary) + luminance * primary
        let estimatedFieldLuminance = afterPrimary * (1 - secondary) + luminance * secondary
        // Secondary labels use 72%-opaque white. Keeping the field at or
        // below these bounds preserves at least 4.5:1 contrast in the normal
        // mode and gives Increased Contrast a visibly stronger margin.
        let targetLuminance = usesIncreasedContrast ? 0.06 : 0.125
        let requiredOpacity = estimatedFieldLuminance > targetLuminance
            ? 1 - targetLuminance / estimatedFieldLuminance
            : 0

        let floors = usesIncreasedContrast
            ? (top: 0.32, middle: 0.38, bottom: 0.46)
            : (top: 0.18, middle: 0.22, bottom: 0.28)
        return NowPlayingAmbientDarkOverlay(
            topOpacity: max(floors.top, requiredOpacity),
            middleOpacity: max(floors.middle, requiredOpacity),
            bottomOpacity: max(floors.bottom, requiredOpacity)
        )
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
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
