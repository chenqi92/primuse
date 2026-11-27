import Foundation

/// What a medley needs to know about a song's audio to find its chorus: per
/// half second, how loud it is and which pitch classes sound (chroma).
public struct MedleyAudioFeatures: Equatable, Sendable {
    public let frameDuration: TimeInterval
    /// Twelve values per frame, unit length; all zero for a silent frame.
    public let chroma: [Float]
    /// Mean power per frame, in dB.
    public let loudness: [Float]

    public init(frameDuration: TimeInterval, chroma: [Float], loudness: [Float]) {
        self.frameDuration = frameDuration
        self.chroma = chroma
        self.loudness = loudness
    }

    public var frameCount: Int { loudness.count }
    public var duration: TimeInterval { Double(frameCount) * frameDuration }

    /// Mean loudness between two song times, or nil when no frame lies there.
    public func meanLoudness(from start: TimeInterval, to end: TimeInterval) -> Float? {
        guard frameDuration > 0, end > start else { return nil }
        let first = max(0, Int((start / frameDuration).rounded(.down)))
        let last = min(frameCount, Int((end / frameDuration).rounded(.up)))
        guard last > first else { return nil }
        var sum: Float = 0
        for index in first..<last { sum += loudness[index] }
        return sum / Float(last - first)
    }
}

/// Turns decoded mono samples into `MedleyAudioFeatures` as they arrive, so a
/// whole song never has to be held in memory.
public final class MedleyAudioFeatureExtractor {
    /// The rate the players decode to for analysis: chroma needs nothing above
    /// about 5 kHz, and a quarter of CD rate keeps the work small.
    public static let preferredSampleRate: Double = 11025
    public static let frameDuration: TimeInterval = 0.5
    /// Longer files (mixes, live sets, audiobooks) are not analysed.
    public static let maximumDuration: TimeInterval = 15 * 60

    static let fftSize = 4096
    static let lowestPitchFrequency: Double = 80
    static let highestPitchFrequency: Double = 5000
    static let silenceFloor: Float = -70

    public let sampleRate: Double
    private let hop: Int
    private let fft: MedleyFFT
    private let window: [Float]
    private let binPitchClass: [Int8]
    private var pending: [Float] = []
    private var pendingOffset = 0
    /// Samples dropped from the front of `pending` so far.
    private var droppedSamples = 0
    private var chromaSums: [Float] = []
    private var powerSums: [Double] = []
    private var frameCounts: [Int] = []
    private var real: [Float]
    private var imaginary: [Float]
    private var acceptedSamples = 0

