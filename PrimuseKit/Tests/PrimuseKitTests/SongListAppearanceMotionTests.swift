import Foundation
import Testing
@testable import PrimuseKit

@Suite("Song timeline geometry")
struct SongTimelineGeometryTests {
    private let styles: [SongTimelineGeometry.Style] = [.timeline, .artwork]

    private func geometry(
        _ style: SongTimelineGeometry.Style,
        width: CGFloat = 393,
        ordinal: Int = 1,
        cardHeight: CGFloat = 60,
        accessibilitySize: Bool = false,
        rightToLeft: Bool = false
    ) -> SongTimelineGeometry {
        SongTimelineGeometry(style: style, containerWidth: width, ordinal: ordinal, cardHeight: cardHeight,
                             accessibilitySize: accessibilitySize, rightToLeft: rightToLeft)
    }

    @Test("手机竖屏两列：中轴居中，奇数在左、偶数在右")
    func phonesAlternateAroundACenteredAxis() {
        for style in styles {
            for width in [320.0, 361, 375, 393, 440] as [CGFloat] {
                let first = geometry(style, width: width, ordinal: 1)
                let second = geometry(style, width: width, ordinal: 2)
                #expect(!first.isSingleColumn)
                #expect(first.axisX == width / 2)
                #expect(first.isLeadingSide && first.isOnLeft)
                #expect(!second.isLeadingSide && !second.isOnLeft)
                #expect(first.card.maxX < first.axisX && second.card.minX > second.axisX)
                #expect(first.node == CGPoint(x: width / 2, y: first.rowHeight / 2))
                // 卡片（胶囊）内侧边与中轴之间留出节点那一段。
                #expect(abs(first.axisX - first.card.maxX - SongTimelineGeometry.axisGap) < 0.001)
                #expect(abs(second.card.minX - second.axisX - SongTimelineGeometry.axisGap) < 0.001)
            }
        }
    }

    @Test("槽位高度与序号无关，只随宽度与字号变")
    func rowHeightIsTheSameForEveryOrdinal() {
        for style in styles {
            let reference = geometry(style, ordinal: 1).rowHeight
            for ordinal in [2, 3, 4, 3991, 3992, 0, -1] {
                #expect(geometry(style, ordinal: ordinal).rowHeight == reference)
            }
            #expect(geometry(style, cardHeight: 90).rowHeight > reference)
            #expect(reference == reference.rounded())
        }
        #expect(geometry(.artwork, width: 640).rowHeight > geometry(.artwork, width: 393).rowHeight)
    }

    @Test("时间线：卡片在内容区里，外侧小封面、内侧字，节点就在卡片内侧边外")
    func timelineCardsKeepArtworkOutsideAndTextInside() {
        for width in [320.0, 361, 393, 700] as [CGFloat] {
            for ordinal in 1...4 {
                let g = geometry(.timeline, width: width, ordinal: ordinal)
                #expect(g.card.minX >= -0.001 && g.card.maxX <= width + 0.001)
                #expect(g.card.contains(g.artwork))
                #expect(g.card.contains(g.labels))
                #expect(g.labels.width > 40)
                #expect(g.artwork.width == g.artwork.height)
                if g.isOnLeft {
                    #expect(g.artwork.maxX < g.labels.minX)
                } else {
                    #expect(g.labels.maxX < g.artwork.minX)
                }
                // 左右两侧的卡片在竖直方向上略微交错，同一侧上下两张之间空出一大截。
                #expect(g.card.height >= g.rowHeight)
                #expect(2 * g.rowHeight - g.card.height > g.card.height * 0.6)
            }
        }
    }

    @Test("封面：大封面伸出外缘，胶囊压住它的内侧但留出大半张")
    func artworkCapsuleOverlapsTheInnerEdgeOfItsCover() {
        for width in [320.0, 375, 393, 440, 640] as [CGFloat] {
            for ordinal in 1...4 {
                let g = geometry(.artwork, width: width, ordinal: ordinal)
                #expect(g.artwork.width == g.artwork.height)
                #expect(g.artwork.height > g.rowHeight, "The cover reaches into the neighbouring slots")
                #expect(g.card.width >= SongTimelineGeometry.minimumCapsuleWidth)
                #expect(g.card.intersects(g.artwork), "The glass overlaps the cover")
                if g.isOnLeft {
                    #expect(g.artwork.minX < 0, "Bleeds off the leading edge")
                    #expect(g.card.minX > g.artwork.minX + g.artwork.width * 0.4)
                    #expect(g.artworkTurn > 0)
                } else {
                    #expect(g.artwork.maxX > width)
                    #expect(g.card.maxX < g.artwork.maxX - g.artwork.width * 0.4)
                    #expect(g.artworkTurn < 0)
                }
                #expect(g.card.contains(g.labels))
                // 播放标记落在封面露出来的那一段里，不被胶囊挡住。
                let glyphX = g.artwork.minX + g.artwork.width * g.artworkGlyphCenterX
                #expect(glyphX < g.card.minX || glyphX > g.card.maxX)
                #expect(glyphX >= 0 && glyphX <= width)
            }
        }
    }

