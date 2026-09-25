import Foundation
import Testing
@testable import PrimuseKit

@Suite("桌面半折的「接下来播放」封面条")
struct TabletopQueueStripPolicyTests {
    private typealias Policy = TabletopQueueStripPolicy

    @Test("不随机时左边是队列里当前曲之前的几首")
    func playedInQueueOrder() {
        #expect(Policy.recentPlayedIndices(queueCount: 10, currentIndex: 5, shuffledIndices: nil, shufflePosition: 0, limit: 3) == [2, 3, 4])
        #expect(Policy.recentPlayedIndices(queueCount: 10, currentIndex: 1, shuffledIndices: nil, shufflePosition: 0, limit: 3) == [0])
        #expect(Policy.recentPlayedIndices(queueCount: 10, currentIndex: 0, shuffledIndices: nil, shufflePosition: 0, limit: 3).isEmpty)
        #expect(Policy.recentPlayedIndices(queueCount: 0, currentIndex: 0, shuffledIndices: nil, shufflePosition: 0, limit: 3).isEmpty)
    }

    @Test("随机时左边按本轮播放顺序，最近放的在最右")
    func playedInShuffleOrder() {
        let order = [7, 2, 9, 4, 0, 5]
        // 当前位置 4（队列下标 0）：之前放过 7、2、9、4，取最近三首。
        #expect(Policy.recentPlayedIndices(queueCount: 10, currentIndex: 0, shuffledIndices: order, shufflePosition: 4, limit: 3) == [2, 9, 4])
        // 越界与当前曲本身不算。
        #expect(Policy.recentPlayedIndices(queueCount: 8, currentIndex: 4, shuffledIndices: [9, 4, 1, 4], shufflePosition: 3, limit: 3) == [1])
        #expect(Policy.recentPlayedIndices(queueCount: 10, currentIndex: 7, shuffledIndices: order, shufflePosition: 0, limit: 3).isEmpty)
    }

    @Test("整条是 已放过 + 当前 + 接下来，当前曲只出现一次")
    func stripOrder() {
        #expect(Policy.stripIndices(played: [2, 3, 4], currentIndex: 5, upcoming: [6, 7], queueCount: 10) == [2, 3, 4, 5, 6, 7])
        #expect(Policy.stripIndices(played: [5, 1], currentIndex: 5, upcoming: [1, 5, 12, 6], queueCount: 10) == [1, 5, 6])
        #expect(Policy.stripIndices(played: [], currentIndex: 3, upcoming: [], queueCount: 10) == [3])
        #expect(Policy.stripIndices(played: [0], currentIndex: 10, upcoming: [1], queueCount: 10).isEmpty)
    }

    @Test("封面按留给它的高度取，放不下就不显示")
    func metrics() {
        // Duo 内屏竖握半折（669 宽）下半屏留出约 160：封面到上限。
        #expect(Policy.metrics(width: 669, availableHeight: 160)?.coverSide == 132)
        #expect(Policy.metrics(width: 669, availableHeight: 110)?.coverSide == 98)
        // 窄的时候不超过宽度的三成。
        #expect(Policy.metrics(width: 300, availableHeight: 200)?.coverSide == 90)
        #expect(Policy.metrics(width: 669, availableHeight: 70) == nil)
        #expect(Policy.metrics(width: .nan, availableHeight: 160) == nil)
    }

    @Test("离中心越远缩得越小，一整格以外不再缩")
    func scale() throws {
        let metrics = try #require(Policy.metrics(width: 669, availableHeight: 160))
        #expect(Policy.scale(forDistance: 0, metrics: metrics) == 1)
        #expect(Policy.scale(forDistance: 140, metrics: metrics) == 0.74)
        #expect(Policy.scale(forDistance: -400, metrics: metrics) == 0.74)
        let half = Policy.scale(forDistance: 70, metrics: metrics)
        #expect(abs(half - 0.87) < 0.0001)
    }
}
