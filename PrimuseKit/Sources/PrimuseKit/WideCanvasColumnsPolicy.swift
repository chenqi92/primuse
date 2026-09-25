import Foundation

/// 常规宽度的 iPhone 画布(iPhone Duo 内屏横握)上,详情页与首页从竖向单栏重排成两栏。
///
/// 苹果「音乐」在 Duo 上的做法:外屏是竖向单栏,内屏变宽时同一份内容重排成两栏,不换功能、不换层级。
/// iPad 有自己的侧边栏版式,不跟着变;Duo 内屏竖握(比宽还高)和外屏都保持单栏。
public enum WideCanvasColumnsPolicy {
    /// 画布至少这么宽才分两栏:内屏横握(约 890 与 951)能分,iPhone 与内屏竖握(669)不分。
    public static let minimumWidth: Double = 760
    /// 详情页左栏(头图:封面、标题、操作行)的宽度范围与比例。
    public static let detailLeadingFraction: Double = 0.42
    public static let detailLeadingMinimum: Double = 340
    public static let detailLeadingMaximum: Double = 440

    public static func usesTwoColumns(
        isPhone: Bool,
        isRegularWidth: Bool,
        isCompactHeight: Bool,
        width: Double,
        height: Double
    ) -> Bool {
        guard width.isFinite, height.isFinite else { return false }
        return isPhone && isRegularWidth && !isCompactHeight && width > height && width >= minimumWidth
    }

    /// 详情页左栏宽度;右栏是剩下的。
    public static func detailLeadingColumnWidth(pageWidth: Double) -> Double {
        guard pageWidth.isFinite, pageWidth > 0 else { return 0 }
        return min(max(pageWidth * detailLeadingFraction, detailLeadingMinimum), detailLeadingMaximum)
    }

    /// 首页各区块分到两栏:按可见顺序交替放,左栏先。返回左、右两栏各自的下标。
    public static func homeColumns(sectionCount: Int) -> (leading: [Int], trailing: [Int]) {
        guard sectionCount > 0 else { return ([], []) }
        let indices = Array(0..<sectionCount)
        return (indices.filter { $0 % 2 == 0 }, indices.filter { $0 % 2 == 1 })
    }
}