    @Test("封面：同一侧上下两张转到最大角度也不相碰")
    func sameSideCoversNeverTouch() {
        for width in [320.0, 375, 393, 440, 640, 1024] as [CGFloat] {
            for cardHeight in [52.0, 60, 72, 84] as [CGFloat] {
                let g = geometry(.artwork, width: width, cardHeight: cardHeight)
                let extent = g.artwork.height * SongTimelineGeometry.maximumProjectedHeightFactor
                let shift = g.rowHeight * SongTimelineScrollMotion.artworkParallaxFraction
                #expect(2 * g.rowHeight - extent > shift, "width \(width), card \(cardHeight)")
                #expect(g.verticalOverflow >= (extent - g.rowHeight) / 2 - 0.001)
            }
        }
    }

    @Test("同一侧上下两张封面平面转角一正一负")
    func sameSideCoversAlternateTheirRoll() {
        let first = geometry(.artwork, ordinal: 1)
        let third = geometry(.artwork, ordinal: 3)
        let fifth = geometry(.artwork, ordinal: 5)
        #expect(first.artworkRoll == -third.artworkRoll)
        #expect(first.artworkRoll == fifth.artworkRoll)
        #expect(geometry(.timeline).artworkRoll == 0 && geometry(.timeline).artworkTurn == 0)
    }

    @Test("从右往左书写时整体镜像")
    func rightToLeftMirrorsEverything() {
        for style in styles {
            for accessibility in [false, true] {
                for ordinal in 1...4 {
                    let ltr = geometry(style, ordinal: ordinal, accessibilitySize: accessibility)
                    let rtl = geometry(style, ordinal: ordinal, accessibilitySize: accessibility, rightToLeft: true)
                    let width = ltr.containerWidth
                    #expect(rtl.isLeadingSide == ltr.isLeadingSide)
                    #expect(rtl.isOnLeft == !ltr.isOnLeft)
                    #expect(abs(rtl.axisX - (width - ltr.axisX)) < 0.001)
                    #expect(abs(rtl.card.minX - (width - ltr.card.maxX)) < 0.001)
                    #expect(abs(rtl.artwork.minX - (width - ltr.artwork.maxX)) < 0.001)
                    #expect(abs(rtl.labels.minX - (width - ltr.labels.maxX)) < 0.001)
                    #expect(rtl.card.minY == ltr.card.minY && rtl.rowHeight == ltr.rowHeight)
                    #expect(rtl.artworkTurn == -ltr.artworkTurn && rtl.artworkRoll == -ltr.artworkRoll)
                    #expect(abs(rtl.artworkGlyphCenterX - (1 - ltr.artworkGlyphCenterX)) < 0.001)
                }
            }
        }
        // 第一首在前侧：从右往左时在右边。
        #expect(!geometry(.timeline, ordinal: 1, rightToLeft: true).isOnLeft)
    }

    @Test("辅助功能字号与很窄的容器排成单列：中轴靠前侧，卡片都在后侧")
    func accessibilityAndNarrowContainersUseOneColumn() {
        for style in styles {
            for (width, accessibility) in [(393.0, true), (1024, true), (280, false)] as [(CGFloat, Bool)] {
                for ordinal in 1...3 {
                    let g = geometry(style, width: width, ordinal: ordinal, cardHeight: 120,
                                     accessibilitySize: accessibility)
                    #expect(g.isSingleColumn)
                    #expect(!g.isLeadingSide && !g.isOnLeft)
                    #expect(g.card.minX > g.axisX)
                    #expect(g.labels.width > 100 || width < 300)
                    if style == .timeline {
                        #expect(g.rowHeight > g.card.height, "No interleaving in one column")
                    } else {
                        #expect(g.rowHeight >= g.artwork.height, "The cover stays in its own slot")
                    }
                }
            }
        }
    }

    @Test("宽屏封顶居中：iPad 上中轴仍在正中，两侧留白")
    func wideContainersAreCappedAndCentered() {
        for style in styles {
            let maximum = SongTimelineGeometry.maximumWidth(for: style)
            let g = geometry(style, width: 1180, ordinal: 1)
            #expect(g.axisX == 590)
            let inset = (1180 - maximum) / 2
            switch style {
            case .timeline:
                #expect(abs(g.card.minX - inset) < 0.001)
            case .artwork:
                #expect(g.artwork.minX > 0 && g.artwork.minX < inset)
            }
        }
    }

    @Test("宽度或字号异常时按默认值排")
    func degenerateInputsFallBack() {
        for style in styles {
            let fallback = geometry(style, width: SongTimelineGeometry.fallbackWidth)
            for width in [0, -10, .nan, .infinity] as [CGFloat] {
                #expect(geometry(style, width: width) == fallback)
            }
            let tiny = geometry(style, cardHeight: 1)
            #expect(tiny.card.height >= 32)
            #expect(geometry(style, cardHeight: .nan).rowHeight.isFinite)
        }
    }

