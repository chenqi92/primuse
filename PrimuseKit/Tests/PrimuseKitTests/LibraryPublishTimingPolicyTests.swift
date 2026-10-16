import Foundation
import Testing
@testable import PrimuseKit

@Suite("Library publish timing")
struct LibraryPublishTimingPolicyTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func activity(scrolling: Bool, endedSecondsAgo: TimeInterval?) -> LibraryPublishTimingPolicy.ScrollActivity {
        .init(isScrolling: scrolling, lastActivityAt: endedSecondsAgo.map { now.addingTimeInterval(-$0) })
    }

    @Test("Never scrolled and long-stopped scrolling are settled")
    func settledStates() {
        #expect(LibraryPublishTimingPolicy.isSettled(.idle, now: now))
        #expect(LibraryPublishTimingPolicy.isSettled(activity(scrolling: false, endedSecondsAgo: 1), now: now))
        #expect(LibraryPublishTimingPolicy.isSettled(activity(scrolling: false, endedSecondsAgo: 30), now: now))
    }

    @Test("Scrolling, or stopping less than a second ago, is not settled")
    func unsettledStates() {
        #expect(!LibraryPublishTimingPolicy.isSettled(activity(scrolling: true, endedSecondsAgo: 0), now: now))
        #expect(!LibraryPublishTimingPolicy.isSettled(activity(scrolling: true, endedSecondsAgo: nil), now: now))
        #expect(!LibraryPublishTimingPolicy.isSettled(activity(scrolling: false, endedSecondsAgo: 0.4), now: now))
    }

    @Test("A due publish proceeds when nobody is scrolling")
    func proceedsWhenIdle() {
        let gate = LibraryPublishTimingPolicy.scrollGate(
            activity: .idle, holdingSince: nil, pendingCount: 64, batchSize: 64, now: now
        )
        #expect(gate == .proceed)
    }

    @Test("A due publish is held while scrolling and right after it stops")
    func holdsWhileScrolling() {
        let scrolling = LibraryPublishTimingPolicy.scrollGate(
            activity: activity(scrolling: true, endedSecondsAgo: nil),
            holdingSince: nil, pendingCount: 64, batchSize: 64, now: now
        )
        #expect(scrolling == .hold)
        let justStopped = LibraryPublishTimingPolicy.scrollGate(
            activity: activity(scrolling: false, endedSecondsAgo: 0.5),
            holdingSince: now.addingTimeInterval(-3), pendingCount: 90, batchSize: 64, now: now
        )
        #expect(justStopped == .hold)
    }

    @Test("Held results go out once scrolling has settled")
    func proceedsAfterSettle() {
        let gate = LibraryPublishTimingPolicy.scrollGate(
            activity: activity(scrolling: false, endedSecondsAgo: 1.2),
            holdingSince: now.addingTimeInterval(-6), pendingCount: 120, batchSize: 64, now: now
        )
        #expect(gate == .proceed)
    }

    @Test("Continuous scrolling cannot hold results forever")
    func holdIsBoundedByTime() {
        let early = LibraryPublishTimingPolicy.scrollGate(
            activity: activity(scrolling: true, endedSecondsAgo: 0),
            holdingSince: now.addingTimeInterval(-14), pendingCount: 64, batchSize: 64, now: now
        )
        #expect(early == .hold)
        let capped = LibraryPublishTimingPolicy.scrollGate(
            activity: activity(scrolling: true, endedSecondsAgo: 0),
            holdingSince: now.addingTimeInterval(-15), pendingCount: 64, batchSize: 64, now: now
        )
        #expect(capped == .proceedDespiteScrolling)
    }

    @Test("Continuous scrolling cannot pile up more than eight batches")
    func holdIsBoundedByCount() {
        let below = LibraryPublishTimingPolicy.scrollGate(
            activity: activity(scrolling: true, endedSecondsAgo: 0),
            holdingSince: now, pendingCount: 511, batchSize: 64, now: now
        )
        #expect(below == .hold)
        let capped = LibraryPublishTimingPolicy.scrollGate(
            activity: activity(scrolling: true, endedSecondsAgo: 0),
            holdingSince: now, pendingCount: 512, batchSize: 64, now: now
        )
        #expect(capped == .proceedDespiteScrolling)
    }

    @Test("Libraries under ten thousand songs keep the old cadence")
    func smallLibrariesHaveNoSpacing() {
        #expect(LibraryPublishTimingPolicy.minimumBackfillPublishSpacing(librarySongCount: 0) == 0)
        #expect(LibraryPublishTimingPolicy.minimumBackfillPublishSpacing(librarySongCount: 9_999) == 0)
    }

    @Test("Large libraries space publishes by one second per thousand songs, capped at a minute")
    func largeLibrarySpacing() {
        #expect(LibraryPublishTimingPolicy.minimumBackfillPublishSpacing(librarySongCount: 10_000) == 10)
        #expect(LibraryPublishTimingPolicy.minimumBackfillPublishSpacing(librarySongCount: 43_000) == 43)
        #expect(LibraryPublishTimingPolicy.minimumBackfillPublishSpacing(librarySongCount: 60_000) == 60)
        #expect(LibraryPublishTimingPolicy.minimumBackfillPublishSpacing(librarySongCount: 250_000) == 60)
    }

    @Test("A small library publishes on a full batch exactly as before")
    func smallLibraryBatchGate() {
        let due = LibraryPublishTimingPolicy.isBackfillPublishDue(
            pendingCount: 64, batchSize: 64, flushInterval: 30, sinceLastPublish: 3, librarySongCount: 2_000
        )
        #expect(due)
        let notYet = LibraryPublishTimingPolicy.isBackfillPublishDue(
            pendingCount: 63, batchSize: 64, flushInterval: 30, sinceLastPublish: 3, librarySongCount: 2_000
        )
        #expect(!notYet)
        let byTime = LibraryPublishTimingPolicy.isBackfillPublishDue(
            pendingCount: 5, batchSize: 64, flushInterval: 30, sinceLastPublish: 30, librarySongCount: 2_000
        )
        #expect(byTime)
    }

    @Test("A large library waits out its spacing even with a full batch")
    func largeLibraryBatchWaitsForSpacing() {
        let early = LibraryPublishTimingPolicy.isBackfillPublishDue(
            pendingCount: 400, batchSize: 64, flushInterval: 20, sinceLastPublish: 21, librarySongCount: 43_000
        )
        #expect(!early)
        let spaced = LibraryPublishTimingPolicy.isBackfillPublishDue(
            pendingCount: 130, batchSize: 64, flushInterval: 30, sinceLastPublish: 43, librarySongCount: 43_000
        )
        #expect(spaced)
    }

    @Test("Spacing never makes a not-yet-due publish due")
    func spacingOnlyDelays() {
        let due = LibraryPublishTimingPolicy.isBackfillPublishDue(
            pendingCount: 10, batchSize: 64, flushInterval: 60, sinceLastPublish: 50, librarySongCount: 43_000
        )
        #expect(!due)
    }
}
