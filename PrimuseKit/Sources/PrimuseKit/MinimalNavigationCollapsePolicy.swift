import Foundation

/// 极简模式顶栏里可折叠部分（分类 chip 行）的版面数值。
///
/// 顶栏挂在 safeAreaBar 上,折叠会直接改变滚动视图的 adjustedContentInset,
/// 所以判定折叠的一方必须知道这一行有多高。数值与 MinimalTopNavigationBar 的
/// @ScaledMetric 默认值同源,改版面时两边一起改。
public enum MinimalNavigationChromeMetrics: Sendable {
    /// 分类 chip 行自身的高度。
    public static let categoryRowHeight: CGFloat = 37
    /// 分类行与上方搜索行之间的间距。
    public static let categoryRowTopPadding: CGFloat = 9

    /// 折叠时顶栏一共让出的高度。
    public static var collapsibleHeight: CGFloat {
        categoryRowHeight + categoryRowTopPadding
    }

    /// 分类行在静止状态(刚进页面、滚回顶部)是否默认收起。
    ///
    /// 手机横屏纵向只剩三百多点,这一行连同上方间距就要占掉其中 46pt。收起之后搜索行里
    /// 常驻的分类按钮仍然是展开入口,内容区却能多出整整一行。常规高度维持原样:展开才是
    /// 静止状态,收起只由滚动判定给出。
    public static func collapsesCategoriesAtRest(isCompactHeight: Bool) -> Bool {
        isCompactHeight
    }
}

/// 极简模式顶栏分类行的折叠判定。
///
/// 折叠会把顶栏抬高一行,滚动视图的顶部安全区跟着缩,"已滚动距离"在切换的一瞬间
/// 就凭空少掉一整行。用同一条阈值判断折叠与展开时,这个跳变足以立刻把状态翻回去,
/// 顶栏一收一放又带着内容上下弹,列表看起来就在自己抽搐。
///
/// 判定因此分成两条:折叠要滚过一段明显的距离,展开要回到接近顶部,中间的滞回带宽
/// 不小于顶栏让出的高度加余量,切换造成的跳变落不到另一侧;切换之后再留一小段结算
/// 窗口,顶栏收放动画期间的中间尺寸不参与二次判定。分类行被动态字体撑高时带宽跟着
/// 抬高,不需要另外标定。
public struct MinimalNavigationCollapseResolver: Sendable {
    /// 回到离内容顶部这么近时恢复分类行。
    public static let expandDistance: CGFloat = 12
    /// 滞回带宽的下限。默认字号下顶栏让出约 46pt,这里留到 72pt。
    public static let minimumHysteresis: CGFloat = 72
    /// 在顶栏高度之外再留的余量,吸收分隔线、阴影一类的零头。
    public static let settleMargin: CGFloat = 24
    /// 状态切换后的结算窗口,与顶栏收放动画同量级。
    public static let settleWindow: TimeInterval = 0.4

    /// 当前是否折叠。
    public private(set) var isCollapsed = false

    /// 静止状态是否维持折叠。手机横屏为 true:滚回顶部不再自动展开,展开只由用户点
    /// 分类按钮触发;展开之后向下滚动仍然照原来的滞回带宽收回去,判定本身不变。
    public var collapsesAtRest = false

    /// 自动折叠的起算点。手动展开后从当时的位置重新起算,免得刚展开就被判回去。
    private var collapseBaseline: CGFloat = 0
    private var settleDeadline: TimeInterval?

    public init() {}

    /// 从展开到折叠需要向下滚过的距离。
    public static func collapseDistance(collapsibleChromeHeight: CGFloat) -> CGFloat {
        expandDistance + max(minimumHysteresis, max(0, collapsibleChromeHeight) + settleMargin)
    }

    /// 喂入一次滚动采样,返回顶栏应有的折叠状态。
    ///
    /// - Parameters:
    ///   - scrolledDistance: `contentOffset.y + adjustedContentInset.top`,即已滚过的内容距离。
    ///   - collapsibleChromeHeight: 折叠时顶栏让出的高度,决定滞回带宽。
    ///   - now: 单调时钟读数,用于结算窗口。
    @discardableResult
    public mutating func update(
        scrolledDistance: CGFloat,
        collapsibleChromeHeight: CGFloat,
        now: TimeInterval
    ) -> Bool {
        if let settleDeadline {
            guard now >= settleDeadline else { return isCollapsed }
            self.settleDeadline = nil
        }

        let shouldCollapse: Bool
        if isCollapsed {
            shouldCollapse = collapsesAtRest || scrolledDistance > Self.expandDistance
        } else {
            let travelled = scrolledDistance - collapseBaseline
            shouldCollapse = travelled > Self.collapseDistance(
                collapsibleChromeHeight: collapsibleChromeHeight
            )
        }

        guard shouldCollapse != isCollapsed else { return isCollapsed }
        isCollapsed = shouldCollapse
        if !shouldCollapse { collapseBaseline = 0 }
        settleDeadline = now + Self.settleWindow
        return isCollapsed
    }

    /// 用户点顶栏上的分类按钮展开:从当前位置重新起算,要再向下滚一段才会自动折回去。
    public mutating func markManuallyExpanded(at scrolledDistance: CGFloat, now: TimeInterval) {
        isCollapsed = false
        collapseBaseline = scrolledDistance
        settleDeadline = now + Self.settleWindow
    }

    /// 换页、离开或重新挂载时复位判定,不保留结算窗口。
    public mutating func reset(isCollapsed: Bool = false) {
        self.isCollapsed = isCollapsed
        collapseBaseline = 0
        settleDeadline = nil
    }
}
