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

/// 浅色播放页背景几层的浓淡:两团封面色的不透明度,和压在上面那层白色的上下两端。
public struct NowPlayingLightAmbientLevels: Equatable, Sendable {
    public let primaryOpacity: Double
    public let secondaryOpacity: Double
    public let overlayTopOpacity: Double
    public let overlayBottomOpacity: Double

    public init(
        primaryOpacity: Double,
        secondaryOpacity: Double,
        overlayTopOpacity: Double,
        overlayBottomOpacity: Double
    ) {
        self.primaryOpacity = primaryOpacity
        self.secondaryOpacity = secondaryOpacity
        self.overlayTopOpacity = overlayTopOpacity
        self.overlayBottomOpacity = overlayBottomOpacity
    }

    func interpolated(to end: NowPlayingLightAmbientLevels, progress: Double) -> NowPlayingLightAmbientLevels {
        let t = min(max(progress, 0), 1)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return NowPlayingLightAmbientLevels(
            primaryOpacity: mix(primaryOpacity, end.primaryOpacity),
            secondaryOpacity: mix(secondaryOpacity, end.secondaryOpacity),
            overlayTopOpacity: mix(overlayTopOpacity, end.overlayTopOpacity),
            overlayBottomOpacity: mix(overlayBottomOpacity, end.overlayBottomOpacity)
        )
    }
}

/// 浅色播放页的「氛围强度」调过默认值以后,背景往封面颜色上靠到多浓(#69)。
///
/// 默认值以下照旧;往上走时封面色加浓、白色罩层变薄,拉满时接近封面本身的颜色。
/// 浅色外观的字是深色的,封面色太深时背景不能跟着变深:估算有字的地方最暗能到多少,
/// 加浓到那里还压得住深色字为止,而且不会比默认强度时更暗。
///
/// 估算按画法里几团颜色的摆位来:主色在左上、副色在右下、暗色在中间,各自从中心往外淡。
/// 歌名、歌词所在的那一片最多吃到主色的八成、副色的不到一半、暗色的四分之三;
/// 都按中心叠在一起算的话,偏红偏深的封面一点都加不浓,滑杆往上拉看不出变化。
public enum NowPlayingLightAmbientPolicy {
    /// 背景底色(0.94 的浅灰)在 sRGB 编码下的亮度。
    static let baseLuma = 0.945
    /// 中间那团暗色是主色压暗到 0.65 的版本,不透明度是第二团的 0.42 倍(和画法一致)。
    static let darkFieldBrightness = 0.65
    static let darkFieldOpacityRatio = 0.42
    /// 有字的那一片最多吃到的比例(主色、副色、暗色)。
    static let primaryReach = 0.8
    static let secondaryReach = 0.45
    static let darkFieldReach = 0.75

    /// - Parameters:
    ///   - atDefault: 默认强度下这几层的取值。
    ///   - vivid: 拉满时想要的取值。
    ///   - strength: 用户设的强度(0…1)。
    ///   - defaultStrength: 默认强度。
    ///   - primaryLuma: 主色在 sRGB 编码下的亮度(0…1)。
    ///   - secondaryLuma: 副色在 sRGB 编码下的亮度(0…1)。
    ///   - usesIncreasedContrast: 「增强对比度」打开时下限更高。
    public static func levels(
        atDefault: NowPlayingLightAmbientLevels,
        vivid: NowPlayingLightAmbientLevels,
        strength: Double,
        defaultStrength: Double,
        primaryLuma: Double,
        secondaryLuma: Double,
        usesIncreasedContrast: Bool
    ) -> NowPlayingLightAmbientLevels {
        guard strength > defaultStrength, defaultStrength < 1 else { return atDefault }
        let progress = min((strength - defaultStrength) / (1 - defaultStrength), 1)
        let lumas = (primary: min(max(primaryLuma, 0), 1), secondary: min(max(secondaryLuma, 0), 1))
        let floor = min(
            minimumLuma(usesIncreasedContrast: usesIncreasedContrast),
            darkestLuma(atDefault, primaryLuma: lumas.primary, secondaryLuma: lumas.secondary)
        )
        let full = atDefault.interpolated(to: vivid, progress: progress)
        if darkestLuma(full, primaryLuma: lumas.primary, secondaryLuma: lumas.secondary) >= floor { return full }

        // 最暗处随加浓的程度单调变暗,二分找出刚好压得住的那一档。
        var low = 0.0
        var high = 1.0
        for _ in 0..<24 {
            let middle = (low + high) / 2
            let candidate = atDefault.interpolated(to: vivid, progress: progress * middle)
            if darkestLuma(candidate, primaryLuma: lumas.primary, secondaryLuma: lumas.secondary) >= floor {
                low = middle
            } else {
                high = middle
            }
        }
        return atDefault.interpolated(to: vivid, progress: progress * low)
    }

    /// 最暗处至少要有的亮度:深灰色的次要文字在上面仍有大约 4.5:1。
    public static func minimumLuma(usesIncreasedContrast: Bool) -> Double {
        usesIncreasedContrast ? 0.66 : 0.58
    }

    /// 有字那一片最暗的地方:按各团颜色能伸到那里的比例叠上去,再盖上白色罩层较薄的下端。
    static func darkestLuma(
        _ levels: NowPlayingLightAmbientLevels,
        primaryLuma: Double,
        secondaryLuma: Double
    ) -> Double {
        let primary = min(max(levels.primaryOpacity, 0), 1) * primaryReach
        let secondaryOpacity = min(max(levels.secondaryOpacity, 0), 1)
        let secondary = secondaryOpacity * secondaryReach
        let dark = min(secondaryOpacity * darkFieldOpacityRatio, 1) * darkFieldReach
        let wash = min(max(levels.overlayBottomOpacity, 0), 1)
        var luma = baseLuma * (1 - primary) + primaryLuma * primary
        luma = luma * (1 - secondary) + secondaryLuma * secondary
        luma = luma * (1 - dark) + primaryLuma * darkFieldBrightness * dark
        return luma * (1 - wash) + wash
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
