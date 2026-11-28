import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U3:资料库入口在歌曲模型放掉之后按曲库目录的数和小封面画,与模型在内存里时相同,
/// 不装模型、不读整库数组。
///
/// `musicVideoSongs`、`ambientSongs`、`localPodcastShowCount` 的读不在数组读的诊断里(S8 第 1 项):
/// 这里的证明是放掉之后的答案与装着时相同,读到空的就对不上。
@MainActor
final class LibraryHubReleasedTests: LibraryReleasedTwinTestCase {
    func testHubCountsAndTilePreviewsAnswerFromTheCatalogWhileReleased() async throws {
        var songs = Self.fixture(prefix: "hub-released")
        songs[0].mvPath = "/Videos/blue-1.mp4"
        songs[4].mvPath = "/Videos/comp-1.mp4"
        let episodes = (1...2).map { index in
            Song(id: "hub-released-episode-\(index)", title: "Episode \(index)", albumTitle: "Daily Show",
                 artistName: "Host", trackNumber: index, duration: 1_800, fileFormat: .mp3,
                 filePath: "/Podcasts/Daily/\(index).mp3", sourceID: Self.sourceA, genre: "Podcast")
        }
        let (library, _) = try makeLaunchedTwin("hub-released", songs: songs, extra: episodes)
        await assertShadowMatches(library, "fixture")
        let tilesLoaded: [LibrarySection: [String]] = [
            .musicVideos: library.musicVideoSongs.prefix(3).map(\.id),
            .spokenWord: library.spokenWordSongs.prefix(3).map(\.id),
            .ambient: library.ambientSongs.prefix(3).map(\.id),
        ]
        XCTAssertFalse(tilesLoaded[.musicVideos]?.isEmpty ?? true)
        XCTAssertFalse(tilesLoaded[.spokenWord]?.isEmpty ?? true)
        let showsLoaded = library.localPodcastShowCount
        XCTAssertGreaterThan(showsLoaded, 0)
        let countsLoaded = [
            library.musicSongs.count, library.visibleSongs.count, library.visibleAlbums.count,
            library.visibleArtists.count, library.visibleGenres.count, library.ambientSongs.count,
            library.musicVideoSongs.count, showsLoaded,
        ]

        let before = try await releaseForReal(library)
        let tiles = await LibraryHubReleased.tileSongs(library: library)
        XCTAssertEqual(tiles?.filter { $0.key != .genres }.mapValues { $0.map(\.id) }, tilesLoaded,
                       "MV, audiobook and ambient tile covers")
        let model = try XCTUnwrap(LibraryHubCatalogCountsModel.shared(for: library))
        for _ in 0..<250 where model.readableCounts == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let counts = try XCTUnwrap(model.readableCounts)
        XCTAssertEqual([
            counts.music, counts.visibleSongs, counts.albums, counts.artists, counts.genres, counts.ambient,
            counts.musicVideos, counts.podcastShows,
        ], countsLoaded, "the hub's tile counts from the catalog")
        assertNoLoadAndNoArrayRead(library, since: before, "hub while released")
    }

    /// U3b:封面预览(Q2)从曲库目录挑出的与按内存数组挑出的相同(同一个种子;歌、专辑、艺人、备用封面),
    /// 有声书的本数、章数与流派入口的封面也从目录答出与装着时相同的;不装模型、不读整库数组。
    func testHubArtworkSelectionGenreCoversAndBookTotalsMatchTheLoadedLibraryWhileReleased() async throws {
        var songs = Self.fixture(prefix: "hub-selection")
        songs[1].coverArtFileName = "blue-2.jpg"
        songs[5].coverArtFileName = "comp-2.jpg"
        let (library, _) = try makeLaunchedTwin("hub-selection", songs: songs)
        await assertShadowMatches(library, "fixture")
        let pinnedAlbum = try XCTUnwrap(library.visibleAlbums.last?.id)
        let pinnedArtist = try XCTUnwrap(library.visibleArtists.last?.id)
        func picture(_ selection: LibraryArtworkPreviewSelection) -> [String] {
            [selection.songs.map(\.id).joined(separator: ","), selection.albums.map(\.id).joined(separator: ","),
             selection.artists.map(\.id).joined(separator: ",")]
                + selection.albumFallbackSongs.keys.sorted().map { "a:\($0)=\(selection.albumFallbackSongs[$0]!.map(\.id))" }
                + selection.artistFallbackSongs.keys.sorted().map { "r:\($0)=\(selection.artistFallbackSongs[$0]!.map(\.id))" }
        }
        var loadedPictures: [[String]] = []
        for seed in ["seed-a", "seed-b", "seed-c"] {
            loadedPictures.append(picture(LibraryArtworkPreviewBuilder.memorySelection(
                songs: library.visibleSongs, albums: library.visibleAlbums, artists: library.browsableArtists(.allArtists),
                randomSeed: seed, revision: "r", userRevision: "u", playlists: [], playlistMemberIDs: [:], radioStations: [],
                albumOverrideIDs: [], artistOverrideIDs: [], playlistOverrideIDs: [],
                pinnedAlbumIDs: [pinnedAlbum], pinnedArtistIDs: [pinnedArtist]
            )))
        }
        XCTAssertFalse(loadedPictures[0][0].isEmpty)
        let genreCoversLoaded = library.visibleGenres.prefix(3).compactMap { genre in
            genre.representativeSongIDs.lazy.compactMap { library.visibleSong(id: $0) }.first?.id
        }
        let booksLoaded = [library.spokenWordBookCount, library.spokenWordChapterCount]
        XCTAssertGreaterThan(booksLoaded[0], 0)

        let before = try await releaseForReal(library)
        let catalog = try XCTUnwrap(library.catalogHost?.mirror.readableCatalog)
        for (index, seed) in ["seed-a", "seed-b", "seed-c"].enumerated() {
            let released = try LibraryArtworkPreviewBuilder.catalogSelection(
                catalog: catalog, randomSeed: seed, revision: "r", userRevision: "u", playlists: [], playlistMemberIDs: [:],
                radioStations: [], albumOverrideIDs: [], artistOverrideIDs: [], playlistOverrideIDs: [],
                pinnedAlbumIDs: [pinnedAlbum], pinnedArtistIDs: [pinnedArtist]
            )
            XCTAssertEqual(picture(released), loadedPictures[index], "the same selection for \(seed)")
        }
        let tiles = await LibraryHubReleased.tileSongs(library: library)
        XCTAssertEqual(tiles?[.genres]?.map(\.id), genreCoversLoaded, "genre tile covers")
        let model = try XCTUnwrap(LibraryHubCatalogCountsModel.shared(for: library))
        for _ in 0..<250 where model.readableCounts == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let counts = try XCTUnwrap(model.readableCounts)
        XCTAssertEqual([counts.spokenWordBooks, counts.spokenWordChapters], booksLoaded, "audiobook books and chapters")
        assertNoLoadAndNoArrayRead(library, since: before, "hub selection while released")
    }
}

