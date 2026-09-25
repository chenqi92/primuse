import Testing
@testable import PrimuseKit

struct CatalogWalkDriftTrackerTests {
    @Test func stillCatalogueFinishesCleanlyAtTheReportedEnd() {
        var tracker = CatalogWalkDriftTracker()
        tracker.observeTotal(5)
        let admittedAB = [tracker.admit("a"), tracker.admit("b")]
        #expect(admittedAB == [true, true])
        let firstDone = tracker.isFinished(offset: 2, rawCount: 2, pageSize: 2)
        #expect(!firstDone)
        tracker.observeTotal(5)
        let admittedCD = [tracker.admit("c"), tracker.admit("d")]
        #expect(admittedCD == [true, true])
        let secondDone = tracker.isFinished(offset: 4, rawCount: 2, pageSize: 2)
        #expect(!secondDone)
        tracker.observeTotal(5)
        let admitted1 = tracker.admit("e")
        #expect(admitted1)
        let lastDone = tracker.isFinished(offset: 5, rawCount: 1, pageSize: 2)
        #expect(lastDone)
        #expect(!tracker.driftObserved)
        #expect(tracker.admittedCount == 5)
    }

    @Test func rowAddedAheadOfTheCursorRepeatsARowAndKeepsWalking() {
        var tracker = CatalogWalkDriftTracker()
        tracker.observeTotal(4)
        _ = tracker.admit("a")
        _ = tracker.admit("b")
        let firstDone = tracker.isFinished(offset: 2, rawCount: 2, pageSize: 2)
        #expect(!firstDone)
        // "0" landed before "a": the window slid back by one.
        tracker.observeTotal(5)
        let repeated = tracker.admit("b")
        #expect(!repeated)
        let admitted2 = tracker.admit("c")
        #expect(admitted2)
        let secondDone = tracker.isFinished(offset: 4, rawCount: 2, pageSize: 2)
        #expect(!secondDone)
        tracker.observeTotal(5)
        let admitted3 = tracker.admit("d")
        #expect(admitted3)
        let lastDone = tracker.isFinished(offset: 5, rawCount: 1, pageSize: 2)
        #expect(lastDone)
        #expect(tracker.driftObserved)
    }

    @Test func catalogueThatShrankEndsOnAnEarlyEmptyPage() {
        var tracker = CatalogWalkDriftTracker()
        tracker.observeTotal(6)
        let done = tracker.isFinished(offset: 4, rawCount: 0, pageSize: 2)
        #expect(done)
        #expect(tracker.driftObserved)
    }

    @Test func shortPageBeforeTheEndIsDriftButStillStops() {
        var tracker = CatalogWalkDriftTracker()
        tracker.observeTotal(10)
        let done = tracker.isFinished(offset: 3, rawCount: 1, pageSize: 2)
        #expect(done)
        #expect(tracker.driftObserved)
    }

    @Test func serverWithoutTotalsStopsOnTheFirstShortPage() {
        var tracker = CatalogWalkDriftTracker()
        tracker.observeTotal(nil)
        let full = tracker.isFinished(offset: 2, rawCount: 2, pageSize: 2)
        #expect(!full)
        let short = tracker.isFinished(offset: 3, rawCount: 1, pageSize: 2)
        #expect(short)
        #expect(!tracker.driftObserved)
    }

    @Test func steppingPastTheReportedEndIsDrift() {
        var tracker = CatalogWalkDriftTracker()
        tracker.observeTotal(3)
        let done = tracker.isFinished(offset: 4, rawCount: 2, pageSize: 2)
        #expect(done)
        #expect(tracker.driftObserved)
    }
}
