import Foundation
import Testing
@testable import PrimuseKit

@Suite("Music video recommendations")
struct MusicVideoRecommendationPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func video(_ id: String, artist: String?, daysAgo: Double = 400) -> MusicVideoRecommendationPolicy.Candidate {
        .init(id: id, artistID: artist, dateAdded: now.addingTimeInterval(-daysAgo * 86_400))
    }

    @Test("Favorite artists come first")
    func favoritesFirst() {
        let picks = MusicVideoRecommendationPolicy.recommended(
            [video("a", artist: "x"), video("b", artist: "fav"), video("c", artist: "y")],
            favoriteArtistIDs: ["fav"],
            recentlyPlayedIDs: [],
            now: now, day: 10, limit: 3
        )
        #expect(picks.first == "b")
        #expect(Set(picks) == ["a", "b", "c"])
    }

    @Test("Recently watched ones move back")
    func recentlyWatchedMoveBack() {
        let picks = MusicVideoRecommendationPolicy.recommended(
            [video("seen", artist: "fav"), video("new", artist: "other")],
            favoriteArtistIDs: ["fav"],
            recentlyPlayedIDs: ["seen"],
            now: now, day: 3, limit: 2
        )
        #expect(picks == ["new", "seen"])
    }

    @Test("One artist cannot fill the row while others are waiting")
    func artistDiversity() {
        let candidates = (0..<5).map { video("f\($0)", artist: "fav") } + [video("o", artist: "other")]
        let picks = MusicVideoRecommendationPolicy.recommended(
            candidates,
            favoriteArtistIDs: ["fav"],
            recentlyPlayedIDs: [],
            now: now, day: 1, limit: 3
        )
        #expect(picks.count == 3)
        #expect(picks.contains("o"))
        #expect(picks.filter { $0.hasPrefix("f") }.count == 2)
    }

    @Test("Short lists still fill up and the order is stable within a day")
    func fillsAndIsStable() {
        let candidates = (0..<4).map { video("f\($0)", artist: "fav") }
        let first = MusicVideoRecommendationPolicy.recommended(
            candidates, favoriteArtistIDs: [], recentlyPlayedIDs: [], now: now, day: 7, limit: 10
        )
        let again = MusicVideoRecommendationPolicy.recommended(
            candidates, favoriteArtistIDs: [], recentlyPlayedIDs: [], now: now, day: 7, limit: 10
        )
        #expect(first.count == 4)
        #expect(first == again)
        #expect(MusicVideoRecommendationPolicy.recommended(
            candidates, favoriteArtistIDs: [], recentlyPlayedIDs: [], now: now, day: 7, limit: 0
        ).isEmpty)
    }

    @Test("New additions get a lift")
    func freshnessLift() {
        let picks = MusicVideoRecommendationPolicy.recommended(
            [video("old", artist: "a", daysAgo: 300), video("fresh", artist: "b", daysAgo: 1)],
            favoriteArtistIDs: [],
            recentlyPlayedIDs: [],
            now: now, day: 2, limit: 2
        )
        #expect(picks.first == "fresh")
    }
}