    @Test("命中范围：节点那一段连着卡片，封面外侧不超出未旋转的框")
    func hitRegionsCoverNodeCardAndCover() {
        for style in styles {
            for ordinal in 1...2 {
                let g = geometry(style, ordinal: ordinal)
                #expect(g.nodeHitRect.contains(g.node))
                #expect(g.nodeHitRect.intersects(g.card))
                #expect(g.artwork.contains(g.artworkHitRect))
            }
        }
    }
}

@Suite("Song timeline scroll motion")
struct SongTimelineScrollMotionTests {
    private let row: CGFloat = 70
    private let viewport: CGFloat = 640

    private func motion(_ style: SongTimelineGeometry.Style, rowMinY: CGFloat,
                        reduceMotion: Bool = false) -> SongTimelineScrollMotion {
        SongTimelineScrollMotion(style: style, rowMinY: rowMinY, rowHeight: row,
                                 viewportHeight: viewport, reduceMotion: reduceMotion)
    }

    @Test("封面：可视区中部原样，越往上下边缘多转一点、略缩小")
    func coversTurnMoreTowardTheEdges() {
        let center = motion(.artwork, rowMinY: viewport / 2 - row / 2)
        #expect(center.extraTurn == 0 && center.artworkScale == 1 && center.artworkShift == 0)
        let upper = motion(.artwork, rowMinY: 20)
        let lower = motion(.artwork, rowMinY: viewport - row - 20)
        #expect(upper.extraTurn > 4 && upper.extraTurn <= SongTimelineScrollMotion.maximumExtraTurn)
        #expect(abs(upper.extraTurn - lower.extraTurn) < 0.001, "Symmetric about the centre")
        #expect(upper.artworkScale < 1 && upper.artworkScale >= SongTimelineScrollMotion.minimumArtworkScale)
        let far = motion(.artwork, rowMinY: -400)
        #expect(far.extraTurn == SongTimelineScrollMotion.maximumExtraTurn)
        #expect(far.artworkScale == SongTimelineScrollMotion.minimumArtworkScale)
        #expect(center.cardOpacity == 1 && upper.cardOpacity == 1 && upper.cardScale == 1)
    }

    @Test("封面视差：下半部封面偏上，上半部偏下，幅度有上限")
    func coverParallaxLagsBehindTheRow() {
        let lower = motion(.artwork, rowMinY: viewport - row)
        let upper = motion(.artwork, rowMinY: 0)
        #expect(lower.artworkShift < 0 && upper.artworkShift > 0)
        #expect(abs(lower.artworkShift + upper.artworkShift) < 0.001)
        let limit = row * SongTimelineScrollMotion.artworkParallaxFraction
        for y in stride(from: -2000.0, through: 2000, by: 37) {
            #expect(abs(motion(.artwork, rowMinY: CGFloat(y)).artworkShift) <= limit + 0.001)
        }
    }

    @Test("时间线：停在最上面的第一行与中部的卡片原样")
    func restingTimelineCardsAreUntouched() {
        for y in [0, 12, 200, viewport / 2] as [CGFloat] {
            let m = motion(.timeline, rowMinY: y)
            #expect(m.cardOpacity == 1 && m.cardScale == 1, "y \(y)")
            #expect(m.extraTurn == 0 && m.artworkScale == 1 && m.artworkShift == 0)
        }
    }

    @Test("时间线：从底边进入由淡到实，滑进顶部变淡")
    func timelineCardsFadeInAtTheBottomAndOutAtTheTop() {
        let entering = motion(.timeline, rowMinY: viewport - 10)
        #expect(entering.cardOpacity < 0.6 && entering.cardOpacity >= SongTimelineScrollMotion.minimumCardOpacity)
        #expect(entering.cardScale < 1 && entering.cardScale >= SongTimelineScrollMotion.minimumCardScale)
        var previous = 0.0
        for y in stride(from: viewport, through: viewport - 200, by: -10) {
            let opacity = motion(.timeline, rowMinY: y).cardOpacity
            #expect(opacity >= previous - 0.0001)
            previous = opacity
        }
        let leaving = motion(.timeline, rowMinY: -row)
        #expect(leaving.cardOpacity == SongTimelineScrollMotion.minimumCardOpacity)
        #expect(motion(.timeline, rowMinY: -row / 2).cardOpacity < 1)
    }

    @Test("减少动态效果与异常输入时不变")
    func reduceMotionAndDegenerateInputsAreIdentity() {
        for style in [SongTimelineGeometry.Style.timeline, .artwork] {
            for y in [-300, 0, 300, 700] as [CGFloat] {
                #expect(motion(style, rowMinY: y, reduceMotion: true) == .identity)
            }
            for bad in [CGFloat.nan, .infinity] {
                #expect(SongTimelineScrollMotion(style: style, rowMinY: bad, rowHeight: row,
                                                 viewportHeight: viewport, reduceMotion: false) == .identity)
                #expect(SongTimelineScrollMotion(style: style, rowMinY: 100, rowHeight: row,
                                                 viewportHeight: bad, reduceMotion: false) == .identity)
            }
            #expect(SongTimelineScrollMotion(style: style, rowMinY: 100, rowHeight: 0,
                                             viewportHeight: viewport, reduceMotion: false) == .identity)
        }
    }
}
