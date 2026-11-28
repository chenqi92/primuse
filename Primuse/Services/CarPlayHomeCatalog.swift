#if os(iOS)
@preconcurrency import CarPlay
import Foundation
import PrimuseKit

/// 车机首页那份投影(`CarPlayEditorCatalog.Snapshot`)在歌曲模型不在内存里时从曲库目录取(C2)。
///
/// 模型在内存里时首页照旧把整库投影一遍(`CarPlayEditorCatalog.project`)。不在时只取首页各块用得到的那一点,成员、
/// 先后、每一项的字与目标与在内存里投影出来的相同:
/// - 专辑块:可见专辑按标题(`localizedStandardCompare`,同名保持专辑墙的先后)的前若干张 —— 专辑键按墙的先后分批物化,
///   每批与留着的合起来再挑(`CarPlayListSelection.firstSorted`),与在整份上挑同序。
/// - 最近添加:Kit 的 `carPlayRecentlyAdded`(同一套时间与筛法),再按 id 取那一百来首歌、几十张专辑。
/// - 排行、最近播放、歌单的首数:历史与歌单成员(小状态)里的 id 一次问目录哪些可见,只取要显示的那几首。
/// - 自定义内容里的歌、专辑:按 id 取。电台、「开始听」、歌单本身是小状态,照旧。
/// - 「为你推荐」要整库打分,目录答不了:用模型在内存里时算好的那一批(同一天之内),见 `CarPlayEditorCatalog`。
/// 专辑块与最近添加这两样要扫整表,按目录与它的修订号记住,歌单、播放历史变了只重算其余几样。
/// 编辑器的「添加内容」要整库的歌与专辑做候选,这里不给(与以前模型不在内存里时一样是空的),只给歌单与电台。
@MainActor
final class CarPlayHomeCatalog {
    static let shared = CarPlayHomeCatalog()

    /// 要扫整表的那两样:哪个目录、按什么取的、取到了什么。
    private var cachedParts: (host: ObjectIdentifier, key: PartsKey, parts: Parts)?

    init() {}
}

extension CarPlayHomeCatalog {
    /// 车机首页的「歌」:可见、不算有声与环境音(同 `musicSongs` 去掉 `nonMusicSongIDs`)。
    nonisolated static let musicScope = LibrarySongScope(kinds: [.music, .collectionOnly])
    nonisolated static let recentSongLimit = 100
    nonisolated static let recentCollectionLimit = 60
    nonisolated static let rankingLimit = 60

    /// 车机列表的上限(「查看全部」放得下的条数)。
    static var listLimit: Int { CPListTemplate.maximumItemCount }

    struct Request: Sendable {
        /// 专辑块要的张数(首页每块多取一张判断后面还有没有,「查看全部」到车机列表的上限);0:没有专辑块。
        var albumLimit = 0
        var wantsRecentlyAdded = false
        var wantsRanking = false
        // crash-pattern: allow song-id-collection-property 布局里自定义内容的歌,至多 12 块 × 60 项
        var customSongIDs: [String] = []
        var customAlbumIDs: [String] = []
        var playlists: [Playlist] = []
        var memberships: [String: [String]] = [:]
        var stations: [CarPlayHomeItem] = []
        var artistNames: ArtistNameConfiguration = .defaultValue
        var history: [HomeListeningEvent] = []
        var historyCandidates: [String: [String]] = [:]
        /// `recentlyPlayedSongs(limit: 60)`:模型不在内存里时它自己从目录答。
        // crash-pattern: allow library-array-property 至多 60 首(最近播放那一块)
        var recentlyPlayed: [Song] = []
        var listeningIntents: [CarPlayHomeItem] = []
        var forYou: [CarPlayHomeItem] = []
    }

    struct PartsKey: Equatable {
        let albumLimit: Int
        let recentlyAdded: Bool
        let revisions: [UInt64]
    }

    struct Parts: Sendable {
        var albums: [Album] = []
        // crash-pattern: allow library-array-property 至多 100 首(最近添加的歌)
        var recent: [Song] = []
        var recentAlbums: [(album: Album, date: Date)] = []
        var singles: [(song: Song, date: Date)] = []
    }

