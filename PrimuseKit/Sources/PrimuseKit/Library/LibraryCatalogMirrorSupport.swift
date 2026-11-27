import Foundation
import GRDB

/// App 双写(曲库目录跟着 `library-songs.sqlite` 写)要的两处支撑:
/// - 目录 meta 里的镜像状态(带 `mirror.` 前缀,和目录自己的键分开);
/// - 按库内顺序分批读 `library-songs.sqlite`,给对账与追平用。
///
/// 放在 Catalog/ 之外,只用到目录的 meta 读写与导入状态这两处模块内接口。
extension LibraryCatalog {
    static let mirrorMetaPrefix = "mirror."

    public func mirrorMetadata(_ key: String) throws -> String? {
        try pool.read { db in try Self.metaValue(Self.mirrorMetaPrefix + key, in: db) }
    }

    /// 一个事务里写多项;值为 nil 的删掉。
    public func setMirrorMetadata(_ values: [String: String?]) throws {
        guard !values.isEmpty else { return }
        try pool.write { db in
            for (key, value) in values {
                if let value {
                    try Self.setMeta(Self.mirrorMetaPrefix + key, value, in: db)
                } else {
                    try Self.removeMeta(Self.mirrorMetaPrefix + key, in: db)
                }
            }
        }
    }

    /// 从 `library-songs.sqlite` 的导入完整走完过一次(此后靠增量写入跟着走)。
    public var hasCompletedImport: Bool {
        get throws {
            try pool.read { db in try Self.metaValue(MetaKey.importState, in: db) == "complete" }
        }
    }

    /// 下一次 `LibraryCatalogImporter.importIncrementalSongStore` 从头导入:
    /// 旧库被整份替换(外部快照、恢复写入)之后,目录的行序与内容都要换成新的。
    public func invalidateImport() throws {
        try pool.write { db in
            try Self.setMeta(MetaKey.importState, "invalidated", in: db)
        }
    }
}

/// `library-songs.sqlite` 的一行:库内顺序键与解码后的歌。
public struct IncrementalSongStoreRow: Sendable {
    public let orderKey: Int64
    public let song: Song
}

/// 只读、按批读 `library-songs.sqlite`。独立的只读连接(WAL 下与写连接并行),
/// 内存只占一批。
public final class IncrementalSongStoreScanner: @unchecked Sendable {
    /// 变更流水的重放(`Catalog/LibraryCatalogImporter.swift` 里的 `replayChanges`)也经这个连接读。
    let database: DatabaseQueue

    public init(path: String) throws {
        var configuration = Configuration()
        configuration.readonly = true
        configuration.label = "Primuse song store scanner"
        // 曲库目录在冷启动时就打开旧库来读,可能正赶上装载那一边打开它(恢复 WAL、建表):等一下,不当场报忙。
        configuration.busyMode = .timeout(1)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA cache_size = -2048")
        }
        database = try DatabaseQueue(path: path, configuration: configuration)
    }

    public func contentRevision() throws -> Int64 {
        try database.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT CAST(value AS INTEGER) FROM libraryStoreMetadata WHERE key = 'songs-content-revision'"
            ) ?? 0
        }
    }

    public func songCount() throws -> Int {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM librarySongRecords") ?? 0
        }
    }

    /// 库内顺序(orderKey, id)上 `cursor` 之后的至多 `limit` 行。
    public func rows(after cursor: (orderKey: Int64, id: String)?, limit: Int) throws -> [IncrementalSongStoreRow] {
        let raw: [(Int64, String, Data)] = try database.read { db in
            let sql: String
            let arguments: StatementArguments
            if let cursor {
                sql = """
                    SELECT orderKey, id, payload FROM librarySongRecords
                    WHERE (orderKey, id) > (?, ?) ORDER BY orderKey, id LIMIT ?
                    """
                arguments = [cursor.orderKey, cursor.id, limit]
            } else {
                sql = "SELECT orderKey, id, payload FROM librarySongRecords ORDER BY orderKey, id LIMIT ?"
                arguments = [limit]
            }
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { ($0[0], $0[1], $0[2]) }
        }
        let songs = try IncrementalSongStore.decodeSongs(raw.map(\.2))
        guard songs.count == raw.count else { throw LibraryCatalogError.corruptRow }
        return zip(raw, songs).map { IncrementalSongStoreRow(orderKey: $0.0, song: $1) }
    }

    /// `ids` 里在库里的那些。
    public func existingIDs(among ids: some Collection<String>) throws -> Set<String> {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [] }
        return try database.read { db in
            var found: Set<String> = []
            for start in stride(from: 0, to: unique.count, by: 500) {
                let chunk = unique[start..<min(start + 500, unique.count)]
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let cursor = try String.fetchCursor(
                    db,
                    sql: "SELECT id FROM librarySongRecords WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(Array(chunk))
                )
                while let id = try cursor.next() { found.insert(id) }
            }
            return found
        }
    }
}
