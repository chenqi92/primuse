import Foundation

public enum PlaybackLibraryMutationEvent: Equatable, Sendable {
    /// A filtered/searchable view of the library changed. This is never proof
    /// that a song or its source was durably removed.
    case presentationChanged
    /// The library confirmed that these song records were removed.
    case songsRemoved(Set<String>)
}

public enum PlaybackLibraryMutationAction: Equatable, Sendable {
    case ignore
    case removeSongs(Set<String>)
}

/// Separates transient library presentation updates from durable mutations.
/// Playback may only prune its queue after an authoritative removal event, and
/// only for IDs that are still active when the event is handled.
public enum PlaybackLibraryMutationPolicy {
    public static func action(
        queueSongIDs: [String],
        currentSongID: String?,
        isLiveRadio: Bool,
        event: PlaybackLibraryMutationEvent
    ) -> PlaybackLibraryMutationAction {
        guard !isLiveRadio else { return .ignore }

        switch event {
        case .presentationChanged:
            return .ignore
        case let .songsRemoved(removedSongIDs):
            guard !removedSongIDs.isEmpty else { return .ignore }
            var activeSongIDs = Set(queueSongIDs)
            if let currentSongID {
                activeSongIDs.insert(currentSongID)
            }
            let relevantSongIDs = removedSongIDs.intersection(activeSongIDs)
            return relevantSongIDs.isEmpty ? .ignore : .removeSongs(relevantSongIDs)
        }
    }
}

public struct QueueBatchRemovalPlan: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case unchanged
        case replaceQueue(startAt: Int)
        case playReplacement(startAt: Int)
        case stopAndClearQueue
    }

    /// Indices in the original queue that survive the removal, in queue order.
    public let retainedIndices: [Int]
    public let action: Action

    public init(retainedIndices: [Int], action: Action) {
        self.retainedIndices = retainedIndices
        self.action = action
    }
}

/// Plans a queue mutation before songs are removed from the library or source.
/// The active decoder must never be left on a song whose record or source file
/// is about to disappear, and deleting consecutive queue rows must skip the
/// whole removed run rather than advancing only once.
public enum QueueBatchRemovalPolicy {
    public static func plan(
        queueSongIDs: [String],
        currentIndex: Int,
        currentSongID: String?,
        removingSongIDs: Set<String>
    ) -> QueueBatchRemovalPlan {
        guard !removingSongIDs.isEmpty else {
            return QueueBatchRemovalPlan(
                retainedIndices: Array(queueSongIDs.indices),
                action: .unchanged
            )
        }

        let retainedIndices = queueSongIDs.indices.filter {
            !removingSongIDs.contains(queueSongIDs[$0])
        }
        guard retainedIndices.count != queueSongIDs.count else {
            return QueueBatchRemovalPlan(
                retainedIndices: retainedIndices,
                action: .unchanged
            )
        }

        if let currentSongID, removingSongIDs.contains(currentSongID) {
            guard !retainedIndices.isEmpty else {
                return QueueBatchRemovalPlan(
                    retainedIndices: [],
                    action: .stopAndClearQueue
                )
            }

            let replacementOriginalIndex = retainedIndices.first(where: { $0 > currentIndex })
                ?? retainedIndices[0]
            let replacementIndex = retainedIndices.firstIndex(of: replacementOriginalIndex) ?? 0
            return QueueBatchRemovalPlan(
                retainedIndices: retainedIndices,
                action: .playReplacement(startAt: replacementIndex)
            )
        }

        guard !retainedIndices.isEmpty else {
            // The active song is outside the canonical queue. Clear only the
            // removed queue rows and let that independent playback continue.
            return QueueBatchRemovalPlan(
                retainedIndices: [],
                action: .replaceQueue(startAt: 0)
            )
        }

        let currentOriginalIndex: Int? = {
            guard let currentSongID else { return nil }
            if queueSongIDs.indices.contains(currentIndex),
               queueSongIDs[currentIndex] == currentSongID,
               retainedIndices.contains(currentIndex) {
                return currentIndex
            }
            return retainedIndices.first(where: { queueSongIDs[$0] == currentSongID })
        }()

        let retainedCurrentIndex: Int
        if let currentOriginalIndex,
           let resolved = retainedIndices.firstIndex(of: currentOriginalIndex) {
            retainedCurrentIndex = resolved
        } else {
            retainedCurrentIndex = min(
                retainedIndices.filter { $0 < currentIndex }.count,
                retainedIndices.count - 1
            )
        }

        return QueueBatchRemovalPlan(
            retainedIndices: retainedIndices,
            action: .replaceQueue(startAt: retainedCurrentIndex)
        )
    }
}
