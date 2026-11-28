import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U3c:资料库入口不再为这几样占用歌曲模型 —— 「收藏」货架(成员、先后,含书、目录、只当过专辑艺人的
/// 「Various Artists」,对不上的跳过)、「专辑艺术家」列法的人数与头像(封面预览 Q2)、有声书的本数与章数。歌曲模型
/// 真放掉之后与这次启动根本没装模型两种状态下,从曲库目录答出的与模型在内存里时相同;不装模型、不读整库数组。
@MainActor
final class LibraryHubPinsReleasedTests: LibraryReadyCatalogFixture {
    private struct Favorites {
        let likes: LibraryFavoritesStore
        let defaults: UserDefaults
        let store: FavoriteCollectionStore
    }

    /// 收藏顺序里存着「我喜欢」、一个歌单、一个已删的歌单、一本书、一本不存在的书;目录收藏一个在的、一个不在的;
    /// 喜欢两张可见专辑、一位曲目艺人、只当过专辑艺人的「Various Artists」,外加库里没有的一张、一位。
    private func favorites(
        _ name: String, library: MusicLibrary, playlistID: String, bookID: String, folder: LibraryFolderNodeID
    ) throws -> Favorites {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "hub-pins-\(name)-\(UUID().uuidString)"))
        defaults.set(true, forKey: FavoriteCollectionStore.migrationKey)
        let ghostFolder = Self.ghostFolder
        defaults.set(HomeFolderPinStorage.encode([folder, ghostFolder]), forKey: HomeFolderPinStorage.key)
        defaults.set(LibraryPinStorage.encode([
            FavoriteCollectionStore.anchor,
            QuickAccessPinReference(kind: .playlist, itemID: playlistID),
            QuickAccessPinReference(kind: .playlist, itemID: "deleted-playlist"),
            QuickAccessPinReference(kind: .book, itemID: bookID),
            QuickAccessPinReference(kind: .book, itemID: "no-such-book"),
            .folder(folder),
            .folder(ghostFolder),
        ]), forKey: LibraryPinStorage.defaultsKey)
        let likes = LibraryFavoritesStore(fileURL: directory.appendingPathComponent("\(name)-likes.json"))
        likes.setLiked(true, album: Album(id: "ghost", title: "Ghost Album", artistName: "Nobody"))
        likes.setLiked(true, artistNamed: "Nobody Here")
        let blue = try XCTUnwrap(library.visibleAlbums.first { $0.title == "Blue Room" })
        let live = try XCTUnwrap(library.visibleAlbums.first { $0.title == "Live Set" })
        likes.setLiked(true, album: blue)
        likes.setLiked(true, artistNamed: "Ada")
        likes.setLiked(true, album: live)
        likes.setLiked(true, artistNamed: "Various Artists")
        let store = FavoriteCollectionStore(
            defaults: defaults, favorites: likes, cloud: CloudKVSSync(store: nil, defaults: defaults, observing: nil)
        )
        return Favorites(likes: likes, defaults: defaults, store: store)
    }

    private static let ghostFolder = LibraryFolderNodeID(sourceID: sourceA, kind: .folder, normalizedRelativePath: "No/Such/Folder")

    private func playlists(_ library: MusicLibrary) -> [Playlist] {
        library.playlists.filter { $0.id != MusicLibrary.likedSongsPlaylistID }
    }

    /// 源 A 按目录分(扫描根三处),与首页、目录页同一套建法。
    private static let folderSource = LibraryFolderSourceDescriptor(
        sourceID: sourceA, displayName: "A", scanRoots: ["/Music", "/Books", "/Ambient"],
        pathSemantics: .hierarchical, pathEncoding: .native
    )

    /// 模型在内存里时首页那条路:按整库可见歌建。
    static func memoryFolderIndex(_ library: MusicLibrary) -> LibraryFolderIndex {
        LibraryFolderIndexBuilder.build(
            sources: [folderSource], songs: library.visibleSongs, spokenWordSongIDs: library.spokenWordSongIDs
        )
    }

    /// 模型不在内存里时那条路:按曲库目录建。
    static func catalogFolderIndex(_ library: MusicLibrary) async throws -> LibraryFolderIndex {
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let spoken = library.spokenWordSongIDs
        let descriptor = folderSource
        return try await reader.folderIndex { catalog, isCancelled in
            try LibraryFolderIndexBuilder.build(
                sources: [descriptor],
                catalog: LibraryFolderCatalogInput(catalog: catalog, kinds: nil, ordersSpokenWordLikeShelf: !spoken.isEmpty),
                unlistedSource: { LibraryFolderUnlistedSource.descriptor(sourceID: $0, appleMusicName: "AM", genericName: "S") },
                spokenWordSongIDs: spoken,
                isCancelled: isCancelled
            )
        }
    }

    private func artworkPicture(_ selection: LibraryArtworkPreviewSelection) -> [String] {
        [selection.songs.map(\.id).joined(separator: ","), selection.albums.map(\.id).joined(separator: ","),
         selection.artists.map { "\($0.id)|\($0.name)|\($0.albumCount)|\($0.songCount)|\($0.thumbnailPath ?? "-")" }
            .joined(separator: ",")]
            + selection.albumFallbackSongs.keys.sorted().map { "a:\($0)=\(selection.albumFallbackSongs[$0]!.map(\.id))" }
            + selection.artistFallbackSongs.keys.sorted().map { "r:\($0)=\(selection.artistFallbackSongs[$0]!.map(\.id))" }
    }

    private static let seeds = ["seed-a", "seed-b", "seed-c", "seed-d"]

    /// 「专辑艺术家」列法的封面预览,按内存里的数组挑(与 `refreshArtworkPreviews` 装着时同一份输入)。
    private func memoryAlbumArtistSelections(_ library: MusicLibrary, pinnedAlbum: String, pinnedArtists: Set<String>) -> [[String]] {
        Self.seeds.map { seed in
            artworkPicture(LibraryArtworkPreviewBuilder.memorySelection(
                songs: library.visibleSongs, albums: library.visibleAlbums, artists: library.visibleAlbumArtists,
                randomSeed: seed, revision: "r", userRevision: "u", playlists: [], playlistMemberIDs: [:], radioStations: [],
                albumOverrideIDs: [], artistOverrideIDs: [], playlistOverrideIDs: [],
                pinnedAlbumIDs: [pinnedAlbum], pinnedArtistIDs: pinnedArtists
            ))
        }
    }

    private func catalogAlbumArtistSelections(_ library: MusicLibrary, pinnedAlbum: String, pinnedArtists: Set<String>) throws -> [[String]] {
        let catalog = try XCTUnwrap(library.catalogHost?.mirror.readableCatalog)
        return try Self.seeds.map { seed in
            artworkPicture(try LibraryArtworkPreviewBuilder.catalogSelection(
                catalog: catalog, albumArtists: true, randomSeed: seed, revision: "r", userRevision: "u",
                playlists: [], playlistMemberIDs: [:], radioStations: [], albumOverrideIDs: [], artistOverrideIDs: [],
                playlistOverrideIDs: [], pinnedAlbumIDs: [pinnedAlbum], pinnedArtistIDs: pinnedArtists
            ))
        }
    }

    private func hubCounts(_ library: MusicLibrary) async throws -> LibraryHubCatalogCounts {
        let model = try XCTUnwrap(LibraryHubCatalogCountsModel.shared(for: library))
        try await waitUntil("hub counts") { model.readableCounts != nil }
        return try XCTUnwrap(model.readableCounts)
    }

    /// 货架答出来为止(喜欢从目录对出来、书问到了)。
    private func catalogShelf(
        _ library: MusicLibrary, _ favorites: Favorites, folderIndex: LibraryFolderIndex, _ step: String
    ) async throws -> [String] {
        let playlists = playlists(library)
        try await waitUntil("\(step): the shelf from the catalog", timeout: .seconds(15)) {
            LibraryHubPins.visible(library: library, playlists: playlists, folderIndex: folderIndex, store: favorites.store) != nil
        }
        let shelf = try XCTUnwrap(LibraryHubPins.visible(
            library: library, playlists: playlists, folderIndex: folderIndex, store: favorites.store
        ))
        return shelf.map(\.id)
    }

    func testTheHubShelfAlbumArtistTileAndBookCountsAnswerFromTheCatalogWhileReleased() async throws {
        let prefix = "hub-pins"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.catalogFixture(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        let playlist = library.createPlaylist(name: "Kept", songIDs: [])
        let bookID = try XCTUnwrap(library.spokenWordBookIDs.values.first)
        let memoryIndex = Self.memoryFolderIndex(library)
        let folder = try XCTUnwrap(memoryIndex.sourceNodeIDs.first.flatMap { memoryIndex.children(of: $0).first?.id })
        let setup = try favorites("released", library: library, playlistID: playlist.id, bookID: bookID, folder: folder)

        // 模型在内存里:货架的成员与先后(对不上的歌单、书、目录跳过)。
        let expectedShelf = try XCTUnwrap(LibraryHubPins.visible(
            library: library, playlists: playlists(library), folderIndex: memoryIndex, store: setup.store
        )).map(\.id)
        let albumOnly = try XCTUnwrap(library.visibleAlbumArtists.first { $0.name == "Various Artists" })
        XCTAssertTrue(expectedShelf.contains(QuickAccessPinReference(kind: .artist, itemID: albumOnly.id).id))
        XCTAssertTrue(expectedShelf.contains(QuickAccessPinReference(kind: .book, itemID: bookID).id))
        XCTAssertTrue(expectedShelf.contains(QuickAccessPinReference.folder(folder).id))
        XCTAssertFalse(expectedShelf.contains(QuickAccessPinReference(kind: .book, itemID: "no-such-book").id))
        XCTAssertFalse(expectedShelf.contains(QuickAccessPinReference(kind: .playlist, itemID: "deleted-playlist").id))
        XCTAssertFalse(expectedShelf.contains(QuickAccessPinReference.folder(Self.ghostFolder).id), "the ghost folder is skipped")
        let pinnedAlbum = try XCTUnwrap(library.visibleAlbums.first { $0.title == "Blue Room" }?.id)
        let pinnedArtists: Set<String> = [albumOnly.id, try XCTUnwrap(library.visibleArtist(named: "Ada")?.id)]
        let expectedArtwork = memoryAlbumArtistSelections(library, pinnedAlbum: pinnedAlbum, pinnedArtists: pinnedArtists)
        XCTAssertFalse(expectedArtwork[0][2].isEmpty, "album-artist faces were picked")
        let expectedAlbumArtists = library.visibleAlbumArtists.count
        let expectedBooks = [library.spokenWordBookCount, library.spokenWordChapterCount]
        XCTAssertGreaterThan(expectedBooks[0], 0)
        let expectedSpokenWord = library.hasSpokenWordContent

        let before = try await releaseForReal(library)
        let catalogIndex = try await Self.catalogFolderIndex(library)
        let shelf = try await catalogShelf(library, setup, folderIndex: catalogIndex, "released")
        XCTAssertEqual(shelf, expectedShelf, "released: same members, same order")
        // 目录索引还没建好时(有目录收藏)答不了,不当成目录不在。
        XCTAssertNil(LibraryHubPins.visible(library: library, playlists: playlists(library), folderIndex: nil, store: setup.store))
        XCTAssertNil(LibraryHubPins.exists(.folder(folder), library: library, playlists: [], folderIndex: nil))
        XCTAssertEqual(try catalogAlbumArtistSelections(library, pinnedAlbum: pinnedAlbum, pinnedArtists: pinnedArtists),
                       expectedArtwork, "released: album-artist faces (Q2) from the catalog")
        try await waitUntil("released: album-artist count") { AlbumArtistCatalogCount.current(in: library) == expectedAlbumArtists }
        let counts = try await hubCounts(library)
        XCTAssertEqual([counts.spokenWordBooks, counts.spokenWordChapters], expectedBooks, "released: books and chapters")
        XCTAssertEqual(library.hasSpokenWordContent, expectedSpokenWord, "released: the spoken-word tile")
        XCTAssertEqual(LibraryStackDetail.allCases.map(\.readiness), [.catalog, .catalog, .catalog],
                       "album, artist and playlist pages in the Library stack wait only for the catalog")
        assertNoLoadAndNoArrayRead(library, since: before, "released")
    }

    /// 这次启动根本没装模型:以前货架一次都没算过就占用模型;现在从目录对出与装过模型的那一份相同的货架。
    func testTheHubShelfAfterALaunchThatDidNotLoadTheSongModel() async throws {
        let unloaded = try await launchWithoutTheSongModel("hub-pins-unloaded")
        let stats = unloaded.library.songModelResidencyStatistics
        let source = unloaded.source
        let launchPlaylist = try XCTUnwrap(source.allPlaylists.first { $0.name == "Kept" })
        let launchBook = try XCTUnwrap(source.spokenWordBookIDs.values.first)
        let memoryIndex = Self.memoryFolderIndex(source)
        let folder = try XCTUnwrap(memoryIndex.sourceNodeIDs.first.flatMap { memoryIndex.children(of: $0).first?.id })
        let setup = try favorites("launch", library: source, playlistID: launchPlaylist.id, bookID: launchBook, folder: folder)
        let expectedShelf = try XCTUnwrap(LibraryHubPins.visible(
            library: source, playlists: playlists(source), folderIndex: memoryIndex, store: setup.store
        )).map(\.id)
        XCTAssertGreaterThan(expectedShelf.count, 5)
        let pinnedAlbum = try XCTUnwrap(source.visibleAlbums.first { $0.title == "Blue Room" }?.id)
        let albumOnly = try XCTUnwrap(source.visibleAlbumArtists.first { $0.name == "Various Artists" })
        let pinnedArtists: Set<String> = [albumOnly.id]
        let expectedArtwork = memoryAlbumArtistSelections(source, pinnedAlbum: pinnedAlbum, pinnedArtists: pinnedArtists)

        let fresh = FavoriteCollectionStore(
            defaults: setup.defaults, favorites: setup.likes,
            cloud: CloudKVSSync(store: nil, defaults: setup.defaults, observing: nil)
        )
        let launched = Favorites(likes: setup.likes, defaults: setup.defaults, store: fresh)
        let library = unloaded.library
        XCTAssertNil(LibraryHubPins.visible(library: library, playlists: playlists(library), folderIndex: nil, store: fresh),
                     "nothing is shown as missing before the catalog answers")
        let catalogIndex = try await Self.catalogFolderIndex(library)
        let shelf = try await catalogShelf(library, launched, folderIndex: catalogIndex, "unloaded launch")
        XCTAssertEqual(shelf, expectedShelf, "unloaded launch: the shelf equals the loaded one")
        XCTAssertEqual(try catalogAlbumArtistSelections(library, pinnedAlbum: pinnedAlbum, pinnedArtists: pinnedArtists),
                       expectedArtwork, "unloaded launch: album-artist faces")
        try await waitUntil("unloaded launch: album-artist count") {
            AlbumArtistCatalogCount.current(in: library) == source.visibleAlbumArtists.count
        }
        let counts = try await hubCounts(library)
        XCTAssertEqual([counts.spokenWordBooks, counts.spokenWordChapters],
                       [source.spokenWordBookCount, source.spokenWordChapterCount], "unloaded launch: books and chapters")
        XCTAssertEqual(library.hasSpokenWordContent, source.hasSpokenWordContent, "unloaded launch: the spoken-word tile")
        assertNoLoadAndNoArrayRead(library, since: stats, "unloaded launch")
    }
}
