import Foundation
import Testing
@testable import PrimuseKit

@Suite("Recommendation unit: songs, whole albums or both")
struct AIRecommendationUnitTests {
    private func songs(_ count: Int) -> [AIRecommendationCandidate] {
        (0..<count).map { AIRecommendationCandidate(songID: "s\($0)", title: "Song \($0)", artist: "A\($0)") }
    }

    private func albums(_ count: Int) -> [AIRecommendationAlbumCandidate] {
        (0..<count).map {
            AIRecommendationAlbumCandidate(albumKey: "a\($0)", title: "Album \($0)", artist: "B\($0)", trackCount: 10)
        }
    }

    @Test("Stored unit defaults to mixed")
    func storedUnit() {
        #expect(AIRecommendationUnit.stored(nil) == .mixed)
        #expect(AIRecommendationUnit.stored("bogus") == .mixed)
        #expect(AIRecommendationUnit.stored("songs") == .songs)
        #expect(AIRecommendationUnit.stored("albums") == .albums)
        #expect(AIRecommendationUnit.mixed.albumSlotCount == 2)
        #expect(AIRecommendationUnit.songs.albumSlotCount == 0)
    }

    @Test("A songs request carries no albums and keeps the old limits")
    func songsRequest() {
        let request = AIRecommendationRequest(
            scene: .automatic,
            preferences: [],
            candidates: songs(12),
            albumCandidates: albums(4)
        )
        #expect(request.unit == .songs)
        #expect(request.albumCandidates.isEmpty)
        #expect(request.maximumAlbumResults == 0)
        #expect(request.maximumResults == 12)
        #expect(request.minimumResults == 10)
    }

    @Test("Album candidates are deduplicated and bounded")
    func albumBounds() {
        var candidates = albums(14)
        candidates.insert(candidates[0], at: 1)
        candidates.append(AIRecommendationAlbumCandidate(albumKey: "", title: "x", artist: "y", trackCount: 4))
        let mixed = AIRecommendationRequest(
            scene: .automatic, preferences: [], candidates: songs(12),
            unit: .mixed, albumCandidates: candidates
        )
        #expect(mixed.albumCandidates.count == AIRecommendationRequest.maximumAlbumCandidates)
        #expect(mixed.albumCandidates.map(\.albumKey) == (0..<12).map { "a\($0)" })
        #expect(mixed.maximumAlbumResults == 2)

        let albumsOnly = AIRecommendationRequest(
            scene: .automatic, preferences: [], candidates: songs(3),
            unit: .albums, albumCandidates: albums(3)
        )
        #expect(albumsOnly.maximumAlbumResults == 3)
        let none = AIRecommendationRequest(
            scene: .automatic, preferences: [], candidates: songs(3),
            unit: .mixed, albumCandidates: []
        )
        #expect(none.maximumAlbumResults == 0)
    }

    @Test("Normalizing keeps known albums up to the limit next to the songs")
    func normalizeMixed() {
        let request = AIRecommendationRequest(
            scene: .automatic, preferences: [], candidates: songs(3),
            maximumResults: 3, minimumResults: 2,
            unit: .mixed, albumCandidates: albums(4)
        )
        let plan = AIRecommendationPlan(selections: [
            AIRecommendationSelection(albumKey: "a2", reason: " fits "),
            AIRecommendationSelection(songID: "s1", reason: "song"),
            AIRecommendationSelection(albumKey: "a2", reason: "duplicate"),
            AIRecommendationSelection(albumKey: "missing", reason: "invented"),
            AIRecommendationSelection(albumKey: "a0", reason: "second"),
            AIRecommendationSelection(albumKey: "a1", reason: "over the limit"),
            AIRecommendationSelection(songID: "s0", reason: "song"),
            // A song whose id happens to look like an album key stays a song.
            AIRecommendationSelection(songID: "album:a3", reason: "not a candidate"),
        ]).normalized(for: request)
        #expect(plan.albumSelections.map(\.albumKey) == ["a2", "a0"])
        #expect(plan.albumSelections.first?.reason == "fits")
        #expect(plan.songSelections.map(\.songID) == ["s1", "s0"])
        #expect(!plan.isPartial)
    }

