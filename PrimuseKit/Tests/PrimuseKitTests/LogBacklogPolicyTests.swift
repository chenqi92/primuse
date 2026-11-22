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

    @Test("A repeat summary carries the repeated line's source and last repeat time, not the next line's")
    func repeatSummaryCarriesRepeatedLineSource() {
        var coalescer = LogDuplicateCoalescer()
        let start = Date(timeIntervalSince1970: 1_000)
        func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }
        let watch = "WatchConnectivityService:412"
        let intent = "ListeningIntentService:88"
        let first = coalescer.absorb(key: "\(watch) deliver payload", line: "deliver payload", source: watch, at: at(0))
        #expect(first == [.init(text: "deliver payload", source: watch, timestamp: at(0), isRepeatSummary: false)])
        for repeatIndex in 1...28 {
            #expect(coalescer.absorb(key: "\(watch) deliver payload", line: "deliver payload",
                                     source: watch, at: at(Double(repeatIndex))).isEmpty)
        }
        // 打断重复的是另一处的一行:汇总仍记在 Watch 那一行名下,时间是第 28 次重复的时间。
        let produced = coalescer.absorb(key: "\(intent) plan", line: "plan", source: intent, at: at(60))
        #expect(produced.count == 2)
        #expect(produced[0].isRepeatSummary)
        #expect(produced[0].text.contains("重复 28 次"))
        #expect(produced[0].source == watch)
        #expect(produced[0].timestamp == at(28))
        #expect(produced[1] == .init(text: "plan", source: intent, timestamp: at(60), isRepeatSummary: false))
    }

    @Test("Periodic and final summaries also name the repeated line")
    func periodicAndFlushedSummariesNameRepeatedLine() {
        var coalescer = LogDuplicateCoalescer(flushEvery: 3)
        let source = "ScanService:6150"
        let start = Date(timeIntervalSince1970: 50)
        _ = coalescer.absorb(key: "k", line: "loop", source: source, at: start)
        var periodic: [LogDuplicateCoalescer.Emission] = []
        for offset in 1...4 {
            periodic += coalescer.absorb(key: "k", line: "loop", source: source, at: start.addingTimeInterval(Double(offset)))
        }
        #expect(periodic.count == 1)
        #expect(periodic.first?.source == source)
        #expect(periodic.first?.timestamp == start.addingTimeInterval(3))
        let flushed = coalescer.flushEmissions()
        #expect(flushed.count == 1)
        #expect(flushed.first?.text.contains("重复 1 次") == true)
        #expect(flushed.first?.source == source)
        #expect(flushed.first?.timestamp == start.addingTimeInterval(4))
        #expect(coalescer.flushEmissions().isEmpty)
    }

    @Test("After dropped lines the pending repeat summary comes first, so timestamps never go backwards")
    func droppedLinesKeepTimestampsInOrder() {
        var coalescer = LogDuplicateCoalescer()
        let start = Date(timeIntervalSince1970: 5_000)
        let loop = "MetadataBackfillService:900"
        _ = coalescer.absorb(key: "loop", line: "read tag", source: loop, at: start)
        for offset in 1...5 {
            _ = coalescer.absorb(key: "loop", line: "read tag", source: loop, at: start.addingTimeInterval(Double(offset)))
        }
        let next = start.addingTimeInterval(30)
        let produced = coalescer.absorb(
            key: "other", line: "scan done", source: "ScanService:10", at: next,
            droppedBefore: 1_234, droppedSource: "FileLogger"
        )
        #expect(produced.map(\.text).count == 3)
        #expect(produced[0].isRepeatSummary)
        #expect(produced[0].text.contains("重复 5 次"))
        #expect(produced[0].source == loop)
        #expect(produced[1].text == LogBacklogPolicy.droppedSummary(count: 1_234))
        #expect(produced[1].source == "FileLogger")
        #expect(produced[2].text == "scan done")
        #expect(zip(produced, produced.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp })
        // 丢过行之后,同一行再来按新行写,不接着算成前面的重复。
        let again = coalescer.absorb(
            key: "other", line: "scan done", source: "ScanService:10", at: next.addingTimeInterval(1),
            droppedBefore: 3, droppedSource: "FileLogger"
        )
        #expect(again.map(\.text) == [LogBacklogPolicy.droppedSummary(count: 3), "scan done"])
        // 没丢过行时与普通吸收相同。
        #expect(coalescer.absorb(key: "x", line: "x", source: "s", at: next, droppedBefore: 0, droppedSource: "FileLogger")
            .map(\.text) == ["x"])
    }

    @Test("A repeat summary that triggers rotation stays in the file holding its repeated line")
    func repeatSummaryStaysBeforeRotation() {
        var coalescer = LogDuplicateCoalescer()
        let now = Date(timeIntervalSince1970: 9_000)
        _ = coalescer.absorb(key: "a", line: "loop", source: "A:1", at: now)
        _ = coalescer.absorb(key: "a", line: "loop", source: "A:1", at: now)
        let produced = coalescer.absorb(key: "b", line: "next", source: "B:2", at: now)
        #expect(produced.count == 2)
        #expect(LogRotationPlacement.writesBeforeRotation(produced[0]))
        #expect(!LogRotationPlacement.writesBeforeRotation(produced[1]))
        let dropped = coalescer.absorb(key: "c", line: "c", source: "C:3", at: now, droppedBefore: 2, droppedSource: "FileLogger")
        #expect(!dropped.contains { LogRotationPlacement.writesBeforeRotation($0) })
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
