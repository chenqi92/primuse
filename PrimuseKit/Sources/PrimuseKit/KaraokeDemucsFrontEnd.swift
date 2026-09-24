import Foundation

/// The parts of Hybrid Transformer Demucs that run outside the Core ML
/// model: the spectrogram it expects, the inverse transform of its output,
/// and the overlapping segments a whole song is cut into.
///
/// Everything mirrors the reference PyTorch code (`HTDemucs._spec`,
/// `_ispec`, `_magnitude`, `_mask` with complex-as-channels, and
/// `apply_model(split=True)`) so the model sees exactly what it was trained
/// on. The transforms are parameterised only so tests can compare small
/// sizes against PyTorch; production uses `standard`.
public struct KaraokeDemucsLayout: Equatable, Sendable {
    public var sampleRate: Double
    public var fftSize: Int
    public var hopLength: Int
    /// Samples per model call (7.8 s at 44.1 kHz).
    public var segmentLength: Int
    /// Share of each segment that overlaps the next.
    public var overlap: Double

    public init(sampleRate: Double, fftSize: Int, hopLength: Int, segmentLength: Int, overlap: Double) {
        precondition(hopLength * 4 == fftSize)
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.hopLength = hopLength
        self.segmentLength = segmentLength
        self.overlap = overlap
    }

    public static let standard = KaraokeDemucsLayout(
        sampleRate: 44_100,
        fftSize: 4_096,
        hopLength: 1_024,
        segmentLength: 343_980,
        overlap: 0.25
    )

    /// Frequency bins the model sees (the Nyquist bin is dropped).
    public var bins: Int { fftSize / 2 }

    public func frames(forLength length: Int) -> Int {
        (length + hopLength - 1) / hopLength
    }
}

/// Complex-as-channels spectrogram of a stereo segment and its inverse.
/// Channel order is left-real, left-imaginary, right-real, right-imaginary;
/// storage is `[channel][bin][frame]`, row-major.
public final class KaraokeDemucsSpectrogram: @unchecked Sendable {
    public let layout: KaraokeDemucsLayout
    private let fft: KaraokeComplexFFT
    private let window: [Float]
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>

    public init(layout: KaraokeDemucsLayout = .standard) {
        self.layout = layout
        let n = layout.fftSize
        fft = KaraokeComplexFFT(size: n)
        // torch.hann_window is periodic by default.
        window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        real = .allocate(capacity: n)
        imag = .allocate(capacity: n)
        real.initialize(repeating: 0, count: n)
        imag.initialize(repeating: 0, count: n)
    }

    deinit {
        real.deallocate()
        imag.deallocate()
    }

    /// Reflect padding as `torch.nn.functional.pad(mode: "reflect")`, with
    /// Demucs' fallback of zero padding first when the signal is too short.
    static func reflectPadded(_ x: [Float], left: Int, right: Int) -> [Float] {
        var source = x
        var padLeft = left
        var padRight = right
        let maxPad = max(left, right)
        if source.count <= maxPad {
            let extra = maxPad - source.count + 1
            let extraRight = min(right, extra)
            let extraLeft = extra - extraRight
            source = [Float](repeating: 0, count: extraLeft) + source + [Float](repeating: 0, count: extraRight)
            padLeft -= extraLeft
            padRight -= extraRight
        }
        let n = source.count
        var result = [Float](repeating: 0, count: padLeft + n + padRight)
        for i in 0..<padLeft { result[i] = source[padLeft - i] }
        for i in 0..<n { result[padLeft + i] = source[i] }
        for i in 0..<padRight { result[padLeft + n + i] = source[n - 2 - i] }
        return result
    }

    /// `HTDemucs._spec` followed by `_magnitude` (complex as channels).
    public func forward(left: [Float], right: [Float]) -> [Float] {
        precondition(left.count == right.count)
        let length = left.count
        let hop = layout.hopLength
        let n = layout.fftSize
        let bins = layout.bins
        let frames = layout.frames(forLength: length)
        let pad = hop / 2 * 3
        let rightPad = pad + frames * hop - length

        // Demucs pad, then torch.stft's own centring pad.
        let l = Self.reflectPadded(Self.reflectPadded(left, left: pad, right: rightPad), left: n / 2, right: n / 2)
        let r = Self.reflectPadded(Self.reflectPadded(right, left: pad, right: rightPad), left: n / 2, right: n / 2)

        let scale = 1 / Float(n).squareRoot()
        var output = [Float](repeating: 0, count: 4 * bins * frames)
        output.withUnsafeMutableBufferPointer { out in
            for frame in 0..<frames {
                // Demucs keeps stft frames 2 ..< 2 + frames.
                let start = (frame + 2) * hop
                for i in 0..<n {
                    real[i] = l[start + i] * window[i]
                    imag[i] = r[start + i] * window[i]
                }
                fft.forward(real: real, imag: imag)
                for bin in 0..<bins {
                    let mirror = bin == 0 ? 0 : n - bin
                    let a = real[bin], b = imag[bin], c = real[mirror], d = imag[mirror]
                    // Unpack L + iR into the two one-sided spectra.
                    let lr = (a + c) * 0.5 * scale
                    let li = (b - d) * 0.5 * scale
                    let rr = (b + d) * 0.5 * scale
                    let ri = (c - a) * 0.5 * scale
                    out[(0 * bins + bin) * frames + frame] = lr
                    out[(1 * bins + bin) * frames + frame] = li
                    out[(2 * bins + bin) * frames + frame] = rr
                    out[(3 * bins + bin) * frames + frame] = ri
                }
            }
        }
        return output
    }

