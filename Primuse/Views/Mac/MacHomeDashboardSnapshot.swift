import Foundation
import PrimuseKit

// 不按平台包起来:iOS 的测试目标也编这个文件,在那里比对整库数组与曲库目录给出的首页快照。

/// Mac 首页主卡、资料库健康度、「最近添加」、艺术家几块显示的数据(派生快照)。首页、马赛克只算音乐:
/// 有声内容按书在自己那一栏,一部几百集的评书不该把歌曲总数和马赛克撑满。
///
/// 两种来源(6c 单元 4 U2a):歌曲模型在内存里时照旧从整库数组算(`fromArrays`,列表是全部);
/// 放掉了时从曲库目录读(`fromCatalog`),列表只读首页显示的那一段,总数照旧是全部。
struct MacHomeDashboardSnapshot: Sendable {
    // crash-pattern: allow library-array-property 主卡马赛克,至多 6 首(`mosaicCount`)
    var mosaicSongs: [Song] = []
    var recommendationResults: [MusicDiscoveryResult] = []
    /// 「最近添加」的专辑,首页显示的那一段(「查看全部」从目录按页取,`MacHomeRecentlyAddedQuery`)。
    var recentlyAddedAlbums: [Album] = []
    /// 「最近添加」一共几张。
    var recentlyAddedAlbumTotal = 0
    /// 可见艺人,艺人页的顺序;可能只有前几位(见 `hasAllArtists`)。
    var artists: [Artist] = []
    var totalDurationSec: Double = 0
    var coverCount = 0
    var lyricsCount = 0
    var playableCount = 0
    var songCount = 0
    var albumCount = 0
    var artistCount = 0
}

extension MacHomeDashboardSnapshot {
    /// 首页「最近添加」显示几张、艺术家一排显示几位、马赛克几张。
    static let shownRecentlyAddedAlbums = 12
    static let shownArtists = 14
    static let mosaicCount = 6
    /// 马赛克的候选:最近播放的至多这么多首,再补最新加入的这么多首。
    static let recentlyPlayedPoolLimit = 100
    static let newestPoolLimit = 40

    /// 「最近添加」的全部专辑都在 `recentlyAddedAlbums` 里(「查看全部」那一页要全部)。
    var hasAllRecentlyAddedAlbums: Bool { recentlyAddedAlbums.count >= recentlyAddedAlbumTotal }
    /// 全部可见艺人都在 `artists` 里(艺术家「查看全部」那一页要全部)。
    var hasAllArtists: Bool { artists.count >= artistCount }

    /// 只留首页显示的那几张专辑、几位艺人,总数不变。歌曲模型放掉时用:整库那两份列表留在快照里,
    /// 放掉的专辑、艺人数组就还在内存里。首页上看到的不变,「查看全部」再要全部时装回模型重算。
    func keepingShownLists() -> MacHomeDashboardSnapshot {
        var trimmed = self
        if recentlyAddedAlbums.count > Self.shownRecentlyAddedAlbums {
            trimmed.recentlyAddedAlbums = Array(recentlyAddedAlbums.prefix(Self.shownRecentlyAddedAlbums))
        }
        if artists.count > Self.shownArtists {
            trimmed.artists = Array(artists.prefix(Self.shownArtists))
        }
        return trimmed
    }

    /// 「显示外部专辑」开关刚拨过:那一块先清空,等重算(清空就是全部,「查看全部」那一页不去装模型)。
    mutating func clearRecentlyAddedAlbums() {
        recentlyAddedAlbums = []
        recentlyAddedAlbumTotal = 0
    }

    /// 马赛克:最近播放的在前,再补最新加入的(去重);有封面的优先,取前六张。
    static func mosaic(recentlyPlayed: [Song], newest: some Sequence<Song>) -> [Song] {
        var mosaicPool = recentlyPlayed
        var seenIDs = Set(mosaicPool.map(\.id))
        for song in newest where seenIDs.insert(song.id).inserted {
            mosaicPool.append(song)
        }
        let covered = mosaicPool.filter { $0.coverArtFileName?.isEmpty == false }
        return Array((covered.isEmpty ? mosaicPool : covered).prefix(mosaicCount))
    }

    /// 「最近添加」的专辑顺序(每首歌按自己的加入时间,`RecentlyAddedAlbumPolicy`)。
    static func recentlyAddedAlbums(songs: [Song], albums: [Album], includingExternalSongs: Bool) -> [Album] {
        var recentIndex = RecentlyAddedAlbumPolicy.Index(includingExternalSongs: includingExternalSongs)
        for song in songs { recentIndex.add(song, addedDate: song.dateAdded) }
        return recentIndex.sorted(albums: albums)
    }