    public init(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 1000 ? sampleRate : Self.preferredSampleRate
        self.sampleRate = rate
        let size = Self.fftSize
        hop = size / 2
        fft = MedleyFFT(size: size)
        window = (0..<size).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(size))) }
        binPitchClass = (0..<(size / 2)).map { bin in
            let frequency = Double(bin) * rate / Double(size)
            guard frequency >= Self.lowestPitchFrequency,
                  frequency <= min(Self.highestPitchFrequency, rate / 2) else { return -1 }
            let midi = 69 + 12 * log2(frequency / 440)
            let pitch = Int(midi.rounded()) % 12
            return Int8((pitch + 12) % 12)
        }
        real = [Float](repeating: 0, count: size)
        imaginary = [Float](repeating: 0, count: size)
    }

    /// Whether the extractor has taken as much audio as it analyses.
    public var isFull: Bool {
        Double(acceptedSamples) >= Self.maximumDuration * sampleRate
    }

    public var analyzedDuration: TimeInterval { Double(acceptedSamples) / sampleRate }

    public func append(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { append($0) }
    }

    public func append(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty, !isFull else { return }
        let room = Int(Self.maximumDuration * sampleRate) - acceptedSamples
        let taken = min(room, samples.count)
        pending.append(contentsOf: samples.prefix(taken))
        acceptedSamples += taken
        let size = Self.fftSize
        while pending.count - pendingOffset >= size {
            analyzeFrame(at: pendingOffset)
            pendingOffset += hop
        }
        if pendingOffset >= 1 << 16 {
            pending.removeFirst(pendingOffset)
            droppedSamples += pendingOffset
            pendingOffset = 0
        }
    }

    private func analyzeFrame(at offset: Int) {
        let size = Self.fftSize
        let centerTime = Double(droppedSamples + offset + size / 2) / sampleRate
        let frame = Int(centerTime / Self.frameDuration)
        while frameCounts.count <= frame {
            frameCounts.append(0)
            powerSums.append(0)
            chromaSums.append(contentsOf: repeatElement(0, count: 12))
        }

        var power: Double = 0
        pending.withUnsafeBufferPointer { samples in
            window.withUnsafeBufferPointer { window in
                real.withUnsafeMutableBufferPointer { real in
                    imaginary.withUnsafeMutableBufferPointer { imaginary in
                        for index in 0..<size {
                            let sample = samples[offset + index]
                            power += Double(sample * sample)
                            real[index] = sample * window[index]
                            imaginary[index] = 0
                        }
                    }
                }
            }
        }
        power /= Double(size)

        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                fft.transform(real: real.baseAddress!, imaginary: imaginary.baseAddress!)
                binPitchClass.withUnsafeBufferPointer { pitchClass in
                    chromaSums.withUnsafeMutableBufferPointer { chroma in
                        let base = frame * 12
                        for bin in 1..<(size / 2) {
                            let pitch = Int(pitchClass[bin])
                            guard pitch >= 0 else { continue }
                            let magnitude = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot()
                            chroma[base + pitch] += magnitude
                        }
                    }
                }
            }
        }
        powerSums[frame] += power
        frameCounts[frame] += 1
    }

    public func finish() -> MedleyAudioFeatures {
        var chroma = [Float](repeating: 0, count: frameCounts.count * 12)
        var loudness = [Float](repeating: Self.silenceFloor - 30, count: frameCounts.count)
        for frame in frameCounts.indices where frameCounts[frame] > 0 {
            let meanPower = powerSums[frame] / Double(frameCounts[frame])
            let decibels = Float(10 * log10(meanPower + 1e-12))
            loudness[frame] = decibels
            guard decibels > Self.silenceFloor else { continue }
            let base = frame * 12
            var peak: Float = 0
            for pitch in 0..<12 { peak = max(peak, chromaSums[base + pitch]) }
            guard peak > 0 else { continue }
            var norm: Float = 0
            for pitch in 0..<12 {
                // Log compression keeps one loud bass note from deciding the frame.
                let value = log1p(10 * chromaSums[base + pitch] / peak)
                chroma[base + pitch] = value
                norm += value * value
            }
            let length = norm.squareRoot()
            guard length > 0 else { continue }
            for pitch in 0..<12 { chroma[base + pitch] /= length }
        }
        return MedleyAudioFeatures(
            frameDuration: Self.frameDuration,
            chroma: chroma,
            loudness: loudness
        )
    }
}

/// An in-place radix-2 complex FFT. Written over raw pointers so the analysis
/// stays fast in debug builds too.
struct MedleyFFT {
    let size: Int
    private let cosines: [Float]
    private let sines: [Float]
    private let reversed: [Int32]

    init(size: Int) {
        precondition(size >= 2 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        cosines = (0..<(size / 2)).map { Float(cos(2 * Double.pi * Double($0) / Double(size))) }
        sines = (0..<(size / 2)).map { Float(sin(2 * Double.pi * Double($0) / Double(size))) }
        var bits = 0
        while 1 << bits < size { bits += 1 }
        reversed = (0..<size).map { index in
            var value = 0
            var remaining = index
            for _ in 0..<bits {
                value = (value << 1) | (remaining & 1)
                remaining >>= 1
            }
            return Int32(value)
        }
    }

    func transform(real: UnsafeMutablePointer<Float>, imaginary: UnsafeMutablePointer<Float>) {
        reversed.withUnsafeBufferPointer { reversed in
            for index in 0..<size {
                let target = Int(reversed[index])
                if target > index {
                    let r = real[index]; real[index] = real[target]; real[target] = r
                    let i = imaginary[index]; imaginary[index] = imaginary[target]; imaginary[target] = i
                }
            }
        }
        cosines.withUnsafeBufferPointer { cosines in
            sines.withUnsafeBufferPointer { sines in
                var half = 1
                while half < size {
                    let step = size / (half * 2)
                    var start = 0
                    while start < size {
                        var twiddle = 0
                        for offset in 0..<half {
                            let wr = cosines[twiddle]
                            let wi = -sines[twiddle]
                            let a = start + offset
                            let b = a + half
                            let tr = wr * real[b] - wi * imaginary[b]
                            let ti = wr * imaginary[b] + wi * real[b]
                            real[b] = real[a] - tr
                            imaginary[b] = imaginary[a] - ti
                            real[a] += tr
                            imaginary[a] += ti
                            twiddle += step
                        }
                        start += half * 2
                    }
                    half *= 2
                }
            }
        }
    }
}

/// Finds a chorus from the audio alone. The song is cut into sections where
/// its harmony or loudness changes (a novelty curve over the chroma
/// self-similarity), and the section that is both loud and repeated elsewhere
/// in the song wins — loud alone picks a one-off bridge or solo, repeated
/// alone picks a verse.
public enum MedleyAudioHighlightDetector {
    /// Shorter songs are played whole by a medley; nothing to find.
    static let minimumSongDuration: TimeInterval = 45
    /// Wide enough to hold a whole chord cycle either side, so the chord
    /// changes inside a section cancel out and only the section edges stand out.
    static let noveltyHalfWidth: TimeInterval = 8
    /// A section edge is moved to the sharpest loudness step this close to it:
    /// a chorus enters and leaves on a change of level more often than not.
    static let edgeSnapWindow: TimeInterval = 3
    static let edgeSnapMinimumStep: Float = 3
    static let minimumSectionDuration: TimeInterval = 4
    static let repetitionWindow: TimeInterval = 8
    static let maximumLength: TimeInterval = 45
    /// A section shorter than this is a piece of a longer one, cut off by a
    /// change inside it; it joins a strong neighbour.
    static let fragmentLength: TimeInterval = 8
    /// Sections scoring this close to the best count as equally good; the
    /// earliest is played, as a listener would expect the first chorus.
    static let scoreTolerance: Double = 0.3
    static let cutSearchStart: TimeInterval = 30

