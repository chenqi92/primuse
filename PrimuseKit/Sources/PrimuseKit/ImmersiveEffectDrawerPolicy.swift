import Foundation

/// 效果抽屉贴在视口的哪一边。
///
/// 视口宽于高（手机横屏、iPad 横屏）时贴尾侧，转轮纵向滚；否则贴底部，转轮横向滚。
/// 竖屏手机上右侧抽屉会把舞台遮掉大半，用预览挑效果就失去了意义。
public enum ImmersiveEffectDrawerPlacement: Sendable, Equatable {
    case trailing
    case bottom

    /// 转轮是不是纵向滚动。
    public var scrollsVertically: Bool { self == .trailing }
}

/// 这次切换是怎么触发的。
public enum ImmersiveEffectDrawerTrigger: Sendable, Equatable {
    /// 转轮滚停在某一项。
    case settled
    /// 直接点了某张卡片。
    case tapped
}

/// 抽屉与转轮的全部几何量，单位是点。
///
/// 视图层不再自己算尺寸：Apple 端类型检查对长的 CGFloat 混算表达式很敏感，
/// 而这些数字全部可以在 Linux 上真跑测试。
public struct ImmersiveEffectDrawerLayout: Sendable, Equatable {
    /// 贴哪一边。
    public let placement: ImmersiveEffectDrawerPlacement
    /// 抽屉整体宽度（贴底部时等于视口宽）。
    public let panelWidth: CGFloat
    /// 抽屉整体高度（贴尾侧时等于视口高）。
    public let panelHeight: CGFloat
    /// 抽屉内容相对抽屉四边的内边距。安全区按侧消费，左右不假设相等。
    public let contentLeading: CGFloat
    public let contentTrailing: CGFloat
    public let contentTop: CGFloat
    public let contentBottom: CGFloat
    /// 16:9 缩略图的尺寸。
    public let cardWidth: CGFloat
    public let cardHeight: CGFloat
    /// 转轮沿滚动方向的可视长度。
    public let wheelLength: CGFloat
    /// 两端留白，首尾项也要能停在转轮正中。
    public let wheelMargin: CGFloat
}

/// 全屏效果抽屉的纯几何与判定。
public enum ImmersiveEffectDrawerPolicy {

    /// 居中项稳定多久才算"选定"。滚动中途路过的效果不应用。
    public static let settleDelay: TimeInterval = 0.25

    // MARK: - 贴边与尺寸

    public static func placement(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat
    ) -> ImmersiveEffectDrawerPlacement {
        sanitizedLength(viewportWidth) > sanitizedLength(viewportHeight) ? .trailing : .bottom
    }

    /// 按视口与安全区算出抽屉的全部尺寸。
    ///
    /// - Parameters:
    ///   - safeAreaLeading/Trailing: 已经按书写方向解析过的左右安全区，两侧可能不相等
    ///     （折叠屏外屏、带灵动岛的机型横屏）。
    public static func layout(
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        safeAreaLeading: CGFloat = 0,
        safeAreaTrailing: CGFloat = 0,
        safeAreaTop: CGFloat = 0,
        safeAreaBottom: CGFloat = 0
    ) -> ImmersiveEffectDrawerLayout {
        let width = sanitizedLength(viewportWidth)
        let height = sanitizedLength(viewportHeight)
        let leading = sanitizedInset(safeAreaLeading)
        let trailing = sanitizedInset(safeAreaTrailing)
        let top = sanitizedInset(safeAreaTop)
        let bottom = sanitizedInset(safeAreaBottom)

        if width > height {
            return trailingLayout(
                width: width,
                height: height,
                safeTrailing: trailing,
                safeTop: top,
                safeBottom: bottom
            )
        }
        return bottomLayout(
            width: width,
            height: height,
            safeLeading: leading,
            safeTrailing: trailing,
            safeBottom: bottom
        )
    }

    private static func trailingLayout(
        width: CGFloat,
        height: CGFloat,
        safeTrailing: CGFloat,
        safeTop: CGFloat,
        safeBottom: CGFloat
    ) -> ImmersiveEffectDrawerLayout {
        let reserved = min(maximumPanelWidth, max(minimumPanelWidth, width * panelWidthFraction))
        let panelWidth = (min(reserved + safeTrailing, width * maximumPanelFraction)).rounded()
        let contentLeading = innerPadding
        let contentTrailing = safeTrailing + innerPadding
        let contentTop = max(safeTop, edgePadding)
        let contentBottom = max(safeBottom, edgePadding)

        let wheelLength = max(
            height - contentTop - contentBottom - headerHeight - captionHeight - sectionSpacing * 2,
            minimumWheelLength
        ).rounded()

        // 先按抽屉宽度顶满，再看单元沿滚动方向会不会长到看不见邻项。
        let widthBoundHeight = (panelWidth - contentLeading - contentTrailing) * aspectHeight / aspectWidth
        let cellBoundHeight = wheelLength * cellFraction - cardNameHeight - cardNameSpacing
        let cardHeight = max(min(widthBoundHeight, cellBoundHeight), minimumCardHeight).rounded()
        let cardWidth = (cardHeight * aspectWidth / aspectHeight).rounded()
        let cellExtent = cardHeight + cardNameHeight + cardNameSpacing

        return ImmersiveEffectDrawerLayout(
            placement: .trailing,
            panelWidth: panelWidth,
            panelHeight: height.rounded(),
            contentLeading: contentLeading,
            contentTrailing: contentTrailing,
            contentTop: contentTop,
            contentBottom: contentBottom,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            wheelLength: wheelLength,
            wheelMargin: max((wheelLength - cellExtent) / 2, 0).rounded()
        )
    }

