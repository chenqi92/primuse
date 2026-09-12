import Foundation
import Testing
@testable import PrimuseKit

@Suite("Decoded buffer gate")
struct DecodedBufferGateTests {
    /// Records the order in which waiters were resumed.
    private final class WakeOrder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []

        func record(_ value: Int) {
            lock.lock()
            values.append(value)
            lock.unlock()
        }

        var recorded: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    @Test("The duration window blocks the next acquire until a release")
    func durationCapBlocksUntilRelease() async {
        let gate = DecodedBufferGate(
            maxBufferedDuration: 1,
            maxBufferedBytes: .max,
            maxBufferCount: 16
        )
        await gate.acquire(duration: 0.6, byteCount: 10)
        await gate.acquire(duration: 0.4, byteCount: 10)

        let blocked = Task { await gate.acquire(duration: 0.4, byteCount: 10) }
        await Self.settle()
        var snapshot = await gate.snapshot()
        #expect(snapshot.bufferCount == 2)
        #expect(!blocked.isCancelled)

        gate.release(duration: 0.6, byteCount: 10)
        await blocked.value
        snapshot = await gate.snapshot()
        #expect(snapshot.bufferCount == 2)
        #expect(abs(snapshot.bufferedDuration - 0.8) < 0.000_001)
    }

    @Test("The byte window blocks the next acquire until a release")
    func byteCapBlocksUntilRelease() async {
        let gate = DecodedBufferGate(
            maxBufferedDuration: .greatestFiniteMagnitude,
            maxBufferedBytes: 1_000,
            maxBufferCount: 16
        )
        await gate.acquire(duration: 0.1, byteCount: 700)
        await gate.acquire(duration: 0.1, byteCount: 300)

        let blocked = Task { await gate.acquire(duration: 0.1, byteCount: 300) }
        await Self.settle()
        #expect(await gate.snapshot().bufferedBytes == 1_000)

        gate.release(duration: 0.1, byteCount: 700)
        await blocked.value
        #expect(await gate.snapshot().bufferedBytes == 600)
    }

    @Test("The count window blocks the next acquire until a release")
    func countCapBlocksUntilRelease() async {
        let gate = DecodedBufferGate(
            maxBufferedDuration: .greatestFiniteMagnitude,
            maxBufferedBytes: .max,
            maxBufferCount: 2
        )
        await gate.acquire(duration: 0.1, byteCount: 1)
        await gate.acquire(duration: 0.1, byteCount: 1)

        let blocked = Task { await gate.acquire(duration: 0.1, byteCount: 1) }
        await Self.settle()
        #expect(await gate.snapshot().bufferCount == 2)

        gate.release(duration: 0.1, byteCount: 1)
        await blocked.value
        #expect(await gate.snapshot().bufferCount == 2)
    }

    @Test("A single oversized buffer is admitted on an empty gate")
    func oversizedBufferAdmittedWhenNothingInFlight() async {
        let gate = DecodedBufferGate(
            maxBufferedDuration: 1,
            maxBufferedBytes: 100,
            maxBufferCount: 4
        )
        await gate.acquire(duration: 30, byteCount: 10_000_000)
        let snapshot = await gate.snapshot()
        #expect(snapshot.bufferCount == 1)
        #expect(snapshot.bufferedBytes == 10_000_000)

        // With the oversized buffer resident, ordinary buffers must wait.
        let blocked = Task { await gate.acquire(duration: 0.1, byteCount: 1) }
        await Self.settle()
        #expect(await gate.snapshot().bufferCount == 1)

        gate.release(duration: 30, byteCount: 10_000_000)
        await blocked.value
        #expect(await gate.snapshot().bufferCount == 1)
    }