    /// 从整库数组算(歌曲模型在内存里;在主线程外跑)。`songs` 是 `musicSongs`,`recentlyPlayed` 是去掉
    /// 有声、环境音的最近播放。
    static func fromArrays(
        songs: [Song],
        albums: [Album],
        artists: [Artist],
        recentlyPlayed: [Song],
        includingExternalSongs: Bool
    ) -> MacHomeDashboardSnapshot {
        var snapshot = MacHomeDashboardSnapshot()
        snapshot.songCount = songs.count
        snapshot.albumCount = albums.count
        snapshot.artistCount = artists.count
        snapshot.artists = artists
        var totalSec = 0.0
        var coverCount = 0
        var lyricsCount = 0
        var playableCount = 0
        var recentIndex = RecentlyAddedAlbumPolicy.Index(includingExternalSongs: includingExternalSongs)
        for song in songs {
            recentIndex.add(song, addedDate: song.dateAdded)
            totalSec += max(0, song.duration)
            if song.coverArtFileName?.isEmpty == false { coverCount += 1 }
            if song.lyricsFileName?.isEmpty == false { lyricsCount += 1 }
            if song.isPlayable { playableCount += 1 }
        }
        snapshot.totalDurationSec = totalSec
        snapshot.coverCount = coverCount
        snapshot.lyricsCount = lyricsCount
        snapshot.playableCount = playableCount
        // 只留首页那一排;「查看全部」与播放键从目录按同样的顺序取(UB)。
        let recentlyAdded = recentIndex.sorted(albums: albums)
        snapshot.recentlyAddedAlbums = Array(recentlyAdded.prefix(shownRecentlyAddedAlbums))
        snapshot.recentlyAddedAlbumTotal = recentlyAdded.count

        let sortedByAdded = songs.sorted { $0.dateAdded > $1.dateAdded }
        snapshot.mosaicSongs = mosaic(recentlyPlayed: recentlyPlayed, newest: sortedByAdded.prefix(newestPoolLimit))
        return snapshot
    }

    /// 从曲库目录读(歌曲模型不在内存里;读在主线程外)。与 `fromArrays` 同样的数与顺序,列表只读首页显示的那一段:
    /// 计数、时长、封面/歌词/可播放的首数一句聚合;「最近添加」前 `shownAlbums` 张与总张数;艺人前 `shownArtists` 位;
    /// 马赛克从 `recentlyPlayedIDs`(已去掉有声、环境音的最近播放 id,按先后)按 id 取,再补最新加入的几首。
    /// 推荐不在这里(调用方沿用上一份)。
    static func fromCatalog(
        reader: LibraryCatalogReader,
        recentlyPlayedIDs: [String],
        includingExternalSongs: Bool,
        shownAlbums: Int = MacHomeDashboardSnapshot.shownRecentlyAddedAlbums,
        shownArtists: Int = MacHomeDashboardSnapshot.shownArtists
    ) async throws -> MacHomeDashboardSnapshot {
        let playedIDs = Array(recentlyPlayedIDs.prefix(LibraryScale.maxMaterializedRows))
        return try await reader.read { catalog in
            var snapshot = MacHomeDashboardSnapshot()
            let statistics = try catalog.songStatistics(.visibleMusic)
            snapshot.songCount = statistics.count
            snapshot.totalDurationSec = statistics.totalDuration
            snapshot.coverCount = statistics.withCoverCount
            snapshot.lyricsCount = statistics.withLyricsFileCount
            snapshot.playableCount = statistics.playableCount
            snapshot.albumCount = try catalog.albumKeys(visibleOnly: true).count
            let artistKeys = try catalog.artistKeys(visibleOnly: true)
            snapshot.artistCount = artistKeys.count
            snapshot.artists = try catalog.artists(keys: artistKeys.keys.prefix(max(0, shownArtists)), visibleCounts: true)
            let recent = try MacHomeRecentlyAddedQuery.browseKeys(catalog, includingExternalSongs: includingExternalSongs)
            snapshot.recentlyAddedAlbums = try catalog.albums(keys: recent.keys.prefix(max(0, shownAlbums)), visibleCounts: true)
            snapshot.recentlyAddedAlbumTotal = recent.keys.count
            let played = try catalog.songs(ids: playedIDs, scope: .visible).prefix(Self.recentlyPlayedPoolLimit)
            let newest = try catalog.songs(rowids: catalog.newestSongRowList(.visibleMusic, limit: Self.newestPoolLimit).rowids)
            snapshot.mosaicSongs = Self.mosaic(recentlyPlayed: Array(played), newest: newest)
            return snapshot
        }
    }

