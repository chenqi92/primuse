import Foundation
import GRDB

public struct SubsonicCatalogResumeState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var pageSize: Int
    public var stageSessionID: String?
    public var catalogRevision: String?
    public var nextOffset: Int?
    public var completedPageCount: Int
    public var stagedSongCount: Int
    public var stagedItemCount: Int?
    public var firstPageItemIDs: [String]
    /// Retained only to decode v1 checkpoints. v2 stores duplicate receipts in
    /// SQLite and writes this as an empty set, keeping checkpoint size bounded.
    public var seenItemIDs: Set<String>
    /// Set once a drift-tolerant walk re-anchored on a moved catalogue. Its
    /// result may then only add and update rows, even after a relaunch.
    public var observedCatalogDrift: Bool?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        pageSize: Int = SubsonicCatalogPagingPolicy.pageSize,
        stageSessionID: String? = nil,
        catalogRevision: String?,
        nextOffset: Int?,
        completedPageCount: Int,
        stagedSongCount: Int,
        stagedItemCount: Int? = nil,
        firstPageItemIDs: [String],
        seenItemIDs: Set<String> = [],
        observedCatalogDrift: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.pageSize = pageSize
        self.stageSessionID = stageSessionID
        self.catalogRevision = catalogRevision
        self.nextOffset = nextOffset
        self.completedPageCount = completedPageCount
        self.stagedSongCount = stagedSongCount
        self.stagedItemCount = stagedItemCount
        self.firstPageItemIDs = firstPageItemIDs
        self.seenItemIDs = seenItemIDs
        self.observedCatalogDrift = observedCatalogDrift
    }

    public func isUsable(stagedSongCount actualStagedSongCount: Int) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && SubsonicCatalogPagingPolicy.supportedSongPageSizes.contains(pageSize)
            && stageSessionID?.isEmpty == false
            && catalogRevision?.isEmpty == false
            && completedPageCount > 0
            && stagedSongCount == actualStagedSongCount
            && (stagedItemCount ?? -1) >= stagedSongCount
            && (nextOffset.map { $0 > 0 } ?? true)
    }
}

public enum SubsonicCatalogPagingPolicy {
    /// The legacy album-list endpoint has a 500-item protocol limit.
    public static let pageSize = 500
    public static let navidromeSongPageSize = 2_000
    public static let supportedSongPageSizes: Set<Int> = [pageSize, navidromeSongPageSize]

    public static func songPageSize(serverType: String?) -> Int {
        serverType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("navidrome") == .orderedSame
            ? navidromeSongPageSize : pageSize
    }

    public static func resumedPageSize(saved: Int?, preferred: Int) -> Int {
        if let saved, supportedSongPageSizes.contains(saved), saved <= preferred { return saved }
        return supportedSongPageSizes.contains(preferred) ? preferred : pageSize
    }
    public static let legacyAlbumConcurrency = 6
    public static let maximumAlbumCount = 100_000
    public static let maximumSongCount = 10_000_000
    /// `getScanStatus.lastScan|count` describes the global server scanner, not
    /// an immutable snapshot of this account's visible search3 result. Pages
    /// can therefore shift under permission changes without changing that
    /// marker, so one complete walk cannot authorize deletion on its own — it
    /// is one witness, and `ServerCatalogDeletionConfirmationPolicy` decides
    /// when enough of them agree.
    public static let deletionAuthority = CatalogDeletionAuthority.confirmationRequired

    /// OpenSubsonic requires an empty `search3` query to enumerate all media,
    /// and Navidrome implements that endpoint even on versions whose ping did
    /// not yet advertise the OpenSubsonic capability flag.
    public static func shouldUseDirectSongSearch(
        isOpenSubsonic: Bool,
        serverType: String?
    ) -> Bool {
        if isOpenSubsonic { return true }
        return serverType?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("navidrome") == .orderedSame
    }

