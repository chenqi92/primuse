import Foundation

/// Async backpressure gate bounding the duration, byte size, and count of
/// decoded PCM buffers that are scheduled-but-not-yet-played by an audio
/// player node.
///
/// Without this, a native decoder yields buffers far faster than realtime
/// playback and the whole track (plus the gapless next track) ends up resident
/// in the node's unbounded queue — hundreds of MB for hi-res long tracks, which
/// trips iOS jetsam during background playback.
///
/// `acquire()` suspends the decoder when a high-water mark is reached. The
/// matching `release()` must run from `.dataPlayedBack`, not `.dataConsumed`:
/// a player node may consume scheduled PCM substantially before it reaches
/// the output device, so consumed-data accounting cannot describe audible
/// queue depth. `reset()`/`stop()` may also complete callbacks, so playback
/// ownership is still guarded by the play ID at the service boundary.
public actor DecodedBufferGate {
    public struct Snapshot: Sendable {
        public let bufferedDuration: TimeInterval
        public let bufferedBytes: Int
        public let bufferCount: Int
        public let decodingFinished: Bool

        public init(
            bufferedDuration: TimeInterval,
            bufferedBytes: Int,
            bufferCount: Int,
            decodingFinished: Bool
        ) {
            self.bufferedDuration = bufferedDuration
            self.bufferedBytes = bufferedBytes
            self.bufferCount = bufferCount
            self.decodingFinished = decodingFinished
        }
    }

    private struct Waiter {
        let id: UUID
        let duration: TimeInterval
        let byteCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let maxBufferedDuration: TimeInterval
    private let maxBufferedBytes: Int
    private let maxBufferCount: Int
    private var inFlightDuration: TimeInterval = 0
    private var inFlightBytes = 0
    private var inFlightCount = 0
    private var decodingFinished = false
    private var waiters: [Waiter] = []

    public init(maxBufferedDuration: TimeInterval, maxBufferedBytes: Int, maxBufferCount: Int) {
        self.maxBufferedDuration = max(0.1, maxBufferedDuration)
        self.maxBufferedBytes = max(1, maxBufferedBytes)
        self.maxBufferCount = max(1, maxBufferCount)
    }

    public func acquire(duration: TimeInterval, byteCount: Int) async {
        guard !Task.isCancelled else { return }
        let normalizedDuration = Self.normalized(duration)
        let normalizedByteCount = max(0, byteCount)
        if canAdmit(duration: normalizedDuration, byteCount: normalizedByteCount) {
            reserve(duration: normalizedDuration, byteCount: normalizedByteCount)
            return
        }
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                waiters.append(Waiter(
                    id: waiterID,
                    duration: normalizedDuration,
                    byteCount: normalizedByteCount,
                    continuation: continuation
                ))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    /// Non-suspending counterpart to `acquire()`, callable from `@Sendable`
    /// completion handlers without awaiting.
    public nonisolated func release(duration: TimeInterval, byteCount: Int) {
        Task {
            await self.signal(
                releasing: Self.normalized(duration),
                byteCount: max(0, byteCount)
            )
        }
    }

    private nonisolated static func normalized(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return duration
    }

    private func canAdmit(duration: TimeInterval, byteCount: Int) -> Bool {
        guard inFlightCount < maxBufferCount else { return false }
        // A single unusually large buffer must still be admitted or the gate
        // would deadlock before scheduling it.
        if inFlightCount == 0 { return true }
        return inFlightDuration + duration <= maxBufferedDuration
            && inFlightBytes + byteCount <= maxBufferedBytes
    }

    private func reserve(duration: TimeInterval, byteCount: Int) {
        inFlightCount += 1
        inFlightDuration += duration
        inFlightBytes += byteCount
    }

    private func signal(releasing duration: TimeInterval, byteCount: Int) {
        if inFlightCount > 0 {
            inFlightCount -= 1
            inFlightDuration = max(0, inFlightDuration - duration)
            inFlightBytes = max(0, inFlightBytes - byteCount)
        }

        while let waiter = waiters.first,
              canAdmit(duration: waiter.duration, byteCount: waiter.byteCount) {
            waiters.removeFirst()
            reserve(duration: waiter.duration, byteCount: waiter.byteCount)
            waiter.continuation.resume()
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume()
    }

    public func markDecodingFinished() {
        decodingFinished = true
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            bufferedDuration: inFlightDuration,
            bufferedBytes: inFlightBytes,
            bufferCount: inFlightCount,
            decodingFinished: decodingFinished
        )
    }

    /// Wakes every waiter so a cancelled decoder loop never deadlocks on the
    /// gate even if some node completion callbacks were dropped.
    public func drain() {
        let pending = waiters
        waiters.removeAll()
        inFlightCount = 0
        inFlightDuration = 0
        inFlightBytes = 0
        decodingFinished = true
        for waiter in pending {
            waiter.continuation.resume()
        }
    }
}
