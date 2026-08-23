import Foundation
import Testing
@testable import PrimuseKit

struct AutomaticMaintenanceCadencePolicyTests {
    @Test func firstRunAndElapsedIntervalAreDue() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(AutomaticMaintenanceCadencePolicy.isDue(
            lastCompletedAt: nil,
            now: now,
            minimumInterval: 3_600
        ))
        #expect(AutomaticMaintenanceCadencePolicy.isDue(
            lastCompletedAt: now.addingTimeInterval(-3_600),
            now: now,
            minimumInterval: 3_600
        ))
    }

    @Test func recentCompletionAndSmallClockRollbackStayParked() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(!AutomaticMaintenanceCadencePolicy.isDue(
            lastCompletedAt: now.addingTimeInterval(-3_599),
            now: now,
            minimumInterval: 3_600
        ))
        #expect(!AutomaticMaintenanceCadencePolicy.isDue(
            lastCompletedAt: now.addingTimeInterval(60),
            now: now,
            minimumInterval: 3_600
        ))
    }

    @Test func largeClockRollbackCannotParkMaintenanceForever() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(AutomaticMaintenanceCadencePolicy.isDue(
            lastCompletedAt: now.addingTimeInterval(3_600),
            now: now,
            minimumInterval: 3_600
        ))
    }
}
