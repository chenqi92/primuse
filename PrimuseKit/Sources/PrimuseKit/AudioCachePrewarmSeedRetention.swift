import Foundation

/// Seeding writes roughly 1.25 MB of head and tail bytes. The write itself can
/// run off the main actor, but the path it writes to may be claimed by a
/// playback session while those bytes are in flight, so the seed needs a
/// post-write ownership verdict as well as the pre-write one.
public enum PrewarmSeedPublishAction: Equatable, Sendable {
    /// Nobody claimed the cache path while the bytes were written: the staged
    /// seed may be moved into place and the marker written.
    case publish
    /// A playback session, lease or use appeared. Only the prewarm's own
    /// staging file is removed — the file the session owns is never touched.
    case discardStagingOnly
}

extension AudioCachePrewarmSeedPolicy {
    /// Whether a seed that has just been written may stay on disk. The inputs
    /// are re-read after the write: any playback claim that appeared in the
    /// meantime owns the path, and the staged seed must not be published.
    public static func keepsSeedAfterWrite(
        isActiveSessionPath: Bool,
        activePlaybackUses: Int,
        hasPlaybackLease: Bool
    ) -> Bool {
        canReplaceSparseFile(
            isActiveSessionPath: isActiveSessionPath,
            activePlaybackUses: activePlaybackUses,
            hasPlaybackLease: hasPlaybackLease
        )
    }

    /// What to do with a staged seed once the bytes are on disk. A rejected
    /// seed is dropped by deleting the staging file only: the `.partial` a
    /// session claimed in the meantime belongs to that session.
    public static func publishAction(
        isActiveSessionPath: Bool,
        activePlaybackUses: Int,
        hasPlaybackLease: Bool
    ) -> PrewarmSeedPublishAction {
        keepsSeedAfterWrite(
            isActiveSessionPath: isActiveSessionPath,
            activePlaybackUses: activePlaybackUses,
            hasPlaybackLease: hasPlaybackLease
        ) ? .publish : .discardStagingOnly
    }

    /// Byte ranges a seed covers: the head at offset 0 and, when the file is
    /// long enough for the tail not to overlap it, the trailing range. The
    /// marker records exactly these ranges, so the arithmetic must match the
    /// bytes actually written.
    public static func seedRanges(
        headCount: Int64,
        tailCount: Int64,
        fileSize: Int64
    ) -> [[Int64]] {
        guard headCount > 0 else { return [] }
        var ranges: [[Int64]] = [[0, headCount]]
        guard tailCount > 0, fileSize > headCount else { return ranges }
        let tailOffset = fileSize - tailCount
        guard tailOffset >= headCount else { return ranges }
        ranges.append([tailOffset, fileSize])
        return ranges
    }
}
