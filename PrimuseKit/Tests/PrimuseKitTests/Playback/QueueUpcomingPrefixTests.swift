import Foundation
import Testing
@testable import PrimuseKit

@Suite struct QueueUpcomingPrefixTests {
    private func reference(
        queueCount: Int,
        currentIndex: Int,
        shuffledIndices: [Int]?,
        shufflePosition: Int,
        include: (Int) -> Bool
    ) -> [Int] {
        QueuePresentationPolicy.upcomingOccurrences(
            queueCount: queueCount,
            currentIndex: currentIndex,
            shuffledIndices: shuffledIndices,
            shufflePosition: shufflePosition,
            nextRoundIndices: [0, 1, 2]
        )
        .filter { $0.roundOffset == 0 }
        .map(\.queueIndex)
        .filter(include)
    }

    @Test func matchesFullExpansionOrderedQueue() {
        for current in 0..<6 {
            let full = reference(queueCount: 6, currentIndex: current, shuffledIndices: nil, shufflePosition: 0) { $0 % 2 == 0 }
            for limit in 1...4 {
                let prefix = QueuePresentationPolicy.firstCurrentRoundUpcomingIndices(
                    queueCount: 6, currentIndex: current, shuffledIndices: nil,
                    shufflePosition: 0, limit: limit, where: { $0 % 2 == 0 }
                )
                #expect(prefix == Array(full.prefix(limit)))
            }
        }
    }

    @Test func matchesFullExpansionShuffledWithDuplicatesAndStaleIndices() {
        let shuffled = [4, 1, 7, 1, 0, 9, 3, 4, 2, 6, 5]
        for position in 0..<shuffled.count {
            let current = shuffled[position] < 8 ? shuffled[position] : 0
            let full = reference(queueCount: 8, currentIndex: current, shuffledIndices: shuffled, shufflePosition: position) { $0 != 6 }
            for limit in 1...9 {
                let prefix = QueuePresentationPolicy.firstCurrentRoundUpcomingIndices(
                    queueCount: 8, currentIndex: current, shuffledIndices: shuffled,
                    shufflePosition: position, limit: limit, where: { $0 != 6 }
                )
                #expect(prefix == Array(full.prefix(limit)))
            }
        }
    }

    @Test func stopsEvaluatingOnceLimitIsReached() {
        var evaluated = 0
        let prefix = QueuePresentationPolicy.firstCurrentRoundUpcomingIndices(
            queueCount: 40_000, currentIndex: 0, shuffledIndices: Array(0..<40_000).reversed(),
            shufflePosition: 0, limit: 2, where: { _ in evaluated += 1; return true }
        )
        #expect(prefix == [39_998, 39_997])
        #expect(evaluated == 2)
    }

    @Test func emptyAtEndOfRound() {
        #expect(QueuePresentationPolicy.firstCurrentRoundUpcomingIndices(
            queueCount: 3, currentIndex: 2, shuffledIndices: nil, shufflePosition: 0, limit: 1
        ).isEmpty)
        #expect(QueuePresentationPolicy.firstCurrentRoundUpcomingIndices(
            queueCount: 3, currentIndex: 1, shuffledIndices: [0, 2, 1], shufflePosition: 2, limit: 1
        ).isEmpty)
    }
}
