import Foundation
import Testing
@testable import PrimuseKit

@Suite("Ting Reader favorites")
struct TingReaderFavoriteReconciliationTests {
    typealias Reconciliation = TingReaderFavoriteReconciliation

    private let localBooks = ["s1": "L1", "s2": "L2", "s3": "L3"]

    @Test("The first pass takes the union of both sides")
    func firstPassUnion() {
        let plan = Reconciliation.plan(
            serverFavorites: ["s1", "s9"],
            localBooks: localBooks,
            collectedLocalBookIDs: ["L2"],
            baseline: nil
        )
        #expect(plan.collectLocally == ["L1"])
        #expect(plan.favoriteOnServer == ["s2"])
        #expect(plan.uncollectLocally.isEmpty && plan.unfavoriteOnServer.isEmpty)
        // 本机还没有的书只记着,等它出现时收进来。
        #expect(plan.baseline.books == ["s1": "L1", "s2": "L2", "s9": ""])
    }

    @Test("Changes on either side since the last pass carry over to the other")
    func changesCarryOver() {
        let baseline = Reconciliation.Baseline(books: ["s1": "L1", "s2": "L2"])
        // 服务端取消了 s1、收藏了 s3;本机取消了 L2。
        let plan = Reconciliation.plan(
            serverFavorites: ["s2", "s3"],
            localBooks: localBooks,
            collectedLocalBookIDs: ["L1"],
            baseline: baseline
        )
        #expect(plan.uncollectLocally == ["L1"])
        #expect(plan.collectLocally == ["L3"])
        #expect(plan.unfavoriteOnServer == ["s2"])
        #expect(plan.favoriteOnServer.isEmpty)
        #expect(plan.baseline.books == ["s3": "L3"])
    }

    @Test("Agreed books stay put")
    func steadyState() {
        let baseline = Reconciliation.Baseline(books: ["s1": "L1"])
        let plan = Reconciliation.plan(
            serverFavorites: ["s1"],
            localBooks: localBooks,
            collectedLocalBookIDs: ["L1"],
            baseline: baseline
        )
        #expect(plan == Reconciliation.Plan(baseline: baseline))
    }

    @Test("A book that changed its shelf id is collected again rather than unfavorited")
    func regroupedBook() {
        let baseline = Reconciliation.Baseline(books: ["s1": "L1-old"])
        let plan = Reconciliation.plan(
            serverFavorites: ["s1"],
            localBooks: ["s1": "L1-new"],
            collectedLocalBookIDs: ["L1-old"],
            baseline: baseline
        )
        #expect(plan.collectLocally == ["L1-new"])
        #expect(plan.unfavoriteOnServer.isEmpty)
        #expect(plan.baseline.books == ["s1": "L1-new"])
    }

    @Test("A book favorited elsewhere is collected once it reaches the shelf")
    func bookArrivesLater() {
        let plan = Reconciliation.plan(
            serverFavorites: ["s1"],
            localBooks: ["s1": "L1"],
            collectedLocalBookIDs: [],
            baseline: Reconciliation.Baseline(books: ["s1": ""])
        )
        #expect(plan.collectLocally == ["L1"])
        #expect(plan.unfavoriteOnServer.isEmpty)
    }

    @Test("Server books merged into one shelf book are decided together")
    func mergedBooks() {
        let merged = ["s1": "L", "s2": "L"]
        // 本机收藏,服务端一本都没收藏:两本都推上去。
        let push = Reconciliation.plan(
            serverFavorites: [], localBooks: merged, collectedLocalBookIDs: ["L"], baseline: nil
        )
        #expect(push.favoriteOnServer == ["s1", "s2"])
        // 服务端取消了其中一本、另一本还收藏着:本机不取消,下一轮也不会把另一本取消掉。
        let baseline = Reconciliation.Baseline(books: ["s1": "L", "s2": "L"])
        let partial = Reconciliation.plan(
            serverFavorites: ["s2"], localBooks: merged, collectedLocalBookIDs: ["L"], baseline: baseline
        )
        #expect(partial.uncollectLocally.isEmpty)
        #expect(partial.unfavoriteOnServer.isEmpty)
        #expect(partial.baseline.books == ["s2": "L"])
        let next = Reconciliation.plan(
            serverFavorites: ["s2"], localBooks: merged, collectedLocalBookIDs: ["L"], baseline: partial.baseline
        )
        #expect(next == Reconciliation.Plan(baseline: partial.baseline))
        // 本机取消:服务端收藏着的那几本一起取消。
        let unpin = Reconciliation.plan(
            serverFavorites: ["s1", "s2"], localBooks: merged, collectedLocalBookIDs: [], baseline: baseline
        )
        #expect(unpin.unfavoriteOnServer == ["s1", "s2"])
    }

    @Test("Failed pushes are retried on the next pass")
    func failuresRetry() {
        let plan = Reconciliation.plan(
            serverFavorites: ["s1"],
            localBooks: localBooks,
            collectedLocalBookIDs: ["L2"],
            baseline: Reconciliation.Baseline(books: ["s1": "L1"])
        )
        #expect(plan.unfavoriteOnServer == ["s1"])
        #expect(plan.favoriteOnServer == ["s2"])
        let baseline = Reconciliation.baseline(
            plan.baseline,
            failedFavorites: ["s2"],
            failedUnfavorites: ["s1"],
            localBooks: localBooks
        )
        #expect(baseline.books == ["s1": "L1"])
        let retry = Reconciliation.plan(
            serverFavorites: ["s1"],
            localBooks: localBooks,
            collectedLocalBookIDs: ["L2"],
            baseline: baseline
        )
        #expect(retry.unfavoriteOnServer == ["s1"])
        #expect(retry.favoriteOnServer == ["s2"])
    }

    @Test("Books missing from the shelf are never touched")
    func missingBooksUntouched() {
        let plan = Reconciliation.plan(
            serverFavorites: ["s7"],
            localBooks: [:],
            collectedLocalBookIDs: ["L1"],
            baseline: Reconciliation.Baseline(books: ["s7": "L7", "s8": "L8"])
        )
        #expect(plan.collectLocally.isEmpty && plan.uncollectLocally.isEmpty)
        #expect(plan.favoriteOnServer.isEmpty && plan.unfavoriteOnServer.isEmpty)
        #expect(plan.baseline.books == ["s7": "L7"])
    }
}
