import Testing
@testable import PrimuseKit

@Suite("CUE scrape identity")
struct ScrapeCueIdentityPolicyTests {
    @Test("Forced file metadata cannot collapse CUE segment identity")
    func preservesCueIdentity() {
        #expect(ScrapeCueIdentityPolicy.resolvedTitle(
            original: "CUE Segment 440 Hz",
            scraped: "21-CUE-PCM",
            isCueTrack: true
        ) == "CUE Segment 440 Hz")
        #expect(ScrapeCueIdentityPolicy.resolvedOptionalText(
            original: "Codex QA CUE Artist",
            scraped: "Unknown Artist",
            isCueTrack: true
        ) == "Codex QA CUE Artist")
        #expect(ScrapeCueIdentityPolicy.resolvedOptionalText(
            original: "Codex QA CUE Album",
            scraped: "21-CUE-PCM",
            isCueTrack: true
        ) == "Codex QA CUE Album")
    }

    @Test("Ordinary tracks still accept scraped identity")
    func ordinaryTracksUseScrapedIdentity() {
        #expect(ScrapeCueIdentityPolicy.resolvedTitle(
            original: "track-01",
            scraped: "Correct Title",
            isCueTrack: false
        ) == "Correct Title")
        #expect(ScrapeCueIdentityPolicy.resolvedOptionalText(
            original: "Unknown Artist",
            scraped: "Correct Artist",
            isCueTrack: false
        ) == "Correct Artist")
    }

    @Test("Missing CUE optional fields may still be filled")
    func fillsMissingCueFields() {
        #expect(ScrapeCueIdentityPolicy.resolvedOptionalText(
            original: nil,
            scraped: "Recovered Album",
            isCueTrack: true
        ) == "Recovered Album")
    }
}

@Suite("CUE album grouping during scrape")
struct ScrapeCueAlbumGroupingTests {
    private typealias Fields = ScrapedMetadataMergePolicy.Fields

    @Test("Album scrape cannot fill grouping fields the sheet left empty")
    func sheetWithoutPerformerStaysOneAlbum() {
        let original = Fields(title: "Track 3", albumTitle: "Live 1999", trackNumber: 3)
        let merged = Fields(
            title: "Some Song", artist: "Online Artist", albumTitle: "Greatest Hits",
            albumArtist: "Various Artists", year: 2004, genre: "Pop", trackNumber: 9, discNumber: 2
        )
        let result = ScrapeCueIdentityPolicy.protectingCueIdentity(merged, original: original)
        #expect(result.title == "Track 3")
        #expect(result.artist == nil)
        #expect(result.albumTitle == "Live 1999")
        #expect(result.albumArtist == nil)
        #expect(result.trackNumber == 3)
        #expect(result.discNumber == nil)
        // 不影响归属的字段照常补。
        #expect(result.year == 2004)
        #expect(result.genre == "Pop")
    }

    @Test("A sheet-level album artist lets a missing track artist be filled")
    func artistFillsWhenAlbumArtistAnchorsGrouping() {
        let original = Fields(title: "One", albumTitle: "Album", albumArtist: "Band", trackNumber: 1)
        let merged = Fields(title: "One", artist: "Guest", albumTitle: "Album", albumArtist: "Band")
        let result = ScrapeCueIdentityPolicy.protectingCueIdentity(merged, original: original)
        #expect(result.artist == "Guest")
        #expect(result.albumArtist == "Band")
    }

    @Test("Overwrite mode keeps the sheet's album artist and disc")
    func overwriteKeepsSheetGrouping() {
        let original = Fields(
            title: "One", artist: "Band", sourceArtistNames: ["Band"], albumTitle: "Album",
            albumArtist: "Band", trackNumber: 1, discNumber: 1
        )
        let merged = Fields(
            title: "One (Remaster)", artist: "Band feat. X", albumTitle: "Best Of",
            albumArtist: "Band & Friends", trackNumber: 12, discNumber: 2
        )
        let result = ScrapeCueIdentityPolicy.protectingCueIdentity(merged, original: original)
        #expect(result.title == "One")
        #expect(result.artist == "Band")
        #expect(result.sourceArtistNames == ["Band"])
        #expect(result.albumTitle == "Album")
        #expect(result.albumArtist == "Band")
        #expect(result.trackNumber == 1)
        #expect(result.discNumber == 1)
    }

    @Test("Manual match may retitle a track without moving it out of the album")
    func manualMatchKeepsGroupingOnly() {
        let original = Fields(title: "Track 2", artist: "Solo", albumTitle: "Album", albumArtist: "Solo")
        let proposed = Fields(title: "Real Name", artist: "Solo", albumTitle: "Other", albumArtist: "Someone")
        let result = ScrapeCueIdentityPolicy.protectingCueAlbumGrouping(proposed, original: original)
        #expect(result.title == "Real Name")
        #expect(result.albumTitle == "Album")
        #expect(result.albumArtist == "Solo")
    }

    @Test("A track artist that is also the album fallback is not swapped")
    func fallbackArtistIsPartOfGrouping() {
        let original = Fields(title: "Two", artist: "Solo", albumTitle: "Album")
        let proposed = Fields(title: "Two", artist: "Somebody Else", albumTitle: "Album")
        let result = ScrapeCueIdentityPolicy.protectingCueAlbumGrouping(proposed, original: original)
        #expect(result.artist == "Solo")
    }
}

@Suite("CUE album grouping after picking tag fields")
struct ScrapeCueAppliedFieldsTests {
    private typealias Fields = ScrapedMetadataMergePolicy.Fields

    @Test("Ticking the artist keeps a CUE track in its album")
    func artistTickDoesNotDragAlbumArtist() {
        // 整张的 PERFORMER 也是每一轨的艺术家:专辑艺术家看起来像跟着艺术家的回退值。
        let current = Fields(title: "One", artist: "Band", albumTitle: "Live", albumArtist: "Band", trackNumber: 1)
        let proposed = Fields(title: "One", artist: "Band feat. Guest", albumTitle: "Live", albumArtist: "Band")
        let applied = current.applying(proposed, fields: [.artist])
        #expect(applied.albumArtist == "Band feat. Guest")
        let protected = ScrapeCueIdentityPolicy.protectingCueAlbumGrouping(applied, original: current)
        #expect(protected.artist == "Band feat. Guest")
        #expect(protected.albumArtist == "Band")
        #expect(protected.albumTitle == "Live")
    }
}
