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
        seenItemIDs: Set<String> = []
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
    }

    public func isUsable(stagedSongCount actualStagedSongCount: Int) -> Bool {
        schemaVersion == Self.currentSchemaVersion
            && pageSize == SubsonicCatalogPagingPolicy.pageSize
            && stageSessionID?.isEmpty == false
            && catalogRevision?.isEmpty == false
            && completedPageCount > 0
            && stagedSongCount == actualStagedSongCount
            && (stagedItemCount ?? -1) >= stagedSongCount
            && (nextOffset.map { $0 > 0 && $0.isMultiple(of: pageSize) } ?? true)
    }
}

public enum SubsonicCatalogPagingPolicy {
    public static let pageSize = 500
    public static let legacyAlbumConcurrency = 6
    public static let maximumAlbumCount = 100_000
    public static let maximumSongCount = 10_000_000
    /// `getScanStatus.lastScan|count` describes the global server scanner, not
    /// an immutable snapshot of this account's visible search3 result. Pages
    /// can therefore shift under permission changes without changing that
    /// marker. A complete walk may merge rows, but cannot authorize deletion.
    public static let authorizesMissingSongDeletion = false

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

    public static func search3QueryItems(
        songOffset: Int,
        musicFolderID: String? = nil
    ) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "query", value: ""),
            URLQueryItem(name: "artistCount", value: "0"),
            URLQueryItem(name: "albumCount", value: "0"),
            URLQueryItem(name: "songCount", value: String(pageSize)),
            URLQueryItem(name: "songOffset", value: String(max(0, songOffset))),
        ]
        if let musicFolderID, !musicFolderID.isEmpty {
            items.append(URLQueryItem(name: "musicFolderId", value: musicFolderID))
        }
        return items
    }

    public static func nextOffset(currentOffset: Int, receivedCount: Int) -> Int? {
        guard receivedCount >= pageSize else { return nil }
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

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.label = "Primuse paged song catalog staging"
        database = try DatabaseQueue(path: path, configuration: configuration)
        try migrate()
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
        let encodedSongs = try songs.map { ($0.id, try encoder.encode($0)) }
        let encodedHierarchy = try hierarchyItems.map {
            ($0.stableKey, try encoder.encode($0))
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
            for (index, itemID) in itemIDs.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO pagedCatalogItems (sourceID, itemID, orderKey)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [sourceID, itemID, current.stagedItemCount + index]
                )
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
            for (index, encodedSong) in encodedSongs.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO pagedCatalogSongs (
                            sourceID, songID, orderKey, payload, metadataInspected
                        ) VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        sourceID,
                        encodedSong.0,
                        current.stagedSongCount + index,
                        encodedSong.1,
                        metadataInspectedSongIDs.contains(encodedSong.0),
                    ]
                )
            }

            for encodedItem in encodedHierarchy {
                try db.execute(
                    sql: """
                        INSERT INTO pagedCatalogHierarchy (sourceID, stableKey, payload)
                        VALUES (?, ?, ?)
                        ON CONFLICT(sourceID, stableKey) DO UPDATE SET
                            payload = excluded.payload
                        """,
                    arguments: [sourceID, encodedItem.0, encodedItem.1]
                )
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

    public func delta(
        sourceID: String,
        existingByID: [String: Song],
        batchSize: Int = 500
    ) throws -> PagedSongCatalogStageDelta {
        let safeBatchSize = max(1, min(batchSize, 1_000))
        let decoder = JSONDecoder()
        return try database.read { db in
            guard try Self.snapshot(sourceID: sourceID, in: db) != nil else {
                throw PagedSongCatalogStagingError.missingStage
            }
            var authoritativeSongIDs = Set<String>()
            authoritativeSongIDs.reserveCapacity(existingByID.count)
            var metadataInspectedSongIDs = Set<String>()
            var upserts: [Song] = []
            var lastOrderKey = -1
            while true {
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
                guard !rows.isEmpty else { break }
                for row in rows {
                    let orderKey: Int = row["orderKey"]
                    let payload: Data = row["payload"]
                    var song = try decoder.decode(Song.self, from: payload)
                    if let existing = existingByID[song.id] {
                        song.dateAdded = existing.dateAdded
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
                    if existingByID[song.id] != song {
                        upserts.append(song)
                    }
                    lastOrderKey = orderKey
                }
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
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT stableKey, payload FROM pagedCatalogHierarchy
                    WHERE sourceID = ?
                    """,
                arguments: [sourceID]
            )
            var result: [String: SourceSyncIndexedItem] = [:]
            result.reserveCapacity(rows.count)
            for row in rows {
                let stableKey: String = row["stableKey"]
                let payload: Data = row["payload"]
                result[stableKey] = try decoder.decode(
                    SourceSyncIndexedItem.self,
                    from: payload
                )
            }
            return result
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
        for table in [
            "pagedCatalogItems",
            "pagedCatalogSongs",
            "pagedCatalogHierarchy",
            "pagedCatalogStages",
        ] {
            try db.execute(
                sql: "DELETE FROM \(table) WHERE sourceID = ?",
                arguments: [sourceID]
            )
        }
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
