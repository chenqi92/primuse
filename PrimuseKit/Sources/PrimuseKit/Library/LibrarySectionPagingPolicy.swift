import Foundation

/// 资料库分类页（极简导航「音乐」那一格下面的收藏、歌曲、流派……）左右滑动切换。
///
/// 起手与松手的门槛沿用首页横滑（`HomeFaceSwipePolicy`）；这里只管分类页自己的规则：
/// 两端不循环、到头了跟手打折，起手离左右边缘太近不接（左边留给系统返回，右边是歌曲页的字母索引）。
public enum LibrarySectionPagingPolicy {
    /// 设置里的开关，默认开。
    public static let storageKey = "primuse.library.sectionSwipe.v1"

    /// 到头了还往外划时，内容跟手走的比例。
    public static let edgeResistance = 0.16
    /// 起手在前沿（LTR 的左边）这么宽之内不接：系统的返回手势，歌曲行的横滑也让开了这一条。
    public static let leadingEdgeExclusion = 28.0
    /// 起手在后沿这么宽之内不接：歌曲页字母索引的触摸区宽 48。
    public static let trailingEdgeExclusion = 52.0

    /// 相邻的分类。`forward` 是往后翻（LTR 里手指往左划）。两端不循环。
    public static func neighbor<Section: Equatable>(
        in sections: [Section],
        of selection: Section,
        forward: Bool
    ) -> Section? {
        guard let index = sections.firstIndex(of: selection) else { return nil }
        let next = index + (forward ? 1 : -1)
        return sections.indices.contains(next) ? sections[next] : nil
    }

    /// 手指往哪边划算往后翻：LTR 往左划，RTL 往右划。
    public static func isForward(translationX: Double, isRightToLeft: Bool) -> Bool {
        isRightToLeft ? translationX > 0 : translationX < 0
    }

    /// 跟手位移：那一侧有分类时等于手指位移，到头了打折。
    public static func interactiveOffset(translationX: Double, canMove: Bool) -> Double {
        guard translationX.isFinite else { return 0 }
        return canMove ? translationX : translationX * edgeResistance
    }

    /// 起手点在不接的边缘条里。`startX` 是在容器里的横坐标。
    public static func startsInEdgeExclusion(
        startX: Double,
        containerWidth: Double,
        isRightToLeft: Bool
    ) -> Bool {
        guard containerWidth > 0, startX.isFinite else { return true }
        let fromLeft = startX
        let fromRight = containerWidth - startX
        let leading = isRightToLeft ? fromRight : fromLeft
        let trailing = isRightToLeft ? fromLeft : fromRight
        return leading < leadingEdgeExclusion || trailing < trailingEdgeExclusion
    }

    /// 新的一页从哪一侧进来：+1 从右侧（往后翻、LTR），-1 从左侧。和手指方向一致，与语言方向无关。
    public static func entrySide(translationX: Double) -> Double {
        translationX < 0 ? 1 : -1
    }
}
