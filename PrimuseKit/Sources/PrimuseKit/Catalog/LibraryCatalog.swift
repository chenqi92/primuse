import Foundation
import GRDB
import SQLite3

public enum LibraryCatalogError: Error, Equatable, Sendable {
    case corruptRow
    case unknownAudioFormat(String)
    /// GRDB 按 C 字符串绑定文本:含 U+0000 的歌曲或音乐源 id 存不进唯一键。
    case invalidIdentifier(String)
    case rowidOutOfRange(Int64)
    case cancelled
}

/// 曲库目录:`library-catalog.sqlite`,曲库的唯一真相。内存里只留有界的窗口。
///
/// 连接配置见 PLAN §4.1:WAL 连接池,每连接页缓存 ≤ 4 MiB,读连接 ≤ 2 个,
/// 256 MiB 映射读,大排序走临时文件。歌曲行事务 `synchronous=FULL`。
public final class LibraryCatalog: @unchecked Sendable {
    public let path: String
    let pool: DatabasePool

    enum MetaKey {
        static let schemaVersion = "schemaVersion"
        static let collationLocale = "collationLocale"
        static let revision = "revision"
        static let generation = "generation"
        static let sortIndexesDeferred = "sortIndexesDeferred"
        static let importState = "import.state"
        static let importCursorOrderKey = "import.cursor.orderKey"
        static let importCursorID = "import.cursor.id"
        static let importStoreRevision = "import.storeRevision"
        static let importedCount = "import.count"
        /// 一旦写进过 id 不是 NFC 的歌就记 "1":排序的 id 兜底改用 Swift 的字符串比较。
        static let nonNFCIdentifiers = "nonNFCIdentifiers"
    }

    /// 打开(不存在就新建)目录。打开只做迁移检查与 meta 读取,与曲库大小无关;
    /// 系统语言与建索引时不同时重建本地化排序索引。
    public init(path: String, locale: Locale = .current) throws {
        self.path = path
        var configuration = Configuration()
        configuration.label = "Primuse library catalog"
        configuration.maximumReaderCount = LibraryScale.maximumReaderCount
        configuration.prepareDatabase { db in
            try db.execute(sql: """
                PRAGMA cache_size = -\(LibraryScale.connectionCacheKiB);
                PRAGMA temp_store = FILE;
                PRAGMA mmap_size = \(LibraryScale.mmapSize);
                """)
        }
        pool = try DatabasePool(path: path, configuration: configuration)
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        var migrator = DatabaseMigrator()
        LibraryCatalogSchema.registerMigrations(in: &migrator)
        try migrator.migrate(pool)
        try pool.write { db in
            if try Self.metaValue(MetaKey.schemaVersion, in: db) == nil {
                try Self.setMeta(MetaKey.schemaVersion, String(LibraryCatalogSchema.schemaVersion), in: db)
            }
            let identifier = locale.identifier
            let stored = try Self.metaValue(MetaKey.collationLocale, in: db)
            if stored == nil {
                try Self.setMeta(MetaKey.collationLocale, identifier, in: db)
            } else if stored != identifier {
                // GRDB 的本地化比较跟随当前语言,索引里的先后要跟着重排。
                try db.execute(sql: "REINDEX \(LibraryCatalogSchema.localizedCollation)")
                try db.execute(sql: "REINDEX \(LibraryCatalogSchema.localizedStandardCollation)")
                try Self.setMeta(MetaKey.collationLocale, identifier, in: db)
            }
            if try Self.metaValue(MetaKey.sortIndexesDeferred, in: db) == "1",
               try Self.metaValue(MetaKey.importState, in: db) != "running" {
                try LibraryCatalogSchema.createDeferredIndexes(db)
                try Self.setMeta(MetaKey.sortIndexesDeferred, "0", in: db)
            }
        }
    }

    /// 前后台切换、内存告警时调用:放掉各连接的页缓存。
    public func releaseMemory() {
        pool.releaseMemory()
    }

    /// 歌曲内容修订号:每次 `apply` 有改动就递增。
    public func revision() throws -> Int64 {
        try pool.read { db in try Self.revision(in: db) }
    }

    public func collationLocaleIdentifier() throws -> String? {
        try pool.read { db in try Self.metaValue(MetaKey.collationLocale, in: db) }
    }

    /// 这个连接池现在的 SQLite 页缓存占用(字节),给诊断日志与规模测试。
    public func sqliteMemoryUsed() -> Int64 {
        Int64(sqlite3_memory_used())
    }

    // MARK: - Meta

    static func metaValue(_ key: String, in db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT value FROM catalogMeta WHERE key = ?", arguments: [key])
    }

    static func setMeta(_ key: String, _ value: String, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO catalogMeta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [key, value]
        )
    }

    static func removeMeta(_ key: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM catalogMeta WHERE key = ?", arguments: [key])
    }

    static func revision(in db: Database) throws -> Int64 {
        try metaValue(MetaKey.revision, in: db).flatMap(Int64.init) ?? 0
    }

    @discardableResult
    static func bumpRevision(in db: Database) throws -> Int64 {
        let next = try revision(in: db) &+ 1
        try setMeta(MetaKey.revision, String(next), in: db)
        return next
    }

    static func rowid32(_ value: Int64) throws -> Int32 {
        guard let rowid = Int32(exactly: value) else { throw LibraryCatalogError.rowidOutOfRange(value) }
        return rowid
    }
}
