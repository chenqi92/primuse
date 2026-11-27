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
    /// 「最近添加」的专辑,按顺序;可能只有前一段(见 `hasAllRecentlyAddedAlbums`)。
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
        snapshot.recentlyAddedAlbums = recentIndex.sorted(albums: albums)
        snapshot.recentlyAddedAlbumTotal = snapshot.recentlyAddedAlbums.count

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
            let recent = try catalog.recentlyAddedAlbumKeys(includingExternalSongs: includingExternalSongs, limit: shownAlbums)
            snapshot.recentlyAddedAlbums = try catalog.albums(keys: recent.keys, visibleCounts: true)
            snapshot.recentlyAddedAlbumTotal = recent.total
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
               try catalog.recentlyAddedAlbumKeys(
                   includingExternalSongs: includingExternalSongs, limit: LibraryScale.maxMaterializedRows
               ).ids
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
