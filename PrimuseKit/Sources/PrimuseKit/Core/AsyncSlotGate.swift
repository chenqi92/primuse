import Foundation

/// One slot, handed to one holder at a time. When the holder releases it and
/// others are queued, the slot goes straight to the most recent waiter, so the
/// newest request (for example the page that was just built) is served first.
///
/// The queue is guarded by a lock instead of an actor. A cancellation handler
/// runs synchronously on whichever thread calls `cancel()`, so it takes the
/// waiter out of the queue right there rather than spawning a task that hops
/// back to an actor later. Every waiter is resumed exactly once: whichever of
/// `release()` and cancellation removes it from the queue first resumes it,
/// and the other finds nothing to do.
public final class AsyncSlotGate: @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let lock = NSLock()
    private var isOccupied = false
    private var waiters: [Waiter] = []
    private var lastWaiterID: UInt64 = 0

    public init() {}

    /// Waits for the slot. Returns `true` once the caller holds it and must
    /// call `release()`; returns `false` when the task was cancelled while
    /// queued, in which case the caller does not hold the slot.
    public func acquire() async -> Bool {
        let waiterID: UInt64? = lock.withLock {
            guard isOccupied else {
                isOccupied = true
                return nil
            }
            lastWaiterID &+= 1
            return lastWaiterID
        }
        guard let waiterID else { return true }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // The runtime marks the task cancelled before it runs the
                // handler, and the handler needs this lock: a waiter queued
                // here is always found by the handler, and a cancellation
                // whose handler already ran is seen here. The holder may also
                // have released since the check above; queueing behind a free
                // slot would leave this waiter with nobody to wake it.
                let outcome: Bool? = lock.withLock {
                    guard !Task.isCancelled else { return false }
                    guard isOccupied else {
                        isOccupied = true
                        return true
                    }
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                    return nil
                }
                if let outcome { continuation.resume(returning: outcome) }
            }
        } onCancel: {
            self.cancelWaiter(id: waiterID)
        }
    }

    /// Gives the slot back, handing it to the most recent waiter if any.
    public func release() {
        let next: Waiter? = lock.withLock {
            if let waiter = waiters.popLast() { return waiter }
            isOccupied = false
            return nil
        }
        next?.continuation.resume(returning: true)
    }

    private func cancelWaiter(id: UInt64) {
        let waiter: Waiter? = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return waiters.remove(at: index)
        }
        waiter?.continuation.resume(returning: false)
    }

    /// Whether someone holds the slot and how many are queued, for tests.
    var snapshot: (isOccupied: Bool, waiterCount: Int) {
        lock.withLock { (isOccupied, waiters.count) }
    }
}
