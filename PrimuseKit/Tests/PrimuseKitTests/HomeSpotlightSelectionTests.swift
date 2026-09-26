import Foundation
import Testing
@testable import PrimuseKit

@Suite("Home spotlight selection")
struct HomeSpotlightSelectionTests {
    private struct Item: Equatable {
        let id: String
        let name: String
        let played: Date?
    }

    private let items = [
        Item(id: "a", name: "Charlie", played: nil),
        Item(id: "b", name: "alpha", played: Date(timeIntervalSince1970: 100)),
        Item(id: "c", name: "Bravo", played: Date(timeIntervalSince1970: 300)),
        Item(id: "d", name: "Delta", played: nil),
    ]

    private func resolve(_ selection: HomeSpotlightSelection, limit: Int = 10) -> [String] {
        selection.resolve(items, limit: limit, id: \.id, name: \.name, lastListenedAt: \.played).map(\.id)
    }

    @Test("没挑过时按最近收听,没听过的按原顺序补在后面")
    func automaticRecent() {
        #expect(resolve(HomeSpotlightSelection()) == ["c", "b", "a", "d"])
        #expect(resolve(HomeSpotlightSelection(), limit: 3) == ["c", "b", "a"])
    }

    @Test("自定义顺序在自动时就是资料库顺序")
    func automaticCustomKeepsLibraryOrder() {
        #expect(resolve(HomeSpotlightSelection(order: .custom)) == ["a", "b", "c", "d"])
    }

    @Test("按名称不分大小写")
    func sortsByName() {
        #expect(resolve(HomeSpotlightSelection(order: .name)) == ["b", "c", "a", "d"])
    }

    @Test("挑过之后只放挑中的,自定义顺序照挑选顺序")
    func pinnedOnly() {
        let selection = HomeSpotlightSelection(order: .custom, pinnedIDs: ["d", "missing", "b"])
        #expect(resolve(selection) == ["d", "b"])
        var recent = selection
        recent.order = .recent
        #expect(resolve(recent) == ["b", "d"])
    }

    @Test("再点一次是取消,拖动与数组 move 语义一致")
    func togglingAndMoving() {
        var selection = HomeSpotlightSelection()
        selection.togglePin("a")
        selection.togglePin("b")
        selection.togglePin("c")
        #expect(selection.pinnedIDs == ["a", "b", "c"])
        selection.togglePin("b")
        #expect(selection.pinnedIDs == ["a", "c"])
        selection.togglePin("b")
        selection.movePinned(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(selection.pinnedIDs == ["c", "b", "a"])
        selection.movePinned(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(selection.pinnedIDs == ["a", "c", "b"])
        selection.prune(keeping: ["a", "b"])
        #expect(selection.pinnedIDs == ["a", "b"])
    }

    @Test("存档往返,坏值退回默认,重复 id 去掉")
    func codableRoundTrip() {
        let selection = HomeSpotlightSelection(order: .name, pinnedIDs: ["x", "y"])
        #expect(HomeSpotlightSelection.decode(selection.encoded()) == selection)
        #expect(HomeSpotlightSelection.decode("") == HomeSpotlightSelection())
        let legacy = HomeSpotlightSelection.decode(#"{"order":"removed","pinnedIDs":["x","x","y"]}"#)
        #expect(legacy.order == .recent)
        #expect(legacy.pinnedIDs == ["x", "y"])
    }
}
