import Foundation
import Testing
@testable import PrimuseKit

/// 冻结视图:实时目录随后整库重建分组、增删歌曲,视图里的查询仍是冻结那一刻的样子;写落到实时目录。
@Suite("Frozen catalog views")
struct LibraryCatalogFrozenViewTests {
    private static func songs(count: Int) -> [Song] {
        var rng = CatalogTestRandom(seed: 31)
        var songs = (0..<count).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false) }
        for index in songs.indices where index % 3 == 0 {
            songs[index].genre = rng.pick(["Pop/Rock", "Jazz, Blues", "流行", "Rock"])
        }
        return songs
    }

    @Test("Queries on a frozen view keep the moment it was frozen")
    func frozenViewKeepsItsMoment() throws {
        let temporary = try TemporaryCatalog()
        let live = temporary.catalog
        let original = LibraryGroupingConfiguration(unknownArtist: "Unknown Artist")
        try live.setGroupingConfiguration(original)
        let songs = Self.songs(count: 400)
        try live.apply(upserts: songs)

        let genres = try live.genres()
        let count = try live.songCount(.everything)
        let revision = try live.revision()
        let order = try live.rowList(.everything).rowids
        let frozen = try live.frozenView()
        #expect(frozen.isFrozenView && !live.isFrozenView)
        #expect(frozen.live === live && live.live === live)
        #expect(try !live.groupingRebuildInProgress)

        // 实时目录:换流派分隔符整库重建分组,删掉几首、加几首。
        try live.setGroupingConfiguration(LibraryGroupingConfiguration(
            unknownArtist: "Unknown Artist", genreSeparators: [.slash, .comma]
        ))
        let removed = songs.prefix(25).map(\.id)
        var rng = CatalogTestRandom(seed: 77)
        let added = (0..<30).map { CatalogSongFactory.randomSong(&rng, index: 10_000 + $0, exotic: false) }
        try live.apply(upserts: added, deletingIDs: removed)
        #expect(try live.genres() != genres, "the live catalog regrouped")
        #expect(try live.songCount(.everything) == count - 25 + 30)

        #expect(try frozen.genres() == genres)
        #expect(try frozen.songCount(.everything) == count)
        #expect(try frozen.revision() == revision)
        #expect(try frozen.rowList(.everything).rowids == order)
        #expect(try frozen.song(id: removed[0])?.id == removed[0])
        #expect(try frozen.song(id: added[0].id) == nil)
        #expect(frozen.groupingConfiguration == original, "the view keeps the configuration its tables were built with")

        // 新冻结的视图看到的是此刻的实时目录。
        let refrozen = try live.frozenView()
        #expect(try refrozen.genres() == live.genres())
        #expect(try refrozen.songCount(.everything) == count - 25 + 30)
    }

    @Test("A grouping rebuild left half-done is reported as in progress")
    func interruptedRebuildIsInProgress() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        try catalog.setGroupingConfiguration(LibraryGroupingConfiguration(unknownArtist: "Unknown Artist"))
        try catalog.apply(upserts: Self.songs(count: 120))
        #expect(throws: LibraryCatalogError.self) {
            try catalog.setGroupingConfiguration(
                LibraryGroupingConfiguration(unknownArtist: "Unknown Artist", genreSeparators: [.slash]),
                isCancelled: { true }
            )
        }
        #expect(try catalog.groupingRebuildInProgress)
        try catalog.rebuildGrouping()
        #expect(try !catalog.groupingRebuildInProgress)
        #expect(try !catalog.groupingNeedsRebuild)
    }
}
