import Foundation
import Testing
@testable import PrimuseKit

@Suite("Audio cache eviction plan")
struct AudioCacheEvictionPlanPolicyTests {
    private func candidate(
        _ path: String,
        size: Int64,
        age: TimeInterval
    ) -> AudioCacheEvictionPlanPolicy.Candidate {
        AudioCacheEvictionPlanPolicy.Candidate(
            relativePath: path,
            size: size,
            lastUsed: Date(timeIntervalSince1970: age)
        )
    }

    @Test("Oldest entries are planned first and the plan stops once satisfied")
    func planOldestFirstAndStops() {
        let plan = AudioCacheEvictionPlanPolicy.plan(
            candidates: [
                candidate("new.flac", size: 100, age: 300),
                candidate("old.flac", size: 100, age: 100),
                candidate("middle.flac", size: 100, age: 200),
            ],
            excludedPaths: [],
            neededBytes: 150
        )
        #expect(plan.map(\.relativePath) == ["old.flac", "middle.flac"])
    }

    @Test("A single large entry satisfies the need on its own")
    func planStopsAtFirstSufficientEntry() {
        let plan = AudioCacheEvictionPlanPolicy.plan(
            candidates: [
                candidate("old.flac", size: 900, age: 100),
                candidate("new.flac", size: 900, age: 200),
            ],
            excludedPaths: [],
            neededBytes: 500
        )
        #expect(plan.map(\.relativePath) == ["old.flac"])
    }

    @Test("Excluded paths and non-positive sizes are skipped")
    func planSkipsExcludedAndEmptyEntries() {
        let plan = AudioCacheEvictionPlanPolicy.plan(
            candidates: [
                candidate("playing.flac", size: 500, age: 100),
                candidate("empty.flac", size: 0, age: 110),
                candidate("negative.flac", size: -20, age: 120),
                candidate("evictable.flac", size: 500, age: 130),
            ],
            excludedPaths: ["playing.flac"],
            neededBytes: 400
        )
        #expect(plan.map(\.relativePath) == ["evictable.flac"])
    }

    @Test("No need means no plan")
    func planIsEmptyWhenNothingIsNeeded() {
        let candidates = [candidate("old.flac", size: 500, age: 100)]
        #expect(AudioCacheEvictionPlanPolicy.plan(
            candidates: candidates,
            excludedPaths: [],
            neededBytes: 0
        ).isEmpty)
        #expect(AudioCacheEvictionPlanPolicy.plan(
            candidates: candidates,
            excludedPaths: [],
            neededBytes: -10
        ).isEmpty)
    }

    @Test("Insufficient candidates still return every eligible entry")
    func planReturnsAllEligibleWhenInsufficient() {
        let plan = AudioCacheEvictionPlanPolicy.plan(
            candidates: [
                candidate("b.flac", size: 100, age: 200),
                candidate("a.flac", size: 100, age: 100),
                candidate("leased.flac", size: 10_000, age: 50),
            ],
            excludedPaths: ["leased.flac"],
            neededBytes: 5_000
        )
        #expect(plan.map(\.relativePath) == ["a.flac", "b.flac"])
    }
}
