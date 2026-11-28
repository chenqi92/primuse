import Foundation
import GRDB

extension LibraryCatalog {
    /// 这些 id 里此刻在 `scope` 内的(已启用的源、这些类别、这个源……,与列表页同一口径),不物化歌。
    /// 歌曲模型不在内存里时,歌曲页的多选按它修剪已经不在这一页里的歌(6c 单元 4 U9a)。
    /// 每段一条按 id 的 `IN` 查询(走 `song.id` 唯一索引),代价与 `ids` 的个数成正比。
    public func songIDs(_ ids: some Collection<String>, inScope scope: LibrarySongScope) throws -> Set<String> {
        let requested = Array(Set(ids))
        guard !requested.isEmpty else { return [] }
        var result = Set<String>()
        try reader.read { db in
            let (scopeSQL, scopeArguments) = try scope.whereClause(in: db)
            for chunk in Self.chunks(of: requested) {
                var arguments = StatementArguments(chunk)
                arguments += scopeArguments
                let rows = try Row.fetchCursor(
                    db,
                    sql: "SELECT s.id FROM song s WHERE s.id IN (\(Self.placeholders(chunk.count))) AND \(scopeSQL)",
                    arguments: arguments
                )
                while let row = try rows.next() {
                    result.insert(row[0])
                }
            }
        }
        return result
    }

    /// 这些 id 各自的行号,与输入一一对应;不在 `scope` 内(停用的源、别的类别)或目录里没有的是 nil。
    /// 一列 id 按页物化成行时用(6c 单元 4 U9b:搜索与目录页「查看全部」的那一页):内存里那一页只画可见的歌,
    /// 不可见的不给行号就不会被物化出来。每段一条按 id 的 `IN` 查询,一次至多 `LibraryScale.maxMaterializedRows` 个 id。
    public func rowids(forIDs ids: [String], inScope scope: LibrarySongScope) throws -> [Int32?] {
        let admitted = LibraryScaleGuard.admitMaterialization(count: ids.count)
        let requested = Array(ids.prefix(admitted))
        guard !requested.isEmpty else { return [] }
        var byID: [String: Int32] = [:]
        try reader.read { db in
            let (scopeSQL, scopeArguments) = try scope.whereClause(in: db)
            for chunk in Self.chunks(of: Array(Set(requested))) {
                var arguments = StatementArguments(chunk)
                arguments += scopeArguments
                let rows = try Row.fetchCursor(
                    db,
                    sql: "SELECT s.id, s.rowid FROM song s WHERE s.id IN (\(Self.placeholders(chunk.count))) AND \(scopeSQL)",
                    arguments: arguments
                )
                while let row = try rows.next() {
                    byID[row[0]] = try Self.rowid32(row[1])
                }
            }
        }
        return requested.map { byID[$0] }
    }
}
