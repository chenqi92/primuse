import Foundation
import PrimuseKit

/// 首页在歌曲模型不在内存里时读的东西(6c 单元 4 U1a)。模型在内存里时各处与以前相同,读内存模型。
extension HomeView {
    /// 首页在歌曲模型放掉之后照样从曲库目录刷新(不装模型、不占用):可用而不在内存里、目录读得到。
    /// 第一次发布之前(还没装过)不算,那时照旧走启动快照。
    @MainActor
    static func refreshesFromTheCatalog(_ library: MusicLibrary) -> Bool {
        !library.isReady && library.isUsable && PlaybackCatalogAccess.reader(for: library) != nil
    }

    /// 播放记录里不算音乐的那几类(有声、播客、环境音),同 `nonMusicSongIDs` 的口径;只在歌单里的条目照样算。
    nonisolated static let recentMusicKinds: Set<LibraryCatalogContentKind> = [.music, .collectionOnly]

    /// 最近播放的音乐(S6),同 `recentlyPlayedSongs(limit:)`:按播放记录的先后,只要可见、不是有声或环境音的。
    /// 模型不在内存里时按 id 从曲库目录取,不读整库数组。目录答不了时为 nil(调用方留着上一次的)。
    @MainActor
    static func recentMusicSongs(limit: Int, library: MusicLibrary) async -> [Song]? {
        if library.isReady { return library.recentlyPlayedSongs(limit: limit) }
        guard let reader = PlaybackCatalogAccess.reader(for: library) else { return nil }
        var seen = Set<String>()
        let ids = library.recentPlaybackSongIDsForSync.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return [] }
        do {
            let found = try await reader.songsChunked(ids: ids, scope: LibrarySongScope(kinds: recentMusicKinds))
            let byID = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return Array(ids.lazy.compactMap { byID[$0] }.prefix(limit))
        } catch {
            plog("🏠 recent songs: catalog read failed (\(error))")
            return nil
        }
    }

    /// 这一首是不是有声、播客或环境音(点了单独放,不接整库),同 `nonMusicSongIDs.contains`。
    /// 模型不在内存里时问曲库目录的类别;答不了时为 nil。
    @MainActor
    static func isNonMusic(_ songID: String, library: MusicLibrary) async -> Bool? {
        if library.isReady { return library.nonMusicSongIDs.contains(songID) }
        guard let reader = PlaybackCatalogAccess.reader(for: library),
              let kind = try? await reader.contentKind(songID: songID) else { return nil }
        return !recentMusicKinds.contains(kind)
    }
}
