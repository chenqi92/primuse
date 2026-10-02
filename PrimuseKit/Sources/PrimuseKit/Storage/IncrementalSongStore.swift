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

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.label = "Primuse incremental song store"
        database = try DatabaseQueue(path: path, configuration: configuration)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        try migrate()
        // 装载按 orderKey 顺序读整库, 增量写入要取 MAX(orderKey)。没有这条索引时
        // 前者每次启动都把所有行连同负载写进临时文件排序(几十万首要写几百 MB,
        // 磁盘紧张时直接读失败), 后者每批写入都扫全表。建不出来(比如磁盘满)
        // 也照常可用, 只是照旧慢, 下次打开再建。
        try? database.write { db in
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS librarySongRecords_on_orderKey_id
                ON librarySongRecords(orderKey, id)
                """)
        }
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
        // 边读边解码: 先把全部负载读成 [Data] 再解码, 二十多万首时要多占近 200MB。
        // 读游标只能串行, 解码是纯 CPU 活: 每攒一小批就分到多个核上解码,
        // 同时在手的负载只有一批(几 MB)。
        try database.read { db in
            var songs: [Song] = []
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM librarySongRecords") ?? 0
            songs.reserveCapacity(count)
            let payloads = try Data.fetchCursor(db, sql: Self.loadSongsSQL)
            var batch: [Data] = []
            batch.reserveCapacity(Self.decodeBatchSize)
            // 每批解码完就把重复的字段并成一份, 峰值不会先涨到整库各存一份。
            var interner = SongStringInterner()
            func appendDecoded(_ decoded: [Song]) {
                var decoded = decoded
                for index in decoded.indices { interner.intern(&decoded[index]) }
                songs.append(contentsOf: decoded)
            }
            while let payload = try payloads.next() {
                batch.append(payload)
                if batch.count == Self.decodeBatchSize {
                    appendDecoded(try Self.decodeSongs(batch))
                    batch.removeAll(keepingCapacity: true)
                }
            }
            if !batch.isEmpty {
                appendDecoded(try Self.decodeSongs(batch))
            }
            return songs
        }
    }

    static let loadSongsSQL = "SELECT payload FROM librarySongRecords ORDER BY orderKey ASC, id ASC"

    /// The plan SQLite picks for `loadSongs()` (tests).
    func loadSongsQueryPlan() throws -> [String] {
        try database.read { db in
            try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + Self.loadSongsSQL).map { $0["detail"] as String }
        }
    }

    static let decodeBatchSize = 4_096
    private static let minimumSliceSize = 256

    /// 按原顺序返回; 出错时抛的是顺序上第一条坏行的错误, 与逐条解码一致。
    static func decodeSongs(_ payloads: [Data]) throws -> [Song] {
        let sliceCount = min(
            max(1, ProcessInfo.processInfo.activeProcessorCount),
            max(1, payloads.count / minimumSliceSize)
        )
        let sliceSize = (payloads.count + sliceCount - 1) / sliceCount
        let results = DecodedSlices(count: sliceCount)
        DispatchQueue.concurrentPerform(iterations: sliceCount) { slice in
            let start = slice * sliceSize
            let end = min(payloads.count, start + sliceSize)
            // JSONDecoder 是引用类型, 每片各用一个, 不跨线程共享。
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var songs: [Song] = []
            songs.reserveCapacity(max(0, end - start))
            do {
                for index in start..<max(start, end) {
                    songs.append(try decoder.decode(Song.self, from: payloads[index]))
                }
                results.store(.success(songs), at: slice)
            } catch {
                results.store(.failure(error), at: slice)
            }
        }
        var songs: [Song] = []
        songs.reserveCapacity(payloads.count)
        for result in results.take() {
            songs.append(contentsOf: try result.get())
        }
        return songs
    }

    /// 每个下标只由一个解码片写一次, `concurrentPerform` 返回后才读。
    /// 槽位是一次性分配的裸内存: 并发写同一个数组属性会触发独占访问检查。
    private final class DecodedSlices: @unchecked Sendable {
        private let count: Int
        private let slots: UnsafeMutablePointer<Result<[Song], Error>?>

        init(count: Int) {
            self.count = count
            slots = .allocate(capacity: count)
            slots.initialize(repeating: nil, count: count)
        }

        deinit {
            slots.deinitialize(count: count)
            slots.deallocate()
        }

        func store(_ result: Result<[Song], Error>, at index: Int) {
            slots[index] = result
        }

        func take() -> [Result<[Song], Error>] {
            (0..<count).map { slots[$0] ?? .success([]) }
        }
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

/// Songs of one album or artist repeat the same strings: album and artist
/// IDs and names, the source ID, genre, artwork file names, pinyin. Decoded
/// one row at a time, every song carries its own heap copy of each. Sharing
/// one instance per distinct value keeps the values identical and roughly
/// halves a large library's resident size (400K synthetic songs with 30K
/// albums: about 830MB down to 450MB).
public struct SongStringInterner {
    private var strings: [String: String] = [:]
    private var stringLists: [[String]: [String]] = [:]

    public init() {}

    public mutating func intern(_ song: inout Song) {
        share(&song.sourceID)
        share(&song.albumID)
        share(&song.artistID)
        share(&song.albumTitle)
        share(&song.artistName)
        share(&song.albumArtistName)
        share(&song.genre)
        share(&song.coverArtFileName)
        share(&song.artistArtworkFileName)
        share(&song.artistPinyin)
        share(&song.albumPinyin)
        share(&song.cueSheetPath)
        share(&song.serverLibraryID)
        if let names = song.sourceArtistNames {
            if let shared = stringLists[names] {
                song.sourceArtistNames = shared
            } else {
                stringLists[names] = names
            }
        }
    }

    private mutating func share(_ value: inout String) {
        // Up to 15 UTF-8 bytes live inside the String itself: nothing to share.
        guard value.utf8.count > 15 else { return }
        if let shared = strings[value] {
            value = shared
        } else {
            strings[value] = value
        }
    }

    private mutating func share(_ value: inout String?) {
        guard var string = value else { return }
        share(&string)
        value = string
    }
}
