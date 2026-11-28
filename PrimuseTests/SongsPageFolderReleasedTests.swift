import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U9b:歌曲页「目录」版式在歌曲模型放掉之后由曲库目录排每个文件夹的歌 —— 曲目顺序与跟着列表排序的每一种排序,
/// 文件夹自己的歌与整棵子树,与模型在内存里时页面给的(`LibraryFolderBrowserCache` 按内存快照排的)逐首相同;
/// 文件夹页的行按页从目录物化,与内存里的歌相同;「重新读取文件标签」挑出的歌相同;「查看全部」那一页的行按页物化,
/// 不可见的歌照样不画。都不装模型、不读整库数组。目录排不出的(要整首歌而文件夹太大)答「要模型」,不答空文件夹。
@MainActor
final class SongsPageFolderReleasedTests: LibraryReadyCatalogFixture {
    /// 源 A 按目录分(扫描根三处),同首页、目录页的建法;歌曲页整库看的是音乐。
    private static let folderSource = LibraryFolderSourceDescriptor(
        sourceID: sourceA, displayName: "A", scanRoots: ["/Music", "/Books", "/Ambient"],
        pathSemantics: .hierarchical, pathEncoding: .native
    )

    /// 夹具之外:一个文件夹里标题、艺人、年份、码率、加入时间都有相等与缺失的歌,外加一首 CUE 分轨(读不了标签)。
    private static func extra(prefix: String) -> [Song] {
        var songs: [Song] = []
        let titles = ["雨", "apple", "Zebra", "第2集", "Apple", "风", "mango", "10 Bells"]
        for (offset, track) in [5, 2, 8, 1, 7, 3, 6, 4].enumerated() {
            var song = Song(
                id: "\(prefix)-mix-\(offset)", title: titles[offset], albumTitle: offset % 2 == 0 ? "Mix" : "mix",
                artistName: (["Ada", "ben", "Cleo", nil] as [String?])[offset % 4], trackNumber: track, discNumber: 1,
                duration: ([200, 180, 200, 0] as [Double])[offset % 4], fileFormat: offset % 3 == 0 ? .mp3 : .flac,
                filePath: "/Music/Mix/\(String(format: "%02d", 9 - offset)) \(titles[offset]).flac", sourceID: sourceA,
                bitRate: offset % 3 == 0 ? nil : 320, bitDepth: offset % 2 == 0 ? 24 : nil, genre: "Pop",
                year: offset % 4 == 0 ? nil : 2001 + offset % 2, serverPlayCount: offset % 3 == 1 ? 3 : nil
            )
            song.dateAdded = Date(timeIntervalSince1970: 1_700_500_000 + Double(offset % 3))
            song.lastModified = offset % 2 == 0 ? Date(timeIntervalSince1970: 1_600_000_000 + Double(offset % 3)) : nil
            songs.append(song)
        }
        var cue = Song(
            id: "\(prefix)-mix-cue", title: "Cue Track", albumTitle: "Mix", artistName: "Ada", trackNumber: 9,
            fileFormat: .flac, filePath: "/Music/Mix/live.flac", sourceID: sourceA, cueSheetPath: "/Music/Mix/live.cue",
            cueStartTime: 0, cueEndTime: 60
        )
        cue.dateAdded = Date(timeIntervalSince1970: 1_700_500_010)
        songs.append(cue)
        var nested = Song(
            id: "\(prefix)-mix-nested", title: "Deep", albumTitle: "Mix", artistName: "Ada", trackNumber: 1,
            fileFormat: .flac, filePath: "/Music/Mix/Bonus/deep.flac", sourceID: sourceA
        )
        nested.dateAdded = Date(timeIntervalSince1970: 1_700_500_020)
        songs.append(nested)
        return songs
    }

    private func memoryIndex(_ library: MusicLibrary) -> LibraryFolderIndex {
        LibraryFolderIndexBuilder.build(sources: [Self.folderSource], songs: library.musicSongs)
    }

    /// 模型不在内存里时歌曲页那条路:按目录建,只要音乐。
    private func catalogIndex(_ library: MusicLibrary) async throws -> LibraryFolderIndex {
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let descriptor = Self.folderSource
        return try await reader.folderIndex { catalog, isCancelled in
            try LibraryFolderIndexBuilder.build(
                sources: [descriptor],
                catalog: LibraryFolderCatalogInput(catalog: catalog, kinds: [.music], ordersSpokenWordLikeShelf: false),
                unlistedSource: { _ in nil },
                isCancelled: isCancelled
            )
        }
    }

