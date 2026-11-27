import Dispatch
import Foundation
import Testing
@testable import PrimuseKit

@Suite("Async slot gate")
struct AsyncSlotGateTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        private var active = 0
        private var maximumActive = 0

        func record(_ value: Int) {
            lock.withLock { values.append(value) }
        }

        var recorded: [Int] { lock.withLock { values } }

        func enter() {
            lock.withLock {
                active += 1
                maximumActive = max(maximumActive, active)
            }
        }

        func leave() { lock.withLock { active -= 1 } }

        var peak: Int { lock.withLock { maximumActive } }
    }

    @Test("A held slot makes the next caller wait until it is released")
    func holderBlocksUntilRelease() async {
        let gate = AsyncSlotGate()
        #expect(await gate.acquire())
        let waiter = Task { await gate.acquire() }
        await Self.waitForQueue(gate, count: 1)

        gate.release()
        #expect(await waiter.value)
        #expect(gate.snapshot == (true, 0))
        gate.release()
        #expect(gate.snapshot == (false, 0))
    }

    @Test("Release hands the slot to the most recent waiter")
    func newestWaiterGoesFirst() async {
        let gate = AsyncSlotGate()
        let order = Recorder()
        #expect(await gate.acquire())
        var waiters: [Task<Void, Never>] = []
        for index in 0..<3 {
            waiters.append(Task {
                guard await gate.acquire() else { return }
                order.record(index)
                gate.release()
            })
            await Self.waitForQueue(gate, count: index + 1)
        }

        gate.release()
        for waiter in waiters { await waiter.value }
        #expect(order.recorded == [2, 1, 0])
        #expect(gate.snapshot == (false, 0))
    }

    @Test("A waiter cancelled in the queue returns false and does not take the slot")
    func cancelledWaiterLeavesQueue() async {
        let gate = AsyncSlotGate()
        #expect(await gate.acquire())
        let waiter = Task { await gate.acquire() }
        await Self.waitForQueue(gate, count: 1)

        waiter.cancel()
        #expect(await waiter.value == false)
        #expect(gate.snapshot == (true, 0))
        gate.release()
        #expect(gate.snapshot == (false, 0))
    }

    @Test("A task already cancelled does not queue behind the holder")
    func alreadyCancelledTaskDoesNotQueue() async {
        let gate = AsyncSlotGate()
        #expect(await gate.acquire())
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await gate.acquire()
        }
        #expect(await waiter.value == false)
        #expect(gate.snapshot == (true, 0))
        gate.release()
    }

    /// The two parties the CarPlay crash logs caught at the same time: the
    /// holder giving the slot back and the queued task being cancelled, each
    /// arriving from its own plain thread rather than through one executor.
    @Test("Release and cancellation racing on plain threads resume the waiter exactly once")
    func releaseRacingCancellation() async {
        for _ in 0..<500 {
            let gate = AsyncSlotGate()
            #expect(await gate.acquire())
            let waiter = Task { await gate.acquire() }
            await Self.waitForQueue(gate, count: 1)

            let start = DispatchSemaphore(value: 0)
            let done = DispatchGroup()
            DispatchQueue.global().async(group: done) {
                start.wait()
                gate.release()
            }
            DispatchQueue.global().async(group: done) {
                start.wait()
                waiter.cancel()
            }
            start.signal()
            start.signal()
            await withCheckedContinuation { continuation in
                done.notify(queue: .global()) { continuation.resume() }
            }

            // Winning the slot after being cancelled still means holding it.
            if await waiter.value { gate.release() }
            #expect(gate.snapshot == (false, 0))
        }
    }

    /// Mirrors a CarPlay template rebuild: a long queue of artwork loads, one
    /// holder at a time, and a burst of cancellations from another thread.
    @Test("Only one holder at a time while a burst of waiters is cancelled")
    func exclusiveUnderMassCancellation() async {
        let gate = AsyncSlotGate()
        let recorder = Recorder()
        let outcomes = Recorder()
        let tasks = (0..<200).map { _ in
            Task {
                guard await gate.acquire() else {
                    outcomes.record(0)
                    return
                }
                recorder.enter()
                await Task.yield()
                recorder.leave()
                gate.release()
                outcomes.record(1)
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                for (index, task) in tasks.enumerated() where index.isMultiple(of: 2) {
                    task.cancel()
                }
                continuation.resume()
            }
        }
        for task in tasks { await task.value }

        #expect(recorder.peak == 1)
        #expect(outcomes.recorded.count == tasks.count)
        #expect(gate.snapshot == (false, 0))
    }

    @Test("A holder releasing while a waiter is still queueing does not strand the waiter")
    func releaseDuringQueueingDoesNotStrandWaiter() async {
        for _ in 0..<500 {
            let gate = AsyncSlotGate()
            #expect(await gate.acquire())
            let waiter = Task { () -> Bool in
                let acquired = await gate.acquire()
                if acquired { gate.release() }
                return acquired
            }
            DispatchQueue.global().async { gate.release() }
            let finished = await Self.finishes(waiter, within: .seconds(2))
            #expect(finished)
            guard finished else { return }
            #expect(await waiter.value)
            #expect(gate.snapshot == (false, 0))
        }
    }

    /// Whether `task` ends on its own within `duration`; a stranded task is
    /// cancelled so the test itself does not hang.
    private static func finishes(_ task: Task<Bool, Never>, within duration: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await task.value
                return true
            }
            group.addTask {
                try? await Task.sleep(for: duration)
                task.cancel()
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private static func waitForQueue(_ gate: AsyncSlotGate, count: Int) async {
        for _ in 0..<2_000 where gate.snapshot.waiterCount < count {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
