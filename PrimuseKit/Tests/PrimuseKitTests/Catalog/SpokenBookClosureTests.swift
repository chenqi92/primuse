import Foundation
import Testing
@testable import PrimuseKit

/// 只取几首歌所在的连通块再分书,得到的书与对整个书架分书得到的那几本相同(小组件只要有进度的书)。
@Suite("Spoken-word book closures on the catalog")
struct SpokenBookClosureTests {
    @Test("Grouping a closure gives the same books as grouping the whole shelf", arguments: [3, 11, 29] as [UInt64])
    func closureMatchesWholeShelf(seed: UInt64) throws {
        var rng = CatalogTestRandom(seed: seed)
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        let configuration = LibraryGroupingConfiguration(unknownArtist: LibraryGroupingDifferentialTests.unknownArtist)
        try catalog.setGroupingConfiguration(configuration)
        let songs = (0..<500).map {
            LibraryGroupingDifferentialTests.makeSong(&rng, serial: $0, configuration: configuration)
        }
        try catalog.apply(upserts: songs)

        var shelfSongs: [Song] = []
        try catalog.forEachSong(LibrarySongScope(kinds: [.spokenWord])) { _, song in
            shelfSongs.append(song)
            return true
        }
        #expect(shelfSongs.count > 20, "the generator makes enough spoken-word items")
        let wholeShelf = SpokenWordBookGrouping.books(from: shelfSongs.map { SpokenWordBookItem(song: $0) })
        let bookByItemID = Dictionary(
            wholeShelf.flatMap { book in book.items.map { ($0.id, book) } }, uniquingKeysWith: { first, _ in first }
        )

        for round in 0..<8 {
            let seeds = Set(shelfSongs.filter { _ in rng.chance(round == 0 ? 2 : 8) }.map(\.id))
                .union(round == 7 ? ["not-in-the-library", songs[0].id] : [])
            let closure = try catalog.spokenBookClosureSongs(containingSongIDs: seeds)
            let shelfIDs = Set(shelfSongs.map(\.id))
            #expect(closure.allSatisfy { shelfIDs.contains($0.id) }, "only visible spoken-word items")
            let order = Dictionary(uniqueKeysWithValues: shelfSongs.enumerated().map { ($1.id, $0) })
            #expect(closure.map { order[$0.id] ?? -1 } == closure.map { order[$0.id] ?? -1 }.sorted(), "library order")
            let closureBooks = SpokenWordBookGrouping.books(from: closure.map { SpokenWordBookItem(song: $0) })
            let closureBookByID = Dictionary(closureBooks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for seed in seeds {
                guard let expected = bookByItemID[seed] else { continue }
                #expect(closureBookByID[expected.id] == expected, "round \(round): book of \(seed)")
            }
        }
        #expect(try catalog.spokenBookClosureSongs(containingSongIDs: [String]()).isEmpty)
    }
}
