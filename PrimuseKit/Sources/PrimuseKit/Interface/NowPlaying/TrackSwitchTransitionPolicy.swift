import Foundation

/// 切歌时封面与歌词过渡动画的纯规则。
///
/// 1. 封面：能判定下一首 / 上一首方向且允许方向切换时走原有滑动缩放换图；
///    其余切歌（从列表 / 搜索 / 队列直接点播、全铺封面、歌词模式缩略图、或开启减少动态效果）
///    统一走平滑的双层交叉渐变，不再硬切。
/// 2. 歌词：仅在歌曲切换或解析状态落地时触发简洁淡出 / 淡入，普通播放逐行滚动与逐字高亮不触发。
public enum TrackSwitchTransitionPolicy {
    public static let artworkCrossfadeDuration: TimeInterval = 0.28
    public static let lyricsFadeOutDuration: TimeInterval = 0.12
    public static let lyricsFadeInDuration: TimeInterval = 0.24
    public static let lyricsReducedMotionFadeInDuration: TimeInterval = 0.18
    /// 歌词淡入时轻微上浮的距离（减少动态效果下归零）。
    public static let lyricsEntranceOffsetY: Double = 6
    /// 交叉渐变时退场封面保持满不透明的进度阈值，避免中点双层半透明露出底色。
    public static let crossfadeExitHoldFraction: Double = 0.65

    public enum ArtworkTransitionMode: Equatable, Sendable {
        case none
        case directional(ArtworkSwapStyle)
        case crossfade
    }

    public struct LyricsTransitionSnapshot: Equatable, Sendable {
        public let songID: String?
        public let loadedSongID: String?
        public let hasLyrics: Bool
        public let isResolving: Bool

        public init(
            songID: String?,
            loadedSongID: String?,
            hasLyrics: Bool,
            isResolving: Bool
        ) {
            self.songID = songID
            self.loadedSongID = loadedSongID
            self.hasLyrics = hasLyrics
            self.isResolving = isResolving
        }
    }

    public enum LyricsTransitionAction: Equatable, Sendable {
        /// 无需过渡动画（同一首歌正常播放、滚动、翻译到达、或歌词不可见）。
        case none
        /// 刚切到新歌且新歌歌词尚未落地：轻柔淡出旧内容。
        case fadeOutPendingTrack
        /// 切到新歌且新内容已就绪（缓存秒出或加载完成）：平滑淡入。
        case fadeInTrack
        /// 同一首歌从加载骨架解析出正式歌词或空态：平滑淡入。
        case fadeInResolvedContent
    }

    public static func artworkTransition(
        outgoingSongID: String?,
        incomingSongID: String?,
        allowsDirectionalSwap: Bool,
        allowsCrossfadeSwap: Bool,
        reduceMotion: Bool,
        directionalStyle: ArtworkSwapStyle?
    ) -> ArtworkTransitionMode {
        guard let outgoingSongID, !outgoingSongID.isEmpty,
              let incomingSongID, !incomingSongID.isEmpty,
              outgoingSongID != incomingSongID else {
            return .none
        }
        if allowsDirectionalSwap, !reduceMotion, let directionalStyle {
            return .directional(directionalStyle)
        }
        if allowsCrossfadeSwap {
            return .crossfade
        }
        return .none
    }

    /// 交叉渐变时各层的不透明度。
    /// - Parameter signedProgress: `0` 静止；`-1 → 0` 入场层（盖在上层）；`0 → 1` 退场层（垫在下层）。
    /// 入场层匀速从 0 淡到 1；退场层在前 `crossfadeExitHoldFraction` 段保持 1 以防底色透出，收尾再淡到 0。
    public static func crossfadeLayerOpacity(signedProgress: Double) -> Double {
        guard signedProgress.isFinite else { return 1 }
        let progress = min(max(signedProgress, -1), 1)
        if progress < 0 {
            return 1 + progress
        }
        if progress <= crossfadeExitHoldFraction {
            return 1
        }
        let tail = 1 - crossfadeExitHoldFraction
        guard tail > 0 else { return 0 }
        return max(0, (1 - progress) / tail)
    }

    public static func lyricsTransitionAction(
        from previous: LyricsTransitionSnapshot,
        to current: LyricsTransitionSnapshot,
        isVisible: Bool
    ) -> LyricsTransitionAction {
        guard isVisible, previous != current else { return .none }
        if previous.songID != current.songID {
            guard previous.songID != nil, current.songID != nil else { return .none }
            if current.loadedSongID == current.songID && (!current.isResolving || current.hasLyrics) {
                return .fadeInTrack
            }
            return .fadeOutPendingTrack
        }
        guard current.songID != nil else { return .none }
        if previous.loadedSongID != current.loadedSongID, current.loadedSongID == current.songID {
            return .fadeInTrack
        }
        if (previous.isResolving && !current.isResolving) || (!previous.hasLyrics && current.hasLyrics) {
            return .fadeInResolvedContent
        }
        return .none
    }

    public static func lyricsFadeInDuration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? lyricsReducedMotionFadeInDuration : lyricsFadeInDuration
    }

    public static func lyricsEntranceOffset(isRevealed: Bool, reduceMotion: Bool) -> Double {
        (isRevealed || reduceMotion) ? 0 : lyricsEntranceOffsetY
    }
}
