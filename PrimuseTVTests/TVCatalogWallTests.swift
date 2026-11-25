import Foundation
import PrimuseKit
import XCTest
@testable import PrimuseTV

/// 电视专辑墙、艺人墙的目录路径(P3):目录可读时墙由目录排、按页物化,先后、分段与找回记住的那一张
/// 都和内存路径(`LibraryAlbumBrowseLayoutBuilder` / `LibraryArtistBrowseLayoutBuilder`)一样。
@MainActor
final class TVCatalogWallTests: XCTestCase {
    private struct Fixture {
        let library: MusicLibrary
        let store: TVStore
        let cleanup: () -> Void
    }

    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TVCatalogWallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaultsName = "TVCatalogWallTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let sources = SourcesStore(storageDirectoryURL: directory)
        let source = MusicSource(id: "tv-wall-source", name: "Fixture", type: .local)
        try sources.addDurably(source)
        let library = MusicLibrary(
            storageDirectory: directory,
            artistNameConfiguration: .defaultValue,
            deferredMaintenanceAllowed: { true },
            catalogMirroring: .enabled(startDelay: .zero)
        )
        let artists = ["周杰伦", "Beyond", "beyond", "陈奕迅", "Ólafur Arnalds", "", "AC/DC", "王菲"]
        let titles = ["晴天", "Love", "北京", "Zebra", "七里香", "apple", "10", "Ångström", "夜曲"]
        let songTitles = ["晴天", "love", "Love", "", "北京", "zebra", "七里香", "Apple", "10 Days", "Ångström", "夜曲"]
        var songs: [Song] = []
        for index in 0..<300 {
            let artist = artists[index % artists.count]
            let album = titles[(index / 3) % titles.count] + " \(index / 9)"
            // 歌名有完全相同的(不同艺人)、只差大小写的、空的,看「歌曲」页的分段与先后。
            let title = songTitles[index % songTitles.count] + (index % 4 == 0 ? "" : " \(index % 5)")
            songs.append(Song(
                id: "tv-wall-\(index)", title: title, albumTitle: album,
                artistName: artist.isEmpty ? nil : artist, albumArtistName: artist.isEmpty ? nil : artist,
                trackNumber: index % 12 + 1, duration: 180, fileFormat: .flac,
                filePath: "/Music/\(artist)/\(album)/\(index).flac", sourceID: source.id,
                year: [nil, 1987, 2005, 2027, 87][index % 5]
            ))
        }
        library.addSongs(songs, affectedSourceIDs: [source.id])
        await library.waitForPendingIndex()
        await library.waitForCatalogMirror()
        XCTAssertEqual(library.catalogHost?.revisions.isReadable, true)

        let store = TVStore(
            sourcesStore: sources, library: library, defaults: defaults,
            sessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        )
        return Fixture(library: library, store: store) {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testCatalogWallsMatchTheInMemoryLayouts() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let library = fixture.library
        let store = fixture.store
        let unknown = String(localized: "unknown_artist")
        for order in [LibraryAlbumBrowseOrder.artist, .title, .year] {
            await store.prepareAlbumBrowseLayout(order)
            let layout = try XCTUnwrap(store.albumBrowseLayout(order), "\(order)")
            XCTAssertTrue(layout.items.source.isEmpty, "\(order): the wall is served from the catalog")
            let expected = LibraryAlbumBrowseLayoutBuilder.layout(
                albums: library.visibleAlbums, order: order, unknownArtistName: unknown
            )
            XCTAssertEqual(layout.items.map(\.id), expected.items.map(\.id), "\(order): order")
            XCTAssertEqual(layout.sections, expected.sections, "\(order): sections")
            let remembered = try XCTUnwrap(expected.items.dropFirst(expected.items.count / 2).first)
            let position = expected.items.firstIndex { $0.id == remembered.id }
            XCTAssertEqual(layout.items.index(ofID: remembered.id, near: nil), position, "\(order): remembered card")
            XCTAssertEqual(layout.items.index(ofID: remembered.id, near: position), position)
        }

        await store.prepareArtistBrowseLayout(.allArtists)
        let artistLayout = try XCTUnwrap(store.artistBrowseLayout(.allArtists))
        XCTAssertTrue(artistLayout.items.source.isEmpty, "the artist wall is served from the catalog")
        let expectedArtists = LibraryArtistBrowseLayoutBuilder.layout(
            artists: library.visibleArtists, unknownArtistName: unknown
        )
        XCTAssertEqual(artistLayout.items.map(\.id), expectedArtists.items.map(\.id))
        XCTAssertEqual(artistLayout.sections, expectedArtists.sections)
        await library.stopCatalogMirror()
    }

    /// 「歌曲」页的目录路径:同一批歌、同样按标题读音的先后与分段(读音相同的几首之间目录按标题的
    /// 本地化先后、再按行号,同手机歌曲页);记住的那首找得回来;点歌时的队列就是整页的先后。
    func testCatalogSongsPageMatchesTheInMemoryLayout() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanup() }
        let library = fixture.library
        let store = fixture.store

        await store.prepareSongBrowseLayout()
        let layout = try XCTUnwrap(store.songBrowseLayout())
        XCTAssertNotNil(layout.items.catalog, "the songs page is served from the catalog")
        XCTAssertTrue(layout.items.source.isEmpty)
        let expected = LibrarySongBrowseLayoutBuilder.layout(songs: library.musicSongs)
        let ids = Array(layout.items)
        XCTAssertEqual(ids.count, expected.items.count)
        XCTAssertEqual(Set(ids), Set(expected.items))
        XCTAssertEqual(layout.sections, expected.sections)
        let titleByID = Dictionary(uniqueKeysWithValues: library.musicSongs.map { ($0.id, $0.title) })
        func keys(_ ids: [String]) -> [LibraryCollationPolicy.Key] {
            ids.map { LibraryCollationPolicy.songTitleKey(for: titleByID[$0] ?? "") }
        }
        XCTAssertEqual(keys(ids), keys(expected.items), "same reading-key order")

        let remembered = expected.items[expected.items.count / 2]
        let position = try XCTUnwrap(layout.items.index(ofID: remembered, near: nil))
        XCTAssertEqual(layout.items[position], remembered)
        XCTAssertEqual(layout.items.index(ofID: remembered, near: position), position)
        XCTAssertNil(layout.items.index(ofID: "not-a-song", near: nil))

        let queue = await store.catalogSongsPageQueue()
        XCTAssertEqual(queue, ids, "tapping a song queues the whole page in its order")
        await library.stopCatalogMirror()
    }
}
