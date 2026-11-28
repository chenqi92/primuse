import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U9a:「目录」页打开的文件夹在歌曲模型放掉之后照样列出它的歌 —— 同样的歌、同样的先后(每一种「目录」顺序),
/// 行按页从曲库目录物化成与模型在内存里时相同的歌;作用于整个文件夹的「播放」队列、「下载整个文件夹」、「专辑元数据」
/// 与模型在内存里时相同;歌曲页多选按目录修剪的结果与按内存修剪的相同。都不装模型、不读整库数组。目录答不了时什么都不做。
@MainActor
final class HomeFolderBrowserReleasedTests: LibraryReadyCatalogFixture {
    private static let orders: [HomeFolderSongOrder] = [
        .trackOrder, .sorted(.title), .sorted(.artistDescending), .sorted(.album), .originalName(ascending: false),
        .titleLanguageFirst(.chineseFirst, ascending: true), .sorted(.dateAddedOldest),
    ]

    /// 夹具之外:一个曲号打乱、标题夹着中英文的文件夹(叶子),扫描根下直接放着的两首(中间节点自己的歌),
    /// 扫描根之外的三首(落在源的「其他」里,源的根上直接列出)。
    private static func extra(prefix: String) -> [Song] {
        var songs: [Song] = []
        func add(_ id: String, _ title: String, artist: String, track: Int?, path: String, added: TimeInterval) {
            var song = Song(
                id: "\(prefix)-\(id)", title: title, albumTitle: "Shuffle", artistName: artist, trackNumber: track,
                discNumber: 1, duration: 200, fileFormat: .flac, filePath: path, sourceID: sourceA, genre: "Pop"
            )
            song.dateAdded = Date(timeIntervalSince1970: 1_700_400_000 + added)
            songs.append(song)
        }
        let titles = ["雨", "apple", "Zebra", "第2集", "Apple", "风", "mango", "10 Bells"]
        for (offset, track) in [5, 2, 8, 1, 7, 3, 6, 4].enumerated() {
            add("shuffle-\(offset)", titles[offset], artist: ["Ada", "ben", "Cleo"][offset % 3], track: track,
                path: "/Music/Shuffle/\(String(format: "%02d", 9 - offset)) \(titles[offset]).flac", added: Double(offset % 3))
        }
        add("direct-1", "Root Two", artist: "Ada", track: 2, path: "/Music/direct-b.flac", added: 10)
        add("direct-2", "Root One", artist: "Ben", track: nil, path: "/Music/direct-a.flac", added: 11)
        for index in 1...3 {
            add("elsewhere-\(index)", "Away \(4 - index)", artist: "Dee", track: index, path: "/Elsewhere/away-\(index).flac",
                added: 20)
        }
        return songs
    }

    /// 叶子、中间节点、源的根。
    private func probeNodes(_ index: LibraryFolderIndex, prefix: String) throws -> [LibraryFolderNodeID] {
        let leaf = try XCTUnwrap(index.nodeID(containingSongID: "\(prefix)-shuffle-0"))
        let middle = try XCTUnwrap(index.nodeID(containingSongID: "\(prefix)-direct-1"))
        let root = try XCTUnwrap(index.sourceNode(for: Self.sourceA)?.id)
        XCTAssertNotEqual(leaf, middle)
        XCTAssertTrue(LibraryFolderBrowsePolicy.displayedSongIDs(in: index, of: root).contains("\(prefix)-elsewhere-1"),
                      "the songs outside the scan roots are listed on the source root")
        return [leaf, middle, root]
    }

    private struct Picture: Equatable {
        var orders: [String: [String]] = [:]
        var offline: [String] = []
        var batch: [String] = []
    }

    /// 每个节点、页面列出的与「播放」的队列、每种顺序;整个文件夹的下载请求与专辑元数据。
    private func picture(
        _ library: MusicLibrary, index: LibraryFolderIndex, nodes: [LibraryFolderNodeID], expectRowids: Bool
    ) async throws -> Picture {
        var picture = Picture()
        let source = MusicSource(id: Self.sourceA, name: "A", type: .webdav)
        for node in nodes {
            for scope in [LibraryFolderCatalogSongOrder.Scope.displayed, .descendants] {
                for order in Self.orders {
                    let answer = await HomeFolderSongs.ordered(
                        in: node, scope: scope, index: index, order: order, spokenWordSongIDs: library.spokenWordSongIDs,
                        library: library, wait: .action
                    )
                    let ordered = try XCTUnwrap(answer, "\(node) \(scope) \(order) answered")
                    XCTAssertEqual(ordered.rowids != nil, expectRowids, "rows come from the catalog only while released")
                    picture.orders["\(node.normalizedRelativePath)|\(node.kind)|\(scope)|\(order)"] = ordered.ids
                }
            }
            let request = await HomeFolderSongs.offlineRequest(
                node: try XCTUnwrap(index.node(withID: node)), index: index, library: library, source: source,
                cloudBackedLocalSourceIDs: []
            )
            let answered = try XCTUnwrap(request, "the download request is answered")
            picture.offline += (answered?.songs ?? []).map { "\($0.id)|\($0.title)|\($0.filePath)" }
            let batch = Box<BatchSongSelection?>(nil)
            HomeFolderSongs.selectBatch(in: node, index: index, library: library) { batch.value = $0 }
            try await waitUntil("album metadata songs") { batch.value != nil }
            picture.batch += (batch.value?.songs ?? []).map { "\($0.id)|\($0.title)|\($0.albumTitle ?? "-")" }
        }
        return picture
    }

