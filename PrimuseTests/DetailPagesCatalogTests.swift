import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 详情页:艺人页的两排专辑(他发行的、他参与的)与发行分类、专辑页的歌、艺人链接与封面借的那首,
/// 在歌曲模型不在内存里时从曲库目录答,与模型在内存里时逐项相同 —— 一位普通艺人、一位专辑艺人、只当过专辑艺人的
/// 「Various Artists」、只在合辑里唱过的人;模型放掉之后、这次启动没装模型两种状态,不装、不读整库数组。
@MainActor
final class DetailPagesCatalogTests: LibraryReadyCatalogFixture {
    /// 夹具之外:Ada 的一张现场专辑、一张单曲(按专辑名认出分类),Solo 1 也署名在一张合作专辑上(「Ada/Solo 1」按分隔符拆开)。
    static func detailFixture(prefix: String) -> [Song] {
        var songs = catalogFixture(prefix: prefix)
        func add(_ id: String, _ title: String, album: String, artist: String, albumArtist: String, track: Int, year: Int) {
            var song = Song(
                id: "\(prefix)-\(id)", title: title, albumTitle: album, artistName: artist, albumArtistName: albumArtist,
                trackNumber: track, discNumber: 1, duration: 240 + Double(songs.count), fileFormat: .flac,
                filePath: "/Music/\(albumArtist)/\(album)/\(track).flac", sourceID: sourceA, genre: "Pop", year: year
            )
            song.dateAdded = Date(timeIntervalSince1970: 1_700_300_000 + Double(songs.count))
            songs.append(song)
        }
        add("live-1", "Blue Live", album: "Ada Live", artist: "Ada", albumArtist: "Ada", track: 1, year: 2005)
        add("live-2", "Room Live", album: "Ada Live", artist: "Ada", albumArtist: "Ada", track: 2, year: 2005)
        add("single-1", "Blue Edit", album: "Blue - Single", artist: "Ada", albumArtist: "Ada", track: 1, year: 2004)
        add("duet-1", "Duet", album: "Duets", artist: "Ada", albumArtist: "Ada/Solo 1", track: 1, year: 2003)
        return songs
    }

    private struct ExpectedArtist {
        let artist: Artist
        let displayName: String
        let releases: [String]
        let appearsOn: [String]
        let categories: [String]
    }

