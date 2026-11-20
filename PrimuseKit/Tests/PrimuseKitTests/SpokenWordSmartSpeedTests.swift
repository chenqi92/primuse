import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken word smart speed")
struct SpokenWordSmartSpeedTests {
    private let sampleRate = 48_000.0
    private var frames: SmartSpeedPolicy.Frames { SmartSpeedPolicy.standard.frames(sampleRate: sampleRate) }

    // MARK: - Synthetic PCM

    /// 说话:-20 dBFS 左右的正弦,左右声道相位略不同。
    private func speech(_ seconds: Double, phase: Double = 0) -> [[Float]] {
        let count = Int(seconds * sampleRate)
        let left = (0..<count).map { Float(0.1 * sin(2 * Double.pi * 220 * Double($0) / sampleRate + phase)) }
        let right = (0..<count).map { Float(0.1 * sin(2 * Double.pi * 330 * Double($0) / sampleRate + phase)) }
        return [left, right]
    }

    /// 停顿里的底噪:给定电平(dBFS)的方波式抖动,确定性的。
    private func silence(_ seconds: Double, levelDB: Double = -60) -> [[Float]] {
        let count = Int(seconds * sampleRate)
        let amplitude = Float(pow(10, levelDB / 20))
        let samples = (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
        return [samples, samples]
    }

    private func concat(_ parts: [[[Float]]]) -> [[Float]] {
        var result: [[Float]] = [[], []]
        for part in parts {
            result[0] += part[0]
            result[1] += part[1]
        }
        return result
    }

    /// 整段一次喂完再 finish,返回拼起来的输出与所有接缝(接缝换算成整段输出里的位置)。
    private func run(
        _ input: [[Float]],
        chunkSizes: [Int]? = nil,
        policy: SmartSpeedPolicy = .standard
    ) -> (output: [[Float]], cuts: [SmartSpeedCut]) {
        var shortener = SmartSpeedSilenceShortener(policy: policy, sampleRate: sampleRate, channelCount: 2)
        var output: [[Float]] = [[], []]
        var cuts: [SmartSpeedCut] = []
        func take(_ chunk: SmartSpeedChunk) {
            for cut in chunk.cuts {
                #expect(cut.frameOffset < chunk.frameCount)
                cuts.append(SmartSpeedCut(frameOffset: output[0].count + cut.frameOffset, removedFrames: cut.removedFrames))
            }
            output[0] += chunk.channels[0]
            output[1] += chunk.channels[1]
        }
        let total = input[0].count
        var position = 0
        var sizeIndex = 0
        while position < total {
            let size = chunkSizes.map { $0[sizeIndex % $0.count] } ?? total
            sizeIndex += 1
            let end = min(total, position + max(1, size))
            take(shortener.process([Array(input[0][position..<end]), Array(input[1][position..<end])]))
            position = end
        }
        take(shortener.finish())
        return (output, cuts)
    }

    // MARK: - Shortening

    @Test func continuousSpeechPassesThroughUnchanged() {
        let input = speech(3)
        let result = run(input)
        #expect(result.cuts.isEmpty)
        #expect(result.output == input)
    }

    @Test func shortPausesAreKept() {
        let input = concat([speech(1), silence(0.3), speech(1)])
        let result = run(input)
        #expect(result.cuts.isEmpty)
        #expect(result.output == input)
    }

    @Test func longPauseIsShortenedToTheKeptAmount() {
        let pause = 3.0
        let input = concat([speech(1), silence(pause), speech(1, phase: 0.5)])
        let result = run(input)
        #expect(result.cuts.count == 1)
        let removed = result.cuts.reduce(0) { $0 + $1.removedFrames }
        #expect(result.output[0].count == input[0].count - removed)

        // 剩下的停顿 = 开头保留 + 说话前保留 + 超出部分的一成(封顶)。
        let pauseFrames = Int(pause * sampleRate)
        let beyondHead = pauseFrames - frames.head
        let extra = min(frames.maximumExtra, Int(Double(beyondHead - frames.tail) * frames.retainedRatio))
        let keptPause = frames.head + frames.tail + extra
        // 窗口粒度:误差不超过一个窗口。
        #expect(abs((pauseFrames - removed) - keptPause) <= frames.window)
    }

    @Test func speechSamplesSurviveExactly() {
        let before = speech(1)
        let after = speech(1, phase: 0.5)
        let input = concat([before, silence(2), after])
        let result = run(input)
        let speechFrames = before[0].count
        #expect(Array(result.output[0].prefix(speechFrames)) == before[0])
        #expect(Array(result.output[1].suffix(after[1].count)) == after[1])
    }

    @Test func seamIsFadedOnBothSides() throws {
        let input = concat([speech(1), silence(2, levelDB: -50), speech(1)])
        let result = run(input)
        let cut = try #require(result.cuts.first)
        let left = result.output[0]
        // 接缝前最后一帧淡到接近 0,接缝后第一帧从接近 0 起。
        let amplitude = Float(pow(10, -50.0 / 20))
        #expect(abs(left[cut.frameOffset - 1]) < amplitude * 0.05)
        #expect(abs(left[cut.frameOffset]) < amplitude * 0.05)
        // 淡变之外的静音原样。
        #expect(abs(left[cut.frameOffset + frames.fade + 1]) == amplitude)
    }

    @Test func chunkingDoesNotChangeTheResult() {
        let input = concat([speech(0.7), silence(1.6), speech(0.4), silence(0.2), speech(0.5), silence(4), speech(0.3)])
        let whole = run(input)
        for sizes in [[37], [480], [4_096, 17, 1_000], [10_000, 3]] {
            let chunked = run(input, chunkSizes: sizes)
            #expect(chunked.output == whole.output)
            #expect(chunked.cuts == whole.cuts)
        }
        #expect(whole.cuts.count == 2)
    }

    @Test func trailingSilenceAtEndOfStreamIsShortenedAndFlushed() {
        let input = concat([speech(1), silence(5)])
        let result = run(input)
        #expect(result.cuts.count == 1)
        let removed = result.cuts.reduce(0) { $0 + $1.removedFrames }
        #expect(removed > Int(4 * sampleRate))
        #expect(result.output[0].count == input[0].count - removed)
        // 接缝后面还有帧(说话前保留的那段)。
        #expect(result.cuts[0].frameOffset < result.output[0].count)
    }

    @Test func leadingSilenceIsShortened() {
        let input = concat([silence(2), speech(1)])
        let result = run(input)
        #expect(result.cuts.count == 1)
        #expect(Array(result.output[0].suffix(Int(sampleRate))) == speech(1)[0])
    }

    @Test func quietSpeechAboveThresholdIsNotCut() {
        // -35 dBFS 的底噪高于 -42 dBFS 的门限:不算停顿。
        let input = concat([speech(1), silence(2, levelDB: -35), speech(1)])
        let result = run(input)
        #expect(result.cuts.isEmpty)
        #expect(result.output == input)
    }

    @Test func nonFiniteSamplesCountAsAudible() {
        var noisy = silence(2)
        noisy[0][1_000] = .nan
        let input = concat([speech(0.5), noisy, speech(0.5)])
        let result = run(input)
        // 坏样本所在的窗口当有声,两边各自不够长的话就不动;够长的照样缩短,但不会崩。
        let removed = result.cuts.reduce(0) { $0 + $1.removedFrames }
        #expect(result.output[0].count == input[0].count - removed)
    }

    @Test func removedTotalMatchesCuts() {
        let input = concat([speech(0.5), silence(1.5), speech(0.5), silence(3), speech(0.5)])
        var shortener = SmartSpeedSilenceShortener(sampleRate: sampleRate, channelCount: 2)
        var removed = 0
        removed += shortener.process(input).removedFrames
        removed += shortener.finish().removedFrames
        #expect(Int64(removed) == shortener.totalRemovedFrames)
        #expect(removed > 0)
    }

    @Test func unsafePointerInputMatchesArrayInput() {
        let input = concat([speech(0.5), silence(2), speech(0.5)])
        var a = SmartSpeedSilenceShortener(sampleRate: sampleRate, channelCount: 2)
        var b = SmartSpeedSilenceShortener(sampleRate: sampleRate, channelCount: 2)
        let fromArrays = a.process(input)
        let fromPointers = input[0].withUnsafeBufferPointer { left in
            input[1].withUnsafeBufferPointer { right in
                b.process(channels: [left, right])
            }
        }
        #expect(fromArrays == fromPointers)
        #expect(a.finish() == b.finish())
    }

    @Test func policyFramesKeepFadesInsideTheKeptSilence() {
        let tiny = SmartSpeedPolicy(
            silenceThresholdDB: -42, windowDuration: 0.01,
            keptLeadingSilence: 0, keptTrailingSilence: 0, minimumCut: 0,
            retainedRatio: 2, maximumRetainedExtra: -1, fadeDuration: 0.005
        )
        let converted = tiny.frames(sampleRate: sampleRate)
        #expect(converted.head >= converted.fade)
        #expect(converted.tail >= converted.fade)
        #expect(converted.minimumCut >= 1)
        #expect(converted.retainedRatio <= 0.9)
        #expect(converted.maximumExtra == 0)
    }

    // MARK: - Timeline

    @Test func timelineMapsPlayedFramesBackToFileFrames() {
        var timeline = SmartSpeedTimeline()
        timeline.record(cutAt: 1_000, removedFrames: 500)
        timeline.record(cutAt: 3_000, removedFrames: 200)
        // 第一处接缝之前不变。
        #expect(timeline.sourceFrames(playedFrame: 999, sampleTimeOffset: 0) == 999)
        // 正好到接缝:它之前拿掉的已经算上。
        #expect(timeline.sourceFrames(playedFrame: 1_000, sampleTimeOffset: 0) == 1_500)
        #expect(timeline.sourceFrames(playedFrame: 2_999, sampleTimeOffset: 0) == 3_499)
        #expect(timeline.sourceFrames(playedFrame: 4_000, sampleTimeOffset: 0) == 4_700)
    }

    @Test func timelineAfterSeekStartsAtTheSeekTarget() {
        var timeline = SmartSpeedTimeline()
        timeline.record(cutAt: 100, removedFrames: 50)
        // 跳到第 10_000 帧:零点在节点时间线的 -10_000 处。
        #expect(timeline.sourceFrames(playedFrame: 0, sampleTimeOffset: -10_000) == 10_000)
        #expect(timeline.sourceFrames(playedFrame: 200, sampleTimeOffset: -10_000) == 10_250)
    }

    @Test func gaplessSuccessorOnlyCountsItsOwnCuts() {
        var timeline = SmartSpeedTimeline()
        // 上一首的接缝。
        timeline.record(cutAt: 500, removedFrames: 300)
        // 下一首从节点第 1_000 帧开始,第一块开头就有一处接缝。
        timeline.record(cutAt: 1_000, removedFrames: 40)
        timeline.record(cutAt: 1_500, removedFrames: 60)
        #expect(timeline.sourceFrames(playedFrame: 1_000, sampleTimeOffset: 1_000) == 40)
        #expect(timeline.sourceFrames(playedFrame: 1_600, sampleTimeOffset: 1_000) == 700)
        #expect(timeline.removedFrames(from: 1_000, through: 1_600) == 100)
    }

    @Test func timelineMergesCutsAtTheSameFrame() {
        var timeline = SmartSpeedTimeline()
        timeline.record(cutAt: 10, removedFrames: 5)
        timeline.record(cutAt: 10, removedFrames: 7)
        timeline.record(cutAt: 20, removedFrames: 0)
        #expect(timeline.count == 1)
        #expect(timeline.removedFrames(from: 0, through: 10) == 12)
    }

    @Test func discardingOldCutsKeepsLaterQueriesExact() {
        var timeline = SmartSpeedTimeline()
        timeline.record(cutAt: 10, removedFrames: 5)
        timeline.record(cutAt: 20, removedFrames: 3)
        timeline.record(cutAt: 30, removedFrames: 2)
        let before = timeline.removedFrames(from: 15, through: 40)
        timeline.discard(before: 15)
        #expect(timeline.count == 2)
        #expect(timeline.removedFrames(from: 15, through: 40) == before)
        #expect(timeline.removedFrames(from: 25, through: 40) == 2)
        timeline.discard(before: 100)
        #expect(timeline.isEmpty)
        #expect(timeline.removedFrames(from: 100, through: 200) == 0)
        timeline.reset()
        timeline.record(cutAt: 5, removedFrames: 1)
        #expect(timeline.removedFrames(from: 0, through: 5) == 1)
    }

    @Test func shortenerCutsMapBackToTheOriginalPosition() {
        // 处理过的输出排在节点上,按接缝表映射回去的位置要落回原文件里同一段说话。
        let first = speech(1)
        let second = speech(1, phase: 0.5)
        let input = concat([first, silence(3), second])
        let result = run(input)
        var timeline = SmartSpeedTimeline()
        for cut in result.cuts {
            timeline.record(cutAt: Int64(cut.frameOffset), removedFrames: Int64(cut.removedFrames))
        }
        let secondStartInOutput = Int64(result.output[0].count - second[0].count)
        let secondStartInFile = Int64(input[0].count - second[0].count)
        #expect(timeline.sourceFrames(playedFrame: secondStartInOutput, sampleTimeOffset: 0) == secondStartInFile)
        let lastPlayed = Int64(result.output[0].count - 1)
        #expect(timeline.sourceFrames(playedFrame: lastPlayed, sampleTimeOffset: 0) == Int64(input[0].count - 1))
    }

    // MARK: - Saved time

    @Test func savingsMeterCountsOnlyNewSkipsAtTheListeningRate() {
        var meter = SmartSpeedSavingsMeter()
        #expect(meter.record(skipped: 0, rate: 1) == 0)
        #expect(meter.record(skipped: 2, rate: 1) == 2)
        #expect(meter.record(skipped: 2, rate: 1) == 0)
        // 1.5 倍速下拿掉 3 秒文件时长,省下 2 秒收听时间。
        #expect(meter.record(skipped: 5, rate: 1.5) == 2)
        // 跳转后从零重新算:只换基准,不倒扣。
        #expect(meter.record(skipped: 0.5, rate: 1) == 0)
        #expect(meter.record(skipped: 1.5, rate: 1) == 1)
        // 异常读数不计。
        #expect(meter.record(skipped: .nan, rate: 1) == 0)
        #expect(meter.record(skipped: 10_000, rate: 1) == 0)
        #expect(meter.record(skipped: 10_001, rate: 0) == 1)
    }
}
