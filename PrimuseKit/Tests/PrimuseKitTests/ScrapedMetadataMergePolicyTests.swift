import Foundation
import Testing
@testable import PrimuseKit

@Suite("Scraped metadata merge policy")
struct ScrapedMetadataMergePolicyTests {
    private typealias Policy = ScrapedMetadataMergePolicy

    @Test("Fill-only keeps known values and fills gaps")
    func fillOnlyKeepsKnownValues() {
        let merged = Policy.merged(
            Policy.Fields(title: "Known", artist: "Artist", albumTitle: nil, year: nil, genre: "Rock"),
            with: Policy.Candidate(
                title: "Provider Title",
                artist: "Provider Artist",
                album: "Provider Album",
                year: 1999,
                genres: ["Pop"],
                trackNumber: 3,
                discNumber: 1
            ),
            overwrite: false
        )
        #expect(merged.title == "Known")
        #expect(merged.artist == "Artist")
        #expect(merged.albumTitle == "Provider Album")
        #expect(merged.year == 1999)
        #expect(merged.genre == "Rock")
        #expect(merged.trackNumber == 3)
        #expect(merged.discNumber == 1)
    }

    @Test("Overwrite replaces known values but never with empty provider text")
    func overwriteReplacesKnownValues() {
        let merged = Policy.merged(
            Policy.Fields(title: "01 - old", artist: "Old", albumTitle: "Old Album", year: 2001),
            with: Policy.Candidate(title: "New", artist: "   ", album: "New Album", year: nil),
            overwrite: true
        )
        #expect(merged.title == "New")
        #expect(merged.artist == "Old")
        #expect(merged.albumTitle == "New Album")
        #expect(merged.year == 2001)
    }

    @Test("A changed artist drops the source's multi-value artist list")
    func changedArtistDropsSourceArtistNames() {
        let fields = Policy.Fields(title: "T", artist: "A", sourceArtistNames: ["A", "B"])
        let changed = Policy.merged(fields, with: Policy.Candidate(title: "T", artist: "C"), overwrite: true)
        #expect(changed.artist == "C")
        #expect(changed.sourceArtistNames == nil)

        let kept = Policy.merged(fields, with: Policy.Candidate(title: "T", artist: "C"), overwrite: false)
        #expect(kept.artist == "A")
        #expect(kept.sourceArtistNames == ["A", "B"])
    }

    @Test("Album artist follows a track-artist fallback but keeps an explicit one")
    func albumArtistFollowsFallbackOnly() {
        let fallback = Policy.merged(
            Policy.Fields(title: "T", artist: "Old", albumArtist: "Old"),
            with: Policy.Candidate(title: "T", artist: "New"),
            overwrite: true
        )
        #expect(fallback.albumArtist == "New")

        let explicit = Policy.merged(
            Policy.Fields(title: "T", artist: "Old", albumArtist: "Various Artists"),
            with: Policy.Candidate(title: "T", artist: "New"),
            overwrite: true
        )
        #expect(explicit.albumArtist == "Various Artists")

        let provided = Policy.merged(
            Policy.Fields(title: "T", artist: "Old", albumArtist: nil),
            with: Policy.Candidate(title: "T", artist: "New", albumArtist: "Band"),
            overwrite: false
        )
        #expect(provided.albumArtist == "Band")
    }

    @Test("Genres are joined from at most three provider values")
    func genresJoinAtMostThree() {
        let merged = Policy.merged(
            Policy.Fields(title: "T"),
            with: Policy.Candidate(title: "T", genres: ["A", "B", "C", "D"]),
            overwrite: false
        )
        #expect(merged.genre == "A, B, C")
    }
}

@Suite("Local metadata override policy")
struct LocalMetadataOverridePolicyTests {
    private typealias Policy = LocalMetadataOverridePolicy
    private typealias Fields = ScrapedMetadataMergePolicy.Fields

    @Test("A newer edit on the incoming row supersedes the local override")
    func newerIncomingEditWins() {
        let local = Date(timeIntervalSince1970: 1_000)
        #expect(Policy.isSuperseded(localEditedAt: local, incomingUserEditedAt: local.addingTimeInterval(1)))
        #expect(!Policy.isSuperseded(localEditedAt: local, incomingUserEditedAt: local))
        #expect(!Policy.isSuperseded(localEditedAt: local, incomingUserEditedAt: nil))
    }

    @Test("A chosen candidate is put back over the incoming row")
    func chosenValuesReplaceIncoming() {
        let replayed = Policy.replayedFields(
            incoming: Fields(title: "file name", artist: "Unknown", albumTitle: "Other", year: 2000),
            local: Fields(title: "Real Title", artist: "Real Artist", albumTitle: "Real Album", year: nil, genre: "Jazz"),
            kind: .chosen
        )
        #expect(replayed.title == "Real Title")
        #expect(replayed.artist == "Real Artist")
        #expect(replayed.albumTitle == "Real Album")
        #expect(replayed.year == 2000)
        #expect(replayed.genre == "Jazz")
    }

