import Foundation

/// Decides whether MusicKit or Primuse owns the ordering for an Apple Music
/// item. Any item selected from Primuse's visible queue must remain
/// Primuse-managed, including queues made entirely of Apple Music songs.
public enum AppleMusicQueueOwnershipPolicy {
    public static func shouldUsePrimuseQueue(
        selectedQueueEntryMatches: Bool
    ) -> Bool {
        selectedQueueEntryMatches
    }
}

public struct AppleMusicSystemQueuePlan: Equatable, Sendable {
    public let retainedIndices: [Int]
    public let startIndex: Int

    public init(retainedIndices: [Int], startIndex: Int) {
        self.retainedIndices = retainedIndices
        self.startIndex = startIndex
    }
}

/// Keeps a subscription-independent library start from smuggling catalog-backed
/// entries into an `ApplicationMusicPlayer` queue after the catalog preflight
/// has intentionally been bypassed for that starting item.
public enum AppleMusicSystemQueuePolicy {
    public static func plan(
        startingItemID: String,
        startingSource: AppleMusicPlaybackSource,
        queuedItemIDs: [String],
        queuedSources: [AppleMusicPlaybackSource]
    ) -> AppleMusicSystemQueuePlan? {
        guard queuedItemIDs.count == queuedSources.count,
              let originalStartIndex = queuedItemIDs.firstIndex(of: startingItemID) else {
            return nil
        }

        let retainedIndices: [Int]
        if startingSource == .subscriptionIndependentUserLibrary {
            retainedIndices = queuedSources.indices.filter {
                queuedSources[$0] == .subscriptionIndependentUserLibrary
            }
        } else {
            retainedIndices = Array(queuedSources.indices)
        }

        guard let startIndex = retainedIndices.firstIndex(of: originalStartIndex) else {
            return nil
        }
        return AppleMusicSystemQueuePlan(
            retainedIndices: retainedIndices,
            startIndex: startIndex
        )
    }
}
