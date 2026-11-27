import Foundation

/// Rejects asynchronous playback work after another selection supersedes it.
/// Cancellation alone is insufficient because a resolver may finish normally
/// after its owning task has been cancelled.
public enum PlaybackRequestGenerationPolicy {
    public static func shouldApplyResult<RequestID: Equatable>(
        requestID: RequestID,
        activeRequestID: RequestID?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled && requestID == activeRequestID
    }
}
