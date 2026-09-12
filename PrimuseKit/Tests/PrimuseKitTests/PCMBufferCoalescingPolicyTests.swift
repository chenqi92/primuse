import Foundation
import Testing
@testable import PrimuseKit

@Suite("PCM buffer coalescing")
struct PCMBufferCoalescingPolicyTests {
    private static let dtsKey = "48000.0|2|1|false"
    private static let otherKey = "44100.0|2|1|false"

    @Test("The first flush happens at 1024 frames so playback still starts fast")
    func firstFlushUsesSmallThreshold() {
        var plan = PCMBufferCoalescingPlan()
        // DTS 一帧 512 个样本。
        #expect(plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .buffer)
        #expect(plan.accumulatedFrames == 512)
        #expect(!plan.hasFlushedOnce)
        #expect(plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .appendThenFlush)
        #expect(plan.accumulatedFrames == 0)
        #expect(plan.hasFlushedOnce)
    }

    @Test("After the first flush a 512-frame stream flushes every 16 inputs")
    func steadyStateFlushesAtTargetFrameCount() {
        var plan = PCMBufferCoalescingPlan()
        #expect(plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .buffer)
        #expect(plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .appendThenFlush)

        for round in 0..<3 {
            for index in 1...16 {
                let action = plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey)
                if index == 16 {
                    #expect(action == .appendThenFlush, "round \(round) input \(index)")
                    #expect(plan.accumulatedFrames == 0)
                } else {
                    #expect(action == .buffer, "round \(round) input \(index)")
                    #expect(plan.accumulatedFrames == 512 * index)
                }
            }
        }
    }

    @Test("A buffer that already meets the threshold passes through uncopied")
    func nativeSizedInputPassesThrough() {
        var plan = PCMBufferCoalescingPlan()
        #expect(plan.absorb(incomingFrames: 8192, formatKey: Self.dtsKey) == .passThrough)
        #expect(plan.accumulatedFrames == 0)
        #expect(plan.hasFlushedOnce)
        // 稳定阶段同样大小的输入仍然直通。
        #expect(plan.absorb(incomingFrames: 8192, formatKey: Self.dtsKey) == .passThrough)
        #expect(plan.accumulatedFrames == 0)
    }

    @Test("Pending frames are flushed before a format change starts accumulating")
    func formatChangeFlushesPendingFrames() {
        var plan = PCMBufferCoalescingPlan()
        #expect(plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .buffer)
        #expect(plan.absorb(incomingFrames: 600, formatKey: Self.otherKey) == .flushThenBuffer)
        #expect(plan.accumulatedFrames == 600)
        #expect(plan.formatKey == Self.otherKey)
    }

    @Test("A format change with an empty accumulator just keeps buffering")
    func formatChangeWithoutPendingFramesDoesNotFlush() {
        var plan = PCMBufferCoalescingPlan()
        #expect(plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .buffer)
        #expect(plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .appendThenFlush)
        #expect(plan.absorb(incomingFrames: 300, formatKey: Self.otherKey) == .buffer)
        #expect(plan.accumulatedFrames == 300)
    }

    @Test("finish() reports a remainder only when frames are pending")
    func finishReportsPendingFramesOnly() {
        var empty = PCMBufferCoalescingPlan()
        #expect(!empty.finish())

        var pending = PCMBufferCoalescingPlan()
        #expect(pending.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .buffer)
        #expect(pending.finish())

        var flushed = PCMBufferCoalescingPlan()
        #expect(flushed.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .buffer)
        #expect(flushed.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .appendThenFlush)
        #expect(!flushed.finish())
    }

    @Test("finish() resets the plan for the next stream")
    func finishResetsState() {
        var plan = PCMBufferCoalescingPlan()
        #expect(plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .buffer)
        #expect(plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .appendThenFlush)
        #expect(plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .buffer)
        #expect(plan.finish())

        #expect(plan.accumulatedFrames == 0)
        #expect(!plan.hasFlushedOnce)
        #expect(plan.formatKey == nil)
        // 复位后重新按首次阈值起步。
        #expect(plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .buffer)
        #expect(plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .appendThenFlush)
    }

    @Test("An empty input changes nothing")
    func zeroFrameInputIsIgnored() {
        var plan = PCMBufferCoalescingPlan()
        #expect(plan.absorb(incomingFrames: 512, formatKey: Self.dtsKey) == .buffer)
        #expect(plan.absorb(incomingFrames: 0, formatKey: Self.otherKey) == .buffer)
        #expect(plan.accumulatedFrames == 512)
        #expect(plan.formatKey == Self.dtsKey)
        #expect(!plan.hasFlushedOnce)
    }

    @Test("A custom policy drives both thresholds")
    func customPolicyThresholds() {
        let policy = PCMBufferCoalescingPolicy(
            targetFrameCount: 2048,
            firstFlushFrameCount: 256
        )
        var plan = PCMBufferCoalescingPlan(policy: policy)
        #expect(plan.flushThreshold == 256)
        #expect(plan.absorb(incomingFrames: 128, formatKey: Self.dtsKey) == .buffer)
        #expect(plan.absorb(incomingFrames: 128, formatKey: Self.dtsKey) == .appendThenFlush)
        #expect(plan.flushThreshold == 2048)
        for _ in 1..<16 {
            #expect(plan.absorb(incomingFrames: 128, formatKey: Self.dtsKey) == .buffer)
        }
        #expect(plan.absorb(incomingFrames: 128, formatKey: Self.dtsKey) == .appendThenFlush)
    }

    @Test("Accumulated frames never exceed the target plus one input")
    func accumulationStaysBounded() {
        var plan = PCMBufferCoalescingPlan()
        var peak = 0
        for _ in 0..<200 {
            _ = plan.absorb(incomingFrames: 1000, formatKey: Self.dtsKey)
            peak = max(peak, plan.accumulatedFrames)
        }
        #expect(peak <= PCMBufferCoalescingPolicy.targetFrameCount + 1000)
    }
}
