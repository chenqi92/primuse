import Testing
@testable import PrimuseKit

/// MainActor-isolated counter, so waiter tasks can record progress.
@MainActor
private final class ResumeLog {
    private(set) var count = 0
    func record() { count += 1 }
}

@Suite("Playback schedule settlement")
@MainActor
struct PlaybackScheduleSettlementTests {
    @Test("A waiter resumes when the schedule settles")
    func waitResumesAfterSettle() async {
        let settlement = PlaybackScheduleSettlement()
        let log = ResumeLog()

        let waiter = Task { @MainActor in
            await settlement.waitUntilSettled()
            log.record()
        }
        await Task.yield()

        #expect(settlement.isSettled == false)
        #expect(log.count == 0)
        settlement.settle()
        await waiter.value

        #expect(log.count == 1)
        #expect(settlement.isSettled)
    }

    @Test("Settling before waiting returns immediately")
    func settleBeforeWait() async {
        let settlement = PlaybackScheduleSettlement()
        settlement.settle()
        // Idempotent: a second signal must not resume anything twice.
        settlement.settle()

        await settlement.waitUntilSettled()

        #expect(settlement.isSettled)
    }

    @Test("Every waiter resumes on a single settle")
    func resumesEveryWaiter() async {
        let settlement = PlaybackScheduleSettlement()
        let log = ResumeLog()

        let waiters = (0..<4).map { _ in
            Task { @MainActor in
                await settlement.waitUntilSettled()
                log.record()
            }
        }
        await Task.yield()

        settlement.settle()
        for waiter in waiters {
            await waiter.value
        }

        #expect(log.count == 4)
    }

    @Test("A cancelled waiter returns without a settle, and a later settle is harmless")
    func cancelledWaiterReturns() async {
        let settlement = PlaybackScheduleSettlement()
        let log = ResumeLog()

        let waiter = Task { @MainActor in
            await settlement.waitUntilSettled()
            log.record()
        }
        // Let the waiter register before cancelling it.
        await Task.yield()
        waiter.cancel()
        await waiter.value

        #expect(log.count == 1)
        #expect(settlement.isSettled == false)

        settlement.settle()
        #expect(settlement.isSettled)
        await settlement.waitUntilSettled()
    }
}