    /// `musicFolderIDs` 是只读这几个库(Navidrome 认多个 `musicFolderId`,见
    /// `SubsonicLibraryScopePolicy.includedLibraryIDs`);给了它就不再看 `musicFolderID`。
    public static func search3QueryItems(
        songOffset: Int,
        musicFolderID: String? = nil,
        musicFolderIDs: [String] = [],
        pageSize: Int = pageSize
    ) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "query", value: ""),
            URLQueryItem(name: "artistCount", value: "0"),
            URLQueryItem(name: "albumCount", value: "0"),
            URLQueryItem(name: "songCount", value: String(pageSize)),
            URLQueryItem(name: "songOffset", value: String(max(0, songOffset))),
        ]
        if !musicFolderIDs.isEmpty {
            items += musicFolderIDs.map { URLQueryItem(name: "musicFolderId", value: $0) }
        } else if let musicFolderID, !musicFolderID.isEmpty {
            items.append(URLQueryItem(name: "musicFolderId", value: musicFolderID))
        }
        return items
    }

    public static func nextOffset(
        currentOffset: Int,
        receivedCount: Int,
        pageSize: Int = pageSize,
        continuesAfterShortPage: Bool = false
    ) -> Int? {
        guard receivedCount > 0,
              continuesAfterShortPage || receivedCount >= pageSize else { return nil }
        return currentOffset + receivedCount
    }

    /// A short terminal page is not authoritative until the immediately
    /// following offset is also empty. Some compatible servers have silently
    /// truncated search results while still reporting a stable scan revision.
    public static func terminalVerificationOffset(
        currentOffset: Int,
        receivedCount: Int,
        nextOffset: Int?
    ) -> Int? {
        guard nextOffset == nil else { return nil }
        return currentOffset + max(0, receivedCount)
    }

    public static func needsTerminalProbe(
        terminalOffset: Int?,
        observedEmptyTerminalOffset: Int?
    ) -> Bool {
        guard let terminalOffset else { return false }
        return terminalOffset != observedEmptyTerminalOffset
    }

    public static func isWithinAlbumLimit(_ count: Int) -> Bool {
        count <= maximumAlbumCount
    }

    public static func isWithinSongLimit(_ count: Int) -> Bool {
        count <= maximumSongCount
    }

    public static func canResume(
        _ state: SubsonicCatalogResumeState?,
        stagedSongCount: Int
    ) -> Bool {
        state?.isUsable(stagedSongCount: stagedSongCount) == true
    }
}


public enum PagedSongCatalogStagingError: Error, Sendable, Equatable {
    case missingStage
    case scopeChanged
    case revisionChanged
    case unexpectedOffset(expected: Int?, actual: Int)
    case duplicateItemID(String)
    case duplicateSongID(String)
}

public struct PagedSongCatalogStageSnapshot: Sendable, Equatable {
    public let sourceID: String
    public let stageSessionID: String
    public let ownerGeneration: Int
    public let scopeFingerprint: String
    public let catalogRevision: String?
    public let nextOffset: Int?
    public let completedPageCount: Int
    public let stagedSongCount: Int
    public let stagedItemCount: Int
    public let addedSongCount: Int
    public let firstPageItemIDs: [String]
}

public struct PagedSongCatalogStageDelta: Sendable, Equatable {
    public let upserts: [Song]
    public let authoritativeSongIDs: Set<String>
    public let metadataInspectedSongIDs: Set<String>
}

