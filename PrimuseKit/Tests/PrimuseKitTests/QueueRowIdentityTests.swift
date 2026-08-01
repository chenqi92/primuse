import Testing
@testable import PrimuseKit

@Suite("Queue row identity")
struct QueueRowIdentityTests {
    @Test("Repeated songs remain distinct queue occurrences")
    func repeatedSongsHaveUniqueIdentities() {
        let identities = QueueRowIdentity.make(for: ["same", "same", "other", "same"])

        #expect(Set(identities).count == identities.count)
        #expect(identities.map(\.position) == [0, 1, 2, 3])
        #expect(identities.map(\.songID) == ["same", "same", "other", "same"])
    }

    @Test("Replacing a queue slot invalidates only that row identity")
    func replacementInvalidatesAffectedRow() {
        let before = QueueRowIdentity.make(for: ["a", "b", "c"])
        let after = QueueRowIdentity.make(for: ["a", "replacement", "c"])

        #expect(before[0] == after[0])
        #expect(before[1] != after[1])
        #expect(before[2] == after[2])
    }

    @Test("Filtering unavailable songs preserves canonical queue offsets")
    func visibleRowsPreserveQueueOffsets() {
        let rows = QueueRowIdentity.makeVisible(
            for: ["removed", "same", "same", "disabled", "last"],
            where: { !["removed", "disabled"].contains($0) }
        )

        #expect(rows.map(\.position) == [1, 2, 4])
        #expect(rows.map(\.songID) == ["same", "same", "last"])
        #expect(Set(rows).count == rows.count)
    }
}

@Suite("Queue presentation rounds")
struct QueuePresentationPolicyTests {
    @Test("Shuffle played rows use the actual traversal prefix")
    func shufflePlayedRowsDoNotOverlapCurrentRoundUpcoming() {
        let played = QueuePresentationPolicy.playedOccurrences(
            queueCount: 4,
            currentIndex: 2,
            shuffledIndices: [3, 2, 0, 1],
            shufflePosition: 1
        )
        let upcoming = QueuePresentationPolicy.upcomingOccurrences(
            queueCount: 4,
            currentIndex: 2,
            shuffledIndices: [3, 2, 0, 1],
            shufflePosition: 1,
            nextRoundIndices: nil
        )

        #expect(played == [QueuePresentationOccurrence(queueIndex: 3, roundOffset: 0)])
        #expect(upcoming == [
            QueuePresentationOccurrence(queueIndex: 0, roundOffset: 0),
            QueuePresentationOccurrence(queueIndex: 1, roundOffset: 0)
        ])
        #expect(Set(played).isDisjoint(with: Set(upcoming)))
    }

    @Test("Repeat-all gives next-round slots distinct presentation identities")
    func nextRoundOccurrencesRemainUnique() {
        let upcoming = QueuePresentationPolicy.upcomingOccurrences(
            queueCount: 3,
            currentIndex: 2,
            shuffledIndices: [2, 0, 1],
            shufflePosition: 0,
            nextRoundIndices: [0, 2, 1]
        )

        #expect(upcoming == [
            QueuePresentationOccurrence(queueIndex: 0, roundOffset: 0),
            QueuePresentationOccurrence(queueIndex: 1, roundOffset: 0),
            QueuePresentationOccurrence(queueIndex: 0, roundOffset: 1),
            QueuePresentationOccurrence(queueIndex: 2, roundOffset: 1),
            QueuePresentationOccurrence(queueIndex: 1, roundOffset: 1)
        ])
        #expect(Set(upcoming).count == upcoming.count)
    }

    @Test("Non-shuffle presentation keeps raw queue partitions")
    func nonShuffleUsesRawOrder() {
        let played = QueuePresentationPolicy.playedOccurrences(
            queueCount: 4,
            currentIndex: 2,
            shuffledIndices: nil,
            shufflePosition: 0
        )
        let upcoming = QueuePresentationPolicy.upcomingOccurrences(
            queueCount: 4,
            currentIndex: 2,
            shuffledIndices: nil,
            shufflePosition: 0,
            nextRoundIndices: nil
        )

        #expect(played.map(\.queueIndex) == [0, 1])
        #expect(upcoming.map(\.queueIndex) == [3])
    }
}

@Suite("Shuffle round preparation")
struct ShuffleRoundPreparationPolicyTests {
    @Test("The first generated round is reused after the caller caches it")
    func cachedRoundPreventsPreviewAndAdvanceFromDiverging() {
        var generationCount = 0
        let first = ShuffleRoundPreparationPolicy.preparedRound(pending: nil) {
            generationCount += 1
            return [2, 0, 1]
        }
        let subsequent = ShuffleRoundPreparationPolicy.preparedRound(pending: first) {
            generationCount += 1
            return [1, 2, 0]
        }

        #expect(first == [2, 0, 1])
        #expect(subsequent == first)
        #expect(generationCount == 1)
    }
}

@Suite("Queue traversal")
struct QueueTraversalPolicyTests {
    @Test("Next skips unavailable entries without changing queue positions")
    func nextSkipsUnavailableEntries() {
        let available = Set([3])
        let next = QueueTraversalPolicy.nextAvailableIndex(
            queueCount: 5,
            after: 0,
            wraps: false,
            isAvailable: available.contains
        )

        #expect(next == 3)
    }

    @Test("Repeat all wraps to the first available entry")
    func nextWrapsPastUnavailableTail() {
        let available = Set([1, 4])
        let next = QueueTraversalPolicy.nextAvailableIndex(
            queueCount: 5,
            after: 4,
            wraps: true,
            isAvailable: available.contains
        )

        #expect(next == 1)
    }

    @Test("Repeat off stops when no available successor remains")
    func nextStopsWithoutWrap() {
        let available = Set([0])
        let next = QueueTraversalPolicy.nextAvailableIndex(
            queueCount: 4,
            after: 0,
            wraps: false,
            isAvailable: available.contains
        )

        #expect(next == nil)
    }

    @Test("Previous skips unavailable entries")
    func previousSkipsUnavailableEntries() {
        let available = Set([0, 3])
        let previous = QueueTraversalPolicy.previousAvailableIndex(
            before: 3,
            isAvailable: available.contains
        )

        #expect(previous == 0)
    }
}
