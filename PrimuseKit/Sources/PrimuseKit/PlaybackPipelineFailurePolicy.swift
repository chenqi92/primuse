import Foundation

/// Losing the system audio session says nothing about whether a song is playable.
public struct PlaybackAudioSessionFailure: Error, LocalizedError, Sendable {
    public let underlyingError: NSError

    public init(_ error: any Error) {
        underlyingError = error as NSError
    }

    public var errorDescription: String? { underlyingError.localizedDescription }
}

public enum PlaybackPipelineFailureAction: Equatable, Sendable {
    /// The result belongs to an older request and must not publish any state.
    case discardStaleResult
    /// Cancellation or unavailable audio ownership must not skip a healthy item.
    case preserveCurrentItem
    /// A current, non-cancellation failure may use normal queue recovery.
    case advanceAfterFailure
}

public enum PlaybackPipelineFailurePolicy {
    public static func action(
        requestIsCurrent: Bool,
        error: any Error
    ) -> PlaybackPipelineFailureAction {
        action(
            requestIsCurrent: requestIsCurrent,
            errorIsCancellation: OperationCancellationPolicy.isCancellation(error),
            errorIsAudioSessionFailure: error is PlaybackAudioSessionFailure
        )
    }

    public static func action(
        requestIsCurrent: Bool,
        errorIsCancellation: Bool,
        errorIsAudioSessionFailure: Bool = false
    ) -> PlaybackPipelineFailureAction {
        guard requestIsCurrent else { return .discardStaleResult }
        return errorIsCancellation || errorIsAudioSessionFailure
            ? .preserveCurrentItem : .advanceAfterFailure
    }
}

public enum SourceConfigurationInvalidationAction: Equatable, Sendable {
    case ignoreNonSecurityChange
    case invalidateSecurityScope
}

/// Source rows also carry display and scan-derived fields. Those changes must
/// not cancel an active transport unless the account/endpoint security scope
/// actually changed.
public enum SourceConfigurationInvalidationPolicy {
    public static func action(
        previousScopeFingerprint: String?,
        currentScopeFingerprint: String?
    ) -> SourceConfigurationInvalidationAction {
        guard previousScopeFingerprint == currentScopeFingerprint,
              previousScopeFingerprint != nil else {
            return .invalidateSecurityScope
        }
        return .ignoreNonSecurityChange
    }
}
