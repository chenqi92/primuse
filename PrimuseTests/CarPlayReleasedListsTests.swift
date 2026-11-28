import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// C2:歌曲模型不在内存里时车机的列表(专辑、歌曲 A–Z、喜欢的专辑、环境音、有声书架与本机播客的歌)、首页各块、
/// 文件夹里的歌与搜索从曲库目录答 —— 成员、先后、每一项与模型在内存里时相同,不装模型、不读整库数组;答不出时是 nil
/// (车机摆「正在准备」),不是空列表,目录能读之后收到重建的信号、答案与内存里的相同;一次都没装过模型的启动也一样。
@MainActor
final class CarPlayReleasedListsTests: LibraryReadyCatalogFixture {
    #if os(iOS)
    /// MV 那份夹具,再加:标题只差大小写、数字大小的歌与专辑(两种比较的排法不同)、两首没有专辑的歌(加入时间相同,
    /// 一首带服务端时间)、带服务端专辑加入时间的专辑、启用源里的一档本机播客、第二段环境音、第二本书。
    static func carPlayFixture(prefix: String) -> [Song] {
        var songs = catalogFixture(prefix: prefix)
        func add(_ id: String, _ title: String, album: String?, artist: String, path: String, genre: String = "Pop",
                 format: AudioFormat = .flac, track: Int = 1, added: TimeInterval) -> Int {
            var song = Song(
                id: "\(prefix)-\(id)", title: title, albumTitle: album, artistName: artist, albumArtistName: nil,
                trackNumber: track, discNumber: 1, duration: 150 + Double(songs.count), fileFormat: format,
                filePath: path, sourceID: sourceA, genre: genre, year: 2019, coverArtFileName: nil
            )
            song.dateAdded = Date(timeIntervalSince1970: 1_700_300_000 + added)
            songs.append(song)
            return songs.count - 1
        }
        _ = add("num-2", "Track 2", album: "Album 2", artist: "Nina", path: "/Music/Nina/Album 2/1.flac", added: 10)
        let ten = add("num-10", "Track 10", album: "Album 10", artist: "Nina", path: "/Music/Nina/Album 10/1.flac", added: 10)
        songs[ten].serverAlbumDateAdded = Date(timeIntervalSince1970: 1_700_400_000)
        _ = add("num-2b", "track 2", album: "album 2", artist: "Omar", path: "/Music/Omar/album 2/1.flac", added: 20)
        let zulu = add("single-z", "Zulu Single", album: nil, artist: "Pia", path: "/Music/Singles/zulu.flac", added: 30)
        songs[zulu].serverDateAdded = Date(timeIntervalSince1970: 1_700_350_000)
        _ = add("single-e", "Echo Single", album: nil, artist: "Pia", path: "/Music/Singles/echo.flac", added: 30)
        for episode in 1...2 {
            _ = add("lpod-\(episode)", "Talk \(episode)", album: "Daily Talk", artist: "Quinn",
                    path: "/Podcasts/Daily/\(episode).mp3", genre: "Podcast", format: .mp3, track: episode, added: 40)
        }
        _ = add("waves", "Waves", album: "Sleep", artist: "Nature", path: "/Ambient/waves.flac", genre: "White Noise", added: 50)
        for chapter in 1...2 {
            _ = add("story2-\(chapter)", "Part \(chapter)", album: "Second Story", artist: "Teller",
                    path: "/Books/Second Story/\(chapter).m4b", genre: "Audiobook", format: .m4a, track: chapter, added: 60)
        }
        return songs
    }

    private func likes(_ name: String, _ library: MusicLibrary) -> LibraryFavoritesStore {
        let likes = LibraryFavoritesStore(fileURL: directory.appendingPathComponent("\(name)-likes.json"))
        for title in ["Hits Collection", "Blue Room", "Album 2"] {
            guard let album = library.visibleAlbums.first(where: { $0.title == title }) else {
                XCTFail("no album \(title)")
                continue
            }
            likes.setLiked(true, album: album)
        }
        return likes
    }

    private func albumPicture(_ albums: [Album]?) -> [String]? {
        albums?.map { "\($0.id)|\($0.title)|\($0.artistName ?? "-")" }
    }

    private func songPicture(_ songs: [Song]?) -> [String]? {
        songs?.map { "\($0.id)|\($0.title)" }
    }

