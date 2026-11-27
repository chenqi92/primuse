import Foundation
import Testing
@testable import PrimuseKit

@Suite("Library section paging")
struct LibrarySectionPagingPolicyTests {
    private let sections = ["favorites", "songs", "genres"]

    @Test("相邻分类不循环，两端没有下一页")
    func neighborsStopAtTheEnds() {
        #expect(LibrarySectionPagingPolicy.neighbor(in: sections, of: "songs", forward: true) == "genres")
        #expect(LibrarySectionPagingPolicy.neighbor(in: sections, of: "songs", forward: false) == "favorites")
        #expect(LibrarySectionPagingPolicy.neighbor(in: sections, of: "genres", forward: true) == nil)
        #expect(LibrarySectionPagingPolicy.neighbor(in: sections, of: "favorites", forward: false) == nil)
        #expect(LibrarySectionPagingPolicy.neighbor(in: sections, of: "albums", forward: true) == nil)
    }

    @Test("往后翻的方向跟着语言方向")
    func forwardFollowsLayoutDirection() {
        #expect(LibrarySectionPagingPolicy.isForward(translationX: -40, isRightToLeft: false))
        #expect(!LibrarySectionPagingPolicy.isForward(translationX: 40, isRightToLeft: false))
        #expect(LibrarySectionPagingPolicy.isForward(translationX: 40, isRightToLeft: true))
    }

    @Test("到头了跟手打折")
    func resistsAtTheEnds() {
        #expect(LibrarySectionPagingPolicy.interactiveOffset(translationX: -100, canMove: true) == -100)
        #expect(LibrarySectionPagingPolicy.interactiveOffset(translationX: -100, canMove: false) == -16)
        #expect(LibrarySectionPagingPolicy.interactiveOffset(translationX: .nan, canMove: true) == 0)
    }

    @Test("相邻页贴在内容让出来的那一侧")
    func neighborFollowsTheRevealedSide() {
        #expect(LibrarySectionPagingPolicy.neighborSlot(contentOffset: -80) == 1)
        #expect(LibrarySectionPagingPolicy.neighborSlot(contentOffset: 80) == -1)
        #expect(LibrarySectionPagingPolicy.neighborSlot(contentOffset: 0) == nil)
        #expect(LibrarySectionPagingPolicy.neighborSlot(contentOffset: .nan) == nil)
    }

    @Test("落位时长随剩下的路变短")
    func settleDurationShrinksWithDistance() {
        let full = LibrarySectionPagingPolicy.settleDuration(remainingFraction: 1)
        let short = LibrarySectionPagingPolicy.settleDuration(remainingFraction: 0.2)
        #expect(full == LibrarySectionPagingPolicy.settleMaximumDuration)
        #expect(short < full)
        #expect(LibrarySectionPagingPolicy.settleDuration(remainingFraction: 0) == LibrarySectionPagingPolicy.settleMinimumDuration)
        #expect(LibrarySectionPagingPolicy.settleDuration(remainingFraction: -3) == full)
        #expect(LibrarySectionPagingPolicy.settleDuration(remainingFraction: .nan) == full)
    }

    @Test("落位起步接住手速，慢松手不停顿，快甩不冲过头")
    func settleCurveMatchesReleaseVelocity() {
        // 剩 300、0.3 秒：平均 1000/s，手速 2000/s 就是两倍起步。
        let matched = LibrarySectionPagingPolicy.settleCurve(velocity: -2000, remaining: -300, duration: 0.3)
        #expect(abs(matched.y1 / matched.x1 - 2) < 0.0001)
        #expect(matched.y2 == 1)
        let slow = LibrarySectionPagingPolicy.settleCurve(velocity: 0, remaining: -300, duration: 0.3)
        #expect(slow.y1 / slow.x1 == LibrarySectionPagingPolicy.settleMinimumLaunch)
        let backwards = LibrarySectionPagingPolicy.settleCurve(velocity: 900, remaining: -300, duration: 0.3)
        #expect(backwards.y1 / backwards.x1 == LibrarySectionPagingPolicy.settleMinimumLaunch)
        let flick = LibrarySectionPagingPolicy.settleCurve(velocity: -9000, remaining: -100, duration: 0.3)
        #expect(flick.y1 <= 1)
        let degenerate = LibrarySectionPagingPolicy.settleCurve(velocity: .infinity, remaining: 0, duration: 0.3)
        #expect(degenerate.y1 / degenerate.x1 == LibrarySectionPagingPolicy.settleMinimumLaunch)
    }