    /// 这一份布局要首页取哪些(块的种类、自定义内容里的 id、专辑块的张数)。`listLimit`:车机列表的上限(「查看全部」)。
    static func request(for configuration: CarPlayLayoutConfiguration, listLimit: Int) -> Request {
        var request = Request()
        for block in configuration.blocks {
            if (block.usesCustomContent && !block.kind.keepsLiveContent) || block.kind == .custom {
                for item in block.items {
                    switch item.kind {
                    case .song: request.customSongIDs.append(item.targetID)
                    case .album: request.customAlbumIDs.append(item.targetID)
                    case .playlist, .folder, .radio, .nowPlaying: break
                    }
                }
                continue
            }
            switch block.kind {
            case .albums:
                request.albumLimit = max(request.albumLimit, CarPlayHomeMorePolicy.probeLimit(for: block.itemLimit),
                                         max(block.itemLimit, listLimit))
            case .recentlyAdded: request.wantsRecentlyAdded = true
            case .ranking: request.wantsRanking = true
            default: break
            }
        }
        return request
    }

    /// 首页那份投影;nil:此刻答不出(目录读不了、读失败),调用方留着上一份。
    func snapshot(_ request: Request, library: MusicLibrary) async -> CarPlayEditorCatalog.Snapshot? {
        guard let host = library.catalogHost, host.revisions.isReadable else { return nil }
        let revisions = host.revisions
        let key = PartsKey(
            albumLimit: request.albumLimit, recentlyAdded: request.wantsRecentlyAdded,
            revisions: [revisions.songs, revisions.membership, revisions.albums, revisions.everything]
        )
        let hostID = ObjectIdentifier(host)
        let known = cachedParts.flatMap { $0.host == hostID && $0.key == key ? $0.parts : nil }
        do {
            let (snapshot, parts) = try await host.reader.read { catalog in
                let parts = try known ?? Self.parts(request, catalog: catalog)
                return (try Self.snapshot(request, parts: parts, catalog: catalog), parts)
            }
            if known == nil { cachedParts = (hostID, key, parts) }
            return snapshot
        } catch {
            plog("🚗 CarPlay home from the catalog failed (\(error)); keeping the last one")
            return nil
        }
    }