    /// 文件夹(混排的那个)、扫描根、源的根。
    private func probeNodes(_ index: LibraryFolderIndex, prefix: String) throws -> [LibraryFolderNodeID] {
        let leaf = try XCTUnwrap(index.nodeID(containingSongID: "\(prefix)-mix-0"))
        let root = try XCTUnwrap(index.sourceNode(for: Self.sourceA)?.id)
        let scanRoot = try XCTUnwrap(index.children(of: root).first { $0.kind == .scanRoot }?.id)
        return [leaf, scanRoot, root]
    }

    private static let orders: [LibrarySongSortOrder?] = [nil] + LibrarySongSortOrder.allCases.map(Optional.some)

    private static func label(_ node: LibraryFolderNodeID, _ scope: LibraryFolderBrowserCache.QueryScope,
                              _ order: LibrarySongSortOrder?) -> String {
        "\(node.kind)|\(node.normalizedRelativePath)|\(scope)|\(order?.rawValue ?? "track")"
    }

    /// 模型在内存里时页面给的:同一个文件夹缓存,内存快照由整页的歌按这种排序排好(iOS 的排序值是空的)。
    private func loadedPicture(
        _ library: MusicLibrary, index: LibraryFolderIndex, nodes: [LibraryFolderNodeID]
    ) -> [String: [String]] {
        var picture: [String: [String]] = [:]
        for order in Self.orders {
            let cache = LibraryFolderBrowserCache()
            cache.publish(index)
            cache.followsListSort = order != nil
            let listCache = SongListCache()
            if let order {
                let snapshot = SongListSnapshotBuilder.build(songs: library.musicSongs, order: order)
                listCache.publish(snapshot, pruneRowModels: false, resolve: { _ in nil })
            }
            for node in nodes {
                for scope in [LibraryFolderBrowserCache.QueryScope.visible, .action] {
                    picture[Self.label(node, scope, order)] = cache.orderedSongIDs(in: node, scope: scope, listCache: listCache)
                }
            }
        }
        return picture
    }

    /// 模型不在内存里时:同一个文件夹缓存交了目录的读法,等每个位置照这种排法排好。
    private func catalogPicture(
        _ library: MusicLibrary, index: LibraryFolderIndex, nodes: [LibraryFolderNodeID]
    ) async throws -> [String: [String]] {
        let host = try XCTUnwrap(library.catalogHost)
        var picture: [String: [String]] = [:]
        for order in Self.orders {
            let cache = LibraryFolderBrowserCache()
            cache.publish(index)
            cache.followsListSort = order != nil
            cache.setCatalog(LibraryFolderBrowserCache.CatalogContext(host: host, listOrder: order ?? .title, sortValues: .empty, sortRevision: nil))
            let listCache = SongListCache()
            for node in nodes {
                for scope in [LibraryFolderBrowserCache.QueryScope.visible, .action] {
                    _ = cache.orderedSongIDs(in: node, scope: scope, listCache: listCache)
                    try await waitUntil("\(Self.label(node, scope, order)) answered") {
                        cache.hasCatalogAnswer(in: node, scope: scope)
                    }
                    picture[Self.label(node, scope, order)] = cache.orderedSongIDs(in: node, scope: scope, listCache: listCache)
                }
                XCTAssertFalse(cache.isCatalogPending(node))
            }
            XCTAssertFalse(cache.catalogNeedsModel, "\(order?.rawValue ?? "track"): the catalog answers")
        }
        return picture
    }

