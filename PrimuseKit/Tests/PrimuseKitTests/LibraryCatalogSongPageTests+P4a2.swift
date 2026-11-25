import Foundation
import Testing
@testable import PrimuseKit

@Suite("Library catalog song pages")
struct LibraryCatalogSongPageTests {
    @Test("Pages walk the same rows in the same order as the streaming visit, per scope")
    func pagesMatchStreaming() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = try LibraryCatalog(path: directory.appendingPathComponent("c.sqlite").path)
        var rng = CatalogTestRandom(seed: 5_301)
        let songs = (0..<1_234).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false).withoutAppliedPlaybackRange }
        try catalog.apply(upserts: songs)
        try catalog.apply(upserts: [], deletingIDs: songs.enumerated().filter { $0.offset % 7 == 0 }.map(\.element.id))
        try catalog.setSourceEnabled(false, sourceID: "src-nas")

        for scope in [LibrarySongScope.everything, .visible, .source("src-smb"), LibrarySongScope(kinds: [.music])] {
            var streamed: [(Int32, String)] = []
            try catalog.forEachSong(scope) { rowid, song in
                streamed.append((rowid, song.id))
                return true
            }
            var paged: [(Int32, String)] = []
            var cursor: Int32 = 0
            while true {
                let page = try catalog.songPage(scope, after: cursor, limit: 97)
                #expect(page.count <= 97)
                paged += page.map { ($0.rowid, $0.song.id) }
                guard let last = page.last else { break }
                cursor = last.rowid
            }
            #expect(paged.map(\.0) == streamed.map(\.0))
            #expect(paged.map(\.1) == streamed.map(\.1))
        }
        #expect(try catalog.songPage(.everything, limit: 0).isEmpty)
        #expect(try catalog.songPage(.everything, limit: 1_000_000).count == min(LibraryScale.maxMaterializedRows, 1_234 - 1_234 / 7 - 1))
    }
}
