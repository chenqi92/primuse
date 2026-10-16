import Foundation
import Testing
@testable import PrimuseKit

@Suite("Offline source cache tally")
struct OfflineSourceCacheTallyTests {
    @Test("Progress follows the recorded sizes, counting earlier caches and in-flight parts")
    func byteProgress() {
        var tally = OfflineSourceCacheTally(sizes: [100, 100, 600, 200])
        #expect(tally.knownBytes == 1_000)
        #expect(tally.fraction(inFlightBytes: 0) == 0)

        // 开始前就缓存过的两首一开始就算下完。
        tally.record(size: 100, completed: true)
        tally.record(size: 100, completed: true)
        #expect(tally.fraction(inFlightBytes: 0) == 0.2)
        // 大文件下到一半:进度跟着走,剩余里也扣掉。
        #expect(tally.fraction(inFlightBytes: 300) == 0.5)
        #expect(tally.downloadedBytes(inFlightBytes: 300) == 500)
        #expect(tally.remainingBytes(inFlightBytes: 300) == 500)

        tally.record(size: 600, completed: true)
        tally.record(size: 200, completed: false)
        // 失败的算处理过,进度到头;已下载里不算它。
        #expect(tally.fraction(inFlightBytes: 0) == 1)
        #expect(tally.downloadedBytes(inFlightBytes: 0) == 800)
        #expect(tally.remainingBytes(inFlightBytes: 0) == 0)
        #expect(tally.completedCount == 3)
        #expect(tally.failedCount == 1)
        #expect(tally.handledCount == tally.totalCount)

        // 多记的一次不会超过总数。
        tally.record(size: 100, completed: true)
        #expect(tally.handledCount == 4)
    }

    @Test("Without recorded sizes progress counts songs; cancelling is remembered")
    func countProgressAndCancel() {
        var tally = OfflineSourceCacheTally(sizes: [0, 0, 0, 0])
        #expect(tally.unknownCount == 4)
        #expect(tally.fraction(inFlightBytes: 0) == 0)
        tally.record(size: 0, completed: true)
        #expect(tally.fraction(inFlightBytes: 0) == 0.25)
        #expect(!tally.wasCancelled)
        tally.markCancelled()
        #expect(tally.wasCancelled)
        #expect(OfflineSourceCacheTally(sizes: []).fraction(inFlightBytes: 0) == nil)
    }
}
