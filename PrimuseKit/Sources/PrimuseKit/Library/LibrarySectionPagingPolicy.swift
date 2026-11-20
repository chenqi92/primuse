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
    ///
    /// 后沿那一条只有带字母索引的页（歌曲页）才让：别的页往后翻时手指常从右边缘附近起手，
    /// 流派、收藏的卡片一直排到边上，让出这一条就成了「只有中间能划」。
    public static func startsInEdgeExclusion(
        startX: Double,
        containerWidth: Double,
        isRightToLeft: Bool,
        excludesTrailingEdge: Bool = true
    ) -> Bool {
        guard containerWidth > 0, startX.isFinite else { return true }
        let fromLeft = startX
        let fromRight = containerWidth - startX
        let leading = isRightToLeft ? fromRight : fromLeft
        let trailing = isRightToLeft ? fromLeft : fromRight
        return leading < leadingEdgeExclusion
            || (excludesTrailingEdge && trailing < trailingEdgeExclusion)
    }

    /// 相邻的那一页挂在当前页哪一侧（容器自己的坐标，+1 右、-1 左）：内容往哪边走，就从另一侧露出来。
    /// 没动时为 nil。用的是容器坐标里的位移，不管语言方向，画面上总是紧贴在当前页露出空白的那一边。
    public static func neighborSlot(contentOffset: Double) -> Double? {
        guard contentOffset.isFinite, contentOffset != 0 else { return nil }
        return contentOffset < 0 ? 1 : -1
    }

    /// 松手翻页时，相邻那一页滑到位要多久（秒）：剩下的路越短越快。`remainingFraction` 是剩下的路占页宽的比例。
    public static func settleDuration(remainingFraction: Double) -> Double {
        let fraction = remainingFraction.isFinite ? min(abs(remainingFraction), 1) : 1
        return settleMinimumDuration + (settleMaximumDuration - settleMinimumDuration) * fraction
    }

    public static let settleMinimumDuration = 0.2
    public static let settleMaximumDuration = 0.34

    /// 落位那一段的三次贝塞尔曲线两个控制点 `(x1, y1, x2, y2)`：起步的快慢接住松手时的手速，然后减速停稳。
    ///
    /// 起步斜率 `y1 / x1` 就是起步速度相对整段平均速度的倍数，取 `手速 × 时长 ÷ 剩下的路`；
    /// 手速很小（拖过一半慢慢松手）、往回甩时也至少按缓出曲线的起步走，不会先停一下再动；
    /// 甩得再快也封顶，`y1` 不超过 1，曲线不冲过头。
    public static func settleCurve(
        velocity: Double,
        remaining: Double,
        duration: Double
    ) -> (x1: Double, y1: Double, x2: Double, y2: Double) {
        let x1 = 0.25
        var ratio = settleMinimumLaunch
        if velocity.isFinite, remaining.isFinite, duration.isFinite, abs(remaining) >= 1, duration > 0 {
            ratio = min(max(velocity * duration / remaining, settleMinimumLaunch), settleMaximumLaunch)
        }
        return (x1, x1 * ratio, 0.45, 1)
    }

    /// 起步速度至少是平均速度的这么多倍（同系统缓出曲线的起步）。
    public static let settleMinimumLaunch = 1.7
    /// 起步速度最多这么多倍：`0.25 × 4 = 1`，控制点不高出终点。
    public static let settleMaximumLaunch = 4.0

    /// 翻页刚落定、导航栈还没换过来时摆哪一页：外面给的还是翻页前那一页，就先摆翻到的这一页；
    /// 外面已经换成了别的（导航栈跟上了，或者这期间点了顶上的分类、深链），听外面的。
    public static func shownPage<Page: Equatable>(current: Page, committedFrom: Page?, committedTo: Page?) -> Page {
        guard let committedFrom, let committedTo, committedFrom == current else { return current }
        return committedTo
    }
}

/// 极简导航点顶栏换页（点去处、音乐的分类、「有声」里的切换，不是横滑）时的过渡参数。
///
/// 旧页由外壳截一张屏淡出，新页第一帧就是完整的样子，只轻推一小段给个方向：
/// 新去处在这一排里排在后面，就从后沿那一侧进来。
public enum MinimalPageSwitchPolicy {
    /// 新页轻推进来的距离（点）。横滑翻页是整页宽，点选只要看得出方向；再远，页边露出底色的那一条
    /// 在旧页淡完之后还看得见。
    public static let entryDistance = 16.0
    /// 换页之后这么久（秒）之内出现的新页、新顶栏才接这一次的过渡；再晚出现的（返回、恢复）直接到位。
    /// 要盖得住新页头一次建出来的时间（大曲库的歌曲页在调试构建里要两三百毫秒）。
    public static let freshness = 0.6

    /// 新页从哪一侧进来：+1 右侧，-1 左侧（屏幕方向，同 `LibrarySectionPagingPolicy.entrySide`）。
    /// 排在后面的去处 LTR 从右边进、RTL 从左边进；不在这一排里或者没换格时不推。
    public static func entrySide(fromIndex: Int?, toIndex: Int?, isRightToLeft: Bool) -> Double? {
        guard let fromIndex, let toIndex, fromIndex != toIndex else { return nil }
        let isLater = toIndex > fromIndex
        let side: Double = isLater != isRightToLeft ? 1 : -1
        return side
    }

    /// 换页记录还新鲜。时钟倒退、算不出数时都当不新鲜。
    public static func isFresh(elapsed: Double) -> Bool {
        elapsed.isFinite && elapsed >= 0 && elapsed < freshness
    }
}
