import Foundation

/// iPhone Duo 桌面半折时播放页上下两半怎么分栏。内屏竖握半折后每一半都是一块偏宽的横条
/// （约 669 × 460），单栏居中两边空着、下半屏又挤，所以两半各自分成左右两栏：
/// 上半屏立着、离人远，左边封面、右边歌词（有声内容是文字稿）；下半屏平放、手够得着，
/// 左边歌名、进度与控件，右边「接下来播放」（有声内容是目录与书签）。
///
/// 某一半没有第二栏可放（还没有歌词、队列只有一首）或画布太窄放不下两栏时，那一半退回单栏居中。
public enum TabletopColumnsPolicy {
    /// 两栏外侧与屏幕边的距离。
    public static let outerPadding: Double = 24
    /// 上半屏封面与歌词之间的距离。
    public static let columnGap: Double = 24
    /// 上半屏两栏时封面占内容宽度的比例（其余给歌词）。
    public static let artworkWidthFraction: Double = 0.44
    /// 封面小于这个边长就不分栏，宁可整幅只放封面。
    public static let minimumArtworkSide: Double = 140
    /// 歌词那一栏至少要这么宽，一行才排得下几个字。
    public static let minimumTextColumnWidth: Double = 260
    /// 下半屏控件那一栏的宽度范围：有声内容一行七颗键要 320 上下，再加两侧留白。
    public static let minimumControlsWidth: Double = 360
    public static let maximumControlsWidth: Double = 440
    /// 下半屏控件那一栏按整幅宽度的这个比例取，再夹进上面的范围。
    public static let controlsWidthFraction: Double = 0.56
    /// 「接下来播放」那一栏至少要这么宽，封面加歌名才放得下。
    public static let minimumListWidth: Double = 220

    public struct TopHalf: Equatable, Sendable {
        /// 封面边长。
        public let artworkSide: Double
        /// 歌词那一栏的宽度；nil 时不分栏，封面整幅居中。
        public let textColumnWidth: Double?

        public var hasTextColumn: Bool { textColumnWidth != nil }
    }

    /// 上半屏。`width` 是整幅宽，`height` 是扣掉顶部安全区、把手与下沿留白后留给封面的高度。
    /// `wantsTextColumn` 为假（这一首确定没有歌词）时封面整幅居中，和不分栏时一样大。
    public static func topHalf(width: Double, height: Double, wantsTextColumn: Bool) -> TopHalf {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            return TopHalf(artworkSide: 0, textColumnWidth: nil)
        }
        if wantsTextColumn {
            let content = width - outerPadding * 2 - columnGap
            let side = min(height, content * artworkWidthFraction).rounded(.down)
            let text = (content - side).rounded(.down)
            if side >= minimumArtworkSide, text >= minimumTextColumnWidth {
                return TopHalf(artworkSide: side, textColumnWidth: text)
            }
        }
        // 与不分栏时的老版式同一个取法：左右各留 48。
        return TopHalf(artworkSide: max(0, min(width - 96, height)).rounded(.down), textColumnWidth: nil)
    }

    public struct BottomHalf: Equatable, Sendable {
        /// 控件那一栏的宽度；不分栏时就是整幅宽。
        public let controlsWidth: Double
        /// 「接下来播放」那一栏的宽度；nil 时不分栏。
        public let listWidth: Double?

        public var hasListColumn: Bool { listWidth != nil }
    }

    /// 下半屏。`wantsList` 为假（队列只有一首、放着 MV）时控件占满整幅。
    public static func bottomHalf(width: Double, wantsList: Bool) -> BottomHalf {
        guard width.isFinite, width > 0 else {
            return BottomHalf(controlsWidth: 0, listWidth: nil)
        }
        guard wantsList else { return BottomHalf(controlsWidth: width, listWidth: nil) }
        let controls = min(max(width * controlsWidthFraction, minimumControlsWidth), maximumControlsWidth)
            .rounded(.down)
        let list = width - controls
        guard list >= minimumListWidth else { return BottomHalf(controlsWidth: width, listWidth: nil) }
        return BottomHalf(controlsWidth: controls, listWidth: list)
    }
}
