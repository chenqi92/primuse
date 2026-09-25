import Foundation

/// 整屏居中的沉浸界面怎么让开遮挡区。
///
/// iPhone Duo 外屏把状态栏竖排到前置摄像头下面,两者合成一块「遮挡区」(系统叫 occlusion
/// reserved region;竖握在右上角约 84×170,横握在左上角,状态栏收起时缩成 84×82;灵动岛
/// 展开实时活动时会往下变长)。苹果的要求是:能滚动的内容按安全区让开整条竖栏;播放页这类
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

    /// 解析调试用的假遮挡区:`trailing,84,170` 或 `leading,84,82`,多块用分号隔开。
    /// 用来在没有灵动岛实时活动的模拟器、以及 iPad 取证页上看遮挡区变大时的排法。
    public static func debugRegions(from specification: String?, width: Double) -> [Region] {
        guard let specification, width.isFinite, width > 0 else { return [] }
        return specification.split(separator: ";").compactMap { part in
            let fields = part.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 3,
                  let regionWidth = Double(fields[1]), let regionHeight = Double(fields[2]),
                  regionWidth > 0, regionHeight > 0 else { return nil }
            switch fields[0] {
            case "leading":
                return Region(x: 0, y: 0, width: regionWidth, height: regionHeight)
            case "trailing":
                return Region(x: width - regionWidth, y: 0, width: regionWidth, height: regionHeight)
            default:
                return nil
            }
        }
    }
}