    private func displayName(_ artist: Artist) -> String {
        let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "unknown_artist") : name
    }

    private func categoryPicture(_ albums: [Album], _ categories: (Album) -> Set<AlbumReleaseCategory>) -> [String] {
        albums.map { album in "\(album.id)=" + categories(album).map(\.rawValue).sorted().joined(separator: "+") }
    }

    /// 模型在内存里时艺人页那几句(`ArtistDetailView.albumShelves`、`releases(in:)`)。
    private func expectedArtist(_ artist: Artist, in library: MusicLibrary) -> ExpectedArtist {
        let name = displayName(artist)
        let partition = ArtistAlbumShelfPolicy.partition(
            albums: library.visibleAlbums, artistID: artist.id, displayName: name,
            songAlbumIDs: Set(library.songs(forArtist: artist.id).compactMap(\.albumID)),
            isCredited: { library.isAlbum($0, creditedToArtist: artist.id) }
        )
        return ExpectedArtist(
            artist: artist, displayName: name, releases: partition.releases.map(\.id), appearsOn: partition.appearsOn.map(\.id),
            categories: categoryPicture(partition.releases) { LibraryReleaseCategoryIndex.shared.categories(for: $0, in: library) }
        )
    }

    private func assertCatalogArtist(
        _ expected: ExpectedArtist, in library: MusicLibrary, _ step: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let key = try XCTUnwrap(ArtistCatalogShelves.key(
            artistID: expected.artist.id, displayName: expected.displayName, library: library
        ), "\(step): the catalog answers", file: file, line: line)
        let songs = library.songs(forArtist: expected.artist.id)
        let shelves = await ArtistCatalogShelves.load(key, songs: songs, library: library)
        let loaded = try XCTUnwrap(shelves, "\(step): \(expected.artist.name) shelves", file: file, line: line)
        XCTAssertEqual(loaded.release.map(\.id), expected.releases, "\(step): \(expected.artist.name) releases", file: file, line: line)
        XCTAssertEqual(loaded.appearsOn.map(\.id), expected.appearsOn, "\(step): \(expected.artist.name) appears on",
                       file: file, line: line)
        XCTAssertEqual(categoryPicture(loaded.release) { ReleaseCategoryCatalog.categories(for: $0, in: library) },
                       expected.categories, "\(step): \(expected.artist.name) release categories", file: file, line: line)
    }

    private func artists(_ library: MusicLibrary) throws -> [Artist] {
        let ada = try XCTUnwrap(library.visibleArtists.first { $0.name == "Ada" })
        let dj = try XCTUnwrap(library.visibleArtists.first { $0.name == "DJ" })
        let solo = try XCTUnwrap(library.visibleArtists.first { $0.name == "Solo 1" })
        let various = try XCTUnwrap(library.visibleAlbumArtists.first { $0.name == "Various Artists" })
        XCTAssertNil(library.visibleArtist(id: various.id), "only an album artist")
        return [ada, dj, solo, various]
    }

    func testDetailPagesFromTheCatalogEqualTheModel() async throws {
        let (library, _) = try makeLaunchedTwin("detail-pages", songs: Self.detailFixture(prefix: "detail-pages"))
        await assertShadowMatches(library, "fixture")
        let expected = try artists(library).map { expectedArtist($0, in: library) }
        let ada = try XCTUnwrap(expected.first)
        XCTAssertTrue(ada.categories.contains { $0.hasSuffix("=live") }, "the fixture has a live album")
        XCTAssertTrue(ada.categories.contains { $0.hasSuffix("=singleEP") }, "and a single")
        XCTAssertFalse(expected[2].appearsOn.isEmpty || expected[2].releases.isEmpty, "Solo 1 releases and appears on")
        XCTAssertFalse(expected[3].releases.isEmpty, "Various Artists releases")
        // 专辑页:歌、艺人链接、封面借的那首。
        let albums = library.visibleAlbums.filter { ["Duets", "Hits Collection", "Blue Room", "Ada Live"].contains($0.title) }
        XCTAssertEqual(albums.count, 4)
        let albumSongs = albums.map { library.songs(forAlbum: $0.id).map(\.id) }
        let links = albums.map { library.linkedArtists(for: $0).map(\.id) }
        let covers = albums.map { library.preferredArtworkSong(forAlbumID: $0.id)?.id }

        let before = try await releaseForReal(library)
        for artist in expected { try await assertCatalogArtist(artist, in: library, "released") }
        XCTAssertEqual(albums.map { library.songs(forAlbum: $0.id).map(\.id) }, albumSongs, "released: album songs")
        XCTAssertEqual(albums.map { library.linkedArtists(for: $0).map(\.id) }, links, "released: artist links")
        var catalogCovers: [String?] = []
        for album in albums {
            catalogCovers.append(await ArtworkSongCatalogMemo.shared.preferredSong(for: .album(album.id), library: library)?.id)
        }
        XCTAssertEqual(catalogCovers, covers, "released: the song the cover (and the page tint) comes from")
        assertNoLoadAndNoArrayRead(library, since: before, "released")
    }

    func testArtistShelvesAfterALaunchThatDidNotLoadTheSongModel() async throws {
        let wait = MusicLibrary.unloadedLaunchCatalogWait
        MusicLibrary.unloadedLaunchCatalogWait = .seconds(10)
        defer { MusicLibrary.unloadedLaunchCatalogWait = wait }
        let (source, storage) = try await launchFixture("detail-unloaded", songs: Self.detailFixture(prefix: "detail-unloaded"))
        let expected = try artists(source).map { expectedArtist($0, in: source) }
        let library = await launch(try copyOfDirectory(storage, "detail-unloaded-launch"), unloaded: true)
        try await waitUntilUsable(library)
        try await waitUntil("catalog readable") { library.readableCatalogReader != nil }
        let stats = library.songModelResidencyStatistics
        XCTAssertEqual(stats.loads, 0)
        // 只当过专辑艺人的人歌从专辑取(核心那一支还没改):他的两排专辑与歌无关,照样相同。
        for artist in expected { try await assertCatalogArtist(artist, in: library, "unloaded launch") }
        assertNoLoadAndNoArrayRead(library, since: stats, "unloaded launch")
    }
}
