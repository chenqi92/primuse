import Foundation

/// 详情页头图跟着滚动的那几种动效：下拉拉伸、上滚视差、标题滚进导航栏。
///
/// 只算变换（缩放、位移）和一个显隐开关，不改任何布局尺寸 —— 头图高度一动，
/// 滚动视图的内容高度跟着变，滚动位置又反过来影响头图，就成了反馈环。
public enum LibraryDetailHeroMotionPolicy {
    /// 上滚时头图跟随内容的速度（0 = 钉住不动，1 = 与内容同速）。
    public static let parallaxFactor: Double = 0.5
    /// 浮在底色上的封面下拉时最多放大到这么多。
    public static let artworkMaximumScale: Double = 1.2
    /// 导航栏标题显隐的滞回带宽：过线 6 点才出现，退回 6 点才消失，停在线上不闪。
    public static let inlineTitleHysteresis: Double = 12

    public struct Transform: Equatable, Sendable {
        public let scale: Double
        /// 相对头图原位的纵向位移，向下为正。
        public let offsetY: Double

        public static let identity = Transform(scale: 1, offsetY: 0)

        public init(scale: Double, offsetY: Double) {
            self.scale = scale
            self.offsetY = offsetY
        }
    }

    /// 铺满整幅的头图（艺术家海报、封面墙）。以上沿为锚点缩放。
    ///
    /// - Parameters:
    ///   - pull: 头图上沿离静止位置的距离：下拉超出顶部为正，向上滚为负。
    ///   - height: 头图高度。
    /// - Returns: 下拉时上沿钉在屏幕顶上、按拉出来的距离放大，正好填满拉开的空隙；
    ///   上滚时以半速跟随内容，比正文走得慢。
    public static func poster(pull: Double, height: Double) -> Transform {
        guard height > 0, pull.isFinite else { return .identity }
        if pull > 0 {
            return Transform(scale: (height + pull) / height, offsetY: -pull)
        }
        // 上滚最多跟到头图完全离开屏幕为止，再往后的位移看不见，不必再算。
        let scrolled = min(-pull, height)
        return Transform(scale: 1, offsetY: scrolled * (1 - parallaxFactor))
    }

    /// 浮在整页底色上的封面（专辑、单封面歌单、风格马赛克）。以下沿为锚点缩放。
    ///
    /// 下拉时往上长进拉开的空隙，最多放大到 `artworkMaximumScale`；上滚不动 ——
    /// 封面下面紧挨着标题，走得比正文慢就会压到标题上。
    public static func artwork(pull: Double, extent: Double) -> Transform {
        guard extent > 0, pull > 0, pull.isFinite else { return .identity }
        let scale = min(artworkMaximumScale, 1 + pull / extent * 0.5)
        return Transform(scale: scale, offsetY: 0)
    }

    /// 导航栏里的标题要不要显示。
    ///
    /// - Parameters:
    ///   - scrolled: 内容往上滚了多远（静止为 0）。
    ///   - threshold: 头图里那行大标题的下沿滚到导航栏下沿时对应的滚动距离。
    ///   - wasShowing: 上一次的结果。落在滞回带里时保持不变。
    public static func showsInlineTitle(scrolled: Double, threshold: Double, wasShowing: Bool) -> Bool {
        let half = inlineTitleHysteresis / 2
        if scrolled >= threshold + half { return true }
        if scrolled <= threshold - half { return false }
        return wasShowing
    }
}
