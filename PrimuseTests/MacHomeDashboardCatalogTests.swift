import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U2a:Mac 首页与侧栏在歌曲模型真放掉之后从曲库目录作答,与模型在内存里时按整库数组算的相同;
/// 不装模型、不读整库数组;答不了时不当成 0;目录答不了才读数组时先把模型装回来。
@MainActor
final class MacHomeDashboardCatalogTests: LibraryReleasedTwinTestCase {
    /// 夹具之外:只有外部条目的专辑、混着外部条目的专辑(外部那首最新)、最新加入时间相同的两张专辑、带歌词文件的歌。
    static func dashboardExtras(prefix: String) -> [Song] {
        func song(_ id: String, album: String, artist: String, track: Int, added: TimeInterval,
                  cover: String? = nil, lyrics: String? = nil, external: Bool? = nil) -> Song {
            var song = Song(
                id: "\(prefix)-\(id)", title: "Extra \(id)", albumTitle: album, artistName: artist, albumArtistName: artist,
                trackNumber: track, discNumber: 1, duration: 200 + Double(track), fileFormat: .flac,
                filePath: "/Music/\(artist)/\(album)/\(id).flac", sourceID: sourceA, genre: "Pop", year: 2010,
                coverArtFileName: cover
            )
            song.lyricsFileName = lyrics
            song.isExternal = external
            song.dateAdded = Date(timeIntervalSince1970: 1_700_000_000 + added)
            return song
        }
        return [
            song("outside-1", album: "Outside", artist: "Preview", track: 1, added: 400, cover: "out.jpg", external: true),
            song("tie-a", album: "Tie A", artist: "Tie Band", track: 1, added: 300, lyrics: "tie-a.lrc"),
            song("tie-b", album: "Tie B", artist: "Other Band", track: 1, added: 300, cover: "tie-b.jpg"),
            song("tie-b2", album: "Tie B", artist: "Other Band", track: 2, added: 300, lyrics: "tie-b2.lrc", external: false),
            song("tie-b3", album: "Tie B", artist: "Other Band", track: 3, added: 600, external: true),
        ]
    }

    func assertSame(
        _ catalog: MacHomeDashboardSnapshot, _ arrays: MacHomeDashboardSnapshot,
        shownAlbums: Int, shownArtists: Int, _ step: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(catalog.songCount, arrays.songCount, "\(step): songs", file: file, line: line)
        XCTAssertEqual(catalog.albumCount, arrays.albumCount, "\(step): albums", file: file, line: line)
        XCTAssertEqual(catalog.artistCount, arrays.artistCount, "\(step): artists", file: file, line: line)
        XCTAssertEqual(catalog.totalDurationSec, arrays.totalDurationSec, accuracy: 0.001, "\(step): duration", file: file, line: line)
        XCTAssertEqual(catalog.coverCount, arrays.coverCount, "\(step): covers", file: file, line: line)
        XCTAssertEqual(catalog.lyricsCount, arrays.lyricsCount, "\(step): lyrics", file: file, line: line)
        XCTAssertEqual(catalog.playableCount, arrays.playableCount, "\(step): playable", file: file, line: line)
        XCTAssertEqual(catalog.recentlyAddedAlbumTotal, arrays.recentlyAddedAlbums.count, "\(step): recently added total",
                       file: file, line: line)
        func albumFields(_ albums: [Album]) -> [String] {
            albums.map { "\($0.id) \($0.title) \($0.artistName ?? "-") \($0.artistID ?? "-") \($0.songCount) \($0.year ?? 0)" }
        }
        XCTAssertEqual(albumFields(catalog.recentlyAddedAlbums), albumFields(Array(arrays.recentlyAddedAlbums.prefix(shownAlbums))),
                       "\(step): recently added albums", file: file, line: line)
        func artistFields(_ artists: [Artist]) -> [String] {
            artists.map { "\($0.id) \($0.name) \($0.songCount) \($0.albumCount)" }
        }
        XCTAssertEqual(artistFields(catalog.artists), artistFields(Array(arrays.artists.prefix(shownArtists))),
                       "\(step): artists", file: file, line: line)
        XCTAssertEqual(catalog.mosaicSongs.map(\.id), arrays.mosaicSongs.map(\.id), "\(step): mosaic", file: file, line: line)
        XCTAssertEqual(catalog.hasAllRecentlyAddedAlbums, shownAlbums >= arrays.recentlyAddedAlbums.count,
                       "\(step): all recently added albums", file: file, line: line)
        XCTAssertEqual(catalog.hasAllArtists, shownArtists >= arrays.artists.count, "\(step): all artists", file: file, line: line)
    }

