import Foundation

/// User-visible execution state for metadata backfill. Pending work is kept
/// separate from active work so a deferred queue never presents itself as a
/// running spinner.
public enum MetadataBackfillActivityState: Equatable, Sendable {
    case idle
    case running
    case retrying
    case waitingForWiFi
    case pending
    case retryPending

    public static func resolve(
        hasPendingWork: Bool,
        isRunning: Bool,
        isWaitingForWiFi: Bool,
        hasDeferredRetryWork: Bool = false
    ) -> Self {
        if isRunning, hasPendingWork {
            return hasDeferredRetryWork ? .retrying : .running
        }
        guard hasPendingWork || hasDeferredRetryWork else { return .idle }
        if hasPendingWork, isWaitingForWiFi { return .waitingForWiFi }
        // A few deferred requests must not relabel hundreds of untouched,
        // normally eligible rows as though the whole source had paused.
        if hasPendingWork { return .pending }
        return hasDeferredRetryWork ? .retryPending : .idle
    }
}

/// Stops a background metadata session after a complete round produces no
/// observable progress. The songs remain eligible on the next launch; parking
/// only suppresses an endless spinner and repeated network work in this run.
public enum MetadataBackfillStallPolicy {
    public static func shouldParkRepeatedSnapshot(
        previousIDs: Set<String>,
        currentIDs: Set<String>
    ) -> Bool {
        !previousIDs.isEmpty
            && previousIDs == currentIDs
    }
}
