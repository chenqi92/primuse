import Foundation
import Testing
@testable import PrimuseKit

@Suite("Deferred retry membership revision")
struct DeferredRetryMembershipTests {
    @Test("Inserting a new ID advances the revision, re-inserting does not")
    func insertAdvancesOnlyOnChange() {
        var membership = DeferredRetryMembership()

        let didInsert = membership.insert("a")
        #expect(didInsert)
        let afterInsert = membership.revision
        #expect(afterInsert != 0)
        #expect(membership.contains("a"))

        let didReinsert = membership.insert("a")
        #expect(!didReinsert)
        #expect(membership.revision == afterInsert)
    }

    @Test("Removing a missing ID leaves the revision alone")
    func removeAdvancesOnlyOnChange() {
        var membership = DeferredRetryMembership(songIDs: ["a"], revision: 4)

        let didRemoveMissing = membership.remove("b")
        #expect(!didRemoveMissing)
        #expect(membership.revision == 4)

        let didRemovePresent = membership.remove("a")
        #expect(didRemovePresent)
        #expect(membership.revision == 5)
        #expect(membership.isEmpty)
    }

    @Test("Bulk operations that change nothing keep the revision stable")
    func bulkOperationsAdvanceOnlyOnChange() {
        var membership = DeferredRetryMembership(songIDs: ["a", "b"], revision: 9)

        let didUnionExisting = membership.formUnion(["a", "b"])
        #expect(!didUnionExisting)
        let didSubtractMissing = membership.subtract(["c"])
        #expect(!didSubtractMissing)
        let didReplaceWithEqual = membership.replace(with: ["b", "a"])
        #expect(!didReplaceWithEqual)
        #expect(membership.revision == 9)

        let didUnionNew = membership.formUnion(["c"])
        #expect(didUnionNew)
        #expect(membership.count == 3)
        let didSubtractPresent = membership.subtract(["a", "c"])
        #expect(didSubtractPresent)
        #expect(membership.songIDs == ["b"])
        #expect(membership.revision == 11)

        let didRemoveAll = membership.removeAll()
        #expect(didRemoveAll)
        let didRemoveAllAgain = membership.removeAll()
        #expect(!didRemoveAllAgain)
        #expect(membership.revision == 12)
    }

    @Test("The revision wraps instead of overflowing")
    func revisionWraps() {
        var membership = DeferredRetryMembership(songIDs: [], revision: .max)

        let didInsert = membership.insert("a")
        #expect(didInsert)
        #expect(membership.revision == 1)
    }
}
