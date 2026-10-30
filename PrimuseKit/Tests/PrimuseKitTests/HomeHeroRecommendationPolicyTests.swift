import Foundation
import Testing
@testable import PrimuseKit

@Suite("Daily home recommendations")
struct HomeHeroRecommendationPolicyTests {
    @Test func settingsStayWithinSupportedCounts() {
        #expect(HomeHeroRecommendationPolicy.songCount(-4) == 1)
        #expect(HomeHeroRecommendationPolicy.songCount(50) == 50)
        #expect(HomeHeroRecommendationPolicy.songCount(500) == 50)
        #expect(HomeHeroRecommendationPolicy.albumCount(0) == 1)
        #expect(HomeHeroRecommendationPolicy.albumCount(50) == 12)
    }

    @Test func dailySelectionIsStableAndChangesAtLocalMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let before = ISO8601DateFormatter().date(from: "2026-10-30T15:59:59Z")!
        let day = HomeHeroRecommendationPolicy.dayStamp(before, calendar: calendar)
        let following = HomeHeroRecommendationPolicy.dayStamp(before.addingTimeInterval(1), calendar: calendar)
        #expect(day == 20261030)
        #expect(following == 20261031)
        let ids = (0..<200).map(String.init)
        let first = HomeHeroRecommendationPolicy.candidates(rankedIDs: ids, day: day, round: 0, excluding: [], limit: 50)
        #expect(first == HomeHeroRecommendationPolicy.candidates(rankedIDs: ids, day: day, round: 0, excluding: [], limit: 50))
        let next = HomeHeroRecommendationPolicy.candidates(rankedIDs: ids, day: following, round: 0, excluding: Set(first), limit: 50)
        #expect(Set(first).isDisjoint(with: next))
    }

    @Test func manualRefreshPrefersFreshSongsAndFillsSmallLibrariesWithoutDuplicates() {
        let ids = (0..<80).map(String.init)
        let first = HomeHeroRecommendationPolicy.candidates(rankedIDs: ids, day: 20261030, round: 0, excluding: [], limit: 50)
        let next = HomeHeroRecommendationPolicy.candidates(rankedIDs: ids + ids, day: 20261030, round: 1, excluding: Set(first), limit: 50)
        #expect(next.count == 50)
        #expect(Set(next).count == 50)
        #expect(Set(next.prefix(30)).isDisjoint(with: first))
        #expect(Set(next).intersection(first).count == 20)
        #expect(HomeHeroRecommendationPolicy.candidates(rankedIDs: ["", "a", "a", "b"], day: 20261030, round: 2, excluding: ["a", "b"], limit: 50).count == 2)
    }

    @Test func partialAIResultsNeverIntroduceMissingSongsOrExceedTheRequestedCount() {
        let local = (0..<80).map(String.init)
        let ranked = HomeHeroRecommendationPolicy.merged(preferred: ["40", "missing", "40", "60"], fallback: local, limit: 50)
        #expect(ranked.count == 50)
        #expect(Array(ranked.prefix(2)) == ["40", "60"])
        #expect(Set(ranked).count == 50)
        #expect(!ranked.contains("missing"))
        #expect(HomeHeroRecommendationPolicy.merged(preferred: ["missing"], fallback: ["a"], limit: 50) == ["a"])
    }

    @Test func themedPoolsFavorKnownErasWithoutInventingMissingYears() {
        let songs = (0..<120).map { index in
            var song = Song(id: "era-\(index)", title: "Track \(index)", fileFormat: .mp3, filePath: "\(index).mp3", sourceID: "fixture")
            song.year = index < 100 ? 1950 + index / 2 : nil
            return song
        }
        let older = HomeHeroRecommendationTheme.catalogRewind.candidatePool(from: songs, minimumCount: 24)
        let newer = HomeHeroRecommendationTheme.recentCatalog.candidatePool(from: songs, minimumCount: 24)
        #expect(older.count == 50)
        #expect(newer.count == 50)
        #expect(older.allSatisfy { ($0.year ?? 0) < 1975 })
        #expect(newer.allSatisfy { ($0.year ?? 0) >= 1975 })
        #expect(Set(older.map(\.id)).isDisjoint(with: newer.map(\.id)))
        let missing = Array(songs.suffix(20))
        #expect(HomeHeroRecommendationTheme.recentCatalog.candidatePool(from: missing, minimumCount: 50).map(\.id) == missing.map(\.id))
        let sparse = Array(songs.prefix(2)) + missing
        #expect(HomeHeroRecommendationTheme.catalogRewind.candidatePool(from: sparse, minimumCount: 24).count == sparse.count)
    }
}
