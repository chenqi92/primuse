import Foundation

/// Cancellation stops the current worker generation. It must not consume a
/// transient retry or park a song as though the source had failed.
public enum MetadataBackfillRetryPolicy {
    public static let maximumAutomaticAttempts = 5

    public static func shouldCountTransientFailure(
        isCancellation: Bool,
        isTransient: Bool
    ) -> Bool {
        isTransient && !isCancellation
    }

    public static func attemptCountAfterFailure(currentCount: Int) -> Int {
        min(maximumAutomaticAttempts, max(0, currentCount) + 1)
    }

    public static func hasExhaustedAutomaticAttempts(_ count: Int) -> Bool {
        count >= maximumAutomaticAttempts
    }
}

/// A successful catalogue scan is a bounded source-availability signal. It may
/// renew an exhausted source-wide retry budget when unresolved tag work still
/// exists, but it must not erase a partially consumed budget on every routine
/// scan.
public enum MetadataBackfillSourceRecoveryPolicy {
    public static func shouldRenewRetryBudget(
        sourceAttemptCount: Int,
        unresolvedSongCount: Int
    ) -> Bool {
        unresolvedSongCount > 0
            && MetadataBackfillRetryPolicy.hasExhaustedAutomaticAttempts(
                sourceAttemptCount
            )
    }
}

public enum MetadataBackfillDeferredRetryCause: Sendable, Equatable {
    case sourceUnavailable
    case repeatedSnapshot
}

public enum MetadataBackfillDeferredRetryPolicy {
    /// Source-level circuit breaking may pause a whole snapshot in memory, but
    /// persisting every member makes one failed request look like hundreds of
    /// failed songs on the next launch. Persist only the request that actually
    /// failed; a generic repeated-snapshot guard is session-only.
    public static func idsToPersist(
        failedSongID: String?,
        snapshotSongIDs: Set<String>,
        cause: MetadataBackfillDeferredRetryCause
    ) -> Set<String> {
        switch cause {
        case .sourceUnavailable:
            guard let failedSongID,
                  snapshotSongIDs.contains(failedSongID) else { return [] }
            return [failedSongID]
        case .repeatedSnapshot:
            return []
        }
    }
}
