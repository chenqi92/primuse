import Foundation
import GRDB

extension LibraryCatalog {
    /// 源内一个目录里直接放着的歌,在 `scope` 内,按库内顺序(行号)。目录的口径同
    /// `rowList(sourceID:directory:recursive: false)`:文件夹键相同(`AlbumArtistInferencePolicy.directory(ofPath:)`)。
    /// 多于 `limit` 首时返回 nil:调用方当「答不了」,不截断;目录里没有这个目录时是空的。
    ///
    /// 标签编辑器的翻页队列(同源同目录的歌)在歌曲模型不在内存里时用(6c 单元 4 U9b)。一条按文件夹键的查询
    /// (`song_folder` 索引),至多物化 `limit` 首。
    public func directorySongs(
        sourceID: String,
        directory: String,
        scope: LibrarySongScope = .visible,
        limit: Int = LibraryScale.maxMaterializedRows
    ) throws -> [Song]? {
        let cap = min(max(0, limit), LibraryScale.maxMaterializedRows)
        return try reader.read { db -> [Song]? in
            guard let folder = try Self.folderKey(sourceID: sourceID, path: Self.normalizedDirectory(directory), in: db) else {
                return []
            }
            let (scopeSQL, scopeArguments) = try scope.whereClause(in: db)
            var arguments: StatementArguments = [folder]
            arguments += scopeArguments
            arguments += [cap + 1]
            let rows = try Row.fetchCursor(
                db,
                sql: """
                    SELECT \(LibraryCatalogSongCodec.selectColumns) FROM song s
                    JOIN source ON source.key = s.sourceKey
                    WHERE s.folderKey = ? AND \(scopeSQL) ORDER BY s.rowid LIMIT ?
                    """.replacingOccurrences(of: "song.", with: "s."),
                arguments: arguments
            )
            var songs: [Song] = []
            while let row = try rows.next() {
                if songs.count == cap { return nil }
                songs.append(try LibraryCatalogSongCodec.decode(row))
            }
            return songs
        }
    }
}
