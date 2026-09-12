import Foundation
import Testing
@testable import PrimuseKit

@Suite("Log backlog policy")
struct LogBacklogPolicyTests {
    @Test("Pending entries below the limit are admitted")
    func admitsBelowLimit() {
        #expect(LogBacklogPolicy.admits(pendingCount: 0, limit: 3))
        #expect(LogBacklogPolicy.admits(pendingCount: 2, limit: 3))
        #expect(LogBacklogPolicy.admits(pendingCount: LogBacklogPolicy.maximumPendingEntries - 1))
    }

    @Test("Pending entries at or above the limit are rejected")
    func rejectsAtAndAboveLimit() {
        #expect(!LogBacklogPolicy.admits(pendingCount: 3, limit: 3))
        #expect(!LogBacklogPolicy.admits(pendingCount: 9, limit: 3))
        #expect(!LogBacklogPolicy.admits(pendingCount: LogBacklogPolicy.maximumPendingEntries))
    }

    @Test("Dropped summary is one line carrying the count")
    func droppedSummaryCarriesCount() {
        let summary = LogBacklogPolicy.droppedSummary(count: 1234)
        #expect(summary.contains("1234"))
        #expect(summary.contains("丢弃"))
        #expect(!summary.contains("\n"))
    }
}

@Suite("Log duplicate coalescer")
struct LogDuplicateCoalescerTests {
    @Test("Distinct lines pass through unchanged and in order")
    func distinctLinesPassThrough() {
        var coalescer = LogDuplicateCoalescer()
        #expect(coalescer.absorb(key: "a", line: "first") == ["first"])
        #expect(coalescer.absorb(key: "b", line: "second") == ["second"])
        #expect(coalescer.absorb(key: "c", line: "third") == ["third"])
        #expect(coalescer.flush().isEmpty)
    }

    @Test("Repeats are folded until the next distinct line")
    func repeatsFoldIntoSummary() {
        var coalescer = LogDuplicateCoalescer()
        #expect(coalescer.absorb(key: "a", line: "loop") == ["loop"])
        #expect(coalescer.absorb(key: "a", line: "loop").isEmpty)
        #expect(coalescer.absorb(key: "a", line: "loop").isEmpty)

        let produced = coalescer.absorb(key: "b", line: "other")
        #expect(produced.count == 2)
        #expect(produced.first?.contains("重复 2 次") == true)
        #expect(produced.last == "other")
    }

    @Test("Endless repeats still emit a summary every flushEvery hits")
    func repeatCapEmitsPeriodicSummary() {
        var coalescer = LogDuplicateCoalescer(flushEvery: 3)
        #expect(coalescer.absorb(key: "a", line: "loop") == ["loop"])

        var summaries: [String] = []
        // 9 次重复 = 3 组, 每组结束时立刻吐一条汇总, 中间没有任何不同的行。
        for _ in 0..<9 {
            summaries.append(contentsOf: coalescer.absorb(key: "a", line: "loop"))
        }
        #expect(summaries.count == 3)
        #expect(summaries.allSatisfy { $0.contains("重复 3 次") })
        // 攒够就清零, 所以此时没有待收尾的计数。
        #expect(coalescer.flush().isEmpty)
    }

    @Test("Flush emits the pending summary once and then nothing")
    func flushEmitsPendingSummaryOnce() {
        var coalescer = LogDuplicateCoalescer()
        _ = coalescer.absorb(key: "a", line: "loop")
        _ = coalescer.absorb(key: "a", line: "loop")
        _ = coalescer.absorb(key: "a", line: "loop")

        let flushed = coalescer.flush()
        #expect(flushed.count == 1)
        #expect(flushed.first?.contains("重复 2 次") == true)
        #expect(coalescer.flush().isEmpty)
        // flush 清掉了上一条 key, 同一行再来算新行。
        #expect(coalescer.absorb(key: "a", line: "loop") == ["loop"])
    }

    @Test("Alternating lines never coalesce")
    func alternatingLinesNeverCoalesce() {
        var coalescer = LogDuplicateCoalescer()
        var produced: [String] = []
        for index in 0..<6 {
            let key = index.isMultiple(of: 2) ? "a" : "b"
            produced.append(contentsOf: coalescer.absorb(key: key, line: key))
        }
        #expect(produced == ["a", "b", "a", "b", "a", "b"])
        #expect(coalescer.flush().isEmpty)
    }
}
