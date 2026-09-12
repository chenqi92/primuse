import Foundation

/// One-shot latch for "this playback schedule has settled".
///
/// Follow-up scheduling used to poll the transition state on a timer for most
/// of a track. A settlement is signalled exactly once — when the schedule
/// completed, failed, or was cancelled — so waiters stay parked until there is
/// real work to do.
///
/// MainActor-isolated: every mutation happens on the same actor as the
/// playback state it mirrors.
@MainActor
public final class PlaybackScheduleSettlement {
    public private(set) var isSettled: Bool = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Creating the latch touches no isolated state, so non-isolated owners
    /// (such as a handoff state object) can hold one as a stored property.
    public nonisolated init() {}

    /// Marks the schedule as settled and resumes every waiter. Idempotent.
    public func settle() {
        guard !isSettled else { return }
        isSettled = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values {
            continuation.resume()
        }
    }

    /// Suspends until `settle()` is called, or returns immediately if the
    /// schedule has already settled. Cancelling the waiting task also returns;
    /// callers re-check their own guards afterwards.
    public func waitUntilSettled() async {
        if isSettled { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Both the settle and the cancellation paths remove the entry
                // before resuming, so a continuation is resumed exactly once.
                if isSettled || Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in self.resumeWaiter(id) }
        }
    }

    private func resumeWaiter(_ id: UUID) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume()
    }
}
