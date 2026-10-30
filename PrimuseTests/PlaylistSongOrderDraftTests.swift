import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class PlaylistSongOrderDraftTests: XCTestCase {
    func testUnchangedDraftDoesNotReplaceTheStoredOrder() {
        var draft = PlaylistSongOrderDraft(["c", "a", "b"])
        let available: Set<String> = ["a", "b", "c"]
        XCTAssertNil(draft.changedOrder(availableIDs: available))

        draft.move(fromOffsets: IndexSet(integer: 0), toOffset: 3, availableIDs: available)
        draft.move(fromOffsets: IndexSet(integer: 2), toOffset: 0, availableIDs: available)
        XCTAssertNil(draft.changedOrder(availableIDs: available))
    }

    func testFilteredReorderKeepsUnlistedMembersAndPendingEntries() throws {
        var draft = PlaylistSongOrderDraft(["a", "c"])
        let available: Set<String> = ["a", "b", "c", "pending"]
        draft.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, availableIDs: available)

        let order = try XCTUnwrap(draft.changedOrder(availableIDs: available))
        XCTAssertEqual(
            PlaylistMemberOrderPolicy.reordered(["a", "hidden", "b", "pending", "c"], listedOrder: order),
            ["c", "hidden", "b", "pending", "a"]
        )
    }

    func testVisiblePendingEntriesCanMoveWithoutLosingHiddenMembers() throws {
        var draft = PlaylistSongOrderDraft(["a", "pending", "b"])
        let available: Set<String> = ["a", "pending", "b"]
        draft.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, availableIDs: available)

        let order = try XCTUnwrap(draft.changedOrder(availableIDs: available))
        XCTAssertEqual(
            PlaylistMemberOrderPolicy.reordered(["a", "hidden", "pending", "b"], listedOrder: order),
            ["pending", "hidden", "a", "b"]
        )
    }

    func testConcurrentRemovalDoesNotResurrectADeletedMember() {
        var draft = PlaylistSongOrderDraft(["a", "b", "c"])
        draft.move(fromOffsets: IndexSet(integer: 2), toOffset: 0, availableIDs: ["a", "b", "c"])
        XCTAssertEqual(draft.changedOrder(availableIDs: ["a", "c"]), ["c", "a"])
        XCTAssertNil(PlaylistSongOrderDraft(["a", "b", "c"]).changedOrder(availableIDs: ["a", "c"]))
    }

    func testDragUsesTheRowsStillVisibleAfterConcurrentRemoval() {
        var draft = PlaylistSongOrderDraft(["a", "b", "c"])
        draft.move(fromOffsets: IndexSet(integer: 1), toOffset: 0, availableIDs: ["a", "c"])
        XCTAssertEqual(draft.changedOrder(availableIDs: ["a", "c"]), ["c", "a"])
    }

    func testConcurrentAdditionKeepsItsOwnPosition() throws {
        var draft = PlaylistSongOrderDraft(["a", "b", "c"])
        draft.move(fromOffsets: IndexSet(integer: 2), toOffset: 0, availableIDs: ["a", "b", "c", "new"])
        let order = try XCTUnwrap(draft.changedOrder(availableIDs: ["a", "b", "c", "new"]))
        XCTAssertEqual(
            PlaylistMemberOrderPolicy.reordered(["a", "new", "b", "c"], listedOrder: order),
            ["c", "new", "a", "b"]
        )
    }

    func testInvalidDragOffsetsLeaveTheOrderUnchanged() {
        var draft = PlaylistSongOrderDraft(["a", "b"])
        draft.move(fromOffsets: IndexSet(integer: 2), toOffset: 0, availableIDs: ["a", "b"])
        draft.move(fromOffsets: IndexSet(integer: 1), toOffset: 3, availableIDs: ["a", "b"])
        XCTAssertNil(draft.changedOrder(availableIDs: ["a", "b"]))
    }
}
