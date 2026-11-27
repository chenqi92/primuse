import Foundation

/// Separates an unresolved asynchronous projection from a confirmed empty
/// result. Views that derive content off the main actor must not present their
/// empty state until that first derivation has completed.
public enum DeferredContentPresentationState: Equatable, Sendable {
    case loading
    case content
    case empty
}

public enum DeferredContentPresentationPolicy {
    public static func resolve(
        isPrepared: Bool,
        hasContent: Bool
    ) -> DeferredContentPresentationState {
        guard isPrepared else { return .loading }
        return hasContent ? .content : .empty
    }
}