    @Test("导航栈换过来之前先摆翻到的那一页，别的换页听外面的")
    func shownPageBridgesTheCommit() {
        #expect(LibrarySectionPagingPolicy.shownPage(current: "songs", committedFrom: "songs", committedTo: "genres") == "genres")
        #expect(LibrarySectionPagingPolicy.shownPage(current: "genres", committedFrom: "songs", committedTo: "genres") == "genres")
        #expect(LibrarySectionPagingPolicy.shownPage(current: "favorites", committedFrom: "songs", committedTo: "genres") == "favorites")
        #expect(LibrarySectionPagingPolicy.shownPage(current: "songs", committedFrom: nil, committedTo: nil) == "songs")
    }

    @Test("起手贴着左右边缘不接：左边留给系统返回，右边留给字母索引")
    func excludesEdges() {
        #expect(LibrarySectionPagingPolicy.startsInEdgeExclusion(startX: 10, containerWidth: 390, isRightToLeft: false))
        #expect(LibrarySectionPagingPolicy.startsInEdgeExclusion(startX: 360, containerWidth: 390, isRightToLeft: false))
        #expect(!LibrarySectionPagingPolicy.startsInEdgeExclusion(startX: 200, containerWidth: 390, isRightToLeft: false))
        #expect(LibrarySectionPagingPolicy.startsInEdgeExclusion(startX: 380, containerWidth: 390, isRightToLeft: true))
        #expect(LibrarySectionPagingPolicy.startsInEdgeExclusion(startX: 30, containerWidth: 390, isRightToLeft: true))
        #expect(!LibrarySectionPagingPolicy.startsInEdgeExclusion(startX: 200, containerWidth: 390, isRightToLeft: true))
        #expect(LibrarySectionPagingPolicy.startsInEdgeExclusion(startX: 200, containerWidth: 0, isRightToLeft: false))
    }

    @Test("没有字母索引的页后沿也能起手，前沿照样让给系统返回")
    func trailingEdgeOnlyForAlphabetIndex() {
        #expect(!LibrarySectionPagingPolicy.startsInEdgeExclusion(
            startX: 360, containerWidth: 390, isRightToLeft: false, excludesTrailingEdge: false))
        #expect(!LibrarySectionPagingPolicy.startsInEdgeExclusion(
            startX: 30, containerWidth: 390, isRightToLeft: true, excludesTrailingEdge: false))
        #expect(LibrarySectionPagingPolicy.startsInEdgeExclusion(
            startX: 10, containerWidth: 390, isRightToLeft: false, excludesTrailingEdge: false))
        #expect(LibrarySectionPagingPolicy.startsInEdgeExclusion(
            startX: 380, containerWidth: 390, isRightToLeft: true, excludesTrailingEdge: false))
    }
}

@Suite("Minimal page switch")
struct MinimalPageSwitchPolicyTests {
    @Test("点排在后面的去处从后沿那一侧进来，跟着语言方向")
    func entrySideFollowsOrderAndLayoutDirection() {
        #expect(MinimalPageSwitchPolicy.entrySide(fromIndex: 0, toIndex: 2, isRightToLeft: false) == 1)
        #expect(MinimalPageSwitchPolicy.entrySide(fromIndex: 2, toIndex: 1, isRightToLeft: false) == -1)
        #expect(MinimalPageSwitchPolicy.entrySide(fromIndex: 0, toIndex: 2, isRightToLeft: true) == -1)
        #expect(MinimalPageSwitchPolicy.entrySide(fromIndex: 2, toIndex: 1, isRightToLeft: true) == 1)
    }

    @Test("没换格、排不上号时不推")
    func noEntryWithoutDirection() {
        #expect(MinimalPageSwitchPolicy.entrySide(fromIndex: 1, toIndex: 1, isRightToLeft: false) == nil)
        #expect(MinimalPageSwitchPolicy.entrySide(fromIndex: nil, toIndex: 1, isRightToLeft: false) == nil)
        #expect(MinimalPageSwitchPolicy.entrySide(fromIndex: 0, toIndex: nil, isRightToLeft: true) == nil)
    }

    @Test("只认刚发生的换页")
    func freshnessWindow() {
        #expect(MinimalPageSwitchPolicy.isFresh(elapsed: 0))
        #expect(MinimalPageSwitchPolicy.isFresh(elapsed: 0.3))
        #expect(!MinimalPageSwitchPolicy.isFresh(elapsed: MinimalPageSwitchPolicy.freshness))
        #expect(!MinimalPageSwitchPolicy.isFresh(elapsed: -0.1))
        #expect(!MinimalPageSwitchPolicy.isFresh(elapsed: .nan))
        #expect(!MinimalPageSwitchPolicy.isFresh(elapsed: .infinity))
    }
}
