import Testing
@testable import PrimuseKit

/// 全屏「封面流」(#191)的几何与两侧专辑取法。
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

    @Test func neighboursComeFromBothSidesWithoutWrappingAround() {
        let middle = AlbumFlowLayoutPolicy.neighborIndices(count: 10, currentIndex: 5, perSide: 3)
        #expect(middle.before == [4, 3, 2])
        #expect(middle.after == [6, 7, 8])

        let first = AlbumFlowLayoutPolicy.neighborIndices(count: 10, currentIndex: 0, perSide: 3)
        #expect(first.before.isEmpty)
        #expect(first.after == [1, 2, 3])

        let last = AlbumFlowLayoutPolicy.neighborIndices(count: 10, currentIndex: 9, perSide: 3)
        #expect(last.before == [8, 7, 6])
        #expect(last.after.isEmpty)

        let short = AlbumFlowLayoutPolicy.neighborIndices(count: 3, currentIndex: 1, perSide: 4)
        #expect(short.before == [0])
        #expect(short.after == [2])
    }

    @Test func noNeighboursWithoutACurrentAlbumOrALibraryToBrowse() {
        #expect(AlbumFlowLayoutPolicy.neighborIndices(count: 10, currentIndex: nil, perSide: 3) == ([], []))
        #expect(AlbumFlowLayoutPolicy.neighborIndices(count: 1, currentIndex: 0, perSide: 3) == ([], []))
        #expect(AlbumFlowLayoutPolicy.neighborIndices(count: 10, currentIndex: 4, perSide: 0) == ([], []))
        #expect(AlbumFlowLayoutPolicy.neighborIndices(count: 10, currentIndex: 12, perSide: 3) == ([], []))
    }

    /// 没封面的歌常和一片没封面的专辑挨着：两侧跳过它们，接着往外取有封面的。
    @Test func neighboursSkipAlbumsWithoutArtwork() {
        // 3–7 没封面（同一个没刮削的文件夹），正在播第 5 张。
        let covered: Set<Int> = [0, 1, 2, 8, 9, 10, 11]
        let picks = AlbumFlowLayoutPolicy.neighborIndices(
            count: 12,
            currentIndex: 5,
            perSide: 2,
            hasArtwork: { covered.contains($0) }
        )
        #expect(picks.before == [2, 1])
        #expect(picks.after == [8, 9])
    }

    @Test func oneSideWithoutArtworkStaysEmptyInsteadOfShowingPlaceholders() {
        let picks = AlbumFlowLayoutPolicy.neighborIndices(
            count: 10,
            currentIndex: 4,
            perSide: 3,
            hasArtwork: { $0 > 4 }
        )
        #expect(picks.before.isEmpty)
        #expect(picks.after == [5, 6, 7])
    }

    @Test func libraryWithoutAnyArtworkFallsBackToShelfOrder() {
        let picks = AlbumFlowLayoutPolicy.neighborIndices(
            count: 10,
            currentIndex: 4,
            perSide: 2,
            hasArtwork: { _ in false }
        )
        #expect(picks.before == [3, 2])
        #expect(picks.after == [5, 6])
    }

    @Test func scanStopsAfterTheLimitInHugeUncoveredStretches() {
        var asked = 0
        let picks = AlbumFlowLayoutPolicy.neighborIndices(
            count: 100_000,
            currentIndex: 50_000,
            perSide: 6,
            hasArtwork: { index in
                asked += 1
                return index == 99_000
            }
        )
        #expect(asked <= 2 * AlbumFlowLayoutPolicy.maximumScanPerSide)
        #expect(picks.before.count == 6)
        #expect(picks.after.count == 6)
    }

    /// 没有专辑信息的歌：从按歌定下的位置劈开，两边照样有封面。
    @Test func songWithoutAnAlbumSplitsTheShelfAtItsAnchor() {
        let picks = AlbumFlowLayoutPolicy.neighborIndices(count: 10, currentIndex: nil, anchor: 4, perSide: 2)
        #expect(picks.before == [3, 2])
        #expect(picks.after == [4, 5])

        let pastEnd = AlbumFlowLayoutPolicy.neighborIndices(count: 3, currentIndex: nil, anchor: 7, perSide: 2)
        #expect(pastEnd.before == [1, 0])
        #expect(pastEnd.after == [2])
    }

    @Test func anchorIsStablePerSongAndInRange() {
        let first = AlbumFlowLayoutPolicy.anchor(seed: "song-a", count: 37)
        #expect(first == AlbumFlowLayoutPolicy.anchor(seed: "song-a", count: 37))
        #expect((0..<37).contains(first))
        #expect(AlbumFlowLayoutPolicy.anchor(seed: "x", count: 0) == 0)
        let spread = Set((0..<40).map { AlbumFlowLayoutPolicy.anchor(seed: "song-\($0)", count: 20) })
        #expect(spread.count > 8)
    }
}
