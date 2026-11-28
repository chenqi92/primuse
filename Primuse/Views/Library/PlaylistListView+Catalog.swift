import Foundation
import Observation
import PrimuseKit

/// 歌单页(iPhone 资料库的「歌单」分区、Mac 的歌单总览)在歌曲模型不在内存里时要的那几样(6c 单元 4 U9b)。
/// 行上的曲数与第一首走资料库的按 id 读(`songSummary(forPlaylist:)`,目录上数,数过的记下),封面走
/// `PlaylistArtworkView`,这里只管还读整库数组、或在每次求值时逐首读目录的那几处。
@MainActor
enum PlaylistListCatalog {
    /// 「只看有离线可用曲目的歌单」要看的歌:普通歌单的成员、智能歌单命中的。
    /// 模型在内存里:照原来(成员按 id 从内存取)。放掉了(或这次启动没装):成员 id 是小状态,歌在主线程外
    /// 按段从曲库目录取可见的那些(每段至多物化上限),不再逐首在主线程上按 id 读。nil = 答不了。
    static func offlineProbeSongs(playlist: Playlist, library: MusicLibrary) async -> [Song]? {
        if library.isReady {
            return library.songIDs(forPlaylist: playlist.id).compactMap { library.visibleSong(id: $0) }
        }
        return await catalogSongs(library.songIDs(forPlaylist: playlist.id), library: library)
    }

    /// 同上,智能歌单命中的歌。模型在内存里照原来(`SmartPlaylistEngine.matchedSongs`)。放掉了:规则歌单的 id 照原来
    /// 在曲库目录上匹配,歌按段从目录取;AI 歌单要按身份对回整库(`visibleSongs(matching:)`),先占用模型装回来再对。
    static func offlineProbeSongs(smart: SmartPlaylist, library: MusicLibrary) async -> [Song]? {
        if library.isReady {
            return await SmartPlaylistEngine.matchedSongs(smart, in: library, history: PlayHistoryStore.shared)
        }
        guard let ids = await matchedSongIDs(smart, library: library) else { return nil }
        return await catalogSongs(ids, library: library)
    }

    /// 分组「播放全部」要的智能歌单命中的 id。规则歌单照原来(曲库目录可读时在目录上匹配,不要模型);
    /// AI 歌单在模型不在内存里时先占用模型装回来再对(至多等 `SongModelArrayRead.defaultTimeout`)。nil = 答不了。
    static func matchedSongIDs(_ smart: SmartPlaylist, library: MusicLibrary) async -> [String]? {
        guard smart.effectiveKind == .ai, !library.isReady else {
            return await SmartPlaylistEngine.matchedSongIDs(smart, in: library, history: PlayHistoryStore.shared)
        }
        return await SongModelArrayRead.read(library) {
            SmartPlaylistEngine.match(smart, in: library, history: PlayHistoryStore.shared).map(\.id)
        }
    }

    /// 歌单算不算「有离线可用的歌」:答不了(nil)时照样列出来 —— 筛选不把「答不了」当成「没有」。
    static func mayPlayOffline(_ songs: [Song]?, sourceManager: SourceManager, localSourceIDs: Set<String>) async -> Bool {
        guard let songs else { return true }
        return await sourceManager.containsOfflinePlayableSong(in: songs, localSourceIDs: localSourceIDs)
    }

    /// 这些 id 里可见的歌,先后不变、不在的跳过(同按 id 逐首取可见的歌);主线程外按段读,每段至多物化上限。
    /// 读失败是 nil。
    private static func catalogSongs(_ ids: [String], library: MusicLibrary) async -> [Song]? {
        guard !ids.isEmpty else { return [] }
        guard let reader = library.readableCatalogReader else { return nil }
        do {
            return try await reader.read { catalog in
                var songs: [Song] = []
                songs.reserveCapacity(ids.count)
                var start = 0
                while start < ids.count {
                    let end = min(ids.count, start + LibraryScale.maxMaterializedRows)
                    songs.append(contentsOf: try catalog.songs(ids: Array(ids[start..<end]), scope: .visible))
                    start = end
                }
                return songs
            }
        } catch {
            plog("⚠️ Playlist offline filter songs from the catalog failed: \(error)")
            return nil
        }
    }
}

/// 长按菜单里「分享到服务器」那一项的目标:要把整张歌单逐首核对(`ServerMediaShareTargetPolicy.makeTarget`)。
/// 菜单跟着每一行一起求值。模型在内存里时照原来当场建(歌单的歌有缓存);放掉了时整张歌单要从曲库目录读,
/// 不在每次求值时读:按歌单内容的版本(`playlistContentVersion`,同内存里那份缓存的键)在主线程上排一个任务建一次,
/// 建好之前这一项先不出现;内容变了先留着上一份,建好再换。
@MainActor
@Observable
final class PlaylistShareTargets {
    private var entries: [String: Entry] = [:]
    @ObservationIgnored private var building: [String: MusicLibrary.PlaylistContentVersion] = [:]

    init() {}
}

extension PlaylistShareTargets {
    struct Entry {
        let version: MusicLibrary.PlaylistContentVersion
        let target: ServerMediaShareTarget?
    }

    func target(for playlist: Playlist, library: MusicLibrary, sourcesStore: SourcesStore) -> ServerMediaShareTarget? {
        if library.isReady { return Self.make(for: playlist, library: library, sourcesStore: sourcesStore) }
        let version = library.playlistContentVersion
        let entry = entries[playlist.id]
        if entry?.version != version, building[playlist.id] != version {
            building[playlist.id] = version
            Task { @MainActor [weak self, weak library, weak sourcesStore] in
                guard let self, let library, let sourcesStore, self.building[playlist.id] == version else { return }
                let target = Self.make(for: playlist, library: library, sourcesStore: sourcesStore)
                self.building[playlist.id] = nil
                self.entries[playlist.id] = Entry(version: version, target: target)
            }
        }
        return entry?.target
    }

    /// 长按菜单跟着每一行一起求值: 先只看第一首歌的源能不能这样分享, 能的才取出
    /// 整张歌单逐首核对。没有 Subsonic 一类源的歌单不再每行都拷一遍整张歌单。
    static func make(for playlist: Playlist, library: MusicLibrary, sourcesStore: SourcesStore) -> ServerMediaShareTarget? {
        guard let firstSong = library.songSummary(forPlaylist: playlist.id).first,
              let source = sourcesStore.source(id: firstSong.sourceID),
              ServerMediaShareTargetPolicy.supports(source.type) else { return nil }
        // crash-pattern: allow legacy-library-api 一张歌单的歌(按 id 取,模型不在内存里时从目录读);原样从 PlaylistListView 移来
        let songs = library.songs(forPlaylist: playlist.id)
        return try? ServerMediaShareTargetPolicy.makeTarget(
            kind: .playlist,
            title: playlist.name,
            songs: songs,
            source: source
        )
    }
}
