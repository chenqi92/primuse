import Foundation
import Testing
@testable import PrimuseKit

/// 歌曲页「目录」版式的文件夹在曲库目录上排(`LibrarySongListFolderOrder`,6c 单元 4 U9b):每个节点、自己的歌与整棵子树、
/// 曲目顺序与列表的每一种排序(两个方向)、空的与带值的排序值,都与模型在内存里时页面给的
/// (整页列表 `SongListSnapshotBuilder` 排好、再按文件夹的成员筛,`LibraryFolderIndex.orderedSongIDs`)逐首相同;
/// 行号与 id 一一对应;要整首歌而超过上限时答 nil。
@Suite("Songs page folder order from the catalog", .serialized)
struct LibrarySongListFolderOrderTests {
    /// 再补上列表排序要比的那几列(时长、年份、码率、位深、服务端播放次数),各有相等与缺失的。
    static func decorated(_ songs: [Song], seed: UInt64) -> [Song] {
        var rng = CatalogTestRandom(seed: seed &* 104_729)
        return LibraryFolderCatalogSongOrderTests.decorated(songs, seed: seed).map { song in
            var song = song
            song.duration = rng.pick([0, 180, 180, 241.5, Double.nan, -1] as [Double])
            song.year = rng.maybe(70) { $0.pick([1999, 2001, 2001, 2024]) }
            song.bitRate = rng.maybe(60) { $0.pick([128, 320, 320, 1_411]) }
            song.bitDepth = rng.maybe(50) { $0.pick([16, 24, 24]) }
            song.serverPlayCount = rng.maybe(40) { $0.int(0...3) }
            return song
        }
    }

    /// 页面带着的排序值(Mac 的样子):一部分歌的本机播放次数、几首已下载、源名与源 id 的先后相反。
    static func sortValues(_ songs: [Song], seed: UInt64) -> SongListSortValues {
        var rng = CatalogTestRandom(seed: seed &* 31)
        var counts: [String: Int] = [:]
        var downloaded = Set<String>()
        for song in songs {
            if rng.chance(35) { counts[song.id] = rng.int(0...3) }
            if rng.chance(30) { downloaded.insert(song.id) }
        }
        let sources = Set(songs.map(\.sourceID)).sorted()
        var names: [String: String] = [:]
        for (offset, source) in sources.enumerated() { names[source] = "Source \(sources.count - offset)" }
        return SongListSortValues(playCountsBySongID: counts, downloadedSongIDs: downloaded, sourceNamesByID: names)
    }

