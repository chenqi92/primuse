import Foundation

/// 「时间线」「封面」两种歌曲列表外观的版式。
///
/// 中轴竖在内容区正中，歌曲按序号左右交替排在两侧，第 1 首在前侧。一首歌占一个固定高度的槽位，
/// 高度只由宽度与字号决定，懒加载栈、字母索引与定位都按槽位走。封面外观的大封面比槽位高，
/// 伸进上下邻居同一侧空着的半边：只改绘制与命中范围，不改槽位。
///
/// 坐标都是这一行自己的物理坐标（左上为原点），从右往左书写时整体左右镜像。
/// 辅助功能字号或很窄的容器排成单列：中轴靠前侧，卡片都在中轴后侧。
public struct SongTimelineGeometry: Equatable, Sendable {
    public enum Style: Equatable, Sendable {
        /// 中轴两侧交替的玻璃卡片：外侧方形小封面，内侧歌名与艺人。
        case timeline
        /// 左右交替、带透视的大封面，内侧边缘压一块玻璃胶囊写歌名与艺人。
        case artwork
    }

    /// 容器还没量出宽度时先按这个排（常见手机竖屏）。
    public static let fallbackWidth: CGFloat = 390
    /// 内容区窄于这个宽度就排单列。
    public static let minimumTwoColumnWidth: CGFloat = 300
    /// 单列时中轴离前侧的距离。
    public static let singleColumnAxisInset: CGFloat = 18
    /// 卡片（胶囊）内侧边到中轴的距离，节点与短连线在这一段里。
    public static let axisGap: CGFloat = 10
    /// 节点两侧各算多宽的命中范围，让中轴上的节点（多选时是勾选圈）也点得到。
    public static let nodeHitHalfWidth: CGFloat = 14
    /// 时间线外观：槽位高度占卡片高度的比例。小于 1 时左右两侧的卡片上下略有交错，
    /// 同一侧上下两张卡之间空出大半张卡。
    public static let timelinePitchFraction: CGFloat = 0.92
    /// 封面外观：大封面边长占内容宽度的比例。
    public static let artworkWidthFraction: CGFloat = 0.29
    /// 封面外观：大封面边长的上下限（双列）。
    public static let artworkSideRange: ClosedRange<CGFloat> = 96...200
    /// 封面外观：槽位高度至少是封面边长的这个比例。同一侧上下两张封面隔两个槽位，
    /// 加上透视与转角后仍互不相碰。
    public static let artworkPitchFraction: CGFloat = 0.64
    /// 封面外观：大封面越出内容区外缘的比例（手机上就是伸出屏幕边）。
    public static let artworkBleedFraction: CGFloat = 0.14
    /// 封面外观：胶囊压住封面内侧多宽，按封面边长算。
    public static let capsuleOverlapFraction: CGFloat = 0.36
    /// 封面外观：胶囊最窄多宽。
    public static let minimumCapsuleWidth: CGFloat = 96
    /// 封面外观：封面绕竖轴的基础转角（度），内侧边远离观看者。
    public static let artworkTurn: Double = 18
    /// 封面外观：同一侧相邻两张封面在平面内一正一负的转角（度）。
    public static let artworkRoll: Double = 2.5
    /// 透视强度，视图层传给 `rotation3DEffect` 的 `perspective`。
    public static let perspective: CGFloat = 0.5

    /// 内容区最宽多少；更宽的容器（iPad、横屏）左右留白、内容居中。
    public static func maximumWidth(for style: Style) -> CGFloat {
        switch style {
        case .timeline: 760
        case .artwork: 640
        }
    }

    public let style: Style
    public let containerWidth: CGFloat
    public let isSingleColumn: Bool
    /// 在中轴的前侧（从左往右书写时是左边）。单列时恒为 false。
    public let isLeadingSide: Bool
    /// 卡片与封面物理上在中轴左边：决定封面往哪边转、播放标记放在哪一段。
    public let isOnLeft: Bool
    /// 槽位高度。所有序号相同，只看宽度与字号。
    public let rowHeight: CGFloat
    public let axisX: CGFloat
    /// 时间线外观的卡片；封面外观的玻璃胶囊。
    public let card: CGRect
    public let cardCornerRadius: CGFloat
    /// 时间线外观：卡片外侧的方形小封面。封面外观：未旋转时大封面的框，会伸出槽位与内容区。
    public let artwork: CGRect
    public let artworkCornerRadius: CGFloat
    /// 歌名与艺人所在的框，已经让开内边距与封面。
    public let labels: CGRect
    public let node: CGPoint
    /// 封面绕竖轴的转角（度），正值 = 物理右边远离观看者。时间线外观为 0。
    public let artworkTurn: Double
    /// 封面在平面内的转角（度）。时间线外观为 0。
    public let artworkRoll: Double
    /// 大封面上既没被胶囊盖住、也没伸出容器的那一段的中点，按封面宽度的比例从物理左边量。
    /// 正在播放的标记放在这里，不会被胶囊挡住一半。
    public let artworkGlyphCenterX: CGFloat

