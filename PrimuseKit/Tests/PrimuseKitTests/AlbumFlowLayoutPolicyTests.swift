import Testing
@testable import PrimuseKit

/// 全屏「封面流」(#191)的几何、拖动与点按判定。
struct AlbumFlowLayoutPolicyTests {
    private func phoneLandscape() -> AlbumFlowLayoutPolicy.Layout {
        AlbumFlowLayoutPolicy.layout(
            canvasWidth: 852,
            canvasHeight: 393,
            topInset: 20,
            bottomInset: 112,
            horizontalInset: 59,
            titleHeight: 44,
            titleSpacing: 10
        )
    }

    @Test func centerCoverSitsMidCanvasBetweenTheTitleAndTheControls() {
        let layout = phoneLandscape()
        #expect(abs(layout.centerMidX - 426) < 0.001)
        #expect(layout.centerOriginY >= 20 + 44 + 10)
        // 封面和倒影上面那一截不压到底部控件上；再往下的倒影淡进控件底下。
        let visibleReflection = layout.reflectionFraction * AlbumFlowLayoutPolicy.visibleReflectionShare
        let groupBottom = layout.centerOriginY + layout.centerSide * (1 + visibleReflection)
        #expect(groupBottom <= 393 - 112 + 0.001)
        #expect(layout.centerSide > 393 * 0.4)
        #expect(layout.titleOriginY + layout.titleHeight <= layout.centerOriginY)
    }

    @Test func neighboursAreSmallerAndFillTheLandscapeWidth() {
        let layout = phoneLandscape()
        #expect(layout.neighborSide < layout.centerSide)
        #expect(layout.neighborsPerSide >= 2)
        #expect(layout.neighborsPerSide <= AlbumFlowLayoutPolicy.maximumNeighborsPerSide)
        // 左右对称，离中间越远越靠外。
        #expect(abs((layout.neighborMidX(offset: -1) + layout.neighborMidX(offset: 1)) / 2 - layout.centerMidX) < 0.001)
        #expect(layout.neighborMidX(offset: 2) > layout.neighborMidX(offset: 1))
        #expect(layout.neighborMidX(offset: -2) < layout.neighborMidX(offset: -1))
        // 第一张邻居不压住中间封面的正面。
        #expect(layout.neighborMidX(offset: 1) - layout.neighborSide / 2 > layout.centerMidX - layout.centerSide / 2)
    }

    @Test func portraitKeepsALargerShareOfTheWidthForTheCenterCover() {
        let portrait = AlbumFlowLayoutPolicy.layout(
            canvasWidth: 393,
            canvasHeight: 852,
            topInset: 54,
            bottomInset: 160,
            horizontalInset: 24,
            titleHeight: 60,
            titleSpacing: 12
        )
        #expect(portrait.centerSide > 393 * 0.5)
        #expect(portrait.centerSide <= (393 - 48) * 0.66 + 0.001)
    }

    @Test func aTinyCanvasStillDrawsAUsableCover() {
        let layout = AlbumFlowLayoutPolicy.layout(
            canvasWidth: 300,
            canvasHeight: 160,
            topInset: 40,
            bottomInset: 100,
            horizontalInset: 0,
            titleHeight: 30,
            titleSpacing: 8
        )
        #expect(layout.centerSide == AlbumFlowLayoutPolicy.minimumCenterSide)
    }

    @Test func tapHitTestingFollowsTheDrawnCover() {
        let layout = phoneLandscape()
        #expect(layout.centerContains(x: layout.centerMidX, y: layout.centerMidY))
        #expect(!layout.centerContains(x: layout.centerOriginX - 4, y: layout.centerMidY))
        #expect(layout.centerContains(x: layout.centerOriginX - 4, y: layout.centerMidY, tolerance: 8))
        #expect(!layout.centerContains(x: layout.neighborMidX(offset: 2), y: layout.centerMidY))
    }

    /// 倒影下面给歌词留的一块：在露出的倒影之下、底部控件之上；留了位置封面就相应缩小。
    @Test func lyricBandSitsBelowTheReflectionAndAboveTheControls() {
        let plain = phoneLandscape()
        let withLyrics = AlbumFlowLayoutPolicy.layout(
            canvasWidth: 852,
            canvasHeight: 393,
            topInset: 20,
            bottomInset: 112,
            horizontalInset: 59,
            titleHeight: 44,
            titleSpacing: 10,
            lyricHeight: 20,
            lyricSpacing: 8
        )
        #expect(plain.lyricHeight == 0)
        #expect(withLyrics.lyricHeight == 20)
        #expect(withLyrics.centerSide < plain.centerSide)
        let visibleReflection = withLyrics.centerSide * withLyrics.reflectionFraction
            * AlbumFlowLayoutPolicy.visibleReflectionShare
        #expect(abs(withLyrics.lyricOriginY - (withLyrics.baseline + visibleReflection + 8)) < 0.001)
        #expect(withLyrics.lyricOriginY + withLyrics.lyricHeight <= 393 - 112 + 0.001)
        #expect(withLyrics.titleOriginY + withLyrics.titleHeight <= withLyrics.centerOriginY)
    }

