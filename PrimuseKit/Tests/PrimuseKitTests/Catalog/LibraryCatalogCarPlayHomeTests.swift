import Foundation
import Testing
@testable import PrimuseKit

/// 车机首页「最近添加」在目录上的答案(C2,`carPlayRecentlyAdded`)与 App 在内存里的写法(`CarPlayEditorCatalog.project`)
/// 逐项相同:随机曲库,含停用的源、加入时间相同的歌、服务端的加入时间与专辑加入时间、对不上专辑的歌。
@Suite("CarPlay home recently added on the catalog", .serialized)
struct LibraryCatalogCarPlayHomeTests {
    static let scope = LibrarySongScope(kinds: [.music, .collectionOnly])

    /// 仪表盘那份随机曲库,再给一部分歌服务端的加入时间(有的与本机时间相同)和服务端的专辑加入时间。
    static func makeCatalog(seed: UInt64, disabled: Set<String>) throws -> TemporaryCatalog {
        let temporary = try LibraryCatalogDashboardQueriesTests.makeCatalog(seed: seed, disabled: [])
        let catalog = temporary.catalog
        var rng = CatalogTestRandom(seed: seed &+ 1)
        var songs = try Self.songs(catalog, LibrarySongScope.everything)
        for index in songs.indices {
            if rng.chance(20) { songs[index].serverDateAdded = songs[index].dateAdded.addingTimeInterval(Double(rng.next() % 5) * 60) }
            if rng.chance(10) { songs[index].serverAlbumDateAdded = Date(timeIntervalSinceReferenceDate: 690_000_000) }
        }
        try catalog.apply(upserts: songs)
        for sourceID in disabled.sorted() { try catalog.setSourceEnabled(false, sourceID: sourceID) }
        return temporary
    }

    /// 范围里的歌,库内顺序。
    static func songs(_ catalog: LibraryCatalog, _ scope: LibrarySongScope) throws -> [Song] {
        let rowids = Array(try catalog.rowList(scope).rowids)
        var songs: [Song] = []
        var start = 0
        while start < rowids.count {
            let end = min(rowids.count, start + LibraryScale.maxMaterializedRows)
            songs += try catalog.songs(rowids: rowids[start..<end])
            start = end
        }
        return songs
    }

    /// 内存里那一套(`CarPlayEditorCatalog.project`):歌按自己的加入时间,专辑与单曲按 `RecentlyAddedAlbumPolicy.date`。
    static func reference(
        _ catalog: LibraryCatalog, songLimit: Int, albumLimit: Int, singleLimit: Int
    ) throws -> (songs: [String], albums: [String], albumDates: [Date], singles: [String], singleDates: [Date]) {
        let music = try songs(catalog, scope)
        let albums = try catalog.albums(keys: catalog.albumKeys(visibleOnly: true).keys, visibleCounts: true)
        let listed = albums.filter { !$0.id.isEmpty && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let listedIDs = Set(listed.map(\.id))
        let newest = music.sorted { $0.dateAdded == $1.dateAdded ? $0.id < $1.id : $0.dateAdded > $1.dateAdded }
        var albumDates: [String: Date] = [:]
        var singles: [Song] = []
        for song in music {
            if let id = song.albumID, listedIDs.contains(id) {
                albumDates[id] = max(albumDates[id] ?? .distantPast, RecentlyAddedAlbumPolicy.date(for: song))
            } else {
                singles.append(song)
            }
        }
        var dated: [(id: String, date: Date)] = []
        for album in listed {
            if let date = albumDates[album.id] { dated.append((id: album.id, date: date)) }
        }
        dated.sort { lhs, rhs in lhs.date == rhs.date ? lhs.id < rhs.id : lhs.date > rhs.date }
        let datedAlbums = Array(dated.prefix(albumLimit))
        singles.sort {
            let lhs = RecentlyAddedAlbumPolicy.date(for: $0), rhs = RecentlyAddedAlbumPolicy.date(for: $1)
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        let keptSingles = Array(singles.prefix(singleLimit))
        let songIDs: [String] = newest.prefix(songLimit).map { $0.id }
        let albumIDs: [String] = datedAlbums.map { $0.id }
        let albumDateList: [Date] = datedAlbums.map { $0.date }
        let singleIDs: [String] = keptSingles.map { $0.id }
        let singleDates: [Date] = keptSingles.map { RecentlyAddedAlbumPolicy.date(for: $0) }
        return (songIDs, albumIDs, albumDateList, singleIDs, singleDates)
    }

    @Test("Recently added songs, albums and singles equal the in-memory projection", arguments: [UInt64(4), 23, 71])
    func recentlyAdded(seed: UInt64) throws {
        for disabled in [Set<String>(), ["src-nas"]] {
            let temporary = try Self.makeCatalog(seed: seed, disabled: disabled)
            let catalog = temporary.catalog
            for (songLimit, albumLimit, singleLimit) in [(100, 60, 100), (3, 2, 1), (5_000, 5_000, 5_000)] {
                let context = "seed \(seed) disabled \(disabled.sorted()) limits \(songLimit)/\(albumLimit)/\(singleLimit)"
                let expected = try Self.reference(catalog, songLimit: songLimit, albumLimit: albumLimit, singleLimit: singleLimit)
                #expect(!expected.songs.isEmpty && !expected.albums.isEmpty, "\(context): the fixture needs recent albums")
                let actual = try catalog.carPlayRecentlyAdded(
                    scope: Self.scope, songLimit: songLimit, albumLimit: albumLimit, singleLimit: singleLimit
                )
                #expect(actual.songIDs == expected.songs, "\(context): songs")
                #expect(actual.albums.map(\.id) == expected.albums, "\(context): albums")
                #expect(actual.albums.map { Date(timeIntervalSinceReferenceDate: $0.date) } == expected.albumDates, "\(context): album dates")
                #expect(actual.singles.map(\.id) == expected.singles, "\(context): singles")
                #expect(actual.singles.map { Date(timeIntervalSinceReferenceDate: $0.date) } == expected.singleDates, "\(context): single dates")
                let keys = try catalog.albums(keys: actual.albums.map(\.key), visibleCounts: true).map(\.id)
                #expect(keys == expected.albums, "\(context): the keys name those albums")
            }
            let none = try catalog.carPlayRecentlyAdded(scope: Self.scope, songLimit: 0, albumLimit: 0, singleLimit: 0)
            #expect(none == LibraryCarPlayRecentlyAdded())
        }
    }

    @Test("The top list keeps the first entries of the full order")
    func topList() {
        var rng = CatalogTestRandom(seed: 9)
        let entries = (0..<400).map { index in (id: "song-\(rng.next() % 1_000)-\(index)", date: Double(rng.next() % 7)) }
        for limit in [0, 1, 5, 60, 400, 500] {
            var list = CarPlayRecentTopList(limit: limit)
            for entry in entries { list.offer(id: entry.id, date: entry.date) }
            let expected = entries.sorted(by: CarPlayRecentTopList.precedes).prefix(limit)
            #expect(list.entries.map(\.id) == expected.map(\.id), "limit \(limit)")
        }
    }
}
