import Foundation
import Testing
@testable import PrimuseKit

@Suite("Song content metadata")
struct SongContentMetadataTests {
    private func song() -> Song {
        Song(id: "song", title: "Track", fileFormat: .m4a, filePath: "track.m4a", sourceID: "source")
    }

    @Test("Only recognized explicit advisory values show a badge", arguments: [0, 1, 2, 4, 255])
    func advisory(_ value: Int) {
        #expect(SongContentMetadata(iTunesAdvisory: value).isExplicit == [1, 4].contains(value))
    }

    @Test("Legacy rows remain readable and completed tagless reads survive persistence")
    func persistence() throws {
        let legacy = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(song()))
        #expect(legacy.contentMetadata == nil)
        #expect(SongContentMetadata.needsInspection(legacy))
        var inspected = legacy
        inspected.contentMetadata = SongContentMetadata(isFileInspectionComplete: true)
        let restored = try JSONDecoder().decode(Song.self, from: JSONEncoder().encode(inspected))
        #expect(restored == inspected)
        #expect(!SongContentMetadata.needsInspection(restored))
        #expect(SongContentMetadata.needsInspection(legacy))
    }

    @Test("Partial AVFoundation copyright does not suppress the full advisory inspection")
    func partialRead() {
        var value = song()
        value.contentMetadata = SongContentMetadata(copyright: "℗ 2026 Label")
        #expect(SongContentMetadata.needsInspection(value))
        value.contentMetadata = SongContentMetadata(iTunesAdvisory: 4, isFileInspectionComplete: true)
            .fillingMissing(from: value.contentMetadata)
        #expect(value.contentMetadata?.copyright == "℗ 2026 Label")
        #expect(!SongContentMetadata.needsInspection(value))
    }

    @Test("Partial reads preserve prior tags, but a complete tagless reread clears them")
    func partialAndRemovedTags() {
        let old = SongContentMetadata(iTunesAdvisory: 4, copyright: "© Old", isFileInspectionComplete: true)
        let partial = SongContentMetadata(copyright: "© Updated")
        let merged = SongContentMetadata.merging(previous: old, incoming: partial)
        #expect(merged?.iTunesAdvisory == 4)
        #expect(merged?.copyright == "© Updated")
        let removed = SongContentMetadata.merging(
            previous: old, incoming: SongContentMetadata(isFileInspectionComplete: true)
        )
        #expect(removed?.hasValues == false)
        #expect(removed?.isFileInspectionComplete == true)
    }

    @Test("Copyright notices preserve distinct owners and source order")
    func notices() {
        var first = song()
        first.contentMetadata = SongContentMetadata(copyright: "  ℗ 2026 First Label  ")
        var second = first
        second.contentMetadata = SongContentMetadata(copyright: "© 2026 Second Label")
        #expect(SongContentMetadata.copyrightNotices(for: [first, first, song(), second])
            == ["℗ 2026 First Label", "© 2026 Second Label"])
        #expect(first.contentMetadata?.copyright == "℗ 2026 First Label")
    }

    @Test("Stable catalogue refresh preserves tags while replacement drops old tags")
    func refresh() {
        var existing = song()
        existing.revision = "v1"
        existing.contentMetadata = SongContentMetadata(iTunesAdvisory: 4, copyright: "© Label", isFileInspectionComplete: true)
        var incoming = song()
        incoming.revision = "v1"
        #expect(ServerSongCatalogMergePolicy.merged(existing: existing, incoming: incoming).contentMetadata == existing.contentMetadata)
        incoming.revision = "v2"
        #expect(ServerSongCatalogMergePolicy.merged(existing: existing, incoming: incoming).contentMetadata == nil)
    }

    @Test("Tag-only backfill works for complete bare inventory without opening server-only reads")
    func eligibility() {
        let pending = MetadataBackfillEligibilityPolicy.reasons(
            duration: 180, format: .m4a, hasCoverArt: true, artworkGivenUp: false,
            titleChecked: true, restrictToBareRows: true, contentMetadataUnread: true
        )
        #expect(pending == [.contentMetadata])
        let server = MetadataBackfillEligibilityPolicy.reasons(
            duration: 180, format: .m4a, hasCoverArt: true, artworkGivenUp: false,
            titleChecked: true, contentMetadataUnread: true, containerCodecOnly: true
        )
        #expect(server.isEmpty)
    }

    @Test("Embedded chapter counts persist under a short key and older rows decode without one")
    func chapterCountPersistence() throws {
        var value = song()
        value.contentMetadata = SongContentMetadata(isFileInspectionComplete: true, embeddedChapterCount: 24)
        let encoded = try JSONEncoder().encode(value)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"chapters\":24"))
        #expect(try JSONDecoder().decode(Song.self, from: encoded).contentMetadata?.embeddedChapterCount == 24)
        let legacy = try JSONDecoder().decode(
            SongContentMetadata.self,
            from: Data(#"{"isFileInspectionComplete":true,"copyright":"© Label"}"#.utf8)
        )
        #expect(legacy.embeddedChapterCount == nil)
        #expect(legacy.copyright == "© Label")
    }

    @Test("A partial read keeps the chapter count; a complete reread replaces it")
    func chapterCountMerging() {
        let counted = SongContentMetadata(isFileInspectionComplete: true, embeddedChapterCount: 12)
        let partial = SongContentMetadata(copyright: "© Label")
        #expect(SongContentMetadata.merging(previous: counted, incoming: partial)?.embeddedChapterCount == 12)
        let reread = SongContentMetadata(isFileInspectionComplete: true, embeddedChapterCount: 0)
        #expect(SongContentMetadata.merging(previous: counted, incoming: reread)?.embeddedChapterCount == 0)
        #expect(SongContentMetadata(embeddedChapterCount: -3).embeddedChapterCount == 0)
    }

    @Test("Books read before chapters were counted are read once more; short music is not")
    func chapterCountReinspection() {
        let readBeforeCounting = SongContentMetadata(isFileInspectionComplete: true)
        var book = Song(id: "book", title: "Book", duration: 3 * 3600, fileFormat: .m4a,
                        filePath: "books/Book.m4a", sourceID: "source")
        book.contentMetadata = readBeforeCounting
        #expect(SongContentMetadata.needsInspection(book))
        book.contentMetadata = SongContentMetadata(isFileInspectionComplete: true, embeddedChapterCount: 0)
        #expect(!SongContentMetadata.needsInspection(book))

        var shortPart = Song(id: "part", title: "Part", duration: 600, fileFormat: .m4a,
                             filePath: "books/Part 01.M4B", sourceID: "source")
        shortPart.contentMetadata = readBeforeCounting
        #expect(SongContentMetadata.needsInspection(shortPart))

        var music = song()
        music.duration = 240
        music.contentMetadata = readBeforeCounting
        #expect(!SongContentMetadata.needsInspection(music))

        var longMP3 = Song(id: "mp3", title: "Book", duration: 3 * 3600, fileFormat: .mp3,
                           filePath: "books/Book.mp3", sourceID: "source")
        longMP3.contentMetadata = readBeforeCounting
        #expect(!SongContentMetadata.needsInspection(longMP3))
    }

    @Test("The shelf counts a file's embedded chapters, and one chapter for a file without them")
    func chapterTally() {
        func item(_ id: String, chapters: Int?) -> Song {
            var song = Song(id: id, title: id, fileFormat: .m4a, filePath: "\(id).m4b", sourceID: "source")
            song.contentMetadata = chapters.map {
                SongContentMetadata(isFileInspectionComplete: true, embeddedChapterCount: $0)
            }
            return song
        }
        #expect(SpokenWordChapterTally.chapters(embeddedChapterCount: nil) == 1)
        #expect(SpokenWordChapterTally.chapters(embeddedChapterCount: 0) == 1)
        #expect(SpokenWordChapterTally.chapters(embeddedChapterCount: 1) == 1)
        #expect(SpokenWordChapterTally.chapters(embeddedChapterCount: 37) == 37)
        let shelf = [item("m4b", chapters: 37), item("part-1", chapters: 0), item("part-2", chapters: nil),
                     item("mp3", chapters: 5)]
        #expect(SpokenWordChapterTally.total(shelf) == 37 + 1 + 1 + 5)
        #expect(SpokenWordChapterTally.total([]) == 0)
    }
}