    /// 宽画布按宽度封顶，歌词塞得下时封面不必缩。
    @Test func wideCanvasKeepsTheCoverSizeWhenTheLyricsFit() {
        func layout(lyrics: Double) -> AlbumFlowLayoutPolicy.Layout {
            AlbumFlowLayoutPolicy.layout(
                canvasWidth: 1440,
                canvasHeight: 900,
                topInset: 36,
                bottomInset: 95,
                horizontalInset: 57,
                titleHeight: 39,
                titleSpacing: 9,
                lyricHeight: lyrics,
                lyricSpacing: lyrics > 0 ? 8 : 0
            )
        }
        #expect(abs(layout(lyrics: 81).centerSide - layout(lyrics: 0).centerSide) < 0.001)
    }

    /// 拖动途中的位置是连续的：整数格与原来的摆法一致，中间一路缩小、转过去。
    @Test func placementMorphsFromTheCenterToTheSides() {
        let layout = phoneLandscape()
        let center = layout.placement(at: 0)
        #expect(center.midX == layout.centerMidX)
        #expect(center.side == layout.centerSide)
        #expect(center.tiltDegrees == 0)
        #expect(center.opacity == 1)

        let right = layout.placement(at: 1)
        #expect(abs(right.midX - (layout.centerMidX + layout.firstNeighborOffset)) < 0.001)
        #expect(abs(right.side - layout.neighborSide) < 0.001)
        #expect(right.tiltDegrees == -layout.tiltDegrees)
        #expect(layout.placement(at: -1).tiltDegrees == layout.tiltDegrees)

        let halfway = layout.placement(at: 0.5)
        #expect(halfway.midX > center.midX && halfway.midX < right.midX)
        #expect(halfway.side < center.side && halfway.side > right.side)
        #expect(halfway.tiltDegrees < 0 && halfway.tiltDegrees > right.tiltDegrees)

        // 再往外只挪位置、逐张变淡。
        let third = layout.placement(at: 3)
        #expect(abs(third.midX - (layout.centerMidX + layout.firstNeighborOffset + 2 * layout.neighborSpacing)) < 0.001)
        #expect(third.side == right.side)
        #expect(abs(third.opacity - 0.84) < 0.001)
        #expect(abs(layout.placement(at: 1.5).midX - (layout.centerMidX + layout.firstNeighborOffset + 0.5 * layout.neighborSpacing)) < 0.001)
    }

    @Test func tappingASideCoverPicksTheInnermostCardUnderTheFinger() {
        let layout = phoneLandscape()
        let coverY = layout.baseline - layout.neighborSide / 2
        #expect(layout.offset(atX: layout.centerMidX, y: layout.centerMidY, before: 3, after: 3) == 0)
        #expect(layout.offset(atX: layout.neighborMidX(offset: 1), y: coverY, before: 3, after: 3) == 1)
        #expect(layout.offset(atX: layout.neighborMidX(offset: -2), y: coverY, before: 3, after: 3) == -2)
        // 外面那张露出来的一条也认得出。
        let outerStrip = layout.neighborMidX(offset: 3) + layout.neighborSide * 0.2
        #expect(layout.offset(atX: outerStrip, y: coverY, before: 3, after: 3) == 3)
        // 那一边没画封面、点在倒影上、点在两侧之外，都不算。
        #expect(layout.offset(atX: layout.neighborMidX(offset: 1), y: coverY, before: 3, after: 0) == nil)
        #expect(layout.offset(atX: layout.neighborMidX(offset: 1), y: layout.baseline + 20, before: 3, after: 3) == nil)
        #expect(layout.offset(atX: layout.neighborMidX(offset: 2) + layout.neighborSide, y: coverY, before: 3, after: 2) == nil)
    }

    @Test func draggingAFullStepBringsTheNextCoverToTheCenter() {
        let layout = phoneLandscape()
        let step = layout.firstNeighborOffset
        #expect(abs(layout.dragShift(translation: -step, hasBefore: true, hasAfter: true) - 1) < 0.001)
        #expect(abs(layout.dragShift(translation: step / 2, hasBefore: true, hasAfter: true) + 0.5) < 0.001)
        // 过了一格越拖越沉。
        let over = layout.dragShift(translation: -step * 3, hasBefore: true, hasAfter: true)
        #expect(over > 1 && over < 1 + 0.25)
        // 那一边没有封面：只能拉出一点。
        let empty = layout.dragShift(translation: -step * 3, hasBefore: true, hasAfter: false)
        #expect(empty > 0 && empty < 0.3)
        #expect(layout.dragShift(translation: 0, hasBefore: false, hasAfter: false) == 0)
    }

    @Test func releasingCommitsPastAThirdOfAStepOrOnAFling() {
        #expect(AlbumFlowLayoutPolicy.releaseStep(shift: 0.45, predictedShift: 0.5) == 1)
        #expect(AlbumFlowLayoutPolicy.releaseStep(shift: -0.31, predictedShift: -0.2) == -1)
        #expect(AlbumFlowLayoutPolicy.releaseStep(shift: 0.1, predictedShift: 0.2) == 0)
        // 拖得不多但甩得快。
        #expect(AlbumFlowLayoutPolicy.releaseStep(shift: 0.12, predictedShift: 0.9) == 1)
        // 甩回反方向不算。
        #expect(AlbumFlowLayoutPolicy.releaseStep(shift: 0.2, predictedShift: -0.9) == 0)
    }
}