    private static func bottomLayout(
        width: CGFloat,
        height: CGFloat,
        safeLeading: CGFloat,
        safeTrailing: CGFloat,
        safeBottom: CGFloat
    ) -> ImmersiveEffectDrawerLayout {
        let contentHeight = min(maximumBottomHeight, max(minimumBottomHeight, height * bottomHeightFraction))
        let panelHeight = (contentHeight + safeBottom).rounded()
        let contentTop = edgePadding
        let contentBottom = safeBottom + compactBottomPadding

        let wheelCross = max(
            panelHeight - contentTop - contentBottom - compactCaptionHeight - sectionSpacing,
            minimumCardHeight + cardNameHeight + cardNameSpacing
        )
        let wheelLength = max(width - safeLeading - safeTrailing, minimumWheelLength).rounded()

        let crossBoundHeight = wheelCross - cardNameHeight - cardNameSpacing
        let lengthBoundHeight = wheelLength * cellFraction * aspectHeight / aspectWidth
        let cardHeight = max(min(crossBoundHeight, lengthBoundHeight), minimumCardHeight).rounded()
        let cardWidth = (cardHeight * aspectWidth / aspectHeight).rounded()

        return ImmersiveEffectDrawerLayout(
            placement: .bottom,
            panelWidth: width.rounded(),
            panelHeight: panelHeight,
            contentLeading: safeLeading,
            contentTrailing: safeTrailing,
            contentTop: contentTop,
            contentBottom: contentBottom,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            wheelLength: wheelLength,
            wheelMargin: max((wheelLength - cardWidth) / 2, 0).rounded()
        )
    }

    // MARK: - 选中与应用

    /// 打开抽屉时转轮停在哪一项。
    ///
    /// 当前效果不在列表里（从原生播放页进入的入口，当前是 `native`）就停在第一项，
    /// 此时居中项与当前效果不同，但因为不是滚动停下来的，不会触发应用。
    public static func initialCenterID(effectIDs: [String], currentID: String) -> String? {
        guard let first = effectIDs.first else { return nil }
        return effectIDs.contains(currentID) ? currentID : first
    }

    /// 居中项该不该写回当前效果。
    ///
    /// - Parameters:
    ///   - appliesOnSettle: 全屏内为 true（滚停即换背景），从播放页进入全屏的入口为 false
    ///     （转轮只是浏览，点卡片才生效）。
    ///   - secondsSinceCenterChange: 居中项变成 `candidateID` 之后过了多久。滚动途中反复
    ///     变化时调用方重新计时，这里只判断这一次是否已经稳定够久。
    public static func shouldApply(
        currentEffectID: String,
        candidateID: String?,
        trigger: ImmersiveEffectDrawerTrigger,
        appliesOnSettle: Bool,
        secondsSinceCenterChange: TimeInterval
    ) -> Bool {
        guard let candidateID, !candidateID.isEmpty else { return false }
        guard candidateID != currentEffectID else { return false }
        switch trigger {
        case .tapped:
            return true
        case .settled:
            guard appliesOnSettle else { return false }
            return secondsSinceCenterChange >= settleDelay
        }
    }

    // MARK: - 常量

    /// 尾侧抽屉的内容宽度上限与占视口的比例。
    private static let maximumPanelWidth: CGFloat = 300
    private static let minimumPanelWidth: CGFloat = 200
    private static let panelWidthFraction: CGFloat = 0.36
    /// 连安全区一起算，抽屉最多占视口这么宽 —— 再宽舞台就没剩下什么可看。
    private static let maximumPanelFraction: CGFloat = 0.55

    /// 底部抽屉的高度区间与比例。
    private static let maximumBottomHeight: CGFloat = 220
    private static let minimumBottomHeight: CGFloat = 190
    private static let bottomHeightFraction: CGFloat = 0.26

    private static let innerPadding: CGFloat = 16
    private static let edgePadding: CGFloat = 14
    private static let compactBottomPadding: CGFloat = 10
    private static let sectionSpacing: CGFloat = 12
    /// 尾侧抽屉顶部的标题行与底部的说明区。
    private static let headerHeight: CGFloat = 44
    private static let captionHeight: CGFloat = 62
    /// 底部抽屉把说明与收起按钮并成一行放在转轮上方。
    private static let compactCaptionHeight: CGFloat = 46

    private static let cardNameHeight: CGFloat = 18
    private static let cardNameSpacing: CGFloat = 6
    private static let minimumCardHeight: CGFloat = 54
    private static let minimumWheelLength: CGFloat = 120
    /// 单元沿滚动方向最多占转轮这么长，留出邻项让人看出还能转。
    private static let cellFraction: CGFloat = 0.66

    private static let aspectWidth: CGFloat = 16
    private static let aspectHeight: CGFloat = 9

    private static func sanitizedLength(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 1 else { return 1 }
        return value
    }

    private static func sanitizedInset(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }
}
