import Foundation

/// The orphan set is measured by a directory walk that runs while the app keeps
/// running: a source can be re-added under the same id before the walk returns,
/// and a transfer can still own bytes inside an orphaned tree. Both must be
/// excluded from the purge; an in-flight transfer is only purgeable once the
/// caller has cancelled it, which is why cancellation happens before this
/// decision is taken.
public enum OrphanedSourceCachePurgePolicy {
    public static func sourceIDsToPurge(
        observedOrphans: Set<String>,
        liveSourceIDs: Set<String>,
        sourceIDsWithInFlightTransfers: Set<String>
    ) -> Set<String> {
        observedOrphans
            .subtracting(liveSourceIDs)
            .subtracting(sourceIDsWithInFlightTransfers)
    }
}