    /// 首页快照:模型在内存里按整库数组算的,与放掉之后从目录读的逐项相同(计数、时长、封面/歌词/可播放、
    /// 「最近添加」的顺序与总数(含外部条目的两种设置、加入时间相同的专辑)、艺人、马赛克);读目录不装模型、
    /// 不读整库数组。
    func testTheDashboardFromTheCatalogMatchesTheArrays() async throws {
        let (library, _) = try makeLaunchedTwin(
            "mac-home", songs: Self.fixture(prefix: "mac-home"), extra: Self.dashboardExtras(prefix: "mac-home")
        )
        await assertShadowMatches(library, "fixture")
        // 最近播放:音乐、有声(要被去掉)、停用源的歌(不可见)。
        for suffix in ["comp-2", "book-1", "blueb-1", "loose", "blue-3"] {
            library.recordPlayback(of: "mac-home-\(suffix)")
        }
        let nonMusic = library.nonMusicSongIDs
        let recentlyPlayed = library.recentlyPlayedSongs(limit: MacHomeDashboardSnapshot.recentlyPlayedPoolLimit)
            .filter { !nonMusic.contains($0.id) }
        XCTAssertFalse(recentlyPlayed.isEmpty)
        var expected: [Bool: MacHomeDashboardSnapshot] = [:]
        for including in [false, true] {
            expected[including] = MacHomeDashboardSnapshot.fromArrays(
                songs: library.musicSongs, albums: library.visibleAlbums, artists: library.visibleArtists,
                recentlyPlayed: recentlyPlayed, includingExternalSongs: including
            )
        }
        XCTAssertNotEqual(expected[false]?.recentlyAddedAlbums.map(\.id), expected[true]?.recentlyAddedAlbums.map(\.id),
                          "the external songs change the order")
        XCTAssertGreaterThan(expected[false]?.lyricsCount ?? 0, 0)
        let recentIDs = library.recentPlaybackSongIDsForSync.filter { !nonMusic.contains($0) }

        let before = try await releaseForReal(library)
        let reader = try XCTUnwrap(library.readableCatalogReader)
        for including in [false, true] {
            let arrays = try XCTUnwrap(expected[including])
            for (albums, artists) in [(MacHomeDashboardSnapshot.shownRecentlyAddedAlbums, MacHomeDashboardSnapshot.shownArtists), (2, 1)] {
                let catalog = try await MacHomeDashboardSnapshot.fromCatalog(
                    reader: reader, recentlyPlayedIDs: recentIDs, includingExternalSongs: including,
                    shownAlbums: albums, shownArtists: artists
                )
                assertSame(catalog, arrays, shownAlbums: albums, shownArtists: artists,
                           "including \(including), first \(albums) albums and \(artists) artists")
            }
        }
        assertNoLoadAndNoArrayRead(library, since: before, "the dashboard from the catalog")

        let unavailable = LibraryCatalogReader(catalog: { nil })
        do {
            _ = try await MacHomeDashboardSnapshot.fromCatalog(reader: unavailable, recentlyPlayedIDs: [], includingExternalSongs: false)
            XCTFail("a catalog that cannot answer must not give an (empty) dashboard")
        } catch {}
    }

