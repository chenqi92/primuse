import Foundation

/// iPhone Duo 竖栏中间那条资料库分类(App 里的 `LibrarySectionRail`)怎么排:一格多高、一次露几格、要不要上下滑。
///
/// 竖栏中间的空当随页面变:资料库首页上面只有竖排状态栏,放得下全部分类;分类页多了返回和「⋯」,
/// 外屏竖握只剩一百二十来点。放得下时格子按系统标签栏的格距排,放不下先压到最小格距,
/// 再放不下就只露整数格、上下滑 —— 露出来的格子总是完整的,滑动也按格停。
public enum LibrarySectionRailLayoutPolicy {
    public struct Layout: Equatable, Sendable {
        /// 每格的高度。
        public var pitch: Double
        /// 胶囊里一次露出几格。
        public var visibleCount: Int
        /// 分类总数。
        public var itemCount: Int

        /// 分类比露出来的格子多,要上下滑。
        public var scrolls: Bool { visibleCount < itemCount }
        /// 胶囊总高:露出的格子加上下内边距。
        public var height: Double { Double(visibleCount) * pitch + 2 * LibrarySectionRailLayoutPolicy.inset }
        /// 最远能滑到哪(第一格露在最上面时为 0)。
        public var maximumOffset: Double { Double(max(0, itemCount - visibleCount)) * pitch }
    }

    /// 胶囊上下的内边距,选中底色不贴着胶囊的圆头。
    public static let inset = 4.0
    /// 格子再矮,图标和选中底色就挤在一起了。
    public static let minimumPitch = 30.0
    /// 放得下时的格距,和系统竖栏里标签栏那几格差不多。
    public static let preferredPitch = 38.0
    /// 至少露几格才值得摆在竖栏里;更少时资料库照旧在顶上摆一排页签。
    public static let minimumVisibleCount = 3

    /// `available` 是竖栏空当扣掉上下与系统胶囊之间的间距后剩下的高度。放不下时为 nil。
    public static func layout(available: Double, itemCount: Int) -> Layout? {
        guard itemCount > 0, available.isFinite else { return nil }
        let usable = available - 2 * inset
        let evenPitch = (usable / Double(itemCount)).rounded(.down)
        if evenPitch >= minimumPitch {
            return Layout(pitch: min(preferredPitch, evenPitch), visibleCount: itemCount, itemCount: itemCount)
        }
        let visible = Int((usable / minimumPitch).rounded(.down))
        guard visible >= min(itemCount, minimumVisibleCount) else { return nil }
        let pitch = min(preferredPitch, (usable / Double(visible)).rounded(.down))
        return Layout(pitch: pitch, visibleCount: visible, itemCount: itemCount)
    }

    /// 要滑时把选中的那格停在露出那几格的中间(偶数格时偏上),靠头靠尾时贴边。
    /// 返回露在最上面的是第几格。
    public static func firstVisibleIndex(selectedIndex: Int?, layout: Layout) -> Int {
        guard layout.scrolls, let selectedIndex else { return 0 }
        let centered = selectedIndex - (layout.visibleCount - 1) / 2
        return min(max(0, centered), layout.itemCount - layout.visibleCount)
    }

    /// 让选中的那格露在中间时的滑动位置。
    public static func offset(selectedIndex: Int?, layout: Layout) -> Double {
        Double(firstVisibleIndex(selectedIndex: selectedIndex, layout: layout)) * layout.pitch
    }

    /// 手指松开后按格停:停在离落点最近的整格上,不越过两头。
    public static func snappedOffset(_ proposed: Double, layout: Layout) -> Double {
        guard layout.pitch > 0, proposed.isFinite else { return 0 }
        let snapped = (proposed / layout.pitch).rounded() * layout.pitch
        return min(layout.maximumOffset, max(0, snapped))
    }
}
