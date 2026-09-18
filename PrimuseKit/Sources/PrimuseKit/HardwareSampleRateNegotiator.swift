import Foundation

/// Waits for the HAL's completion notification before choosing a render format.
/// All hardware access stays on the caller's actor; listener callbacks only
/// enqueue events. The injected operations also exercise delayed/rejected HAL
/// writes without requiring an audio device in the test runner.
@MainActor
public final class HardwareSampleRateNegotiator {
    public struct Snapshot: Equatable, Sendable {
        public let deviceID: UInt32
        public let sampleRate: Double

        public init(deviceID: UInt32, sampleRate: Double) {
            self.deviceID = deviceID
            self.sampleRate = sampleRate
        }
    }

    public enum Event: Sendable {
        case sampleRateChanged, deviceChanged
    }

    private enum Signal: Sendable {
        case change(Event), deadline, cancelled
    }

    public enum Reason: String, Sendable {
        case confirmed, unchanged, rejected, timedOut
        case deviceChanged, deviceUnavailable, observationUnavailable
    }

    public struct Result: Sendable {
        public let snapshot: Snapshot?
        public let reason: Reason
    }

    private var active: (id: UUID, continuation: AsyncStream<Signal>.Continuation)?

    public init() {}

    public func cancel() {
        active?.continuation.yield(.cancelled)
        active = nil
    }

    public func prepare(
        targetSampleRate: Double,
        deviceID: UInt32,
        timeout: Duration = .seconds(1),
        readSnapshot: @MainActor () -> Snapshot?,
        observe: @MainActor (@escaping @Sendable (Event) -> Void) throws -> @MainActor () -> Void,
        requestChange: @MainActor () -> Bool
    ) async throws -> Result {
        try Task.checkCancellation()
        cancel()
        let id = UUID()
        let (events, continuation) = AsyncStream<Signal>.makeStream()
        active = (id, continuation)
        defer {
            continuation.finish()
            if active?.id == id { active = nil }
        }

        let stopObserving: @MainActor () -> Void
        do {
            stopObserving = try observe { continuation.yield(.change($0)) }
        } catch {
            return Result(snapshot: readSnapshot(), reason: .observationUnavailable)
        }
        defer { stopObserving() }

        guard let before = readSnapshot() else {
            return Result(snapshot: nil, reason: .deviceUnavailable)
        }
        guard before.deviceID == deviceID else {
            return Result(snapshot: before, reason: .deviceChanged)
        }
        if Self.matches(before.sampleRate, targetSampleRate) {
            return Result(snapshot: before, reason: .unchanged)
        }
        try Task.checkCancellation()
        guard requestChange() else {
            return Result(snapshot: readSnapshot(), reason: .rejected)
        }

        let deadline = Task {
            do {
                try await Task.sleep(for: timeout)
                continuation.yield(.deadline)
            } catch {}
        }
        defer { deadline.cancel() }

        for await event in events {
            try Task.checkCancellation()
            if case .cancelled = event { throw CancellationError() }
            guard let current = readSnapshot() else {
                return Result(snapshot: nil, reason: .deviceUnavailable)
            }
            guard current.deviceID == deviceID else {
                return Result(snapshot: current, reason: .deviceChanged)
            }
            switch event {
            case .change(.sampleRateChanged) where Self.matches(current.sampleRate, targetSampleRate):
                return Result(snapshot: current, reason: .confirmed)
            case .deadline:
                return Result(snapshot: current, reason: .timedOut)
            default:
                continue
            }
        }
        throw CancellationError()
    }

    private static func matches(_ actual: Double, _ requested: Double) -> Bool {
        actual.isFinite && requested.isFinite && abs(actual - requested) < 1
    }
}