    public static func highlight(
        in features: MedleyAudioFeatures,
        duration: TimeInterval,
        sectionStarts: [TimeInterval] = []
    ) -> MedleyHighlight? {
        let frameDuration = features.frameDuration
        let count = features.frameCount
        guard frameDuration > 0, Double(count) * frameDuration >= minimumSongDuration,
              features.chroma.count == count * 12 else { return nil }
        let songDuration = duration > 0 ? min(duration, Double(count) * frameDuration) : Double(count) * frameDuration
        func frames(_ seconds: TimeInterval) -> Int { max(1, Int((seconds / frameDuration).rounded())) }

        let similarity = selfSimilarity(features.chroma, count: count)
        let loudness = smoothed(features.loudness, radius: 2)
        let novelty = noveltyCurve(similarity: similarity, loudness: loudness, count: count,
                                   halfWidth: frames(noveltyHalfWidth))

        // Section boundaries: the analysis' own when the platform supplied
        // them, otherwise the clear peaks of the novelty curve.
        let minimumSection = frames(minimumSectionDuration)
        var boundaries: [Int]
        let hinted = sectionStarts
            .filter { $0.isFinite && $0 > 0 && $0 < songDuration }
            .map { Int(($0 / frameDuration).rounded()) }
        if hinted.count >= 3 {
            boundaries = hinted
        } else {
            boundaries = noveltyPeaks(novelty, minimumGap: minimumSection)
        }
        boundaries = ([0] + boundaries + [count]).sorted()
        var cleaned: [Int] = []
        for boundary in boundaries {
            if let last = cleaned.last, boundary - last < minimumSection {
                if boundary == count { cleaned[cleaned.count - 1] = count }
                continue
            }
            cleaned.append(boundary)
        }
        if cleaned.last != count { cleaned.append(count) }
        let sections = zip(cleaned, cleaned.dropFirst()).map { (start: $0, end: $1) }
        guard sections.count >= 2 else { return nil }

        let window = frames(repetitionWindow)
        let energies = sections.map { section -> Double in
            var sum: Float = 0
            for frame in section.start..<section.end { sum += loudness[frame] }
            return Double(sum / Float(section.end - section.start))
        }
        let repetitions = sections.map { section in
            repetition(similarity, count: count, start: section.start,
                       length: min(window, section.end - section.start),
                       excluding: section.start..<section.end)
        }
        // Floors keep near-identical values from being blown up into a ranking.
        let energyScores = standardized(energies, minimumDeviation: 1.5)
        let repetitionScores = standardized(repetitions, minimumDeviation: 0.05)

        let scores = sections.indices.map { index -> Double in
            let section = sections[index]
            let startFraction = Double(section.start) * frameDuration / songDuration
            let endFraction = Double(section.end) * frameDuration / songDuration
            let length = Double(section.end - section.start) * frameDuration
            var score = energyScores[index] + 0.8 * repetitionScores[index]
            if startFraction < 0.06 { score -= 1.5 }
            if index == sections.count - 1, endFraction > 0.97 { score -= 1 }
            if length < 8 { score -= 0.4 }
            return score
        }
        guard let top = scores.max(),
              let bestIndex = scores.indices.first(where: { scores[$0] >= top - scoreTolerance }) else { return nil }

        // A chorus split by a change inside it is put back together: a piece
        // too short to stand alone takes in its stronger neighbour, and short
        // strong fragments either side join it.
        var first = bestIndex
        var last = bestIndex
        func length() -> Double { Double(sections[last].end - sections[first].start) * frameDuration }
        func sectionLength(_ index: Int) -> Double {
            Double(sections[index].end - sections[index].start) * frameDuration
        }
        while length() < MedleyHighlightDetector.minimumLength {
            let next = last + 1 < sections.count ? scores[last + 1] : -.infinity
            let previous = first > 0 ? scores[first - 1] : -.infinity
            if next.isFinite, next >= previous {
                last += 1
            } else if previous.isFinite {
                first -= 1
            } else {
                break
            }
        }
        while last + 1 < sections.count, sectionLength(last + 1) < fragmentLength,
              scores[last + 1] >= scores[bestIndex] - 0.5,
              length() + sectionLength(last + 1) <= maximumLength {
            last += 1
        }
        while first > 0, sectionLength(first - 1) < fragmentLength,
              scores[first - 1] >= scores[bestIndex] - 0.5,
              length() + sectionLength(first - 1) <= maximumLength {
            first -= 1
        }

        var startFrame = sections[first].start
        var endFrame = sections[last].end
        if Double(endFrame - startFrame) * frameDuration > maximumLength {
            // Cut where the music changes most, between 30 and 45 seconds in.
            let low = startFrame + frames(cutSearchStart)
            let high = min(endFrame, startFrame + frames(maximumLength))
            if low < high, let cut = (low..<high).max(by: { novelty[$0] < novelty[$1] }) {
                endFrame = cut
            } else {
                endFrame = startFrame + frames(maximumLength)
            }
        }
        let snap = frames(edgeSnapWindow)
        startFrame = snappedEdge(startFrame, in: loudness, window: snap, rising: true)
        endFrame = snappedEdge(endFrame, in: loudness, window: snap, rising: false)
        startFrame = max(0, startFrame)
        guard endFrame > startFrame else { return nil }
        let start = Double(startFrame) * frameDuration
        let end = min(songDuration, Double(endFrame) * frameDuration)
        guard end - start >= MedleySegmentPolicy.minimumHighlightLength else { return nil }
        return MedleyHighlight(start: start, end: end, basis: .audio)
    }

