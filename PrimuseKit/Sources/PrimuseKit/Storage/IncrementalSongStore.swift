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
        try database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM libraryStoreMetadata WHERE key = ?",
                arguments: [Self.authoritativeKey]
            ) == "1"
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
    public func replaceAll(with songs: [Song]) throws {
        let rows = try songs.enumerated().map { index, song in
            (song.id, song.sourceID, Int64(index), try encoder.encode(song))
        }
        try database.write { db in
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
        }
    }

    /// Applies a completed in-memory mutation atomically. Existing rows retain
    /// their stable order; genuinely new rows are appended in input order.
    public func apply(upserts: [Song], deletingIDs: Set<String> = []) throws {
        guard !upserts.isEmpty || !deletingIDs.isEmpty else { return }
        let encoded = try upserts.map { song in
            (song.id, song.sourceID, try encoder.encode(song))
        }

        try database.write { db in
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
        }
    }

    public func songCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM librarySongRecords") ?? 0
        }
    }

    private static func markAuthoritative(in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO libraryStoreMetadata (key, value) VALUES (?, '1')
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
            arguments: [authoritativeKey]
        )
    }
}
