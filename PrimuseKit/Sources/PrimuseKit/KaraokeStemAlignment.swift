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

    /// 对齐的那一段里,播放信号含了多少倍的人声轨(最小二乘)。人声轨是从原文件分离的,
    /// 播放时 ReplayGain 在消除单元之前就把整首调了音量,原样减去会减多(或减少)、
    /// 留下一份反相的人声;按这个比例缩放后再减才对得上。伴奏和人声不相关,
    /// 在投影里只是噪声。这一段几乎没唱(人声轨太轻)时没有意义,返回 nil。
    ///
    /// - Parameters:
    ///   - live: 对齐用的那一段播放信号(单声道)。
    ///   - excerpt: `match` 用的人声轨片段,从 `excerptStart` 起。
    ///   - stemIndex: `match` 找到的位置。
    public static func gain(live: [Float], excerpt: [Float], excerptStart: Int, stemIndex: Int) -> Double? {
        let offset = stemIndex - excerptStart
        guard !live.isEmpty, offset >= 0, offset + live.count <= excerpt.count else { return nil }
        var cross = 0.0
        var energy = 0.0
        for index in 0..<live.count {
            let stem = Double(excerpt[offset + index])
            cross += Double(live[index]) * stem
            energy += stem * stem
        }
        // 均方低于约 -50 dBFS 的人声轨算没唱。
        guard energy / Double(live.count) > 1e-5 else { return nil }
        let gain = cross / energy
        return gain.isFinite && gain > 0 ? gain : nil
    }
}

/// 把逐次对齐算出的比例(`KaraokeStemAligner.gain`)收成一个稳定的值:取最近几次的中位数,
/// 单次被伴奏带偏的估计动不了它;攒够几次才算数,之前按 1 减。
public struct KaraokeStemGainEstimator: Equatable, Sendable {
    /// 参与中位数的最近几次。
    public static let window = 7
    /// 攒够这么多次才采用。
    public static let minimumCount = 3
    /// 单次估计的合理范围:ReplayGain 正常在 ±20 dB 内,超出的是算坏了。
    public static let range: ClosedRange<Double> = 0.1...4

    private var recent: [Double] = []

    public init() {}

    public var isSettled: Bool { recent.count >= Self.minimumCount }

    public mutating func record(_ gain: Double) {
        guard gain.isFinite, Self.range.contains(gain) else { return }
        recent.append(gain)
        if recent.count > Self.window { recent.removeFirst(recent.count - Self.window) }
    }

    /// 减人声轨时乘的比例;还没攒够时为 1(不缩放)。
    public var scale: Double {
        guard isSettled else { return 1 }
        let sorted = recent.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    public mutating func reset() {
        recent.removeAll()
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
        var data = encodedHeader(sampleRate: sampleRate, frames: left.count)
        data.reserveCapacity(headerSize + left.count * 4)
        var samples = [Int16](repeating: 0, count: left.count * 2)
        for i in 0..<left.count {
            samples[2 * i] = quantize(left[i]).littleEndian
            samples[2 * i + 1] = quantize(right[i]).littleEndian
        }
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    private static func encodedHeader(sampleRate: Double, frames: Int) -> Data {
        var data = Data(capacity: headerSize)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(magic)
        append(formatVersion)
        append(UInt32(sampleRate.rounded()))
        append(UInt32(frames))
        return data
    }

    public final class Writer {
        public enum Failure: Error, Equatable {
            case invalidHeader
            case invalidFrameCount
            case alreadyFinished
        }

        private var handle: FileHandle?
        private let expectedFrames: Int
        public private(set) var writtenFrames = 0

        public init(url: URL, sampleRate: Double, frames: Int) throws {
            guard sampleRate.isFinite, sampleRate.rounded() > 0,
                  sampleRate.rounded() <= Double(UInt32.max),
                  frames >= 0, frames <= Int(UInt32.max) else {
                throw Failure.invalidHeader
            }
            expectedFrames = frames
            try encodedHeader(sampleRate: sampleRate, frames: frames)
                .write(to: url, options: .withoutOverwriting)
            let file = try FileHandle(forWritingTo: url)
            try file.seekToEnd()
            handle = file
        }

        deinit {
            try? handle?.close()
        }

        public func append(left: [Float], right: [Float]) throws {
            guard let handle else { throw Failure.alreadyFinished }
            guard left.count == right.count, left.count <= expectedFrames - writtenFrames else {
                throw Failure.invalidFrameCount
            }
            let capacity = min(left.count, 8_192)
            var samples = [Int16](repeating: 0, count: capacity * 2)
            var offset = 0
            while offset < left.count {
                let count = min(capacity, left.count - offset)
                for i in 0..<count {
                    samples[i * 2] = quantize(left[offset + i]).littleEndian
                    samples[i * 2 + 1] = quantize(right[offset + i]).littleEndian
                }
                try samples.withUnsafeBytes { bytes in
                    try handle.write(contentsOf: Data(bytes.prefix(count * 4)))
                }
                offset += count
            }
            writtenFrames += left.count
        }

        public func finish() throws {
            guard let handle else { throw Failure.alreadyFinished }
            guard writtenFrames == expectedFrames else { throw Failure.invalidFrameCount }
            try handle.synchronize()
            try handle.close()
            self.handle = nil
        }
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

    public static func decodeFrames(_ data: Data, range: Range<Int>) -> (left: [Float], right: [Float])? {
        guard let header = header(of: data),
              range.lowerBound >= 0, range.upperBound <= header.frames else { return nil }
        var left = [Float](repeating: 0, count: range.count)
        var right = left
        let scale: Float = 1 / 32_767
        data.withUnsafeBytes { raw in
            for (i, frame) in range.enumerated() {
                let base = headerSize + frame * 4
                left[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: base, as: Int16.self))) * scale
                right[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: base + 2, as: Int16.self))) * scale
            }
        }
        return (left, right)
    }

    public static func decodeMono(_ data: Data) -> (header: Header, samples: [Float])? {
        guard let header = header(of: data) else { return nil }
        var samples = [Float](repeating: 0, count: header.frames)
        let scale: Float = 1 / 32_767
        data.withUnsafeBytes { raw in
            for i in 0..<header.frames {
                let base = headerSize + i * 4
                let left = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: base, as: Int16.self))) * scale
                let right = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: base + 2, as: Int16.self))) * scale
                samples[i] = (left + right) * 0.5
            }
        }
        return (header, samples)
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
