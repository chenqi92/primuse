import Foundation

/// Finds where a stretch of live playback sits inside a pre-separated vocal
/// stem, so the stem can be subtracted sample-exactly.
///
/// The live signal is the full mix; the stem is only its vocal part, so the
/// two correlate at the true offset (the vocal is a component of the mix)
/// and nowhere else. Stretches without singing correlate weakly and are
/// reported with low confidence, which is fine: they need no subtraction.
public enum KaraokeStemAligner {
    public struct Match: Equatable, Sendable {
        /// Stem index of the first sample of the live window.
        public var stemIndex: Int
        /// Normalised correlation at the match, 0...1.
        public var confidence: Double
    }

    /// Minimum confidence to lock onto a match.
    public static let lockConfidence = 0.35

    /// - Parameters:
    ///   - live: recent mono playback samples.
    ///   - stem: the whole mono vocal stem at the same sample rate.
    ///   - predictedIndex: where `live[0]` is expected in the stem.
    ///   - radius: how far either side of the prediction to search.
    public static func match(
        live: [Float],
        in stem: [Float],
        predictedIndex: Int,
        radius: Int
    ) -> Match? {
        guard let range = searchRange(
            stemLength: stem.count,
            windowLength: live.count,
            predictedIndex: predictedIndex,
            radius: radius
        ) else { return nil }
        return match(live: live, excerpt: Array(stem[range]), excerptStart: range.lowerBound)
    }

    /// The stem samples a search needs, so callers holding a large stem can
    /// hand over only that stretch.
    public static func searchRange(
        stemLength: Int,
        windowLength: Int,
        predictedIndex: Int,
        radius: Int
    ) -> Range<Int>? {
        guard windowLength >= 64, stemLength > 0 else { return nil }
        let searchStart = max(0, predictedIndex - radius)
        let searchEnd = min(stemLength - windowLength, predictedIndex + radius)
        guard searchEnd >= searchStart else { return nil }
        return searchStart..<(searchEnd + windowLength)
    }

    /// - Parameter excerpt: stem samples starting at `excerptStart`, covering
    ///   every candidate lag (see `searchRange`).
    public static func match(live: [Float], excerpt: [Float], excerptStart: Int) -> Match? {
        let windowLength = live.count
        guard windowLength >= 64, excerpt.count >= windowLength else { return nil }
        let searchStart = excerptStart
        let searchEnd = excerptStart + excerpt.count - windowLength
        let stem = excerpt
        let stemBase = excerptStart

        // Correlate the live window against the stem excerpt covering every
        // candidate lag, via FFT: corr[k] = sum_i live[i] * excerpt[k + i].
        let excerptLength = excerpt.count
        var size = 1
        while size < excerptLength + windowLength { size <<= 1 }
        let fft = KaraokeComplexFFT(size: max(size, 64))
        let n = fft.size

        var aReal = [Float](repeating: 0, count: n), aImag = aReal
        var bReal = aReal, bImag = aReal
        for i in 0..<excerptLength { aReal[i] = stem[searchStart - stemBase + i] }
        for i in 0..<windowLength { bReal[i] = live[i] }
        aReal.withUnsafeMutableBufferPointer { r in aImag.withUnsafeMutableBufferPointer { i in
            fft.forward(real: r.baseAddress!, imag: i.baseAddress!)
        } }
        bReal.withUnsafeMutableBufferPointer { r in bImag.withUnsafeMutableBufferPointer { i in
            fft.forward(real: r.baseAddress!, imag: i.baseAddress!)
        } }
        // A * conj(B)
        for k in 0..<n {
            let re = aReal[k] * bReal[k] + aImag[k] * bImag[k]
            let im = aImag[k] * bReal[k] - aReal[k] * bImag[k]
            aReal[k] = re
            aImag[k] = im
        }
        aReal.withUnsafeMutableBufferPointer { r in aImag.withUnsafeMutableBufferPointer { i in
            fft.inverse(real: r.baseAddress!, imag: i.baseAddress!)
        } }

        // Energy of each candidate stem window, from a running sum.
        var prefix = [Double](repeating: 0, count: excerptLength + 1)
        for i in 0..<excerptLength {
            let v = Double(stem[searchStart - stemBase + i])
            prefix[i + 1] = prefix[i] + v * v
        }
        let liveEnergy = live.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard liveEnergy > 1e-9 else { return nil }

        var best: Match?
        for lag in 0...(searchEnd - searchStart) {
            let stemEnergy = prefix[lag + windowLength] - prefix[lag]
            guard stemEnergy > 1e-9 else { continue }
            let correlation = Double(aReal[lag]) / Double(n)
            // Cosine similarity of the stem window with the live window. The
            // live mix also carries accompaniment, so a perfect match scores
            // below 1: it measures how much of the mix is this vocal.
            let score = correlation / (stemEnergy * liveEnergy).squareRoot()
            if score > (best?.confidence ?? 0) {
                best = Match(stemIndex: searchStart + lag, confidence: score)
            }
        }
        return best
    }
}

