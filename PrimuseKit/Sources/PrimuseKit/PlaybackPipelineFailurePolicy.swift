import Foundation

public enum PlaybackPipelineFailureAction: Equatable, Sendable {
    /// The result belongs to an older request and must not publish any state.
    case discardStaleResult
    /// Cancellation is not evidence that the selected item is unplayable.
    case preserveCurrentItem
    /// A current, non-cancellation failure may use normal queue recovery.
    case advanceAfterFailure
}

public enum PlaybackPipelineFailurePolicy {
    public static func action(
        requestIsCurrent: Bool,
        errorIsCancellation: Bool
    ) -> PlaybackPipelineFailureAction {
        guard requestIsCurrent else { return .discardStaleResult }
        return errorIsCancellation ? .preserveCurrentItem : .advanceAfterFailure
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
