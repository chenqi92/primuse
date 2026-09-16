import Foundation

/// What a catalogue source remembers between two passes so the next one can
/// ask "what changed" instead of re-reading every row.
public struct ServerCatalogSyncMarker: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// `stableSongCatalogRevision()` as of the last committed pass.
    public var catalogRevision: String
    /// Server-clock timestamp of the newest row this device has taken in. The
    /// next pass asks the server for everything saved at or after it, so the
    /// value has to come from the server's own timestamps — this device's
    /// clock may sit either side of the server's and would silently skip rows.
    public var modifiedSince: Date
    /// Rows the catalogue held at the last commit. A changed count is the
    /// cheapest possible proof that rows were added or removed.
    public var itemCount: Int

    public init(
        version: Int = Self.currentVersion,
        catalogRevision: String,
        modifiedSince: Date,
        itemCount: Int
    ) {
        self.version = version
        self.catalogRevision = catalogRevision
        self.modifiedSince = modifiedSince
        self.itemCount = itemCount
    }

    public var isUsable: Bool {
        version == Self.currentVersion && !catalogRevision.isEmpty && itemCount >= 0
    }
}

/// Decides when a catalogue source may answer a scan from the server's change
/// feed instead of walking the whole catalogue, and — the part that actually
/// matters — when such an answer is allowed to conclude that a row was deleted.
///
/// A "what changed since T" feed can only ever report rows that still exist.
/// A deleted row simply stops appearing, so no change feed can name it. The
/// only way to find one is to compare the complete set of ids the server has
/// against the set this device holds, which is why every conclusion about
/// deletion here is gated on having enumerated the catalogue's ids.
public enum ServerCatalogIncrementalSyncPolicy {
    /// A verified complete walk stays the backstop. An incremental answer is
    /// only ever as good as the server's own change reporting, so one complete
    /// walk is forced whenever the last one is this old.
    public static let completeWalkInterval: TimeInterval = 7 * 24 * 60 * 60

    /// The first watermark after a complete walk. The walk reads the catalogue
    /// but not each row's `DateLastSaved`, so the first incremental pass has to
    /// start from this device's clock, set back far enough to absorb ordinary
    /// skew against the server's. Asking for too much costs a little traffic;
    /// asking for too little would silently skip an edit.
    public static let initialWatermarkMargin: TimeInterval = 24 * 60 * 60

    /// The marker a completed walk leaves behind, or nil when the source
    /// cannot be asked incrementally next time.
    public static func seedMarker(
        catalogRevision: String?,
        itemCount: Int,
        now: Date = Date()
    ) -> ServerCatalogSyncMarker? {
        guard let catalogRevision, !catalogRevision.isEmpty, itemCount > 0 else { return nil }
        return ServerCatalogSyncMarker(
            catalogRevision: catalogRevision,
            modifiedSince: now.addingTimeInterval(-initialWatermarkMargin),
            itemCount: itemCount
        )
    }

    public enum Refusal: String, Equatable, Sendable {
        /// The user explicitly asked for a deep scan.
        case explicitDeepScan
        /// Nothing durable from a previous pass to compare against.
        case noUsableMarker
        /// A previous pass left the source needing a complete reconciliation.
        case deepScanRequired
        /// The periodic complete walk is due.
        case completeWalkDue
    }

    /// Why this pass may not run incrementally, or nil when it may.
    public static func refusal(
        mode: SourceSyncMode,
        marker: ServerCatalogSyncMarker?,
        lastFullScanAt: Date?,
        requiresDeepScan: Bool,
        now: Date = Date()
    ) -> Refusal? {
        if mode == .deep { return .explicitDeepScan }
        if requiresDeepScan { return .deepScanRequired }
        guard let marker, marker.isUsable else { return .noUsableMarker }
        guard let lastFullScanAt else { return .completeWalkDue }
        guard now.timeIntervalSince(lastFullScanAt) < completeWalkInterval else {
            return .completeWalkDue
        }
        return nil
    }

    /// True when the "modified since" answer cannot be read as a filtered one.
    /// A server that does not implement the parameter answers with its whole
    /// catalogue, which would look like "everything changed" rather than like
    /// an error. Treat that as unusable and let the complete walk handle it.
    public static func modifiedFilterLooksIgnored(
        modifiedCount: Int,
        totalCount: Int
    ) -> Bool {
        totalCount > 0 && modifiedCount >= totalCount
    }

    /// Whether this pass has to enumerate every remote id before it may decide
    /// anything about rows it did not see.
    ///
    /// The catalogue revision carries the per-library item counts, so an
    /// unchanged revision plus an unchanged count means no row entered or left
    /// — unless the change feed names a row this device has never seen, which
    /// proves one arrived, and therefore that one left to keep the count equal.
    public static func requiresCatalogEnumeration(
        previousRevision: String,
        currentRevision: String?,
        previousItemCount: Int,
        currentItemCount: Int,
        changedItemIDs: Set<String>,
        knownItemIDs: Set<String>
    ) -> Bool {
        guard let currentRevision, currentRevision == previousRevision else { return true }
        guard currentItemCount == previousItemCount else { return true }
        return !changedItemIDs.isSubset(of: knownItemIDs)
    }

    /// Song ids the catalogue still contains, for the deletion reconciliation.
    ///
    /// `remoteItemIDs` is the complete id listing when this pass enumerated
    /// one. Pass nil when it did not: the result is then every row this device
    /// already had plus whatever was just fetched, which reconciles to "nothing
    /// was removed" rather than to "everything absent is gone".
    public static func authoritativeSongIDs(
        knownSongIDsByItemID: [String: String],
        remoteItemIDs: Set<String>?,
        fetchedSongIDs: Set<String>
    ) -> Set<String> {
        var result = fetchedSongIDs
        for (itemID, songID) in knownSongIDsByItemID {
            guard remoteItemIDs?.contains(itemID) ?? true else { continue }
            result.insert(songID)
        }
        return result
    }

    /// Item ids whose rows must be fetched in full: everything the change feed
    /// named, plus anything the id listing revealed that this device has never
    /// seen. The second half matters when a server reports a creation without
    /// also reporting it as a change.
    public static func itemIDsNeedingFetch(
        changedItemIDs: Set<String>,
        remoteItemIDs: Set<String>?,
        knownItemIDs: Set<String>
    ) -> Set<String> {
        var result = changedItemIDs
        if let remoteItemIDs {
            result.formUnion(remoteItemIDs.subtracting(knownItemIDs))
            // A row the change feed named but the catalogue no longer lists
            // was removed between the two requests; there is nothing to fetch.
            result.formIntersection(remoteItemIDs)
        }
        return result
    }
}
