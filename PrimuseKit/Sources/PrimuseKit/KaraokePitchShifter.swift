import Foundation

/// Streaming pitch shifter (phase vocoder with frequency-domain bin
/// shifting) for karaoke key changes where no system time-pitch unit is
/// available, such as inside an AVPlayer processing tap on Apple TV.
///
/// Each frame's bins are analysed for their true frequency from the phase
/// advance, moved to `ratio` times that frequency, and resynthesised with
/// accumulated phases. Input and output run at the same rate and length;
/// the output is delayed by `latencySamples`. Allocation-free after `init`,
/// so `process` is safe on a render thread.
public final class KaraokePitchShifter: @unchecked Sendable {
    public let sampleRate: Double
    public let fftSize: Int
    public let hop: Int
    public let latencySamples: Int

    private let fft: KaraokeComplexFFT
    private let window: UnsafeMutablePointer<Float>
    private let channels: [Channel]
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let magnitude: UnsafeMutablePointer<Float>
    private let frequency: UnsafeMutablePointer<Float>
    private let synthMagnitude: UnsafeMutablePointer<Float>
    private let synthFrequency: UnsafeMutablePointer<Float>
    private let analysisPhase: UnsafeMutablePointer<Float>
    private let peaks: UnsafeMutablePointer<Int>
    private var rover: Int
    private let fifoStart: Int
    private let outputScale: Float

    /// Per-channel analysis/synthesis state.
    private final class Channel {
        let input: UnsafeMutablePointer<Float>
        let output: UnsafeMutablePointer<Float>
        let accumulator: UnsafeMutablePointer<Float>
        let lastPhase: UnsafeMutablePointer<Float>
        let sumPhase: UnsafeMutablePointer<Float>
        let size: Int

        init(size: Int) {
            self.size = size
            func buffer(_ n: Int) -> UnsafeMutablePointer<Float> {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
                p.initialize(repeating: 0, count: n)
                return p
            }
            input = buffer(size)
            output = buffer(size)
            accumulator = buffer(size * 2)
            lastPhase = buffer(size / 2 + 1)
            sumPhase = buffer(size / 2 + 1)
        }

        func clear() {
            input.update(repeating: 0, count: size)
            output.update(repeating: 0, count: size)
            accumulator.update(repeating: 0, count: size * 2)
            lastPhase.update(repeating: 0, count: size / 2 + 1)
            sumPhase.update(repeating: 0, count: size / 2 + 1)
        }

        deinit {
            input.deallocate()
            output.deallocate()
            accumulator.deallocate()
            lastPhase.deallocate()
            sumPhase.deallocate()
        }
    }

