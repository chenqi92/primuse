import Foundation

/// 整屏居中的沉浸界面怎么让开遮挡区。
///
/// iPhone Duo 外屏把状态栏竖排到前置摄像头下面,两者合成一块「遮挡区」(系统叫 occlusion
/// reserved region;竖握在右上角约 84×170,横握时跟着摄像头转:一个方向在左上角,另一个方向在
/// 右下角,状态栏收起时缩成 84×82;灵动岛展开实时活动时会变长)。遮挡区不一定在屏幕顶上,
/// 一律按系统报告的矩形算,别假设它在上面或左边。苹果的要求是:能滚动的内容按安全区让开整条竖栏;播放页这类
/// 沉浸式、不滚动的界面按整屏居中,只让开遮挡区本身。这里只放与 SwiftUI 无关的几何判断,
/// 坐标一律用读取遮挡区的那个视图自己的坐标,x 从前沿算起。
public enum OcclusionAvoidancePolicy {
    public struct Region: Equatable, Sendable {
        public var minX: Double
        public var minY: Double
        public var maxX: Double
        public var maxY: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            minX = x
            minY = y
            maxX = x + max(0, width)
            maxY = y + max(0, height)
        }

        public var width: Double { maxX - minX }
        public var height: Double { maxY - minY }
        var isUsable: Bool {
            minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite && maxX > minX && maxY > minY
        }
    }

    /// 某一段高度上,前沿与尾沿各要让出多少(从各自的屏幕边缘量起)。
    public struct SideClearance: Equatable, Sendable {
        public var leading: Double
        public var trailing: Double

        public init(leading: Double, trailing: Double) {
            self.leading = leading
            self.trailing = trailing
        }

        public static let zero = SideClearance(leading: 0, trailing: 0)
        public var larger: Double { max(leading, trailing) }
        public var isZero: Bool { leading <= 0 && trailing <= 0 }
    }

    /// 与 `bandMinY..<bandMaxY` 这段高度相交的遮挡区,在两侧各要让多少。
    /// 遮挡区按中心落在哪半边归到前沿或尾沿。
    public static func sideClearance(
        regions: [Region],
        bandMinY: Double,
        bandMaxY: Double,
        width: Double
    ) -> SideClearance {
        guard width.isFinite, width > 0, bandMaxY > bandMinY else { return .zero }
        var clearance = SideClearance.zero
        for region in regions where region.isUsable && region.maxY > bandMinY && region.minY < bandMaxY {
            let midX = (region.minX + region.maxX) / 2
            if midX < width / 2 {
                clearance.leading = max(clearance.leading, min(width, region.maxX))
            } else {
                clearance.trailing = max(clearance.trailing, min(width, width - region.minX))
            }
        }
        return clearance
    }

    /// 整屏居中的方块(封面)在这段高度上最多多宽,才能两边都不碰遮挡区。
    /// 这段高度上没有遮挡时就是整个宽度。`gap` 是方块与遮挡区之间至少留的距离。
    public static func centeredWidthLimit(
        regions: [Region],
        bandMinY: Double,
        bandMaxY: Double,
        width: Double,
        gap: Double
    ) -> Double {
        let clearance = sideClearance(regions: regions, bandMinY: bandMinY, bandMaxY: bandMaxY, width: width)
        guard !clearance.isZero else { return max(0, width) }
        return max(0, width - 2 * (clearance.larger + max(0, gap)))
    }

    /// 所有遮挡区的最低点;没有遮挡区时为 0。
    public static func lowestEdge(of regions: [Region]) -> Double {
        regions.filter(\.isUsable).map(\.maxY).max() ?? 0
    }

    /// 贴着屏幕上沿那几块遮挡区(中心在上半屏)的最低点;没有时为 0。内容上沿要推到它下面。
    /// 遮挡区在下半屏(外屏横握摄像头在右下角的那个方向)时不算,免得把内容推出屏幕。
    public static func topEdge(of regions: [Region], height: Double) -> Double {
        guard height.isFinite, height > 0 else { return lowestEdge(of: regions) }
        return regions.filter { $0.isUsable && ($0.minY + $0.maxY) / 2 < height / 2 }
            .map(\.maxY).max() ?? 0
    }

    /// 贴着屏幕下沿那几块遮挡区(中心在下半屏)占去的高度(从屏幕下沿量起);没有时为 0。
    public static func bottomExtent(of regions: [Region], height: Double) -> Double {
        guard height.isFinite, height > 0 else { return 0 }
        return regions.filter { $0.isUsable && ($0.minY + $0.maxY) / 2 >= height / 2 }
            .map { max(0, height - $0.minY) }.max() ?? 0
    }

    // MARK: - 竖栏里的那一列按钮

    /// 竖栏那一列按钮能占的一段高度。
    public struct ColumnSegment: Equatable, Sendable {
        public var minY: Double
        public var maxY: Double
        /// 这一段的下端贴着遮挡区(遮挡区在竖栏底部):按钮从下往上贴着它排;否则从上往下排。
        public var alignsToBottom: Bool

        public init(minY: Double, maxY: Double, alignsToBottom: Bool) {
            self.minY = minY
            self.maxY = maxY
            self.alignsToBottom = alignsToBottom
        }

        public var length: Double { max(0, maxY - minY) }
    }

    /// 在 `bandMinX...bandMaxX` 这一条(竖栏)里,去掉与它相交的遮挡区(上下各留 `margin`)与上下安全区之后
    /// 最长的一段连续空白。遮挡区在这一条的顶上时从它下面开始、往下排;在底下时到它上面为止、贴着它排。
    /// 没有遮挡区时从上安全区下面开始。
    public static func columnSegment(
        regions: [Region],
        bandMinX: Double,
        bandMaxX: Double,
        height: Double,
        topInset: Double,
        bottomInset: Double,
        margin: Double
    ) -> ColumnSegment {
        let start = max(0, topInset) + margin
        let end = height - max(0, bottomInset) - margin
        guard height.isFinite, height > 0, end > start else {
            return ColumnSegment(minY: 0, maxY: max(0, height), alignsToBottom: false)
        }
        let blocked = regions
            .filter { $0.isUsable && $0.maxX > bandMinX && $0.minX < bandMaxX }
            .map { (lower: $0.minY - margin, upper: $0.maxY + margin) }
            .sorted { $0.lower < $1.lower }
        // 空白段:(起点, 终点, 起点贴着遮挡区, 终点贴着遮挡区)。
        var gaps: [(lower: Double, upper: Double, afterOcclusion: Bool, beforeOcclusion: Bool)] = []
        var cursor = start
        var cursorAfterOcclusion = false
        for block in blocked {
            if block.upper <= cursor { continue }
            if block.lower > cursor {
                gaps.append((cursor, min(block.lower, end), cursorAfterOcclusion, block.lower < end))
            }
            cursor = max(cursor, block.upper)
            cursorAfterOcclusion = true
            if cursor >= end { break }
        }
        if cursor < end {
            gaps.append((cursor, end, cursorAfterOcclusion, false))
        }
        guard let best = gaps.filter({ $0.upper > $0.lower }).max(by: { $0.upper - $0.lower < $1.upper - $1.lower }) else {
            return ColumnSegment(minY: start, maxY: start, alignsToBottom: false)
        }
        return ColumnSegment(
            minY: best.lower,
            maxY: best.upper,
            alignsToBottom: best.beforeOcclusion && !best.afterOcclusion
        )
    }

    /// 一列按钮放进 `length` 这么高时每颗多大、要把几颗收进「更多」。
    /// `groups` 是每个玻璃胶囊里的按钮数(从上往下);`droppable` 颗可以收走的都在最后一组里。
    /// 先在 `maximumItem...minimumItem` 之间一起缩,最小还放不下再从最后一组里一颗一颗收走。
    public struct ColumnFit: Equatable, Sendable {
        public var itemSize: Double
        public var overflowCount: Int

        public init(itemSize: Double, overflowCount: Int) {
            self.itemSize = itemSize
            self.overflowCount = overflowCount
        }
    }

    public static func columnFit(
        length: Double,
        groups: [Int],
        droppable: Int,
        spacing: Double,
        capsulePadding: Double,
        minimumItem: Double = 34,
        maximumItem: Double = 44
    ) -> ColumnFit {
        let groups = groups.filter { $0 > 0 }
        guard !groups.isEmpty else { return ColumnFit(itemSize: maximumItem, overflowCount: 0) }
        let fixed = spacing * Double(groups.count - 1) + capsulePadding * 2 * Double(groups.count)
        let total = groups.reduce(0, +)
        let maxDrop = max(0, min(droppable, (groups.last ?? 0) - 1))
        for dropped in 0...maxDrop {
            let items = Double(total - dropped)
            let size = ((length - fixed) / max(items, 1)).rounded(.down)
            if size >= minimumItem || dropped == maxDrop {
                return ColumnFit(itemSize: min(maximumItem, max(minimumItem, size)), overflowCount: dropped)
            }
        }
        return ColumnFit(itemSize: minimumItem, overflowCount: maxDrop)
    }

    /// 解析调试用的假遮挡区:`trailing,84,170` 或 `leading,84,82`,多块用分号隔开;第四项写 `bottom`
    /// 时贴着下沿(外屏横握摄像头在右下角的那个方向)。
    /// 用来在没有灵动岛实时活动的模拟器、以及 iPad 取证页上看遮挡区变大时的排法。
    public static func debugRegions(from specification: String?, width: Double, height: Double = 0) -> [Region] {
        guard let specification, width.isFinite, width > 0 else { return [] }
        return specification.split(separator: ";").compactMap { part in
            let fields = part.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 3 || fields.count == 4,
                  let regionWidth = Double(fields[1]), let regionHeight = Double(fields[2]),
                  regionWidth > 0, regionHeight > 0 else { return nil }
            let atBottom = fields.count == 4 && fields[3] == "bottom" && height.isFinite && height > regionHeight
            let y = atBottom ? height - regionHeight : 0
            switch fields[0] {
            case "leading":
                return Region(x: 0, y: y, width: regionWidth, height: regionHeight)
            case "trailing":
                return Region(x: width - regionWidth, y: y, width: regionWidth, height: regionHeight)
            default:
                return nil
            }
        }
    }
}
