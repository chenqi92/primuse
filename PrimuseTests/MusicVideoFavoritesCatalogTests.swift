import Foundation
import PrimuseKit
import SwiftUI
import XCTest
@testable import Primuse
#if os(iOS)
import UIKit
#endif

/// 6c 单元 4 U8b(S5b、S5e):MV 页与收藏在歌曲模型不在内存里时从曲库目录答,与模型在内存里时逐项相同 ——
/// MV 的那些与先后(页面的三种排序、顶上那支),收藏区的成员与顺序(喜欢的专辑、艺人含只当过专辑艺人的、
/// 歌单、有声书),跟着喜欢挪顺序,收藏的书;模型放掉之后、这次启动根本没装模型两种状态。不装模型、不读整库数组。
@MainActor
final class MusicVideoFavoritesCatalogTests: LibraryReadyCatalogFixture {
    // MARK: - Music videos

    /// 页面的三种排序与顶上那支(`featuredSong`:最新加进来的,同一时刻取库内先后靠前的)。
    private func videoPicture(_ songs: [Song]) -> [String] {
        MusicVideoLibrarySort.allCases.map { sort in "\(sort): " + sort.sorted(songs).map(\.id).joined(separator: ",") }
            + ["featured: \(songs.max { $0.dateAdded < $1.dateAdded }?.id ?? "-")"]
    }

    private func catalogVideos(_ library: MusicLibrary, _ step: String) async throws -> [Song] {
        let answer = await MusicVideoCatalogSource.read(in: library)
        return try XCTUnwrap(answer.songs, "\(step): the catalog answered")
    }

    func testMusicVideosFromTheCatalogEqualTheModel() async throws {
        let (library, _) = try makeLaunchedTwin("mv-released", songs: Self.catalogFixture(prefix: "mv-released"))
        await assertShadowMatches(library, "fixture")
        let expected = library.musicVideoSongs.map(\.id)
        XCTAssertEqual(expected.count, 4, "four visible music videos; the disabled source's is not visible")
        let picture = videoPicture(library.musicVideoSongs)
        let loaded = try await catalogVideos(library, "loaded")
        XCTAssertEqual(loaded.map(\.id), expected)
        XCTAssertEqual(MusicVideoCatalogSource.songs(in: library, catalog: nil).map(\.id), expected, "loaded: the arrays")

        let before = try await releaseForReal(library)
        let songs = try await catalogVideos(library, "released")
        XCTAssertEqual(songs.map(\.id), expected, "same videos, library order")
        XCTAssertEqual(videoPicture(songs), picture, "same order in every sort, same featured video")
        let answer = MusicVideoCatalogSource.Answer.songs(songs)
        XCTAssertEqual(MusicVideoCatalogSource.songs(in: library, catalog: answer).map(\.id), expected)
        XCTAssertTrue(MusicVideoCatalogSource.isWaiting(in: library, catalog: nil), "loading until the catalog answers")
        XCTAssertFalse(MusicVideoCatalogSource.isWaiting(in: library, catalog: answer))
        XCTAssertFalse(MusicVideoCatalogSource.needsTheSongModel(in: library, catalog: answer))
        XCTAssertTrue(MusicVideoCatalogSource.needsTheSongModel(in: library, catalog: .cannotAnswer))
        XCTAssertTrue(MusicVideoCatalogSource.songs(in: library, catalog: nil).isEmpty)
        #if os(iOS)
        let shown = Box<MusicVideoCatalogSource.Answer?>(nil)
        let probe = try host(VideoProbe { shown.value = $0 }.environment(library))
        defer { unhost(probe) }
        try await waitUntil("the page's source") { shown.value != nil }
        XCTAssertEqual(shown.value?.songs?.map(\.id), expected)
        #endif
        assertNoLoadAndNoArrayRead(library, since: before, "released")

        let unloaded = try await launchWithoutTheSongModel("mv-unloaded")
        let stats = unloaded.library.songModelResidencyStatistics
        let fromLaunch = try await catalogVideos(unloaded.library, "unloaded launch")
        XCTAssertEqual(videoPicture(fromLaunch), videoPicture(unloaded.source.musicVideoSongs))
        assertNoLoadAndNoArrayRead(unloaded.library, since: stats, "unloaded launch")
    }