    /// `HTDemucs._mask` (complex as channels) followed by `_ispec`.
    public func inverse(spectrum: [Float], length: Int) -> (left: [Float], right: [Float]) {
        let hop = layout.hopLength
        let n = layout.fftSize
        let bins = layout.bins
        let frames = layout.frames(forLength: length)
        precondition(spectrum.count == 4 * bins * frames)
        let pad = hop / 2 * 3
        let paddedLength = hop * frames + 2 * pad
        // Two zero frames on each side (F.pad(z, (2, 2))).
        let totalFrames = frames + 4
        // torch.istft: centred output of (totalFrames - 1) * hop samples.
        let fullLength = n + hop * (totalFrames - 1)
        var left = [Float](repeating: 0, count: fullLength)
        var right = [Float](repeating: 0, count: fullLength)
        var envelope = [Float](repeating: 0, count: fullLength)
        let scale = Float(n).squareRoot() / Float(n)

        for frame in 0..<totalFrames {
            let source = frame - 2
            if source >= 0, source < frames {
                // Build Z = L + iR over the full circle from the one-sided
                // spectra; the Nyquist bin was dropped and stays zero.
                for i in 0..<n { real[i] = 0; imag[i] = 0 }
                for bin in 0..<bins {
                    let lr = spectrum[(0 * bins + bin) * frames + source]
                    let li = spectrum[(1 * bins + bin) * frames + source]
                    let rr = spectrum[(2 * bins + bin) * frames + source]
                    let ri = bin == 0 ? 0 : spectrum[(3 * bins + bin) * frames + source]
                    let liUsed = bin == 0 ? 0 : li
                    real[bin] = lr - ri
                    imag[bin] = liUsed + rr
                    if bin > 0 {
                        let mirror = n - bin
                        real[mirror] = lr + ri
                        imag[mirror] = rr - liUsed
                    }
                }
                fft.inverse(real: real, imag: imag)
                let start = frame * hop
                for i in 0..<n {
                    let w = window[i]
                    left[start + i] += real[i] * scale * w
                    right[start + i] += imag[i] * scale * w
                }
            }
            let start = frame * hop
            for i in 0..<n {
                envelope[start + i] += window[i] * window[i]
            }
        }

        // Undo the stft centring pad, then the Demucs pad.
        let offset = n / 2 + pad
        var outLeft = [Float](repeating: 0, count: length)
        var outRight = [Float](repeating: 0, count: length)
        for i in 0..<length {
            let index = offset + i
            guard index < fullLength, index - n / 2 < paddedLength else { break }
            let weight = envelope[index]
            if weight > 1e-11 {
                outLeft[i] = left[index] / weight
                outRight[i] = right[index] / weight
            }
        }
        return (outLeft, outRight)
    }
}

/// How a song is cut into model-sized segments and stitched back together
/// (`apply_model(split: true)`): overlapping segments, each weighted by a
/// triangle peaking at its centre.
public struct KaraokeSeparationPlan: Sendable {
    public struct Segment: Equatable, Sendable {
        /// Where this segment's output lands in the song.
        public var offset: Int
        /// Output samples it contributes (shorter at the end of the song).
        public var length: Int
        /// First song sample of the model input window; may be negative or
        /// run past the end, where the input is zero.
        public var windowStart: Int
        /// Where the contributed samples begin inside the model output.
        public var trim: Int
    }

    public let layout: KaraokeDemucsLayout
    public let totalLength: Int
    public let segments: [Segment]
    public let weight: [Float]

    public init(totalLength: Int, layout: KaraokeDemucsLayout = .standard) {
        self.layout = layout
        self.totalLength = totalLength
        let segmentLength = layout.segmentLength
        let stride = Int((1 - layout.overlap) * Double(segmentLength))
        var segments: [Segment] = []
        var offset = 0
        while offset < totalLength {
            let length = min(totalLength - offset, segmentLength)
            let delta = segmentLength - length
            segments.append(Segment(
                offset: offset,
                length: length,
                windowStart: offset - delta / 2,
                trim: delta / 2
            ))
            offset += stride
        }
        self.segments = segments
        let half = segmentLength / 2
        var triangle = (1...half).map(Float.init)
        triangle += (1...(segmentLength - half)).reversed().map(Float.init)
        let peak = triangle.max() ?? 1
        weight = triangle.map { $0 / peak }
    }

    /// The zero-padded model input window of `segment` from one channel.
    public func window(_ segment: Segment, of channel: [Float]) -> [Float] {
        var result = [Float](repeating: 0, count: layout.segmentLength)
        let lower = max(0, segment.windowStart)
        let upper = min(totalLength, segment.windowStart + layout.segmentLength)
        if lower < upper {
            for i in lower..<upper {
                result[i - segment.windowStart] = channel[i]
            }
        }
        return result
    }
}

/// Collects weighted segment outputs into one stereo stem.
public struct KaraokeSeparationAccumulator: Sendable {
    public let plan: KaraokeSeparationPlan
    private var left: [Float]
    private var right: [Float]
    private var weights: [Float]

    public init(plan: KaraokeSeparationPlan) {
        self.plan = plan
        left = [Float](repeating: 0, count: plan.totalLength)
        right = left
        weights = left
    }

    /// Adds one segment's model output (full segment length per channel).
    public mutating func add(_ segment: KaraokeSeparationPlan.Segment, left outLeft: [Float], right outRight: [Float]) {
        for i in 0..<segment.length {
            let w = plan.weight[i]
            left[segment.offset + i] += w * outLeft[segment.trim + i]
            right[segment.offset + i] += w * outRight[segment.trim + i]
            weights[segment.offset + i] += w
        }
    }

    public func finish() -> (left: [Float], right: [Float]) {
        var l = left
        var r = right
        for i in 0..<l.count where weights[i] > 0 {
            l[i] /= weights[i]
            r[i] /= weights[i]
        }
        return (l, r)
    }
}
