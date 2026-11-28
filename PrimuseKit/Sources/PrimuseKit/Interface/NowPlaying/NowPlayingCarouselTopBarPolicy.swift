import Foundation

/// 播放页转轮顶部导航栏的自动隐藏规则。
///
/// 交互结束 `autoHideDelay` 秒后自动收起：
/// - 在主播放页（`.player`）上轻柔淡出 / 收进顶部把手区域；
/// - 在其它任意转轮面（调音、发现、接下来、舞台、歌词、评论）上先收拢成圆球，再弹入侧边边缘。
/// 横向滑动翻页、切页或点按顶部唤醒区时立刻弹回。
public enum NowPlayingCarouselTopBarPolicy {
    /// 交互停止后多久自动隐藏（2–3 秒区间）。
    public static let autoHideDelay: TimeInterval = 2.5
    /// 胶囊收拢为圆球阶段的大致时长。
    public static let ballCollapseDuration: TimeInterval = 0.24
    /// 圆球弹入侧边边缘阶段的大致时长。
    public static let edgeTuckDuration: TimeInterval = 0.28

    /// 转轮顶部栏收进哪一侧边缘（逻辑方向，RTL 下自动镜像）。
    public enum EdgeSide: Equatable, Sendable {
        case leading
        case trailing

        /// 转成 SwiftUI `.offset(x:)` 使用的物理水平方向（负值向左、正值向右）。
        public func physicalHorizontalSign(isRightToLeft: Bool) -> Double {
            switch (self, isRightToLeft) {
            case (.leading, false), (.trailing, true):
                return -1
            case (.leading, true), (.trailing, false):
                return 1
            }
        }
    }

    /// 顶部栏的目标隐藏形态。
    public enum Presentation: Equatable, Sendable {
        case visible
        case fadedOnPlayer
        case tuckedToEdge(edge: EdgeSide)

        public var isHidden: Bool { self != .visible }
    }

    /// 顶部栏动画所处的具体阶段（非主播放页分「收成圆球 → 收入侧边」两段）。
    public enum HideStage: Equatable, Sendable {
        case visible
        case fadedOnPlayer
        case collapsedToBall(edge: EdgeSide)
        case tuckedOffEdge(edge: EdgeSide)

        public var allowsDirectBarHitTesting: Bool { self == .visible }

        public var isFullyHidden: Bool {
            switch self {
            case .fadedOnPlayer, .tuckedOffEdge:
                return true
            case .visible, .collapsedToBall:
                return false
            }
        }
    }

    public struct Conditions: Equatable, Sendable {
        public var settledPage: NowPlayingCarouselPage
        public var pageCount: Int
        public var isActive: Bool
        public var isSurfaceExposed: Bool
        public var isLyricsOverlayVisible: Bool
        public var isDragging: Bool
        public var isSettling: Bool
        public var isControlEditing: Bool
        public var isVoiceOverRunning: Bool

        public init(
            settledPage: NowPlayingCarouselPage,
            pageCount: Int,
            isActive: Bool,
            isSurfaceExposed: Bool,
            isLyricsOverlayVisible: Bool,
            isDragging: Bool,
            isSettling: Bool,
            isControlEditing: Bool,
            isVoiceOverRunning: Bool
        ) {
            self.settledPage = settledPage
            self.pageCount = pageCount
            self.isActive = isActive
            self.isSurfaceExposed = isSurfaceExposed
            self.isLyricsOverlayVisible = isLyricsOverlayVisible
            self.isDragging = isDragging
            self.isSettling = isSettling
            self.isControlEditing = isControlEditing
            self.isVoiceOverRunning = isVoiceOverRunning
        }
    }

    /// 是否需要挂起触摸观察器来追踪玩家交互并顺延倒计时。
    public static func tracksActivity(_ conditions: Conditions) -> Bool {
        conditions.isActive
            && conditions.pageCount > 1
            && conditions.isSurfaceExposed
            && !conditions.isLyricsOverlayVisible
    }

    /// 此刻是否允许进入或完成自动隐藏倒计时。
    /// 正在拖动、转到位、编辑面内控件（滑杆 / 捏合）或开启旁白时不隐藏。
    public static func mayAutoHide(_ conditions: Conditions) -> Bool {
        tracksActivity(conditions)
            && !conditions.isDragging
            && !conditions.isSettling
            && !conditions.isControlEditing
            && !conditions.isVoiceOverRunning
    }

    /// 距离自动隐藏还需等待的秒数；正在触摸操作或时钟异常时重新计满一段。
    public static func remainingDelay(sinceLastActivity elapsed: TimeInterval, isInteracting: Bool) -> TimeInterval {
        guard !isInteracting, elapsed.isFinite, elapsed >= 0 else { return autoHideDelay }
        return max(0, autoHideDelay - elapsed)
    }

    /// 某一页进入隐藏时应采用的形态：主播放页轻柔淡出，其余页面收球并收入顶部栏所在的逻辑起始侧边缘。
    public static func hiddenPresentation(for settledPage: NowPlayingCarouselPage) -> Presentation {
        switch settledPage {
        case .player:
            return .fadedOnPlayer
        case .panel:
            return .tuckedToEdge(edge: .leading)
        }
    }

    /// 非主播放页是否执行两段式「收成圆球 → 弹入侧边」动效；开启减少动态效果时退化为柔和淡出。
    public static func usesBallTuckAnimation(
        for presentation: Presentation,
        reduceMotion: Bool
    ) -> Bool {
        guard !reduceMotion else { return false }
        if case .tuckedToEdge = presentation { return true }
        return false
    }

    /// 圆球收入侧边时的物理水平位移（以点为单位）。
    public static func tuckOffsetX(
        edge: EdgeSide,
        barLeadingInset: Double,
        ballDiameter: Double,
        isRightToLeft: Bool
    ) -> Double {
        let travel = max(barLeadingInset, 0) + max(ballDiameter, 0) + 14
        return edge.physicalHorizontalSign(isRightToLeft: isRightToLeft) * travel
    }

    /// 普通触摸落在屏幕任意处时，如果顶部栏正在收拢途中则立即打断并恢复可见；
    /// 已彻底收起时保持安静，等待左右横滑、切页或点按顶部唤醒区再弹出。
    public static func shouldAbortHideOnGeneralTouch(stage: HideStage) -> Bool {
        if case .collapsedToBall = stage { return true }
        return false
    }
}
