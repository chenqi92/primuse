import Foundation
import Testing
@testable import PrimuseKit

/// A managed shuffle round is read by two independent consumers: the Up Next
/// presentation the user sees and drags, and the traversal that picks the next
/// track. They used to cut the round at different places whenever the cached
/// `shufflePosition` no longer pointed at the playing slot, so Up Next stopped
/// describing what would actually play and a drag rewrote a slice playback
/// never visits.
@Suite("Shuffle traversal anchor")
struct ShuffleTraversalAnchorPolicyTests {
    /// Round of five slots; the playing slot (queue index 7) sits at position 3.
    private let round = [4, 1, 9, 7, 2]
    private let playingQueueIndex = 7
    private let queueCount = 10

    private func anchor(hint: Int) -> Int? {
        ShuffleTraversalAnchorPolicy.anchorPosition(
            traversalIndices: round,
            currentIndex: playingQueueIndex,
            shufflePosition: hint
        )
    }

    @Test("The playing slot's own position wins over the cached hint")
    func playingSlotWins() {
        #expect(anchor(hint: 3) == 3)
        #expect(anchor(hint: 0) == 3)
        #expect(anchor(hint: 4) == 3)
        #expect(anchor(hint: 99) == 3)
    }

    @Test("A round that no longer holds the playing slot falls back to the clamped hint")
    func extendedRoundFallsBackToHint() {
        // `extendExhaustedShuffleFromLibrary` rebuilds the round out of freshly
        // appended library indices, so the previous segment's slots are gone.
        let extended = [12, 13, 14]
        #expect(ShuffleTraversalAnchorPolicy.anchorPosition(
            traversalIndices: extended,
            currentIndex: playingQueueIndex,
            shufflePosition: 1
        ) == 1)
        #expect(ShuffleTraversalAnchorPolicy.anchorPosition(
            traversalIndices: extended,
            currentIndex: playingQueueIndex,
            shufflePosition: 7
        ) == 2)
        #expect(ShuffleTraversalAnchorPolicy.anchorPosition(
            traversalIndices: extended,
            currentIndex: playingQueueIndex,
            shufflePosition: -3
        ) == 0)
    }

    @Test("An empty round has no anchor")
    func emptyRoundHasNoAnchor() {
        #expect(ShuffleTraversalAnchorPolicy.anchorPosition(
            traversalIndices: [],
            currentIndex: playingQueueIndex,
            shufflePosition: 0
        ) == nil)
    }

    /// The regression itself: the head of the presented Up Next list has to be
    /// the very track traversal advances to.
    @Test("Up Next head matches the track advance picks, for every stale hint")
    func presentationHeadMatchesTraversal() {
        for hint in -1...(round.count + 2) {
            let resolved = anchor(hint: hint) ?? hint
            let upcoming = QueuePresentationPolicy.upcomingOccurrences(
                queueCount: queueCount,
                currentIndex: playingQueueIndex,
                shuffledIndices: round,
                shufflePosition: resolved,
                nextRoundIndices: nil
            )
            let advancePosition = QueueTraversalPolicy.nextAvailableTraversalPosition(
                in: round,
                queueCount: queueCount,
                after: resolved,
                isAvailable: { _ in true }
            )
            #expect(upcoming.first?.queueIndex == advancePosition.map { round[$0] })
        }
    }

    @Test("The raw stale hint is what used to break that agreement")
    func rawStaleHintDisagrees() {
        let staleHint = 1
        let upcoming = QueuePresentationPolicy.upcomingOccurrences(
            queueCount: queueCount,
            currentIndex: playingQueueIndex,
            shuffledIndices: round,
            shufflePosition: staleHint,
            nextRoundIndices: nil
        )
        let advancePosition = QueueTraversalPolicy.nextAvailableTraversalPosition(
            in: round,
            queueCount: queueCount,
            after: 3,
            isAvailable: { _ in true }
        )
        // Up Next offered slot 9 while advance would have played slot 2.
        #expect(upcoming.first?.queueIndex == 9)
        #expect(advancePosition.map { round[$0] } == 2)
        #expect(upcoming.first?.queueIndex != advancePosition.map { round[$0] })
    }

    /// An Up Next drag rewrites `round[anchor + 1 ..< end]`. That slice has to
    /// be exactly the slots presented as the current round, or the drop lands
    /// on rows playback never reaches.
    @Test("The slice a drag rewrites is exactly the presented current round")
    func reorderSliceMatchesPresentedRound() {
        for hint in 0...(round.count + 1) {
            let resolved = anchor(hint: hint) ?? hint
            let presented = QueuePresentationPolicy.upcomingOccurrences(
                queueCount: queueCount,
                currentIndex: playingQueueIndex,
                shuffledIndices: round,
                shufflePosition: resolved,
                nextRoundIndices: nil
            ).filter { $0.roundOffset == 0 }.map(\.queueIndex)
            let start = min(max(resolved + 1, 0), round.count)
            #expect(Array(round.dropFirst(start)) == presented)
        }
    }

    @Test("Played rows stay behind the anchor once it is resolved")
    func playedRowsStopAtTheAnchor() {
        let played = QueuePresentationPolicy.playedOccurrences(
            queueCount: queueCount,
            currentIndex: playingQueueIndex,
            shuffledIndices: round,
            shufflePosition: anchor(hint: 0) ?? 0
        ).map(\.queueIndex)

        #expect(played == [4, 1, 9])
    }
}
