import Foundation
import GRDB
import SQLite3

/// `songMaintenance` 的标记位:标签补读(`MetadataBackfillService`)逐首记的账。
///
/// - 0–4 位是「读过了」一类,几乎每首都有;
/// - 8 位起是少数行才有的(失败、待重试、本次启动的暂停……),进 `songMaintenance_rare` 部分索引;
/// - 16–18 位只在本次启动有效,下次启动先清掉(`resetSessionMaintenanceFlags`);
/// - 24–27 位不是标记,是诊断记录的种类(`LibraryCatalogMaintenanceNote.kind`),由 `note` 读写。
public struct LibraryCatalogMaintenanceFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue & Self.flagDomain }

    public static let titleChecked = Self(rawValue: 1 << 0)
    public static let albumArtistChecked = Self(rawValue: 1 << 1)
    public static let albumArtistRechecked = Self(rawValue: 1 << 2)
    public static let artistChecked = Self(rawValue: 1 << 3)
    public static let artworkGivenUp = Self(rawValue: 1 << 4)

    public static let failed = Self(rawValue: 1 << 8)
    public static let incomplete = Self(rawValue: 1 << 9)
    public static let sourceIssue = Self(rawValue: 1 << 10)
    public static let deferredRetry = Self(rawValue: 1 << 11)
    public static let albumArtistUnconfirmed = Self(rawValue: 1 << 12)
    public static let peerLyricsPending = Self(rawValue: 1 << 13)
    public static let deferredArtwork = Self(rawValue: 1 << 14)
    public static let playbackArtwork = Self(rawValue: 1 << 15)

    public static let sessionGivenUp = Self(rawValue: 1 << 16)
    public static let sessionNetworkParked = Self(rawValue: 1 << 17)
    public static let sessionStallParked = Self(rawValue: 1 << 18)

    /// 只在本次启动有效的位。
    public static let session: Self = [.sessionGivenUp, .sessionNetworkParked, .sessionStallParked]
    /// 少数行才有的位(都在 8 位以上)。诊断种类的 24–27 位也算在部分索引里(见 `rareStorageMask`)。
    public static let rare = Self(rawValue: 0x00FF_FF00)

    /// 标记位能用的范围;再往上是诊断种类。
    static let flagDomain: UInt32 = 0x00FF_FFFF
    static let noteKindShift: UInt32 = 24
    static let noteKindMask: UInt32 = 0x0F00_0000
    /// 部分索引覆盖的存储位:少数行才有的标记,外加诊断种类。
    static let rareStorageMask: UInt32 = 0xFFFF_FF00
}

/// 一首歌最近一次失败的诊断:种类(1–15,含义由调用方定)、说明与时间。
public struct LibraryCatalogMaintenanceNote: Sendable, Equatable {
    public var kind: UInt8
    public var detail: String
    public var lastAttemptAt: Double?

    public init(kind: UInt8, detail: String, lastAttemptAt: Double?) {
        self.kind = min(max(kind, 1), 15)
        self.detail = detail
        self.lastAttemptAt = lastAttemptAt
    }
}

/// `songMaintenance` 的一行。没有行就是 `empty`。
public struct LibraryCatalogMaintenanceRow: Sendable, Equatable {
    public var flags: LibraryCatalogMaintenanceFlags
    public var retryCount: Int
    public var note: LibraryCatalogMaintenanceNote?

    public init(flags: LibraryCatalogMaintenanceFlags = [], retryCount: Int = 0, note: LibraryCatalogMaintenanceNote? = nil) {
        self.flags = flags
        self.retryCount = max(0, retryCount)
        self.note = note
    }

    public static let empty = LibraryCatalogMaintenanceRow()

    public var isEmpty: Bool { flags.isEmpty && retryCount == 0 && note == nil }

    var storedFlags: Int64 {
        Int64(flags.rawValue | (UInt32(note?.kind ?? 0) << LibraryCatalogMaintenanceFlags.noteKindShift))
    }

    init(storedFlags: Int64, retryCount: Int, lastAttemptAt: Double?, detail: String?) {
        let raw = UInt32(truncatingIfNeeded: storedFlags)
        let kind = UInt8((raw & LibraryCatalogMaintenanceFlags.noteKindMask) >> LibraryCatalogMaintenanceFlags.noteKindShift)
        self.init(
            flags: LibraryCatalogMaintenanceFlags(rawValue: raw),
            retryCount: retryCount,
            note: kind == 0 ? nil : LibraryCatalogMaintenanceNote(kind: kind, detail: detail ?? "", lastAttemptAt: lastAttemptAt)
        )
    }
}

