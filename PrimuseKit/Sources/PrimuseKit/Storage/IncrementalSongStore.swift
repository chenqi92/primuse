import Foundation
import GRDB

/// Device-local canonical storage for library songs.
///
/// `library-cache.json` remains the interoperable snapshot used by iCloud and
/// Apple TV transfer, while this store makes normal scan/backfill persistence
/// proportional to the changed rows. Song payloads are encoded individually so
/// adding two files to a large library does not encode every existing song.
public final class IncrementalSongStore: @unchecked Sendable {
    private static let authoritativeKey = "songs-authoritative"
    private static let contentRevisionKey = "songs-content-revision"
    private static let completedMigrationVersionKey = "songs-migration-version"

    private let database: DatabaseQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.label = "Primuse incremental song store"
        database = try DatabaseQueue(path: path, configuration: configuration)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_incremental_songs") { db in
            try db.create(table: "librarySongRecords") { table in
                table.primaryKey("id", .text)
                table.column("sourceID", .text).notNull().indexed()
                table.column("orderKey", .integer).notNull()
                table.column("payload", .blob).notNull()
            }
            try db.create(table: "libraryStoreMetadata") { table in
                table.primaryKey("key", .text)
                table.column("value", .text).notNull()
            }
        }
        try migrator.migrate(database)
    }

    /// A fresh database is intentionally different from an authoritative empty
    /// library. The distinction lets the app import an existing JSON snapshot
    /// exactly once without resurrecting deleted songs on later launches.
    public func isAuthoritative() throws -> Bool {
        try startupState().isAuthoritative
    }

    /// Cheap metadata used to validate the disposable binary launch cache
    /// without decoding every song row first.
    public func startupState() throws -> IncrementalSongStoreStartupState {
        try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT key, value FROM libraryStoreMetadata WHERE key IN (?, ?, ?)",
                arguments: [
                    Self.authoritativeKey,
                    Self.contentRevisionKey,
                    Self.completedMigrationVersionKey,
                ]
            )
            let values = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, String)? in
                guard let key: String = row["key"], let value: String = row["value"] else {
                    return nil
                }
                return (key, value)
            })
            return IncrementalSongStoreStartupState(
                isAuthoritative: values[Self.authoritativeKey] == "1",
                contentRevision: Int64(values[Self.contentRevisionKey] ?? "") ?? 0,
                completedMigrationVersion: Int(values[Self.completedMigrationVersionKey] ?? "") ?? 0
            )
        }
    }

    public func loadSongs() throws -> [Song] {
        let payloads: [Data] = try database.read { db in
            try Data.fetchAll(
                db,
                sql: "SELECT payload FROM librarySongRecords ORDER BY orderKey ASC, id ASC"
            )
        }
        return try payloads.map { try decoder.decode(Song.self, from: $0) }
    }

    /// Seeds or replaces the canonical table in one transaction. Used only for
    /// first migration and for an explicitly downloaded external snapshot.
    @discardableResult
    public func replaceAll(with songs: [Song], snapshotImportID: String? = nil) throws -> Int64 {
        let rows = try songs.enumerated().map { index, song in
            (song.id, song.sourceID, Int64(index), try encoder.encode(song))
        }
        return try database.write { db in
            try db.execute(sql: "DELETE FROM librarySongRecords")
            for row in rows {
                try db.execute(
                    sql: """
                        INSERT INTO librarySongRecords (id, sourceID, orderKey, payload)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [row.0, row.1, row.2, row.3]
                )
            }
            try Self.markAuthoritative(in: db)
            if let snapshotImportID {
                try Self.setMetadataValue(snapshotImportID, forKey: "last-snapshot-import", in: db)
            }
            return try Self.bumpContentRevision(in: db)
        }
    }

    public func lastSnapshotImportID() throws -> String? {
        try database.read { db in
            try Self.metadataValue(forKey: "last-snapshot-import", in: db)
        }
    }

    /// Applies a completed in-memory mutation atomically. Existing rows retain
    /// their stable order; genuinely new rows are appended in input order.
    @discardableResult
    public func apply(upserts: [Song], deletingIDs: Set<String> = []) throws -> Int64 {
        guard !upserts.isEmpty || !deletingIDs.isEmpty else {
            return try startupState().contentRevision
        }
        let encoded = try upserts.map { song in
            (song.id, song.sourceID, try encoder.encode(song))
        }

        return try database.write { db in
            if !deletingIDs.isEmpty {
                let ids = Array(deletingIDs)
                for chunkStart in stride(from: 0, to: ids.count, by: 500) {
                    let chunk = Array(ids[chunkStart..<min(chunkStart + 500, ids.count)])
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    try db.execute(
                        sql: "DELETE FROM librarySongRecords WHERE id IN (\(placeholders))",
                        arguments: StatementArguments(chunk)
                    )
                }
            }

            var nextOrderKey = (try Int64.fetchOne(
                db,
                sql: "SELECT MAX(orderKey) FROM librarySongRecords"
            ) ?? -1) + 1

            for row in encoded {
                let alreadyExists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM librarySongRecords WHERE id = ?)",
                    arguments: [row.0]
                ) ?? false
                try db.execute(
                    sql: """
                        INSERT INTO librarySongRecords (id, sourceID, orderKey, payload)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            sourceID = excluded.sourceID,
                            payload = excluded.payload
                    """,
                    arguments: [row.0, row.1, nextOrderKey, row.2]
                )
                if !alreadyExists {
                    nextOrderKey += 1
                }
            }
            try Self.markAuthoritative(in: db)
            return try Self.bumpContentRevision(in: db)
        }
    }

    /// Records that all rows currently in the canonical store have passed a
    /// particular launch migration. Future launches can skip an otherwise
    /// O(librarySize) inspection until the migration version is bumped.
    public func markMigrationCompleted(version: Int) throws {
        try database.write { db in
            let current = try Self.metadataValue(
                forKey: Self.completedMigrationVersionKey,
                in: db
            ).flatMap(Int.init) ?? 0
            guard version > current else { return }
            try Self.setMetadataValue(
                String(version),
                forKey: Self.completedMigrationVersionKey,
                in: db
            )
        }
    }

    public func songCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM librarySongRecords") ?? 0
        }
    }

    private static func markAuthoritative(in db: Database) throws {
        try setMetadataValue("1", forKey: authoritativeKey, in: db)
    }

    private static func bumpContentRevision(in db: Database) throws -> Int64 {
        let current = try metadataValue(forKey: contentRevisionKey, in: db)
            .flatMap(Int64.init) ?? 0
        let next = current == .max ? 1 : current + 1
        try setMetadataValue(String(next), forKey: contentRevisionKey, in: db)
        return next
    }

    private static func metadataValue(forKey key: String, in db: Database) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT value FROM libraryStoreMetadata WHERE key = ?",
            arguments: [key]
        )
    }

    private static func setMetadataValue(_ value: String, forKey key: String, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO libraryStoreMetadata (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [key, value]
        )
    }
}

public struct IncrementalSongStoreStartupState: Equatable, Sendable {
    public let isAuthoritative: Bool
    public let contentRevision: Int64
    public let completedMigrationVersion: Int

    public init(
        isAuthoritative: Bool,
        contentRevision: Int64,
        completedMigrationVersion: Int
    ) {
        self.isAuthoritative = isAuthoritative
        self.contentRevision = contentRevision
        self.completedMigrationVersion = completedMigrationVersion
    }
}
