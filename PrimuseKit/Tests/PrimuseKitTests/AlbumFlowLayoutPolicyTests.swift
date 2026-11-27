import Testing
@testable import PrimuseKit

/// 全屏「封面流」(#191)唱片架的几何、拖动与点按判定。
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

    @Test func pulledCardSitsMidCanvasBetweenTheTitleAndTheControls() {
        let layout = phoneLandscape()
        #expect(abs(layout.centerMidX - 426) < 0.001)
        #expect(layout.centerOriginY >= 20 + 44 + 10)
        // 抽出的那张、抬起的那截与架子底板都在底部控件之上。
        #expect(layout.baseline + layout.shelfDepth <= 393 - 112 + 0.001)
        #expect(abs(layout.baseline - (layout.centerOriginY + layout.centerSide + layout.liftHeight)) < 0.001)
        #expect(layout.centerSide > 393 * 0.4)
        #expect(layout.titleOriginY + layout.titleHeight <= layout.centerOriginY)
    }

    @Test func spinesAreNarrowAndStandLowerThanThePulledCard() {
        let layout = phoneLandscape()
        // 书脊宽是封面边长的一成到一成四。
        #expect(layout.spineWidth >= layout.centerSide * 0.10)
        #expect(layout.spineWidth <= layout.centerSide * 0.14)
        #expect(layout.spinePitch > layout.spineWidth)
        #expect(layout.rackSide < layout.centerSide)
        // 架子张开时第一张书脊不碰抽出的那张。
        #expect(layout.firstSpineOffset - layout.spineWidth / 2 > layout.centerSide / 2)
        // 牌面坐标里的书脊宽：缩到架子里的大小时正好是书脊宽。
        #expect(abs(layout.spineFaceShare * layout.rackSide - layout.spineWidth) < 0.001)
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

    /// 架子下面给歌词留的一块：在底板之下、底部控件之上；留了位置唱片就相应缩小。
    @Test func lyricBandSitsBelowTheShelfAndAboveTheControls() {
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
        #expect(abs(withLyrics.lyricOriginY - (withLyrics.baseline + withLyrics.shelfDepth + 8)) < 0.001)
        #expect(withLyrics.lyricOriginY + withLyrics.lyricHeight <= 393 - 112 + 0.001)
        #expect(withLyrics.titleOriginY + withLyrics.titleHeight <= withLyrics.centerOriginY)
    }

    /// 宽画布按宽度封顶，歌词塞得下时唱片不必缩。
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

    /// 停住时：中间那张整个抽出来、正对着人、抬高一截，正好落在抽出那张的方框里；两侧只露书脊，立在台面上。
    @Test func settledRackPullsOutTheCenterAndShowsOnlySpinesAround() {
        let layout = phoneLandscape()
        let center = layout.placement(at: 0)
        #expect(center.midX == layout.centerMidX)
        #expect(abs(center.scale - 1) < 0.001)
        #expect(abs(center.pull - 1) < 0.001)
        #expect(abs(center.bottomY - (layout.centerOriginY + layout.centerSide)) < 0.001)
        #expect(abs(center.faceReveal - 1) < 0.001)
        #expect(abs(center.faceOpacity - 1) < 0.001)
        #expect(abs(center.heroOpacity - 1) < 0.001)
        #expect(center.spineOpacity < 0.001)
        #expect(center.shade < 0.001)

        let right = layout.placement(at: 1)
        #expect(abs(right.midX - (layout.centerMidX + layout.firstSpineOffset)) < 0.001)
        #expect(right.pull == 0)
        #expect(right.bottomY == layout.baseline)
        #expect(abs(right.scale * layout.centerSide - layout.rackSide) < 0.001)
        #expect(right.spineOpacity == 1 && right.faceOpacity == 0 && right.heroOpacity == 0)
        // 左右对称。
        let left = layout.placement(at: -1)
        #expect(abs((left.midX + right.midX) / 2 - layout.centerMidX) < 0.001)

        // 越远越小、越暗，一张张紧挨着往外排；最外头渐渐淡出。
        let second = layout.placement(at: 2)
        let third = layout.placement(at: 3)
        #expect(second.midX - right.midX < layout.spinePitch)
        #expect(second.midX - right.midX > layout.spinePitch * 0.95)
        #expect(third.midX - second.midX < second.midX - right.midX)
        #expect(third.scale < second.scale && second.scale < right.scale)
        #expect(third.shade > second.shade && second.shade > right.shade)
        #expect(layout.placement(at: 4).opacity == 1)
        #expect(layout.placement(at: 6).opacity < layout.placement(at: 5).opacity)
        #expect(layout.placement(at: 5).opacity < 1)
    }

    /// 拖动时架子合拢：一张张按书脊间距排，路过中间的那张只稍稍抽出一点、仍是书脊，不转成正面。
    @Test func draggingClosesTheRackAndOnlyLiftsThePassingSpine() {
        let layout = phoneLandscape()
        let passing = layout.placement(at: 0, settle: 0)
        #expect(abs(passing.pull - AlbumFlowLayoutPolicy.passingPull) < 0.001)
        #expect(passing.bottomY < layout.baseline)
        #expect(passing.bottomY > layout.centerOriginY + layout.centerSide)
        #expect(passing.spineOpacity == 1)
        #expect(passing.heroOpacity == 0)
        #expect(passing.scale < 0.8)

        let neighbour = layout.placement(at: 1, settle: 0)
        #expect(abs(neighbour.midX - (layout.centerMidX + layout.spinePitch)) < 0.001)
        #expect(neighbour.pull == 0)

        // 半路上：位置连续，抽出的程度随离中间的远近变。
        let halfway = layout.placement(at: 0.5, settle: 0)
        #expect(halfway.midX > passing.midX && halfway.midX < neighbour.midX)
        #expect(halfway.pull < passing.pull && halfway.pull > 0)

        // 架子张开到一半：中间那张抽出一半、正面露出一部分。
        let opening = layout.placement(at: 0, settle: 0.5)
        #expect(opening.pull > passing.pull && opening.pull < 1)
        #expect(opening.faceReveal > 0 && opening.faceReveal < 1)
        #expect(opening.scale > passing.scale && opening.scale < 1)
    }

    @Test func tapHitTestingFollowsTheDrawnCards() {
        let layout = phoneLandscape()
        #expect(layout.centerContains(x: layout.centerMidX, y: layout.centerMidY))
        #expect(!layout.centerContains(x: layout.centerOriginX - 4, y: layout.centerMidY))
        #expect(layout.centerContains(x: layout.centerOriginX - 4, y: layout.centerMidY, tolerance: 8))
        #expect(!layout.centerContains(x: layout.placement(at: 2).midX, y: layout.centerMidY))
    }

    /// 点中抽出来的那张认它停在哪一格；点书脊认书脊那一格（含两张之间的缝），点在空白处不算。
    @Test func tappingPicksThePulledCardOrTheSpineUnderTheFinger() {
        let layout = phoneLandscape()
        let spineY = layout.baseline - layout.rackSide / 2
        #expect(layout.offset(atX: layout.centerMidX, y: layout.centerMidY, browsePosition: 0, before: 3, after: 3) == 0)
        #expect(layout.offset(atX: layout.centerMidX, y: layout.centerMidY, browsePosition: 2, before: 3, after: 3) == 2)
        #expect(layout.offset(
            atX: layout.placement(at: 1).midX, y: spineY, browsePosition: 0, before: 3, after: 3
        ) == 1)
        #expect(layout.offset(
            atX: layout.placement(at: -2).midX, y: spineY, browsePosition: 0, before: 3, after: 3
        ) == -2)
        // 两张书脊之间的缝认靠得近的那张。
        let seam = layout.placement(at: 2).midX - layout.spinePitch * 0.4
        #expect(layout.offset(atX: seam, y: spineY, browsePosition: 0, before: 3, after: 3) == 2)
        // 浏览到右边第二张时，正在播的那张成了左边的书脊。
        let playingSpine = layout.placement(at: -2).midX
        #expect(layout.offset(atX: playingSpine, y: spineY, browsePosition: 2, before: 3, after: 3) == 0)
        // 那一边没有唱片、点在架子下面、点在架子外头，都不算。
        #expect(layout.offset(
            atX: layout.placement(at: 1).midX, y: spineY, browsePosition: 0, before: 3, after: 0
        ) == nil)
        #expect(layout.offset(
            atX: layout.placement(at: 1).midX, y: layout.baseline + 20, browsePosition: 0, before: 3, after: 3
        ) == nil)
        #expect(layout.offset(
            atX: layout.placement(at: 2).midX + layout.spinePitch * 2, y: spineY, browsePosition: 0, before: 3, after: 2
        ) == nil)
    }

    /// 拖一张书脊的间距挪一格（书脊跟着手走），向左拖往右边走；过了两头只能再拉出一点。
    @Test func draggingFollowsTheFingerOneSpineAtATime() {
        let layout = phoneLandscape()
        let pitch = layout.spinePitch
        #expect(abs(layout.browsePosition(from: 0, translation: -pitch, before: 3, after: 3) - 1) < 0.001)
        #expect(abs(layout.browsePosition(from: 0, translation: pitch * 2.5, before: 3, after: 3) + 2.5) < 0.001)
        #expect(abs(layout.browsePosition(from: 2, translation: pitch, before: 3, after: 3) - 1) < 0.001)
        // 拖过头：越拖越沉。
        let over = layout.browsePosition(from: 0, translation: -pitch * 6, before: 3, after: 3)
        #expect(over > 3 && over < 3.35)
        // 那一边没有唱片：只能拉出一点。
        let empty = layout.browsePosition(from: 0, translation: -pitch * 3, before: 3, after: 0)
        #expect(empty > 0 && empty < 0.35)
        #expect(layout.browsePosition(from: 0, translation: 0, before: 0, after: 0) == 0)
    }
}

