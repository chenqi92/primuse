import Foundation
import GRDB

/// `songOffline` 的一行:这首歌已下载(离线固定)的那份有多大、什么时候记的。
public struct LibraryCatalogOfflineEntry: Sendable, Equatable {
    public var state: LibraryCatalogOfflineState
    public var bytes: Int64
    public var updatedAt: Double?

    public init(state: LibraryCatalogOfflineState = .downloaded, bytes: Int64, updatedAt: Double? = nil) {
        self.state = state
        self.bytes = max(0, bytes)
        self.updatedAt = updatedAt
    }
}

/// 离线状态表(`songOffline`)。按行号记,「已下载」过滤与排序直接连这张表。
///
/// 行号 0 的那一行是标记:整张表已经按当前目录填满(`finishOfflinePopulation`)。导入会清空这张表,
/// 标记跟着没了,`offlineStateIsCurrent()` 就回答 false,调用方照旧走自己的路径并重新填一遍。
/// 这里的写入不推进目录的修订号(列表另有离线的修订号),只让按修订号缓存的排序结果作废。
extension LibraryCatalog {
    static let offlineSentinelRowid: Int64 = 0

    /// `songOffline` 已经按当前这一份目录填满(导入之后要重新填)。
    public func offlineStateIsCurrent() throws -> Bool {
        try pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM songOffline WHERE songRowid = ?)",
                arguments: [Self.offlineSentinelRowid]
            ) ?? false
        }
    }

    /// 开始整表重填:清掉所有行和标记。
    public func beginOfflinePopulation() throws {
        try pool.write { db in try db.execute(sql: "DELETE FROM songOffline") }
        songListCache.removeAll()
    }

    /// 整表填完:写上标记。
    public func finishOfflinePopulation() throws {
        try pool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO songOffline (songRowid, state, bytes, updatedAt) VALUES (?, 0, 0, ?)",
                arguments: [Self.offlineSentinelRowid, Date().timeIntervalSinceReferenceDate]
            )
        }
    }

    /// 表可能跟实际对不上了(下载清单在别处变过):去掉标记,行留着,等下一次重填。
    public func invalidateOfflineState() throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM songOffline WHERE songRowid = ?", arguments: [Self.offlineSentinelRowid])
        }
    }

    /// 按歌曲 id 写:有值 upsert,nil 删掉。返回目录里还没有的 id(目录跟写慢一拍),调用方稍后再写。
    @discardableResult
    public func setOfflineEntries(_ entries: [(songID: String, entry: LibraryCatalogOfflineEntry?)]) throws -> [String] {
        guard !entries.isEmpty else { return [] }
        let missing: [String] = try pool.write { db in
            let rowidByID = try db.cachedStatement(sql: "SELECT rowid FROM song WHERE id = ?")
            var missing: [String] = []
            for (songID, entry) in entries {
                guard let rowid = try Int64.fetchOne(rowidByID, arguments: [songID]) else {
                    missing.append(songID)
                    continue
                }
                try Self.writeOfflineEntry(entry, rowid: rowid, in: db)
            }
            return missing
        }
        songListCache.removeAll()
        return missing
    }

    /// 按行号写(整表重填时流式遍历拿到的就是行号)。
    public func setOfflineEntries(rowids entries: [(rowid: Int32, entry: LibraryCatalogOfflineEntry?)]) throws {
        guard !entries.isEmpty else { return }
        try pool.write { db in
            for (rowid, entry) in entries where Int64(rowid) != Self.offlineSentinelRowid {
                try Self.writeOfflineEntry(entry, rowid: Int64(rowid), in: db)
            }
        }
        songListCache.removeAll()
    }

    private static func writeOfflineEntry(_ entry: LibraryCatalogOfflineEntry?, rowid: Int64, in db: Database) throws {
        if let entry {
            try db.cachedStatement(sql: """
                INSERT INTO songOffline (songRowid, state, bytes, updatedAt) VALUES (?, ?, ?, ?)
                ON CONFLICT(songRowid) DO UPDATE SET state = excluded.state, bytes = excluded.bytes,
                    updatedAt = excluded.updatedAt
                """).execute(arguments: [rowid, entry.state.rawValue, entry.bytes, entry.updatedAt])
        } else {
            try db.cachedStatement(sql: "DELETE FROM songOffline WHERE songRowid = ?").execute(arguments: [rowid])
        }
    }

    /// 一批歌的离线行,与输入一一对应;没有的是 nil(有界,一次至多 `LibraryScale.maxMaterializedRows` 个)。
    public func offlineEntries(songIDs: [String]) throws -> [LibraryCatalogOfflineEntry?] {
        let requested = songIDs.prefix(LibraryScaleGuard.admitMaterialization(count: songIDs.count))
        guard !requested.isEmpty else { return [] }
        return try pool.read { db in
            let statement = try db.cachedStatement(sql: """
                SELECT o.state, o.bytes, o.updatedAt FROM song s JOIN songOffline o ON o.songRowid = s.rowid
                WHERE s.id = ?
                """)
            return try requested.map { songID in
                guard let row = try Row.fetchOne(statement, arguments: [songID]),
                      let state = LibraryCatalogOfflineState(rawValue: row[0]) else { return nil }
                return LibraryCatalogOfflineEntry(state: state, bytes: row[1], updatedAt: row[2])
            }
        }
    }

    /// 某种状态的行数(不含标记)。
    public func offlineCount(_ state: LibraryCatalogOfflineState = .downloaded, scope: LibrarySongScope = .everything) throws -> Int {
        try pool.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            var all = StatementArguments([state.rawValue])
            all += arguments
            return try Int.fetchOne(
                db,
                sql: """
                    SELECT count(*) FROM songOffline o JOIN song s ON s.rowid = o.songRowid
                    WHERE o.state = ? AND o.songRowid > 0 AND \(sql)
                    """,
                arguments: all
            ) ?? 0
        }
    }

    /// 某种状态的行号,库内顺序。
    public func offlineRowList(_ state: LibraryCatalogOfflineState = .downloaded, scope: LibrarySongScope = .everything) throws -> LibraryRowList {
        try pool.read { db in
            let revision = try Self.revision(in: db)
            let (sql, arguments) = try scope.whereClause(in: db)
            var all = StatementArguments([state.rawValue])
            all += arguments
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT s.rowid FROM songOffline o JOIN song s ON s.rowid = o.songRowid
                    WHERE o.state = ? AND o.songRowid > 0 AND \(sql) ORDER BY s.rowid
                    """,
                arguments: all
            )
            var rowids = ContiguousArray<Int32>()
            while let row = try rows.next() { rowids.append(try Self.rowid32(row[0])) }
            return LibraryRowList(rowids: rowids, revision: revision)
        }
    }

    /// 按库内顺序流式遍历某种状态的歌(连同离线行),每批 `LibraryScale.importBatchSize` 首。
    public func forEachOfflineSong(
        _ state: LibraryCatalogOfflineState = .downloaded,
        scope: LibrarySongScope = .everything,
        _ body: (_ rowid: Int32, _ song: Song, _ entry: LibraryCatalogOfflineEntry) throws -> Bool
    ) throws {
        let first = LibraryCatalogSongCodec.Column.extra + 1
        var lastRowid: Int64 = 0
        while true {
            var batch: [(Int32, Song, LibraryCatalogOfflineEntry)] = []
            try pool.read { db in
                let (sql, arguments) = try scope.whereClause(in: db)
                var all = StatementArguments([state.rawValue])
                all += arguments
                all += [lastRowid, LibraryScale.importBatchSize]
                let rows = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT \(LibraryCatalogSongCodec.selectColumns.replacingOccurrences(of: "song.", with: "s.")),
                               o.bytes, o.updatedAt
                        FROM songOffline o JOIN song s ON s.rowid = o.songRowid JOIN source ON source.key = s.sourceKey
                        WHERE o.state = ? AND \(sql) AND s.rowid > ? ORDER BY s.rowid LIMIT ?
                        """,
                    arguments: all
                )
                while let row = try rows.next() {
                    let rowid: Int64 = row[LibraryCatalogSongCodec.Column.rowid]
                    batch.append((
                        try Self.rowid32(rowid),
                        try LibraryCatalogSongCodec.decode(row),
                        LibraryCatalogOfflineEntry(state: state, bytes: row[first], updatedAt: row[first + 1])
                    ))
                }
            }
            guard let last = batch.last else { return }
            for (rowid, song, entry) in batch {
                guard try body(rowid, song, entry) else { return }
            }
            lastRowid = Int64(last.0)
            if batch.count < LibraryScale.importBatchSize { return }
        }
    }
}
