import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U1a:首页在歌曲模型放掉之后从曲库目录读的东西,与模型在内存里时相同,不装模型、不读整库数组。
@MainActor
final class HomeReleasedLibraryTests: LibraryReleasedTwinTestCase {
    /// 顶部封面、最近添加(歌与专辑)从目录算的与从整库数组算的相同;最近播放(S6)、「这一首是不是有声或环境音」、
    /// 常听的艺人,真放掉之后答出与装着时相同的。
    ///
    /// 「没读整库数组」:`recentlyPlayedSongs`、`nonMusicSongIDs` 的读不在诊断里(S8 第 1 项还没做),
    /// 所以这里另外断言放掉之后的答案与装着时的相同 —— 读到空数组就对不上。
    func testHomeHighlightsRecentAndTopArtistsAnswerFromTheCatalogWhileReleased() async throws {
        let songs = Self.fixture(prefix: "home-released")
        let (library, _) = try makeLaunchedTwin("home-released", songs: songs)
        await assertShadowMatches(library, "fixture")
        for song in [songs[4], songs[10], songs[1], songs[16], songs[0]] {
            library.recordPlayback(of: song.id)
        }
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let seeds = HomeHeroCarouselSeeds(prepared: nil, dayStamp: 20_261_127)
        let albumLimit = 12

        // 模型在内存里:数组那一路(同 `scheduleLibraryHighlightsRefresh` 的后备)。
        let music = library.musicSongs
        let recentLoaded = await HomeView.recentMusicSongs(limit: 30, library: library)
        XCTAssertEqual(recentLoaded?.map(\.id), library.recentlyPlayedSongs(limit: 30).map(\.id))
        XCTAssertFalse(recentLoaded?.isEmpty ?? true)
        let latestFromArrays = CarPlayListSelection.firstSorted(music.indices, limit: 60) {
            music[$0].dateAdded > music[$1].dateAdded
        }.map { music[$0] }
        let heroFromArrays = HomeView.makeHeroCoverSongs(
            musicSongs: music, latestAdded: latestFromArrays, recentSongs: recentLoaded ?? [],
            playedAlbumKeys: [], seeds: seeds
        )
        let tilesFromArrays = HomeView.makeRecentlyAddedAlbumTiles(
            songs: library.visibleSongs, albums: library.visibleAlbums, limit: albumLimit, includingExternalSongs: false
        )
        func fromCatalog(recent: [Song]) async throws -> HomeView.CatalogLibraryHighlights {
            try await HomeView.catalogLibraryHighlights(
                reader: reader, cachedLatestAdded: nil, cachedAlbumTiles: nil, recentSongs: recent,
                playedAlbumKeys: [], seeds: seeds, albumLimit: albumLimit, includingExternalSongs: false
            )
        }
        let loaded = try await fromCatalog(recent: recentLoaded ?? [])
        XCTAssertEqual(loaded.latestAdded.map(\.id), latestFromArrays.map(\.id), "recently added songs")
        XCTAssertEqual(loaded.heroCurrent.map(\.id), heroFromArrays.current.map(\.id), "hero covers")
        XCTAssertEqual(loaded.heroNext.map(\.id), heroFromArrays.next.map(\.id), "tomorrow's hero covers")
        XCTAssertEqual(loaded.albumTiles, tilesFromArrays, "recently added albums")
        let chapter = songs[10]
        let nonMusicLoaded = await HomeView.isNonMusic(chapter.id, library: library)
        let musicLoaded = await HomeView.isNonMusic(songs[0].id, library: library)
        XCTAssertEqual(nonMusicLoaded, true)
        XCTAssertEqual(musicLoaded, false)
        let names = ["Ada", "Artist 2", "Narrator"]
        let topLoaded = try await HomeView.catalogTopArtists(reader: reader, historyNames: names, limit: 6).map(\.id)

        let before = try await releaseForReal(library)
        let recentReleased = await HomeView.recentMusicSongs(limit: 30, library: library)
        XCTAssertEqual(recentReleased?.map(\.id), recentLoaded?.map(\.id), "recent songs from the catalog")
        let released = try await fromCatalog(recent: recentReleased ?? [])
        XCTAssertEqual(released.latestAdded.map(\.id), loaded.latestAdded.map(\.id))
        XCTAssertEqual(released.heroCurrent.map(\.id), loaded.heroCurrent.map(\.id))
        XCTAssertEqual(released.heroNext.map(\.id), loaded.heroNext.map(\.id))
        XCTAssertEqual(released.albumTiles, loaded.albumTiles)
        let nonMusicReleased = await HomeView.isNonMusic(chapter.id, library: library)
        let musicReleased = await HomeView.isNonMusic(songs[0].id, library: library)
        XCTAssertEqual(nonMusicReleased, nonMusicLoaded)
        XCTAssertEqual(musicReleased, musicLoaded)
        let topReleased = try await HomeView.catalogTopArtists(reader: reader, historyNames: names, limit: 6).map(\.id)
        XCTAssertEqual(topReleased, topLoaded)
        XCTAssertTrue(HomeView.refreshesFromTheCatalog(library), "Home refreshes from the catalog while released")
        assertNoLoadAndNoArrayRead(library, since: before, "Home inputs while released")
    }
}
