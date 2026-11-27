import Foundation

public enum NowPlayingLandscapeMode: Equatable, Sendable {
    case none
    case standardLyrics
    case immersiveLyrics
    case musicVideo
}

/// Keeps landscape presentation priority deterministic. Video always owns the
/// screen while active; lyrics use their immersive composition only after the
/// explicit full-screen action, never merely because normal lyrics are visible.
public enum NowPlayingLandscapePolicy {
    public static func mode(
        viewportWidth: Double,
        viewportHeight: Double,
        isMusicVideoActive: Bool,
        areLyricsVisible: Bool,
        areLyricsImmersive: Bool
    ) -> NowPlayingLandscapeMode {
        guard viewportWidth > viewportHeight else { return .none }
        if isMusicVideoActive { return .musicVideo }
        guard areLyricsVisible else { return .none }
        return areLyricsImmersive ? .immersiveLyrics : .standardLyrics
    }
}

public enum NowPlayingPlayerLayoutMode: Equatable, Sendable {
    case portrait
    case compactLandscape
    case wideLandscape
}

/// Chooses the regular player composition independently from lyrics/video
/// takeovers. Compact-width landscape windows need a dedicated horizontal
/// layout; squeezing the portrait stack below a phone's short edge clips the
/// volume/footer rows and places metadata under the sensor housing.
public enum NowPlayingPlayerLayoutPolicy {
    /// Plus/Pro Max phones report a regular width class in landscape, so the
    /// width class alone sends them into the iPad two-column composition that
    /// is laid out for a full-height canvas. The height class is what actually
    /// separates a phone in landscape from a tablet.
    ///
    /// iPhone Duo 展开的内屏也是常规宽度、常规高度，但它仍是手持的 iPhone：iPad 那套两栏
    /// 按一千多点的高度标定，放到六百多点的内屏上会压扁、互相重叠。iPhone 上一律走手机的横屏骨架。
    public static func prefersWideColumns(
        isRegularWidth: Bool,
        isCompactHeight: Bool,
        isPhone: Bool = false
    ) -> Bool {
        isRegularWidth && !isCompactHeight && !isPhone
    }

    /// 横屏时封面、歌词、全屏歌词共用同一副骨架（顶部圆钮排、左栏、右栏进度与传输键），
    /// 三种模式之间切换时控件原地不动。MV 横屏另有整屏的版式。
    public static func usesLandscapeSkeleton(
        layoutMode: NowPlayingPlayerLayoutMode,
        landscapeMode: NowPlayingLandscapeMode
    ) -> Bool {
        layoutMode == .compactLandscape && landscapeMode != .musicVideo
    }

    public static func mode(
        viewportWidth: Double,
        viewportHeight: Double,
        prefersWideColumns: Bool
    ) -> NowPlayingPlayerLayoutMode {
        guard viewportWidth > viewportHeight else { return .portrait }
        return prefersWideColumns ? .wideLandscape : .compactLandscape
    }
}
