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

    @Test("到头了跟手打折，进场方向和手指一致")
    func resistsAtTheEnds() {
        #expect(LibrarySectionPagingPolicy.interactiveOffset(translationX: -100, canMove: true) == -100)
        #expect(LibrarySectionPagingPolicy.interactiveOffset(translationX: -100, canMove: false) == -16)
        #expect(LibrarySectionPagingPolicy.interactiveOffset(translationX: .nan, canMove: true) == 0)
        #expect(LibrarySectionPagingPolicy.entrySide(translationX: -80) == 1)
        #expect(LibrarySectionPagingPolicy.entrySide(translationX: 80) == -1)
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
}
