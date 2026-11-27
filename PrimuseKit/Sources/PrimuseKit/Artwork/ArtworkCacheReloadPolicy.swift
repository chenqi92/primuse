import Foundation

/// Decides whether a visible artwork placeholder should retry after another
/// surface persists artwork for the same song. Successful images stay put;
/// explicit artwork replacement uses the separate invalidation notification.
public enum ArtworkCacheReloadPolicy {
    public static func shouldReload(
        cachedSongID: String?,
        displayedSongID: String?,
        hasResolvedImage: Bool
    ) -> Bool {
        guard !hasResolvedImage,
              let cachedSongID,
              !cachedSongID.isEmpty,
              let displayedSongID,
              !displayedSongID.isEmpty else {
            return false
        }
        return cachedSongID == displayedSongID
    }
}