/// Pre-separated vocal stem on disk: a small header and 16-bit interleaved
/// stereo samples. Sixteen bits are plenty for a signal that is subtracted
/// from 24-bit-or-less audio, and halve the size of float storage.
public enum KaraokeStemFile {
    static let magic: UInt32 = 0x4B56_5354 // "KVST"
    public static let formatVersion: UInt32 = 1
    static let headerSize = 16

    public struct Header: Equatable, Sendable {
        public var sampleRate: Double
        public var frames: Int
    }

    public static func encode(left: [Float], right: [Float], sampleRate: Double) -> Data {
        precondition(left.count == right.count)
        var data = Data(capacity: headerSize + left.count * 4)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(magic)
        append(formatVersion)
        append(UInt32(sampleRate.rounded()))
        append(UInt32(left.count))
        var samples = [Int16](repeating: 0, count: left.count * 2)
        for i in 0..<left.count {
            samples[2 * i] = quantize(left[i])
            samples[2 * i + 1] = quantize(right[i])
        }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    @inline(__always)
    static func quantize(_ value: Float) -> Int16 {
        Int16(max(-32_768, min(32_767, (value * 32_767).rounded())))
    }

    public static func header(of data: Data) -> Header? {
        guard data.count >= headerSize else { return nil }
        func read(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        guard read(0) == magic, read(4) == formatVersion else { return nil }
        let frames = Int(read(12))
        guard data.count >= headerSize + frames * 4 else { return nil }
        return Header(sampleRate: Double(read(8)), frames: frames)
    }

    /// Decodes both channels, or nil for a damaged or foreign file.
    public static func decode(_ data: Data) -> (header: Header, left: [Float], right: [Float])? {
        guard let header = header(of: data) else { return nil }
        var left = [Float](repeating: 0, count: header.frames)
        var right = left
        let scale: Float = 1 / 32_767
        data.withUnsafeBytes { raw in
            for i in 0..<header.frames {
                let base = headerSize + i * 4
                left[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: base, as: Int16.self))) * scale
                right[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: base + 2, as: Int16.self))) * scale
            }
        }
        return (header, left, right)
    }
}

/// Turns individual alignment matches into a lock that a single bad match
/// cannot move: an offset is adopted only after two consecutive matches
/// agree on it, both when first locking and when correcting a lock.
public struct KaraokeStemLockPolicy: Equatable, Sendable {
    /// Offset currently trusted (stem index minus input index).
    public private(set) var lockedDelta: Int?
    private var candidate: Int?

    public init() {}

    /// Feeds one match (already converted to an offset); returns the offset
    /// to publish when the lock is established or moves.
    public mutating func record(delta: Int) -> Int? {
        if delta == lockedDelta {
            candidate = nil
            return nil
        }
        if delta == candidate {
            candidate = nil
            lockedDelta = delta
            return delta
        }
        candidate = delta
        return nil
    }

    /// Playback jumped; everything learned so far is void.
    public mutating func reset() {
        lockedDelta = nil
        candidate = nil
    }
}
