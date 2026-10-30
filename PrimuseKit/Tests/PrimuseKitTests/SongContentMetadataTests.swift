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
}