    /// - Parameters:
    ///   - containerWidth: 这一行拿到的宽度（外层已经扣掉左右留白与字母索引的让位）。
    ///   - ordinal: 在列表里排第几（从 1 数）。奇数在前侧。
    ///   - cardHeight: 卡片（胶囊）高度，视图按动态字号放大后传进来。
    public init(
        style: Style,
        containerWidth: CGFloat,
        ordinal: Int,
        cardHeight: CGFloat,
        accessibilitySize: Bool,
        rightToLeft: Bool
    ) {
        let container = containerWidth.isFinite && containerWidth > 0 ? containerWidth : Self.fallbackWidth
        let width = min(container, Self.maximumWidth(for: style))
        let origin = (container - width) / 2
        let height = cardHeight.isFinite ? max(cardHeight, 32) : 64
        let single = accessibilitySize || width < Self.minimumTwoColumnWidth
        let leading = !single && !ordinal.isMultiple(of: 2)
        let axis = single ? origin + Self.singleColumnAxisInset : origin + width / 2
        let gap = Self.axisGap

        // 先按从左往右书写排（x 从前缘量），最后统一镜像。
        let cardRect: CGRect
        let artRect: CGRect
        let labelRect: CGRect
        let rowHeight: CGFloat
        let cardRadius: CGFloat
        let artRadius: CGFloat
        var glyphX: CGFloat = 0.5
        var turn = 0.0
        var roll = 0.0

        switch style {
        case .timeline:
            let cardWidth = max(single ? origin + width - (axis + gap) : width / 2 - gap, 0)
            rowHeight = single ? (height + 12).rounded() : (height * Self.timelinePitchFraction).rounded()
            let cardX = leading ? axis - gap - cardWidth : axis + gap
            cardRect = CGRect(x: cardX, y: (rowHeight - height) / 2, width: cardWidth, height: height)
            let pad = min(max(height * 0.1, 5), 8)
            let side = max(min(height - pad * 2, cardWidth * 0.42), 0)
            // 封面在外侧：前侧卡片靠前缘，后侧卡片（含单列）靠后缘。
            let artX = leading ? cardRect.minX + pad : cardRect.maxX - pad - side
            artRect = CGRect(x: artX, y: cardRect.midY - side / 2, width: side, height: side)
            let textStart = leading ? artRect.maxX + 10 : cardRect.minX + 14
            let textEnd = leading ? cardRect.maxX - 12 : artRect.minX - 10
            labelRect = CGRect(x: textStart, y: cardRect.minY + pad,
                               width: max(textEnd - textStart, 0), height: max(height - pad * 2, 0))
            cardRadius = min(height * 0.3, 22)
            artRadius = side * 0.2

        case .artwork:
            let lower = single ? max(Self.artworkSideRange.lowerBound, height + 12) : Self.artworkSideRange.lowerBound
            let upper = single ? max(170, lower) : Self.artworkSideRange.upperBound
            let side = min(max(width * (single ? 0.36 : Self.artworkWidthFraction), lower), upper)
            let bleed = side * Self.artworkBleedFraction
            let overlap = side * Self.capsuleOverlapFraction
            let artX = leading ? origin - bleed : origin + width + bleed - side
            let capsuleX: CGFloat
            let capsuleWidth: CGFloat
            if leading {
                let innerEdge = axis - gap
                capsuleWidth = max(innerEdge - (artX + side - overlap), Self.minimumCapsuleWidth)
                capsuleX = innerEdge - capsuleWidth
            } else {
                let innerEdge = axis + gap
                capsuleWidth = max(artX + overlap - innerEdge, Self.minimumCapsuleWidth)
                capsuleX = innerEdge
            }
            rowHeight = single
                ? max(height + 14, side + 10).rounded()
                : max(height + 10, side * Self.artworkPitchFraction).rounded()
            artRect = CGRect(x: artX, y: (rowHeight - side) / 2, width: side, height: side)
            cardRect = CGRect(x: capsuleX, y: (rowHeight - height) / 2, width: capsuleWidth, height: height)
            labelRect = cardRect.insetBy(dx: 14, dy: min(6, height / 8))
            cardRadius = height * 0.42
            artRadius = side * 0.1
            turn = Self.artworkTurn
            // 同一侧的上下两张一正一负；单列时每一行都在同一侧。
            let sameSideIndex = single ? ordinal - 1 : (ordinal - 1) / 2
            roll = sameSideIndex.isMultiple(of: 2) ? Self.artworkRoll : -Self.artworkRoll
            let visibleStart = leading ? max(artX, 0) : cardRect.maxX
            let visibleEnd = leading ? cardRect.minX : min(artX + side, container)
            glyphX = min(max(((visibleStart + visibleEnd) / 2 - artX) / side, 0.2), 0.8)
        }

        let onLeft = leading != rightToLeft
        func physical(_ rect: CGRect) -> CGRect {
            rightToLeft ? CGRect(x: container - rect.maxX, y: rect.minY, width: rect.width, height: rect.height) : rect
        }

        self.style = style
        self.containerWidth = container
        isSingleColumn = single
        isLeadingSide = leading
        isOnLeft = onLeft
        self.rowHeight = rowHeight
        axisX = rightToLeft ? container - axis : axis
        card = physical(cardRect)
        cardCornerRadius = cardRadius
        artwork = physical(artRect)
        artworkCornerRadius = artRadius
        labels = physical(labelRect)
        node = CGPoint(x: rightToLeft ? container - axis : axis, y: rowHeight / 2)
        // 大封面在中轴左边时内侧是右边，绕竖轴正转右边远离；在右边时反过来。镜像后平面转角也反号。
        artworkTurn = onLeft ? turn : -turn
        artworkRoll = onLeft ? roll : -roll
        artworkGlyphCenterX = rightToLeft ? 1 - glyphX : glyphX
    }