    /// 主线程外:要扫整表的两样。
    nonisolated static func parts(_ request: Request, catalog: LibraryCatalog) throws -> Parts {
        var parts = Parts()
        if request.albumLimit > 0 {
            let keys = try catalog.albumKeys(visibleOnly: true).keys
            var start = 0
            while start < keys.count {
                let end = min(keys.count, start + LibraryScale.maxMaterializedRows)
                let chunk = try catalog.albums(keys: keys[start..<end], visibleCounts: true)
                parts.albums = CarPlayListSelection.firstSorted(parts.albums + chunk, limit: request.albumLimit) {
                    $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                start = end
            }
        }
        if request.wantsRecentlyAdded {
            let recent = try catalog.carPlayRecentlyAdded(
                scope: musicScope, songLimit: recentSongLimit, albumLimit: recentCollectionLimit, singleLimit: recentSongLimit
            )
            let songs = try catalog.songs(ids: recent.songIDs + recent.singles.map(\.id), scope: .visible)
            let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            parts.recent = recent.songIDs.compactMap { byID[$0] }
            parts.singles = recent.singles.compactMap { single in
                byID[single.id].map { (song: $0, date: Date(timeIntervalSinceReferenceDate: single.date)) }
            }
            let albums = try catalog.albums(keys: recent.albums.map(\.key), visibleCounts: true)
            let albumByID = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            parts.recentAlbums = recent.albums.compactMap { entry in
                albumByID[entry.id].map { (album: $0, date: Date(timeIntervalSinceReferenceDate: entry.date)) }
            }
        }
        return parts
    }

    /// 主线程外:按 `CarPlayEditorCatalog.project` 的写法把首页各块拼出来(每一项的构造与那里逐字相同)。
    nonisolated static func snapshot(_ request: Request, parts: Parts, catalog: LibraryCatalog) throws -> CarPlayEditorCatalog.Snapshot {
        var result = CarPlayEditorCatalog.Snapshot()
        let names = request.artistNames
        result.memberships = request.memberships

        let ranked = request.wantsRanking
            ? HomeListeningRanking.ranks(events: request.history, songs: [:], folders: nil, period: .all, category: .songs)
            : []
        let rankCandidates = ranked.map { rank in
            rank.songGroups.first.map { ListeningSongIdentity.expandingCandidateIDs($0, candidates: request.historyCandidates) } ?? []
        }
        // 「库里有这首」:歌单成员、排行候选、最近播放里此刻可见的(同内存里那份可见集,只问这些 id)。
        var asked = request.recentlyPlayed.map(\.id)
        for members in request.memberships.values { asked += members }
        for candidates in rankCandidates { asked += candidates }
        let valid = try catalog.songIDs(asked, inScope: .visible)

        let queue = parts.recent.map(\.id)
        result.recent = parts.recent.map { songItem($0, names: names, queue: queue) }
        var recentCollections: [(item: CarPlayHomeItem, date: Date)] = parts.recentAlbums.map { album, date in
            (CarPlayHomeItem(id: "recent.album:" + album.id, title: album.title, subtitle: album.artistName,
                symbol: "square.stack", artwork: .album(album), target: .album(album.id, directly: true)), date)
        }
        let singleQueue = parts.singles.prefix(recentSongLimit).map { $0.song.id }
        recentCollections += parts.singles.prefix(recentCollectionLimit).map { song, date in
            (CarPlayHomeItem(id: "recent.song:" + song.id, title: song.title,
                subtitle: song.displayArtistName(configuration: names),
                artwork: .songReference(id: song.id, coverRef: song.coverArtFileName),
                target: .song(song.id, queue: singleQueue)), date)
        }
        result.recentAlbums = recentCollections.sorted {
            $0.date == $1.date ? $0.item.id < $1.item.id : $0.date > $1.date
        }.prefix(recentCollectionLimit).map { $0.item }

        result.entries[.album] = parts.albums.map(albumItem)
        result.entries[.playlist] = request.playlists.sorted { $0.updatedAt > $1.updatedAt }.map {
            let count = (request.memberships[$0.id] ?? []).reduce(0) { $0 + (valid.contains($1) ? 1 : 0) }
            return CarPlayHomeItem(id: $0.id, title: $0.name,
                subtitle: String(format: String(localized: "carplay_playlist_song_count_format"), count),
                symbol: $0.id == MusicLibrary.likedSongsPlaylistID ? "heart.fill" : "music.note.list",
                artwork: .playlist($0), enabled: count > 0, target: .playlist($0.id, directly: true))
        }
        result.entries[.radio] = request.stations
        for (kind, values) in result.entries {
            result.lookup[kind] = Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        // 编辑器「添加内容」的候选只给完整的两种(歌单、电台);整库的歌与专辑这里没有。
        for kind in [CarPlayLayoutItem.Kind.playlist, .radio] {
            result.searchItems[kind] = (result.entries[kind] ?? [])
                .map { CarPlayLayoutItem(id: $0.id, kind: kind, targetID: $0.id, title: $0.title) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        // 自定义内容里按 id 指到的专辑与歌(内存里那份 lookup 有整库,这里只取布局里用到的)。
        for album in try catalog.albums(visibleIDs: request.customAlbumIDs) where result.lookup[.album]?[album.id] == nil {
            result.lookup[.album, default: [:]][album.id] = albumItem(album)
        }
        for song in try catalog.songs(ids: request.customSongIDs, scope: .visible) {
            result.lookup[.song, default: [:]][song.id] = songItem(song, names: names, queue: [song.id])
        }

        result.forYou = request.forYou
        let recentQueue = request.recentlyPlayed.map(\.id).filter(valid.contains)
        let recentByID = Dictionary(request.recentlyPlayed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        result.recentlyPlayed = recentQueue.compactMap { id in recentByID[id].map { songItem($0, names: names, queue: recentQueue) } }
        result.startListening = request.listeningIntents

        // 同一首歌在几个源里各有一份时取库里还在的那份;别的设备上播的、本机 ID 不同的,取认出来的本机那首。
        let rankedQueue = rankCandidates.compactMap { $0.first(where: valid.contains) }
        let rankedSongs = try catalog.songs(ids: Array(rankedQueue.prefix(rankingLimit)), scope: .visible)
        let rankedByID = Dictionary(rankedSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        result.ranking = rankedQueue.prefix(rankingLimit).compactMap { id in
            rankedByID[id].map { songItem($0, names: names, queue: rankedQueue) }
        }
        return result
    }

    nonisolated static func songItem(_ song: Song, names: ArtistNameConfiguration, queue: [String]) -> CarPlayHomeItem {
        CarPlayHomeItem(id: song.id, title: song.title, subtitle: song.displayArtistName(configuration: names),
                        artwork: .songReference(id: song.id, coverRef: song.coverArtFileName), target: .song(song.id, queue: queue))
    }

    nonisolated static func albumItem(_ album: Album) -> CarPlayHomeItem {
        CarPlayHomeItem(id: album.id, title: album.title, subtitle: album.artistName, symbol: "square.stack",
                        artwork: .album(album), target: .album(album.id, directly: true))
    }
}
#endif
