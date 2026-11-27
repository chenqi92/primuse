import Foundation
import Testing
@testable import PrimuseKit

@Suite("Listener restart policy")
struct ListenerRestartPolicyTests {
    // MARK: Backoff

    @Test("The unjittered schedule grows to the cap and then gives up")
    func backoffSequenceWithNeutralJitter() {
        let backoff = ListenerRestartBackoff()
        let expected: [TimeInterval] = [0.5, 1, 2, 4, 8, 16, 30, 30]
        for (attempt, want) in expected.enumerated() {
            let got = backoff.delay(forAttempt: attempt, jitterUnit: 0.5)
            #expect(got == want, "attempt \(attempt) expected \(want), got \(String(describing: got))")
        }
        #expect(backoff.delay(forAttempt: 8, jitterUnit: 0.5) == nil)
        #expect(backoff.delay(forAttempt: 99, jitterUnit: 0.5) == nil)
    }

    @Test("Jitter units span exactly the configured fraction and clamp")
    func backoffJitterBounds() {
        let backoff = ListenerRestartBackoff()
        #expect(backoff.delay(forAttempt: 0, jitterUnit: 0) == 0.4)
        #expect(backoff.delay(forAttempt: 0, jitterUnit: 1) == 0.6)
        #expect(backoff.delay(forAttempt: 3, jitterUnit: 0) == 3.2)
        #expect(backoff.delay(forAttempt: 3, jitterUnit: 1) == 4.8)
        // Out-of-range units clamp instead of producing a negative delay.
        #expect(backoff.delay(forAttempt: 0, jitterUnit: -5) == 0.4)
        #expect(backoff.delay(forAttempt: 0, jitterUnit: 5) == 0.6)
    }

    // MARK: Start / ready

    @Test("Start hands out a fresh generation and begins listening")
    func startBeginsListening() {
        var machine = ListenerRestartStateMachine()
        #expect(machine.currentGeneration == 0)
        #expect(machine.currentState == .idle)
        #expect(machine.start() == .startListener(generation: 1))
        #expect(machine.currentGeneration == 1)
        #expect(machine.currentAttempt == 0)
        #expect(machine.currentState == .listening)
        #expect(machine.isDegraded == false)
        #expect(machine.isWaitingRetry == false)
    }

    // MARK: Single flight

