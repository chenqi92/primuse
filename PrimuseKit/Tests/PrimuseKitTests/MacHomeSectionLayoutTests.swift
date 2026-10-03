import Foundation
import Testing
@testable import PrimuseKit

@Suite("Mac home section layout")
struct MacHomeSectionLayoutTests {
    @Test("默认顺序:统计卡片、处理管线、开始听、场景推荐在前")
    func defaultOrderLeadsWithOverviewPipelineStartListeningForYou() {
        let order = MacHomeSectionLayout.decodeOrder("")
        #expect(Array(order.prefix(4)) == [.overview, .pipeline, .startListening, .forYou])
        #expect(Set(order) == Set(MacHomeSection.allCases))
        #expect(order.count == MacHomeSection.allCases.count)
    }

    @Test("等于默认顺序时存空串")
    func defaultOrderEncodesAsEmpty() {
        #expect(MacHomeSectionLayout.encodeOrder(MacHomeSectionLayout.defaultOrder).isEmpty)
    }

    @Test("用户的顺序原样读回")
    func roundTripsCustomOrder() {
        var custom = MacHomeSectionLayout.defaultOrder
        custom.swapAt(0, 3)
        let raw = MacHomeSectionLayout.encodeOrder(custom)
        #expect(!raw.isEmpty)
        #expect(MacHomeSectionLayout.decodeOrder(raw) == custom)
    }

    @Test("认不出的丢掉、重复的只留第一个、缺的插回默认位置")
    func decodeToleratesUnknownDuplicateAndMissingSections() {
        let raw = #"["topArtists","removedSection","overview","topArtists","radio"]"#
        let order = MacHomeSectionLayout.decodeOrder(raw)
        #expect(order.count == MacHomeSection.allCases.count)
        #expect(order.first == .topArtists)
        // pipeline 在默认顺序里紧跟 overview,补回时也落在 overview 后面。
        let overviewIndex = order.firstIndex(of: .overview)
        let pipelineIndex = order.firstIndex(of: .pipeline)
        #expect(overviewIndex != nil && pipelineIndex == overviewIndex.map { $0 + 1 })
    }

    @Test("坏掉的存档退回默认顺序")
    func corruptArchiveFallsBackToDefault() {
        #expect(MacHomeSectionLayout.decodeOrder("not json") == MacHomeSectionLayout.defaultOrder)
    }

    @Test("往下拖一行")
    func reorderingMovesRowDown() {
        let order = MacHomeSectionLayout.defaultOrder
        let moved = MacHomeSectionLayout.reordering(order, fromOffsets: IndexSet(integer: 0), toOffset: 2)
        #expect(Array(moved.prefix(3)) == [.pipeline, .overview, .startListening])
    }

    @Test("往上拖一行")
    func reorderingMovesRowUp() {
        let order = MacHomeSectionLayout.defaultOrder
        let moved = MacHomeSectionLayout.reordering(order, fromOffsets: IndexSet(integer: 3), toOffset: 2)
        #expect(Array(moved.prefix(4)) == [.overview, .pipeline, .forYou, .startListening])
    }

    @Test("越界的拖动不改顺序")
    func reorderingIgnoresOutOfRangeSource() {
        let order = MacHomeSectionLayout.defaultOrder
        let moved = MacHomeSectionLayout.reordering(order, fromOffsets: IndexSet(integer: 99), toOffset: 0)
        #expect(moved == order)
    }
}