    /// 每个节点、两种范围、每种顺序都相同;返回比过的歌数。
    @discardableResult
    static func expectSameOrder(
        memory: LibraryFolderIndex, catalog: LibraryFolderIndex, store: LibraryCatalog, listSongs: [Song],
        sortValues: SongListSortValues, _ label: String
    ) throws -> Int {
        var compared = 0
        var lists: [LibrarySongSortOrder: [String]] = [:]
        for order in LibrarySongSortOrder.allCases {
            lists[order] = SongListSnapshotBuilder.build(songs: listSongs, order: order, sortValues: sortValues).orderedSongIDs
        }
        var pending = memory.sourceNodeIDs
        while let id = pending.popLast() {
            for scope in [LibraryFolderSongScope.direct, .descendants] {
                let track = try #require(try LibrarySongListFolderOrder.ordered(
                    in: id, scope: scope, index: catalog, listOrder: nil, catalog: store
                ))
                #expect(track.ids == memory.songIDs(in: id, scope: scope), "\(label): track order of \(id) \(scope)")
                #expect(try store.songIDs(rowids: track.rowids) == track.ids, "\(label): track rowids line up \(id)")
                for order in LibrarySongSortOrder.allCases {
                    let expected = memory.orderedSongIDs(in: id, scope: scope, orderedBy: lists[order] ?? [])
                    let answered = try LibrarySongListFolderOrder.ordered(
                        in: id, scope: scope, index: catalog, listOrder: order, sortValues: sortValues, catalog: store
                    )
                    #expect(answered?.ids == expected, "\(label): node \(id) \(scope) \(order)")
                    if let answered {
                        #expect(try store.songIDs(rowids: answered.rowids) == answered.ids, "\(label): rowids line up \(id)")
                    }
                    compared += expected.count
                }
            }
            pending.append(contentsOf: memory.children(of: id).map(\.id))
        }
        return compared
    }

    @Test("Random libraries: every node, scope and list order matches the in-memory page", arguments: Array(UInt64(1)...UInt64(8)))
    func randomLibraries(seed: UInt64) throws {
        var library = LibraryFolderCatalogIndexTests.randomLibrary(seed: seed)
        library.songs = Self.decorated(library.songs, seed: seed)
        let temporary = try LibraryFolderCatalogIndexTests.makeCatalog(library)
        let unlisted: (String) -> LibraryFolderSourceDescriptor? = { $0 == library.unlisted.sourceID ? library.unlisted : nil }
        let memory = LibraryFolderIndexBuilder.build(
            sources: LibraryFolderCatalogIndexTests.memoryDescriptors(library, songs: library.songs), songs: library.songs
        )
        let built = try LibraryFolderIndexBuilder.build(
            sources: library.configured,
            catalog: LibraryFolderCatalogInput(catalog: temporary.catalog, kinds: nil, ordersSpokenWordLikeShelf: false),
            unlistedSource: unlisted
        )
        for (name, values) in [("empty", SongListSortValues.empty), ("page values", Self.sortValues(library.songs, seed: seed))] {
            let compared = try Self.expectSameOrder(
                memory: memory, catalog: built, store: temporary.catalog, listSongs: library.songs, sortValues: values,
                "seed \(seed) \(name)"
            )
            #expect(compared > 0, "seed \(seed): something was compared")
        }
    }

    @Test("Orders that need whole songs answer nil past the limit; folder-column orders and track order do not")
    func songLimit() throws {
        var library = LibraryFolderCatalogIndexTests.randomLibrary(seed: 5)
        library.songs = Self.decorated(library.songs, seed: 5)
        let temporary = try LibraryFolderCatalogIndexTests.makeCatalog(library)
        let built = try LibraryFolderIndexBuilder.build(
            sources: library.configured,
            catalog: LibraryFolderCatalogInput(catalog: temporary.catalog, kinds: nil, ordersSpokenWordLikeShelf: false)
        )
        let root = try #require(built.sourceNodeIDs.first { (built.rowids(in: $0, scope: .descendants)?.count ?? 0) > 3 })
        #expect(try LibrarySongListFolderOrder.ordered(
            in: root, scope: .descendants, index: built, listOrder: nil, catalog: temporary.catalog, songLimit: 3
        ) != nil)
        for order in LibrarySongSortOrder.allCases {
            let answered = try LibrarySongListFolderOrder.ordered(
                in: root, scope: .descendants, index: built, listOrder: order, catalog: temporary.catalog, songLimit: 3
            )
            #expect((answered == nil) == !LibrarySongListFolderOrder.readsFolderColumnsOnly(order), "\(order)")
        }
        #expect(throws: CancellationError.self) {
            try LibrarySongListFolderOrder.ordered(
                in: root, scope: .descendants, index: built, listOrder: .artist, catalog: temporary.catalog, isCancelled: { true }
            )
        }
    }

    @Test("Songs of one directory from the catalog: the directory query's rows, in library order; the limit")
    func directorySongs() throws {
        var library = LibraryFolderCatalogIndexTests.randomLibrary(seed: 2)
        library.songs = Self.decorated(library.songs, seed: 2)
        let temporary = try LibraryFolderCatalogIndexTests.makeCatalog(library)
        let byID = Dictionary(library.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var directories: [(sourceID: String, directory: String)] = []
        var seen = Set<String>()
        for song in library.songs {
            let directory = AlbumArtistInferencePolicy.directory(ofPath: song.filePath)
            guard !directory.isEmpty, seen.insert("\(song.sourceID)\u{0}\(directory)").inserted else { continue }
            directories.append((song.sourceID, directory))
        }
        var compared = 0
        for (sourceID, directory) in directories {
            let expected = try temporary.catalog.songIDs(
                rowids: temporary.catalog.rowList(sourceID: sourceID, directory: directory, recursive: false).rowids
            )
            let answered = try #require(try temporary.catalog.directorySongs(
                sourceID: sourceID, directory: directory, scope: .everything
            ))
            #expect(answered.map(\.id) == expected, "\(sourceID) \(directory)")
            // 整首歌(时长里有 NaN,不能整首比 `==`):比编辑器要的那几列。
            let fields = { (song: Song) in "\(song.id)|\(song.title)|\(song.filePath)|\(song.sourceID)|\(song.albumTitle ?? "-")" }
            #expect(answered.map(fields) == expected.compactMap { byID[$0] }.map(fields), "whole songs, \(sourceID) \(directory)")
            compared += answered.count
            if answered.count > 1 {
                #expect(try temporary.catalog.directorySongs(
                    sourceID: sourceID, directory: directory, scope: .everything, limit: answered.count - 1
                ) == nil, "more than the limit: cannot answer")
            }
        }
        #expect(compared > 0)
        #expect(try temporary.catalog.directorySongs(sourceID: "smb", directory: "/No/Such/Directory") == [])
    }
}
