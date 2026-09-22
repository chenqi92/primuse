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

@Suite("Diagnostic logging policy")
struct DiagnosticLoggingPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("Turning on stores an expiry, clamped to the allowed hours")
    func enabling() {
        let hours = DiagnosticLoggingPolicy.resolve(request: "6", storedExpiry: nil, now: now)
        #expect(hours.isActive)
        #expect(hours.change == .enabled(until: now.addingTimeInterval(6 * 3600)))

        let fallback = DiagnosticLoggingPolicy.resolve(request: "on", storedExpiry: nil, now: now)
        #expect(fallback.expiresAt == now.addingTimeInterval(24 * 3600))

        let clamped = DiagnosticLoggingPolicy.resolve(request: "999", storedExpiry: nil, now: now)
        #expect(clamped.expiresAt == now.addingTimeInterval(72 * 3600))
        let floor = DiagnosticLoggingPolicy.resolve(request: "-5", storedExpiry: nil, now: now)
        #expect(floor.expiresAt == now.addingTimeInterval(3600))
    }

    @Test("A stored window survives relaunches until it expires")
    func storedWindow() {
        let later = now.addingTimeInterval(3600)
        let running = DiagnosticLoggingPolicy.resolve(request: nil, storedExpiry: later, now: now)
        #expect(running.isActive)
        #expect(running.change == .unchanged)

        let expired = DiagnosticLoggingPolicy.resolve(request: "", storedExpiry: now, now: now)
        #expect(!expired.isActive)
        #expect(expired.change == .expired)
    }

    @Test("Turning off only reports a change when something was on")
    func disabling() {
        let later = now.addingTimeInterval(3600)
        #expect(DiagnosticLoggingPolicy.resolve(request: "off", storedExpiry: later, now: now)
            == .init(expiresAt: nil, change: .disabled))
        #expect(DiagnosticLoggingPolicy.resolve(request: " OFF ", storedExpiry: nil, now: now)
            == .init(expiresAt: nil, change: .unchanged))
        #expect(!DiagnosticLoggingPolicy.resolve(request: "0", storedExpiry: later, now: now).isActive)
        #expect(DiagnosticLoggingPolicy.resolve(request: nil, storedExpiry: nil, now: now)
            == .init(expiresAt: nil, change: .unchanged))
    }

    @Test("Standard limits keep the previous behaviour; diagnostic limits are larger")
    func limits() {
        let standard = DiagnosticLoggingPolicy.limits(isActive: false)
        #expect(standard.maxFileBytes == 10_000_000)
        #expect(standard.rotatedGenerations == 1)
        #expect(standard.backlogLimit == LogBacklogPolicy.maximumPendingEntries)
        let diagnostic = DiagnosticLoggingPolicy.limits(isActive: true)
        #expect(diagnostic.maxFileBytes > standard.maxFileBytes)
        #expect(diagnostic.rotatedGenerations > standard.rotatedGenerations)
        #expect(diagnostic.backlogLimit > standard.backlogLimit)
    }

    @Test("Rotation shifts from the oldest generation towards the current file")
    func rotationMoves() {
        let one = DiagnosticLoggingPolicy.rotationMoves(generations: 1)
        #expect(one == [.init(from: 0, to: 1)])
        let three = DiagnosticLoggingPolicy.rotationMoves(generations: 3)
        #expect(three == [.init(from: 2, to: 3), .init(from: 1, to: 2), .init(from: 0, to: 1)])
        let zero = DiagnosticLoggingPolicy.rotationMoves(generations: 0)
        #expect(zero == one)
    }
}