    @Test("Waiters wake in FIFO order")
    func waitersWakeInArrivalOrder() async {
        let gate = DecodedBufferGate(
            maxBufferedDuration: .greatestFiniteMagnitude,
            maxBufferedBytes: .max,
            maxBufferCount: 1
        )
        await gate.acquire(duration: 0.1, byteCount: 1)
        let order = WakeOrder()

        var waiters: [Task<Void, Never>] = []
        for index in 0..<4 {
            waiters.append(Task {
                await gate.acquire(duration: 0.1, byteCount: 1)
                order.record(index)
            })
            // Serialise enqueueing so arrival order is deterministic.
            await Self.settle()
        }

        for _ in 0..<4 {
            gate.release(duration: 0.1, byteCount: 1)
            await Self.settle()
        }
        for waiter in waiters { await waiter.value }
        #expect(order.recorded == [0, 1, 2, 3])
    }

    @Test("Draining wakes every waiter and marks decoding finished")
    func drainReleasesAllWaiters() async {
        let gate = DecodedBufferGate(
            maxBufferedDuration: .greatestFiniteMagnitude,
            maxBufferedBytes: .max,
            maxBufferCount: 1
        )
        await gate.acquire(duration: 0.1, byteCount: 1)

        var waiters: [Task<Void, Never>] = []
        for _ in 0..<3 {
            waiters.append(Task { await gate.acquire(duration: 0.1, byteCount: 1) })
            await Self.settle()
        }

        await gate.drain()
        for waiter in waiters { await waiter.value }

        let snapshot = await gate.snapshot()
        #expect(snapshot.bufferCount == 0)
        #expect(snapshot.bufferedBytes == 0)
        #expect(snapshot.bufferedDuration == 0)
        #expect(snapshot.decodingFinished)
    }

    @Test("A cancelled waiter is resumed and removed from the queue")
    func cancelledWaiterIsResumed() async {
        let gate = DecodedBufferGate(
            maxBufferedDuration: .greatestFiniteMagnitude,
            maxBufferedBytes: .max,
            maxBufferCount: 1
        )
        await gate.acquire(duration: 0.1, byteCount: 1)

        let cancelled = Task { await gate.acquire(duration: 0.1, byteCount: 1) }
        await Self.settle()
        let survivor = Task { await gate.acquire(duration: 0.1, byteCount: 1) }
        await Self.settle()

        cancelled.cancel()
        await cancelled.value

        // The cancelled waiter left without reserving, so the single release
        // must reach the waiter that is still queued behind it.
        gate.release(duration: 0.1, byteCount: 1)
        await survivor.value
        #expect(await gate.snapshot().bufferCount == 1)
    }

    @Test("Snapshots report the in-flight totals")
    func snapshotReflectsInFlightTotals() async {
        let gate = DecodedBufferGate(
            maxBufferedDuration: 100,
            maxBufferedBytes: 1_000_000,
            maxBufferCount: 100
        )
        #expect(await gate.snapshot().bufferCount == 0)

        await gate.acquire(duration: 0.5, byteCount: 2_048)
        await gate.acquire(duration: 0.25, byteCount: 1_024)
        var snapshot = await gate.snapshot()
        #expect(snapshot.bufferCount == 2)
        #expect(snapshot.bufferedBytes == 3_072)
        #expect(abs(snapshot.bufferedDuration - 0.75) < 0.000_001)
        #expect(!snapshot.decodingFinished)

        gate.release(duration: 0.5, byteCount: 2_048)
        await Self.settle()
        await gate.markDecodingFinished()
        snapshot = await gate.snapshot()
        #expect(snapshot.bufferCount == 1)
        #expect(snapshot.bufferedBytes == 1_024)
        #expect(snapshot.decodingFinished)
    }

    @Test("Non-finite and negative measurements normalize to zero")
    func invalidMeasurementsNormalize() async {
        let gate = DecodedBufferGate(
            maxBufferedDuration: 1,
            maxBufferedBytes: 100,
            maxBufferCount: 4
        )
        await gate.acquire(duration: .nan, byteCount: -50)
        let snapshot = await gate.snapshot()
        #expect(snapshot.bufferCount == 1)
        #expect(snapshot.bufferedDuration == 0)
        #expect(snapshot.bufferedBytes == 0)
    }

    /// `release()` hops through a detached task, so tests need a settling point
    /// that is not a wall-clock sleep of arbitrary length.
    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        for _ in 0..<20 { await Task.yield() }
    }
}