    /// 「最近添加」那颗播放键要的专辑 id,按顺序。快照里是全部时直接用(与改之前相同);只有首页那一段时
    /// 从曲库目录取(至多 `LibraryScale.maxMaterializedRows` 张,凑满播放队列绰绰有余);目录答不了时
    /// 按整库数组算(放掉了就先占用模型装回来)。
    @MainActor
    static func recentlyAddedAlbumIDsForPlayback(
        _ snapshot: MacHomeDashboardSnapshot,
        library: MusicLibrary,
        includingExternalSongs: Bool
    ) async -> [String] {
        if snapshot.hasAllRecentlyAddedAlbums { return snapshot.recentlyAddedAlbums.map(\.id) }
        if let reader = library.readableCatalogReader,
           let ids = try? await reader.read({ catalog in
               let keys = try MacHomeRecentlyAddedQuery.browseKeys(catalog, includingExternalSongs: includingExternalSongs).keys
               return try catalog.albums(keys: keys.prefix(LibraryScale.maxMaterializedRows), visibleCounts: true).map(\.id)
           }) {
            return ids
        }
        return await MacLibraryArrayFallback.read(library) {
            Self.recentlyAddedAlbums(
                // crash-pattern: allow legacy-library-api 目录读不了时的后备,同原来从整库数组算;放掉了先装回来
                songs: library.musicSongs, albums: library.visibleAlbums, includingExternalSongs: includingExternalSongs
            ).map(\.id)
        }
    }
}

/// Mac 首页「为你推荐」上一次算出来的那组(UB):推荐要整库的特征,只在歌曲模型在内存里时算;这次启动没装模型
/// 或模型放掉了时,首页按 id 把这一组从曲库目录取回来先摆上(同 iPhone 首页 `PersistedHomeSnapshot.recommendations`),
/// 模型装回来后才重算。只存 id、分数与理由,不存歌。
enum MacHomeRecommendationMemory {
    static let defaultsKey = "primuse.macHome.recommendations.v1"

    static func save(_ results: [MusicDiscoveryResult], defaults: UserDefaults = .standard) {
        let entries = results.map {
            PersistedHomeRecommendation(songID: $0.song.id, score: $0.score, reasons: $0.reasons.map(\.rawValue))
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        if defaults.data(forKey: defaultsKey) != data { defaults.set(data, forKey: defaultsKey) }
    }

    static func savedEntries(defaults: UserDefaults = .standard) -> [PersistedHomeRecommendation] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([PersistedHomeRecommendation].self, from: data) else { return [] }
        return entries
    }

    /// 存着的那一组,按 id 取回此刻可见的歌(模型不在时由曲库目录作答);取不到的那几首不摆。
    @MainActor
    static func restore(in library: MusicLibrary, defaults: UserDefaults = .standard) -> [MusicDiscoveryResult] {
        savedEntries(defaults: defaults).compactMap { entry in
            library.unobservedVisibleSong(id: entry.songID).map {
                MusicDiscoveryResult(
                    song: $0, score: entry.score,
                    reasons: entry.reasons.compactMap(MusicDiscoveryReason.init(rawValue:))
                )
            }
        }
    }
}

/// Mac 首页「最近添加」在曲库目录上的顺序(首页那一排、「查看全部」、播放键共用):可见音乐里每首歌按自己的
/// `dateAdded` 归到专辑(`RecentlyAddedAlbumPolicy.Index` 的 Mac 写法),「显示外部专辑」关着时外部条目不算(S5c)。
struct MacHomeRecentlyAddedQuery: LibraryListQuery {
    let includingExternalSongs: Bool

    static func browseKeys(_ catalog: LibraryCatalog, includingExternalSongs: Bool) throws -> LibraryCatalogBrowseKeys {
        try catalog.recentlyAddedAlbumBrowseKeys(
            scope: .visibleMusic, includingExternalSongs: includingExternalSongs, dateRule: .songDateAdded
        )
    }

    func fetchRows(_ catalog: LibraryCatalog) throws -> LibraryListRows {
        let keys = try Self.browseKeys(catalog, includingExternalSongs: includingExternalSongs)
        return LibraryListRows(ids: keys.keys, sections: [], revision: keys.revision)
    }

    func materialize(_ ids: [Int32], catalog: LibraryCatalog, rowCache: LibraryRowCache) throws -> [Int32: Album] {
        try LibraryAlbumListQuery(visibleOnly: true).materialize(ids, catalog: catalog, rowCache: rowCache)
    }

    func isAffected(by change: LibraryCatalogChange) -> Bool { true }
}
