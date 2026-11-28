import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// C1:歌曲模型不在内存里时,车机的两份艺人列表(A–Z 的前 500 位、喜欢的艺术家;两种列法,「专辑艺术家」带不带
/// 「不列只有单曲、EP 的人」)与资料库入口「艺术家」那一格(人数、头像,不列只有单曲的人时)从曲库目录答 —— 成员、
/// 先后与模型在内存里时相同,不装模型、不读整库数组,入口不再为它占用模型。目录里的发行类别还没算齐时答不出:车机
/// 给 nil(摆「正在准备」,不是空列表),入口照旧占用模型;算齐那一刻车机收到重建的信号,答案与内存里的相同。
@MainActor
final class AlbumArtistListsReleasedTests: LibraryReadyCatalogFixture {
    private var previousHiding: Any?

    override func setUp() async throws {
        try await super.setUp()
        previousHiding = UserDefaults.standard.object(forKey: AlbumArtistReleaseFilter.storageKey)
    }

    override func tearDown() async throws {
        if let previousHiding {
            UserDefaults.standard.set(previousHiding, forKey: AlbumArtistReleaseFilter.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AlbumArtistReleaseFilter.storageKey)
        }
        FullReleaseAlbumArtistMemo.shared.resetForTesting()
        try await super.tearDown()
    }

    private func setHidingSingles(_ hiding: Bool) {
        UserDefaults.standard.set(hiding, forKey: AlbumArtistReleaseFilter.storageKey)
    }

    private func picture(_ artists: [Artist]?) -> [String]? {
        artists?.map { "\($0.id)|\($0.name)" }
    }

    private func likes(_ name: String) -> LibraryFavoritesStore {
        let likes = LibraryFavoritesStore(fileURL: directory.appendingPathComponent("\(name)-likes.json"))
        for artist in ["Various Artists", "Echo", "Gus", "Ada", "DJ", "Nobody Here"] { likes.setLiked(true, artistNamed: artist) }
        return likes
    }

    private static let modes: [ArtistBrowseMode] = [.allArtists, .albumArtists]

    // MARK: CarPlay

    #if os(iOS)
    /// 车机两份列表在模型在内存里时的答案(就是车机以前的写法),按列法 × 不列只有单曲的人。
    private func carPlayLists(_ library: MusicLibrary, likes: LibraryFavoritesStore) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for hiding in [false, true] {
            setHidingSingles(hiding)
            for mode in Self.modes {
                let byName = CarPlayArtistLists.shared.firstByName(mode, in: library)
                let old = CarPlayListSelection.firstSorted(library.browsableArtists(mode), limit: 500) {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                XCTAssertEqual(picture(byName), picture(old), "loaded: the A–Z list as CarPlay built it")
                result["\(mode) hiding=\(hiding) byName"] = picture(byName)
                let liked = CarPlayArtistLists.shared.liked(mode, in: library, favorites: likes)
                XCTAssertEqual(picture(liked), picture(Array(likes.likedArtists(in: library.browsableArtists(mode)).prefix(500))))
                result["\(mode) hiding=\(hiding) liked"] = picture(liked)
            }
        }
        return result
    }

    /// 模型不在内存里时等每一份从目录答出来再比。`firstAskIsPending`:这份列表还没答过,第一次问是 nil(还在查,
    /// 不是空列表)。
    private func assertCarPlayLists(
        _ library: MusicLibrary, likes: LibraryFavoritesStore, expected: [String: [String]], firstAskIsPending: Bool,
        _ step: String
    ) async throws {
        for hiding in [false, true] {
            setHidingSingles(hiding)
            for mode in Self.modes {
                let name = "\(mode) hiding=\(hiding)"
                if firstAskIsPending, mode == .albumArtists {
                    XCTAssertNil(CarPlayArtistLists.shared.firstByName(mode, in: library), "\(step) \(name): pending, not empty")
                }
                try await waitUntil("\(step) \(name) A–Z", timeout: .seconds(15)) {
                    CarPlayArtistLists.shared.firstByName(mode, in: library) != nil
                }
                XCTAssertEqual(picture(CarPlayArtistLists.shared.firstByName(mode, in: library)), expected["\(name) byName"],
                               "\(step) \(name): A–Z")
                try await waitUntil("\(step) \(name) liked", timeout: .seconds(15)) {
                    CarPlayArtistLists.shared.liked(mode, in: library, favorites: likes) != nil
                }
                XCTAssertEqual(picture(CarPlayArtistLists.shared.liked(mode, in: library, favorites: likes)),
                               expected["\(name) liked"], "\(step) \(name): liked")
            }
        }
    }
    #endif

