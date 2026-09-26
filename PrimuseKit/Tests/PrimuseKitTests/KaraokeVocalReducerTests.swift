import Foundation
import Testing

@testable import PrimuseKit

@Suite("Karaoke vocal reducer")
struct KaraokeVocalReducerTests {
    static let sampleRate = 44_100.0

    /// Deterministic pseudo-random noise so runs are repeatable.
    struct Noise {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2_000_001 - 1_000_000) / 1_000_000
        }
    }

    static func sine(_ frequency: Double, _ index: Int, amplitude: Float = 0.3) -> Float {
        amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
    }

    /// Runs the reducer over whole signals in render-sized chunks.
    static func run(
        _ reducer: KaraokeVocalReducer,
        left: inout [Float],
        right: inout [Float],
        vocal: inout [Float],
        active: Bool,
        reduction: Float,
        chunk: Int = 512
    ) {
        var offset = 0
        while offset < left.count {
            let count = min(chunk, left.count - offset)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    vocal.withUnsafeMutableBufferPointer { v in
                        reducer.process(
                            left: l.baseAddress! + offset,
                            right: r.baseAddress! + offset,
                            frameCount: count,
                            isActive: active,
                            reduction: reduction,
                            vocal: v.baseAddress! + offset
                        )
                    }
                }
            }
            offset += count
        }
    }

    static func energy(_ signal: ArraySlice<Float>) -> Double {
        signal.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, signal.count))
    }

    /// Projection of a signal onto a sine/cosine pair: the amplitude of that
    /// frequency, independent of everything else in the signal.
    static func toneAmplitude(_ signal: ArraySlice<Float>, frequency: Double) -> Double {
        var s = 0.0, c = 0.0
        for (offset, value) in signal.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(signal.startIndex + offset) / sampleRate
            s += Double(value) * sin(phase)
            c += Double(value) * cos(phase)
        }
        return 2 * (s * s + c * c).squareRoot() / Double(signal.count)
    }

    @Test("FFT round trip reproduces the input")
    func fftRoundTrip() {
        let fft = KaraokeComplexFFT(size: 64)
        var noise = Noise(state: 7)
        var real = (0..<64).map { _ in noise.next() }
        var imag = (0..<64).map { _ in noise.next() }
        let originalReal = real, originalImag = imag
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                fft.forward(real: r.baseAddress!, imag: i.baseAddress!)
                fft.inverse(real: r.baseAddress!, imag: i.baseAddress!)
            }
        }
        for index in 0..<64 {
            #expect(abs(real[index] / 64 - originalReal[index]) < 1e-5)
            #expect(abs(imag[index] / 64 - originalImag[index]) < 1e-5)
        }
    }

    @Test("FFT puts a pure tone in its own bin")
    func fftTone() {
        let fft = KaraokeComplexFFT(size: 32)
        var real = (0..<32).map { Float(cos(2 * Double.pi * 4 * Double($0) / 32)) }
        var imag = [Float](repeating: 0, count: 32)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                fft.forward(real: r.baseAddress!, imag: i.baseAddress!)
            }
        }
        #expect(abs(real[4] - 16) < 1e-3)
        #expect(abs(real[28] - 16) < 1e-3)
        #expect(abs(real[5]) < 1e-3)
    }

    @Test("Inactive reducer leaves audio untouched")
    func bypassIsTransparent() {
        let reducer = KaraokeVocalReducer(sampleRate: Self.sampleRate)
        var left = (0..<4_000).map { Self.sine(440, $0) }
        var right = left
        var vocal = [Float](repeating: 1, count: left.count)
        let original = left
        Self.run(reducer, left: &left, right: &right, vocal: &vocal, active: false, reduction: 1)
        #expect(left == original)
        #expect(right == original)
        #expect(vocal.allSatisfy { $0 == 0 })
        #expect(reducer.phase == .bypassed)
    }

    @Test("Zero reduction reconstructs the input after the latency")
    func zeroReductionIsDelayedIdentity() {
        let reducer = KaraokeVocalReducer(sampleRate: Self.sampleRate)
        var noise = Noise(state: 1)
        let count = 30_000
        let sourceLeft = (0..<count).map { Self.sine(330, $0) + 0.1 * noise.next() }
        let sourceRight = (0..<count).map { Self.sine(550, $0) + 0.1 * noise.next() }
        var left = sourceLeft, right = sourceRight
        var vocal = [Float](repeating: 0, count: count)
        Self.run(reducer, left: &left, right: &right, vocal: &vocal, active: true, reduction: 0)

        let latency = reducer.latencySamples
        #expect(reducer.phase == .processing)
        // Well after the fade-in, output == input delayed by the latency.
        var maxError: Float = 0
        for index in 10_000..<count {
            maxError = max(maxError, abs(left[index] - sourceLeft[index - latency]))
            maxError = max(maxError, abs(right[index] - sourceRight[index - latency]))
        }
        #expect(maxError < 1e-4, "max error \(maxError)")
        var bestShift = 0
        var bestError = Float.infinity
        for shift in (latency - 600)...(latency + 600) {
            var e: Float = 0
            for index in 10_000..<10_400 { e = max(e, abs(left[index] - sourceLeft[index - shift])) }
            if e < bestError { bestError = e; bestShift = shift }
        }
        #expect(bestShift == latency, "best shift \(bestShift) error \(bestError)")
    }

    @Test("Centre tone is removed, a hard-panned tone and the bass survive")
    func removesCentreKeepsSides() {
        let reducer = KaraokeVocalReducer(sampleRate: Self.sampleRate)
        var noise = Noise(state: 3)
        let count = 60_000
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let voice = Self.sine(880, index)       // centre, in the vocal band
            let bass = Self.sine(60, index)         // centre, below the band
            let guitar = Self.sine(1_320, index)    // left only
            left[index] = voice + bass + guitar + 0.05 * noise.next()
            right[index] = voice + bass + 0.05 * noise.next()
        }
        let sourceLeft = left
        var vocal = [Float](repeating: 0, count: count)
        Self.run(reducer, left: &left, right: &right, vocal: &vocal, active: true, reduction: 1)

        let tail = 30_000..<count
        let voiceBefore = Self.toneAmplitude(sourceLeft[tail], frequency: 880)
        let voiceAfter = Self.toneAmplitude(left[tail], frequency: 880)
        let guitarAfter = Self.toneAmplitude(left[tail], frequency: 1_320)
        let bassAfter = Self.toneAmplitude(left[tail], frequency: 60)
        #expect(voiceAfter < voiceBefore * 0.15, "voice \(voiceBefore) → \(voiceAfter)")
        #expect(guitarAfter > 0.27, "guitar \(guitarAfter)")
        #expect(bassAfter > 0.27, "bass \(bassAfter)")
        // The removed voice appears in the vocal estimate.
        #expect(Self.toneAmplitude(vocal[tail], frequency: 880) > 0.2)
        #expect(!reducer.isEffectivelyMono)
    }

    @Test("A mono recording is detected and left intact")
    func monoGuard() {
        let reducer = KaraokeVocalReducer(sampleRate: Self.sampleRate)
        var noise = Noise(state: 5)
        let count = 60_000
        let mono = (0..<count).map { Self.sine(880, $0) + 0.1 * noise.next() }
        var left = mono, right = mono
        var vocal = [Float](repeating: 0, count: count)
        Self.run(reducer, left: &left, right: &right, vocal: &vocal, active: true, reduction: 1)
        #expect(reducer.isEffectivelyMono)
        let tail = 40_000..<count
        #expect(Self.toneAmplitude(left[tail], frequency: 880) > 0.25)
    }

    @Test("A near-mono mix does not flip the mono verdict back and forth")
    func nearMonoVerdictIsStable() {
        let reducer = KaraokeVocalReducer(sampleRate: Self.sampleRate)
        var noise = Noise(state: 11)
        let count = Int(Self.sampleRate * 8)
        let block = Int(Self.sampleRate / 4)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let voice = Self.sine(880, index) + 0.02 * noise.next()
            // A faint one-sided part that comes and goes every 0.25 s keeps the
            // width hovering around the mono threshold.
            let side: Float = (index / block) % 2 == 0 ? 0 : Self.sine(1_320, index, amplitude: 0.09)
            left[index] = voice + side
            right[index] = voice
        }
        var vocal = [Float](repeating: 0, count: count)
        var flips = 0
        var last = reducer.isEffectivelyMono
        var offset = 0
        while offset < count {
            let chunk = min(512, count - offset)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    vocal.withUnsafeMutableBufferPointer { v in
                        reducer.process(
                            left: l.baseAddress! + offset,
                            right: r.baseAddress! + offset,
                            frameCount: chunk,
                            isActive: true,
                            reduction: 1,
                            vocal: v.baseAddress! + offset
                        )
                    }
                }
            }
            if reducer.isEffectivelyMono != last {
                flips += 1
                last = reducer.isEffectivelyMono
            }
            offset += chunk
        }
        #expect(flips <= 1, "verdict flipped \(flips) times")

        // Loudness settles instead of pumping between hollowed and full.
        let blocks = stride(from: 2 * block, to: count - block, by: block).map {
            Self.energy(left[$0..<($0 + block)])
        }
        let settled = blocks.suffix(16)
        let ratio = (settled.max() ?? 0) / max(1e-12, settled.min() ?? 0)
        #expect(ratio < 2, "block energy ratio \(ratio)")
    }

    @Test("Switching on and off never produces a jump")
    func transitionsAreSmooth() {
        let reducer = KaraokeVocalReducer(sampleRate: Self.sampleRate)
        var noise = Noise(state: 9)
        let count = 40_000
        var left = (0..<count).map { Self.sine(440, $0) + 0.05 * noise.next() }
        var right = (0..<count).map { Self.sine(440, $0) + 0.05 * noise.next() }
        var vocal = [Float](repeating: 0, count: count)

        // On for the first half, off for the second half.
        var firstLeft = Array(left[0..<20_000]), firstRight = Array(right[0..<20_000])
        var firstVocal = Array(vocal[0..<20_000])
        Self.run(reducer, left: &firstLeft, right: &firstRight, vocal: &firstVocal, active: true, reduction: 1)
        var secondLeft = Array(left[20_000...]), secondRight = Array(right[20_000...])
        var secondVocal = Array(vocal[20_000...])
        Self.run(reducer, left: &secondLeft, right: &secondRight, vocal: &secondVocal, active: false, reduction: 1)
        left = firstLeft + secondLeft
        right = firstRight + secondRight

        var largestStep: Float = 0
        for index in 1..<count {
            largestStep = max(largestStep, abs(left[index] - left[index - 1]))
        }
        // A 440 Hz, 0.3 sine moves at most ~0.019 per sample; noise adds ~0.1.
        #expect(largestStep < 0.2)
        #expect(reducer.phase == .bypassed)
    }
}