    // MARK: - Favorites

    private struct Setup {
        let likes: LibraryFavoritesStore
        let defaults: UserDefaults
        let store: FavoriteCollectionStore
    }

    /// 喜欢:两张可见专辑、一张库里没有的;艺人:一位曲目艺人、只当过专辑艺人的「Various Artists」、一位库里没有的。
    /// 收藏顺序里存着「我喜欢」、一个歌单、一本书。
    private func favorites(_ name: String, library: MusicLibrary, playlistID: String, bookID: String) throws -> Setup {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "favorites-catalog-\(name)-\(UUID().uuidString)"))
        defaults.set(true, forKey: FavoriteCollectionStore.migrationKey)
        let likes = LibraryFavoritesStore(fileURL: directory.appendingPathComponent("\(name)-likes.json"))
        let pins = [
            FavoriteCollectionStore.anchor,
            QuickAccessPinReference(kind: .playlist, itemID: playlistID),
            QuickAccessPinReference(kind: .book, itemID: bookID),
        ]
        defaults.set(LibraryPinStorage.encode(pins), forKey: LibraryPinStorage.defaultsKey)
        likes.setLiked(true, album: Album(id: "ghost", title: "Ghost Album", artistName: "Nobody"))
        likes.setLiked(true, artistNamed: "Nobody Here")
        let store = FavoriteCollectionStore(
            defaults: defaults, favorites: likes, cloud: CloudKVSSync(store: nil, defaults: defaults, observing: nil)
        )
        return Setup(likes: likes, defaults: defaults, store: store)
    }

    private func like(_ setup: Setup, in library: MusicLibrary) throws {
        let blue = try XCTUnwrap(library.visibleAlbums.first { $0.title == "Blue Room" })
        let live = try XCTUnwrap(library.visibleAlbums.first { $0.title == "Live Set" })
        setup.likes.setLiked(true, album: blue)
        setup.likes.setLiked(true, artistNamed: "Ada")
        setup.likes.setLiked(true, album: live)
        setup.likes.setLiked(true, artistNamed: "Various Artists")
    }

    private func pinPicture(_ store: FavoriteCollectionStore, _ library: MusicLibrary, among pins: [QuickAccessPinReference]) -> [String] {
        store.references(library: library).map(\.id)
            + pins.map { "\($0.id)=\(store.isCollected($0, library: library))" }
    }

    func testFavoritesFromTheCatalogEqualTheModel() async throws {
        let (library, _) = try makeLaunchedTwin("fav-released", songs: Self.catalogFixture(prefix: "fav-released"))
        await assertShadowMatches(library, "fixture")
        let albumOnly = try XCTUnwrap(library.visibleAlbumArtists.first { $0.name == "Various Artists" })
        XCTAssertNil(library.visibleArtist(id: albumOnly.id), "only an album artist")
        let playlist = library.createPlaylist(name: "Kept", songIDs: [])
        let bookID = try XCTUnwrap(library.spokenWordBookIDs.values.first)
        let setup = try favorites("released", library: library, playlistID: playlist.id, bookID: bookID)
        try like(setup, in: library)
        let probes = library.visibleAlbums.map { QuickAccessPinReference(kind: .album, itemID: $0.id) }
            + library.favoriteArtistCandidates.map { QuickAccessPinReference(kind: .artist, itemID: $0.id) }
        let expected = pinPicture(setup.store, library, among: probes)
        XCTAssertEqual(setup.store.references(library: library).filter { $0.kind == .album }.count, 2)
        XCTAssertTrue(setup.store.references(library: library).contains(QuickAccessPinReference(kind: .artist, itemID: albumOnly.id)))

        let before = try await releaseForReal(library)
        try await waitUntil("albums and artists from the catalog") { setup.store.answersAlbumsAndArtists(library: library) }
        XCTAssertEqual(pinPicture(setup.store, library, among: probes), expected, "same members, same order")
        assertNoLoadAndNoArrayRead(library, since: before, "released")

        // 这次启动没装模型:同一本账、同一份收藏顺序。
        let unloaded = try await launchWithoutTheSongModel("fav-unloaded")
        let stats = unloaded.library.songModelResidencyStatistics
        let launchPlaylist = try XCTUnwrap(unloaded.source.allPlaylists.first { $0.name == "Kept" })
        let launchBook = try XCTUnwrap(unloaded.source.spokenWordBookIDs.values.first)
        let source = try favorites("launch-source", library: unloaded.source, playlistID: launchPlaylist.id, bookID: launchBook)
        try like(source, in: unloaded.source)
        let launchProbes = unloaded.source.visibleAlbums.map { QuickAccessPinReference(kind: .album, itemID: $0.id) }
            + unloaded.source.favoriteArtistCandidates.map { QuickAccessPinReference(kind: .artist, itemID: $0.id) }
        let launchExpected = pinPicture(source.store, unloaded.source, among: launchProbes)
        let fresh = FavoriteCollectionStore(
            defaults: source.defaults, favorites: source.likes,
            cloud: CloudKVSSync(store: nil, defaults: source.defaults, observing: nil)
        )
        XCTAssertFalse(fresh.answersAlbumsAndArtists(library: unloaded.library), "loading until the catalog answers")
        try await waitUntil("albums and artists after an unloaded launch") {
            fresh.answersAlbumsAndArtists(library: unloaded.library)
        }
        XCTAssertEqual(pinPicture(fresh, unloaded.library, among: launchProbes), launchExpected)
        assertNoLoadAndNoArrayRead(unloaded.library, since: stats, "unloaded launch")
    }

    /// 模型不在内存里时点了喜欢:新收藏的专辑排到最前(「我喜欢」后面),与模型在内存里时排的一样,不等模型装回来。
    func testALikeWhileReleasedMovesToTheFrontLikeWhileLoaded() async throws {
        func run(_ name: String, release: Bool) async throws -> [String] {
            let (library, _) = try makeLaunchedTwin(name, songs: Self.catalogFixture(prefix: name))
            await assertShadowMatches(library, "\(name) fixture")
            let playlist = library.createPlaylist(name: "Kept", songIDs: [])
            let bookID = try XCTUnwrap(library.spokenWordBookIDs.values.first)
            let setup = try favorites(name, library: library, playlistID: playlist.id, bookID: bookID)
            try like(setup, in: library)
            setup.store.start(library: library)
            let album = try XCTUnwrap(library.visibleAlbums.first { $0.title == "Mixtape" })
            let before = release ? try await releaseForReal(library) : library.songModelResidencyStatistics
            if release {
                try await waitUntil("\(name): catalog answer") { setup.store.answersAlbumsAndArtists(library: library) }
            }
            setup.likes.setLiked(true, album: album)
            let pin = QuickAccessPinReference(kind: .album, itemID: album.id)
            try await waitUntil("\(name): the like moves to the front", timeout: .seconds(15)) {
                LibraryPinStorage.decode(setup.defaults.string(forKey: LibraryPinStorage.defaultsKey) ?? "").dropFirst().first == pin
            }
            if release { assertNoLoadAndNoArrayRead(library, since: before, "\(name)") }
            return setup.store.references(library: library).map { $0.kind == .playlist ? "\($0.kind)" : $0.id }
        }
        let loaded = try await run("like-loaded", release: false)
        let released = try await run("like-released", release: true)
        XCTAssertEqual(released.map { $0.replacingOccurrences(of: "like-released", with: "like-loaded") }, loaded)
    }

    /// 收藏的书:同模型在内存里时那一本(书、章节、先后),放掉之后、没装模型的启动都从目录问来。
    func testAFavoriteBookFromTheCatalogEqualsTheModel() async throws {
        let (library, _) = try makeLaunchedTwin("fav-book", songs: Self.catalogFixture(prefix: "fav-book"))
        await assertShadowMatches(library, "fixture")
        let bookID = try XCTUnwrap(library.spokenWordBookIDs.values.first)
        let expected = try XCTUnwrap(FavoriteCollectionResolver.book(id: bookID, library: library))
        XCTAssertEqual(expected.songs.count, 3)
        let before = try await releaseForReal(library)
        try await waitUntil("the book from the catalog") { FavoriteCollectionResolver.book(id: bookID, library: library) != nil }
        let answered = try XCTUnwrap(FavoriteCollectionResolver.book(id: bookID, library: library))
        XCTAssertEqual(answered.book, expected.book)
        XCTAssertEqual(answered.songs.map(\.id), expected.songs.map(\.id))
        XCTAssertNil(FavoriteCollectionResolver.book(id: "no-such-book", library: library), "asking")
        try await waitUntil("an unknown book is answered") { !FavoriteBookCatalog.shared.isReading(["no-such-book"]) }
        XCTAssertNil(FavoriteCollectionResolver.book(id: "no-such-book", library: library))
        assertNoLoadAndNoArrayRead(library, since: before, "released")
    }
}

