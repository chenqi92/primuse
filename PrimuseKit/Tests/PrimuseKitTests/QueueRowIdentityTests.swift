import Foundation
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

@Suite("Queue upcoming reorder")
struct QueueUpcomingReorderPolicyTests {
    private let played = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let current = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    private let last = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

    @Test("A distinct bottom entry moves to first Up Next")
    func bottomToFirst() {
        let upcoming = occurrences([first, second, last])

        let reordered = QueueUpcomingReorderPolicy.reorderedOccurrences(
            dragging: occurrence(last),
            over: occurrence(first),
            queueEntryIDs: [played, current, first, second, last],
            upcomingOccurrences: upcoming
        )

        #expect(reordered?.map(\.queueEntryID) == [last, first, second])
        #expect(Set(reordered ?? []) == Set(upcoming))
    }

    @Test("A top entry moves after a lower drop target")
    func topToBottom() {
        let upcoming = occurrences([first, second, last])

        let reordered = QueueUpcomingReorderPolicy.reorderedOccurrences(
            dragging: occurrence(first),
            over: occurrence(last),
            queueEntryIDs: [played, current, first, second, last],
            upcomingOccurrences: upcoming
        )

        #expect(reordered?.map(\.queueEntryID) == [second, last, first])
        #expect(Set(reordered ?? []) == Set(upcoming))
    }