    /// 六份列表此刻的答案(ids 与标题,按先后);nil 是此刻答不出。
    private func pictures(_ lists: CarPlayCatalogLists, _ library: MusicLibrary, likes: LibraryFavoritesStore) -> [String: [String]?] {
        [
            "albums": albumPicture(lists.albumsByTitle(in: library)),
            "songs": songPicture(lists.songsByTitle(in: library)),
            "liked": albumPicture(lists.likedAlbums(in: library, favorites: likes)),
            "ambient": songPicture(lists.ambient(limit: 500, in: library)),
            "books": songPicture(lists.shelfSongs(.books, in: library)),
            "podcasts": songPicture(lists.shelfSongs(.localPodcasts, in: library)),
        ]
    }

    /// 模型在内存里时的答案,并核对它就是车机以前的写法。
    private func loadedPictures(_ lists: CarPlayCatalogLists, _ library: MusicLibrary, likes: LibraryFavoritesStore) -> [String: [String]?] {
        let loaded = pictures(lists, library, likes: likes)
        let byTitle: (String, String) -> Bool = { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        XCTAssertEqual(loaded["albums"], albumPicture(CarPlayListSelection.firstSorted(library.visibleAlbums, limit: 500) {
            byTitle($0.title, $1.title)
        }), "loaded A–Z albums as CarPlay listed them")
        XCTAssertEqual(loaded["songs"], songPicture(CarPlayListSelection.firstSorted(library.musicSongs, limit: 500) {
            byTitle($0.title, $1.title)
        }), "loaded A–Z songs")
        XCTAssertEqual(loaded["liked"], albumPicture(Array(likes.likedAlbums(in: library.visibleAlbums).prefix(500))))
        XCTAssertEqual(loaded["ambient"], songPicture(Array(library.ambientSongs.prefix(500))))
        XCTAssertEqual(loaded["books"], songPicture(library.spokenWordSongs))
        XCTAssertEqual(loaded["podcasts"], songPicture(library.localPodcastSongs))
        for (name, value) in loaded { XCTAssertFalse(value?.isEmpty ?? true, "the fixture fills \(name)") }
        XCTAssertGreaterThan(loaded["liked"]??.count ?? 0, 2, "the cross-source album and the album-only artist's album are liked")
        return loaded
    }

    private func assertAnswers(
        _ lists: CarPlayCatalogLists, _ library: MusicLibrary, likes: LibraryFavoritesStore,
        expected: [String: [String]?], _ step: String
    ) async throws {
        try await waitUntil("\(step): every list answers", timeout: .seconds(20)) {
            !self.pictures(lists, library, likes: likes).values.contains { $0 == nil }
        }
        let answers = pictures(lists, library, likes: likes)
        for name in expected.keys.sorted() { XCTAssertEqual(answers[name], expected[name], "\(step): \(name)") }
    }

    // MARK: Home

    /// 每一种块都有的布局:捷径(钉住的歌单)、歌单、专辑(3 张,与「查看全部」)、最近添加(歌与专辑两种)、排行、
    /// 最近播放、为你推荐、电台,和一块自定义内容(歌、专辑、歌单、一首不在库里的歌)。
    private static func homeConfiguration(prefix: String, playlistID: String, albumID: String) -> CarPlayLayoutConfiguration {
        func block(_ kind: CarPlayLayoutBlockKind, limit: Int, _ change: (inout CarPlayLayoutBlock) -> Void = { _ in }) -> CarPlayLayoutBlock {
            var block = CarPlayLayoutBlock(id: "c2." + kind.rawValue + ".\(limit)", kind: kind)
            block.itemLimit = limit
            change(&block)
            return block
        }
        var configuration = CarPlayLayoutConfiguration()
        configuration.pinnedPlaylistIDs = [playlistID]
        configuration.blocks = [
            block(.shortcuts, limit: 6),
            block(.playlists, limit: 6),
            block(.albums, limit: 3),
            block(.recentlyAdded, limit: 8) { $0.recentlyAddedGrouping = .songs },
            block(.recentlyAdded, limit: 7) { $0.recentlyAddedGrouping = .albums },
            block(.ranking, limit: 6),
            block(.recentlyPlayed, limit: 6),
            block(.forYou, limit: 6),
            block(.radio, limit: 6),
            block(.custom, limit: 10) {
                $0.usesCustomContent = true
                $0.items = [
                    CarPlayLayoutItem(id: "i1", kind: .song, targetID: "\(prefix)-comp-2", title: "Comp 2"),
                    CarPlayLayoutItem(id: "i2", kind: .album, targetID: albumID, title: "Blue Room"),
                    CarPlayLayoutItem(id: "i3", kind: .playlist, targetID: playlistID, title: "Kept"),
                    CarPlayLayoutItem(id: "i4", kind: .song, targetID: "\(prefix)-gone", title: "Gone"),
                    CarPlayLayoutItem(id: "i5", kind: .song, targetID: "\(prefix)-blueb-1", title: "Hidden source"),
                ]
            },
        ]
        return configuration
    }

    /// 首页各块(和专辑、最近添加两块的「查看全部」)里每一项:id、字、图标、封面、能不能点、点了去哪。
    private func homePicture(_ snapshot: CarPlayEditorCatalog.Snapshot, _ configuration: CarPlayLayoutConfiguration) -> [String] {
        func describe(_ blocks: [CarPlayHomeBlock]) -> [String] {
            blocks.flatMap { block in
                ["block \(block.id)"] + block.items.map { item in
                    "\(item.id)|\(item.title)|\(item.subtitle ?? "-")|\(item.symbol)|\(item.artwork?.cacheIdentity ?? "-")"
                        + "|\(item.enabled)|\(item.target)"
                }
            }
        }
        let seeAll = configuration.blocks.filter { [.albums, .recentlyAdded].contains($0.kind) }.map { block in
            var block = block
            block.itemLimit = max(block.itemLimit, CarPlayHomeCatalog.listLimit)
            return block
        }
        return describe(snapshot.blocks(for: configuration)) + describe(snapshot.blocks(seeAll, in: configuration))
    }

    /// 模型在内存里时首页那份投影(`refresh` 的输入、`project`),播放历史换成给定的几次。
    private func loadedHome(_ library: MusicLibrary, history: [HomeListeningEvent]) -> CarPlayEditorCatalog.Snapshot {
        var input = CarPlayEditorCatalog.memoryInput(
            library, wanted: [.forYou, .recentlyPlayed], now: Date(), intelligentOrder: [],
            recentIDs: library.recentlyPlayedSongs(limit: 60).map(\.id), intents: []
        )
        input.history = history
        input.historyCandidates = [:]
        return CarPlayEditorCatalog.project(input)
    }

    private func catalogHome(
        _ library: MusicLibrary, _ configuration: CarPlayLayoutConfiguration, history: [HomeListeningEvent],
        forYou: [CarPlayHomeItem], home: CarPlayHomeCatalog = CarPlayHomeCatalog()
    ) async -> CarPlayEditorCatalog.Snapshot? {
        var request = CarPlayEditorCatalog.catalogRequest(
            library, configuration: configuration, recentSongs: library.recentlyPlayedSongs(limit: 60), intents: [], forYou: forYou
        )
        request.history = history
        request.historyCandidates = [:]
        return await home.snapshot(request, library: library)
    }

    /// 排行要的几次播放:两首各播几次(一首在停用的源里,排不上),一首只播一次。
    private func history(_ prefix: String) -> [HomeListeningEvent] {
        let now = Date()
        return [("blue-2", 3), ("comp-1", 2), ("num-10", 1), ("blueb-2", 4), ("rain", 2)].flatMap { id, plays in
            (0..<plays).map { offset in
                HomeListeningEvent(songID: "\(prefix)-\(id)", playedAt: now.addingTimeInterval(-Double(offset + 1) * 600),
                                   listenedSeconds: 120)
            }
        }
    }

    private func smallState(_ library: MusicLibrary, prefix: String) -> Playlist {
        let kept = library.createPlaylist(name: "Kept", songIDs: ["\(prefix)-blue-1", "\(prefix)-blueb-1", "\(prefix)-num-2"])
        library.setLiked(songID: "\(prefix)-comp-3", isLiked: true, propagatesServerMutation: false)
        for id in ["comp-2", "blue-3", "book-1", "num-2b"] { library.recordPlayback(of: "\(prefix)-\(id)") }
        return kept
    }

    // MARK: Tests

    func testCarPlayListsHomeFoldersAndSearchFromTheCatalogEqualTheModel() async throws {
        let prefix = "c2-lists"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.carPlayFixture(prefix: prefix))
        let kept = smallState(library, prefix: prefix)
        await assertShadowMatches(library, "fixture")
        let likes = likes(prefix, library)
        let lists = CarPlayCatalogLists()
        let expected = loadedPictures(lists, library, likes: likes)
        let loadedSongs = (lists.songsByTitle(in: library), lists.shelfSongs(.books, in: library),
                           lists.shelfSongs(.localPodcasts, in: library), lists.ambient(limit: 500, in: library))

        // 首页:内存里那份投影,「为你推荐」记下的那一批按它重排与投影里的相同。
        let blueRoom = try XCTUnwrap(library.visibleAlbums.first { $0.title == "Blue Room" })
        let configuration = Self.homeConfiguration(prefix: prefix, playlistID: kept.id, albumID: blueRoom.id)
        XCTAssertEqual(configuration.blocks.last?.items.count, 5, "every custom item is kept")
        let history = history(prefix)
        let loadedHome = loadedHome(library, history: history)
        XCTAssertFalse(loadedHome.recent.isEmpty || loadedHome.recentAlbums.isEmpty || loadedHome.ranking.isEmpty
                       || loadedHome.recentlyPlayed.isEmpty || loadedHome.forYou.isEmpty, "every live block has items")
        let carry = CarPlayEditorCatalog.ForYouCarry(day: 1, snapshot: loadedHome)
        XCTAssertEqual(carry.items(intelligentOrder: []).map { "\($0.id)|\($0.target)" },
                       loadedHome.forYou.map { "\($0.id)|\($0.target)" }, "the carried pick re-sorts like the projection")
        let reversed = Array(carry.localIDs.reversed().prefix(2))
        let projected = CarPlayEditorCatalog.project(CarPlayEditorCatalog.memoryInput(
            library, wanted: [.forYou], now: Date(), intelligentOrder: reversed, recentIDs: [], intents: []
        ))
        XCTAssertEqual(carry.items(intelligentOrder: reversed).map { "\($0.id)|\($0.target)" },
                       projected.forYou.map { "\($0.id)|\($0.target)" }, "a new intelligent order")
        let picked = MusicDiscoveryEngine.dailyRecommendations(
            from: MusicDiscoveryEngine.RecommendationSnapshot(
                songs: library.musicSongs, recentSongs: library.recentlyPlayedSongs(limit: 12),
                historyEntries: PlayHistoryStore.shared.musicEntries, now: Date(),
                libraryRevision: library.musicSongsRevision, excludedSongIDs: library.dislikedSongIDs
            ).makeInput(), limit: 12
        ).map(\.song)
        let held = CarPlayEditorCatalog.ForYouCarry(day: 1, songs: picked, names: library.artistNameConfiguration)
        XCTAssertEqual(homePicture(CarPlayEditorCatalog.Snapshot(forYou: held.items(intelligentOrder: [])), configuration),
                       homePicture(CarPlayEditorCatalog.Snapshot(forYou: loadedHome.forYou), configuration),
                       "the pick under a hold equals the projection's")
        let expectedHome = homePicture(loadedHome, configuration)
        // 播放历史换了(只剩前三次)时内存里的排行。
        var lessHistory = loadedHome
        do {
            var input = CarPlayEditorCatalog.memoryInput(library, wanted: [], now: Date(), intelligentOrder: [], recentIDs: [], intents: [])
            input.history = Array(history.prefix(3))
            lessHistory.ranking = CarPlayEditorCatalog.project(input).ranking
        }
        XCTAssertNotEqual(lessHistory.ranking.map(\.id), loadedHome.ranking.map(\.id), "the shorter history ranks differently")

        // 文件夹:内存里的索引与歌。
        let memoryIndex = LibraryHubPinsReleasedTests.memoryFolderIndex(library)
        let leaf = try XCTUnwrap(memoryIndex.nodeID(containingSongID: "\(prefix)-blue-1"))
        let root = try XCTUnwrap(memoryIndex.sourceNodes.first?.id)
        var expectedFolders: [String: [String]] = [:]
        for (name, node) in [("leaf", leaf), ("root", root)] {
            for scope in [LibraryFolderSongScope.direct, .descendants] {
                expectedFolders["\(name) \(scope)"] = memoryIndex.songIDs(in: node, scope: scope)
                    .compactMap { library.unobservedVisibleSong(id: $0) }.sorted(by: CarPlayFolderLibrary.playOrder).map(\.id)
            }
        }
        XCTAssertFalse(expectedFolders["root descendants"]?.isEmpty ?? true)

        // 搜索:同一个索引,内存里的快照。
        let searchIndex = LibrarySearchIndex(storageDirectory: directory.appendingPathComponent("\(prefix)-search", isDirectory: true))
        await searchIndex.applyChanges(upserts: library.songs, deletingIDs: [], generation: LibrarySearchIndex.persistLibraryChangePending())
        let queries = ["blue", "track", "Rain", "chapter", "co", "nina", "single", "zz-none"]
        var expectedSearch: [String: [String]] = [:]
        for query in queries {
            expectedSearch[query] = await CarPlaySearchMatches.songs(matching: query, in: library, index: searchIndex).map(\.id)
        }
        XCTAssertFalse(expectedSearch["blue"]?.isEmpty ?? true)
        XCTAssertFalse(expectedSearch["chapter"]?.isEmpty ?? true, "CarPlay search includes books")

        let before = try await releaseForReal(library)
        let fresh = CarPlayCatalogLists()
        XCTAssertNil(fresh.albumsByTitle(in: library), "released, first ask: pending, not an empty list")
        try await assertAnswers(fresh, library, likes: likes, expected: expected, "released")
        XCTAssertEqual(fresh.songsByTitle(in: library), loadedSongs.0, "the songs themselves (queue entries)")
        XCTAssertEqual(fresh.shelfSongs(.books, in: library), loadedSongs.1, "the books' songs (grouped by CarPlay)")
        XCTAssertEqual(fresh.shelfSongs(.localPodcasts, in: library), loadedSongs.2)
        XCTAssertEqual(fresh.ambient(limit: 500, in: library), loadedSongs.3)
        XCTAssertNil(fresh.ambient(limit: 1, in: library), "another limit is another list (pending)")
        try await waitUntil("released: one ambient sound") { fresh.ambient(limit: 1, in: library)?.count == 1 }

        let home = CarPlayHomeCatalog()
        let releasedHome = await catalogHome(library, configuration, history: history,
                                             forYou: carry.items(intelligentOrder: []), home: home)
        XCTAssertEqual(homePicture(try XCTUnwrap(releasedHome, "released: the home answers"), configuration), expectedHome,
                       "released: every home block and its see-all list")
        let again = await catalogHome(library, configuration, history: Array(history.prefix(3)),
                                      forYou: carry.items(intelligentOrder: []), home: home)
        XCTAssertEqual(again.map { homePicture($0, configuration) }, homePicture(lessHistory, configuration),
                       "a new play history re-ranks with the remembered album and recently added parts")

        let catalogIndex = try await LibraryHubPinsReleasedTests.catalogFolderIndex(library)
        let reader = try XCTUnwrap(library.readableCatalogReader)
        for (name, node) in [("leaf", leaf), ("root", root)] {
            for scope in [LibraryFolderSongScope.direct, .descendants] {
                let songs = try await CarPlayFolderLibrary.catalogSongs(in: node, scope: scope, index: catalogIndex, reader: reader)
                XCTAssertEqual(songs.map(\.id), expectedFolders["\(name) \(scope)"], "released: folder \(name) \(scope)")
            }
        }
        for query in queries {
            let songs = await CarPlaySearchMatches.songs(matching: query, in: library, index: searchIndex)
            XCTAssertEqual(songs.map(\.id), expectedSearch[query], "released: search \(query)")
        }
        assertNoLoadAndNoArrayRead(library, since: before, "released")
    }

