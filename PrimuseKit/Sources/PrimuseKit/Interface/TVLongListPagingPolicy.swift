import Foundation

/// Apple TV 长列表的分页。
///
/// 遥控器只能一行一行挪焦点,所以一次把整条队列或整个曲库交给 `ForEach`
/// 没有任何收益:焦点引擎要为每一行建立候选并参与每次方向键的几何搜索,
/// 七千多行时上下键和 Menu 键一起失去响应。改成先渲染一页,焦点挪到末尾
/// 附近再续下一页 —— 用户能翻到的行照样翻得到,翻不到的行不必先存在。
public enum TVLongListPagingPolicy {
    /// 一页的行数。电视一屏排得下约十行,一页够连续按住方向键翻一阵子。
    public static let pageSize = 60
    /// 焦点距离已渲染末尾还剩这么多行时就续页,别等焦点真撞到底再补。
    public static let focusTriggerDistance = 15

    /// 把行数钳进 `0...totalCount`,并保证非空列表至少渲染一页。
    public static func clamped(limit: Int, totalCount: Int) -> Int {
        let total = max(totalCount, 0)
        guard total > 0 else { return 0 }
        return min(max(limit, min(pageSize, total)), total)
    }

    /// 焦点落到第 `focusedRow` 行之后应渲染的行数。没到续页距离就保持不变。
    public static func limit(after currentLimit: Int, focusedRow: Int, totalCount: Int) -> Int {
        let total = max(totalCount, 0)
        let current = clamped(limit: currentLimit, totalCount: total)
        guard current < total, focusedRow >= current - focusTriggerDistance else { return current }
        // 一次至少续一页;焦点若被直接送到很靠后的位置,一次补到够用为止。
        return min(total, max(current + pageSize, focusedRow + focusTriggerDistance + 1))
    }

    /// 首次渲染的行数:打开时要滚到第 `revealing` 行 (当前章节之类) 就一次覆盖到它,否则一页。
    public static func initialLimit(revealing: Int?, totalCount: Int) -> Int {
        guard let revealing, revealing >= 0 else { return clamped(limit: pageSize, totalCount: totalCount) }
        return limit(after: pageSize, focusedRow: revealing, totalCount: totalCount)
    }

    /// 网格按整行渲染:把格数补成列数的整数倍,不超过总数。
    public static func wholeRows(_ count: Int, columns: Int, totalCount: Int) -> Int {
        let columns = max(columns, 1)
        let rounded = (max(count, 0) + columns - 1) / columns * columns
        return min(rounded, max(totalCount, 0))
    }
}
