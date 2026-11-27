import Foundation

/// Controls when a newly configured source is allowed to become durable.
/// Credential-backed filesystem endpoints must be exercised by the directory
/// browser before an empty or unauthenticated source can enter the library.
public enum SourceCreationPersistencePolicy {
    public enum CancellationDisposition: Equatable, Sendable {
        case discardUncommittedDraft
        case preservePersistedSource
    }

    public static func defersUntilValidatedDirectorySelection(
        for sourceType: MusicSourceType
    ) -> Bool {
        sourceType == .smb || sourceType == .webdav || sourceType == .infiniCloud
    }

    public static func canCommitDeferredCreation(
        for sourceType: MusicSourceType,
        connectionValidated: Bool,
        selectedDirectories: [String]
    ) -> Bool {
        guard defersUntilValidatedDirectorySelection(for: sourceType) else {
            return true
        }
        return connectionValidated && !selectedDirectories.isEmpty
    }

    public static func cancellationDisposition(
        wasPersistedBeforeFlow: Bool,
        wasCommittedDuringFlow: Bool
    ) -> CancellationDisposition {
        if !wasPersistedBeforeFlow && !wasCommittedDuringFlow {
            return .discardUncommittedDraft
        }
        return .preservePersistedSource
    }
}