    /// The frame nearest `edge` where loudness rises (or falls) most sharply,
    /// when that step is clear; otherwise `edge` itself.
    static func snappedEdge(_ edge: Int, in loudness: [Float], window: Int, rising: Bool) -> Int {
        let span = 4
        let low = max(span, edge - window)
        let high = min(loudness.count - span, edge + window)
        guard low <= high else { return edge }
        var best = edge
        var bestStep = edgeSnapMinimumStep
        for frame in low...high {
            var before: Float = 0
            var after: Float = 0
            for offset in 0..<span {
                before += loudness[frame - 1 - offset]
                after += loudness[frame + offset]
            }
            let step = (after - before) / Float(span) * (rising ? 1 : -1)
            if step > bestStep || (step == bestStep && abs(frame - edge) < abs(best - edge)) {
                bestStep = step
                best = frame
            }
        }
        return best
    }

    /// Correlation of every pair of frames: each frame's chroma with its mean
    /// taken away, so chords that share notes still tell apart (plain cosine
    /// similarity of compressed chroma is close to 1 for almost any pair).
    static func selfSimilarity(_ rawChroma: [Float], count: Int) -> [Float] {
        var chroma = rawChroma
        for frame in 0..<count {
            let base = frame * 12
            var mean: Float = 0
            for pitch in 0..<12 { mean += chroma[base + pitch] }
            mean /= 12
            var norm: Float = 0
            for pitch in 0..<12 {
                let value = chroma[base + pitch] - mean
                chroma[base + pitch] = value
                norm += value * value
            }
            let length = norm.squareRoot()
            for pitch in 0..<12 { chroma[base + pitch] = length > 1e-6 ? chroma[base + pitch] / length : 0 }
        }
        var matrix = [Float](repeating: 0, count: count * count)
        chroma.withUnsafeBufferPointer { chroma in
            matrix.withUnsafeMutableBufferPointer { matrix in
                for i in 0..<count {
                    let a = i * 12
                    matrix[i * count + i] = 1
                    var j = i + 1
                    while j < count {
                        let b = j * 12
                        var dot: Float = 0
                        for pitch in 0..<12 { dot += chroma[a + pitch] * chroma[b + pitch] }
                        matrix[i * count + j] = dot
                        matrix[j * count + i] = dot
                        j += 1
                    }
                }
            }
        }
        return matrix
    }

