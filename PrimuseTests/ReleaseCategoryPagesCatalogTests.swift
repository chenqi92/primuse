import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// RC-b:目录里的发行类别算齐之后,专辑页按发行类别筛、艺术家页「不列只有单曲、EP 的人」(列表与人数)、详情页的
/// 发行分类都从曲库目录答 —— 与模型在内存里时页面那一份逐项、按先后相同(每种类别、手动按专辑与按歌选过的),
/// 模型放掉之后不装、不读整库数组,页面不再占用模型。没算齐时(刚升级、后台还在补)照旧走内存路径,不给空列表、
/// 不给 0;补齐那一刻页面改走目录。降级后旧版写过的行在下次启动时补好。
@MainActor
final class ReleaseCategoryPagesCatalogTests: LibraryReadyCatalogFixture {
    private var suites: [String] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        FullReleaseAlbumArtistMemo.shared.resetForTesting()
        try await super.tearDown()
    }

    /// 夹具之外:Ada 的现场专辑、单曲(按专辑名认出);Echo 只有一张 EP(按歌上的发行类型标签),只收一首、没标签的
    /// Faye One(按单曲算),Gus 的一首现场(标签);合辑「Hits Collection」的专辑艺人是只当过专辑艺人的「Various Artists」。
    static func releaseFixture(prefix: String) -> [Song] {
        var songs = catalogFixture(prefix: prefix)
        func add(_ id: String, album: String, artist: String, track: Int, releaseType: String? = nil) {
            var song = Song(
                id: "\(prefix)-\(id)", title: "\(album) \(track)", albumTitle: album, artistName: artist, albumArtistName: artist,
                trackNumber: track, discNumber: 1, duration: 230 + Double(songs.count), fileFormat: .flac,
                filePath: "/Music/\(artist)/\(album)/\(track).flac", sourceID: sourceA, genre: "Pop", year: 2010 + track
            )
            if let releaseType { song.contentMetadata = SongContentMetadata(releaseType: releaseType) }
            song.dateAdded = Date(timeIntervalSince1970: 1_700_400_000 + Double(songs.count))
            songs.append(song)
        }
        add("live-1", album: "Ada Live", artist: "Ada", track: 1)
        add("live-2", album: "Ada Live", artist: "Ada", track: 2)
        add("single-1", album: "Blue - Single", artist: "Ada", track: 1)
        add("echo-1", album: "Echo Days", artist: "Echo", track: 1, releaseType: "EP")
        add("echo-2", album: "Echo Days", artist: "Echo", track: 2, releaseType: "EP")
        add("faye-1", album: "Faye One", artist: "Faye", track: 1)
        add("gus-1", album: "Gus Nights", artist: "Gus", track: 1, releaseType: "Live")
        return songs
    }

    /// 一份手动选择(单独的存储,不碰 `.shared`):按专辑记的、按歌记的(记在别的专辑 id 上,经歌对到它此刻的专辑),
    /// 同一张专辑上按歌记的旧、按专辑记的新时以新的为准。
    private func choices(_ library: MusicLibrary, prefix: String) throws -> AlbumReleaseCategoryStore {
        let suite = "rc-pages-\(UUID().uuidString)"
        suites.append(suite)
        let store = AlbumReleaseCategoryStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        func albumID(_ title: String) throws -> String { try XCTUnwrap(library.visibleAlbums.first { $0.title == title }?.id, title) }
        func at(_ offset: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + offset) }
        store.set([.album], albumID: try albumID("Faye One"), songIDs: [], at: at(1))
        store.set([.album], albumID: "elsewhere-echo", songIDs: ["\(prefix)-echo-1"], at: at(2))
        store.set([.singleEP], albumID: "elsewhere-live", songIDs: ["\(prefix)-live-1"], at: at(3))
        store.set([.album, .live], albumID: try albumID("Ada Live"), songIDs: [], at: at(4))
        store.set([.live], albumID: try albumID("Blue - Single"), songIDs: [], at: at(5))
        return store
    }

    // MARK: Albums page

    private struct AlbumCase: Hashable {
        let order: AlbumGridOrder
        let category: AlbumReleaseCategory
        let manual: Bool
        let filtered: Bool
    }

    private static let orders: [AlbumGridOrder] = [.artist, .title, .year, .recentlyAdded, .songCount]

    private func predicate(_ filtered: Bool) -> AlbumGridAlbumPredicate {
        AlbumGridAlbumPredicate(query: filtered ? "e" : "", likedOnly: false, hidesSingleSongAlbums: filtered,
                                favorites: LibraryFavoriteLedger(), unknownArtistName: String(localized: "unknown_artist"))
    }

    /// 内存路径:页面那一套(`AlbumGridOrder.layout` 排好,`AlbumGridFilterRequest.filter` 按类别与条件筛)。
    private func memoryAlbums(
        _ library: MusicLibrary, overrides: [String: [String: Set<AlbumReleaseCategory>]]
    ) -> [AlbumCase: [String]] {
        let unknown = String(localized: "unknown_artist")
        var result: [AlbumCase: [String]] = [:]
        for order in Self.orders {
            let ordered = AlbumGridOrder.layout(library.visibleAlbums, order: order, songs: library.visibleSongs,
                                                unknownArtistName: unknown).items
            for category in AlbumReleaseCategory.allCases {
                for manual in [false, true] {
                    for filtered in [false, true] {
                        let condition = predicate(filtered)
                        let request = AlbumGridFilterRequest(
                            order: AlbumGridOrderRequest(order: order, albums: []), query: condition.query, category: category,
                            likedOnly: false, hidesSingleSongAlbums: condition.hidesSingleSongAlbums, favoritesRevision: 0,
                            categoryRevision: 0, membershipRevision: 0, overrideRevision: 0
                        )
                        result[AlbumCase(order: order, category: category, manual: manual, filtered: filtered)] = request.filter(
                            ordered, categories: library.releaseCategorySnapshot,
                            overrides: overrides[manual ? "manual" : "none"] ?? [:], favorites: condition.favorites,
                            unknownArtistName: unknown
                        )?.map(\.id)
                    }
                }
            }
        }
        return result
    }

    /// 目录路径:页面的列表查询(`LibraryAlbumBrowseQuery` 带上发行类别)。
    private func catalogAlbums(
        _ library: MusicLibrary, _ item: AlbumCase, choices: AlbumReleaseCategoryStore.Snapshot
    ) async throws -> [String] {
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let condition = predicate(item.filtered)
        let query = LibraryAlbumBrowseQuery(
            order: item.order.browseOrder ?? .title, bySongCount: item.order == .songCount,
            unknownArtistName: String(localized: "unknown_artist"), currentYear: 2026,
            predicate: condition.isEmpty ? nil : condition, releaseFilter: (item.category, choices)
        )
        let rows = try await reader.read { try query.fetchRows($0) }
        let keys = Array(rows.ids)
        return try await reader.read { try $0.albums(keys: keys, visibleCounts: true).map(\.id) }
    }

    private func assertAlbumPages(
        _ library: MusicLibrary, expected: [AlbumCase: [String]], manual: AlbumReleaseCategoryStore.Snapshot, _ step: String
    ) async throws {
        XCTAssertTrue(AlbumGridCatalogKey.catalogAnswers(.live, library: library), "\(step): the filtered page reads the catalog")
        for (item, want) in expected.sorted(by: { "\($0.key)" < "\($1.key)" }) {
            let shown = try await catalogAlbums(library, item, choices: item.manual ? manual : AlbumReleaseCategoryStore.Snapshot.empty)
            XCTAssertEqual(shown, want, "\(step): \(item)")
        }
    }

    func testAlbumsByReleaseCategoryFromTheCatalogEqualTheModel() async throws {
        let prefix = "rc-albums"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.releaseFixture(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        XCTAssertTrue(try XCTUnwrap(library.catalogHost).releaseCategoriesComplete, "a fresh catalog is complete")
        let store = try choices(library, prefix: prefix)
        let resolved = await library.resolvedReleaseOverrides(store.snapshot)
        let manual = try XCTUnwrap(resolved)
        let adaLive = try XCTUnwrap(library.visibleAlbums.first { $0.title == "Ada Live" })
        XCTAssertEqual(manual[adaLive.id], [.album, .live], "the newer choice by album wins over the older one by song")
        let expected = memoryAlbums(library, overrides: ["manual": manual])
        for category in AlbumReleaseCategory.allCases {
            XCTAssertFalse(expected[AlbumCase(order: .title, category: category, manual: false, filtered: false)]?.isEmpty ?? true,
                           "the fixture has \(category) albums")
        }
        XCTAssertNotEqual(expected[AlbumCase(order: .title, category: .live, manual: false, filtered: false)],
                          expected[AlbumCase(order: .title, category: .live, manual: true, filtered: false)],
                          "the manual choices change what is listed")
        try await assertAlbumPages(library, expected: expected, manual: store.snapshot, "loaded")

        let before = try await releaseForReal(library)
        try await assertAlbumPages(library, expected: expected, manual: store.snapshot, "released")
        assertNoLoadAndNoArrayRead(library, since: before, "released")
    }

    // MARK: Artists page

    /// 内存路径:「专辑艺术家」只留名下至少一张正式专辑的人(同 `albumArtistsWithFullReleases`,手动选择从外面给)。
    private func memoryKept(_ library: MusicLibrary, overrides: [String: Set<AlbumReleaseCategory>]) -> [Artist] {
        let release = library.releaseCategorySnapshot
        let albumByID = Dictionary(library.visibleAlbums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let artists = library.visibleAlbumArtists
        let credited = Dictionary(artists.map { ($0.id, library.albumIDs(creditedToArtist: $0.id)) }, uniquingKeysWith: { first, _ in first })
        return AlbumArtistReleaseFilter.artists(artists, albumIDsByArtistID: credited) { albumID in
            guard let album = albumByID[albumID] else { return false }
            let chosen = overrides[albumID]
            return AlbumArtistReleaseFilter.countsAsFullRelease(
                categories: chosen ?? release.categories(albumID: albumID), isManualChoice: chosen != nil, songCount: album.songCount
            )
        }
    }

    private struct ArtistExpected {
        let kept: [Artist]
        let likes: LibraryFavoritesStore
    }

    private func picture(_ artists: [Artist]) -> [String] {
        artists.map { "\($0.id)|\($0.name)|\($0.albumCount)|\($0.songCount)" }
    }

    /// 页面的各种列法(Mac 的先后 / iPhone 的读音 × 查找 × 只看喜欢)对着内存路径比;读音那一份连分段也比。
    private func assertArtistPages(
        _ library: MusicLibrary, _ expected: ArtistExpected, choices: FullReleaseAlbumArtistMemo.Choices, _ step: String
    ) async throws {
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let unknown = String(localized: "unknown_artist")
        let likedOrder = FavoriteCatalogLikes.likedOrder(expected.likes, .artist)
        for reading in [false, true] {
            for search in ["", "a"] {
                for liked in [false, true] {
                    var want = expected.kept
                    if reading { want = LibraryArtistBrowseLayoutBuilder.layout(artists: want, unknownArtistName: unknown).items }
                    if liked { want = expected.likes.likedArtists(in: want) }
                    if !search.isEmpty { want = want.filter { $0.name.localizedCaseInsensitiveContains(search) } }
                    let query = LibraryArtistBrowseQuery(
                        unknownArtistName: unknown, search: search, mode: .albumArtists, readingOrder: reading,
                        likedOrder: liked ? likedOrder : nil, fullReleaseChoices: choices
                    )
                    let rows = try await reader.read { try query.fetchRows($0) }
                    let ids = Array(rows.ids)
                    let cache = reader.rowCache
                    let items = try await reader.read { try query.materialize(ids, catalog: $0, rowCache: cache) }
                    XCTAssertEqual(picture(ids.compactMap { items[$0] }), picture(want),
                                   "\(step): reading=\(reading) search=\(search) liked=\(liked)")
                    if reading, search.isEmpty, !liked {
                        let layout = LibraryArtistBrowseLayoutBuilder.layout(artists: expected.kept, unknownArtistName: unknown)
                        XCTAssertEqual(rows.browseSections, layout.sections, "\(step): sections")
                    }
                }
            }
        }
    }

    private func withHidingSingles<T>(_ body: () throws -> T) rethrows -> T {
        let key = AlbumArtistReleaseFilter.storageKey
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        return try body()
    }

    func testFullReleaseAlbumArtistsFromTheCatalogEqualTheModel() async throws {
        let prefix = "rc-artists"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.releaseFixture(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        let likes = LibraryFavoritesStore(fileURL: directory.appendingPathComponent("rc-likes.json"))
        likes.setLiked(true, artistNamed: "Various Artists")
        likes.setLiked(true, artistNamed: "Echo")
        likes.setLiked(true, artistNamed: "Ada")
        let store = try choices(library, prefix: prefix)
        let resolved = await library.resolvedReleaseOverrides(store.snapshot)
        let manual = try XCTUnwrap(resolved)
        // 页面真正读的那一份(`.shared` 的手动选择、本机的开关)与按同一规则从外面给手动选择的那一份。
        let resolvedShared = await library.resolvedReleaseOverrides(AlbumReleaseCategoryStore.shared.snapshot)
        let sharedOverrides = try XCTUnwrap(resolvedShared)
        let pagePath = withHidingSingles { library.browsableArtists(.albumArtists) }
        XCTAssertEqual(picture(memoryKept(library, overrides: sharedOverrides)), picture(pagePath), "the rule as the page applies it")
        let plain = ArtistExpected(kept: pagePath, likes: likes)
        let chosen = ArtistExpected(kept: memoryKept(library, overrides: manual), likes: likes)
        let names = Set(library.visibleAlbumArtists.map(\.name))
        XCTAssertTrue(["Echo", "Faye", "Gus", "Various Artists"].allSatisfy(names.contains), "the fixture's album artists")
        XCTAssertFalse(plain.kept.contains { $0.name == "Echo" || $0.name == "Faye" }, "single-only album artists are hidden")
        XCTAssertTrue(plain.kept.contains { $0.name == "Gus" } && plain.kept.contains { $0.name == "Various Artists" })
        XCTAssertTrue(chosen.kept.contains { $0.name == "Echo" } && chosen.kept.contains { $0.name == "Faye" },
                      "chosen by song and by album, they are kept")
        try await assertArtistPages(library, plain, choices: .init(.shared), "loaded")
        try await assertArtistPages(library, chosen, choices: .init(store), "loaded, manual")

        let before = try await releaseForReal(library)
        // 同一组修订号:八种列法、侧栏与页面的人数共用一次查询。
        FullReleaseAlbumArtistMemo.shared.resetForTesting()
        try await assertArtistPages(library, plain, choices: .init(.shared), "released")
        XCTAssertEqual(FullReleaseAlbumArtistMemo.shared.computationsForTesting, 1, "computed once, then remembered")
        try await assertArtistPages(library, chosen, choices: .init(store), "released, manual")
        let key = ArtistCatalogKey.current(pagesLibrary: true, mode: .albumArtists, likedOnly: false, search: "",
                                           hidesSingles: true, requiresEmptySearch: true, library: library)
        XCTAssertNotNil(key?.fullReleaseRevision, "released: hiding single-only album artists reads the catalog, no hold")
        try await waitUntil("released: the count of the kept album artists") {
            AlbumArtistCatalogCount.current(in: library, hidingSingleOnly: true) == plain.kept.count
        }
        try await waitUntil("released: the sidebar count") {
            MacSidebarCounts.current(library: library, artistMode: .albumArtists, hidesSingleOnlyAlbumArtists: true,
                                     sourceIDs: []).artists == plain.kept.count
        }
        assertNoLoadAndNoArrayRead(library, since: before, "released")
    }

    // MARK: Detail pages

    func testDetailReleaseCategoriesFromTheStoredColumnsEqualTheModel() async throws {
        let prefix = "rc-detail"
        let (library, storage) = try makeLaunchedTwin(prefix, songs: Self.releaseFixture(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        let store = try choices(library, prefix: prefix)
        let albums = library.visibleAlbums
        let index = LibraryReleaseCategoryIndex.shared
        _ = albums.map { index.categories(for: $0, in: library, store: store) }
        await index.waitForPendingResolution()
        let expected = albums.map { "\($0.id)=\(index.categories(for: $0, in: library, store: store).map(\.rawValue).sorted())" }
        let automatic = albums.map { "\($0.id)=\(library.releaseCategorySnapshot.categories(albumID: $0.id).map(\.rawValue).sorted())" }

        let before = try await releaseForReal(library)
        await ReleaseCategoryCatalog.shared.prefetch(albums, library: library, store: store)
        let shown = albums.map {
            "\($0.id)=\(ReleaseCategoryCatalog.categories(for: $0, in: library, store: store).map(\.rawValue).sorted())"
        }
        XCTAssertEqual(shown, expected, "released: stored categories with the manual choices applied")
        assertNoLoadAndNoArrayRead(library, since: before, "released")

        // 还没算齐的目录(刚升上来):照同一条规则按可见的歌现算,与内存里自动认出的相同。
        await library.stopCatalogMirror()
        let copy = try copyOfDirectory(storage, "\(prefix)-upgraded")
        let upgraded = try LibraryCatalog(path: copy.appendingPathComponent("library-catalog.sqlite").path)
        try upgraded.simulateReleaseCategoryUpgradeForTesting()
        XCTAssertNil(try upgraded.albumReleaseCategories(), "not complete")
        let computed = try ReleaseCategoryCatalog.automaticCategories(of: albums, in: upgraded)
        XCTAssertEqual(albums.map { "\($0.id)=\((computed[$0.id] ?? []).map(\.rawValue).sorted())" }, automatic,
                       "computed by the rule while incomplete")
    }

    // MARK: Incomplete, then complete; repaired after a downgrade

    /// 刚升上来、后台的补算被用户的滑动挡着:这时各页照旧走内存路径(答不出,不给空列表、不给 0);补齐之后改走目录。
    func testIncompleteCategoriesKeepTheInMemoryPathUntilTheBackfillCompletes() async throws {
        let prefix = "rc-incomplete"
        let (source, storage) = try await launchFixture(prefix, songs: Self.releaseFixture(prefix: prefix))
        let expectedKept = withHidingSingles { source.browsableArtists(.albumArtists) }
        do {
            let stored = try LibraryCatalog(path: storage.appendingPathComponent("library-catalog.sqlite").path)
            try stored.simulateReleaseCategoryUpgradeForTesting()
        }
        // 滑动挡住整库的活:补算停在第一批之前。
        let wait = MusicLibrary.unloadedLaunchCatalogWait
        MusicLibrary.unloadedLaunchCatalogWait = .seconds(10)
        defer { MusicLibrary.unloadedLaunchCatalogWait = wait }
        UserScrollActivityMonitor.shared.recordInteraction(lasting: 8)
        let library = await launch(try copyOfDirectory(storage, "\(prefix)-launch"), unloaded: true)
        try await waitUntilUsable(library)
        try await waitUntil("catalog readable") { library.readableCatalogReader != nil }
        let host = try XCTUnwrap(library.catalogHost)
        let stats = library.songModelResidencyStatistics
        XCTAssertFalse(host.releaseCategoriesComplete, "the backfill waits for the interaction to end")
        XCTAssertTrue(AlbumGridCatalogKey.catalogAnswers(nil, library: library), "unfiltered albums still read the catalog")
        XCTAssertFalse(AlbumGridCatalogKey.catalogAnswers(.singleEP, library: library), "filtered by category: the in-memory path")
        XCTAssertNil(ArtistCatalogKey.current(pagesLibrary: true, mode: .albumArtists, likedOnly: false, search: "",
                                              hidesSingles: true, requiresEmptySearch: false, library: library),
                     "hiding single-only album artists: the in-memory path (the page holds the model)")
        XCTAssertNil(AlbumArtistCatalogCount.current(in: library, hidingSingleOnly: true), "no count: unknown, not 0")
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let albumQuery = LibraryAlbumBrowseQuery(order: .title, unknownArtistName: String(localized: "unknown_artist"),
                                                 currentYear: 2026, predicate: nil,
                                                 releaseFilter: (.singleEP, AlbumReleaseCategoryStore.Snapshot.empty))
        do {
            _ = try await reader.read { try albumQuery.fetchRows($0) }
            XCTFail("the album query cannot answer before the categories are complete")
        } catch {}
        let artistQuery = LibraryArtistBrowseQuery(unknownArtistName: String(localized: "unknown_artist"), search: "",
                                                   mode: .albumArtists, fullReleaseChoices: .init(.shared))
        do {
            _ = try await reader.read { try artistQuery.fetchRows($0) }
            XCTFail("the artist query cannot answer before the categories are complete")
        } catch {}

        try await waitUntil("the backfill completed", timeout: .seconds(20)) { host.releaseCategoriesComplete }
        XCTAssertTrue(AlbumGridCatalogKey.catalogAnswers(.singleEP, library: library), "complete: the catalog answers")
        XCTAssertNotNil(ArtistCatalogKey.current(pagesLibrary: true, mode: .albumArtists, likedOnly: false, search: "",
                                                 hidesSingles: true, requiresEmptySearch: false, library: library))
        try await waitUntil("the kept album artists' count") {
            AlbumArtistCatalogCount.current(in: library, hidingSingleOnly: true) == expectedKept.count
        }
        assertNoLoadAndNoArrayRead(library, since: stats, "a launch that never loaded the model")
    }

    /// 降级后旧版写过的目录(记着「算齐了」,有发行类别没写过的行):下次启动镜像第一次看就退回补算,补完的答案与
    /// 内存里的相同。
    func testRowsWrittenByAnOlderBuildAreRepairedAtTheNextLaunch() async throws {
        let prefix = "rc-downgrade"
        let (source, storage) = try await launchFixture(prefix, songs: Self.releaseFixture(prefix: prefix))
        let expected = Dictionary(source.visibleAlbums.map { ($0.id, source.releaseCategorySnapshot.categories(albumID: $0.id)) },
                                  uniquingKeysWith: { first, _ in first })
        do {
            let stored = try LibraryCatalog(path: storage.appendingPathComponent("library-catalog.sqlite").path)
            try stored.simulateRowsWrittenByAnOlderBuildForTesting(count: 3)
            XCTAssertTrue(try stored.releaseCategoriesAreComplete(), "still marked complete")
            XCTAssertNotEqual(try XCTUnwrap(try stored.albumReleaseCategories()), expected, "the rows are wrong now")
        }
        let wait = MusicLibrary.unloadedLaunchCatalogWait
        MusicLibrary.unloadedLaunchCatalogWait = .seconds(10)
        defer { MusicLibrary.unloadedLaunchCatalogWait = wait }
        let library = await launch(try copyOfDirectory(storage, "\(prefix)-launch"), unloaded: true)
        try await waitUntilUsable(library)
        try await waitUntil("catalog readable") { library.readableCatalogReader != nil }
        let host = try XCTUnwrap(library.catalogHost)
        try await waitUntil("repaired", timeout: .seconds(20)) { host.releaseCategoriesComplete }
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let repaired = try await reader.read { try $0.albumReleaseCategories() }
        XCTAssertEqual(try XCTUnwrap(repaired), expected, "the backfill repaired the rows")
        let clean = try await reader.read { try $0.releaseCategoriesAreComplete(checkingRows: true) }
        XCTAssertTrue(clean, "no row is left unwritten")
    }
}

extension AlbumReleaseCategoryStore.Snapshot {
    /// 测试:没有手动选择。
    @MainActor static var empty: Self {
        AlbumReleaseCategoryStore(defaults: UserDefaults(suiteName: "rc-empty-\(UUID().uuidString)") ?? .standard).snapshot
    }
}
