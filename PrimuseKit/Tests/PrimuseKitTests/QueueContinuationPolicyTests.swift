import Foundation
import Testing
@testable import PrimuseKit

@Suite("Keep playing similar songs when the queue runs out")
struct QueueContinuationPolicyTests {
    private func decision(
        enabled: Bool = true,
        repeatMode: RepeatMode = .off,
        shuffle: Bool = false,
        space: ListeningSpace? = .music,
        medley: Bool = false,
        radio: Bool = false,
        upcoming: Bool = false,
        pending: Bool = false,
        tvPlayer: Bool = false
    ) -> QueueContinuationPolicy.Decision {
        QueueContinuationPolicy.decision(
            isEnabled: enabled,
            repeatMode: repeatMode,
            shuffleEnabled: shuffle,
            space: space,
            isMedley: medley,
            isLiveRadio: radio,
            hasUpcomingSongs: upcoming,
            hasPendingRequestSongs: pending,
            shuffleExtendsFromLibrary: !tvPlayer
        )
    }

    @Test("A music queue that ran out continues with similar songs")
    func endOfMusicQueueContinues() {
        #expect(decision() == .similarSongs)
    }

    @Test("Switched off, repeating, or not music: the queue simply ends")
    func endsWhenNotApplicable() {
        #expect(decision(enabled: false) == QueueContinuationPolicy.Decision.none)
        #expect(decision(repeatMode: .all) == QueueContinuationPolicy.Decision.none)
        #expect(decision(repeatMode: .one) == QueueContinuationPolicy.Decision.none)
        #expect(decision(space: .spokenWord) == QueueContinuationPolicy.Decision.none)
        #expect(decision(space: nil) == QueueContinuationPolicy.Decision.none)
        #expect(decision(medley: true) == QueueContinuationPolicy.Decision.none)
        #expect(decision(radio: true) == QueueContinuationPolicy.Decision.none)
    }

    @Test("Nothing is added while the queue still has songs or a large request still owes some")
    func waitsForTheRealEnd() {
        #expect(decision(upcoming: true) == QueueContinuationPolicy.Decision.none)
        #expect(decision(pending: true) == QueueContinuationPolicy.Decision.none)
    }

    @Test("Shuffle keeps its own library continuation; a player without one falls back to similar songs")
    func shuffleHandOff() {
        #expect(decision(shuffle: true) == .shuffleFromLibrary)
        // The shuffle continuation predates the setting and is not governed by it.
        #expect(decision(enabled: false, shuffle: true) == .shuffleFromLibrary)
        #expect(decision(shuffle: true, tvPlayer: true) == .similarSongs)
        #expect(decision(enabled: false, shuffle: true, tvPlayer: true) == QueueContinuationPolicy.Decision.none)
    }

    @Test("Seeds are the last distinct songs up to the current one, newest first")
    func seeds() {
        let queue = ["a", "b", "c", "c", "d", "e"]
        #expect(QueueContinuationPolicy.seedIDs(queueIDs: queue, currentIndex: 4) == ["d", "c", "b"])
        #expect(QueueContinuationPolicy.seedIDs(queueIDs: queue, currentIndex: 0) == ["a"])
        #expect(QueueContinuationPolicy.seedIDs(queueIDs: queue, currentIndex: 9).isEmpty)
        #expect(QueueContinuationPolicy.seedIDs(queueIDs: ["x"], currentIndex: 0, count: 3) == ["x"])
    }

    @Test("Rankings are interleaved per seed, without repeats or excluded songs")
    func mergeInterleaves() {
        let merged = QueueContinuationPolicy.merge(
            rankedBySeed: [["a1", "shared", "a2", "a3"], ["shared", "b1", "b2"], ["c1"]],
            excluding: ["a2"],
            limit: 6
        )
        #expect(merged == ["a1", "shared", "c1", "a3", "b1", "b2"])
    }

    @Test("Merging stops at the limit and survives empty rankings")
    func mergeLimits() {
        #expect(QueueContinuationPolicy.merge(rankedBySeed: [], excluding: [], limit: 5).isEmpty)
        #expect(QueueContinuationPolicy.merge(rankedBySeed: [[], []], excluding: [], limit: 5).isEmpty)
        let long = (0..<50).map { "s\($0)" }
        #expect(QueueContinuationPolicy.merge(rankedBySeed: [long], excluding: [], limit: 20) == Array(long.prefix(20)))
        #expect(QueueContinuationPolicy.merge(rankedBySeed: [long], excluding: [], limit: 0).isEmpty)
    }

    @Test("Songs the listener adds go before the autoplay songs")
    func insertionBeforeAutoplay() {
        let auto: Set<Int> = [4, 5, 6]
        #expect(QueueContinuationPolicy.insertionIndexBeforeAutoplay(
            queueCount: 7, currentIndex: 2, isAutoplay: { auto.contains($0) }
        ) == 4)
        // Already playing inside the autoplay part: right after the current one.
        #expect(QueueContinuationPolicy.insertionIndexBeforeAutoplay(
            queueCount: 7, currentIndex: 4, isAutoplay: { auto.contains($0) }
        ) == 5)
        #expect(QueueContinuationPolicy.insertionIndexBeforeAutoplay(
            queueCount: 7, currentIndex: 2, isAutoplay: { _ in false }
        ) == nil)
        #expect(QueueContinuationPolicy.insertionIndexBeforeAutoplay(
            queueCount: 0, currentIndex: 0, isAutoplay: { _ in true }
        ) == nil)
    }

    @Test("Up Next splits at the first autoplay song")
    func split() {
        let parts = QueueContinuationPolicy.splitUpcoming(["q1", "q2", "a1", "a2"]) { $0.hasPrefix("a") }
        #expect(parts.queued == ["q1", "q2"])
        #expect(parts.autoplay == ["a1", "a2"])
        let none = QueueContinuationPolicy.splitUpcoming(["q1"]) { $0.hasPrefix("a") }
        #expect(none.queued == ["q1"])
        #expect(none.autoplay.isEmpty)
    }
}

@Suite("Similar-song top-ups stay varied")
struct QueueContinuationGroupLimitTests {
    @Test("Group limits spread a top-up across albums, then fill from what they held back")
    func groupLimits() {
        let album: [String: String] = ["a1": "A", "a2": "A", "a3": "A", "b1": "B", "c1": "C"]
        let merged = QueueContinuationPolicy.merge(
            rankedBySeed: [["a1", "a2", "a3", "b1", "c1"]],
            excluding: [],
            limit: 4,
            groupLimits: [.init(maximum: 2, key: { album[$0] })]
        )
        #expect(merged == ["a1", "a2", "b1", "c1"])
        let short = QueueContinuationPolicy.merge(
            rankedBySeed: [["a1", "a2", "a3"]],
            excluding: [],
            limit: 3,
            groupLimits: [.init(maximum: 1, key: { album[$0] })]
        )
        #expect(short == ["a1", "a2", "a3"])
    }
}
