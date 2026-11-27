import Foundation

public enum PlaybackURLRequestPolicy {
    public static func canBegin<RequestID: Equatable>(
        requestID: RequestID,
        activeRequestID: RequestID,
        isCancelled: Bool,
        requiresCurrentStreamEpoch: Bool,
        streamEpochIsCurrent: Bool
    ) -> Bool {
        guard PlaybackRequestGenerationPolicy.shouldApplyResult(
            requestID: requestID,
            activeRequestID: activeRequestID,
            isCancelled: isCancelled
        ) else {
            return false
        }
        return !requiresCurrentStreamEpoch || streamEpochIsCurrent
    }
}