    func testFolderSongsAndFolderActionsMatchTheLoadedOnesWhileReleased() async throws {
        let prefix = "u9a-folders"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.fixture(prefix: prefix), extra: Self.extra(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        let memoryIndex = LibraryHubPinsReleasedTests.memoryFolderIndex(library)
        let nodes = try probeNodes(memoryIndex, prefix: prefix)
        let loaded = try await picture(library, index: memoryIndex, nodes: nodes, expectRowids: false)
        XCTAssertGreaterThan(loaded.orders.values.map(\.count).reduce(0, +), 50)
        let leafKey = "\(nodes[0].normalizedRelativePath)|\(nodes[0].kind)|displayed|"
        XCTAssertNotEqual(loaded.orders[leafKey + "\(HomeFolderSongOrder.trackOrder)"],
                          loaded.orders[leafKey + "\(HomeFolderSongOrder.sorted(.title))"], "the orders differ on the fixture")
        XCTAssertFalse(loaded.offline.isEmpty, "something to download")
        let loadedSongs = Dictionary(library.visibleSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let loadedKey = HomeFolderSongList.key(nodeID: nodes[0], order: .trackOrder, model: HomeDiscoveryModel(), library: library)
        XCTAssertNotNil(loadedKey.revision, "with the model loaded the list is keyed on the model revision, as before")

        let before = try await releaseForReal(library)
        let catalogIndex = try await LibraryHubPinsReleasedTests.catalogFolderIndex(library)
        let released = try await picture(library, index: catalogIndex, nodes: nodes, expectRowids: true)
        XCTAssertEqual(released.orders, loaded.orders, "the same songs in the same order, every node, scope and order")
        XCTAssertEqual(released.offline, loaded.offline, "the same folder download request")
        XCTAssertEqual(released.batch, loaded.batch, "the same album metadata songs")

        // 页面上的那份:先后同上,行按页从目录物化,与模型在内存里时的歌逐首相同。
        let model = HomeDiscoveryModel()
        model.bindLibrary(library)
        model.publish(
            index: catalogIndex, songs: [:], covers: [:],
            request: HomeDiscoveryModel.Request(collection: 0, playlists: 0, hierarchy: 0, names: 0, sources: []),
            metadataToken: UUID(), directoryNames: [:], spokenWordSongIDs: library.spokenWordSongIDs
        )
        let list = HomeFolderSongList()
        for node in nodes {
            let key = HomeFolderSongList.key(nodeID: node, order: .sorted(.title), model: model, library: library)
            XCTAssertNil(key.revision)
            await list.refresh(key, model: model, library: library)
            XCTAssertEqual(list.ids(for: node), loaded.orders["\(node.normalizedRelativePath)|\(node.kind)|displayed|\(HomeFolderSongOrder.sorted(.title))"])
            let rows = try XCTUnwrap(list.rows, "rows are paged from the catalog")
            for (position, id) in list.ids(for: node).enumerated() {
                let song = await rows.waitForItem(at: position)
                XCTAssertEqual(song, loadedSongs[id], "row \(position) of \(node)")
            }
            XCTAssertFalse(list.isPending(node))
        }
        // 后台收进一批封面时首页模型的 revision 加一:模型不在内存里时那不是重排文件夹的理由。
        let keyBefore = HomeFolderSongList.key(nodeID: nodes[0], order: .trackOrder, model: model, library: library)
        model.adoptCatalogCovers([nodes[0]: []], for: catalogIndex)
        XCTAssertEqual(HomeFolderSongList.key(nodeID: nodes[0], order: .trackOrder, model: model, library: library), keyBefore)
        assertNoLoadAndNoArrayRead(library, since: before, "folder songs and folder actions while released")

        // 要整首歌才能排(按艺人)而歌比目录上一次排的上限多:占用模型照内存排,与内存里的相同(装一次)。
        let limit = HomeFolderSongs.catalogSongLimit
        HomeFolderSongs.catalogSongLimit = 2
        defer { HomeFolderSongs.catalogSongLimit = limit }
        let held = await HomeFolderSongs.ordered(
            in: nodes[0], scope: .displayed, index: catalogIndex, order: .sorted(.artistDescending),
            spokenWordSongIDs: library.spokenWordSongIDs, library: library, wait: .action
        )
        XCTAssertEqual(held?.ids, loaded.orders["\(nodes[0].normalizedRelativePath)|\(nodes[0].kind)|displayed|\(HomeFolderSongOrder.sorted(.artistDescending))"])
        XCTAssertNil(held?.rowids, "ordered in memory")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
    }

    func testFolderSongsAnswerFromTheCatalogAfterALaunchThatNeverLoadedTheModel() async throws {
        let name = "u9a-launch"
        let (source, library) = try await launchWithoutTheSongModel(name)
        let memoryIndex = LibraryHubPinsReleasedTests.memoryFolderIndex(source)
        let leaf = try XCTUnwrap(memoryIndex.nodeID(containingSongID: "\(name)-blue-1"))
        let root = try XCTUnwrap(memoryIndex.sourceNode(for: Self.sourceA)?.id)
        let before = library.songModelResidencyStatistics
        let catalogIndex = try await LibraryHubPinsReleasedTests.catalogFolderIndex(library)
        for node in [leaf, root] {
            for scope in [LibraryFolderCatalogSongOrder.Scope.displayed, .descendants] {
                for order in Self.orders {
                    let expected = await HomeFolderSongs.ordered(
                        in: node, scope: scope, index: memoryIndex, order: order, spokenWordSongIDs: source.spokenWordSongIDs,
                        library: source, wait: .action
                    )
                    let answered = await HomeFolderSongs.ordered(
                        in: node, scope: scope, index: catalogIndex, order: order, spokenWordSongIDs: library.spokenWordSongIDs,
                        library: library, wait: .action
                    )
                    XCTAssertEqual(answered?.ids, expected?.ids, "\(node) \(scope) \(order)")
                    XCTAssertNotNil(answered?.rowids)
                }
            }
        }
        XCTAssertFalse(library.isReady)
        assertNoLoadAndNoArrayRead(library, since: before, "folder songs after an unloaded launch")
    }

    /// 歌曲页多选:模型在内存里时按这一页的歌(整库是音乐)修剪;放掉之后按目录修剪,结果相同,不装、不读整库数组。
    func testSongsPageSelectionPrunesAgainstTheCatalogLikeTheLoadedPage() async throws {
        let prefix = "u9a-prune"
        let songs = Self.fixture(prefix: prefix)
        let (library, _) = try makeLaunchedTwin(prefix, songs: songs)
        await assertShadowMatches(library, "fixture")
        let chosen = ["\(prefix)-blue-1", "\(prefix)-book-1", "\(prefix)-rain", "\(prefix)-pod-1", "\(prefix)-comp-2", "ghost-song"]
        let loaded = SongSelectionModel()
        loaded.activate()
        loaded.selectAll(chosen)
        loaded.prune(to: Set(library.musicSongs.map(\.id)))
        XCTAssertTrue(loaded.selectedIDs.isSuperset(of: ["\(prefix)-blue-1", "\(prefix)-comp-2"]), "music stays")
        XCTAssertTrue(loaded.selectedIDs.isDisjoint(with: ["ghost-song", "\(prefix)-pod-1"]), "gone and disabled are pruned")

        let before = try await releaseForReal(library)
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let selection = SongSelectionModel()
        selection.activate()
        selection.selectAll(chosen)
        SongSelectionCatalogPrune.prune(selection, scope: SongListFolderCatalogScope(kinds: [.music], sourceID: nil).songScope,
                                        reader: reader)
        try await waitUntil("the selection is pruned") { selection.selectedIDs.count < chosen.count }
        XCTAssertEqual(selection.selectedIDs, loaded.selectedIDs)
        assertNoLoadAndNoArrayRead(library, since: before, "selection pruning while released")
    }

    /// 目录答不了、模型也装不回来:不播、不弹下载确认、不打开专辑元数据 —— 不把「答不了」当成「文件夹里没有歌」。
    func testFolderActionsThatCannotBeAnsweredDoNothing() async throws {
        let prefix = "u9a-stuck"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.fixture(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        let index = LibraryHubPinsReleasedTests.memoryFolderIndex(library)
        let node = try XCTUnwrap(index.nodeID(containingSongID: "\(prefix)-blue-1"))
        library.dropSongModelForMeasurement(includingCollections: true)
        library.catalogHost?.revisions.setReadable(false)
        let timeout = HomeFolderSongs.actionTimeout
        HomeFolderSongs.actionTimeout = .milliseconds(300)
        defer {
            HomeFolderSongs.actionTimeout = timeout
            library.catalogHost?.revisions.setReadable(true)
        }
        XCTAssertNil(library.readableCatalogReader)
        let ordered = await HomeFolderSongs.ordered(
            in: node, scope: .descendants, index: index, order: .trackOrder, spokenWordSongIDs: [], library: library, wait: .action
        )
        XCTAssertNil(ordered, "cannot answer: nothing is played")
        let request = await HomeFolderSongs.offlineRequest(
            node: try XCTUnwrap(index.node(withID: node)), index: index, library: library,
            source: MusicSource(id: Self.sourceA, name: "A", type: .webdav), cloudBackedLocalSourceIDs: []
        )
        XCTAssertNil(request, "cannot answer, not \"nothing to download\"")
        let batch = Box<BatchSongSelection?>(nil)
        HomeFolderSongs.selectBatch(in: node, index: index, library: library) { batch.value = $0 }
        try await Task.sleep(for: .seconds(1))
        XCTAssertNil(batch.value, "the album metadata sheet is not opened")
    }
}
