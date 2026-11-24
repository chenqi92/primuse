import Foundation
import Testing
@testable import PrimuseKit

/// 目录上的专辑墙、艺人墙排序与分段和内存里的布局构建器逐项一致(随机曲库,含停用的源)。
@Suite("Library catalog browse orders", .serialized)
struct LibraryCatalogBrowseOrderTests {
    static let unknownArtist = "Unknown Artist"
    static let currentYear = 2026

    static func makeCatalog(seed: UInt64, count: Int, disabled: Set<String>) throws -> TemporaryCatalog {
        let temporary = try TemporaryCatalog()
        try temporary.catalog.setGroupingConfiguration(LibraryGroupingConfiguration(unknownArtist: unknownArtist))
        var rng = CatalogTestRandom(seed: seed)
        var songs = (0..<count).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false) }
        // 年份覆盖排序的几种情形:没有、两位数、远古、未来、像样的。
        for index in songs.indices where index % 5 == 0 {
            songs[index].year = rng.pick([nil, 0, 87, 999, 1000, 1959, 1987, 2026, 2027, 2028, 30000])
        }
        try temporary.catalog.apply(upserts: songs)
        for sourceID in disabled.sorted() { try temporary.catalog.setSourceEnabled(false, sourceID: sourceID) }
        return temporary
    }

    @Test("Album wall orders and sections match LibraryAlbumBrowseLayoutBuilder", arguments: [UInt64(1), 7, 42])
    func albumOrders(seed: UInt64) throws {
        for disabled in [Set<String>(), ["src-nas", "src-webdav"]] {
            let temporary = try Self.makeCatalog(seed: seed, count: 600, disabled: disabled)
            let catalog = temporary.catalog
            for visibleOnly in [true, false] {
                let albums = try catalog.albums(keys: catalog.albumKeys(visibleOnly: visibleOnly).keys, visibleCounts: visibleOnly)
                #expect(albums.count > 20, "seed \(seed): the fixture needs a real album wall")
                for order in [LibraryAlbumBrowseOrder.artist, .title, .year] {
                    let expected = LibraryAlbumBrowseLayoutBuilder.layout(
                        albums: albums, order: order, unknownArtistName: Self.unknownArtist, currentYear: Self.currentYear
                    )
                    let actual = try #require(try catalog.albumBrowseKeys(
                        order: order, unknownArtistName: Self.unknownArtist, currentYear: Self.currentYear,
                        visibleOnly: visibleOnly
                    ))
                    let actualIDs = try catalog.albums(keys: actual.keys, visibleCounts: visibleOnly).map(\.id)
                    let context = "seed \(seed) disabled \(disabled.sorted()) visibleOnly \(visibleOnly) order \(order)"
                    #expect(actualIDs == expected.items.map(\.id), "\(context): order")
                    #expect(actual.sections == expected.sections, "\(context): sections")
                }
            }
        }
    }

    @Test("Artist wall order and sections match LibraryArtistBrowseLayoutBuilder", arguments: [UInt64(3), 11, 99])
    func artistOrder(seed: UInt64) throws {
        for disabled in [Set<String>(), ["src-smb"]] {
            let temporary = try Self.makeCatalog(seed: seed, count: 600, disabled: disabled)
            let catalog = temporary.catalog
            for visibleOnly in [true, false] {
                let artists = try catalog.artists(keys: catalog.artistKeys(visibleOnly: visibleOnly).keys, visibleCounts: visibleOnly)
                #expect(artists.count > 5)
                let expected = LibraryArtistBrowseLayoutBuilder.layout(artists: artists, unknownArtistName: Self.unknownArtist)
                let actual = try catalog.artistBrowseKeys(unknownArtistName: Self.unknownArtist, visibleOnly: visibleOnly)
                let actualIDs = try catalog.artists(keys: actual.keys, visibleCounts: visibleOnly).map(\.id)
                let context = "seed \(seed) disabled \(disabled.sorted()) visibleOnly \(visibleOnly)"
                #expect(actualIDs == expected.items.map(\.id), "\(context): order")
                #expect(actual.sections == expected.sections, "\(context): sections")
            }
        }
    }

    @Test("Genre representative songs match LibraryGenreIndexBuilder", arguments: [UInt64(2), 13, 77])
    func genreRepresentatives(seed: UInt64) throws {
        for separators in [GenreSeparatorOptions(), [.slash, .comma]] {
            let temporary = try TemporaryCatalog()
            let catalog = temporary.catalog
            try catalog.setGroupingConfiguration(LibraryGroupingConfiguration(
                unknownArtist: Self.unknownArtist, genreSeparators: separators
            ))
            var rng = CatalogTestRandom(seed: seed)
            var songs = (0..<500).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false) }
            // 同一流派里有封面、没封面、年份相同、没有专辑的都要有。
            for index in songs.indices where index % 3 == 0 {
                songs[index].genre = rng.pick(["Rock", "Jazz; Blues", "Pop/Rock", "流行"])
                songs[index].coverArtFileName = rng.chance(50) ? "cover-\(index % 7).jpg" : nil
                songs[index].year = rng.pick([nil, 1999, 2005, 2005])
                if rng.chance(20) { songs[index].albumID = rng.chance(50) ? nil : "  " }
            }
            try catalog.apply(upserts: songs)
            try catalog.setSourceEnabled(false, sourceID: "src-webdav")
            let music = try catalog.songs(rowids: catalog.rowList(.visibleMusic).rowids)
            let expected = LibraryGenreIndexBuilder.build(from: music, alsoSplitting: separators).genres
            let actual = try catalog.genreRepresentativeSongIDs()
            #expect(expected.count > 3, "seed \(seed): the fixture needs several genres")
            for genre in expected {
                #expect(actual[genre.id] ?? [] == genre.representativeSongIDs,
                        "seed \(seed) separators \(separators.rawValue) genre \(genre.id)")
            }
            #expect(Set(actual.keys) == Set(expected.map(\.id)))
            let subset = Set(expected.prefix(2).map(\.id))
            #expect(try catalog.genreRepresentativeSongIDs(genreIDs: subset).keys.sorted() == subset.sorted())
        }
    }

    @Test("Orders the catalog does not sort here return nil")
    func unsupportedOrders() throws {
        let temporary = try Self.makeCatalog(seed: 5, count: 40, disabled: [])
        for order in [LibraryAlbumBrowseOrder.recentlyAdded, .liked] {
            #expect(try temporary.catalog.albumBrowseKeys(
                order: order, unknownArtistName: Self.unknownArtist, currentYear: Self.currentYear
            ) == nil)
        }
    }
}