    // MARK: The hub's artists tile

    private static let seeds = ["seed-a", "seed-b", "seed-c", "seed-d"]

    private func artworkPicture(_ selection: LibraryArtworkPreviewSelection) -> [String] {
        [selection.songs.map(\.id).joined(separator: ","), selection.albums.map(\.id).joined(separator: ","),
         selection.artists.map { "\($0.id)|\($0.name)|\($0.albumCount)|\($0.songCount)|\($0.thumbnailPath ?? "-")" }
            .joined(separator: ",")]
            + selection.albumFallbackSongs.keys.sorted().map { "a:\($0)=\(selection.albumFallbackSongs[$0]!.map(\.id))" }
            + selection.artistFallbackSongs.keys.sorted().map { "r:\($0)=\(selection.artistFallbackSongs[$0]!.map(\.id))" }
    }

    /// 模型在内存里时入口按 `browsableArtists(.albumArtists)`(不列只有单曲的人)挑的头像。
    private func memoryFaces(_ library: MusicLibrary) -> [[String]] {
        setHidingSingles(true)
        let kept = library.browsableArtists(.albumArtists)
        return Self.seeds.map { seed in
            artworkPicture(LibraryArtworkPreviewBuilder.memorySelection(
                songs: library.visibleSongs, albums: library.visibleAlbums, artists: kept,
                randomSeed: seed, revision: "r", userRevision: "u", playlists: [], playlistMemberIDs: [:], radioStations: [],
                albumOverrideIDs: [], artistOverrideIDs: [], playlistOverrideIDs: [], pinnedAlbumIDs: [], pinnedArtistIDs: []
            ))
        }
    }

    /// 模型不在内存里时入口那一条路:`faces` 给出名单选择,`catalogSelection` 按筛过的列表挑。
    private func catalogFaces(_ library: MusicLibrary) throws -> [[String]] {
        let faces = LibraryHubArtistTile.faces(library, modeRawValue: ArtistBrowseMode.albumArtists.rawValue, hidingSingleOnly: true)
        XCTAssertTrue(faces.albumArtists)
        let choices = try XCTUnwrap(faces.fullReleaseChoices, "complete: the faces come from the kept list")
        let catalog = try XCTUnwrap(library.catalogHost?.mirror.readableCatalog)
        return try Self.seeds.map { seed in
            artworkPicture(try LibraryArtworkPreviewBuilder.catalogSelection(
                catalog: catalog, albumArtists: true, fullReleaseChoices: choices, randomSeed: seed, revision: "r",
                userRevision: "u", playlists: [], playlistMemberIDs: [:], radioStations: [], albumOverrideIDs: [],
                artistOverrideIDs: [], playlistOverrideIDs: [], pinnedAlbumIDs: [], pinnedArtistIDs: []
            ))
        }
    }

    private func needsTheSongModel(_ library: MusicLibrary) -> Bool {
        LibraryHubArtistTile.needsTheSongModel(library, modeRawValue: ArtistBrowseMode.albumArtists.rawValue, hidingSingleOnly: true)
    }

    // MARK: Tests

