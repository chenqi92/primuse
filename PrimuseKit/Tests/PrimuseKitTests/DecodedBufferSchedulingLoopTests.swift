import Foundation
import Testing
@testable import PrimuseKit

private struct FakeBuffer: Sendable {
    let index: Int
    let frames: Int
}

private struct FakeDecodeError: Error {}

/// Stands in for the player node: records what was handed to it and keeps the
/// `.dataPlayedBack` release handlers so a test can play a buffer out by hand.
private final class RecordingScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var scheduled: [FakeBuffer] = []
    private var releases: [@Sendable () -> Void] = []

    func schedule(_ buffer: FakeBuffer, release: @escaping @Sendable () -> Void) {
        lock.lock()
        scheduled.append(buffer)
        releases.append(release)
        lock.unlock()
    }

    var scheduledIndices: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return scheduled.map(\.index)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return scheduled.count
    }

    /// Invokes the oldest outstanding release handler, mirroring a buffer
    /// finishing playback on the node.
    func playOutOldest() {
        lock.lock()
        let handler = releases.isEmpty ? nil : releases.removeFirst()
        lock.unlock()
        handler?()
    }
}

/// Feeds buffers to the loop, optionally failing or pausing at a given index.
private final class FakeSource: @unchecked Sendable {
    private let lock = NSLock()
    private var produced = 0
    private let total: Int
    private let failAt: Int?
    private let framesPerBuffer: Int

    init(total: Int, failAt: Int? = nil, framesPerBuffer: Int = 1_000) {
        self.total = total
        self.failAt = failAt
        self.framesPerBuffer = framesPerBuffer
    }

    func next() throws -> FakeBuffer? {
        lock.lock()
        let index = produced
        produced += 1
        lock.unlock()
        if let failAt, index == failAt { throw FakeDecodeError() }
        guard index < total else { return nil }
        return FakeBuffer(index: index, frames: framesPerBuffer)
    }
}

@Suite("Decoded buffer scheduling loop")
struct DecodedBufferSchedulingLoopTests {
    private static let halfSecond = DecodedBufferMeasurement(duration: 0.5, byteCount: 4_000)

    private static func measureHalfSecond(_ buffer: FakeBuffer) -> DecodedBufferMeasurement {
        DecodedBufferMeasurement(duration: 0.5, byteCount: buffer.frames * 4)
    }

    private static func openGate() -> DecodedBufferGate {
        DecodedBufferGate(
            maxBufferedDuration: .greatestFiniteMagnitude,
            maxBufferedBytes: .max,
            maxBufferCount: .max
        )
    }

    private static func ownedLease(_ playID: Int) -> PlaybackOwnershipLease<Int> {
        let lease = PlaybackOwnershipLease<Int>()
        lease.update(currentPlayID: playID, isCrossfading: false, outgoingPlayID: nil)
        return lease
    }