    /// 放掉时快照只留首页显示的那一段,总数不变,「查看全部」据此知道要装回模型;本来就不多的不动。
    func testKeepingTheShownListsKeepsTheTotals() {
        var snapshot = MacHomeDashboardSnapshot()
        snapshot.recentlyAddedAlbums = (0..<20).map { Album(id: "album-\($0)", title: "Album \($0)") }
        snapshot.recentlyAddedAlbumTotal = 20
        snapshot.artists = (0..<30).map { Artist(id: "artist-\($0)", name: "Artist \($0)") }
        snapshot.artistCount = 30
        XCTAssertTrue(snapshot.hasAllRecentlyAddedAlbums)
        XCTAssertTrue(snapshot.hasAllArtists)
        let kept = snapshot.keepingShownLists()
        XCTAssertEqual(kept.recentlyAddedAlbums.map(\.id), Array(snapshot.recentlyAddedAlbums.prefix(12)).map(\.id))
        XCTAssertEqual(kept.artists.map(\.id), Array(snapshot.artists.prefix(14)).map(\.id))
        XCTAssertEqual(kept.recentlyAddedAlbumTotal, 20)
        XCTAssertEqual(kept.artistCount, 30)
        XCTAssertFalse(kept.hasAllRecentlyAddedAlbums)
        XCTAssertFalse(kept.hasAllArtists)

        var small = MacHomeDashboardSnapshot()
        small.recentlyAddedAlbums = [Album(id: "only", title: "Only")]
        small.recentlyAddedAlbumTotal = 1
        XCTAssertEqual(small.keepingShownLists().recentlyAddedAlbums.map(\.id), ["only"])
        XCTAssertTrue(small.keepingShownLists().hasAllRecentlyAddedAlbums)
        var cleared = snapshot
        cleared.clearRecentlyAddedAlbums()
        XCTAssertTrue(cleared.hasAllRecentlyAddedAlbums, "cleared while the switch flips: empty, not loading")
    }

    /// 「最近添加」的播放键:快照只有首页那一段时,往后的专辑从目录取,与整库数组算的顺序相同;不装模型。
    func testRecentlyAddedPlaybackAlbumsComeFromTheCatalogWhileReleased() async throws {
        let (library, _) = try makeLaunchedTwin(
            "mac-home-play", songs: Self.fixture(prefix: "mac-home-play"), extra: Self.dashboardExtras(prefix: "mac-home-play")
        )
        await assertShadowMatches(library, "fixture")
        var expected: [Bool: [String]] = [:]
        for including in [false, true] {
            expected[including] = MacHomeDashboardSnapshot.recentlyAddedAlbums(
                songs: library.musicSongs, albums: library.visibleAlbums, includingExternalSongs: including
            ).map(\.id)
        }
        let before = try await releaseForReal(library)
        let reader = try XCTUnwrap(library.readableCatalogReader)
        for including in [false, true] {
            let shown = try await MacHomeDashboardSnapshot.fromCatalog(
                reader: reader, recentlyPlayedIDs: [], includingExternalSongs: including, shownAlbums: 1
            )
            XCTAssertFalse(shown.hasAllRecentlyAddedAlbums)
            let ids = await MacHomeDashboardSnapshot.recentlyAddedAlbumIDsForPlayback(
                shown, library: library, includingExternalSongs: including
            )
            XCTAssertEqual(ids, expected[including], "including \(including)")
        }
        assertNoLoadAndNoArrayRead(library, since: before, "recently added playback while released")
    }

