import Foundation

public struct SourceCacheActivityPresentation: Equatable, Sendable {
    public let isPreparingCurrentSource: Bool
    public let isCachingCurrentSource: Bool
    public let isBlockedByAnotherSource: Bool

    public var isCurrentSourceBusy: Bool {
        isPreparingCurrentSource || isCachingCurrentSource
    }
}

/// Keeps an explicit "cache this source" operation separate from incidental
/// per-song downloads started by playback, seeking, casting, or prewarming.
/// Only the explicit batch IDs and the source screen's locally tracked run are
/// allowed to present whole-source progress.
public enum SourceCachePresentationPolicy {
    public static func resolve(
        sourceID: String,
        preparingSourceID: String?,
        locallyTrackedBatchSourceID: String?,
        activeBatchSourceIDs: Set<String>
    ) -> SourceCacheActivityPresentation {
        SourceCacheActivityPresentation(
            isPreparingCurrentSource: preparingSourceID == sourceID,
            isCachingCurrentSource: locallyTrackedBatchSourceID == sourceID
                || activeBatchSourceIDs.contains(sourceID),
            isBlockedByAnotherSource: (preparingSourceID != nil && preparingSourceID != sourceID)
                || (locallyTrackedBatchSourceID != nil && locallyTrackedBatchSourceID != sourceID)
                || activeBatchSourceIDs.contains { $0 != sourceID }
        )
    }
}