    @Test("Duplicate Song IDs remain distinct queue occurrences")
    func duplicateSongIDsUseQueueEntryIdentity() {
        let duplicateSongIDs = [first: "same-song", second: "same-song", last: "other-song"]
        let upcoming = occurrences([first, second, last])

        let reordered = QueueUpcomingReorderPolicy.reorderedOccurrences(
            dragging: occurrence(second),
            over: occurrence(first),
            queueEntryIDs: [current, first, second, last],
            upcomingOccurrences: upcoming
        )

        #expect(reordered?.map(\.queueEntryID) == [second, first, last])
        #expect(reordered?.compactMap { duplicateSongIDs[$0.queueEntryID] } == [
            "same-song", "same-song", "other-song"
        ])
        #expect(Set(reordered ?? []).count == upcoming.count)
    }

    @Test("Played and current entries cannot cross into Up Next")
    func playedAndCurrentAreRejected() {
        let upcoming = occurrences([first, second, last])
        let queue = [played, current, first, second, last]

        #expect(QueueUpcomingReorderPolicy.reorderedOccurrences(
            dragging: occurrence(played),
            over: occurrence(first),
            queueEntryIDs: queue,
            upcomingOccurrences: upcoming
        ) == nil)
        #expect(QueueUpcomingReorderPolicy.reorderedOccurrences(
            dragging: occurrence(current),
            over: occurrence(first),
            queueEntryIDs: queue,
            upcomingOccurrences: upcoming
        ) == nil)
    }

    @Test("A natural transition invalidates the consumed drag occurrence")
    func naturalTransitionRebasesAgainstLatestUpcoming() {
        let afterTransition = occurrences([second, last])
        let queue = [played, current, first, second, last]

        #expect(QueueUpcomingReorderPolicy.reorderedOccurrences(
            dragging: occurrence(first),
            over: occurrence(second),
            queueEntryIDs: queue,
            upcomingOccurrences: afterTransition
        ) == nil)
        #expect(QueueUpcomingReorderPolicy.reorderedOccurrences(
            dragging: occurrence(last),
            over: occurrence(second),
            queueEntryIDs: queue,
            upcomingOccurrences: afterTransition
        )?.map(\.queueEntryID) == [last, second])
    }

    @Test("Shuffle traversal order, not raw queue order, drives the move")
    func shuffleTraversalOrder() {
        let shuffledUpcoming = occurrences([last, first, second])

        let reordered = QueueUpcomingReorderPolicy.reorderedOccurrences(
            dragging: occurrence(second),
            over: occurrence(last),
            queueEntryIDs: [current, first, second, last],
            upcomingOccurrences: shuffledUpcoming
        )

        #expect(reordered?.map(\.queueEntryID) == [second, last, first])
        #expect(Set(reordered ?? []) == Set(shuffledUpcoming))
        #expect(!(reordered ?? []).contains(occurrence(current)))
    }

    @Test("Only changing the first upcoming occurrence invalidates prepared audio")
    func successorPreparationInvalidationIsScoped() {
        let before = occurrences([first, second, last])
        let laterOnly = occurrences([first, last, second])
        let newSuccessor = occurrences([last, first, second])

        #expect(!QueueUpcomingReorderPolicy.shouldInvalidatePreparedSuccessor(
            before: before,
            after: laterOnly
        ))
        #expect(QueueUpcomingReorderPolicy.shouldInvalidatePreparedSuccessor(
            before: before,
            after: newSuccessor
        ))
        #expect(!QueueUpcomingReorderPolicy.shouldInvalidatePreparedSuccessor(
            before: [],
            after: []
        ))
    }

    @Test("A repeat-all next round invalidates preparation only at the active boundary")
    func repeatAllBoundaryScopesSuccessorInvalidation() {
        let currentRoundLast = occurrence(last)
        let nextRoundFirst = occurrence(first, roundOffset: 1)
        let nextRoundSecond = occurrence(second, roundOffset: 1)

        #expect(!QueueUpcomingReorderPolicy.shouldInvalidatePreparedSuccessor(
            before: [currentRoundLast, nextRoundFirst, nextRoundSecond],
            after: [currentRoundLast, nextRoundSecond, nextRoundFirst]
        ))
        #expect(QueueUpcomingReorderPolicy.shouldInvalidatePreparedSuccessor(
            before: [nextRoundFirst, nextRoundSecond],
            after: [nextRoundSecond, nextRoundFirst]
        ))
    }

    @Test("Repeat-all occurrences cannot move across shuffle rounds")
    func shuffleRoundsStayIndependent() {
        let currentRoundLast = occurrence(last)
        let nextRoundFirst = occurrence(first, roundOffset: 1)
        let upcoming = [currentRoundLast, nextRoundFirst, occurrence(second, roundOffset: 1)]

        #expect(QueueUpcomingReorderPolicy.reorderedOccurrences(
            dragging: currentRoundLast,
            over: nextRoundFirst,
            queueEntryIDs: [current, first, second, last],
            upcomingOccurrences: upcoming
        ) == nil)
    }

    @Test("Malformed and stale payloads safely do nothing")
    func invalidAndStalePayloads() {
        #expect(QueueReorderOccurrenceID(dragPayload: "not-a-queue-entry") == nil)
        #expect(QueueReorderOccurrenceID(dragPayload: "primuse.queue-entry|bad-uuid|0") == nil)
        #expect(QueueReorderOccurrenceID(dragPayload: occurrence(first).dragPayload) == occurrence(first))

        let stale = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        #expect(QueueUpcomingReorderPolicy.reorderedOccurrences(
            dragging: occurrence(stale),
            over: occurrence(first),
            queueEntryIDs: [current, first, second],
            upcomingOccurrences: occurrences([first, second])
        ) == nil)
        #expect(QueueUpcomingReorderPolicy.reorderedOccurrences(
            dragging: occurrence(first),
            over: occurrence(stale),
            queueEntryIDs: [current, first, second],
            upcomingOccurrences: occurrences([first, second])
        ) == nil)
    }

    private func occurrence(_ id: UUID, roundOffset: Int = 0) -> QueueReorderOccurrenceID {
        QueueReorderOccurrenceID(queueEntryID: id, roundOffset: roundOffset)
    }

    private func occurrences(_ ids: [UUID], roundOffset: Int = 0) -> [QueueReorderOccurrenceID] {
        ids.map { occurrence($0, roundOffset: roundOffset) }
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

@Suite("Queue upcoming removal")
struct QueueUpcomingRemovalPolicyTests {
    private let played = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private let current = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!

    @Test("An exact upcoming occurrence resolves to its canonical queue slot")
    func resolvesExactOccurrence() {
        let queue = [played, current, first, second]
        let upcoming = [
            occurrence(first),
            occurrence(second),
            occurrence(played, roundOffset: 1),
        ]

        #expect(QueueUpcomingRemovalPolicy.queueIndex(
            for: occurrence(second),
            currentQueueEntryID: current,
            queueEntryIDs: queue,
            upcomingOccurrences: upcoming
        ) == 3)
        #expect(QueueUpcomingRemovalPolicy.queueIndex(
            for: occurrence(played, roundOffset: 1),
            currentQueueEntryID: current,
            queueEntryIDs: queue,
            upcomingOccurrences: upcoming
        ) == 0)
    }

    @Test("The current slot and stale occurrences cannot be removed")
    func rejectsCurrentAndStaleOccurrences() {
        let queue = [played, current, first]
        let upcoming = [
            occurrence(first),
            occurrence(current, roundOffset: 1),
        ]

        #expect(QueueUpcomingRemovalPolicy.queueIndex(
            for: occurrence(current, roundOffset: 1),
            currentQueueEntryID: current,
            queueEntryIDs: queue,
            upcomingOccurrences: upcoming
        ) == nil)
        #expect(QueueUpcomingRemovalPolicy.queueIndex(
            for: occurrence(second),
            currentQueueEntryID: current,
            queueEntryIDs: queue,
            upcomingOccurrences: upcoming
        ) == nil)
    }

    @Test("Only the exact immediate successor cancels transition preparation")
    func cancelsPreparationOnlyForImmediateSuccessor() {
        #expect(QueueUpcomingRemovalPolicy.shouldCancelSuccessorPreparation(
            removing: occurrence(first),
            immediateSuccessorQueueEntryID: first
        ))
        #expect(!QueueUpcomingRemovalPolicy.shouldCancelSuccessorPreparation(
            removing: occurrence(second),
            immediateSuccessorQueueEntryID: first
        ))
        #expect(!QueueUpcomingRemovalPolicy.shouldCancelSuccessorPreparation(
            removing: occurrence(first),
            immediateSuccessorQueueEntryID: nil
        ))
    }

    @Test("Removing a raw slot preserves shuffle order and the current position")
    func rebasesShuffleTraversal() {
        let result = QueueUpcomingRemovalPolicy.rebasedTraversal(
            [3, 1, 0, 2],
            currentPosition: 2,
            removingQueueIndex: 1,
            queueCount: 4
        )

        #expect(result == QueueTraversalRemovalResult(
            indices: [2, 0, 1],
            currentPosition: 1
        ))
        #expect(QueueUpcomingRemovalPolicy.rebasedIndices(
            [2, 0, 3, 1],
            removingQueueIndex: 1,
            queueCount: 4
        ) == [1, 0, 2])
    }

    private func occurrence(_ id: UUID, roundOffset: Int = 0) -> QueueReorderOccurrenceID {
        QueueReorderOccurrenceID(queueEntryID: id, roundOffset: roundOffset)
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

@Suite("Source failure queue advance")
struct SourceFailureAdvancePolicyTests {
    @Test("Entries from the failed source are skipped")
    func failedSourceEntriesAreSkipped() {
        #expect(SourceFailureAdvancePolicy.shouldSkipCandidate(
            failedSourceID: "offline-source",
            candidateSourceID: "offline-source"
        ))
    }

    @Test("A different provider remains eligible")
    func differentProviderCanContinue() {
        #expect(!SourceFailureAdvancePolicy.shouldSkipCandidate(
            failedSourceID: "offline-source",
            candidateSourceID: "healthy-source"
        ))
    }

    @Test("An identical song from a fallback provider remains eligible")
    func identicalFallbackProviderRemainsEligible() {
        #expect(!QueueAdjacentDuplicatePolicy.shouldSkipCandidate(
            queueCount: 3,
            currentTitle: "Same Song",
            currentArtist: "Same Artist",
            candidateTitle: "Same Song",
            candidateArtist: "Same Artist",
            context: .sourceFailureRecovery
        ))
    }

    @Test("Manual next still skips an adjacent duplicate")
    func manualNextStillSkipsDuplicate() {
        #expect(QueueAdjacentDuplicatePolicy.shouldSkipCandidate(
            queueCount: 3,
            currentTitle: "Same Song",
            currentArtist: "Same Artist",
            candidateTitle: "Same Song",
            candidateArtist: "Same Artist",
            context: .userInitiated
        ))
    }
}
