import Foundation
import Testing
@testable import PrimuseKit

@Suite("Immersive frame rate policy")
struct ImmersiveFrameRatePolicyTests {
    @Test("Unknown or missing stored values fall back to the balanced default")
    func storedValueFallback() {
        #expect(ImmersiveFrameRateMode(storedValue: nil) == .balanced)
        #expect(ImmersiveFrameRateMode(storedValue: "120hz") == .balanced)
        #expect(ImmersiveFrameRateMode(storedValue: "display") == .display)
        #expect(ImmersiveFrameRateMode(storedValue: "fps60") == .fps60)
    }

    @Test("Balanced keeps every layer's tuned interval; fixed modes only speed layers up")
    func timelineIntervals() {
        #expect(ImmersiveFrameRateMode.balanced.minimumInterval(base: 1.0 / 15.0) == 1.0 / 15.0)
        #expect(ImmersiveFrameRateMode.fps30.minimumInterval(base: 1.0 / 15.0) == 1.0 / 30.0)
        #expect(ImmersiveFrameRateMode.fps30.minimumInterval(base: 1.0 / 60.0) == 1.0 / 60.0)
        #expect(ImmersiveFrameRateMode.fps60.minimumInterval(base: 1.0 / 24.0) == 1.0 / 60.0)
        #expect(ImmersiveFrameRateMode.display.minimumInterval(base: 1.0 / 24.0) == nil)
    }

    @Test("Spectrum pacing follows the mode and clamps the display rate")
    func spectrumPacing() {
        #expect(ImmersiveFrameRateMode.balanced.spectrumPacing(displayMaximumFramesPerSecond: 120)
            == .onArrival(pollInterval: 0.04))
        #expect(ImmersiveFrameRateMode.fps60.spectrumPacing(displayMaximumFramesPerSecond: 120)
            == .paced(interval: 1.0 / 60.0))
        #expect(ImmersiveFrameRateMode.display.spectrumPacing(displayMaximumFramesPerSecond: 120)
            == .paced(interval: 1.0 / 120.0))
        #expect(ImmersiveFrameRateMode.display.spectrumPacing(displayMaximumFramesPerSecond: 240)
            == .paced(interval: 1.0 / 120.0))
        #expect(ImmersiveFrameRateMode.display.spectrumPacing(displayMaximumFramesPerSecond: 0)
            == .paced(interval: 1.0 / 30.0))
    }
}

@Suite("Spectrum sample ring")
struct SpectrumSampleRingTests {
    private func window(_ ring: SpectrumSampleRing, end: Int64, count: Int) -> [Float] {
        var output = [Float](repeating: -1, count: count)
        output.withUnsafeMutableBufferPointer { buffer in
            ring.copyWindow(endingAt: end, count: count, into: buffer.baseAddress!)
        }
        return output
    }

    private func write(_ ring: SpectrumSampleRing, _ values: [Float], stride: Int = 1, at uptime: UInt64 = 1) {
        values.withUnsafeBufferPointer { buffer in
            _ = ring.write(
                buffer.baseAddress!,
                frameCount: values.count / stride,
                stride: stride,
                uptimeNanoseconds: uptime
            )
        }
    }

    @Test("Windows wrap around the ring and zero-fill frames that are not there")
    func wrapAndZeroFill() {
        let ring = SpectrumSampleRing(capacityPowerOfTwo: 10)
        write(ring, (0..<1000).map(Float.init))
        write(ring, (1000..<1100).map(Float.init), at: 7)

        let state = ring.state()
        #expect(state == .init(written: 1100, latestBurst: 100, arrivalUptime: 7))
        #expect(window(ring, end: 1100, count: 4) == [1096, 1097, 1098, 1099])
        // 第 0…75 帧已被覆盖，第 1100 帧以后还没写到。
        #expect(window(ring, end: 78, count: 4) == [0, 0, 76, 77])
        #expect(window(ring, end: 1102, count: 4) == [1098, 1099, 0, 0])
        #expect(window(ring, end: 1, count: 3) == [0, 0, 0])
    }

    @Test("Interleaved input keeps only the first channel")
    func interleavedInput() {
        let ring = SpectrumSampleRing(capacityPowerOfTwo: 10)
        write(ring, [1, -1, 2, -2, 3, -3], stride: 2)
        #expect(ring.state().written == 3)
        #expect(window(ring, end: 3, count: 3) == [1, 2, 3])
    }

    @Test("An oversized burst keeps its newest frames and still counts all of them")
    func oversizedBurst() {
        let ring = SpectrumSampleRing(capacityPowerOfTwo: 10)
        write(ring, (0..<1500).map(Float.init))
        #expect(ring.state().written == 1500)
        #expect(window(ring, end: 1500, count: 2) == [1498, 1499])
        #expect(window(ring, end: 477, count: 2) == [0, 476])
    }

    @Test("Reset clears both samples and counters")
    func reset() {
        let ring = SpectrumSampleRing(capacityPowerOfTwo: 10)
        write(ring, [1, 2, 3])
        ring.reset()
        #expect(ring.state() == .init(written: 0, latestBurst: 0, arrivalUptime: 0))
        #expect(window(ring, end: 3, count: 3) == [0, 0, 0])
    }
}

