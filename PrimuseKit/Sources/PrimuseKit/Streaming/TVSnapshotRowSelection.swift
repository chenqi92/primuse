import Foundation

/// One `songs` row of an incoming Apple TV snapshot, reduced to the two fields
/// the install's scope rule looks at.
public struct TVSnapshotIncomingRow: Sendable, Equatable {
    /// `id` of the row, or `nil` when the payload omits it.
    public let id: String?
    /// `sourceID` of the row, or `nil` when the payload omits it.
    public let sourceID: String?

    public init(id: String?, sourceID: String?) {
        self.id = id
        self.sourceID = sourceID
    }
}

/// A song this device scanned itself and wants to keep across a snapshot
/// install.
public struct TVSnapshotLocalSong: Sendable, Equatable {
    public let id: String
    public let sourceID: String

    public init(id: String, sourceID: String) {
        self.id = id
        self.sourceID = sourceID
    }
}

/// Which rows of an incoming snapshot survive the install, and which locally
/// scanned songs are appended back to them.
///
/// A snapshot describes the sending device's whole library. Rows whose
/// `sourceID` is not in the merged source list cannot be played here, so they
/// are dropped. Over LAN that is a hard error: the payload is supposed to be
/// complete, and a partial one would silently shrink the library, so the whole
/// install is refused. A cloud snapshot is allowed to be partial (the account's
/// record may predate a source removal), so the unknown rows are simply
/// dropped.
///
/// Songs this device scanned itself are not in the sender's payload at all.
/// They are appended after the surviving rows when they are still backed by a
/// known source and the payload does not already carry the same id.
///
/// When nothing is dropped and nothing has to be appended, the caller keeps the
/// snapshot bytes exactly as they arrived instead of re-encoding them.
public enum TVSnapshotRowSelection {
    public struct Outcome: Sendable, Equatable {
        /// Indices into `incomingRows` that stay, in their original order.
        public let keptIncomingIndices: [Int]
        /// Indices into `retainedSongIDs` that are appended, in their original
        /// order. Always empty when `requiresRewrite` is `false`.
        public let retainedLocalIndices: [Int]
        /// Whether the `songs` array has to be rebuilt and re-encoded.
        public let requiresRewrite: Bool

        public init(keptIncomingIndices: [Int], retainedLocalIndices: [Int], requiresRewrite: Bool) {
            self.keptIncomingIndices = keptIncomingIndices
            self.retainedLocalIndices = retainedLocalIndices
            self.requiresRewrite = requiresRewrite
        }
    }

    /// - Parameters:
    ///   - incomingRows: the payload's `songs` rows, in payload order.
    ///   - knownSourceIDs: ids of the sources that exist after the incoming and
    ///     local source lists are merged.
    ///   - retainedSongIDs: songs scanned on this device that the caller wants
    ///     to survive the install.
    ///   - fromCloud: `true` for a CloudKit snapshot, which may legitimately
    ///     reference sources this device no longer has.
    /// - Returns: `nil` when a LAN payload references an unknown source, which
    ///   means the install must be refused wholesale.
    public static func select(
        incomingRows: [TVSnapshotIncomingRow],
        knownSourceIDs: Set<String>,
        retainedSongIDs: [TVSnapshotLocalSong],
        fromCloud: Bool
    ) -> Outcome? {
        let kept = incomingRows.indices.filter { index in
            guard let sourceID = incomingRows[index].sourceID else { return false }
            return knownSourceIDs.contains(sourceID)
        }
        guard fromCloud || kept.count == incomingRows.count else { return nil }
        guard !retainedSongIDs.isEmpty || kept.count != incomingRows.count else {
            return Outcome(keptIncomingIndices: kept, retainedLocalIndices: [], requiresRewrite: false)
        }
        let keptIDs = Set(kept.compactMap { incomingRows[$0].id })
        let retained = retainedSongIDs.indices.filter { index in
            let song = retainedSongIDs[index]
            return !keptIDs.contains(song.id) && knownSourceIDs.contains(song.sourceID)
        }
        return Outcome(keptIncomingIndices: kept, retainedLocalIndices: retained, requiresRewrite: true)
    }
}
