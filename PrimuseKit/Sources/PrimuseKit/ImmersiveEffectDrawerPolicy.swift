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

    /// 缩略卡换上真实画面的先后:停在中间的那张最先,再往两边一张一张排(后面那张先于前面那张),
    /// 一张都不跳过。返回值按卡片下标给出它排第几。
    ///
    /// 真实画面是整套舞台缩下来的,一张要建好几十毫秒;一起建会卡住抽屉的滑入,滑到才建会让卡片
    /// 一张张「闪」出来。所以打开时先放占位,按这个顺序一张接一张换上。
    public static func previewSequence(count: Int, centerIndex: Int) -> [Int] {
        guard count > 0 else { return [] }
        let center = min(max(centerIndex, 0), count - 1)
        var ranks = Array(repeating: 0, count: count)
        var rank = 0
        ranks[center] = rank
        for distance in 1..<count {
            for index in [center + distance, center - distance] where ranks.indices.contains(index) {
                rank += 1
                ranks[index] = rank
            }
            if center + distance >= count - 1, center - distance <= 0 { break }
        }
        return ranks
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
            // 普通全屏会切换宿主，必须点选，不能因转轮经过而打断浏览。
            guard appliesOnSettle, candidateID != "native" else { return false }
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

/// 效果转轮首尾相接用的格子换算。
///
/// 做法是把效果清单原样排三遍，平时停在中间那一遍：往后滚过最后一张接着是下一遍的第一张，
/// 往前反过来。滚停时如果落在前后两遍里，就不加动画换回中间那一遍的同一张 —— 卡片一模一样，
/// 看不出换过，下一次滑动又从中间出发，前后各有一整遍的余量，一次滑动一般滑不到头。
///
/// 格子（slot）是转轮里从头数的第几张，三遍连着数；同一种效果在三遍里各占一格，
/// 视图拿格子当滚动位置的身份，卡片身份就不会重复。
public struct ImmersiveEffectWheelLoop: Sendable, Equatable {
    /// 不重复的效果有几种。
    public let itemCount: Int
    /// 清单排了几遍：两种以上排三遍转圈，只有一种（或没有）就排一遍、不转圈。
    public let copies: Int

    public init(itemCount: Int) {
        let count = max(itemCount, 0)
        self.itemCount = count
        self.copies = count > 1 ? 3 : 1
    }

    /// 是不是首尾相接。
    public var loops: Bool { copies > 1 }

    /// 转轮里一共几格。
    public var slotCount: Int { itemCount * copies }

    /// 平时停的那一遍（三遍时是中间那遍）。
    public var homeCopy: Int { copies / 2 }

    /// 第 `slot` 格是第几种效果；格子越界时为 nil。
    public func itemIndex(forSlot slot: Int) -> Int? {
        guard itemCount > 0, slot >= 0, slot < slotCount else { return nil }
        return slot % itemCount
    }

    /// 这一格在不在平时停的那一遍里。前后两遍只是转圈用的替身，无障碍朗读跳过它们。
    public func isHomeSlot(_ slot: Int) -> Bool {
        guard itemIndex(forSlot: slot) != nil else { return false }
        return slot / itemCount == homeCopy
    }

    /// 平时停的那一遍里第 `item` 种效果在第几格；越界时为 nil。
    public func homeSlot(forItem item: Int) -> Int? {
        guard item >= 0, item < itemCount else { return nil }
        return homeCopy * itemCount + item
    }

    /// 滚停在 `slot` 之后要不要换回平时停的那一遍：落在前后两遍里时返回中间那遍里同一种效果的格子，
    /// 已经在中间（或不转圈、格子越界）时为 nil。
    public func recenteredSlot(for slot: Int) -> Int? {
        guard loops,
              let item = itemIndex(forSlot: slot),
              let home = homeSlot(forItem: item),
              home != slot else { return nil }
        return home
    }

    /// 三遍里每一格排第几个换上真实画面，按格子给出名次。
    ///
    /// 从打开时停着的那一格（中间那遍里的 `centerItem`）往两边一格一格排，后面那格先于前面那格，
    /// 和 `ImmersiveEffectDrawerPolicy.previewSequence` 一样。多出来的一条：排到前后两遍里的某一格时，
    /// 它在中间那遍里的同一张紧跟着排 —— 滚停后换回中间那遍时，换上的那张已经画好，不会从真实画面
    /// 退回占位。
    public func previewSequence(centerItem: Int) -> [Int] {
        guard itemCount > 0 else { return [] }
        let center = homeCopy * itemCount + min(max(centerItem, 0), itemCount - 1)
        var ranks = Array(repeating: -1, count: slotCount)
        var rank = 0

        for distance in 0..<slotCount {
            let candidates = distance == 0 ? [center] : [center + distance, center - distance]
            for slot in candidates {
                guard slot >= 0, slot < slotCount, ranks[slot] < 0 else { continue }
                ranks[slot] = rank
                rank += 1
                if let home = recenteredSlot(for: slot), ranks[home] < 0 {
                    ranks[home] = rank
                    rank += 1
                }
            }
            if rank >= slotCount { break }
        }
        return ranks
    }
}
