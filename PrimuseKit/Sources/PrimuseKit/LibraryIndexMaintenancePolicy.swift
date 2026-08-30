import Foundation

/// Pure scheduling and invalidation rules shared by the app's library indexes.
public enum LibraryIndexMaintenancePolicy {
    /// Metadata backfill can run for hours. Keep derived collections and
    /// Spotlight reasonably fresh without restarting a whole-library pass for
    /// every small persistence flush.
    public static let maximumDeferredMaintenanceInterval: TimeInterval = 60

    /// Values consumed by MusicLibrary's album/artist derivation and prepared
    /// visible caches. Technical metadata such as bitrate and sample rate
    /// deliberately stays out so it cannot schedule an unrelated regroup.
    public static func derivedCollectionsChanged(from old: Song, to new: Song) -> Bool {
        old.artistName != new.artistName
            || old.sourceArtistNames != new.sourceArtistNames
            || old.albumArtistName != new.albumArtistName
            || old.albumTitle != new.albumTitle
            || old.year != new.year
            || old.genre != new.genre
            || old.duration.bitPattern != new.duration.bitPattern
            || old.sourceID != new.sourceID
            || old.coverArtFileName != new.coverArtFileName
            || old.artistArtworkFileName != new.artistArtworkFileName
            || old.discNumber != new.discNumber
            || old.trackNumber != new.trackNumber
    }

    /// Incremental completion is safe only when it directly follows the last
    /// durable completion. A gap means a prior process may have exited before
    /// writing unknown rows, so only a full reconciliation can clear it.
    public static func canCompleteIncrementally(
        completedGeneration: Int,
        firstPendingGeneration: Int
    ) -> Bool {
        if completedGeneration == .max { return firstPendingGeneration == 1 }
        return firstPendingGeneration == completedGeneration + 1
    }
}

/// Compact latest-value set used by the persistent search index. Its size is
/// proportional to rows changed since the active transaction began, never to
/// the total library or the number of repeated publications.
public struct IncrementalLibrarySearchMutationState: Equatable, Sendable {
    public private(set) var upsertIDs: Set<String> = []
    public private(set) var deletingIDs: Set<String> = []

    public var isEmpty: Bool { upsertIDs.isEmpty && deletingIDs.isEmpty }
    public var touchedRowCount: Int { upsertIDs.count + deletingIDs.count }

    public init() {}

    public mutating func recordUpserts<S: Sequence>(_ ids: S) where S.Element == String {
        for id in ids {
            deletingIDs.remove(id)
            upsertIDs.insert(id)
        }
    }

    public mutating func recordDeletions<S: Sequence>(_ ids: S) where S.Element == String {
        for id in ids {
            upsertIDs.remove(id)
            deletingIDs.insert(id)
        }
    }
}

/// State machine for a cancellable worker that may have at most one active
/// request and one replaceable latest request.
public struct LatestOnlyLibraryIndexWorkState: Equatable, Sendable {
    public enum Submission: Equatable, Sendable {
        case start
        case replacePending
    }

    public private(set) var activeGeneration: Int?
    public private(set) var pendingGeneration: Int?

    public init() {}

    public mutating func submit(generation: Int) -> Submission {
        if activeGeneration == nil {
            activeGeneration = generation
            return .start
        }
        pendingGeneration = generation
        return .replacePending
    }

    /// Completes only the active request. Returns the latest pending generation
    /// that should start next, if one exists.
    public mutating func complete(generation: Int) -> Int? {
        guard activeGeneration == generation else { return nil }
        let next = pendingGeneration
        activeGeneration = next
        pendingGeneration = nil
        return next
    }
}