    @Test("Filled-in values only fill what the incoming row still lacks")
    func filledMissingOnlyFillsGaps() {
        let replayed = Policy.replayedFields(
            incoming: Fields(title: "Title", artist: "Phone Artist", albumTitle: nil, year: nil),
            local: Fields(title: "Title", artist: "TV Artist", albumTitle: "TV Album", year: 1990),
            kind: .filledMissing
        )
        #expect(replayed.artist == "Phone Artist")
        #expect(replayed.albumTitle == "TV Album")
        #expect(replayed.year == 1990)
    }

    @Test("Assets: chosen ones are restored, filled ones yield to the incoming copy")
    func assetActions() {
        #expect(Policy.assetAction(kind: .chosen, current: .missing) == .restore)
        #expect(Policy.assetAction(kind: .chosen, current: .differs) == .restore)
        #expect(Policy.assetAction(kind: .chosen, current: .matchesLocalCopy) == .keep)
        #expect(Policy.assetAction(kind: .filledMissing, current: .missing) == .restore)
        #expect(Policy.assetAction(kind: .filledMissing, current: .differs) == .yieldToIncoming)
        #expect(Policy.assetAction(kind: .filledMissing, current: .matchesLocalCopy) == .keep)
    }
}

@Suite("Album artwork match policy")
struct AlbumArtworkMatchPolicyTests {
    private typealias Policy = AlbumArtworkMatchPolicy

    @Test("An unrelated first result is rejected")
    func unrelatedTopResultIsRejected() {
        let index = Policy.bestMatchIndex(
            requestedAlbum: "Demo Album 01",
            requestedArtist: "Artist 2",
            candidates: [
                (album: "Nothing Compares 2 U", artist: "Prince"),
                (album: "Sweeney Todd", artist: "Stephen Sondheim"),
                (album: "Album", artist: "Artist"),
            ]
        )
        #expect(index == nil)
    }

    @Test("Edition suffixes still match, and an exact title beats a longer edition")
    func editionSuffixesMatch() {
        #expect(Policy.matchStrength(
            requestedAlbum: "Abbey Road",
            requestedArtist: "The Beatles",
            candidateAlbum: "Abbey Road (Remastered)",
            candidateArtist: "The Beatles"
        ) == .exact)
        #expect(Policy.matchStrength(
            requestedAlbum: "Divide",
            requestedArtist: "Ed Sheeran",
            candidateAlbum: "Divide - Deluxe Edition",
            candidateArtist: "Ed Sheeran"
        ) == .exact)
        let index = Policy.bestMatchIndex(
            requestedAlbum: "Thriller",
            requestedArtist: "Michael Jackson",
            candidates: [
                (album: "Thriller 25 Super Deluxe", artist: "Michael Jackson"),
                (album: "Thriller", artist: "Michael Jackson"),
            ]
        )
        #expect(index == 1)
    }

    @Test("A different artist rejects a same-named album")
    func artistConflictRejects() {
        #expect(Policy.matchStrength(
            requestedAlbum: "Greatest Hits",
            requestedArtist: "Queen",
            candidateAlbum: "Greatest Hits",
            candidateArtist: "ABBA"
        ) == nil)
        #expect(Policy.matchStrength(
            requestedAlbum: "Greatest Hits",
            requestedArtist: "Queen",
            candidateAlbum: "Greatest Hits",
            candidateArtist: "Queen & David Bowie"
        ) == .exact)
    }

    @Test("Without a known artist an album title alone is not enough")
    func unknownArtistIsNotEnough() {
        // 扫描刚开始时专辑名就是目录名,歌手还没读出来。
        #expect(Policy.matchStrength(
            requestedAlbum: "Album 31",
            requestedArtist: nil,
            candidateAlbum: "Album 31",
            candidateArtist: "Meditational State"
        ) == nil)
        #expect(Policy.matchStrength(
            requestedAlbum: "Greatest Hits",
            requestedArtist: "Queen",
            candidateAlbum: "Greatest Hits",
            candidateArtist: nil
        ) == .exact)
    }

    @Test("A prefix-only album match needs a confirmed artist on both sides")
    func prefixMatchNeedsArtist() {
        #expect(Policy.matchStrength(
            requestedAlbum: "Love",
            requestedArtist: nil,
            candidateAlbum: "Love Songs",
            candidateArtist: "Someone"
        ) == nil)
        #expect(Policy.matchStrength(
            requestedAlbum: "Thriller",
            requestedArtist: "Michael Jackson",
            candidateAlbum: "Thriller 25",
            candidateArtist: "Michael Jackson"
        ) == .prefix)
        #expect(Policy.matchStrength(
            requestedAlbum: "Demo Album 01",
            requestedArtist: "Artist 2",
            candidateAlbum: "Demo",
            candidateArtist: "Artist"
        ) == nil)
    }

    @Test("Placeholder and empty names are not searched")
    func placeholdersAreNotSearchable() {
        #expect(Policy.searchableName(nil) == nil)
        #expect(Policy.searchableName("  ") == nil)
        #expect(Policy.searchableName("Unknown Album") == nil)
        #expect(Policy.searchableName("unknown artist") == nil)
        #expect(Policy.searchableName("Unbekannter Künstler", placeholders: ["Unbekannter Künstler"]) == nil)
        #expect(Policy.searchableName(" Blue ") == "Blue")
    }
}