    @Test("A service that predates albums still answers a mixed request with songs")
    func olderServiceAnswer() {
        let request = AIRecommendationRequest(
            scene: .automatic, preferences: [], candidates: songs(4),
            maximumResults: 4, minimumResults: 4,
            unit: .albums, albumCandidates: albums(2)
        )
        let plan = AIRecommendationPlan(selections: songs(4).map {
            AIRecommendationSelection(songID: $0.songID, reason: "r")
        }).normalized(for: request)
        #expect(plan.albumSelections.isEmpty)
        #expect(plan.songSelections.count == 4)
        // Albums-only requests are judged by the service's own flag.
        #expect(!plan.isPartial)
    }

    @Test("Albums are dropped from a songs request")
    func songsRequestDropsAlbums() {
        let request = AIRecommendationRequest(
            scene: .automatic, preferences: [], candidates: songs(2),
            maximumResults: 2, minimumResults: 1
        )
        let plan = AIRecommendationPlan(selections: [
            AIRecommendationSelection(albumKey: "a0", reason: "r"),
            AIRecommendationSelection(songID: "s0", reason: "r"),
        ]).normalized(for: request)
        #expect(plan.selections == [AIRecommendationSelection(songID: "s0", reason: "r")])
    }

    @Test("Selections cached before albums still decode as songs")
    func legacyDecoding() throws {
        let data = Data(#"{"selections":[{"songID":"one","reason":"calm"}],"summary":"x"}"#.utf8)
        let plan = try JSONDecoder().decode(AIRecommendationPlan.self, from: data)
        #expect(plan.selections == [AIRecommendationSelection(songID: "one", reason: "calm")])
        let album = AIRecommendationSelection(albumKey: "k", reason: "r")
        let roundTrip = try JSONDecoder().decode(
            AIRecommendationSelection.self,
            from: JSONEncoder().encode(album)
        )
        #expect(roundTrip == album)
        #expect(album.itemID == "album:k")
        #expect(AIRecommendationSelection(songID: "k", reason: "r").itemID == "k")
    }

    @Test("Mixed puts two album cards first, the service's picks before local ones")
    func composeMixed() {
        let entries = AIRecommendationFeedComposer.compose(
            unit: .mixed,
            intelligentAlbumKeys: ["l3", "gone"],
            localAlbumKeys: ["l1", "l2", "l3"],
            songIDs: ["s1", "s2", "s1"]
        )
        #expect(entries == [.album("l3"), .album("l1"), .song("s1"), .song("s2")])
    }

    @Test("Without the service's albums the slots fall back to local picks")
    func composeFallback() {
        let entries = AIRecommendationFeedComposer.compose(
            unit: .mixed,
            intelligentAlbumKeys: [],
            localAlbumKeys: ["l1", "l2", "l3"],
            songIDs: ["s1"]
        )
        #expect(entries == [.album("l1"), .album("l2"), .song("s1")])
    }

    @Test("Songs only, albums only, and albums only without any album")
    func composeUnits() {
        let songsOnly = AIRecommendationFeedComposer.compose(
            unit: .songs, intelligentAlbumKeys: ["l1"], localAlbumKeys: ["l1"], songIDs: ["s1"]
        )
        #expect(songsOnly == [.song("s1")])
        let albumsOnly = AIRecommendationFeedComposer.compose(
            unit: .albums, intelligentAlbumKeys: [], localAlbumKeys: ["l1", "l2"], songIDs: ["s1"]
        )
        #expect(albumsOnly == [.album("l1"), .album("l2")])
        let empty = AIRecommendationFeedComposer.compose(
            unit: .albums, intelligentAlbumKeys: [], localAlbumKeys: [], songIDs: ["s1"]
        )
        #expect(empty == [.song("s1")])
        let custom = AIRecommendationFeedComposer.compose(
            unit: .mixed, intelligentAlbumKeys: [], localAlbumKeys: ["l1", "l2"], songIDs: [], albumSlots: 1
        )
        #expect(custom == [.album("l1")])
    }
}
