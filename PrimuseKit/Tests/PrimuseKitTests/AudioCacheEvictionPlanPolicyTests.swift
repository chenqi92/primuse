import Foundation
import Testing
@testable import PrimuseKit

@Suite("Audio cache eviction plan")
struct AudioCacheEvictionPlanPolicyTests {
    private func candidate(
        _ path: String,
        size: Int64,
        age: TimeInterval,
        isIncomplete: Bool = false
    ) -> AudioCacheEvictionPlanPolicy.Candidate {
        AudioCacheEvictionPlanPolicy.Candidate(
            relativePath: path,
            size: size,
            lastUsed: Date(timeIntervalSince1970: age),
            isIncomplete: isIncomplete
        )
    }

    private let now = Date(timeIntervalSince1970: 100_000)

    @Test("Abandoned partial downloads go before older complete files")
    func planAbandonedIncompleteFirst() {
        let plan = AudioCacheEvictionPlanPolicy.plan(
            candidates: [
                candidate("oldest.flac", size: 100, age: 100),
                candidate("newer.flac.partial", size: 100, age: 50_000, isIncomplete: true),
                candidate("older.flac.partial", size: 100, age: 40_000, isIncomplete: true),
                candidate("middle.flac", size: 100, age: 200),
            ],
            excludedPaths: [],
            neededBytes: 300,
            now: now
        )
        #expect(plan.map(\.relativePath) == [
            "older.flac.partial",
            "newer.flac.partial",
            "oldest.flac",
        ])
    }

    @Test("A partial written moments ago is ordered by use like a complete file")
    func planKeepsFreshIncompleteInLRUOrder() {
        let fresh = now.timeIntervalSince1970
            - AudioCacheEvictionPlanPolicy.abandonedIncompleteAge + 1
        let plan = AudioCacheEvictionPlanPolicy.plan(
            candidates: [
                candidate("next.flac.partial", size: 100, age: fresh, isIncomplete: true),
                candidate("old.flac", size: 100, age: 100),
            ],
            excludedPaths: [],
            neededBytes: 100,
            now: now
        )
        #expect(plan.map(\.relativePath) == ["old.flac"])
    }

    @Test("Partial downloads still respect the exclusion set")
    func planSkipsExcludedIncomplete() {
        let plan = AudioCacheEvictionPlanPolicy.plan(
            candidates: [
                candidate("streaming.flac.partial", size: 100, age: 100, isIncomplete: true),
                candidate("old.flac", size: 100, age: 200),
            ],
            excludedPaths: ["streaming.flac.partial"],
            neededBytes: 100,
            now: now
        )
        #expect(plan.map(\.relativePath) == ["old.flac"])
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

@Suite("Offline audio mirror")
struct OfflineAudioMirrorPolicyTests {
    private let file = OfflineAudioMirrorPolicy.FileIdentity(device: 1, inode: 10)
    private let replaced = OfflineAudioMirrorPolicy.FileIdentity(device: 1, inode: 11)

    @Test("A pinned file is linked into the offline store and kept once linked")
    func pinnedFileIsMirrored() {
        #expect(OfflineAudioMirrorPolicy.action(
            isPinned: true, cacheFile: file, mirrorFile: nil, cacheDirectoryIntact: true
        ) == .mirror)
        #expect(OfflineAudioMirrorPolicy.action(
            isPinned: true, cacheFile: file, mirrorFile: file, cacheDirectoryIntact: true
        ) == .keep)
    }

    @Test("A file replaced in the cache (refresh, re-download) replaces the offline copy")
    func replacedFileRefreshesMirror() {
        #expect(OfflineAudioMirrorPolicy.action(
            isPinned: true, cacheFile: replaced, mirrorFile: file, cacheDirectoryIntact: true
        ) == .mirror)
    }

    @Test("After the system purges the cache directory the offline copy is linked back")
    func purgedCacheIsRestored() {
        #expect(OfflineAudioMirrorPolicy.action(
            isPinned: true, cacheFile: nil, mirrorFile: file, cacheDirectoryIntact: false
        ) == .restore)
    }

    @Test("A pinned file deleted on purpose in an intact cache is not resurrected")
    func deliberateDeletionDropsMirror() {
        #expect(OfflineAudioMirrorPolicy.action(
            isPinned: true, cacheFile: nil, mirrorFile: file, cacheDirectoryIntact: true
        ) == .drop)
    }

    @Test("Unpinned files leave the offline store but stay in the cache")
    func unpinnedFileLeavesMirror() {
        #expect(OfflineAudioMirrorPolicy.action(
            isPinned: false, cacheFile: file, mirrorFile: file, cacheDirectoryIntact: true
        ) == .drop)
        #expect(OfflineAudioMirrorPolicy.action(
            isPinned: false, cacheFile: nil, mirrorFile: file, cacheDirectoryIntact: false
        ) == .drop)
        #expect(OfflineAudioMirrorPolicy.action(
            isPinned: false, cacheFile: file, mirrorFile: nil, cacheDirectoryIntact: true
        ) == .keep)
        #expect(OfflineAudioMirrorPolicy.action(
            isPinned: true, cacheFile: nil, mirrorFile: nil, cacheDirectoryIntact: false
        ) == .keep)
    }
}
