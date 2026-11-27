import Foundation
import Testing
@testable import PrimuseKit

/// Mac 首页在目录上的几个查询(6c 单元 4 U2a)与逐首数内存里的歌逐项一致:统计、最新加入的几首、
/// 「最近添加」的专辑顺序(随机曲库,含停用的源、外部条目、加入时间相同的歌)。
@Suite("Dashboard queries on the catalog", .serialized)
struct LibraryCatalogDashboardQueriesTests {
    /// 随机曲库;歌的 `albumID` 换成分组给它的专辑 id(App 里写进目录的就是这个),留几首对不上的。
    /// 三分之一的歌共用几个加入时间,两成标成外部条目。
    static func makeCatalog(seed: UInt64, disabled: Set<String>) throws -> TemporaryCatalog {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        try catalog.setGroupingConfiguration(LibraryGroupingConfiguration(unknownArtist: "Unknown Artist"))
        var rng = CatalogTestRandom(seed: seed)
        let sharedDates = (0..<4).map { Date(timeIntervalSinceReferenceDate: 700_000_000 + Double($0) * 3_600) }
        var songs = (0..<500).map { index -> Song in
            var song = CatalogSongFactory.randomSong(&rng, index: index, exotic: false)
            if rng.chance(33) { song.dateAdded = rng.pick(sharedDates) }
            song.isExternal = rng.chance(20) ? true : (rng.chance(10) ? false : nil)
            return song
        }
        try catalog.apply(upserts: songs)
        var albumIDBySongID: [String: String] = [:]
        for album in try catalog.albums(keys: catalog.albumKeys(visibleOnly: false).keys, visibleCounts: false) {
            for song in try catalog.songs(rowids: catalog.albumSongRowList(albumID: album.id).rowids) {
                albumIDBySongID[song.id] = album.id
            }
        }
        for index in songs.indices where !rng.chance(5) {
            songs[index].albumID = albumIDBySongID[songs[index].id]
        }
        try catalog.apply(upserts: songs)
        for sourceID in disabled.sorted() { try catalog.setSourceEnabled(false, sourceID: sourceID) }
        return temporary
    }

    /// 可见音乐,库内顺序(从目录本身读出来,和内存里的 `musicSongs` 同一组)。
    static func visibleMusic(_ catalog: LibraryCatalog) throws -> [Song] {
        let rowids = Array(try catalog.rowList(.visibleMusic).rowids)
        var songs: [Song] = []
        var start = 0
        while start < rowids.count {
            let end = min(rowids.count, start + LibraryScale.maxMaterializedRows)
            songs += try catalog.songs(rowids: rowids[start..<end])
            start = end
        }
        return songs
    }

    @Test("Statistics equal a pass over the visible music", arguments: [UInt64(5), 17, 64])
    func statistics(seed: UInt64) throws {
        for disabled in [Set<String>(), ["src-nas", "src-webdav"]] {
            let temporary = try Self.makeCatalog(seed: seed, disabled: disabled)
            let songs = try Self.visibleMusic(temporary.catalog)
            #expect(songs.count > 50, "seed \(seed): the fixture needs music")
            var expected = LibraryCatalogSongStatistics(count: songs.count)
            for song in songs {
                expected.totalDuration += max(0, song.duration)
                if song.isPlayable { expected.playableCount += 1 }
                if song.coverArtFileName?.isEmpty == false { expected.withCoverCount += 1 }
                if song.lyricsFileName?.isEmpty == false { expected.withLyricsFileCount += 1 }
            }
            let actual = try temporary.catalog.songStatistics(.visibleMusic)
            let context = "seed \(seed) disabled \(disabled.sorted())"
            #expect(actual.count == expected.count, "\(context)")
            #expect(actual.playableCount == expected.playableCount, "\(context)")
            #expect(actual.withCoverCount == expected.withCoverCount, "\(context)")
            #expect(actual.withLyricsFileCount == expected.withLyricsFileCount, "\(context)")
            #expect(abs(actual.totalDuration - expected.totalDuration) < 0.001, "\(context): duration")
        }
    }

    @Test("Newest songs equal a stable sort of the visible music by date added", arguments: [UInt64(2), 31])
    func newestSongs(seed: UInt64) throws {
        let temporary = try Self.makeCatalog(seed: seed, disabled: ["src-smb"])
        let songs = try Self.visibleMusic(temporary.catalog)
        let expected = songs.sorted { $0.dateAdded > $1.dateAdded }.prefix(40).map(\.id)
        let rows = try temporary.catalog.newestSongRowList(.visibleMusic, limit: 40)
        #expect(try temporary.catalog.songs(rowids: rows.rowids).map(\.id) == expected)
        #expect(try temporary.catalog.newestSongRowList(.visibleMusic, limit: 0).rowids.isEmpty)
    }

    @Test("Recently added albums follow RecentlyAddedAlbumPolicy", arguments: [UInt64(3), 29, 88])
    func recentlyAddedAlbums(seed: UInt64) throws {
        for disabled in [Set<String>(), ["src-nas"]] {
            let temporary = try Self.makeCatalog(seed: seed, disabled: disabled)
            let catalog = temporary.catalog
            let songs = try Self.visibleMusic(catalog)
            let albums = try catalog.albums(keys: catalog.albumKeys(visibleOnly: true).keys, visibleCounts: true)
            #expect(albums.count > 20, "seed \(seed): the fixture needs a real album wall")
            for including in [true, false] {
                var index = RecentlyAddedAlbumPolicy.Index(includingExternalSongs: including)
                for song in songs { index.add(song, addedDate: song.dateAdded) }
                let expected = index.sorted(albums: albums).map(\.id)
                let context = "seed \(seed) disabled \(disabled.sorted()) including \(including)"
                let all = try catalog.recentlyAddedAlbumKeys(includingExternalSongs: including, limit: 100_000)
                #expect(all.ids == expected, "\(context): order")
                #expect(all.total == expected.count, "\(context): total")
                #expect(try catalog.albums(keys: all.keys, visibleCounts: true).map(\.id) == expected, "\(context): keys")
                let first = try catalog.recentlyAddedAlbumKeys(includingExternalSongs: including, limit: 12)
                #expect(first.ids == Array(expected.prefix(12)), "\(context): first twelve")
                #expect(first.total == expected.count, "\(context): total with a limit")
            }
        }
    }
}