@Suite("Album flow browsing")
struct AlbumFlowBrowsePolicyTests {
    @Test("Stops on the nearest card and never past either end")
    func detentRoundsAndClamps() {
        #expect(AlbumFlowBrowsePolicy.detent(at: 0.4, before: 3, after: 3) == 0)
        #expect(AlbumFlowBrowsePolicy.detent(at: 0.6, before: 3, after: 3) == 1)
        #expect(AlbumFlowBrowsePolicy.detent(at: -1.7, before: 3, after: 3) == -2)
        #expect(AlbumFlowBrowsePolicy.detent(at: 5.2, before: 3, after: 3) == 3)
        #expect(AlbumFlowBrowsePolicy.detent(at: -0.8, before: 0, after: 3) == 0)
        #expect(AlbumFlowBrowsePolicy.detent(at: .nan, before: 3, after: 3) == 0)
    }

    @Test("Releasing snaps with momentum, a fling goes a few cards at most")
    func releaseSnapsWithMomentum() {
        // 慢慢松手：就近停。
        #expect(AlbumFlowBrowsePolicy.releaseTarget(position: 1.3, predictedPosition: 1.35, before: 6, after: 6) == 1)
        // 往右甩：多走几张。
        #expect(AlbumFlowBrowsePolicy.releaseTarget(position: 0.4, predictedPosition: 2.8, before: 6, after: 6) == 3)
        // 甩得再猛也最多再走四张。
        #expect(AlbumFlowBrowsePolicy.releaseTarget(position: 0.2, predictedPosition: 40, before: 6, after: 6) == 4)
        // 到头为止。
        #expect(AlbumFlowBrowsePolicy.releaseTarget(position: -1.2, predictedPosition: -5, before: 2, after: 6) == -2)
        // 往回甩：回到起点那一侧。
        #expect(AlbumFlowBrowsePolicy.releaseTarget(position: 0.6, predictedPosition: -0.4, before: 6, after: 6) == 0)
    }

