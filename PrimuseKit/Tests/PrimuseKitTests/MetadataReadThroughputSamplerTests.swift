import Foundation
import Testing
@testable import PrimuseKit

@Suite("Metadata read throughput sampling")
struct MetadataReadThroughputSamplerTests {

    @Test("第一次汇报只开窗，不出采样")
    func firstReportOpensTheWindow() {
        var sampler = MetadataReadThroughputSampler(window: 30)
        #expect(sampler.record(totalCompleted: 0, at: Date()) == nil)
    }

    @Test("窗口未满不出采样")
    func holdsUntilTheWindowIsFull() {
        let start = Date()
        var sampler = MetadataReadThroughputSampler(window: 30)
        _ = sampler.record(totalCompleted: 0, at: start)
        #expect(sampler.record(totalCompleted: 40, at: start.addingTimeInterval(20)) == nil)
    }

    @Test("窗口满了给出每分钟速率")
    func reportsItemsPerMinute() {
        let start = Date()
        var sampler = MetadataReadThroughputSampler(window: 30)
        _ = sampler.record(totalCompleted: 0, at: start)
        let sample = sampler.record(totalCompleted: 150, at: start.addingTimeInterval(30))
        #expect(sample?.processedInWindow == 150)
        // 30 秒读 150 首 == 300 首/分钟
        #expect(sample.map { abs($0.itemsPerMinute - 300) < 0.001 } == true)
    }

    @Test("窗口滚动，下一段独立计算")
    func rollsToTheNextWindow() {
        let start = Date()
        var sampler = MetadataReadThroughputSampler(window: 10)
        _ = sampler.record(totalCompleted: 0, at: start)
        _ = sampler.record(totalCompleted: 50, at: start.addingTimeInterval(10))
        // 第二段只读了 10 首，不能被第一段的高速率带偏
        let second = sampler.record(totalCompleted: 60, at: start.addingTimeInterval(20))
        #expect(second?.processedInWindow == 10)
        #expect(second.map { abs($0.itemsPerMinute - 60) < 0.001 } == true)
    }

    /// 换一轮读取时累计数会归零，直接相减会算出负速率。
    @Test("计数回退时作废当前窗口")
    func discardsWindowWhenCounterRestarts() {
        let start = Date()
        var sampler = MetadataReadThroughputSampler(window: 10)
        _ = sampler.record(totalCompleted: 500, at: start)
        #expect(sampler.record(totalCompleted: 0, at: start.addingTimeInterval(10)) == nil)
        let next = sampler.record(totalCompleted: 20, at: start.addingTimeInterval(20))
        #expect(next?.processedInWindow == 20)
    }

    @Test("重置后从新窗口开始")
    func resetStartsOver() {
        let start = Date()
        var sampler = MetadataReadThroughputSampler(window: 10)
        _ = sampler.record(totalCompleted: 0, at: start)
        sampler.reset()
        #expect(sampler.record(totalCompleted: 999, at: start.addingTimeInterval(10)) == nil)
    }

    @Test("完全没有进展时速率为零而不是崩掉")
    func reportsZeroWhenNothingProgressed() {
        let start = Date()
        var sampler = MetadataReadThroughputSampler(window: 5)
        _ = sampler.record(totalCompleted: 7, at: start)
        let sample = sampler.record(totalCompleted: 7, at: start.addingTimeInterval(5))
        #expect(sample?.processedInWindow == 0)
        #expect(sample?.itemsPerMinute == 0)
    }
}
