import Foundation
import GRDB

extension LibraryCatalog {
    /// 一页歌:库内顺序,行号大于 `after`,至多 `limit` 首(上限 `LibraryScale.maxMaterializedRows`)。
    /// 与 `forEachSong` 同一句查询,但一页一调:页与页之间调用方可以做异步的事(按批探测本机缓存等),
    /// 内存只占一页。翻下一页时把这一页最后一行的行号传进 `after`。
    public func songPage(
        _ scope: LibrarySongScope,
        after rowid: Int32 = 0,
        limit: Int = LibraryScale.importBatchSize
    ) throws -> [(rowid: Int32, song: Song)] {
        let cap = min(max(0, limit), LibraryScale.maxMaterializedRows)
        guard cap > 0 else { return [] }
        return try pool.read { db in
            let (sql, arguments) = try scope.whereClause(in: db)
            var pageArguments = arguments
            pageArguments += [Int64(rowid), cap]
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT \(LibraryCatalogSongCodec.selectColumns.replacingOccurrences(of: "song.", with: "s."))
                    FROM song s JOIN source ON source.key = s.sourceKey
                    WHERE \(sql) AND s.rowid > ? ORDER BY s.rowid LIMIT ?
                    """,
                arguments: pageArguments
            )
            var page: [(rowid: Int32, song: Song)] = []
            while let row = try rows.next() {
                let value: Int64 = row[LibraryCatalogSongCodec.Column.rowid]
                page.append((try Self.rowid32(value), try LibraryCatalogSongCodec.decode(row)))
            }
            return page
        }
    }
}