    private static func makeLoop(
        playID: Int,
        lease: PlaybackOwnershipLease<Int>,
        gate: DecodedBufferGate,
        scheduler: RecordingScheduler
    ) -> DecodedBufferSchedulingLoop<FakeBuffer, Int> {
        DecodedBufferSchedulingLoop(
            playID: playID,
            lease: lease,
            gate: gate,
            measure: measureHalfSecond,
            schedule: { buffer, release in scheduler.schedule(buffer, release: release) }
        )
    }

    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        for _ in 0..<20 { await Task.yield() }
    }

    @Test("Buffers are scheduled in order and the final one is held back")
    func schedulesInOrderAndHoldsLast() async {
        let scheduler = RecordingScheduler()
        let lease = Self.ownedLease(1)
        let source = FakeSource(total: 5)
        let loop = Self.makeLoop(playID: 1, lease: lease, gate: Self.openGate(), scheduler: scheduler)

        let outcome = await loop.run(next: { try source.next() })

        guard case let .completed(lastBuffer, scheduledCount) = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        #expect(scheduledCount == 4)
        #expect(scheduler.scheduledIndices == [0, 1, 2, 3])
        #expect(lastBuffer?.index == 4)
        // The held buffer must never reach the node from inside the loop.
        #expect(!scheduler.scheduledIndices.contains(4))
    }

    @Test("An initial held buffer is scheduled first")
    func initialHeldBufferIsScheduledFirst() async {
        let scheduler = RecordingScheduler()
        let lease = Self.ownedLease(1)
        let source = FakeSource(total: 3)
        let loop = Self.makeLoop(playID: 1, lease: lease, gate: Self.openGate(), scheduler: scheduler)

        let outcome = await loop.run(
            next: { try source.next() },
            initialHeldBuffer: FakeBuffer(index: -1, frames: 1_000)
        )

        guard case let .completed(lastBuffer, scheduledCount) = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        #expect(scheduler.scheduledIndices == [-1, 0, 1])
        #expect(scheduledCount == 3)
        #expect(lastBuffer?.index == 2)
    }

    @Test("A single buffer is held, never scheduled")
    func singleBufferIsOnlyHeld() async {
        let scheduler = RecordingScheduler()
        let loop = Self.makeLoop(
            playID: 1,
            lease: Self.ownedLease(1),
            gate: Self.openGate(),
            scheduler: scheduler
        )
        let source = FakeSource(total: 1)

        let outcome = await loop.run(next: { try source.next() })
        guard case let .completed(lastBuffer, scheduledCount) = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        #expect(scheduledCount == 0)
        #expect(scheduler.count == 0)
        #expect(lastBuffer?.index == 0)
    }

    @Test("The gate stalls the pump until a release handler runs")
    func gateStallsUntilRelease() async {
        let scheduler = RecordingScheduler()
        // 1 s window with 0.5 s buffers admits two, so the third schedule waits.
        let gate = DecodedBufferGate(
            maxBufferedDuration: 1,
            maxBufferedBytes: .max,
            maxBufferCount: .max
        )
        let source = FakeSource(total: 8)
        let loop = Self.makeLoop(playID: 1, lease: Self.ownedLease(1), gate: gate, scheduler: scheduler)

        let running = Task { await loop.run(next: { try source.next() }) }
        await Self.settle()
        #expect(scheduler.count == 2)
        #expect(scheduler.scheduledIndices == [0, 1])

        scheduler.playOutOldest()
        await Self.settle()
        #expect(scheduler.count == 3)
        #expect(scheduler.scheduledIndices == [0, 1, 2])

        // Drain the rest so the loop can finish.
        while scheduler.count < 7 {
            scheduler.playOutOldest()
            await Self.settle()
        }
        let outcome = await running.value
        guard case let .completed(lastBuffer, scheduledCount) = outcome else {
            Issue.record("expected completion, got \(outcome)")
            return
        }
        #expect(scheduledCount == 7)
        #expect(lastBuffer?.index == 7)
    }

    @Test("Losing ownership mid-stream stops scheduling immediately")
    func lostOwnershipStopsPump() async {
        let scheduler = RecordingScheduler()
        let lease = Self.ownedLease(1)
        let gate = DecodedBufferGate(
            maxBufferedDuration: 1,
            maxBufferedBytes: .max,
            maxBufferCount: .max
        )
        let source = FakeSource(total: 20)
        let loop = Self.makeLoop(playID: 1, lease: lease, gate: gate, scheduler: scheduler)

        let running = Task { await loop.run(next: { try source.next() }) }
        await Self.settle()
        #expect(scheduler.count == 2)

        // A newer track takes over while the pump is parked on the gate.
        lease.update(currentPlayID: 2, isCrossfading: false, outgoingPlayID: nil)
        scheduler.playOutOldest()

        let outcome = await running.value
        guard case let .lostOwnership(scheduledCount) = outcome else {
            Issue.record("expected lost ownership, got \(outcome)")
            return
        }
        #expect(scheduledCount == 2)
        await Self.settle()
        #expect(scheduler.scheduledIndices == [0, 1])
    }

    @Test("The outgoing crossfade owner keeps scheduling until the ramp ends")
    func outgoingOwnerKeepsGraceWhileCrossfading() async {
        let scheduler = RecordingScheduler()
        let lease = Self.ownedLease(1)
        let source = FakeSource(total: 20)
        let gate = DecodedBufferGate(
            maxBufferedDuration: 1,
            maxBufferedBytes: .max,
            maxBufferCount: .max
        )
        let loop = Self.makeLoop(playID: 1, lease: lease, gate: gate, scheduler: scheduler)

        let running = Task { await loop.run(next: { try source.next() }) }
        await Self.settle()

        // Commit the crossfade: the play ID rotates but the ramp is still live.
        lease.update(currentPlayID: 2, isCrossfading: true, outgoingPlayID: 1)
        scheduler.playOutOldest()
        await Self.settle()
        #expect(scheduler.count == 3)

        // Ending the transition retires the outgoing pump.
        lease.update(currentPlayID: 2, isCrossfading: false, outgoingPlayID: nil)
        scheduler.playOutOldest()
        let outcome = await running.value
        guard case let .lostOwnership(scheduledCount) = outcome else {
            Issue.record("expected lost ownership, got \(outcome)")
            return
        }
        #expect(scheduledCount == 3)
    }

    @Test("A mid-stream decode error reports the count and the held buffer")
    func midStreamErrorIsReported() async {
        let scheduler = RecordingScheduler()
        let source = FakeSource(total: 20, failAt: 4)
        let loop = Self.makeLoop(
            playID: 1,
            lease: Self.ownedLease(1),
            gate: Self.openGate(),
            scheduler: scheduler
        )

        let outcome = await loop.run(next: { try source.next() })
        guard case let .failed(error, lastBuffer, scheduledCount) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(error is FakeDecodeError)
        #expect(scheduledCount == 3)
        #expect(scheduler.scheduledIndices == [0, 1, 2])
        // Already-scheduled audio stays queued; the held buffer goes to the
        // caller so it can still attach a failure-aware final path.
        #expect(lastBuffer?.index == 3)
    }

    @Test("Cancelling the running task reports cancellation")
    func cancellationIsReported() async {
        let scheduler = RecordingScheduler()
        let gate = DecodedBufferGate(
            maxBufferedDuration: 1,
            maxBufferedBytes: .max,
            maxBufferCount: .max
        )
        let source = FakeSource(total: 50)
        let loop = Self.makeLoop(playID: 1, lease: Self.ownedLease(1), gate: gate, scheduler: scheduler)

        let running = Task { await loop.run(next: { try source.next() }) }
        await Self.settle()
        #expect(scheduler.count == 2)

        running.cancel()
        // Cancellation also wakes the waiter parked inside the gate.
        await gate.drain()

        let outcome = await running.value
        guard case let .cancelled(scheduledCount) = outcome else {
            Issue.record("expected cancellation, got \(outcome)")
            return
        }
        #expect(scheduledCount == 2)
    }

    @Test("A cancellation thrown by the source is not a decode failure")
    func cancellationErrorFromSourceIsCancellation() async {
        let scheduler = RecordingScheduler()
        let loop = Self.makeLoop(
            playID: 1,
            lease: Self.ownedLease(1),
            gate: Self.openGate(),
            scheduler: scheduler
        )

        let running = Task { () -> DecodedBufferSchedulingOutcome<FakeBuffer> in
            await loop.run(next: {
                // Model a stream that surfaces cancellation as a thrown error.
                while !Task.isCancelled { await Task.yield() }
                throw CancellationError()
            })
        }
        await Self.settle()
        running.cancel()

        let outcome = await running.value
        guard case let .cancelled(scheduledCount) = outcome else {
            Issue.record("expected cancellation, got \(outcome)")
            return
        }
        #expect(scheduledCount == 0)
        #expect(scheduler.count == 0)
    }
}
