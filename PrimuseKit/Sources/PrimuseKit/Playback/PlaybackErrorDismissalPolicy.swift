import Foundation

/// Prevents a delayed error-dismiss timer from clearing a newer playback
/// request's message, including the case where the text happens to match.
public enum PlaybackErrorDismissalPolicy {
    public static func shouldDismiss<RequestID: Equatable>(
        requestID: RequestID?,
        activeRequestID: RequestID?,
        scheduledMessage: String,
        currentMessage: String?,
        isCancelled: Bool
    ) -> Bool {
        !isCancelled
            && requestID == activeRequestID
            && scheduledMessage == currentMessage
    }
}