    /// 侧栏:模型在内存里时与数组的数相同;放掉之后目录的计数读到了就是同样的数,还没读到时是 nil(不是 0),
    /// 侧栏沿用上一次显示的;「专辑艺术家」列法目录答不出,沿用同一种列法上一次的数,换了列法不沿用。
    /// 都不装模型、不读整库数组。
    func testSidebarCountsWhileReleasedNeverPretendZero() async throws {
        let (library, _) = try makeLaunchedTwin("mac-sidebar", songs: Self.fixture(prefix: "mac-sidebar"))
        await assertShadowMatches(library, "fixture")
        let sources = [Self.sourceA, Self.sourceB]
        let loaded = MacSidebarCounts.current(
            library: library, artistMode: .allArtists, hidesSingleOnlyAlbumArtists: false, sourceIDs: sources
        )
        XCTAssertEqual(loaded.music, library.musicSongs.count)
        XCTAssertEqual(loaded.ambient, library.ambientSongs.count)
        XCTAssertEqual(loaded.musicVideos, library.musicVideoSongs.count)
        XCTAssertEqual(loaded.albums, library.visibleAlbums.count)
        XCTAssertEqual(loaded.artists, library.visibleArtists.count)
        XCTAssertEqual(loaded.genres, library.visibleGenres.count)
        XCTAssertEqual(loaded.bySource[Self.sourceA], library.visibleSongCount(forSourceID: Self.sourceA))
        XCTAssertEqual(loaded.bySource[Self.sourceB], library.visibleSongCount(forSourceID: Self.sourceB))
        XCTAssertGreaterThan(loaded.ambient ?? 0, 0)
        let loadedAlbumArtists = MacSidebarCounts.current(
            library: library, artistMode: .albumArtists, hidesSingleOnlyAlbumArtists: false, sourceIDs: sources
        )
        XCTAssertEqual(loadedAlbumArtists.artists, library.browsableArtists(.albumArtists).count)

        let before = try await releaseForReal(library)
        for _ in 0..<250 where MacSidebarCounts.current(
            library: library, artistMode: .allArtists, hidesSingleOnlyAlbumArtists: false, sourceIDs: sources
        ).music == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let released = MacSidebarCounts.current(
            library: library, artistMode: .allArtists, hidesSingleOnlyAlbumArtists: false, sourceIDs: sources
        )
        XCTAssertEqual(released, loaded, "the catalog answers the same counts")

        let albumArtists = MacSidebarCounts.current(
            library: library, artistMode: .albumArtists, hidesSingleOnlyAlbumArtists: false, sourceIDs: sources
        )
        XCTAssertNil(albumArtists.artists, "album artists: unknown while released, not 0")
        XCTAssertEqual(albumArtists.music, loaded.music)
        XCTAssertEqual(albumArtists.filling(from: loadedAlbumArtists).artists, loadedAlbumArtists.artists,
                       "the last count of the same list stays")
        XCTAssertNil(albumArtists.filling(from: loaded).artists, "a count of the other list is not reused")
        let filtered = MacSidebarCounts.current(
            library: library, artistMode: .albumArtists, hidesSingleOnlyAlbumArtists: true, sourceIDs: sources
        )
        XCTAssertNil(filtered.filling(from: loadedAlbumArtists).artists, "another filter is another list")
        assertNoLoadAndNoArrayRead(library, since: before, "sidebar counts while released")

        let unknown = MacSidebarCounts(artistListKey: loaded.artistListKey)
        let filled = unknown.filling(from: loaded)
        XCTAssertEqual(filled, loaded, "nothing answers: everything stays as last shown")
    }

    /// 目录答不了才读整库数组的那一下:模型在内存里时直接读、不占用;放掉之后先占用 `.legacyPage` 装回来再读,
    /// 读到的与放掉之前相同,读完放手。
    func testTheArrayFallbackLoadsTheModelOnlyWhileReleased() async throws {
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        let (library, _) = try makeLaunchedTwin("mac-fallback", songs: Self.fixture(prefix: "mac-fallback"))
        await assertShadowMatches(library, "fixture")
        let loadedIDs = await MacLibraryArrayFallback.read(library) { library.musicSongIDsExcludingDisliked }
        XCTAssertFalse(loadedIDs.isEmpty)
        XCTAssertFalse(songModelHolds(of: library).contains(.legacyPage), "loaded: no hold")

        let before = try await releaseForReal(library)
        let releasedIDs = await MacLibraryArrayFallback.read(library) { library.musicSongIDsExcludingDisliked }
        XCTAssertEqual(releasedIDs, loadedIDs, "read after the model came back, not the empty arrays")
        XCTAssertEqual(songModelHolds(of: library).filter { $0 == .legacyPage }.count, 1)
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
        XCTAssertFalse(library.songModelHoldReasons.contains(.legacyPage), "the hold ended after the read")
    }
}
