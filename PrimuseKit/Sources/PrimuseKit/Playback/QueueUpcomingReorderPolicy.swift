import Foundation

/// Stable identity carried by a queue-row drag. `queueEntryID` identifies the
/// exact queue slot (not merely its Song), while `roundOffset` disambiguates a
/// slot that repeat-all presents again in the next shuffle round.
public struct QueueReorderOccurrenceID: Hashable, Sendable {
    private static let payloadPrefix = "primuse.queue-entry"

    public let queueEntryID: UUID
    public let roundOffset: Int

    public init(queueEntryID: UUID, roundOffset: Int) {
        self.queueEntryID = queueEntryID
        self.roundOffset = roundOffset
    }

    public var dragPayload: String {
        "\(Self.payloadPrefix)|\(queueEntryID.uuidString)|\(roundOffset)"
    }

    public init?(dragPayload: String) {
        let fields = dragPayload.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 3,
              fields[0] == Substring(Self.payloadPrefix),
              let queueEntryID = UUID(uuidString: String(fields[1])),
              let roundOffset = Int(fields[2]),
              roundOffset >= 0 else { return nil }
        self.init(queueEntryID: queueEntryID, roundOffset: roundOffset)
    }
}

/// Resolves a drop against the latest Up Next snapshot. Dropping a row over a
/// row above it inserts before the target; dropping over a row below it inserts
/// after the target. This makes either drag direction reach the edge position
/// while keeping played/current entries outside the mutation boundary.
public enum QueueUpcomingReorderPolicy {
    public static func reorderedOccurrences(
        dragging dragged: QueueReorderOccurrenceID,
        over target: QueueReorderOccurrenceID,
        queueEntryIDs: [UUID],
        upcomingOccurrences: [QueueReorderOccurrenceID]
    ) -> [QueueReorderOccurrenceID]? {
        guard dragged != target,
              dragged.roundOffset >= 0,
              dragged.roundOffset == target.roundOffset,
              Set(queueEntryIDs).count == queueEntryIDs.count,
              Set(upcomingOccurrences).count == upcomingOccurrences.count else { return nil }

        let queueEntryIDSet = Set(queueEntryIDs)
        guard upcomingOccurrences.allSatisfy({ queueEntryIDSet.contains($0.queueEntryID) }),
              let sourceIndex = upcomingOccurrences.firstIndex(of: dragged),
              let targetIndex = upcomingOccurrences.firstIndex(of: target) else { return nil }

        var reordered = upcomingOccurrences
        let moved = reordered.remove(at: sourceIndex)
        // `targetIndex` is still the correct insertion offset after removing a
        // preceding source (insert after target), and means "before target"
        // when removing a later source.
        reordered.insert(moved, at: targetIndex)
        return reordered == upcomingOccurrences ? nil : reordered
    }

    /// Gapless and crossfade preparation only owns the first upcoming
    /// occurrence. Reordering later rows can keep that work intact; replacing
    /// the first occurrence must discard it without touching the current
    /// transport or its natural-end ticket.
    public static func shouldInvalidatePreparedSuccessor(
        before currentUpcoming: [QueueReorderOccurrenceID],
        after reorderedUpcoming: [QueueReorderOccurrenceID]
    ) -> Bool {
        currentUpcoming.first != reorderedUpcoming.first
    }
}
