import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple Music catalog continuation")
struct AppleMusicCatalogContinuationPolicyTests {
    private typealias Policy = AppleMusicCatalogContinuationPolicy
    private typealias Candidate = AppleMusicCatalogContinuationPolicy.Candidate

    @Test("Song keys ignore case, width, accents and version notes")
    func songKeysIgnoreDecoration() {
        #expect(Policy.songKey(title: "Café (Remastered 2011)", artist: "BEYONCÉ")
            == Policy.songKey(title: "cafe", artist: "Beyonce"))
        #expect(Policy.titleKey("晴天（Live）") == Policy.titleKey("晴天"))
        #expect(Policy.titleKey("【MV】夜曲") == Policy.titleKey("夜曲"))
    }

    @Test("A title made only of brackets keeps its text")
    func bracketOnlyTitleKeepsText() {
        #expect(Policy.titleKey("(Intro)") == "intro")
    }

    @Test("A Last.fm track matches the catalog result with the same title and artist")
    func matchesTitleAndArtist() {
        let results = [
            Candidate(id: "1", title: "Hello", artist: "Lionel Richie"),
            Candidate(id: "2", title: "Hello", artist: "Adele"),
        ]
        #expect(Policy.matchIndex(title: "Hello", artist: "Adele", in: results) == 1)
    }

    @Test("A featured or joint credit still matches the lead artist")
    func jointCreditMatches() {
        let results = [Candidate(id: "1", title: "Shallow", artist: "Lady Gaga & Bradley Cooper")]
        #expect(Policy.matchIndex(title: "Shallow", artist: "Lady Gaga", in: results) == 0)
    }

    @Test("A result by another artist is never taken as the match")
    func otherArtistDoesNotMatch() {
        let results = [Candidate(id: "1", title: "Hello", artist: "Lionel Richie")]
        #expect(Policy.matchIndex(title: "Hello", artist: "Adele", in: results) == nil)
    }

    @Test("A different title is never taken as the match")
    func otherTitleDoesNotMatch() {
        let results = [Candidate(id: "1", title: "Someone Like You", artist: "Adele")]
        #expect(Policy.matchIndex(title: "Hello", artist: "Adele", in: results) == nil)
    }

    @Test("Last.fm matches come first, then artists' top songs in turns")
    func similarTracksThenRoundRobin() {
        let picked = Policy.assemble(
            similarTracks: [Candidate(id: "s1", title: "One", artist: "X")],
            artistTopSongs: [
                [Candidate(id: "a1", title: "A1", artist: "A"), Candidate(id: "a2", title: "A2", artist: "A")],
                [Candidate(id: "b1", title: "B1", artist: "B")],
            ],
            isExcluded: { _ in false }
        )
        #expect(picked.map(\.id) == ["s1", "a1", "b1", "a2"])
    }

    @Test("Excluded songs and repeats of the same song are skipped")
    func skipsExcludedAndRepeats() {
        let picked = Policy.assemble(
            similarTracks: [
                Candidate(id: "s1", title: "One", artist: "X"),
                Candidate(id: "s2", title: "One (Live)", artist: "x"),
                Candidate(id: "s3", title: "Two", artist: "Y"),
            ],
            artistTopSongs: [[Candidate(id: "s3", title: "Two", artist: "Y")]],
            isExcluded: { $0.id == "s1" }
        )
        // s2 is another version of the excluded s1; s3 appears twice and is kept once.
        #expect(picked.map(\.id) == ["s3"])
    }

    @Test("One artist never fills more than the per-artist limit")
    func perArtistLimit() {
        let songs = (1...6).map { Candidate(id: "a\($0)", title: "A\($0)", artist: "A") }
        let picked = Policy.assemble(
            similarTracks: songs,
            artistTopSongs: [],
            isExcluded: { _ in false },
            perArtistLimit: 3
        )
        #expect(picked.count == 3)
    }

    @Test("A batch stops at its limit")
    func stopsAtLimit() {
        let lists = (0..<5).map { artist in
            (0..<5).map { Candidate(id: "\(artist)-\($0)", title: "T\(artist)\($0)", artist: "Artist \(artist)") }
        }
        let picked = Policy.assemble(similarTracks: [], artistTopSongs: lists, isExcluded: { _ in false }, limit: 7)
        #expect(picked.count == 7)
        #expect(picked.prefix(5).map(\.id) == ["0-0", "1-0", "2-0", "3-0", "4-0"])
    }
}
