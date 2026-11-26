import Foundation
import GRDB

/// 文件夹索引按目录建时一首歌的投影:行号、所在源、目录文件夹键、路径与内容类别。
struct LibraryCatalogFolderRow {
    let rowid: Int32
    let sourceID: String
    let folderKey: Int64?
    let filePath: String
    let kind: Int
}

/// 文件夹里按曲目顺序排一首歌要的字段(不物化整首歌)。
struct LibraryCatalogFolderOrderRecord {
    let rowid: Int32
    let id: String
    let title: String
    let trackNumber: Int?
    let discNumber: Int?
    let filePath: String
}

/// 按 id 找文件夹归属时的那一行。
struct LibraryCatalogFolderLookup: Sendable {
    let rowid: Int32
    let sourceID: String
    let kind: Int
}

extension LibraryCatalog {
    /// 每批读多少行。每批一个读事务,不让整库遍历长时间占着一个读快照。
    static let folderRowBatchSize = 4_000

    /// 范围(已启用源里的这些类别,nil 为全部)内每首歌的文件夹投影,按库内顺序流式给出;
    /// 内存只占一批。`body` 返回 false 时提前结束。批与批之间写进来的新行(行号更大)
    /// 会出现在后面的批里,删掉的行不再出现。
    func forEachFolderRow(
        kinds: Set<LibraryCatalogContentKind>?,
        sourceID: String? = nil,
        _ body: (LibraryCatalogFolderRow) throws -> Bool
    ) throws {
        var lastRowid: Int64 = 0
        while true {
            var batch: [LibraryCatalogFolderRow] = []
            batch.reserveCapacity(Self.folderRowBatchSize)
            var fetched = 0
            try reader.read { db in
                var sourceIDs: [Int64: String] = [:]
                let sources = try Row.fetchCursor(db, sql: "SELECT key, id FROM source")
                while let row = try sources.next() {
                    let key: Int64 = row[0]
                    sourceIDs[key] = row[1]
                }
                let (sql, arguments) = try LibrarySongScope(kinds: kinds, sourceID: sourceID).whereClause(in: db)
                var batchArguments = arguments
                batchArguments += [lastRowid, Self.folderRowBatchSize]
                let rows = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT s.rowid, s.sourceKey, s.folderKey, s.filePath, s.kind FROM song s
                        WHERE \(sql) AND s.rowid > ? ORDER BY s.rowid LIMIT ?
                        """,
                    arguments: batchArguments
                )
                while let row = try rows.next() {
                    fetched += 1
                    let rowid: Int64 = row[0]
                    lastRowid = rowid
                    let sourceKey: Int64 = row[1]
                    guard let sourceID = sourceIDs[sourceKey] else { continue }
                    batch.append(LibraryCatalogFolderRow(
                        rowid: try Self.rowid32(rowid), sourceID: sourceID, folderKey: row[2], filePath: row[3], kind: row[4]
                    ))
                }
            }
            for row in batch {
                guard try body(row) else { return }
            }
            if fetched < Self.folderRowBatchSize { return }
        }
    }

    /// 一个文件夹里排曲目顺序要的字段,按行号取;已删掉的行不在结果里。调用方按文件夹分批。
    func folderOrderRecords(rowids: some Collection<Int32>) throws -> [Int32: LibraryCatalogFolderOrderRecord] {
        guard !rowids.isEmpty else { return [:] }
        var result: [Int32: LibraryCatalogFolderOrderRecord] = [:]
        result.reserveCapacity(rowids.count)
        try reader.read { db in
            for chunk in Self.chunks(of: Array(rowids)) {
                let rows = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT rowid, id, title, trackNumber, discNumber, filePath FROM song
                        WHERE rowid IN (\(Self.placeholders(chunk.count)))
                        """,
                    arguments: StatementArguments(chunk.map(Int64.init))
                )
                while let row = try rows.next() {
                    let rowid = try Self.rowid32(row[0])
                    result[rowid] = LibraryCatalogFolderOrderRecord(
                        rowid: rowid, id: row[1], title: row[2],
                        trackNumber: row[3], discNumber: row[4], filePath: row[5]
                    )
                }
            }
        }
        return result
    }

    /// 行号 → 歌曲 id,保持输入顺序;已删掉的行跳过。结果与输入同阶,只给模块内的文件夹索引用。
    func songIDs(rowids: some Collection<Int32>) throws -> [String] {
        guard !rowids.isEmpty else { return [] }
        let ordered = Array(rowids)
        var byRowid: [Int32: String] = [:]
        byRowid.reserveCapacity(ordered.count)
        try reader.read { db in
            for chunk in Self.chunks(of: ordered) {
                let rows = try Row.fetchCursor(
                    db,
                    sql: "SELECT rowid, id FROM song WHERE rowid IN (\(Self.placeholders(chunk.count)))",
                    arguments: StatementArguments(chunk.map(Int64.init))
                )
                while let row = try rows.next() {
                    byRowid[try Self.rowid32(row[0])] = row[1]
                }
            }
        }
        return ordered.compactMap { byRowid[$0] }
    }

    /// id → (行号, 源 id, 内容类别);不在目录里的 id 不在结果里。结果与输入同阶。
    func folderLookups(ids: some Collection<String>) throws -> [String: LibraryCatalogFolderLookup] {
        guard !ids.isEmpty else { return [:] }
        var result: [String: LibraryCatalogFolderLookup] = [:]
        try reader.read { db in
            for chunk in Self.chunks(of: Array(Set(ids))) {
                let rows = try Row.fetchCursor(
                    db,
                    sql: """
                        SELECT s.id, s.rowid, source.id, s.kind FROM song s JOIN source ON source.key = s.sourceKey
                        WHERE s.id IN (\(Self.placeholders(chunk.count)))
                        """,
                    arguments: StatementArguments(chunk)
                )
                while let row = try rows.next() {
                    result[row[0]] = LibraryCatalogFolderLookup(rowid: try Self.rowid32(row[1]), sourceID: row[2], kind: row[3])
                }
            }
        }
        return result
    }
}
