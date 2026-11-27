import Foundation

public enum ScanDirectoryFailureDisposition: Equatable, Sendable {
    case retainForResume
    case discardMissingChild
    case failMissingRoot
}

/// A selected root disappearing requires user action. A child remembered by
/// an older checkpoint can simply be dropped from that queue, while unknown
/// or transient failures remain resumable.
public enum ScanDirectoryFailurePolicy {
    public static func disposition(
        isMissingPath: Bool,
        isSelectedRoot: Bool
    ) -> ScanDirectoryFailureDisposition {
        guard isMissingPath else { return .retainForResume }
        return isSelectedRoot ? .failMissingRoot : .discardMissingChild
    }
}