/// 一首歌的一笔改动:先清 `clearFlags` 再置 `setFlags`,重试次数与诊断给了才改。
/// 几笔按先后用 `then` 合成一笔,结果与逐笔落库相同。
public struct LibraryCatalogMaintenanceDelta: Sendable, Equatable {
    public enum NoteChange: Sendable, Equatable {
        case set(LibraryCatalogMaintenanceNote)
        case clear
        /// 种类在掩码里(第 k 位对应种类 k)才清。
        case clearIfKind(UInt16)
    }

    public var setFlags: LibraryCatalogMaintenanceFlags
    public var clearFlags: LibraryCatalogMaintenanceFlags
    public var retryCount: Int?
    public var note: NoteChange?

    public init(
        setFlags: LibraryCatalogMaintenanceFlags = [],
        clearFlags: LibraryCatalogMaintenanceFlags = [],
        retryCount: Int? = nil,
        note: NoteChange? = nil
    ) {
        self.setFlags = setFlags
        self.clearFlags = clearFlags.subtracting(setFlags)
        self.retryCount = retryCount.map { max(0, $0) }
        self.note = note
    }

    /// 整行换成 `row`。
    public static func replacing(with row: LibraryCatalogMaintenanceRow) -> Self {
        Self(
            setFlags: row.flags,
            clearFlags: LibraryCatalogMaintenanceFlags(rawValue: LibraryCatalogMaintenanceFlags.flagDomain),
            retryCount: row.retryCount,
            note: row.note.map(NoteChange.set) ?? .clear
        )
    }

    public var isNoop: Bool { setFlags.isEmpty && clearFlags.isEmpty && retryCount == nil && note == nil }

    /// 先这一笔,再 `later`。
    public func then(_ later: Self) -> Self {
        var result = Self(
            setFlags: setFlags.subtracting(later.clearFlags).union(later.setFlags),
            clearFlags: clearFlags.subtracting(later.setFlags).union(later.clearFlags),
            retryCount: later.retryCount ?? retryCount
        )
        switch (note, later.note) {
        case (let earlier, nil):
            result.note = earlier
        case (_, .set(let value)):
            result.note = .set(value)
        case (_, .clear):
            result.note = .clear
        case (nil, .clearIfKind(let mask)):
            result.note = .clearIfKind(mask)
        case (.set(let value), .clearIfKind(let mask)):
            result.note = Self.matches(value.kind, mask) ? .clear : .set(value)
        case (.clear, .clearIfKind):
            result.note = .clear
        case (.clearIfKind(let first), .clearIfKind(let second)):
            result.note = .clearIfKind(first | second)
        }
        return result
    }

    public func applied(to row: LibraryCatalogMaintenanceRow) -> LibraryCatalogMaintenanceRow {
        var result = row
        result.flags = row.flags.subtracting(clearFlags).union(setFlags)
        if let retryCount { result.retryCount = retryCount }
        switch note {
        case nil: break
        case .set(let value): result.note = value
        case .clear: result.note = nil
        case .clearIfKind(let mask):
            if let kind = row.note?.kind, Self.matches(kind, mask) { result.note = nil }
        }
        return result
    }

    static func matches(_ kind: UInt8, _ mask: UInt16) -> Bool {
        kind < 16 && mask & (1 << UInt16(kind)) != 0
    }
}

extension LibraryCatalog {
    static let maintenanceMetaPrefix = "maintenance."
    /// 有本次启动才有效的位落过库;下次启动据此才去清(不为每次启动扫一遍表)。
    static let maintenanceSessionMetaKey = "maintenance.sessionFlags"

    static let maintenanceRowSQL = "SELECT flags, retryCount, lastAttemptAt, detail FROM songMaintenance WHERE songID = ?"

    static func maintenanceRow(_ row: Row) -> LibraryCatalogMaintenanceRow {
        LibraryCatalogMaintenanceRow(storedFlags: row[0], retryCount: row[1], lastAttemptAt: row[2], detail: row[3])
    }

