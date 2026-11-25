import Foundation
import PrimuseKit
import XCTest
@testable import PrimuseTV

/// 电视专辑墙、艺人墙的目录路径(P3):目录可读时墙由目录排、按页物化,先后、分段与找回记住的那一张
/// 都和内存路径(`LibraryAlbumBrowseLayoutBuilder` / `LibraryArtistBrowseLayoutBuilder`)一样。
@MainActor
final class TVCatalogWallTests: XCTestCase {
    func testCatalogWallsMatchTheInMemoryLayouts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TVCatalogWallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaultsName = "TVCatalogWallTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
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
        var songs: [Song] = []
        for index in 0..<300 {
            let artist = artists[index % artists.count]
            let album = titles[(index / 3) % titles.count] + " \(index / 9)"
            songs.append(Song(
                id: "tv-wall-\(index)", title: "Track \(index)", albumTitle: album,
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
}