/// 夹具与启动的共用:MV(含停用源里的一支)、只当过专辑艺人的「Various Artists」,真放掉与不装模型的启动。
@MainActor
class LibraryReadyCatalogFixture: LibraryReleasedTwinTestCase {
    static func catalogFixture(prefix: String) -> [Song] {
        var songs = fixture(prefix: prefix)
        func add(_ id: String, _ title: String, album: String, artist: String?, albumArtist: String? = nil,
                 path: String, source: String = sourceA, mv: Bool = false, added: TimeInterval) {
            var song = Song(
                id: "\(prefix)-\(id)", title: title, albumTitle: album, artistName: artist, albumArtistName: albumArtist,
                trackNumber: 1, discNumber: 1, duration: 200 + Double(songs.count), fileFormat: .flac,
                filePath: path, sourceID: source, genre: "Pop", year: 2015, coverArtFileName: nil
            )
            if mv { song.mvPath = path.replacingOccurrences(of: ".flac", with: ".mp4") }
            song.dateAdded = Date(timeIntervalSince1970: 1_700_200_000 + added)
            songs.append(song)
        }
        add("mv-zebra", "Zebra", album: "Clips", artist: "beta", path: "/Music/Clips/zebra.flac", mv: true, added: 10)
        add("mv-apple", "apple", album: "Clips", artist: "Alpha", path: "/Music/Clips/apple.flac", mv: true, added: 30)
        add("mv-apple2", "Apple", album: "Clips", artist: "alpha", path: "/Music/Clips/apple2.flac", mv: true, added: 30)
        add("mv-mango", "Mango", album: "Clips", artist: nil, path: "/Music/Clips/mango.flac", mv: true, added: 20)
        add("mv-hidden", "Hidden", album: "Clips B", artist: "Gamma", path: "/Share/Clips/hidden.flac",
            source: sourceB, mv: true, added: 40)
        for track in 1...2 {
            add("hits-\(track)", "Hit \(track)", album: "Hits Collection", artist: "Solo \(track)",
                albumArtist: "Various Artists", path: "/Music/Hits/\(track).flac", added: 50 + Double(track))
        }
        return songs
    }