    /// 这次启动没装模型:各份列表、首页、文件夹从目录答,与装过模型的那个库的答案相同,一直没装。
    func testANeverLoadedLaunchAnswersCarPlayFromTheCatalog() async throws {
        let prefix = "c2-unloaded"
        let songs = Self.carPlayFixture(prefix: prefix)
        let wait = MusicLibrary.unloadedLaunchCatalogWait
        MusicLibrary.unloadedLaunchCatalogWait = .seconds(10)
        defer { MusicLibrary.unloadedLaunchCatalogWait = wait }
        let (source, storage) = try await launchFixture(prefix, songs: songs)
        let likes = likes(prefix, source)
        let expected = loadedPictures(CarPlayCatalogLists(), source, likes: likes)
        let playlistID = try XCTUnwrap(source.playlists.first { $0.name == "Kept" }?.id)
        let configuration = Self.homeConfiguration(
            prefix: prefix, playlistID: playlistID,
            albumID: try XCTUnwrap(source.visibleAlbums.first { $0.title == "Blue Room" }).id
        )
        let history = history(prefix)
        let loadedHome = loadedHome(source, history: history)
        let carry = CarPlayEditorCatalog.ForYouCarry(day: 1, snapshot: loadedHome)
        let memoryIndex = LibraryHubPinsReleasedTests.memoryFolderIndex(source)
        let root = try XCTUnwrap(memoryIndex.sourceNodes.first?.id)
        let expectedRoot = memoryIndex.songIDs(in: root, scope: .descendants)
            .compactMap { source.unobservedVisibleSong(id: $0) }.sorted(by: CarPlayFolderLibrary.playOrder).map(\.id)

        let library = await launch(try copyOfDirectory(storage, "\(prefix)-launch"), unloaded: true)
        XCTAssertEqual(library.songModelLaunch, "unloaded")
        try await waitUntilUsable(library)
        try await waitUntil("catalog readable") { library.readableCatalogReader != nil }
        XCTAssertTrue(library.isUsable && !library.isReady, "CarPlay builds its root now (usable), with the model out")
        let stats = library.songModelResidencyStatistics
        try await assertAnswers(CarPlayCatalogLists(), library, likes: likes, expected: expected, "never loaded")
        let releasedHome = await catalogHome(library, configuration, history: history, forYou: carry.items(intelligentOrder: []))
        XCTAssertEqual(homePicture(try XCTUnwrap(releasedHome), configuration), homePicture(loadedHome, configuration),
                       "never loaded: every home block")
        let catalogIndex = try await LibraryHubPinsReleasedTests.catalogFolderIndex(library)
        let rootSongs = try await CarPlayFolderLibrary.catalogSongs(
            in: root, scope: .descendants, index: catalogIndex, reader: try XCTUnwrap(library.readableCatalogReader)
        )
        XCTAssertEqual(rootSongs.map(\.id), expectedRoot, "never loaded: the whole source folder")
        assertNoLoadAndNoArrayRead(library, since: stats, "a launch that never loaded the model")
    }

