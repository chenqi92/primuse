import Foundation

/// How a decode→schedule pump ended.
///
/// `lastBuffer` is the buffer the loop deliberately held back: the caller still
/// owes it a final-buffer path (track-end / gapless callbacks), so the loop
/// never schedules it itself.
public enum DecodedBufferSchedulingOutcome<Buffer: Sendable>: Sendable {
    /// The source ran dry. `lastBuffer` is the held-back final buffer, if any.
    case completed(lastBuffer: Buffer?, scheduledCount: Int)
    /// The source threw mid-stream. Everything scheduled so far is still queued.
    case failed(error: any Error, lastBuffer: Buffer?, scheduledCount: Int)
    /// The task was cancelled; the held buffer is dropped with the pump.
    case cancelled(scheduledCount: Int)
    /// A newer play ID took over, so this pump must stop feeding the node.
    case lostOwnership(scheduledCount: Int)
}

/// The two quantities the backpressure gate accounts for, measured per buffer.
public struct DecodedBufferMeasurement: Sendable {
    public let duration: TimeInterval
    public let byteCount: Int

    public init(duration: TimeInterval, byteCount: Int) {
        self.duration = duration
        self.byteCount = byteCount
    }
}

/// The steady-state decode→schedule pump, with no audio framework dependency.
///
/// The loop is deliberately one buffer behind the decoder: it holds the newest
/// buffer and schedules the previous one, so the caller always gets the real
/// final buffer back and can attach the track-end callbacks to it.
///
/// Ownership and cancellation are re-checked both before and after the gate
/// wait, because `acquire()` can suspend for as long as the queued audio takes
/// to play — a track change is very likely to land inside that window.
public struct DecodedBufferSchedulingLoop<Buffer: Sendable, ID: Equatable & Sendable>: Sendable {
    private let playID: ID
    private let lease: PlaybackOwnershipLease<ID>
    private let gate: DecodedBufferGate
    private let measure: @Sendable (Buffer) -> DecodedBufferMeasurement
    private let schedule: @Sendable (Buffer, @escaping @Sendable () -> Void) -> Void

    /// - Parameter schedule: receives the buffer plus the release handler that
    ///   the caller must invoke from the player node's `.dataPlayedBack`
    ///   completion. Releasing earlier (or never) breaks the backpressure
    ///   window the gate maintains.
    public init(
        playID: ID,
        lease: PlaybackOwnershipLease<ID>,
        gate: DecodedBufferGate,
        measure: @escaping @Sendable (Buffer) -> DecodedBufferMeasurement,
        schedule: @escaping @Sendable (Buffer, @escaping @Sendable () -> Void) -> Void
    ) {
        self.playID = playID
        self.lease = lease
        self.gate = gate
        self.measure = measure
        self.schedule = schedule
    }

    public func run(
        next: @Sendable () async throws -> Buffer?,
        initialHeldBuffer: Buffer? = nil
    ) async -> DecodedBufferSchedulingOutcome<Buffer> {
        var lastBuffer = initialHeldBuffer
        var scheduledCount = 0

        do {
            while let buffer = try await next() {
                guard !Task.isCancelled else {
                    return .cancelled(scheduledCount: scheduledCount)
                }
                guard lease.mayContinue(playID) else {
                    return .lostOwnership(scheduledCount: scheduledCount)
                }

                if let previous = lastBuffer {
                    // Backpressure: block once the duration/byte/count window is
                    // full so resident PCM tracks playback instead of the whole
                    // track piling into the node's unbounded queue.
                    let measurement = measure(previous)
                    await gate.acquire(
                        duration: measurement.duration,
                        byteCount: measurement.byteCount
                    )
                    guard !Task.isCancelled else {
                        return .cancelled(scheduledCount: scheduledCount)
                    }
                    guard lease.mayContinue(playID) else {
                        return .lostOwnership(scheduledCount: scheduledCount)
                    }
                    let gate = gate
                    schedule(previous) {
                        gate.release(
                            duration: measurement.duration,
                            byteCount: measurement.byteCount
                        )
                    }
                    scheduledCount += 1
                }
                lastBuffer = buffer
            }
        } catch {
            // A cancelled source reports cancellation, not a decode failure:
            // the caller must not surface an error banner for a track change.
            if error is CancellationError, Task.isCancelled {
                return .cancelled(scheduledCount: scheduledCount)
            }
            return .failed(error: error, lastBuffer: lastBuffer, scheduledCount: scheduledCount)
        }

        return .completed(lastBuffer: lastBuffer, scheduledCount: scheduledCount)
    }
}
