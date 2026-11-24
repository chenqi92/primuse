import Foundation
import PrimuseKit

/// P2a(资料库各页)在目录读接口上补的几种查询。都只用目录的公开接口,在主线程外执行。
extension LibraryCatalogReader {
    /// 一串行号对应的歌曲 id,保持行号的先后;已经不在 `scope` 里的跳过。
    ///
    /// 按库内顺序流式读 (行号, id),再按行号归位:不物化整首歌,也不建「行号 → id」的整表字典。
    /// 结果交给只认 id 的接口(播放器的 `play(queueIDs:)`、多选的 `SongSelectionModel`),
    /// 它们改成认行号列表之前只能这样转一次。
    func songIDs(rowids: ContiguousArray<Int32>, scope: LibrarySongScope) async throws -> [String] {
        guard !rowids.isEmpty else { return [] }
        return try await read { catalog in
            let order = rowids.indices.sorted { rowids[$0] < rowids[$1] }
            var result = [String?](repeating: nil, count: rowids.count)
            var cursor = 0
            try catalog.forEachSongIdentity(scope) { rowid, id, _ in
                while cursor < order.count, rowids[order[cursor]] < rowid { cursor += 1 }
                while cursor < order.count, rowids[order[cursor]] == rowid {
                    result[order[cursor]] = id
                    cursor += 1
                }
                return cursor < order.count
            }
            return result.compactMap { $0 }
        }
    }

    /// 「播放全部 / 随机播放全部」交给播放器的 id:可播放的音乐、不含不喜欢的,库内顺序。
    /// 与 `MusicLibrary.musicSongIDsExcludingDisliked` 经播放器 `playableOnly` 过滤后的那一份相同
    /// (那边不可播放的歌由播放器挑掉,这边在目录里先挑掉)。
    func playbackSongIDs(excluding excluded: Set<String>) async throws -> [String] {
        try await read { catalog in
            var ids: [String] = []
            try catalog.forEachSongIdentity(LibrarySongScope(kinds: [.music], playableOnly: true)) { _, id, _ in
                if !excluded.contains(id) { ids.append(id) }
                return true
            }
            return ids
        }
    }
}
