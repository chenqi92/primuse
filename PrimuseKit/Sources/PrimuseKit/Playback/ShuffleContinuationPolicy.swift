import Foundation

/// Picks songs that may extend an exhausted shuffle round. Existing queue IDs
/// and duplicates in the library snapshot are excluded so an expansion never
/// immediately replays the just-finished track or inflates the queue.
public enum ShuffleContinuationPolicy {
    public static func candidateIDs(
        queueIDs: [String],
        libraryIDs: [String],
        currentID: String?
    ) -> [String] {
        var excluded = Set(queueIDs)
        if let currentID { excluded.insert(currentID) }
        var emitted = Set<String>()
        return libraryIDs.filter { id in
            !id.isEmpty && !excluded.contains(id) && emitted.insert(id).inserted
        }
    }
}
