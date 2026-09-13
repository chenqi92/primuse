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
    /// Cancellation, audio ownership or a local asset requiring user action
    /// must preserve the selected item.
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
            errorIsAudioSessionFailure: error is PlaybackAudioSessionFailure,
            errorRequiresUserAction: error is AppleMusicLocalAssetError
        )
    }

    public static func action(
        requestIsCurrent: Bool,
        errorIsCancellation: Bool,
        errorIsAudioSessionFailure: Bool = false,
        errorRequiresUserAction: Bool = false
    ) -> PlaybackPipelineFailureAction {
        guard requestIsCurrent else { return .discardStaleResult }
        return errorIsCancellation || errorIsAudioSessionFailure || errorRequiresUserAction
            ? .preserveCurrentItem : .advanceAfterFailure
    }
}

public enum SourceConfigurationInvalidationAction: Equatable, Sendable {
    case ignoreNonSecurityChange
    /// The account and the content root are unchanged; only the addresses that
    /// reach them differ. Connectors must be rebuilt on the new route list, but
    /// the active transport and the trusted offline bytes stay valid.
    case rebuildRoutesOnly
    case invalidateSecurityScope
}

/// Source rows also carry display and scan-derived fields. Those changes must
/// not cancel an active transport unless the account/endpoint security scope
/// actually changed.
public enum SourceConfigurationInvalidationPolicy {
    public static func action(
        previousScopeFingerprint: String?,
        currentScopeFingerprint: String?,
        previousCredentialScopeFingerprint: String? = nil,
        currentCredentialScopeFingerprint: String? = nil
    ) -> SourceConfigurationInvalidationAction {
        if previousScopeFingerprint == currentScopeFingerprint,
           previousScopeFingerprint != nil {
            return .ignoreNonSecurityChange
        }
        // Both credential fingerprints must be known before a mismatch can be
        // attributed to routing alone. A missing one (older state, unreadable
        // revision file) keeps the fail-closed answer.
        if let previousCredentialScopeFingerprint,
           let currentCredentialScopeFingerprint,
           previousCredentialScopeFingerprint == currentCredentialScopeFingerprint {
            return .rebuildRoutesOnly
        }
        return .invalidateSecurityScope
    }
}