    @Test("Arrow keys and the remote move one card and stop at the ends")
    func stepMovesOneCard() {
        #expect(AlbumFlowBrowsePolicy.step(from: 0, by: 1, before: 2, after: 2) == 1)
        #expect(AlbumFlowBrowsePolicy.step(from: -2, by: -1, before: 2, after: 2) == -2)
        #expect(AlbumFlowBrowsePolicy.step(from: 2, by: 1, before: 2, after: 2) == 2)
        #expect(AlbumFlowBrowsePolicy.step(from: 0, by: 1, before: 2, after: 0) == 0)
    }

    @Test("Returns to the playing card after three idle seconds away from it")
    func returnsAfterIdle() {
        #expect(AlbumFlowBrowsePolicy.shouldReturnToPlaying(browseIndex: 2, isInteracting: false, idle: 3))
        #expect(!AlbumFlowBrowsePolicy.shouldReturnToPlaying(browseIndex: 2, isInteracting: false, idle: 2.9))
        #expect(!AlbumFlowBrowsePolicy.shouldReturnToPlaying(browseIndex: -1, isInteracting: true, idle: 10))
        #expect(!AlbumFlowBrowsePolicy.shouldReturnToPlaying(browseIndex: 0, isInteracting: false, idle: 10))
    }

    @Test("Dragging pushes the pulled card back in as the finger moves")
    func dragCollapsesTheRackWithTheFinger() {
        #expect(AlbumFlowBrowsePolicy.dragSettle(from: 1, travelled: 0) == 1)
        let early = AlbumFlowBrowsePolicy.dragSettle(from: 1, travelled: 0.1)
        let later = AlbumFlowBrowsePolicy.dragSettle(from: 1, travelled: 0.3)
        #expect(early < 1 && later < early && later > 0)
        #expect(AlbumFlowBrowsePolicy.dragSettle(from: 1, travelled: AlbumFlowBrowsePolicy.collapseDistance) == 0)
        #expect(AlbumFlowBrowsePolicy.dragSettle(from: 1, travelled: 3) == 0)
        // 起手时已经合拢着（上一段还没抽出来）就一直合拢。
        #expect(AlbumFlowBrowsePolicy.dragSettle(from: 0, travelled: 0.1) == 0)
    }

