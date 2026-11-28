import Foundation
import PrimuseKit

/// 目录版式建索引时 Apple Music 虚拟集合那个源的歌(6c 单元 4 U6b)。
///
/// 集合(`AppleMusicFolderSnapshot.collections(availableSongs:)`)只看这个源的歌,建索引时这个源的歌也按内存给
/// (`memorySongs`)。歌曲模型不在内存里时从曲库目录取:与内存里同一范围、同一库内顺序,不读整库数组。
enum LibraryFolderCatalogSongs {
    /// `scope` 是页面的范围(整库、某种内容、某个源);范围限定在别的源上时没有这个源的歌(空数组)。
    /// 目录读不了、读失败时回 nil:答不出来不等于没有歌,调用方这一轮不发布索引。
    static func appleMusicSongs(
        _ snapshot: MusicLibrary.AppleMusicFolderSnapshot,
        scope: LibrarySongScope,
        reader: LibraryCatalogReader?
    ) async -> [Song]? {
        let sourceID = AppleMusicLibraryIdentity.sourceID
        guard snapshot.enabled, scope.sourceID == nil || scope.sourceID == sourceID else { return [] }
        guard let reader else { return nil }
        var sourceScope = scope
        sourceScope.sourceID = sourceID
        let catalogScope = sourceScope
        do {
            return try await reader.read { catalog in
                var songs: [Song] = []
                try catalog.forEachSong(catalogScope) { _, song in
                    songs.append(song)
                    return true
                }
                return songs
            }
        } catch {
            plog("⚠️ Folder index: Apple Music songs from the catalog failed: \(error)")
            return nil
        }
    }
}
