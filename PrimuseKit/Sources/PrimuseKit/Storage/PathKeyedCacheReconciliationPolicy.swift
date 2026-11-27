import Foundation

public enum PathKeyedCacheReconciliationPlan: Equatable, Sendable {
    case skip
    case migrate
    case invalidate
}

/// A relocated library moves path-keyed cache objects to their new name.
/// `SourceStableCacheFileMigration.migrateCompletedFile` also removes the
/// transfer fragments beside the destination, so a migration must not run
/// while a download, a background cache task, a playback use or a streaming
/// session owns the destination path — those bytes belong to the newer writer.
public enum PathKeyedCacheReconciliationPolicy {
    public static func plan(
        decision: SourceStableCacheTransitionDecision,
        hasInFlightOfflineDownloadAtDestination: Bool,
        hasInFlightBackgroundCacheForSong: Bool,
        hasActivePlaybackUseAtDestination: Bool,
        hasActiveStreamingSessionAtDestination: Bool
    ) -> PathKeyedCacheReconciliationPlan {
        switch decision {
        case .none:
            return .skip
        case .invalidate:
            // Only the previous path is deleted, so destination ownership is
            // irrelevant here.
            return .invalidate
        case .migrate:
            let destinationIsInUse = hasInFlightOfflineDownloadAtDestination
                || hasInFlightBackgroundCacheForSong
                || hasActivePlaybackUseAtDestination
                || hasActiveStreamingSessionAtDestination
            return destinationIsInUse ? .skip : .migrate
        }
    }
}
