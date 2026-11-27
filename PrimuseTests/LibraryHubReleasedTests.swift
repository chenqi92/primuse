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
        XCTAssertEqual(tiles?.mapValues { $0.map(\.id) }, tilesLoaded, "MV, audiobook and ambient tile covers")
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
}