    /// 节点那一段的命中范围：中轴两侧各 `nodeHitHalfWidth`，高度同卡片。
    public var nodeHitRect: CGRect {
        CGRect(x: axisX - Self.nodeHitHalfWidth, y: card.minY,
               width: Self.nodeHitHalfWidth * 2, height: card.height)
    }

    /// 封面的命中范围。大封面转过以后内侧边缩进去，按未旋转的框略收一圈。
    public var artworkHitRect: CGRect {
        switch style {
        case .timeline: artwork
        case .artwork: artwork.insetBy(dx: artwork.width * 0.06, dy: artwork.height * 0.04)
        }
    }

    /// 内容伸出槽位多少（上下各一份）。外层栈在首尾各留这么多，第一行的封面不顶到上面的内容。
    /// 按封面外观最大的透视与转角估。
    public var verticalOverflow: CGFloat {
        switch style {
        case .timeline:
            return max(0, (card.height - rowHeight) / 2)
        case .artwork:
            let extent = artwork.height * Self.maximumProjectedHeightFactor
            return max(0, (max(extent, card.height) - rowHeight) / 2)
        }
    }

    /// 大封面转到最大角度、带上平面转角之后，外接框的高度相对边长的倍数（估计，偏大）。
    /// 透视的消失距离按 SwiftUI 的做法取边长 ÷ `perspective`。
    public static var maximumProjectedHeightFactor: CGFloat {
        let turn = (artworkTurn + SongTimelineScrollMotion.maximumExtraTurn) * .pi / 180
        let nearEdge = 1 / (1 - CGFloat(sin(turn)) / 2 * perspective)
        let roll = CGFloat(sin(artworkRoll * .pi / 180))
        return nearEdge + roll
    }
}