    func testFolderSongsInEveryOrderAndTheirRowsMatchTheLoadedPageWhileReleased() async throws {
        let prefix = "u9b-folders"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.fixture(prefix: prefix), extra: Self.extra(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        let memory = memoryIndex(library)
        let nodes = try probeNodes(memory, prefix: prefix)
        let loaded = loadedPicture(library, index: memory, nodes: nodes)
        let leafVisible = { (order: LibrarySongSortOrder?) in loaded[Self.label(nodes[0], .visible, order)] ?? [] }
        XCTAssertEqual(leafVisible(nil).count, 9, "the mixed folder's own songs")
        XCTAssertNotEqual(leafVisible(nil), leafVisible(.title), "the orders differ on the fixture")
        XCTAssertNotEqual(leafVisible(.artist), leafVisible(.artistDescending))
        let loadedSongs = Dictionary(library.visibleSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 「能不能重新读取」的规则(源、文件类型)交进去;这里比的是歌从哪里来:模型在内存里逐首按 id 问资料库,
        // 放掉之后按段从目录取。规则同 `canRereadTags(songID:expectedSourceID:)`:先看源,再看这首能不能读。
        let isReadable: @MainActor (Song) -> Bool = { $0.cueSheetPath == nil }
        let asksLoaded: (String) -> Bool = { id in
            library.song(id: id).map { $0.sourceID == Self.sourceA && isReadable($0) } ?? false
        }
        let leafAll = loaded[Self.label(nodes[0], .action, nil)] ?? []
        let loadedReadable = leafAll.filter(asksLoaded)
        XCTAssertFalse(loadedReadable.contains("\(prefix)-mix-cue"), "a CUE track is not re-read")
        XCTAssertFalse(loadedReadable.isEmpty)

        let before = try await releaseForReal(library)
        let index = try await catalogIndex(library)
        let released = try await catalogPicture(library, index: index, nodes: nodes)
        for key in loaded.keys.sorted() {
            XCTAssertEqual(released[key], loaded[key], key)
        }
        XCTAssertEqual(released.count, loaded.count)

        // 文件夹页的行:按页从目录物化,与内存里的歌逐首相同(曲目顺序与一种跟着排序的)。
        let host = try XCTUnwrap(library.catalogHost)
        for order in [nil, LibrarySongSortOrder.artistDescending] as [LibrarySongSortOrder?] {
            let cache = LibraryFolderBrowserCache()
            cache.publish(index)
            cache.followsListSort = order != nil
            cache.setCatalog(LibraryFolderBrowserCache.CatalogContext(host: host, listOrder: order ?? .title, sortValues: .empty, sortRevision: nil))
            XCTAssertTrue(cache.servesFromCatalog)
            for node in nodes {
                // 多选时文件夹行只看成员:与模型在内存里时那一份的成员相同,不为它在后台排。
                XCTAssertEqual(Set(cache.memberSongIDs(in: node, listCache: SongListCache())),
                               Set(loaded[Self.label(node, .action, order)] ?? []), "members of \(node)")
                _ = cache.orderedSongIDs(in: node, scope: .visible, listCache: SongListCache())
                try await waitUntil("rows of \(node)") { cache.hasCatalogAnswer(in: node, scope: .visible) }
                let ids = cache.orderedSongIDs(in: node, scope: .visible, listCache: SongListCache())
                for (position, id) in ids.enumerated() {
                    try await waitUntil("row \(position) of \(node)") {
                        cache.catalogRowModel(in: node, at: position, id: id) != nil
                    }
                    XCTAssertEqual(cache.catalogRowModel(in: node, at: position, id: id)?.song, loadedSongs[id], "row \(position)")
                }
            }
            cache.setCatalog(nil)
            XCTAssertFalse(cache.servesFromCatalog, "the page takes the memory path back")
        }

        // 重新读取文件标签:挑出的歌与模型在内存里时逐首问的相同;菜单上那一项的判断也相同。
        let readable = await LibraryFolderMaintenanceModel.rereadable(
            leafAll, sourceID: Self.sourceA, library: library, readable: isReadable
        )
        XCTAssertEqual(readable, loadedReadable)
        let maintenance = LibraryFolderMaintenanceModel()
        let probe = { maintenance.canReread(leafAll.prefix(24), sourceID: Self.sourceA, library: library,
                                            asksLoaded: asksLoaded, readable: isReadable) }
        XCTAssertFalse(probe(), "not offered until it is known")
        try await waitUntil("re-read probe") { maintenance.rereadProbe != nil }
        XCTAssertTrue(probe())
        assertNoLoadAndNoArrayRead(library, since: before, "songs page folders while released")

        // 要整首歌才能排(按艺人)而文件夹比上限大:答「要模型」(页面占用模型照内存排),不答空文件夹,也不自己去装。
        let limit = LibraryFolderBrowserCache.catalogSongLimit
        LibraryFolderBrowserCache.catalogSongLimit = 2
        defer { LibraryFolderBrowserCache.catalogSongLimit = limit }
        let held = LibraryFolderBrowserCache()
        held.publish(index)
        held.followsListSort = true
        held.setCatalog(LibraryFolderBrowserCache.CatalogContext(host: host, listOrder: .artist, sortValues: .empty, sortRevision: nil))
        XCTAssertEqual(held.orderedSongIDs(in: nodes[0], scope: .visible, listCache: SongListCache()), [])
        try await waitUntil("needs the model") { held.catalogNeedsModel }
        XCTAssertTrue(held.isCatalogPending(nodes[0]), "still pending: not an empty folder")
        // 标题这类按文件夹列排的不受上限所限。
        held.setCatalog(LibraryFolderBrowserCache.CatalogContext(host: host, listOrder: .title, sortValues: .empty, sortRevision: nil))
        XCTAssertFalse(held.catalogNeedsModel, "a different order tries the catalog again")
        _ = held.orderedSongIDs(in: nodes[0], scope: .visible, listCache: SongListCache())
        try await waitUntil("title order answered") { held.hasCatalogAnswer(in: nodes[0], scope: .visible) }
        XCTAssertEqual(held.orderedSongIDs(in: nodes[0], scope: .visible, listCache: SongListCache()), leafVisible(.title))
        assertNoLoadAndNoArrayRead(library, since: before, "the cache itself never loads the model")
    }

    func testFolderSongsAnswerFromTheCatalogAfterALaunchThatNeverLoadedTheModel() async throws {
        let name = "u9b-launch"
        let (source, library) = try await launchWithoutTheSongModel(name)
        let memory = memoryIndex(source)
        let leaf = try XCTUnwrap(memory.nodeID(containingSongID: "\(name)-blue-1"))
        let root = try XCTUnwrap(memory.sourceNode(for: Self.sourceA)?.id)
        let loaded = loadedPicture(source, index: memory, nodes: [leaf, root])
        let before = library.songModelResidencyStatistics
        let released = try await catalogPicture(library, index: try await catalogIndex(library), nodes: [leaf, root])
        for key in loaded.keys.sorted() {
            XCTAssertEqual(released[key], loaded[key], key)
        }
        XCTAssertFalse(library.isReady)
        assertNoLoadAndNoArrayRead(library, since: before, "songs page folders after an unloaded launch")
    }

    /// 「查看全部」那一页:id 照旧(歌单成员里有停用源的歌、目录里没有的 id),行按页从目录物化,可见的与内存里的歌相同,
    /// 不可见的照样不画;模型在内存里时不建,照原来按 id 取。
    func testSeeAllRowsArePagedFromTheCatalogLikeTheLoadedPage() async throws {
        let prefix = "u9b-see-all"
        let songs = Self.fixture(prefix: prefix)
        let (library, _) = try makeLaunchedTwin(prefix, songs: songs)
        await assertShadowMatches(library, "fixture")
        let ids = ["\(prefix)-comp-2", "\(prefix)-blueb-1", "\(prefix)-blue-3", "ghost-song", "\(prefix)-cue-2", "\(prefix)-rain"]
        let loaded = ids.map { library.unobservedVisibleSong(id: $0) }
        XCTAssertNil(loaded[1], "a song of the disabled source is not shown")
        XCTAssertNil(loaded[3])
        let rows = SearchCollectionRows()
        await rows.refresh(ids: ids, library: library)
        XCTAssertNil(rows.rows, "with the model loaded the rows come from memory, as before")

        let before = try await releaseForReal(library)
        await rows.refresh(ids: ids, library: library)
        let paged = try XCTUnwrap(rows.rows, "rows are paged from the catalog")
        for (position, id) in ids.enumerated() {
            let item = await paged.waitForItem(at: position)
            XCTAssertEqual(item?.id == id ? item : nil, loaded[position], "row \(position)")
            XCTAssertEqual(rows.song(at: position, id: id, library: library), loaded[position], "row \(position)")
        }
        rows.stop()
        XCTAssertNil(rows.rows)
        assertNoLoadAndNoArrayRead(library, since: before, "see-all rows while released")
    }
}
