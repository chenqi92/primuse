import Foundation
import GRDB
import os
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
    /// 查询读哪里:实时目录读连接池本身;`frozenView()` 给的只读视图读那一刻的快照。
    /// 写入(含维护、离线状态表的读写)一律走 `pool`。
    let reader: any DatabaseReader
    /// 冻结视图的来源;实时目录自己为 nil。
    private let frozenFrom: LibraryCatalog?
    /// 这是 `frozenView()` 给的视图(查询看到的是冻结那一刻的目录)。
    public var isFrozenView: Bool { frozenFrom != nil }
    /// 实时目录。要长期留着句柄(维护记账等)时留它:留着冻结视图会一直拖住检查点,读到的也一直是旧的。
    public var live: LibraryCatalog { frozenFrom ?? self }
    let songListCache = LibrarySongListCache()
    private let groupingState = OSAllocatedUnfairLock(initialState: LibraryGroupingConfiguration())
    let writeWorkState = OSAllocatedUnfairLock(initialState: LibraryCatalogWriteWorkState())
    /// `bulkInsert` 跨批复用的整数引用与艺人解析结果(写事务串行,不会并发用)。
    let bulkLoadRefs = CatalogRefCache()
    let bulkLoadMemo = GroupingMaintenance.RowValueMemo()
    /// 按 id 读一行专用的只读连接,第一次用到时才打开(见 `pointRead`)。
    private let pointReaderLock = NSLock()
    private var pointReader: DatabaseQueue?

    /// 分组派生当前用的 App 输入。`setGroupingConfiguration` 换掉并按需整库重建。
    public var groupingConfiguration: LibraryGroupingConfiguration {
        groupingState.withLock { $0 }
    }

    func replaceGroupingConfiguration(_ configuration: LibraryGroupingConfiguration) {
        groupingState.withLock { $0 = configuration }
    }

    enum MetaKey {
        static let schemaVersion = "schemaVersion"
        static let collationLocale = "collationLocale"
        static let revision = "revision"
        static let generation = "generation"
        static let sortIndexesDeferred = "sortIndexesDeferred"
        /// 迁移后留到后台补建的排序索引还没建完(`buildPendingSortIndexes`)。
        static let sortIndexesPending = "sortIndexesPending"
        static let importState = "import.state"
        static let importCursorOrderKey = "import.cursor.orderKey"
        static let importCursorID = "import.cursor.id"
        static let importStoreRevision = "import.storeRevision"
        static let importedCount = "import.count"
        static let groupingFingerprint = "grouping.fingerprint"
        static let groupingRebuildPhase = "grouping.rebuild.phase"
        static let groupingRebuildCursor = "grouping.rebuild.cursor"
        static let groupingGeneration = "grouping.generation"
        static let frozenAt = "frozenView.at"
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
                PRAGMA threads = \(LibraryCatalogSchema.sorterThreads);
                """)
        }
        pool = try DatabasePool(path: path, configuration: configuration)
        reader = pool
        frozenFrom = nil
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        var migrator = DatabaseMigrator()
        LibraryCatalogSchema.registerMigrations(in: &migrator)
        try migrator.migrate(pool)
        try pool.write { db in
            if try Self.metaValue(MetaKey.schemaVersion, in: db) == nil {
                try Self.setMeta(MetaKey.schemaVersion, String(LibraryCatalogSchema.schemaVersion), in: db)
                // 新建的空目录按默认输入算是已分好组;此后每次 `apply` 增量维护。
                try Self.setMeta(MetaKey.groupingFingerprint, LibraryGroupingConfiguration().fingerprint, in: db)
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
                // 打开要快:建索引慢的那几条排序索引不在这里建,记成待建,由后台补。
                try LibraryCatalogSchema.createDeferredIndexes(db, includingBackgroundSortIndexes: false)
                try Self.setMeta(MetaKey.sortIndexesDeferred, "0", in: db)
                try Self.notePendingSortIndexes(in: db)
            }
        }
    }

    private init(frozenFrom base: LibraryCatalog, snapshot: DatabaseSnapshotPool) {
        path = base.path
        pool = base.pool
        reader = snapshot
        frozenFrom = base
        replaceGroupingConfiguration(base.groupingConfiguration)
    }

    /// 此刻目录的只读视图:查询一直看到冻结那一刻的样子,哪怕实时目录随后在整库重建分组、对账。
    /// 写仍落到实时目录。视图持有一个 WAL 快照,检查点越不过它,用完就放掉(不再引用即可)。
    public func frozenView() throws -> LibraryCatalog {
        // SQLite 只在 WAL 里已经写过事务时才取得到快照(刚打开的目录 WAL 是空的):先记一笔不动内容的 meta。
        try pool.write { db in
            try Self.setMeta(MetaKey.frozenAt, String(Date().timeIntervalSince1970), in: db)
        }
        return LibraryCatalog(frozenFrom: self, snapshot: try pool.makeSnapshotPool())
    }

    /// 上次的整库分组重建没做完(各表此刻是新旧混着的):这时冻结出来的视图不一致,不能给读者。
    public var groupingRebuildInProgress: Bool {
        get throws { try pool.read { db in try Self.metaValue(MetaKey.groupingRebuildPhase, in: db) != nil } }
    }

    /// 前后台切换、内存告警时调用:放掉各连接的页缓存。
    public func releaseMemory() {
        songListCache.removeAll()
        pool.releaseMemory()
        live.pointReaderLock.withLock { live.pointReader }?.releaseMemory()
    }

    /// 在按 id 读专用的那个连接上读实时目录。主线程上按 id 读一首不排在连接池后面:池里的读连接
    /// (`maximumReaderCount` 个)都被整库排序、遍历占着时,排队要等上一整趟查询。
    /// 只给读歌曲行本身(`song` 与 `source` 两张表)的查询用:冻结视图存在期间这里读到的仍是实时目录,
    /// 歌曲行照样对(那之后的改动都在待写登记里),分组派生的各表可能正重建到一半,不能经这里读。
    func pointRead<T>(_ body: (Database) throws -> T) throws -> T {
        let base = live
        let queue = try base.pointReaderLock.withLock { () throws -> DatabaseQueue in
            if let existing = base.pointReader { return existing }
            var configuration = Configuration()
            configuration.readonly = true
            configuration.label = "Primuse library catalog by-id reads"
            configuration.prepareDatabase { db in
                try db.execute(sql: """
                    PRAGMA cache_size = -\(LibraryScale.pointReaderCacheKiB);
                    PRAGMA mmap_size = \(LibraryScale.mmapSize);
                    """)
            }
            let opened = try DatabaseQueue(path: base.path, configuration: configuration)
            base.pointReader = opened
            return opened
        }
        return try queue.read(body)
    }

    /// 按 id 取一张专辑、一位艺人这类只碰几行的读:平时也走那个专用的连接;这是冻结视图时读冻结那一刻的
    /// 各表(实时目录的分组表可能正重建到一半),经它自己的读连接。
    func pointReadOfGrouping<T>(_ body: (Database) throws -> T) throws -> T {
        if isFrozenView { return try reader.read(body) }
        return try pointRead(body)
    }

    /// 歌曲内容修订号:每次 `apply` 有改动就递增。
    public func revision() throws -> Int64 {
        try reader.read { db in try Self.revision(in: db) }
    }

    public func collationLocaleIdentifier() throws -> String? {
        try reader.read { db in try Self.metaValue(MetaKey.collationLocale, in: db) }
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
