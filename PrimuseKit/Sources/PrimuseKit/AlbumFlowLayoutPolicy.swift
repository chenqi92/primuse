import Foundation

/// 全屏「封面流」(#191)的几何与两侧专辑的取法。
///
/// 正在播的这张专辑居中、正对着人；资料库里排在它前后的专辑斜着排在两边，像一排立着的唱片，
/// 下面是倒影。舞台画面与全屏页的点按判定（点中间这张 = 播放 / 暂停）用同一份几何，
/// 免得画的和点的对不上。
public enum AlbumFlowLayoutPolicy {
    public struct Layout: Equatable, Sendable {
        /// 中间封面的边长与左上角（画布坐标）。
        public var centerSide: Double
        public var centerOriginX: Double
        public var centerOriginY: Double
        /// 两侧封面的边长。
        public var neighborSide: Double
        /// 第一张邻居的中心离中间封面中心多远。
        public var firstNeighborOffset: Double
        /// 往外每多一张，中心再挪多远。斜着的封面彼此叠着，所以比边长小得多。
        public var neighborSpacing: Double
        /// 两侧每边画几张：画布放得下的上限，实际还要看有几张可画。
        public var neighborsPerSide: Int
        /// 两侧封面绕竖轴转的角度（度），朝向中间。
        public var tiltDegrees: Double
        /// 倒影露出的高度占封面边长的比例。
        public var reflectionFraction: Double
        /// 歌名一块的上沿与高度：在封面上面。
        public var titleOriginY: Double
        public var titleHeight: Double

        public var centerMidX: Double { centerOriginX + centerSide / 2 }
        public var centerMidY: Double { centerOriginY + centerSide / 2 }

        /// 第 `offset` 张邻居（负数在左、正数在右，±1 紧挨着中间）的中心横坐标。
        public func neighborMidX(offset: Int) -> Double {
            guard offset != 0 else { return centerMidX }
            let distance = firstNeighborOffset + Double(abs(offset) - 1) * neighborSpacing
            return centerMidX + (offset < 0 ? -distance : distance)
        }

        /// 点在不在中间这张封面上。`tolerance` 往外放宽一圈，手指点偏一点也算。
        public func centerContains(x: Double, y: Double, tolerance: Double = 0) -> Bool {
            x >= centerOriginX - tolerance
                && x <= centerOriginX + centerSide + tolerance
                && y >= centerOriginY - tolerance
                && y <= centerOriginY + centerSide + tolerance
        }
    }

    /// 两侧每边最多画几张。再多也只是挤在屏幕边上的细条。
    public static let maximumNeighborsPerSide = 6
    public static let tiltDegrees = 58.0
    public static let reflectionFraction = 0.34
    /// 倒影越往下越淡，只要求上面这一截露在控件之上，其余淡进控件底下。
    public static let visibleReflectionShare = 0.4
    public static let neighborScale = 0.8
    /// 中间封面最小边长：画布实在太矮时以它为准，不再缩。
    public static let minimumCenterSide = 96.0

    /// - Parameters:
    ///   - topInset / bottomInset: 舞台上沿要让开的圆钮排、下沿要让开的控件。
    ///   - horizontalInset: 左右安全区。邻居可以伸进去一点，中间封面与歌名不进。
    ///   - titleHeight: 歌名一块要的高度，由视图层按字号给。
    public static func layout(
        canvasWidth: Double,
        canvasHeight: Double,
        topInset: Double,
        bottomInset: Double,
        horizontalInset: Double,
        titleHeight: Double,
        titleSpacing: Double
    ) -> Layout {
        let width = max(canvasWidth, 1)
        let height = max(canvasHeight, 1)
        let isLandscape = width > height
        let contentTop = max(topInset, 0) + max(titleHeight, 0) + max(titleSpacing, 0)
        let contentBottom = height - max(bottomInset, 0)
        // 封面加倒影上面那一截要放进歌名与控件之间。
        let availableHeight = max(contentBottom - contentTop, 0)
        let visibleReflection = reflectionFraction * visibleReflectionShare
        let widthCap = (width - 2 * max(horizontalInset, 0)) * (isLandscape ? 0.36 : 0.66)
        let side = max(
            min(availableHeight / (1 + visibleReflection), widthCap),
            minimumCenterSide
        )
        let originX = (width - side) / 2
        // 封面与倒影这一组在可用高度里居中；放不下时贴着歌名。
        let groupHeight = side * (1 + visibleReflection)
        let originY = contentTop + max((availableHeight - groupHeight) / 2, 0)

        let neighborSide = side * neighborScale
        let firstOffset = side / 2 + neighborSide * 0.42
        let spacing = neighborSide * 0.34
        let halfWidth = width / 2
        // 最外一张的中心可以落到画布边外半张斜封面的宽度，边上不留空。
        let reach = halfWidth + neighborSide * 0.25 - firstOffset
        let perSide = reach < 0 ? 0 : min(Int(reach / spacing) + 1, maximumNeighborsPerSide)

        return Layout(
            centerSide: side,
            centerOriginX: originX,
            centerOriginY: originY,
            neighborSide: neighborSide,
            firstNeighborOffset: firstOffset,
            neighborSpacing: spacing,
            neighborsPerSide: perSide,
            tiltDegrees: tiltDegrees,
            reflectionFraction: reflectionFraction,
            titleOriginY: max(originY - max(titleSpacing, 0) - max(titleHeight, 0), max(topInset, 0)),
            titleHeight: max(titleHeight, 0)
        )
    }

    /// 两侧取哪几张。`count` 张专辑里正在播的是第 `currentIndex` 张，前后各取最多 `perSide` 张，
    /// 按离当前由近到远排。和 iPod 的封面流一样不首尾相接：排在最前的专辑左边就是空的。
    public static func neighborIndices(
        count: Int,
        currentIndex: Int?,
        perSide: Int
    ) -> (before: [Int], after: [Int]) {
        guard let currentIndex, count > 1, perSide > 0,
              currentIndex >= 0, currentIndex < count else { return ([], []) }
        let beforeCount = min(perSide, currentIndex)
        let afterCount = min(perSide, count - 1 - currentIndex)
        let before = beforeCount > 0 ? (1...beforeCount).map { currentIndex - $0 } : []
        let after = afterCount > 0 ? (1...afterCount).map { currentIndex + $0 } : []
        return (before, after)
    }
}
