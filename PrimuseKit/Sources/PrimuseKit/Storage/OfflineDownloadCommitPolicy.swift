import Foundation

public enum OfflineDownloadCommitAction: Equatable, Sendable {
    /// Publish the downloaded artifact: manifest entry, snapshot, pin intent.
    case commit
    /// The request was cancelled after the bytes were installed. Nothing may be
    /// published, so no joiner can pin a file the canceller already deleted.
    case reportCancelled
}

/// Installing the canonical file and publishing it are separate steps with a
/// suspension between them. A removal that runs inside that window deletes the
/// file family and publishes "not cached"; the resumed transfer must not then
/// re-publish a downloaded — or worse, pinned — artifact for a file that no
/// longer exists.
public enum OfflineDownloadCommitPolicy {
    public static func commitsInstalledArtifact(
        isCancelled: Bool,
        installSucceeded: Bool
    ) -> OfflineDownloadCommitAction {
        guard installSucceeded, !isCancelled else { return .reportCancelled }
        return .commit
    }

    /// A waiter joins someone else's transfer. It may only pin an artifact the
    /// transfer actually completed, never a cancelled or failed one.
    public static func joinerPinsResult(
        resultIsCompleted: Bool,
        waiterIsCancelled: Bool
    ) -> Bool {
        resultIsCompleted && !waiterIsCancelled
    }
}
