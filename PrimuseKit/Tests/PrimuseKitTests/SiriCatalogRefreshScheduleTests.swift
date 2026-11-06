import Testing
@testable import PrimuseKit

struct SiriCatalogRefreshScheduleTests {
    @Test func firstCatalogArrivesPromptlyEvenWithContinuousArtworkChanges() throws {
        var schedule = SiriCatalogRefreshSchedule()
        #expect(schedule.request(at: 0) == 0.4)
        let coalescedDelay = schedule.request(at: 0.3)
        #expect(abs(try #require(coalescedDelay) - 0.1) < 0.000_001)
        #expect(schedule.request(at: 0.4) == 0)
        #expect(schedule.begin(at: 0.4) == false)
        #expect(schedule.complete(at: 0.5, succeeded: true) == nil)
        #expect(schedule.request(at: 1) == 29.4)
    }

    @Test func importBatchesShareOneDeadlineAndPublishTheFinalBatch() throws {
        var schedule = SiriCatalogRefreshSchedule()
        _ = schedule.request(at: 0)
        _ = schedule.begin(at: 0.4)
        _ = schedule.complete(at: 0.5, succeeded: true)
        let batches = [6.0, 13, 20, 27]
        for batch in batches {
            let pendingDelay = schedule.request(at: batch)
            let delay = try #require(pendingDelay)
            #expect(abs(batch + delay - 30.4) < 0.000_001)
        }
        #expect(schedule.begin(at: 30.4) == false)
        #expect(schedule.complete(at: 31, succeeded: true) == nil)
        let finalDelay = schedule.request(at: 36)
        #expect(abs(try #require(finalDelay) - 24.4) < 0.000_001)
        #expect(schedule.begin(at: 60.4) == false)
        #expect(schedule.complete(at: 61, succeeded: true) == nil)
    }

    @Test func notificationsDuringPreparationDoNotCancelItAndScheduleTheTail() {
        var schedule = SiriCatalogRefreshSchedule()
        _ = schedule.request(at: 0)
        #expect(schedule.begin(at: 0.4) == false)
        for event in [1.0, 8, 16, 24, 32] {
            #expect(schedule.request(at: event) == nil)
            #expect(schedule.begin(at: event) == nil)
        }
        // The first run completed despite continuous changes. The latest
        // state is prepared next even if no further notification arrives.
        #expect(schedule.complete(at: 33, succeeded: true) == 0)
        #expect(schedule.begin(at: 33) == false)
        #expect(schedule.complete(at: 34, succeeded: true) == nil)
    }

    @Test func forceDuringPreparationIsDeliveredByTheTail() {
        var schedule = SiriCatalogRefreshSchedule()
        _ = schedule.request(at: 0)
        #expect(schedule.begin(at: 0.4) == false)
        #expect(schedule.request(at: 1, force: true) == nil)
        #expect(schedule.request(at: 2) == nil)
        #expect(schedule.complete(at: 3, succeeded: true) == 0)
        #expect(schedule.begin(at: 3) == true)
        #expect(schedule.complete(at: 4, succeeded: true) == nil)
    }

    @Test func permissionGrantBypassesWaitingCooldown() {
        var schedule = SiriCatalogRefreshSchedule()
        _ = schedule.request(at: 9.6)
        _ = schedule.begin(at: 10)
        _ = schedule.complete(at: 10.5, succeeded: true)
        #expect(schedule.request(at: 11) == 29)
        #expect(schedule.request(at: 12, force: true) == 0)
        #expect(schedule.request(at: 12.1) == 0)
        #expect(schedule.begin(at: 12.1) == true)
    }

    @Test func failedForcedPreparationRetriesOnceWithoutAnIdleLoop() {
        var schedule = SiriCatalogRefreshSchedule()
        #expect(schedule.request(at: 0, force: true) == 0)
        #expect(schedule.begin(at: 0) == true)
        #expect(schedule.complete(at: 1, succeeded: false) == 29)
        #expect(schedule.begin(at: 30) == true)
        #expect(schedule.complete(at: 31, succeeded: false) == nil)
        // A later real event can retry, retaining the unfulfilled force.
        #expect(schedule.request(at: 35) == 25)
        #expect(schedule.begin(at: 60) == true)
        #expect(schedule.complete(at: 61, succeeded: true) == nil)
        #expect(schedule.request(at: 65) == 25)
        #expect(schedule.begin(at: 90) == false)
    }

    @Test func failureKeepsANewerRequestAndItsRetryBudget() {
        var schedule = SiriCatalogRefreshSchedule()
        _ = schedule.request(at: 0)
        _ = schedule.begin(at: 0.4)
        #expect(schedule.request(at: 2, force: true) == nil)
        #expect(schedule.complete(at: 3, succeeded: false) == 0)
        #expect(schedule.begin(at: 3) == true)
        #expect(schedule.complete(at: 4, succeeded: false) == 29)
        #expect(schedule.begin(at: 33) == true)
        #expect(schedule.complete(at: 34, succeeded: true) == nil)
    }

    @Test func expiredPendingDeadlineRunsWithoutAnotherDebounce() {
        var schedule = SiriCatalogRefreshSchedule()
        _ = schedule.request(at: 0, force: true)
        _ = schedule.begin(at: 0)
        _ = schedule.complete(at: 1, succeeded: true)
        #expect(schedule.request(at: 5) == 25)
        #expect(schedule.request(at: 31) == 0)
    }
}
