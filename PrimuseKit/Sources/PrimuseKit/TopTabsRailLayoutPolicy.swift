import Foundation

/// 极简外壳的 tab 条在系统竖排工具栏时改成侧边竖栏的几何。
///
/// iOS 27.1 起,iPhone Duo 这类设备会把状态栏、导航栏按钮、标签栏竖排进屏幕一侧的一条竖栏
/// (系统叫 vertical bar):那一侧多出一条安全区,顶部安全区变成 0。自绘的顶部 tab 条
/// 这时改成同一侧的竖栏,住进系统让出的那条安全区,顶部的高度还给页面。
/// 这里只放与 SwiftUI 无关的判断与取值,视图层照着摆。
public enum TopTabsRailLayoutPolicy {
    /// 竖栏那一侧的安全区至少这么宽,才算系统真的让出了一条竖栏(iPhone Duo 外屏实测 84)。
    public static let minimumRailWidth: Double = 44
    /// 竖栏内容离顶端遮挡区(竖排的状态栏、前置摄像头)下沿的距离。
    public static let clearanceSpacing: Double = 8
    /// 顶端没有遮挡(横握时状态栏收起)时也留这么一段,不贴着屏幕圆角。
    public static let minimumTopClearance: Double = 12
    /// 竖栏底部那组按钮离竖栏下沿(底部安全区以内)至少这么远。
    public static let minimumBottomClearance: Double = 4

    /// 是否改成竖栏:系统在这一侧竖排,并且那一侧确实让出了一条够宽的安全区。
    public static func usesRail(hasVerticalBarEdge: Bool, verticalBarInset: Double) -> Bool {
        hasVerticalBarEdge && verticalBarInset.isFinite && verticalBarInset >= minimumRailWidth
    }

    /// 竖栏里的内容从多高开始。
    ///
    /// - Parameters:
    ///   - occlusions: 与竖栏相交、正在生效的遮挡区的上下沿(竖栏自己的坐标)。
    ///   - railHeight: 竖栏高度。只认从上半截开始的遮挡 —— 顶端的状态栏与摄像头;
    ///     下半截若有别的遮挡,不该把整列内容推下去。
    public static func topClearance(occlusions: [(minY: Double, maxY: Double)], railHeight: Double) -> Double {
        let bottoms = occlusions
            .filter { $0.minY.isFinite && $0.maxY.isFinite && $0.maxY > 0 && $0.minY < railHeight / 2 }
            .map(\.maxY)
        guard let bottom = bottoms.max() else { return minimumTopClearance }
        return max(minimumTopClearance, bottom + clearanceSpacing)
    }

    /// 竖栏底部那组按钮(筛选、页面动作、搜索、设置)离竖栏下沿多远。
    ///
    /// iPhone Duo 外屏横握时遮挡区跟着摄像头转:一个方向在竖栏顶上,另一个方向(摄像头在右下角)
    /// 贴着竖栏底部 —— 竖排的状态栏与摄像头正好压在按钮组的位置上,按钮组要贴着它上沿往上排。
    /// 与 `topClearance` 分工:这里只认从下半截开始的遮挡,按伸进竖栏的那一段让开。
    public static func bottomClearance(occlusions: [(minY: Double, maxY: Double)], railHeight: Double) -> Double {
        guard railHeight.isFinite, railHeight > 0 else { return minimumBottomClearance }
        let extents = occlusions
            .filter { $0.minY.isFinite && $0.maxY.isFinite && $0.minY >= railHeight / 2 && $0.minY < railHeight }
            .map { railHeight - $0.minY }
        guard let extent = extents.max() else { return minimumBottomClearance }
        return max(minimumBottomClearance, extent + clearanceSpacing)
    }

    /// 竖栏模式下根页顶部的留白,代替 tab 条那一行的高度。系统竖排后顶部安全区是 0,
    /// 页面内容顶着屏幕上沿会被圆角切到;留一小段,滚上去的内容在这里柔化淡出。
    public static func contentTopInset(isCompactHeight: Bool) -> Double {
        isCompactHeight ? 12 : 16
    }

    /// 竖栏底部那组按钮(筛选、页面动作、搜索、设置)怎么分行:从末尾往前每行尽量放满,
    /// 放不下的留给上一行 —— 搜索与设置总在最后一行并排,多出来的筛选、页面动作排在它们上面。
    /// 比竖栏还宽的按钮(文字按钮)单独一行。返回从上到下每行的下标区间。
    public static func clusterRows(itemWidths: [Double], railWidth: Double) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var end = itemWidths.count
        var start = end
        var used = 0.0
        for index in itemWidths.indices.reversed() {
            let width = max(0, itemWidths[index].isFinite ? itemWidths[index] : 0)
            if start < end, used + width > railWidth {
                rows.append(start..<end)
                end = start
                used = 0
            }
            start = index
            used += width
        }
        if start < end {
            rows.append(start..<end)
        }
        return rows.reversed()
    }
}
