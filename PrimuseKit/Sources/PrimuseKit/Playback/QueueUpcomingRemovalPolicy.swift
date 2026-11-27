import Foundation

public struct QueueTraversalRemovalResult: Equatable, Sendable {
    public let indices: [Int]
    public let currentPosition: Int

    public init(indices: [Int], currentPosition: Int) {
        self.indices = indices
        self.currentPosition = currentPosition
    }
}

public enum QueueUpcomingRemovalPolicy {
    /// Removing an entry only invalidates already-started successor preparation
    /// when that exact queue slot is the immediate successor. Song identity is
    /// deliberately insufficient because the same song may occupy several
    /// independent queue slots.
    public static func shouldCancelSuccessorPreparation(
        removing occurrence: QueueReorderOccurrenceID,
        immediateSuccessorQueueEntryID: UUID?
    ) -> Bool {
        occurrence.queueEntryID == immediateSuccessorQueueEntryID
    }

    public static func queueIndex(
        for occurrence: QueueReorderOccurrenceID,
        currentQueueEntryID: UUID,
        queueEntryIDs: [UUID],
        upcomingOccurrences: [QueueReorderOccurrenceID]
    ) -> Int? {
        guard occurrence.roundOffset >= 0,
              occurrence.queueEntryID != currentQueueEntryID,
              Set(queueEntryIDs).count == queueEntryIDs.count,
              Set(upcomingOccurrences).count == upcomingOccurrences.count,
              upcomingOccurrences.contains(occurrence) else { return nil }

        let queueEntryIDSet = Set(queueEntryIDs)
        guard upcomingOccurrences.allSatisfy({ queueEntryIDSet.contains($0.queueEntryID) }) else {
            return nil
        }
        return queueEntryIDs.firstIndex(of: occurrence.queueEntryID)
    }

    public static func rebasedIndices(
        _ indices: [Int],
        removingQueueIndex removalIndex: Int,
        queueCount: Int
    ) -> [Int]? {
        guard queueCount > 1,
              (0..<queueCount).contains(removalIndex),
              Set(indices).count == indices.count,
              indices.allSatisfy({ (0..<queueCount).contains($0) }),
              indices.contains(removalIndex) else { return nil }

        return indices.compactMap { index in
            guard index != removalIndex else { return nil }
            return index > removalIndex ? index - 1 : index
        }
    }

    public static func rebasedTraversal(
        _ indices: [Int],
        currentPosition: Int,
        removingQueueIndex removalIndex: Int,
        queueCount: Int
    ) -> QueueTraversalRemovalResult? {
        guard indices.indices.contains(currentPosition),
              let removalPosition = indices.firstIndex(of: removalIndex),
              removalPosition != currentPosition,
              let rebased = rebasedIndices(
                indices,
                removingQueueIndex: removalIndex,
                queueCount: queueCount
              ) else { return nil }

        let rebasedCurrentPosition = currentPosition - (removalPosition < currentPosition ? 1 : 0)
        guard rebased.indices.contains(rebasedCurrentPosition) else { return nil }
        return QueueTraversalRemovalResult(
            indices: rebased,
            currentPosition: rebasedCurrentPosition
        )
    }
}
