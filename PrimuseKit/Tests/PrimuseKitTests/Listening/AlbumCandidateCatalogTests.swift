import Foundation
import Testing
@testable import PrimuseKit

/// 专辑推荐的候选专辑表:在曲库目录上逐首建,与把同一份歌按库内顺序交给数组入口建的相同。
@Suite("Album candidates over the library catalog")
struct AlbumCandidateCatalogTests {
    @Test("Streaming the catalog builds the same candidate index", arguments: [1, 2, 3] as [UInt64])
    func catalogMatchesArrays(seed: UInt64) throws {
        var random = CatalogTestRandom(seed: seed)
        let catalog = try TemporaryCatalog()
        var songs: [Song] = []
        for index in 0..<360 {
            let album = random.chance(92) ? "Album \(random.int(0...40))" : nil
            let artist = random.pick(["Ada", "Ben", "周杰伦", "Carla", "Duo、Trio", "  ", ""])
            var song = Song(
                id: "album-candidate-\(seed)-\(index)",
                title: "Song \(index)",
                albumID: album.map { "id-\($0)" },
                albumTitle: random.chance(95) ? album : "  ",
                artistName: artist,
                albumArtistName: random.chance(25) ? "Various Artists" : nil,
                trackNumber: random.int(1...12),
                duration: random.chance(5) ? 0 : Double(random.int(60...500)),
                fileFormat: random.chance(50) ? .flac : .mp3,
                filePath: random.chance(8) ? "" : "/Music/\(album ?? "x")/\(index).flac",
                sourceID: "src",
                genre: random.pick(["Jazz", "Rock", "Pop", "Classical", "电子", nil]),
                year: random.chance(80) ? random.int(1970...2026) : nil,
                coverArtFileName: random.chance(50) ? "cover.jpg" : nil
            )
            if random.chance(5) { song.cueSheetPath = "/Music/\(album ?? "x")/image.cue" }
            song.dateAdded = Date(timeIntervalSince1970: 1_700_000_000 + Double(random.int(0...10_000_000)))
            songs.append(song)
        }
        try catalog.catalog.apply(upserts: songs)
        var music: [Song] = []
        try catalog.catalog.forEachSong(.visibleMusic) { _, song in
            music.append(song)
            return true
        }
        let fromCatalog = try #require(try AlbumCandidateIndex.build(
            catalog: catalog.catalog, scope: .visibleMusic, libraryGeneration: 5
        ))
        let fromArray = try #require(AlbumCandidateIndex.build(librarySongs: music, libraryGeneration: 5))
        #expect(fromCatalog.candidates == fromArray.candidates)
        #expect(fromCatalog.libraryGeneration == 5)
        #expect(fromCatalog.candidates.count > 5)
        #expect(try AlbumCandidateIndex.build(
            catalog: catalog.catalog, scope: .visibleMusic, libraryGeneration: 5, isCancelled: { true }
        ) == nil)
    }
}