    /// 目录读不了:每份列表、首页、文件夹里的歌都答不出(nil),不是空的;目录能读之后车机收到重建的信号,答案与内存里的相同。
    func testWhileTheCatalogCannotAnswerNothingIsShownAsEmptyAndTheAnswersFollow() async throws {
        let prefix = "c2-stuck"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.carPlayFixture(prefix: prefix))
        let kept = smallState(library, prefix: prefix)
        await assertShadowMatches(library, "fixture")
        let likes = likes(prefix, library)
        let expected = loadedPictures(CarPlayCatalogLists(), library, likes: likes)
        let configuration = Self.homeConfiguration(prefix: prefix, playlistID: kept.id, albumID: "")
        let index = LibraryHubPinsReleasedTests.memoryFolderIndex(library)
        let leaf = try XCTUnwrap(index.nodeID(containingSongID: "\(prefix)-blue-1"))

        library.dropSongModelForMeasurement(includingCollections: true)
        let revisions = try XCTUnwrap(library.catalogHost?.revisions)
        revisions.setReadable(false)
        defer { revisions.setReadable(true) }
        let lists = CarPlayCatalogLists()
        for (name, value) in pictures(lists, library, likes: likes) { XCTAssertNil(value, "cannot answer: \(name) is nil, not empty") }
        let home = await catalogHome(library, configuration, history: [], forYou: [])
        XCTAssertNil(home, "cannot answer: no home snapshot (the last one stays)")
        let unavailable = LibraryCatalogReader(catalog: { nil })
        do {
            _ = try await CarPlayFolderLibrary.catalogSongs(in: leaf, scope: .descendants, index: index, reader: unavailable)
            XCTFail("cannot answer: a folder is not played as empty")
        } catch {}
        let search = await CarPlaySearchMatches.songs(matching: "blue", in: library)
        XCTAssertTrue(search.isEmpty, "no catalog: no results, and no whole-library read")

        let signal = lists.revision
        revisions.setReadable(true)
        try await waitUntil("CarPlay is told to rebuild") { lists.revision != signal }
        try await assertAnswers(lists, library, likes: likes, expected: expected, "readable again")
        // 车机断开(或内存吃紧)时记着的答案放掉:再问时先是「答不出」,读完与内存里的相同。
        lists.forgetAnswers()
        XCTAssertNil(lists.albumsByTitle(in: library), "forgotten: pending again, not empty")
        try await assertAnswers(lists, library, likes: likes, expected: expected, "after forgetting")
    }
    #endif
}
