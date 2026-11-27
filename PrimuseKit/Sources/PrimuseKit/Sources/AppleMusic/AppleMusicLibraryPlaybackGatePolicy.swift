import Foundation

/// Decides whether playback needs the complete Apple Music library cache.
/// A Primuse-managed queue hands MusicKit only the current DRM item, so a
/// direct lookup can start immediately while the full library keeps syncing.
public enum AppleMusicPlaybackCachePolicy {
    public static func requiresCompleteLibrarySnapshot(
        hasQueueContext: Bool,
        appleMusicItemCount: Int
    ) -> Bool {
        !hasQueueContext || appleMusicItemCount != 1
    }
}

/// Revalidates every condition that makes a user-library playback request
/// meaningful after a shared sync suspension.
public enum AppleMusicLibraryPlaybackGatePolicy {
    public static func canContinue(
        requestIsPending: Bool,
        isCancelled: Bool,
        syncEnabled: Bool,
        sourceInstalled: Bool,
        sourceEnabled: Bool,
        isAuthorized: Bool
    ) -> Bool {
        requestIsPending
            && !isCancelled
            && syncEnabled
            && sourceInstalled
            && sourceEnabled
            && isAuthorized
    }
}