    public init(sampleRate: Double, channelCount: Int = 2, fftSize: Int = 2_048, oversampling: Int = 4) {
        precondition(fftSize & (fftSize - 1) == 0 && oversampling >= 4)
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        hop = fftSize / oversampling
        fifoStart = fftSize - hop
        latencySamples = fftSize
        rover = fftSize - hop
        fft = KaraokeComplexFFT(size: fftSize)
        func buffer(_ n: Int) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        window = buffer(fftSize)
        for i in 0..<fftSize {
            window[i] = Float(0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(fftSize)))
        }
        // Hann analysis × Hann synthesis overlap-adds to 3/8 × osamp; the
        // analysis magnitudes are doubled (one-sided spectrum).
        outputScale = 2 / (Float(fftSize / 2) * Float(oversampling)) / 0.75 / 4
        channels = (0..<max(1, channelCount)).map { _ in Channel(size: fftSize) }
        real = buffer(fftSize)
        imag = buffer(fftSize)
        let bins = fftSize / 2 + 1
        magnitude = buffer(bins)
        frequency = buffer(bins)
        synthMagnitude = buffer(bins)
        synthFrequency = buffer(bins)
        analysisPhase = buffer(bins)
        peaks = .allocate(capacity: bins)
        peaks.initialize(repeating: 0, count: bins)
    }

    deinit {
        for p in [window, real, imag, magnitude, frequency, synthMagnitude, synthFrequency, analysisPhase] {
            p.deallocate()
        }
        peaks.deallocate()
    }

    public func reset() {
        for channel in channels { channel.clear() }
        rover = fifoStart
    }

    /// Shifts `frameCount` samples of each channel in place by `semitones`.
    /// `channels` holds one pointer per channel, as many as at `init`.
    public func process(_ buffers: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>, frameCount: Int, semitones: Double) {
        let ratio = Float(pow(2, semitones / 12))
        let n = fftSize
        let latency = fifoStart
        let count = min(buffers.count, channels.count)
        for index in 0..<frameCount {
            for c in 0..<count {
                let channel = channels[c]
                channel.input[rover] = buffers[c][index]
                buffers[c][index] = channel.output[rover - latency]
            }
            rover += 1
            if rover >= n {
                rover = latency
                for c in 0..<count {
                    processFrame(channels[c], ratio: ratio)
                }
            }
        }
    }

    private func processFrame(_ channel: Channel, ratio: Float) {
        let n = fftSize
        let half = n / 2
        let osamp = Float(n / hop)
        let binHz = Float(sampleRate) / Float(n)
        let expected = 2 * Float.pi * Float(hop) / Float(n)

        for i in 0..<n {
            real[i] = channel.input[i] * window[i]
            imag[i] = 0
        }
        fft.forward(real: real, imag: imag)

        // Analysis: magnitude, phase, and true frequency of each bin from
        // its phase advance since the previous frame.
        for k in 0...half {
            let re = real[k], im = imag[k]
            magnitude[k] = 2 * (re * re + im * im).squareRoot()
            let phase = atan2f(im, re)
            analysisPhase[k] = phase
            var delta = phase - channel.lastPhase[k]
            channel.lastPhase[k] = phase
            delta -= Float(k) * expected
            delta -= 2 * Float.pi * (delta / (2 * Float.pi)).rounded()
            frequency[k] = (Float(k) + osamp * delta / (2 * Float.pi)) * binHz
        }

        // Peaks, and for every bin the peak whose region it belongs to.
        var peakCount = 0
        for k in 2..<(half - 1) where magnitude[k] > magnitude[k - 1] && magnitude[k] >= magnitude[k + 1]
            && magnitude[k] > magnitude[k - 2] && magnitude[k] >= magnitude[k + 2] {
            peaks[peakCount] = k
            peakCount += 1
        }

        // Region shifting with identity phase locking (Laroche & Dolson):
        // each peak moves to ratio × its true frequency; its region moves
        // with it by the same whole number of bins, keeping every bin's
        // phase relative to the peak, so partials stay coherent.
        for i in 0..<n { real[i] = 0; imag[i] = 0 }
        let newSumPhase = synthFrequency   // reused as scratch for this frame
        newSumPhase.update(repeating: 0, count: half + 1)
        var regionStart = 0
        for index in 0..<peakCount {
            let peak = peaks[index]
            let regionEnd = index + 1 < peakCount ? (peak + peaks[index + 1]) / 2 : half
            let target = Int((Float(peak) * ratio).rounded())
            let shift = target - peak
            guard target > 0, target < half else {
                regionStart = regionEnd + 1
                continue
            }
            // Advance the peak's synthesis phase at its new frequency.
            let newFrequency = frequency[peak] * ratio
            let peakPhase = channel.sumPhase[target] + 2 * Float.pi * newFrequency * Float(hop) / Float(sampleRate)
            newSumPhase[target] = peakPhase
            let rotation = peakPhase - analysisPhase[peak]
            for k in regionStart...regionEnd {
                let destination = k + shift
                guard destination > 0, destination < half else { continue }
                let phase = analysisPhase[k] + rotation
                real[destination] += magnitude[k] * cosf(phase)
                imag[destination] += magnitude[k] * sinf(phase)
            }
            regionStart = regionEnd + 1
        }
        channel.sumPhase.update(from: newSumPhase, count: half + 1)

        // Hermitian mirror so the inverse is real.
        for k in 1..<half {
            real[n - k] = real[k]
            imag[n - k] = -imag[k]
        }
        fft.inverse(real: real, imag: imag)

        let scale = outputScale
        for i in 0..<n {
            channel.accumulator[i] += window[i] * real[i] * scale
        }
        for i in 0..<hop {
            channel.output[i] = channel.accumulator[i]
        }
        memmove(channel.accumulator, channel.accumulator + hop, n * MemoryLayout<Float>.stride)
        (channel.accumulator + n).update(repeating: 0, count: hop)
        memmove(channel.input, channel.input + hop, (n - hop) * MemoryLayout<Float>.stride)
    }
}
