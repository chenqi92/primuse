import Testing
@testable import PrimuseKit

@Suite("Queue history layout")
struct QueueHistoryLayoutTests {
    @Test("A short history is drawn whole, numbered from the top")
    func shortHistoryIsWhole() {
        let layout = QueueHistoryLayout(playedCount: 3, upcomingCount: 5, historyLimit: 100)

        #expect(layout.visibleHistoryRange == 0..<3)
        #expect(layout.hiddenHistoryCount == 0)
        #expect(layout.nextRevealCount == 0)
        #expect(layout.revealsCurrentOnAppear)
        #expect(layout.totalCount == 9)
        #expect((0..<3).map { layout.historyOrdinal(visibleOffset: $0) } == [1, 2, 3])
        #expect(layout.currentOrdinal == 4)
        #expect(layout.upcomingOrdinal(offset: 0) == 5)
        #expect(layout.upcomingOrdinal(offset: 4) == 9)
    }

    @Test("A long history only draws the most recent page and keeps absolute numbers")
    func longHistoryDrawsRecentPage() {
        let layout = QueueHistoryLayout(playedCount: 3_000, upcomingCount: 7_000, historyLimit: 100)

        #expect(layout.visibleHistoryRange == 2_900..<3_000)
        #expect(layout.hiddenHistoryCount == 2_900)
        #expect(layout.nextRevealCount == QueueHistoryLayout.pageSize)
        // 最上面画出来的那首接着没画出来的那些往下数,刚放完的那首紧挨正在播放。
        #expect(layout.historyOrdinal(visibleOffset: 0) == 2_901)
        #expect(layout.historyOrdinal(visibleOffset: 99) == 3_000)
        #expect(layout.currentOrdinal == 3_001)
        #expect(layout.upcomingOrdinal(offset: 0) == 3_002)
        #expect(layout.totalCount == 10_001)
    }

    @Test("Showing earlier songs grows the window a page at a time until the start")
    func showingEarlierGrowsByPage() {
        var limit = QueueHistoryLayout.pageSize
        var layout = QueueHistoryLayout(playedCount: 230, upcomingCount: 0, historyLimit: limit)
        #expect(layout.nextRevealCount == 100)

        limit = layout.expandedHistoryLimit
        layout = QueueHistoryLayout(playedCount: 230, upcomingCount: 0, historyLimit: limit)
        #expect(layout.visibleHistoryRange == 30..<230)
        #expect(layout.nextRevealCount == 30)

        limit = layout.expandedHistoryLimit
        layout = QueueHistoryLayout(playedCount: 230, upcomingCount: 0, historyLimit: limit)
        #expect(layout.visibleHistoryRange == 0..<230)
        #expect(layout.hiddenHistoryCount == 0)
        #expect(layout.nextRevealCount == 0)
    }

    @Test("An expanded window keeps its size as the queue moves on")
    func expandedWindowSlidesWithPlayback() {
        let before = QueueHistoryLayout(playedCount: 500, upcomingCount: 10, historyLimit: 200)
        let after = QueueHistoryLayout(playedCount: 501, upcomingCount: 9, historyLimit: 200)

        #expect(before.visibleHistoryRange.count == after.visibleHistoryRange.count)
        #expect(after.visibleHistoryRange.upperBound == 501)
    }

    @Test("Nothing played: the list already starts at the current song")
    func emptyHistoryDoesNotReveal() {
        let layout = QueueHistoryLayout(playedCount: 0, upcomingCount: 4, historyLimit: 100)

        #expect(layout.visibleHistoryRange.isEmpty)
        #expect(!layout.revealsCurrentOnAppear)
        #expect(layout.nextRevealCount == 0)
        #expect(layout.currentOrdinal == 1)
        #expect(layout.upcomingOrdinal(offset: 0) == 2)
        #expect(layout.totalCount == 5)
    }

    @Test("Negative inputs are clamped")
    func negativeInputsClamp() {
        let layout = QueueHistoryLayout(playedCount: -3, upcomingCount: -1, historyLimit: -5)

        #expect(layout.playedCount == 0)
        #expect(layout.upcomingCount == 0)
        #expect(layout.visibleHistoryRange == 0..<0)
        #expect(layout.totalCount == 1)
    }
}

@Suite("Recent played occurrences")
struct RecentPlayedOccurrencesTests {
    @Test("Without shuffle the recent slice is the queue just before the current song")
    func nonShuffleSlicesQueuePrefix() {
        let recent = QueuePresentationPolicy.recentPlayedOccurrences(
            queueCount: 50_000,
            currentIndex: 40_000,
            shuffledIndices: nil,
            shufflePosition: 0,
            limit: 100
        )

        #expect(recent.totalCount == 40_000)
        #expect(recent.occurrences.map(\.queueIndex) == Array(39_900..<40_000))
        #expect(recent.occurrences.allSatisfy { $0.roundOffset == 0 })
    }

    @Test("Matches the tail of the full played list, with and without shuffle")
    func matchesFullPlayedTail() {
        let cases: [(queueCount: Int, currentIndex: Int, shuffled: [Int]?, position: Int)] = [
            (8, 5, nil, 0),
            (8, 0, nil, 0),
            (8, 12, nil, 0),
            (6, 2, [4, 0, 5, 2, 1, 3], 3),
            (6, 1, [4, 4, 0, 5, 1, 3], 4),
            (6, 3, [3, 0, 1], 0),
        ]
        for item in cases {
            let full = QueuePresentationPolicy.playedOccurrences(
                queueCount: item.queueCount,
                currentIndex: item.currentIndex,
                shuffledIndices: item.shuffled,
                shufflePosition: item.position
            )
            for limit in [0, 1, 2, 100] {
                let recent = QueuePresentationPolicy.recentPlayedOccurrences(
                    queueCount: item.queueCount,
                    currentIndex: item.currentIndex,
                    shuffledIndices: item.shuffled,
                    shufflePosition: item.position,
                    limit: limit
                )
                #expect(recent.totalCount == full.count)
                #expect(recent.occurrences == Array(full.suffix(limit)))
            }
        }
    }

    @Test("Empty queue has no history")
    func emptyQueue() {
        let recent = QueuePresentationPolicy.recentPlayedOccurrences(
            queueCount: 0,
            currentIndex: 3,
            shuffledIndices: nil,
            shufflePosition: 0,
            limit: 100
        )

        #expect(recent.occurrences.isEmpty)
        #expect(recent.totalCount == 0)
    }
}