    /// 按 id 逐个查(主键点查),结果与输入一一对应;没有行的是 `empty`。整库对账每首查一次,
    /// 直接用 `sqlite3_*` 绑定、取列,不经 GRDB 的参数与行对象(那一层比点查本身还贵)。
    static func fetchMaintenanceRows(_ db: Database, songIDs: some Sequence<String>) throws -> [LibraryCatalogMaintenanceRow] {
        let statement = try db.cachedStatement(sql: maintenanceRowSQL)
        let handle = statement.sqliteStatement
        var rows: [LibraryCatalogMaintenanceRow] = []
        rows.reserveCapacity(songIDs.underestimatedCount)
        for id in songIDs {
            var text = id
            let code: Int32 = text.withUTF8 { buffer -> Int32 in
                buffer.withMemoryRebound(to: CChar.self) { chars in
                    sqlite3_bind_text(handle, 1, chars.baseAddress, Int32(chars.count), nil)
                }
                return sqlite3_step(handle)
            }
            defer {
                sqlite3_reset(handle)
                sqlite3_clear_bindings(handle)
            }
            switch code {
            case SQLITE_ROW:
                let lastAttemptAt = sqlite3_column_type(handle, 2) == SQLITE_NULL ? nil : sqlite3_column_double(handle, 2)
                let detail = sqlite3_column_type(handle, 3) == SQLITE_NULL ? nil : sqlite3_column_text(handle, 3).map {
                    String(cString: $0)
                }
                rows.append(LibraryCatalogMaintenanceRow(
                    storedFlags: sqlite3_column_int64(handle, 0),
                    retryCount: Int(sqlite3_column_int64(handle, 1)),
                    lastAttemptAt: lastAttemptAt,
                    detail: detail
                ))
            case SQLITE_DONE:
                rows.append(.empty)
            default:
                throw DatabaseError(
                    resultCode: ResultCode(rawValue: code),
                    message: String(cString: sqlite3_errmsg(db.sqliteConnection)),
                    sql: statement.sql
                )
            }
        }
        return rows
    }

    /// 带位的条件:只问少数行才有的位时,写成部分索引的那个表达式,只扫那几行。
    static func maintenanceFlagsTerm(_ flags: LibraryCatalogMaintenanceFlags) -> String {
        let mask = flags.rawValue
        if mask & ~LibraryCatalogMaintenanceFlags.rareStorageMask == 0 {
            return "\(LibraryCatalogSchema.maintenanceRareTerm) AND (flags & \(mask)) != 0"
        }
        return "(flags & \(mask)) != 0"
    }

    // MARK: - Reads

    /// 一批歌的记账行,与输入一一对应(没有行的是 `empty`)。走连接池;主线程上的同步点查用
    /// `makeMaintenanceReader()` 的专用连接。
    public func maintenanceRows(songIDs: [String]) throws -> [LibraryCatalogMaintenanceRow] {
        guard !songIDs.isEmpty else { return [] }
        return try pool.read { db in try Self.fetchMaintenanceRows(db, songIDs: songIDs) }
    }

    /// 带某几位(任一)的歌曲 id,按 id 排,从 `after` 之后起至多 `limit` 个(分页列出,内存只占一页)。
    public func maintenanceSongIDs(
        withAny flags: LibraryCatalogMaintenanceFlags,
        after cursor: String? = nil,
        limit: Int = LibraryScale.maxMaterializedRows
    ) throws -> [String] {
        try pool.read { db in try Self.maintenanceSongIDs(db, withAny: flags, after: cursor, limit: limit) }
    }

    /// 带某几位(任一)的行数。
    public func maintenanceCount(withAny flags: LibraryCatalogMaintenanceFlags) throws -> Int {
        try pool.read { db in try Self.maintenanceCount(db, withAny: flags) }
    }

    /// 有没有带某几位(任一)的行。
    public func hasMaintenanceRows(withAny flags: LibraryCatalogMaintenanceFlags) throws -> Bool {
        try pool.read { db in try Self.hasMaintenanceRows(db, withAny: flags) }
    }

    static func maintenanceSongIDs(
        _ db: Database,
        withAny flags: LibraryCatalogMaintenanceFlags,
        after cursor: String?,
        limit: Int
    ) throws -> [String] {
        guard !flags.isEmpty else { return [] }
        let cap = min(max(0, limit), LibraryScale.maxMaterializedRows)
        guard cap > 0 else { return [] }
        return try String.fetchAll(
            db,
            sql: """
                SELECT songID FROM songMaintenance
                WHERE \(maintenanceFlagsTerm(flags)) AND songID > ?
                ORDER BY songID LIMIT ?
                """,
            arguments: [cursor ?? "", cap]
        )
    }

    static func maintenanceCount(_ db: Database, withAny flags: LibraryCatalogMaintenanceFlags) throws -> Int {
        guard !flags.isEmpty else { return 0 }
        return try Int.fetchOne(db, sql: "SELECT count(*) FROM songMaintenance WHERE \(maintenanceFlagsTerm(flags))") ?? 0
    }

