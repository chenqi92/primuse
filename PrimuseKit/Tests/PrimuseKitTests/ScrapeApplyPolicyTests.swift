import Foundation
import Testing
@testable import PrimuseKit

@Suite("Scrape apply scopes and field selection")
struct ScrapeApplyPolicyTests {
    @Test("A lyrics-only scrape keeps every tag, the cover and technical values")
    func lyricsOnlyKeepsTagsAndCover() {
        let original = song()
        var scraped = original
        scraped.title = "Scraped Title"
        scraped.artistName = "Someone Else"
        scraped.year = 1999
        scraped.duration = 300
        scraped.bitRate = 999
        scraped.coverArtFileName = "new-cover.jpg"
        scraped.lyricsFileName = "new-lyrics.json"

        let restricted = ScrapeApplyPolicy.restricted(scraped, to: .lyrics, original: original)
        #expect(restricted.title == original.title)
        #expect(restricted.artistName == original.artistName)
        #expect(restricted.year == original.year)
        #expect(restricted.duration == original.duration)
        #expect(restricted.bitRate == original.bitRate)
        #expect(restricted.coverArtFileName == original.coverArtFileName)
        #expect(restricted.lyricsFileName == "new-lyrics.json")
        #expect(!SongUserMetadataPolicy.editableFieldsChanged(from: original, to: restricted))

        let coverOnly = ScrapeApplyPolicy.restricted(scraped, to: .cover, original: original)
        #expect(coverOnly.coverArtFileName == "new-cover.jpg")
        #expect(coverOnly.lyricsFileName == original.lyricsFileName)
        #expect(coverOnly.title == original.title)

        #expect(ScrapeApplyPolicy.restricted(scraped, to: .all, original: original) == scraped)
    }

    @Test("CUE tracks default to no tag fields; other songs pick every changed one")
    func defaultSelection() {
        let original = fields(title: "01", artist: "A", album: "X", track: 1)
        var proposed = original
        proposed.title = "Song"
        proposed.year = 2001
        proposed.genre = "Rock"

        #expect(ScrapeTagField.defaultSelection(original: original, proposed: proposed, isCueTrack: true).isEmpty)
        #expect(ScrapeTagField.defaultSelection(original: original, proposed: proposed, isCueTrack: false)
            == [.title, .year, .genre])
    }

    @Test("Only checked fields are applied; a fallback album artist follows the new artist")
    func applyingSelectedFields() {
        var original = fields(title: "01", artist: "Old", album: "X", track: 1)
        original.albumArtist = "Old"
        var proposed = original
        proposed.title = "Song"
        proposed.artist = "New"
        proposed.albumArtist = "New"
        proposed.year = 2001
        proposed.trackNumber = 7

        let artistOnly = original.applying(proposed, fields: [.artist])
        #expect(artistOnly.artist == "New")
        #expect(artistOnly.albumArtist == "New")
        #expect(artistOnly.title == "01")
        #expect(artistOnly.trackNumber == 1)

        let yearOnly = original.applying(proposed, fields: [.year])
        #expect(yearOnly.year == 2001)
        #expect(yearOnly.artist == "Old")
        #expect(yearOnly.albumArtist == "Old")

        var compilation = proposed
        compilation.artist = "Old"
        compilation.albumArtist = "Various Artists"
        #expect(ScrapeTagField.album.differs(original, compilation))
        #expect(!ScrapeTagField.artist.differs(original, compilation))
        #expect(original.applying(compilation, fields: [.album]).albumArtist == "Various Artists")
    }

    @Test("Album completion in overwrite mode keeps a CUE track's identity")
    func cueIdentitySurvivesOverwrite() {
        var original = fields(title: "Track 3", artist: "崔健", album: "红旗下的蛋", track: 3)
        original.albumArtist = "崔健"
        original.discNumber = 1
        var merged = original
        merged.title = "红旗下的蛋 (Full Album)"
        merged.artist = "Various"
        merged.albumTitle = "Best Of"
        merged.albumArtist = "Various"
        merged.trackNumber = 1
        merged.discNumber = 2
        merged.year = 1994
        merged.genre = "Rock"

        let protected = ScrapeCueIdentityPolicy.protectingCueIdentity(merged, original: original)
        #expect(protected.title == "Track 3")
        #expect(protected.artist == "崔健")
        #expect(protected.albumTitle == "红旗下的蛋")
        #expect(protected.albumArtist == "崔健")
        #expect(protected.trackNumber == 3)
        #expect(protected.discNumber == 1)
        #expect(protected.year == 1994)
        #expect(protected.genre == "Rock")

        var blank = original
        blank.discNumber = nil
        #expect(ScrapeCueIdentityPolicy.protectingCueIdentity(merged, original: blank).discNumber == 2)
    }

    private func fields(title: String, artist: String, album: String, track: Int) -> ScrapedMetadataMergePolicy.Fields {
        ScrapedMetadataMergePolicy.Fields(title: title, artist: artist, albumTitle: album, trackNumber: track)
    }

    private func song() -> Song {
        Song(
            id: "song",
            title: "01 Track",
            albumTitle: "Album",
            artistName: "Artist",
            trackNumber: 1,
            duration: 180,
            fileFormat: .flac,
            filePath: "/01 Track.flac",
            sourceID: "source",
            bitRate: 900,
            year: 2003,
            coverArtFileName: "old-cover.jpg",
            lyricsFileName: "old.lrc"
        )
    }
}