extension KaraokeVocalReducerTests {
    @Test("A discontinuity drops the delay line and fades in from silence")
    func discontinuityRestart() {
        let reducer = KaraokeVocalReducer(sampleRate: Self.sampleRate)
        var noise = Noise(state: 11)
        var left = (0..<20_000).map { _ in 0.3 * noise.next() }
        var right = (0..<20_000).map { _ in 0.3 * noise.next() }
        var vocal = [Float](repeating: 0, count: 20_000)
        Self.run(reducer, left: &left, right: &right, vocal: &vocal, active: true, reduction: 1)
        #expect(reducer.phase == .processing)

        reducer.restartAfterDiscontinuity()
        #expect(reducer.phase == .priming)
        var afterLeft = [Float](repeating: 0.5, count: 5_000)
        var afterRight = [Float](repeating: -0.5, count: 5_000)
        var afterVocal = [Float](repeating: 0, count: 5_000)
        Self.run(reducer, left: &afterLeft, right: &afterRight, vocal: &afterVocal, active: true, reduction: 1)
        // Silent while priming: neither the old position nor the dry vocal.
        #expect(afterLeft[0..<reducer.latencySamples].allSatisfy { $0 == 0 })
        #expect(reducer.phase == .processing)
        #expect(abs(afterLeft[4_999] - 0.5) < 0.01)

        let idle = KaraokeVocalReducer(sampleRate: Self.sampleRate)
        idle.restartAfterDiscontinuity()
        #expect(idle.phase == .bypassed)
    }
}