    static func hasMaintenanceRows(_ db: Database, withAny flags: LibraryCatalogMaintenanceFlags) throws -> Bool {
        guard !flags.isEmpty else { return false }
        return try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS(SELECT 1 FROM songMaintenance WHERE \(maintenanceFlagsTerm(flags)))"
        ) ?? false
    }

    /// 整张表的行数(诊断日志用)。
    public func maintenanceRowCount() throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM songMaintenance") ?? 0 }
    }

    // MARK: - Writes

    /// 在一个写事务里落一批改动:先按 `clearing` 把所有行的这些位清掉(对应「整套清空」),
    /// 再逐首读出、合上改动、写回;合完是空行就删掉。只写变了的行。
    public func applyMaintenance(
        _ changes: some Sequence<(songID: String, delta: LibraryCatalogMaintenanceDelta)>,
        clearing: LibraryCatalogMaintenanceFlags = []
    ) throws {
        try pool.write { db in
            if !clearing.isEmpty { try Self.clearMaintenanceFlags(clearing, in: db) }
            let select = try db.cachedStatement(sql: Self.maintenanceRowSQL)
            let upsert = try db.cachedStatement(sql: """
                INSERT INTO songMaintenance (songID, flags, retryCount, lastAttemptAt, detail) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(songID) DO UPDATE SET flags = excluded.flags, retryCount = excluded.retryCount,
                    lastAttemptAt = excluded.lastAttemptAt, detail = excluded.detail
                """)
            let delete = try db.cachedStatement(sql: "DELETE FROM songMaintenance WHERE songID = ?")
            var setsSessionFlags = false
            for (songID, delta) in changes where !delta.isNoop {
                guard !songID.utf8.contains(0) else { throw LibraryCatalogError.invalidIdentifier(songID) }
                let existing = try Row.fetchOne(select, arguments: [songID]).map(Self.maintenanceRow)
                let updated = delta.applied(to: existing ?? .empty)
                if !delta.setFlags.isDisjoint(with: .session) { setsSessionFlags = true }
                guard updated != existing else { continue }
                if updated.isEmpty {
                    if existing != nil { try delete.execute(arguments: [songID]) }
                } else {
                    try upsert.execute(arguments: [
                        songID, updated.storedFlags, updated.retryCount,
                        updated.note?.lastAttemptAt, updated.note?.detail,
                    ])
                }
            }
            if setsSessionFlags { try Self.setMeta(Self.maintenanceSessionMetaKey, "1", in: db) }
        }
    }

    /// 所有行清掉这些位(对应某一套「整个清空」)。
    public func clearMaintenanceFlags(_ flags: LibraryCatalogMaintenanceFlags) throws {
        guard !flags.isEmpty else { return }
        try pool.write { db in try Self.clearMaintenanceFlags(flags, in: db) }
    }

    static func clearMaintenanceFlags(_ flags: LibraryCatalogMaintenanceFlags, in db: Database) throws {
        // 先删清完就空了的行,再清剩下的;两句都只碰带这些位的行(少数位走部分索引)。
        let mask = Int64(flags.rawValue)
        let term = maintenanceFlagsTerm(flags)
        try db.execute(
            sql: """
                DELETE FROM songMaintenance WHERE \(term) AND (flags & ~?) = 0
                    AND retryCount = 0 AND detail IS NULL AND lastAttemptAt IS NULL
                """,
            arguments: [mask]
        )
        try db.execute(sql: "UPDATE songMaintenance SET flags = flags & ~? WHERE \(term)", arguments: [mask])
    }

    /// 启动时调一次:清掉上次启动留下的本次有效的位。上次没落过这些位就什么都不做。返回清没清。
    @discardableResult
    public func resetSessionMaintenanceFlags() throws -> Bool {
        try pool.write { db in
            guard try Self.metaValue(Self.maintenanceSessionMetaKey, in: db) != nil else { return false }
            try Self.clearMaintenanceFlags(.session, in: db)
            try Self.removeMeta(Self.maintenanceSessionMetaKey, in: db)
            return true
        }
    }

    // MARK: - Meta

    public func maintenanceValue(_ key: String) throws -> String? {
        try pool.read { db in try Self.metaValue(Self.maintenanceMetaPrefix + key, in: db) }
    }

    /// 一个事务里写多项;值为 nil 的删掉。
    public func setMaintenanceValues(_ values: [String: String?]) throws {
        guard !values.isEmpty else { return }
        try pool.write { db in
            for (key, value) in values {
                if let value {
                    try Self.setMeta(Self.maintenanceMetaPrefix + key, value, in: db)
                } else {
                    try Self.removeMeta(Self.maintenanceMetaPrefix + key, in: db)
                }
            }
        }
    }

    // MARK: - Point reads

    /// 专用的只读连接,给主线程上的同步点查:不跟连接池里的长查询(流式遍历、整表排序)抢那两个读连接。
    public func makeMaintenanceReader() throws -> LibraryCatalogMaintenanceReader {
        try LibraryCatalogMaintenanceReader(path: path)
    }

    // MARK: - Joined stream

    /// 按库内顺序流式遍历一个范围的整首歌,连同它的记账行(没有行的是 `empty`),每批
    /// `LibraryScale.importBatchSize` 首,内存只占一批。目录追上内存模型之后,补读的计数与选批可以直接走这里。
    public func forEachSongMaintenance(
        _ scope: LibrarySongScope,
        _ body: (_ rowid: Int32, _ song: Song, _ maintenance: LibraryCatalogMaintenanceRow) throws -> Bool
    ) throws {
        let first = LibraryCatalogSongCodec.Column.extra + 1
        var lastRowid: Int64 = 0
        while true {
            var batch: [(Int32, Song, LibraryCatalogMaintenanceRow)] = []
            try pool.read { db in
                let (sql, arguments) = try scope.whereClause(in: db)
                var batchArguments = arguments
                batchArguments += [lastRowid, LibraryScale.importBatchSize]
                let rows = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT \(LibraryCatalogSongCodec.selectColumns.replacingOccurrences(of: "song.", with: "s.")),
                               m.flags, m.retryCount, m.lastAttemptAt, m.detail
                        FROM song s JOIN source ON source.key = s.sourceKey
                        LEFT JOIN songMaintenance m ON m.songID = s.id
                        WHERE \(sql) AND s.rowid > ? ORDER BY s.rowid LIMIT ?
                        """,
                    arguments: batchArguments
                )
                while let row = try rows.next() {
                    let rowid: Int64 = row[LibraryCatalogSongCodec.Column.rowid]
                    let flags: Int64? = row[first]
                    let maintenance = flags.map {
                        LibraryCatalogMaintenanceRow(
                            storedFlags: $0, retryCount: row[first + 1], lastAttemptAt: row[first + 2], detail: row[first + 3]
                        )
                    } ?? .empty
                    batch.append((try Self.rowid32(rowid), try LibraryCatalogSongCodec.decode(row), maintenance))
                }
            }
            guard let last = batch.last else { return }
            for (rowid, song, maintenance) in batch {
                guard try body(rowid, song, maintenance) else { return }
            }
            lastRowid = Int64(last.0)
            if batch.count < LibraryScale.importBatchSize { return }
        }
    }
}

/// `songMaintenance` 的专用只读连接(WAL 下与写连接并行)。点查一次几十微秒,
/// 主线程上同步调用也不会等连接池里的长查询。
public final class LibraryCatalogMaintenanceReader: @unchecked Sendable {
    private let database: DatabaseQueue

    init(path: String) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = "Primuse catalog maintenance reader"
        configuration.prepareDatabase { db in
            try db.execute(sql: """
                PRAGMA cache_size = -512;
                PRAGMA mmap_size = \(LibraryScale.mmapSize);
                """)
        }
        database = try DatabaseQueue(path: path, configuration: configuration)
    }

    public func row(songID: String) throws -> LibraryCatalogMaintenanceRow {
        try rows(songIDs: [songID])[0]
    }

    /// 与输入一一对应;没有行的是 `empty`。批量预取时每批几百上千个(实测逐键点查比 `IN (…)` 一句快),
    /// 主线程上的点查最多等一批。
    public func rows(songIDs: [String]) throws -> [LibraryCatalogMaintenanceRow] {
        guard !songIDs.isEmpty else { return [] }
        return try database.read { db in try LibraryCatalog.fetchMaintenanceRows(db, songIDs: songIDs) }
    }

    /// 同 `LibraryCatalog.maintenanceSongIDs`,走这条专用连接。
    public func songIDs(
        withAny flags: LibraryCatalogMaintenanceFlags,
        after cursor: String? = nil,
        limit: Int = LibraryScale.maxMaterializedRows
    ) throws -> [String] {
        try database.read { db in try LibraryCatalog.maintenanceSongIDs(db, withAny: flags, after: cursor, limit: limit) }
    }

    public func count(withAny flags: LibraryCatalogMaintenanceFlags) throws -> Int {
        try database.read { db in try LibraryCatalog.maintenanceCount(db, withAny: flags) }
    }

    public func hasRows(withAny flags: LibraryCatalogMaintenanceFlags) throws -> Bool {
        try database.read { db in try LibraryCatalog.hasMaintenanceRows(db, withAny: flags) }
    }

    /// 前后台切换、内存告警时放掉页缓存。
    public func releaseMemory() {
        database.releaseMemory()
    }
}
