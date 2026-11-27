import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playlist manual order policy")
struct PlaylistManualOrderPolicyTests {
    private func key(_ sortOrder: Int, _ secondsAgo: TimeInterval) -> PlaylistManualOrderPolicy.OrderKey {
        PlaylistManualOrderPolicy.OrderKey(
            sortOrder: sortOrder,
            updatedAt: Date(timeIntervalSince1970: 1_000_000 - secondsAgo)
        )
    }

    @Test("Positions start at 1 so zero keeps meaning \"never ordered\"")
    func sortOrdersAreOneBased() {
        #expect(
            PlaylistManualOrderPolicy.sortOrders(forOrderedIDs: ["b", "a", "c"])
                == ["b": 1, "a": 2, "c": 3]
        )
        #expect(PlaylistManualOrderPolicy.sortOrders(forOrderedIDs: []).isEmpty)
        // 重复 id 只认第一次出现的位置，位次不会出现空洞。
        #expect(
            PlaylistManualOrderPolicy.sortOrders(forOrderedIDs: ["a", "b", "a"])
                == ["a": 1, "b": 2]
        )
    }

    @Test("Untouched libraries keep the old most-recently-updated order")
    func unorderedFallsBackToUpdatedAt() {
        let newer = key(PlaylistManualOrderPolicy.unordered, 10)
        let older = key(PlaylistManualOrderPolicy.unordered, 100)
        #expect(PlaylistManualOrderPolicy.isOrderedBefore(newer, older))
        #expect(!PlaylistManualOrderPolicy.isOrderedBefore(older, newer))
    }

    @Test("A manual position wins over the update time")
    func manualPositionBeatsUpdatedAt() {
        let positionedButStale = key(1, 10_000)
        let positionedAndFresh = key(2, 1)
        #expect(PlaylistManualOrderPolicy.isOrderedBefore(positionedButStale, positionedAndFresh))
    }

    @Test("A newly created playlist surfaces above the ordered ones")
    func newPlaylistsSortToTheTop() {
        let brandNew = key(PlaylistManualOrderPolicy.unordered, 0)
        let firstPositioned = key(1, 5)
        #expect(PlaylistManualOrderPolicy.isOrderedBefore(brandNew, firstPositioned))
    }

    @Test("Only a real change is written back")
    func orderChangedDetectsRealEdits() {
        let ordered = ["a": 1, "b": 2, "c": 3]
        #expect(!PlaylistManualOrderPolicy.orderChanged(
            currentOrderedIDs: ["a", "b", "c"],
            newOrderedIDs: ["a", "b", "c"],
            currentSortOrders: ordered
        ))
        #expect(PlaylistManualOrderPolicy.orderChanged(
            currentOrderedIDs: ["a", "b", "c"],
            newOrderedIDs: ["b", "a", "c"],
            currentSortOrders: ordered
        ))
        // 顺序看着没变，但还没有人排过序：要写一次位次才能把它钉住。
        #expect(PlaylistManualOrderPolicy.orderChanged(
            currentOrderedIDs: ["a", "b", "c"],
            newOrderedIDs: ["a", "b", "c"],
            currentSortOrders: [:]
        ))
    }
}