    func launchWithoutTheSongModel(_ name: String) async throws -> (source: MusicLibrary, library: MusicLibrary) {
        let wait = MusicLibrary.unloadedLaunchCatalogWait
        MusicLibrary.unloadedLaunchCatalogWait = .seconds(10)
        defer { MusicLibrary.unloadedLaunchCatalogWait = wait }
        let (source, storage) = try await launchFixture(name, songs: Self.catalogFixture(prefix: name))
        let library = await launch(try copyOfDirectory(storage, "\(name)-launch"), unloaded: true)
        XCTAssertEqual(library.songModelLaunch, "unloaded")
        try await waitUntilUsable(library)
        try await waitUntil("\(name): catalog readable") { library.readableCatalogReader != nil }
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 0)
        return (source, library)
    }

    func waitUntil(
        _ step: String, timeout: Duration = .seconds(10), file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "\(step): timed out", file: file, line: line)
    }

    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    #if os(iOS)
    struct VideoProbe: View {
        let sink: (MusicVideoCatalogSource.Answer?) -> Void
        @State private var answer: MusicVideoCatalogSource.Answer?

        var body: some View {
            Color.clear
                .musicVideoCatalogSource($answer)
                .onChange(of: answer) { _, answer in sink(answer) }
        }
    }

    func host<Content: View>(_ view: Content) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        window.rootViewController?.view.layoutIfNeeded()
        return window
    }

    func unhost(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }
    #endif
}