    @Test("A second failure while a retry is pending is ignored")
    func singleFlightRetry() {
        var machine = ListenerRestartStateMachine()
        _ = machine.start()
        #expect(machine.listenerFailed(generation: 1, jitterUnit: 0.5)
            == .scheduleRetry(after: 0.5, generation: 1))
        #expect(machine.isWaitingRetry)
        #expect(machine.currentAttempt == 1)
        // Same generation, still waiting: no second timer, no attempt burned.
        #expect(machine.listenerFailed(generation: 1, jitterUnit: 0.5) == .ignore)
        #expect(machine.listenerFailed(generation: 1, jitterUnit: 0.5) == .ignore)
        #expect(machine.currentAttempt == 1)
        #expect(machine.isWaitingRetry)
        #expect(machine.currentGeneration == 1)
    }

    @Test("A failure reported while idle cannot start a retry")
    func failureWhileIdleIsIgnored() {
        var machine = ListenerRestartStateMachine()
        #expect(machine.listenerFailed(generation: 0, jitterUnit: 0.5) == .ignore)
        #expect(machine.currentState == .idle)
        #expect(machine.currentAttempt == 0)
    }

    // MARK: Stale callbacks

    @Test("Callbacks from an earlier generation change nothing")
    func staleCallbacksAreIgnored() {
        var machine = ListenerRestartStateMachine()
        _ = machine.start()
        _ = machine.listenerFailed(generation: 1, jitterUnit: 0.5)
        #expect(machine.retryDue(generation: 1) == .startListener(generation: 2))
        #expect(machine.currentGeneration == 2)
        #expect(machine.currentState == .listening)
        #expect(machine.currentAttempt == 1)

        // The cancelled generation-1 listener reports late.
        #expect(machine.listenerFailed(generation: 1, jitterUnit: 0.5) == .ignore)
        #expect(machine.listenerReady(generation: 1) == .ignore)
        #expect(machine.retryDue(generation: 1) == .ignore)
        #expect(machine.currentGeneration == 2)
        #expect(machine.currentState == .listening)
        #expect(machine.currentAttempt == 1, "a stale ready must not reset the failure streak")
    }

    @Test("A retry that is not due is ignored")
    func retryWhileListeningIsIgnored() {
        var machine = ListenerRestartStateMachine()
        _ = machine.start()
        #expect(machine.retryDue(generation: 1) == .ignore)
        #expect(machine.currentGeneration == 1)
        #expect(machine.currentState == .listening)
    }

    // MARK: Exhaustion

    @Test("The retry budget is spent once, then the machine degrades for good")
    func exhaustionEntersDegraded() {
        var machine = ListenerRestartStateMachine()
        var action = machine.start()
        var generation: UInt64 = 1
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            guard case .startListener(let g) = action else {
                Issue.record("expected a listener start, got \(action)")
                return
            }
            generation = g
            switch machine.listenerFailed(generation: generation, jitterUnit: 0.5) {
            case .scheduleRetry(let delay, let retryGeneration):
                #expect(retryGeneration == generation, "a retry must be pinned to the failed generation")
                delays.append(delay)
            default:
                Issue.record("expected a scheduled retry while the budget lasts")
                return
            }
            action = machine.retryDue(generation: generation)
        }
        #expect(delays == [0.5, 1, 2, 4, 8, 16, 30, 30])
        #expect(machine.currentAttempt == 8)

        guard case .startListener(let lastGeneration) = action else {
            Issue.record("expected a listener start for the final attempt")
            return
        }
        #expect(machine.listenerFailed(generation: lastGeneration, jitterUnit: 0.5)
            == .enterDegraded(afterAttempts: 8))
        #expect(machine.isDegraded)
        #expect(machine.isWaitingRetry == false)

        // Degraded is stable: nothing restarts the loop.
        #expect(machine.listenerFailed(generation: lastGeneration, jitterUnit: 0.5) == .ignore)
        #expect(machine.retryDue(generation: lastGeneration) == .ignore)
        #expect(machine.isDegraded)
        #expect(machine.currentGeneration == lastGeneration)
    }

    // MARK: Recovery

    @Test("A ready listener resets the streak so the next failure starts over")
    func readyResetsTheFailureStreak() {
        var machine = ListenerRestartStateMachine()
        _ = machine.start()
        _ = machine.listenerFailed(generation: 1, jitterUnit: 0.5)
        _ = machine.retryDue(generation: 1)
        _ = machine.listenerFailed(generation: 2, jitterUnit: 0.5)
        guard case .startListener(let generation) = machine.retryDue(generation: 2) else {
            Issue.record("expected a listener start")
            return
        }
        #expect(machine.currentAttempt == 2)
        #expect(machine.listenerReady(generation: generation) == .ignore)
        #expect(machine.currentAttempt == 0)
        #expect(machine.currentState == .listening)
        #expect(machine.listenerFailed(generation: generation, jitterUnit: 0.5)
            == .scheduleRetry(after: 0.5, generation: generation))
    }

    // MARK: Stop

    @Test("Stopping while a retry is pending invalidates that retry")
    func stopInvalidatesPendingRetry() {
        var machine = ListenerRestartStateMachine()
        _ = machine.start()
        _ = machine.listenerFailed(generation: 1, jitterUnit: 0.5)
        #expect(machine.isWaitingRetry)
        machine.stop()
        #expect(machine.currentState == .idle)
        #expect(machine.currentAttempt == 0)
        #expect(machine.currentGeneration == 2)
        // The timer that survived cancellation fires with the old generation.
        #expect(machine.retryDue(generation: 1) == .ignore)
        #expect(machine.currentState == .idle)
    }

    @Test("Stopping clears a degraded state only through a later start")
    func startAfterStopIsFresh() {
        var machine = ListenerRestartStateMachine()
        _ = machine.start()
        _ = machine.listenerFailed(generation: 1, jitterUnit: 0.5)
        machine.stop()
        #expect(machine.start() == .startListener(generation: 3))
        #expect(machine.currentGeneration == 3)
        #expect(machine.currentAttempt == 0)
        #expect(machine.currentState == .listening)
        // Callbacks from every previous generation stay stale.
        #expect(machine.listenerFailed(generation: 1, jitterUnit: 0.5) == .ignore)
        #expect(machine.listenerFailed(generation: 2, jitterUnit: 0.5) == .ignore)
        #expect(machine.currentState == .listening)
    }
}
