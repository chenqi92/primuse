import Foundation

/// How much a completed catalogue observation is allowed to conclude about
/// rows it did not see.
public enum CatalogDeletionAuthority: String, Sendable, Equatable, Codable {
    /// A complete walk is authoritative on its own: anything absent is gone.
    /// File-oriented sources and media servers that enumerate by stable item
    /// identity belong here.
    case authoritative
    /// A complete snapshot is evidence, not authority. Absence has to be
    /// witnessed by several distinct catalogue revisions before a row may be
    /// removed.
    case confirmationRequired
    /// A degraded, partial or compatibility listing. It may merge rows but
    /// must never remove them.
    case never
}

/// Turns repeated "this song was not in the complete catalogue" observations
/// into an actual deletion decision.
///
/// Subsonic-family servers cannot express an immutable snapshot of what one
/// account may see: `getScanStatus.lastScan|count` describes the server-wide
/// scanner, so a permission change, a library remount or a mid-flight re-index
/// can shift every `search3` page without changing that marker. A single
/// complete walk is therefore not allowed to delete. Two walks that observed
/// the same absence under *different* catalogue revisions are, because the
/// server state provably moved on between them and the row still did not come
/// back.
public enum ServerCatalogDeletionConfirmationPolicy {
    /// Witnesses required before an absent row is removed.
    public static let requiredWitnessCount = 2
    /// A pass that loses this share of the source's rows at once is treated as
    /// suspicious and needs an extra witness.
    public static let massDisappearanceRatio = 0.2
    /// Small libraries lose a large share on ordinary edits, so the ratio only
    /// applies once the absolute loss is meaningful too.
    public static let massDisappearanceFloor = 50
    /// Witnesses required for rows that disappeared in a suspicious pass.
    public static let massDisappearanceWitnessCount = 3

    /// How many complete observations must agree before an absent row may be
    /// removed. `nil` means "never remove it from this kind of listing".
    ///
    /// An authoritative snapshot decides on its own, but a pass that lost a
    /// suspicious share of the source still has to be repeated — an unmounted
    /// library reads exactly like a bulk deletion, and that is the one case
    /// where being wrong costs the user their playlists.
    public static func requiredWitnesses(
        for authority: CatalogDeletionAuthority,
        isMassDisappearance: Bool
    ) -> Int? {
        switch authority {
        case .never:
            return nil
        case .authoritative:
            return isMassDisappearance ? massDisappearanceWitnessCount : 1
        case .confirmationRequired:
            return isMassDisappearance ? massDisappearanceWitnessCount : requiredWitnessCount
        }
    }

    public struct Plan: Sendable, Equatable {
        /// Rows that may be removed from the library now.
        public var confirmedDeletionSongIDs: Set<String>
        /// Updated per-song witness counts, to be persisted on the sync state.
        public var missingCounts: [String: Int]
        /// Revision that produced this observation, persisted so the next pass
        /// can tell a new server state from a re-read of the same one.
        public var evidenceRevision: String?
        /// Rows observed as absent that are still short of their witness bar.
        public var pendingSongIDs: Set<String>
        /// True when this pass lost a suspiciously large share of the source.
        public var isMassDisappearance: Bool

        public init(
            confirmedDeletionSongIDs: Set<String> = [],
            missingCounts: [String: Int] = [:],
            evidenceRevision: String? = nil,
            pendingSongIDs: Set<String> = [],
            isMassDisappearance: Bool = false
        ) {
            self.confirmedDeletionSongIDs = confirmedDeletionSongIDs
            self.missingCounts = missingCounts
            self.evidenceRevision = evidenceRevision
            self.pendingSongIDs = pendingSongIDs
            self.isMassDisappearance = isMassDisappearance
        }

        public var hasPendingConfirmations: Bool { !pendingSongIDs.isEmpty }
    }

    /// - Parameters:
    ///   - existingSongIDs: library rows currently attributed to this source.
    ///   - authoritativeSongIDs: every song id in the verified complete snapshot.
    ///   - previousMissingCounts: witness counts carried on the sync state.
    ///   - previousEvidenceRevision: revision that produced the newest counts.
    ///   - currentRevision: revision of this snapshot. `nil` for servers that
    ///     expose no scan marker; each complete walk then counts on its own,
    ///     which is still two full catalogue transfers apart.
    ///   - authority: how much this listing may conclude about rows it did not
    ///     see. Defaults to the conservative bar.
    public static func plan(
        existingSongIDs: Set<String>,
        authoritativeSongIDs: Set<String>,
        previousMissingCounts: [String: Int],
        previousEvidenceRevision: String?,
        currentRevision: String?,
        authority: CatalogDeletionAuthority = .confirmationRequired
    ) -> Plan {
        let missing = existingSongIDs.subtracting(authoritativeSongIDs)
        guard !missing.isEmpty else {
            // Nothing is absent, so no evidence is carried forward. Rows that
            // came back clear their history along with it.
            return Plan(evidenceRevision: currentRevision)
        }

        // The same revision re-read is the same observation. Counting it twice
        // would let one retry loop delete rows on its own.
        let isRepeatedObservation = currentRevision != nil
            && currentRevision == previousEvidenceRevision

        let isMassDisappearance = missing.count >= massDisappearanceFloor
            && Double(missing.count) >= Double(existingSongIDs.count) * massDisappearanceRatio
        let witnessBar = requiredWitnesses(
            for: authority,
            isMassDisappearance: isMassDisappearance
        )

        var counts: [String: Int] = [:]
        counts.reserveCapacity(missing.count)
        var confirmed: Set<String> = []
        var pending: Set<String> = []
        for songID in missing {
            let previous = previousMissingCounts[songID] ?? 0
            let witnesses = isRepeatedObservation ? max(previous, 1) : previous + 1
            counts[songID] = witnesses
            if let witnessBar, witnesses >= witnessBar {
                confirmed.insert(songID)
            } else {
                pending.insert(songID)
            }
        }

        return Plan(
            confirmedDeletionSongIDs: confirmed,
            missingCounts: counts,
            evidenceRevision: currentRevision,
            pendingSongIDs: pending,
            isMassDisappearance: isMassDisappearance
        )
    }

    /// Song ids the library must keep even though the snapshot did not contain
    /// them. Feeding this to the authoritative-prune path removes exactly the
    /// confirmed rows and nothing else.
    public static func retainedAuthoritativeSongIDs(
        existingSongIDs: Set<String>,
        authoritativeSongIDs: Set<String>,
        confirmedDeletionSongIDs: Set<String>
    ) -> Set<String> {
        authoritativeSongIDs
            .union(existingSongIDs.subtracting(confirmedDeletionSongIDs))
    }
}