    static func smoothed(_ values: [Float], radius: Int) -> [Float] {
        guard radius > 0, !values.isEmpty else { return values }
        return values.indices.map { index in
            let low = max(0, index - radius)
            let high = min(values.count - 1, index + radius)
            var sum: Float = 0
            for other in low...high { sum += values[other] }
            return sum / Float(high - low + 1)
        }
    }

    /// Foote novelty: a checkerboard kernel slid along the similarity matrix's
    /// diagonal peaks where the music before a frame differs from the music
    /// after it. A loudness step adds to it, so a chorus entering on the same
    /// chords as the verse still marks a boundary.
    static func noveltyCurve(similarity: [Float], loudness: [Float], count: Int, halfWidth: Int) -> [Float] {
        var harmonic = [Float](repeating: 0, count: count)
        var dynamic = [Float](repeating: 0, count: count)
        let sigma = Float(halfWidth) / 2
        let taper = (0..<(2 * halfWidth)).map { index -> Float in
            let x = Float(index - halfWidth) + 0.5
            return exp(-(x * x) / (2 * sigma * sigma))
        }
        similarity.withUnsafeBufferPointer { matrix in
            for center in halfWidth..<max(halfWidth, count - halfWidth) {
                var sum: Float = 0
                for a in 0..<(2 * halfWidth) {
                    let row = (center - halfWidth + a) * count
                    let before = a < halfWidth
                    for b in 0..<(2 * halfWidth) {
                        let sign: Float = before == (b < halfWidth) ? 1 : -1
                        sum += sign * taper[a] * taper[b] * matrix[row + center - halfWidth + b]
                    }
                }
                harmonic[center] = max(0, sum)
                var earlier: Float = 0
                var later: Float = 0
                for offset in 0..<halfWidth {
                    earlier += loudness[center - 1 - offset]
                    later += loudness[center + offset]
                }
                dynamic[center] = abs(later - earlier) / Float(halfWidth)
            }
        }
        let harmonicPeak = max(harmonic.max() ?? 0, 1e-6)
        let dynamicPeak = max(dynamic.max() ?? 0, 1e-6)
        return (0..<count).map { harmonic[$0] / harmonicPeak + 0.7 * dynamic[$0] / dynamicPeak }
    }

    /// Frames where the novelty curve peaks clearly: the highest point within
    /// `minimumGap` either side, above the curve's typical level.
    static func noveltyPeaks(_ novelty: [Float], minimumGap: Int) -> [Int] {
        guard novelty.count > 2 * minimumGap else { return [] }
        let sorted = novelty.sorted()
        let threshold = sorted[Int(Double(sorted.count - 1) * 0.6)]
        var peaks: [Int] = []
        for index in minimumGap..<(novelty.count - minimumGap) {
            let value = novelty[index]
            guard value > threshold else { continue }
            var isPeak = true
            for other in (index - minimumGap)...(index + minimumGap) where other != index {
                if novelty[other] > value || (novelty[other] == value && other < index) {
                    isPeak = false
                    break
                }
            }
            if isPeak { peaks.append(index) }
        }
        return peaks
    }

    /// How closely the `length` frames from `start` recur anywhere else in the
    /// song: the best mean similarity along a diagonal of the matrix that does
    /// not overlap the frames themselves. The start is tried a frame or two
    /// late too, since a boundary can land just before the repeat begins.
    /// Matches inside `excluding` (the section itself) do not count: a chord
    /// loop repeating within one bridge is not the bridge recurring.
    static func repetition(
        _ similarity: [Float],
        count: Int,
        start: Int,
        length: Int,
        excluding: Range<Int>? = nil
    ) -> Double {
        guard length > 0 else { return 0 }
        var best: Float = 0
        similarity.withUnsafeBufferPointer { matrix in
            for shift in 0...2 {
                let origin = start + shift
                guard origin + length <= count else { continue }
                var other = 0
                while other + length <= count {
                    let overlapsItself = excluding.map { other < $0.upperBound && other + length > $0.lowerBound } ?? false
                    if abs(other - origin) >= length, !overlapsItself {
                        var sum: Float = 0
                        for offset in 0..<length {
                            sum += matrix[(origin + offset) * count + other + offset]
                        }
                        best = max(best, sum / Float(length))
                    }
                    other += 1
                }
            }
        }
        return Double(best)
    }

    static func standardized(_ values: [Double], minimumDeviation: Double) -> [Double] {
        guard values.count > 1 else { return values.map { _ in 0 } }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let deviation = max(variance.squareRoot(), minimumDeviation)
        return values.map { ($0 - mean) / deviation }
    }
}
