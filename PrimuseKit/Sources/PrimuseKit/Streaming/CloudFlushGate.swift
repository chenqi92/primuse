import Foundation

/// Throttled CloudKit pushes (playback history, listening stats) arm a task that
/// sleeps for the throttle window and then enqueues one save. The sleep is a
/// suspension point the service can outlive: `stop()` cancels the task, but a
/// `try?`-swallowed `CancellationError` still lets the body run on the next
/// main-actor turn, and by then the service may have been restarted with a new
/// engine.
///
/// Two facts decide whether the sleeping task may still act:
/// - it was cancelled — the flush belongs to a teardown that already happened;
/// - the token it was armed with is no longer the current one — either `stop()`
///   cleared it, or a newer change armed a replacement that now owns the handle.
///
/// The token half is what cancellation alone cannot cover: a task that was never
/// cancelled, but whose service restarted, would otherwise clear the newer
/// task's handle and push immediately, bypassing the throttle window.
public enum CloudFlushGate {
    /// Whether a throttled flush task may still run its body after the sleep.
    ///
    /// - Parameters:
    ///   - isCancelled: the flush task's own cancellation state.
    ///   - currentToken: the token the service currently considers armed, or
    ///     `nil` once it has been stopped.
    ///   - taskToken: the token this task was armed with.
    public static func shouldFlush(isCancelled: Bool, currentToken: UUID?, taskToken: UUID) -> Bool {
        guard !isCancelled else { return false }
        return currentToken == taskToken
    }
}