    func testCarPlayArtistListsAndTheHubArtistTileFromTheCatalogEqualTheModel() async throws {
        let prefix = "c1-artists"
        let (library, _) = try makeLaunchedTwin(prefix, songs: ReleaseCategoryPagesCatalogTests.releaseFixture(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        let likes = likes(prefix)
        setHidingSingles(true)
        let kept = library.browsableArtists(.albumArtists)
        setHidingSingles(false)
        let all = library.browsableArtists(.albumArtists)
        XCTAssertTrue(all.contains { $0.name == "Echo" } && !kept.contains { $0.name == "Echo" }, "the setting hides single-only Echo")
        XCTAssertTrue(kept.contains { $0.name == "Various Artists" }, "the album-only artist stays")
        #if os(iOS)
        let expectedLists = carPlayLists(library, likes: likes)
        XCTAssertFalse(expectedLists["albumArtists hiding=true liked"]?.isEmpty ?? true)
        #endif
        let expectedFaces = memoryFaces(library)
        XCTAssertFalse(expectedFaces[0][2].isEmpty, "faces were picked")
        XCTAssertNil(LibraryHubArtistTile.faces(library, modeRawValue: ArtistBrowseMode.albumArtists.rawValue,
                                                hidingSingleOnly: true).fullReleaseChoices, "loaded: the in-memory faces")

        let before = try await releaseForReal(library)
        #if os(iOS)
        try await assertCarPlayLists(library, likes: likes, expected: expectedLists, firstAskIsPending: true, "released")
        XCTAssertEqual(CarPlayArtistLists.preparingSections.first?.items.count, 1, "one row while it cannot answer")
        #endif
        setHidingSingles(true)
        XCTAssertFalse(needsTheSongModel(library), "released, categories complete: the hub takes no hold")
        XCTAssertEqual(try catalogFaces(library), expectedFaces, "released: the faces from the kept list")
        try await waitUntil("released: the kept count") {
            AlbumArtistCatalogCount.current(in: library, hidingSingleOnly: true) == kept.count
        }
        assertNoLoadAndNoArrayRead(library, since: before, "released")
    }

    /// 这次启动没装模型、刚升上来的目录、后台补算被用户的滑动挡着:车机答不出(nil,不是空列表)、入口照旧占用模型、
    /// 人数答不出;不筛的「专辑艺术家」照样从目录答。补齐之后车机收到重建的信号,答案、人数、头像与装过模型的那个库相同。
    func testWhileTheCategoriesAreIncompleteNothingIsShownAsEmptyAndTheAnswersFollowCompletion() async throws {
        let prefix = "c1-incomplete"
        let (source, storage) = try await launchFixture(prefix, songs: ReleaseCategoryPagesCatalogTests.releaseFixture(prefix: prefix))
        let likes = likes(prefix)
        #if os(iOS)
        let expectedLists = carPlayLists(source, likes: likes)
        #endif
        setHidingSingles(true)
        let expectedKept = source.browsableArtists(.albumArtists).count
        let expectedFaces = memoryFaces(source)
        do {
            let stored = try LibraryCatalog(path: storage.appendingPathComponent("library-catalog.sqlite").path)
            try stored.simulateReleaseCategoryUpgradeForTesting()
        }
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

        setHidingSingles(true)
        XCTAssertTrue(needsTheSongModel(library), "incomplete: the hub keeps today's hold")
        XCTAssertNil(AlbumArtistCatalogCount.current(in: library, hidingSingleOnly: true), "no count: unknown, not 0")
        XCTAssertNil(LibraryHubArtistTile.faces(library, modeRawValue: ArtistBrowseMode.albumArtists.rawValue,
                                                hidingSingleOnly: true).fullReleaseChoices, "incomplete: no faces are picked")
        #if os(iOS)
        XCTAssertNil(CarPlayArtistLists.shared.firstByName(.albumArtists, in: library), "incomplete: cannot answer, not empty")
        XCTAssertNil(CarPlayArtistLists.shared.liked(.albumArtists, in: library, favorites: likes))
        setHidingSingles(false)
        try await waitUntil("unfiltered album artists from the catalog", timeout: .seconds(15)) {
            CarPlayArtistLists.shared.firstByName(.albumArtists, in: library) != nil
        }
        XCTAssertEqual(picture(CarPlayArtistLists.shared.firstByName(.albumArtists, in: library)),
                       expectedLists["albumArtists hiding=false byName"])
        setHidingSingles(true)
        XCTAssertNil(CarPlayArtistLists.shared.firstByName(.albumArtists, in: library), "still incomplete")
        // 车机重建的信号:先让已经报过的信落地、再问一次(问的时候在这个目录上重新跟),从这一刻起只有目录(补齐)能让它变。
        try await Task.sleep(for: .milliseconds(300))
        let completedEarly = host.releaseCategoriesComplete
        _ = CarPlayArtistLists.shared.firstByName(.albumArtists, in: library)
        let signal = CarPlayArtistLists.shared.revision
        #endif

        try await waitUntil("the backfill completed", timeout: .seconds(20)) { host.releaseCategoriesComplete }
        #if os(iOS)
        if !completedEarly {
            try await waitUntil("CarPlay is told to rebuild") { CarPlayArtistLists.shared.revision != signal }
        }
        try await assertCarPlayLists(library, likes: likes, expected: expectedLists, firstAskIsPending: false, "complete")
        #endif
        setHidingSingles(true)
        XCTAssertFalse(needsTheSongModel(library), "complete: no hold")
        try await waitUntil("the kept count") {
            AlbumArtistCatalogCount.current(in: library, hidingSingleOnly: true) == expectedKept
        }
        XCTAssertEqual(try catalogFaces(library), expectedFaces, "complete: the faces from the kept list")
        assertNoLoadAndNoArrayRead(library, since: stats, "a launch that never loaded the model")
    }
}