@Suite("Spectrum playout cursor")
struct SpectrumPlayoutCursorTests {
    private let sampleRate = 48_000.0
    private let burst = 4_800
    private let second: UInt64 = 1_000_000_000

    private func state(written: Int64, arrival: UInt64) -> SpectrumSampleRing.State {
        .init(written: written, latestBurst: burst, arrivalUptime: arrival)
    }

    @Test("100 ms bursts turn into a distinct window every 1/60 s")
    func pacesBurstsAtDisplayRate() {
        var cursor = SpectrumPlayoutCursor()
        var ends: [Int64] = []
        // 每 100 ms 到一批 4800 帧，按 60 Hz 取 2 秒。
        for frame in 0..<120 {
            let now = UInt64(frame) * second / 60 + second / 2
            let batches = Int64(now / (second / 10))
            let arrival = UInt64(batches) * (second / 10)
            let current = state(written: batches * Int64(burst), arrival: arrival)
            if let step = cursor.advance(state: current, nowUptime: now, sampleRate: sampleRate) {
                ends.append(step.end)
            }
        }
        // 匀速：除了开头，每一帧都前进约 800 帧，从不后退也不原地停。
        #expect(ends.count >= 118)
        let steps = zip(ends.dropFirst(), ends).map { $0 - $1 }
        #expect(steps.allSatisfy { (790...810).contains($0) })
    }

    @Test("The cursor trails the newest sample by one burst plus the jitter margin")
    func trailsOneBurst() {
        var cursor = SpectrumPlayoutCursor()
        let arrival: UInt64 = 10 * second
        let written: Int64 = 48_000
        let step = cursor.advance(state: state(written: written, arrival: arrival), nowUptime: arrival, sampleRate: sampleRate)
        let margin = Int64(sampleRate * SpectrumPlayoutCursor.jitterMargin)
        #expect(step?.end == written - Int64(burst) - margin)
    }

    @Test("A late batch holds the window instead of running past the data or going back")
    func lateBatchHolds() {
        var cursor = SpectrumPlayoutCursor()
        let arrival: UInt64 = 10 * second
        let current = state(written: 48_000, arrival: arrival)
        let first = cursor.advance(state: current, nowUptime: arrival, sampleRate: sampleRate)
        // 下一批迟到了 50 ms：位置停在已写入的末尾，不越界。
        let late = cursor.advance(state: current, nowUptime: arrival + second * 3 / 20, sampleRate: sampleRate)
        #expect(late?.end == 48_000)
        #expect(cursor.advance(state: current, nowUptime: arrival + second / 5, sampleRate: sampleRate) == nil)
        // 迟到的那批到了以后重新以它为锚，位置略微靠后，在追上之前不发布。
        let recovered = state(written: 52_800, arrival: arrival + second * 3 / 20)
        #expect(cursor.advance(state: recovered, nowUptime: arrival + second * 3 / 20, sampleRate: sampleRate) == nil)
        #expect(first != nil)
    }

    @Test("A restarted stream starts over instead of waiting for the old position")
    func restartedStream() {
        var cursor = SpectrumPlayoutCursor()
        _ = cursor.advance(state: state(written: 480_000, arrival: 5 * second), nowUptime: 5 * second, sampleRate: sampleRate)
        let restarted = cursor.advance(
            state: state(written: 9_600, arrival: 6 * second),
            nowUptime: 6 * second + second / 10,
            sampleRate: sampleRate
        )
        #expect(restarted != nil)
        #expect(restarted?.advancedFrames == 0)
    }

    @Test("No samples yet means nothing to publish")
    func emptyStream() {
        var cursor = SpectrumPlayoutCursor()
        #expect(cursor.advance(state: .init(written: 0, latestBurst: 0, arrivalUptime: 0), nowUptime: second, sampleRate: sampleRate) == nil)
        #expect(cursor.advance(state: state(written: 4_800, arrival: second), nowUptime: second, sampleRate: 0) == nil)
    }
}

@Suite("Spectrum temporal smoothing")
struct SpectrumTemporalSmoothingTests {
    @Test("The reference interval reproduces the per-analysis coefficient")
    func referenceInterval() {
        #expect(abs(SpectrumTemporalSmoothing.blend(base: 0.72, elapsed: 0.1, reference: 0.1) - 0.72) < 0.000_01)
        #expect(SpectrumTemporalSmoothing.blend(base: 0.72, elapsed: nil, reference: 0.1) == 0.72)
    }

    @Test("Six steps at 1/60 s add up to one 0.1 s step")
    func compoundsOverTime() {
        let step = SpectrumTemporalSmoothing.blend(base: 0.18, elapsed: 0.1 / 6, reference: 0.1)
        var value: Float = 0
        for _ in 0..<6 { value += (1 - value) * step }
        #expect(abs(value - 0.18) < 0.0001)
        #expect(step < 0.18)
    }
}
