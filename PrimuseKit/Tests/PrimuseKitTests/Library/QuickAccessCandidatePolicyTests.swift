import Foundation
import Testing
@testable import PrimuseKit

@Suite("Quick access candidate policy")
struct QuickAccessCandidatePolicyTests {
    private struct Item: Equatable {
        let id: String
        let title: String
        let subtitle: String?
    }

    private let items = [
        Item(id: "b", title: "Blue Train", subtitle: "John Coltrane"),
        Item(id: "a", title: "Kind of Blue", subtitle: "Miles Davis"),
        Item(id: "c", title: "Giant Steps", subtitle: nil),
    ]

    private func filtered(pinned: Set<String>, query: String) -> [Item] {
        QuickAccessCandidatePolicy.filtered(
            items,
            id: \.id,
            pinnedIDs: pinned,
            query: query,
            searchFields: { [$0.title, $0.subtitle] }
        )
    }

    @Test("The incoming order is preserved, never re-sorted")
    func keepsSourceOrder() {
        // 专辑/艺术家来自资料库已排好的集合，歌单来自用户排定的顺序：
        // 这里再排一次既慢又会打乱用户的歌单顺序。
        #expect(filtered(pinned: [], query: "").map(\.id) == ["b", "a", "c"])
    }

    @Test("Pinned items drop out of the candidate list")
    func pinnedItemsAreExcluded() {
        #expect(filtered(pinned: ["a"], query: "").map(\.id) == ["b", "c"])
        #expect(filtered(pinned: ["a", "b", "c"], query: "").isEmpty)
    }

    @Test("Any field can match, and a blank query matches everything")
    func queryMatchesAnyField() {
        #expect(filtered(pinned: [], query: "blue").map(\.id) == ["b", "a"])
        #expect(filtered(pinned: [], query: "miles").map(\.id) == ["a"])
        #expect(filtered(pinned: [], query: "   ").map(\.id) == ["b", "a", "c"])
        #expect(filtered(pinned: [], query: "nothing").isEmpty)
        // 已固定的项即使命中搜索词也不该回到候选列表里。
        #expect(filtered(pinned: ["a"], query: "blue").map(\.id) == ["b"])
    }

    @Test("Matching ignores case and surrounding whitespace")
    func matchesIgnoresCaseAndPadding() {
        #expect(QuickAccessCandidatePolicy.matches(query: "", fields: ["anything"]))
        #expect(QuickAccessCandidatePolicy.matches(query: "  ", fields: [nil]))
        #expect(QuickAccessCandidatePolicy.matches(query: " TRAIN ", fields: ["Blue Train"]))
        #expect(!QuickAccessCandidatePolicy.matches(query: "train", fields: [nil, "Giant Steps"]))
    }
}