/// 两种外观随滚动位置的变化。只看位置不看速度，静止画面就是滚动途中那一帧；
/// 坐标都在可视区里量（可视区顶部是 0）。开启「减少动态效果」时一律不变：封面保持基础转角。
///
/// - 封面：离可视区中部越远，封面在基础转角上多转一点、略缩小，并且比槽位走得慢一点（视差），
///   像一面略带弧度的墙。
/// - 时间线：从底边进入的卡片由淡到实、略放大；滑进顶栏下面时变淡。停在最上面的第一行保持原样。
public struct SongTimelineScrollMotion: Equatable, Sendable {
    /// 封面在基础转角上最多再转多少度。
    public static let maximumExtraTurn: Double = 9
    /// 封面最小缩放。
    public static let minimumArtworkScale: CGFloat = 0.94
    /// 封面视差幅度，按槽位高度。
    public static let artworkParallaxFraction: CGFloat = 0.1
    /// 卡片进入、离开时的最低透明度。
    public static let minimumCardOpacity: Double = 0.35
    /// 卡片进入时的最小缩放。
    public static let minimumCardScale: CGFloat = 0.96

    /// 封面多转的角度（度，≥ 0），方向跟基础转角相同。
    public let extraTurn: Double
    public let artworkScale: CGFloat
    /// 封面相对槽位的竖向位移（点）。
    public let artworkShift: CGFloat
    public let cardScale: CGFloat
    public let cardOpacity: Double

    public static let identity = SongTimelineScrollMotion(
        extraTurn: 0, artworkScale: 1, artworkShift: 0, cardScale: 1, cardOpacity: 1
    )

    private init(extraTurn: Double, artworkScale: CGFloat, artworkShift: CGFloat,
                 cardScale: CGFloat, cardOpacity: Double) {
        self.extraTurn = extraTurn
        self.artworkScale = artworkScale
        self.artworkShift = artworkShift
        self.cardScale = cardScale
        self.cardOpacity = cardOpacity
    }

    /// - Parameters:
    ///   - rowMinY: 槽位上沿到可视区顶部的距离（在可视区下方为正）。
    ///   - rowHeight: 槽位高度。
    ///   - viewportHeight: 可视区高度。
    public init(
        style: SongTimelineGeometry.Style,
        rowMinY: CGFloat,
        rowHeight: CGFloat,
        viewportHeight: CGFloat,
        reduceMotion: Bool
    ) {
        guard !reduceMotion, rowMinY.isFinite, rowHeight.isFinite, viewportHeight.isFinite,
              rowHeight > 0, viewportHeight > 0 else {
            self = .identity
            return
        }
        switch style {
        case .artwork:
            let half = viewportHeight / 2
            let fromCenter = rowMinY + rowHeight / 2 - half
            // 中部一个槽位高的一段保持原样，往外到可视区边缘走完。
            let core = min(rowHeight * 0.5, half * 0.5)
            let distance = SongListMotionCurve.smooth((abs(fromCenter) - core) / max(half - core, 1))
            extraTurn = Self.maximumExtraTurn * Double(distance)
            artworkScale = 1 - (1 - Self.minimumArtworkScale) * distance
            let reach = half + rowHeight
            artworkShift = -SongListMotionCurve.clamp(fromCenter / reach, -1, 1)
                * rowHeight * Self.artworkParallaxFraction
            cardScale = 1
            cardOpacity = 1
        case .timeline:
            // 进入：上沿离底边升起一段（一张多卡片高，最多可视区的三成）时完全复原。
            let enterBand = min(rowHeight * 1.6, viewportHeight * 0.3)
            let enter = SongListMotionCurve.smooth((viewportHeight - rowMinY) / enterBand)
            // 离开：上沿滑进顶部以后才开始，滑进一个槽位高时最淡。
            let exit = SongListMotionCurve.smooth(-rowMinY / rowHeight)
            let visible = Double(enter) * (1 - Double(exit))
            extraTurn = 0
            artworkScale = 1
            artworkShift = 0
            // 写成「1 减去缺的那一截」：完全可见时恰好是 1，不带浮点尾数。
            cardOpacity = 1 - (1 - Self.minimumCardOpacity) * (1 - visible)
            cardScale = 1 - (1 - Self.minimumCardScale) * (1 - enter)
        }
    }
}

enum SongListMotionCurve {
    static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return value > 0 ? upper : lower }
        return min(max(value, lower), upper)
    }

    /// 0…1 之间的平滑过渡（smoothstep），两端斜率为 0，不会在边界上突然起步。
    static func smooth(_ value: CGFloat) -> CGFloat {
        let t = clamp(value, 0, 1)
        return t * t * (3 - 2 * t)
    }
}
