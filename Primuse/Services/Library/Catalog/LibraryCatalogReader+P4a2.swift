import Foundation
import PrimuseKit

/// P4a 第二轮(本机缓存同步、整源缓存估算)要的读接口。
extension LibraryCatalogReader {
    /// 一页歌:库内顺序,行号大于 `after`,至多 `limit` 首。页与页之间调用方可以做异步的事。
    func songPage(
        _ scope: LibrarySongScope,
        after rowid: Int32 = 0,
        limit: Int = LibraryScale.importBatchSize
    ) async throws -> [(rowid: Int32, song: Song)] {
        try await read { try $0.songPage(scope, after: rowid, limit: limit) }
    }

    /// 按 id 取一批歌(含停用源),返回 id → 歌;不在目录里的不在结果里。一次至多
    /// `LibraryScale.maxMaterializedRows` 个,多的分批取(结果以输入为界)。
    func songsByID(_ ids: some Collection<String>) async throws -> [String: Song] {
        var result: [String: Song] = [:]
        let unique = Array(Set(ids))
        var start = 0
        while start < unique.count {
            let end = min(unique.count, start + LibraryScale.maxMaterializedRows)
            let chunk = Array(unique[start..<end])
            for song in try await songs(ids: chunk, visibility: .includingDisabledSources) where result[song.id] == nil {
                result[song.id] = song
            }
            start = end
        }
        return result
    }
}