/// Durable private staging for authoritative server pages. Each page, its
/// duplicate receipts, hierarchy rows, and the next offset commit in one SQLite
/// transaction. The live library remains untouched until the terminal delta is
/// derived from this store.
public final class PagedSongCatalogStagingStore: @unchecked Sendable {
    private let database: DatabaseQueue
    // PMC v1 stores zlib-compressed JSON; unprefixed rows are legacy JSON.
    private static let compressedPayloadPrefix = Data([0x50, 0x4D, 0x43, 0x01])

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.label = "Primuse paged song catalog staging"
        configuration.journalMode = .wal
        database = try DatabaseQueue(path: path, configuration: configuration)
        try database.writeWithoutTransaction { db in
            // Keep each page durable, but coalesce index-page rewrites before checkpointing.
            try db.execute(sql: "PRAGMA synchronous = FULL")
            try db.execute(sql: "PRAGMA cache_size = -8192")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 8192")
        }
        try migrate()
    }

    private static func encodedPayload<T: Encodable>(_ value: T, encoder: JSONEncoder) throws -> Data {
        let json = try encoder.encode(value)
        guard json.count >= 256 else { return json }
        let compressed = try (json as NSData).compressed(using: .zlib) as Data
        guard compressed.count + compressedPayloadPrefix.count + 32 < json.count else { return json }
        return compressedPayloadPrefix + compressed
    }

    private static func decodedPayload<T: Decodable>(
        _ type: T.Type, from payload: Data, decoder: JSONDecoder
    ) throws -> T {
        // Existing checkpoints keep their JSON rows; a resumed scan can contain both formats.
        let json: Data
        if payload.starts(with: compressedPayloadPrefix) {
            json = try (Data(payload.dropFirst(compressedPayloadPrefix.count)) as NSData)
                .decompressed(using: .zlib) as Data
        } else {
            json = payload
        }
        return try decoder.decode(type, from: json)
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_paged_song_catalog_staging") { db in
            try db.create(table: "pagedCatalogStages") { table in
                table.primaryKey("sourceID", .text)
                table.column("stageSessionID", .text).notNull()
                table.column("ownerGeneration", .integer).notNull()
                table.column("scopeFingerprint", .text).notNull()
                table.column("catalogRevision", .text)
                table.column("nextOffset", .integer)
                table.column("completedPageCount", .integer).notNull()
                table.column("stagedSongCount", .integer).notNull()
                table.column("stagedItemCount", .integer).notNull()
                table.column("addedSongCount", .integer).notNull()
                table.column("firstPageItemIDs", .blob).notNull()
            }
            try db.create(table: "pagedCatalogItems") { table in
                table.column("sourceID", .text).notNull()
                table.column("itemID", .text).notNull()
                table.column("orderKey", .integer).notNull()
                table.primaryKey(["sourceID", "itemID"])
            }
            try db.create(table: "pagedCatalogSongs") { table in
                table.column("sourceID", .text).notNull()
                table.column("songID", .text).notNull()
                table.column("orderKey", .integer).notNull()
                table.column("payload", .blob).notNull()
                table.column("metadataInspected", .boolean).notNull()
                table.primaryKey(["sourceID", "songID"])
            }
            try db.create(
                index: "pagedCatalogSongs_source_order",
                on: "pagedCatalogSongs",
                columns: ["sourceID", "orderKey"]
            )
            try db.create(table: "pagedCatalogHierarchy") { table in
                table.column("sourceID", .text).notNull()
                table.column("stableKey", .text).notNull()
                table.column("payload", .blob).notNull()
                table.primaryKey(["sourceID", "stableKey"])
            }
        }
        try migrator.migrate(database)
    }

    public func reset(
        sourceID: String,
        stageSessionID: String,
        ownerGeneration: Int,
        replacingStageSessionID: String?,
        scopeFingerprint: String,
        catalogRevision: String?
    ) throws {
        let firstPageData = try JSONEncoder().encode([String]())
        try database.write { db in
            let current = try Self.snapshot(sourceID: sourceID, in: db)
            guard current?.stageSessionID == replacingStageSessionID
                    || ownerGeneration > (current?.ownerGeneration ?? .min) else {
                throw PagedSongCatalogStagingError.scopeChanged
            }
            try Self.deleteStage(sourceID: sourceID, in: db)
            try db.execute(
                sql: """
                    INSERT INTO pagedCatalogStages (
                        sourceID, stageSessionID, ownerGeneration, scopeFingerprint,
                        catalogRevision, nextOffset,
                        completedPageCount, stagedSongCount, stagedItemCount,
                        addedSongCount, firstPageItemIDs
                    ) VALUES (?, ?, ?, ?, ?, 0, 0, 0, 0, 0, ?)
                    """,
                arguments: [
                    sourceID,
                    stageSessionID,
                    ownerGeneration,
                    scopeFingerprint,
                    catalogRevision,
                    firstPageData,
                ]
            )
        }
    }

    @discardableResult
    public func stagePage(
        sourceID: String,
        stageSessionID: String,
        scopeFingerprint: String,
        catalogRevision: String?,
        offset: Int,
        nextOffset: Int?,
        itemIDs: [String],
        songs: [Song],
        metadataInspectedSongIDs: Set<String>,
        hierarchyItems: [SourceSyncIndexedItem],
        addedSongCount: Int
    ) throws -> PagedSongCatalogStageSnapshot {
        if let duplicate = Self.firstDuplicate(in: itemIDs) {
            throw PagedSongCatalogStagingError.duplicateItemID(duplicate)
        }
        let songIDs = songs.map(\.id)
        if let duplicate = Self.firstDuplicate(in: songIDs) {
            throw PagedSongCatalogStagingError.duplicateSongID(duplicate)
        }

        // Foundation's `.iso8601` strategy truncates fractional seconds. A
        // staged Subsonic mtime must round-trip exactly or every later delta
        // misclassifies the stable file as replaced and drops local metadata.
        let encoder = JSONEncoder()
        let encodedSongs = try songs.map { ($0.id, try Self.encodedPayload($0, encoder: encoder)) }
        let hierarchyByKey = Dictionary(hierarchyItems.map { ($0.stableKey, $0) },
                                       uniquingKeysWith: { _, last in last })
        encoder.outputFormatting = .sortedKeys
        let encodedHierarchy = try hierarchyByKey.sorted { $0.key < $1.key }.map { key, item in
            (key, try Self.encodedPayload(item, encoder: encoder))
        }

        return try database.write { db in
            guard let current = try Self.snapshot(sourceID: sourceID, in: db) else {
                throw PagedSongCatalogStagingError.missingStage
            }
            guard current.scopeFingerprint == scopeFingerprint else {
                throw PagedSongCatalogStagingError.scopeChanged
            }
            guard current.stageSessionID == stageSessionID else {
                throw PagedSongCatalogStagingError.scopeChanged
            }
            guard current.catalogRevision == catalogRevision else {
                throw PagedSongCatalogStagingError.revisionChanged
            }
            guard current.nextOffset == offset else {
                throw PagedSongCatalogStagingError.unexpectedOffset(
                    expected: current.nextOffset,
                    actual: offset
                )
            }

            for itemID in itemIDs {
                guard !itemID.isEmpty else {
                    throw PagedSongCatalogStagingError.duplicateItemID(itemID)
                }
            }
            if let existingItemID = try Self.firstExistingID(
                in: "pagedCatalogItems",
                column: "itemID",
                sourceID: sourceID,
                values: itemIDs,
                db: db
            ) {
                throw PagedSongCatalogStagingError.duplicateItemID(existingItemID)
            }
            let insertItem = try db.cachedStatement(sql: """
                INSERT INTO pagedCatalogItems (sourceID, itemID, orderKey) VALUES (?, ?, ?)
                """)
            for (index, itemID) in itemIDs.enumerated() {
                try insertItem.execute(arguments: [sourceID, itemID, current.stagedItemCount + index])
            }

            if let existingSongID = try Self.firstExistingID(
                in: "pagedCatalogSongs",
                column: "songID",
                sourceID: sourceID,
                values: songIDs,
                db: db
            ) {
                throw PagedSongCatalogStagingError.duplicateSongID(existingSongID)
            }
            let insertSong = try db.cachedStatement(sql: """
                INSERT INTO pagedCatalogSongs (sourceID, songID, orderKey, payload, metadataInspected)
                VALUES (?, ?, ?, ?, ?)
                """)
            for (index, encodedSong) in encodedSongs.enumerated() {
                try insertSong.execute(arguments: [
                    sourceID,
                    encodedSong.0,
                    current.stagedSongCount + index,
                    encodedSong.1,
                    metadataInspectedSongIDs.contains(encodedSong.0),
                ])
            }

            let upsertHierarchy = try db.cachedStatement(sql: """
                INSERT INTO pagedCatalogHierarchy (sourceID, stableKey, payload) VALUES (?, ?, ?)
                ON CONFLICT(sourceID, stableKey) DO UPDATE SET payload = excluded.payload
                WHERE pagedCatalogHierarchy.payload != excluded.payload
                """)
            for encodedItem in encodedHierarchy {
                try upsertHierarchy.execute(arguments: [sourceID, encodedItem.0, encodedItem.1])
            }

            let firstPageItemIDs = current.completedPageCount == 0
                ? itemIDs
                : current.firstPageItemIDs
            let firstPageData = try JSONEncoder().encode(firstPageItemIDs)
            try db.execute(
                sql: """
                    UPDATE pagedCatalogStages SET
                        nextOffset = ?,
                        completedPageCount = ?,
                        stagedSongCount = ?,
                        stagedItemCount = ?,
                        addedSongCount = ?,
                        firstPageItemIDs = ?
                    WHERE sourceID = ?
                    """,
                arguments: [
                    nextOffset,
                    current.completedPageCount + 1,
                    current.stagedSongCount + songs.count,
                    current.stagedItemCount + itemIDs.count,
                    current.addedSongCount + addedSongCount,
                    firstPageData,
                    sourceID,
                ]
            )
            guard let updated = try Self.snapshot(sourceID: sourceID, in: db) else {
                throw PagedSongCatalogStagingError.missingStage
            }
            return updated
        }
    }

    public func snapshot(sourceID: String) throws -> PagedSongCatalogStageSnapshot? {
        try database.read { db in
            try Self.snapshot(sourceID: sourceID, in: db)
        }
    }

    /// Moves a stage onto a catalogue revision that changed while it was being
    /// read, keeping every staged page. The stage then holds a union of
    /// observations rather than one snapshot, so only sources whose rows carry
    /// stable ids may do this, and such a stage must never authorize removal.
    public func reanchor(
        sourceID: String,
        stageSessionID: String,
        catalogRevision: String?,
        nextOffset: Int?
    ) throws -> PagedSongCatalogStageSnapshot {
        try database.write { db in
            guard let current = try Self.snapshot(sourceID: sourceID, in: db) else {
                throw PagedSongCatalogStagingError.missingStage
            }
            guard current.stageSessionID == stageSessionID else {
                throw PagedSongCatalogStagingError.scopeChanged
            }
            try db.execute(
                sql: """
                    UPDATE pagedCatalogStages SET catalogRevision = ?, nextOffset = ?
                    WHERE sourceID = ?
                    """,
                arguments: [catalogRevision, nextOffset, sourceID]
            )
            guard let updated = try Self.snapshot(sourceID: sourceID, in: db) else {
                throw PagedSongCatalogStagingError.missingStage
            }
            return updated
        }
    }

    /// The subset of `itemIDs` an earlier page of this stage already holds.
    public func stagedItemIDs(sourceID: String, among itemIDs: [String]) throws -> Set<String> {
        try stagedIDs(in: "pagedCatalogItems", column: "itemID", sourceID: sourceID, among: itemIDs)
    }

    /// The subset of `songIDs` an earlier page of this stage already holds.
    public func stagedSongIDs(sourceID: String, among songIDs: [String]) throws -> Set<String> {
        try stagedIDs(in: "pagedCatalogSongs", column: "songID", sourceID: sourceID, among: songIDs)
    }

    private func stagedIDs(
        in table: String,
        column: String,
        sourceID: String,
        among values: [String]
    ) throws -> Set<String> {
        try database.read { db in
            var result = Set<String>()
            for start in stride(from: 0, to: values.count, by: 400) {
                let chunk = Array(values[start..<min(start + 400, values.count)])
                let placeholders = Array(repeating: "?", count: chunk.count)
                    .joined(separator: ",")
                let found = try String.fetchAll(
                    db,
                    sql: """
                        SELECT \(column) FROM \(table)
                        WHERE sourceID = ? AND \(column) IN (\(placeholders))
                        """,
                    arguments: StatementArguments([sourceID] + chunk)
                )
                result.formUnion(found)
            }
            return result
        }
    }

    public func delta(
        sourceID: String,
        existingByID: [String: Song],
        batchSize: Int = 500, enrichment: ServerCatalogEnrichment? = nil
    ) throws -> PagedSongCatalogStageDelta {
        try delta(sourceID: sourceID, existingCount: existingByID.count,
                  existingSong: { existingByID[$0] }, batchSize: batchSize, enrichment: enrichment)
    }

    public func delta(
        sourceID: String, existingByID: IndexedSongSnapshot, batchSize: Int = 500,
        enrichment: ServerCatalogEnrichment? = nil
    ) throws -> PagedSongCatalogStageDelta {
        try delta(sourceID: sourceID, existingCount: existingByID.count,
                  existingSong: { existingByID[$0] }, batchSize: batchSize, enrichment: enrichment)
    }

    private func delta(
        sourceID: String, existingCount: Int,
        existingSong: (String) -> Song?, batchSize: Int, enrichment: ServerCatalogEnrichment?
    ) throws -> PagedSongCatalogStageDelta {
        let safeBatchSize = max(1, min(batchSize, 1_000))
        let decoder = JSONDecoder()
        return try database.read { db in
            guard try Self.snapshot(sourceID: sourceID, in: db) != nil else {
                throw PagedSongCatalogStagingError.missingStage
            }
            var authoritativeSongIDs = Set<String>()
            authoritativeSongIDs.reserveCapacity(existingCount)
            var metadataInspectedSongIDs = Set<String>()
            var upserts: [Song] = []
            var lastOrderKey = -1
            while true {
                try Task.checkCancellation()
                let hasRows = try autoreleasepool {
                    let rows = try Row.fetchAll(
                        db,
                        sql: """
                            SELECT orderKey, payload, metadataInspected
                            FROM pagedCatalogSongs
                            WHERE sourceID = ? AND orderKey > ?
                            ORDER BY orderKey ASC
                            LIMIT ?
                            """,
                        arguments: [sourceID, lastOrderKey, safeBatchSize]
                    )
                    guard !rows.isEmpty else { return false }
                    for row in rows {
                        try Task.checkCancellation()
                        let orderKey: Int = row["orderKey"]
                        let payload: Data = row["payload"]
                        var song = try Self.decodedPayload(Song.self, from: payload, decoder: decoder)
                        if let enrichment { song = enrichment.applying(to: song) }
                        if let existing = existingSong(song.id) {
                            song = ServerSongCatalogMergePolicy.merged(
                                existing: existing,
                                incoming: song
                            )
                        }
                        authoritativeSongIDs.insert(song.id)
                        let metadataInspected: Bool = row["metadataInspected"]
                        if metadataInspected {
                            metadataInspectedSongIDs.insert(song.id)
                        }
                        if existingSong(song.id) != song {
                            upserts.append(song)
                        }
                        lastOrderKey = orderKey
                    }
                    return true
                }
                if !hasRows { break }
            }
            return PagedSongCatalogStageDelta(
                upserts: upserts,
                authoritativeSongIDs: authoritativeSongIDs,
                metadataInspectedSongIDs: metadataInspectedSongIDs
            )
        }
    }

    public func loadHierarchyIndex(
        sourceID: String
    ) throws -> [String: SourceSyncIndexedItem] {
        let decoder = JSONDecoder()
        return try database.read { db in
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT stableKey, payload FROM pagedCatalogHierarchy
                    WHERE sourceID = ?
                    """,
                arguments: [sourceID]
            )
            var result: [String: SourceSyncIndexedItem] = [:]
            while let row = try rows.next() {
                try Task.checkCancellation()
                try autoreleasepool {
                    let stableKey: String = row["stableKey"]
                    let payload: Data = row["payload"]
                    result[stableKey] = try Self.decodedPayload(
                        SourceSyncIndexedItem.self,
                        from: payload, decoder: decoder
                    )
                }
            }
            return result
        }
    }

    /// Owner generation of a stage no scan of this launch has claimed.
    public static let unownedGeneration = Int.min

    /// Scan generations restart with every launch, so an owner generation
    /// written by an earlier process means nothing now; left in place it could
    /// outrank this launch's scans and refuse their reset forever. Call once
    /// at startup, before any scan runs.
    public func releaseOwnershipFromEarlierLaunch() throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE pagedCatalogStages SET ownerGeneration = ?",
                arguments: [Self.unownedGeneration]
            )
        }
    }

    /// Deletes stages no checkpoint can resume: a stage resumes only while a
    /// checkpoint names its session, so any other one is dead rows (a removed
    /// source, a crash between reset and the first page). Stages a scan of this
    /// launch has already reset are owned and left alone.
    @discardableResult
    public func discardUnresumableStages(
        keepingStageSessionIDs keep: [String: String]
    ) throws -> [String] {
        try database.write { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT sourceID, stageSessionID FROM pagedCatalogStages WHERE ownerGeneration = ?",
                arguments: [Self.unownedGeneration]
            )
            var discarded: [String] = []
            for row in rows {
                let sourceID: String = row["sourceID"]
                let stageSessionID: String = row["stageSessionID"]
                guard keep[sourceID] != stageSessionID else { continue }
                try Self.deleteStage(sourceID: sourceID, in: db)
                discarded.append(sourceID)
            }
            // Page rows whose stage row is already gone.
            for table in ["pagedCatalogItems", "pagedCatalogSongs", "pagedCatalogHierarchy"] {
                try db.execute(sql: """
                    DELETE FROM \(table)
                    WHERE sourceID NOT IN (SELECT sourceID FROM pagedCatalogStages)
                    """)
            }
            return discarded.sorted()
        }
    }

    public func discard(sourceID: String, stageSessionID: String? = nil) throws {
        try database.write { db in
            if let stageSessionID {
                guard let current = try Self.snapshot(sourceID: sourceID, in: db),
                      current.stageSessionID == stageSessionID else { return }
            }
            try Self.deleteStage(sourceID: sourceID, in: db)
        }
    }

    /// Detach the completed stage before reclaiming its rows. An interrupted
    /// cleanup cannot be resumed as a partially deleted scan, and a new stage
    /// for the same source takes ownership before the next cleanup batch.
    /// With no remaining stages, whole-table clearing returns pages to SQLite's
    /// freelist instead of removing each row and index entry individually.
    public func discardInBatches(
        sourceID: String, stageSessionID: String,
        afterBatch: @Sendable (Int) async throws -> Void = { _ in }
    ) async throws {
        _ = try await reclaimStage(sourceID: sourceID, stageSessionID: stageSessionID,
                                   requiresUnowned: false, afterBatch: afterBatch)
    }

    @discardableResult
    public func discardUnresumableStagesInBatches(
        keepingStageSessionIDs keep: [String: String],
        afterBatch: @Sendable (Int) async throws -> Void = { _ in }
    ) async throws -> [String] {
        let candidates = try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT sourceID, stageSessionID FROM pagedCatalogStages WHERE ownerGeneration = ?",
                             arguments: [Self.unownedGeneration]).map { row -> (String, String) in
                (row["sourceID"], row["stageSessionID"])
            }
        }
        var discarded: [String] = []
        for (sourceID, sessionID) in candidates where keep[sourceID] != sessionID {
            if try await reclaimStage(sourceID: sourceID, stageSessionID: sessionID,
                                      requiresUnowned: true, afterBatch: afterBatch) {
                discarded.append(sourceID)
            }
        }
        let orphanSources = try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT sourceID FROM pagedCatalogItems WHERE sourceID NOT IN (SELECT sourceID FROM pagedCatalogStages)
                UNION SELECT DISTINCT sourceID FROM pagedCatalogSongs WHERE sourceID NOT IN (SELECT sourceID FROM pagedCatalogStages)
                UNION SELECT DISTINCT sourceID FROM pagedCatalogHierarchy WHERE sourceID NOT IN (SELECT sourceID FROM pagedCatalogStages)
                """)
        }
        for sourceID in orphanSources {
            _ = try await reclaimStage(sourceID: sourceID, stageSessionID: nil,
                                       requiresUnowned: true, afterBatch: afterBatch)
        }
        return discarded.sorted()
    }

    private func reclaimStage(
        sourceID: String, stageSessionID: String?, requiresUnowned: Bool,
        afterBatch: @Sendable (Int) async throws -> Void
    ) async throws -> Bool {
        try Task.checkCancellation()
        try await afterBatch(0)
        try Task.checkCancellation()
        let detached = try await database.write { db in
            if let current = try Self.snapshot(sourceID: sourceID, in: db) {
                guard current.stageSessionID == stageSessionID,
                      !requiresUnowned || current.ownerGeneration == Self.unownedGeneration else { return false }
                try db.execute(sql: "DELETE FROM pagedCatalogStages WHERE sourceID = ?", arguments: [sourceID])
            }
            return true
        }
        guard detached else { return false }
        for table in ["pagedCatalogItems", "pagedCatalogSongs", "pagedCatalogHierarchy"] {
            while true {
                try Task.checkCancellation()
                let startedAt = ContinuousClock.now
                let removed: Int? = try await database.write { db in
                    let hasOwner = try Bool.fetchOne(db,
                        sql: "SELECT EXISTS(SELECT 1 FROM pagedCatalogStages WHERE sourceID = ?)",
                        arguments: [sourceID]) ?? true
                    guard !hasOwner else { return nil }
                    if try Self.hasStages(in: db) {
                        try db.execute(sql: """
                            DELETE FROM \(table) WHERE rowid IN (
                                SELECT rowid FROM \(table) WHERE sourceID = ? LIMIT 512
                            )
                            """, arguments: [sourceID])
                    } else {
                        try db.execute(sql: "DELETE FROM \(table)")
                    }
                    return db.changesCount
                }
                guard let removed else { return true }
                guard removed > 0 else { break }
                let delay = max(Duration.milliseconds(5), startedAt.duration(to: .now) * 3)
                try await afterBatch(removed)
                try await Task.sleep(for: delay)
            }
        }
        return true
    }

    private static func snapshot(
        sourceID: String,
        in db: Database
    ) throws -> PagedSongCatalogStageSnapshot? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM pagedCatalogStages WHERE sourceID = ?",
            arguments: [sourceID]
        ) else { return nil }
        let firstPageData: Data = row["firstPageItemIDs"]
        return PagedSongCatalogStageSnapshot(
            sourceID: row["sourceID"],
            stageSessionID: row["stageSessionID"],
            ownerGeneration: row["ownerGeneration"],
            scopeFingerprint: row["scopeFingerprint"],
            catalogRevision: row["catalogRevision"],
            nextOffset: row["nextOffset"],
            completedPageCount: row["completedPageCount"],
            stagedSongCount: row["stagedSongCount"],
            stagedItemCount: row["stagedItemCount"],
            addedSongCount: row["addedSongCount"],
            firstPageItemIDs: try JSONDecoder().decode([String].self, from: firstPageData)
        )
    }

    private static func deleteStage(sourceID: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM pagedCatalogStages WHERE sourceID = ?", arguments: [sourceID])
        let keepsOtherStages = try hasStages(in: db)
        for table in [
            "pagedCatalogItems",
            "pagedCatalogSongs",
            "pagedCatalogHierarchy",
        ] {
            if keepsOtherStages {
                try db.execute(sql: "DELETE FROM \(table) WHERE sourceID = ?", arguments: [sourceID])
            } else {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    private static func hasStages(in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM pagedCatalogStages)") ?? true
    }

    private static func firstDuplicate(in values: [String]) -> String? {
        var seen = Set<String>()
        for value in values where !seen.insert(value).inserted {
            return value
        }
        return nil
    }

    private static func firstExistingID(
        in table: String,
        column: String,
        sourceID: String,
        values: [String],
        db: Database
    ) throws -> String? {
        for start in stride(from: 0, to: values.count, by: 400) {
            let chunk = Array(values[start..<min(start + 400, values.count)])
            let placeholders = Array(repeating: "?", count: chunk.count)
                .joined(separator: ",")
            let arguments = StatementArguments([sourceID] + chunk)
            if let value = try String.fetchOne(
                db,
                sql: """
                    SELECT \(column) FROM \(table)
                    WHERE sourceID = ? AND \(column) IN (\(placeholders))
                    LIMIT 1
                    """,
                arguments: arguments
            ) {
                return value
            }
        }
        return nil
    }
}