    @Test("Long moves put the card back, slide, then pull the next one out")
    func longMovesAreStaged() {
        let short = AlbumFlowBrowsePolicy.motion(distance: 1, reduceMotion: false)
        #expect(short.collapse == 0 && short.expand == 0 && short.travel > 0)
        let long = AlbumFlowBrowsePolicy.motion(distance: 4, reduceMotion: false)
        #expect(long.collapse > 0 && long.expand > 0)
        #expect(long.travel > short.travel)
        #expect(AlbumFlowBrowsePolicy.motion(distance: 40, reduceMotion: false).travel <= 0.66)
        #expect(AlbumFlowBrowsePolicy.motion(distance: 4, reduceMotion: true).isInstant)
        #expect(AlbumFlowBrowsePolicy.motion(distance: 0, reduceMotion: false).isInstant)
    }

    @Test("Pulling the browsed card up follows the finger and commits past the threshold")
    func queueLiftFollowsAndCommits() {
        let side = 228.0
        let threshold = AlbumFlowBrowsePolicy.queueLiftThreshold(centerSide: side)
        #expect(threshold >= 44)
        // 往上跟手，往下不动。
        #expect(AlbumFlowBrowsePolicy.queueLiftOffset(translation: -30, centerSide: side) == 30)
        #expect(AlbumFlowBrowsePolicy.queueLiftOffset(translation: 40, centerSide: side) == 0)
        // 过了门槛越拉越沉。
        let far = AlbumFlowBrowsePolicy.queueLiftOffset(translation: -threshold * 3, centerSide: side)
        #expect(far > threshold && far < threshold + side * 0.12)
        // 拉够了算；拉一点但甩得猛也算；只拉一点不算；往下不算。
        #expect(AlbumFlowBrowsePolicy.queueLiftCommits(translation: -threshold, predictedTranslation: -threshold, centerSide: side))
        #expect(AlbumFlowBrowsePolicy.queueLiftCommits(
            translation: -threshold * 0.5, predictedTranslation: -threshold * 3, centerSide: side
        ))
        #expect(!AlbumFlowBrowsePolicy.queueLiftCommits(
            translation: -threshold * 0.5, predictedTranslation: -threshold * 0.6, centerSide: side
        ))
        #expect(!AlbumFlowBrowsePolicy.queueLiftCommits(translation: 60, predictedTranslation: 200, centerSide: side))
    }
}
