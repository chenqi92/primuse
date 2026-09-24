import Foundation

/// A note or syllable start found in a vocal track.
public struct KaraokeOnset: Equatable, Sendable {
    public var time: TimeInterval
    /// Normalised peak height, roughly 0...1.
    public var strength: Double

    public init(time: TimeInterval, strength: Double) {
        self.time = time
        self.strength = strength
    }
}

/// Finds syllable onsets in a clean (separated) vocal track with spectral
/// flux: the summed rise of log-magnitude across the voice band, peak-picked
/// against a moving average.
public enum KaraokeOnsetDetector {
    public static let fftSize = 1_024
    public static let hopSize = 256

    public static func onsets(in samples: [Float], sampleRate: Double) -> [KaraokeOnset] {
        let n = fftSize
        let hop = hopSize
        guard samples.count > n else { return [] }
        let fft = KaraokeComplexFFT(size: n)
        let window = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        let binHz = sampleRate / Double(n)
        let lowBin = max(1, Int(80 / binHz))
        let highBin = min(n / 2 - 1, Int(5_000 / binHz))

        let frameCount = (samples.count - n) / hop + 1
        var flux = [Double](repeating: 0, count: frameCount)
        var previous = [Float](repeating: 0, count: n / 2)
        var real = [Float](repeating: 0, count: n)
        var imag = [Float](repeating: 0, count: n)
        for frame in 0..<frameCount {
            let start = frame * hop
            for i in 0..<n {
                real[i] = samples[start + i] * window[i]
                imag[i] = 0
            }
            real.withUnsafeMutableBufferPointer { r in imag.withUnsafeMutableBufferPointer { m in
                fft.forward(real: r.baseAddress!, imag: m.baseAddress!)
            } }
            var rise = 0.0
            for bin in lowBin...highBin {
                let magnitude = log1p(1_000 * (real[bin] * real[bin] + imag[bin] * imag[bin]).squareRoot())
                let difference = magnitude - previous[bin]
                if difference > 0 { rise += Double(difference) }
                previous[bin] = magnitude
            }
            // The first frame has nothing to rise from.
            flux[frame] = frame == 0 ? 0 : rise
        }

        // Peaks above a local mean, at least 60 ms apart.
        let context = max(3, Int(0.1 * sampleRate / Double(hop)))
        let minimumGap = max(1, Int(0.06 * sampleRate / Double(hop)))
        let globalMax = flux.max() ?? 0
        guard globalMax > 0 else { return [] }
        var result: [KaraokeOnset] = []
        var lastPeak = -minimumGap
        for frame in 1..<(frameCount - 1) {
            let value = flux[frame]
            guard value > flux[frame - 1], value >= flux[frame + 1] else { continue }
            let lower = max(0, frame - context)
            let upper = min(frameCount - 1, frame + context)
            var sum = 0.0
            for k in lower...upper { sum += flux[k] }
            let mean = sum / Double(upper - lower + 1)
            guard value > mean * 1.5 + globalMax * 0.03 else { continue }
            if frame - lastPeak < minimumGap {
                // Keep the stronger of two close peaks.
                if let last = result.last, value / globalMax > last.strength {
                    result[result.count - 1] = KaraokeOnset(
                        time: onsetTime(frame: frame, hop: hop, fftSize: n, sampleRate: sampleRate),
                        strength: value / globalMax
                    )
                    lastPeak = frame
                }
                continue
            }
            result.append(KaraokeOnset(
                time: onsetTime(frame: frame, hop: hop, fftSize: n, sampleRate: sampleRate),
                strength: value / globalMax
            ))
            lastPeak = frame
        }
        return result
    }

    /// The flux of frame `f` compares it with frame `f - 1`; the new sound
    /// arrives inside the later half of that window.
    static func onsetTime(frame: Int, hop: Int, fftSize: Int, sampleRate: Double) -> TimeInterval {
        (Double(frame * hop) + Double(fftSize) * 0.5) / sampleRate
    }
}

/// Places the words of a line-timed lyric row on the onsets of its vocal,
/// turning it into a word-timed row. Units keep their order; each takes an
/// onset near where an even spread would put it, and a unit with no onset
/// nearby falls back to that even position.
public enum KaraokeWordTimingPolicy {
    /// How far (in share of the row) an onset may sit from a unit's even
    /// position and still be preferred; beyond it the position term wins.
    static let positionWeight = 3.0
    /// Reward of taking a real onset instead of the even position.
    static let onsetReward = 1.0
    static let minimumUnitDuration: TimeInterval = 0.07

    /// Word-timed copy of `line` using `onsets` (any order, song seconds),
    /// or nil when the row is already word-timed or has nothing to place.
    public static func timedLine(
        _ line: LyricLine,
        window: KaraokeLineWindow,
        onsets: [KaraokeOnset]
    ) -> LyricLine? {
        if let syllables = line.syllables, !syllables.isEmpty { return nil }
        let units = KaraokeSweepPolicy.sweepUnits(of: line.text)
        guard !units.isEmpty else { return nil }
        let weights = units.map { Double(max(1, $0.filter { !$0.isWhitespace }.count)) }
        let starts = startTimes(weights: weights, window: window, onsets: onsets)
        let lineEnd = window.start + max(0.2, (window.end - window.start) * 0.92)
        var syllables: [LyricSyllable] = []
        for (index, unit) in units.enumerated() {
            let start = starts[index]
            let next = index + 1 < starts.count ? starts[index + 1] : max(lineEnd, start + minimumUnitDuration)
            syllables.append(LyricSyllable(text: unit, start: start, end: max(start + 0.01, next), endTiming: .inferred))
        }
        var result = line
        result.syllables = syllables
        return result
    }

    /// Unit start times: a monotonic assignment to onsets or even positions
    /// minimising distance from the even spread minus a reward per onset.
    static func startTimes(weights: [Double], window: KaraokeLineWindow, onsets: [KaraokeOnset]) -> [TimeInterval] {
        let count = weights.count
        let span = max(0.2, (window.end - window.start) * 0.92)
        let total = weights.reduce(0, +)
        var cumulative = 0.0
        let expected: [TimeInterval] = weights.map { weight in
            defer { cumulative += weight }
            return window.start + span * cumulative / total
        }
        // The first sung onset may come a little before or after the stamp.
        let candidates = onsets
            .filter { $0.time >= window.start - 0.2 && $0.time < window.start + span }
            .sorted { $0.time < $1.time }

        // Options per unit: every onset, plus its own even position.
        struct Option { var time: TimeInterval; var cost: Double }
        var options: [[Option]] = []
        for k in 0..<count {
            var list = [Option(time: expected[k], cost: 0)]
            for onset in candidates {
                let distance = abs(onset.time - expected[k]) / span
                list.append(Option(
                    time: onset.time,
                    cost: positionWeight * distance - onsetReward * min(1, onset.strength * 2)
                ))
            }
            options.append(list)
        }

        // DP over units; transitions require strictly later start times.
        var best = options[0].map { $0.cost }
        var back = [[Int]](repeating: [], count: count)
        back[0] = [Int](repeating: -1, count: options[0].count)
        for k in 1..<max(1, count) {
            var next = [Double](repeating: .infinity, count: options[k].count)
            var choice = [Int](repeating: -1, count: options[k].count)
            for (j, option) in options[k].enumerated() {
                for (i, previous) in options[k - 1].enumerated()
                where best[i].isFinite && option.time >= previous.time + minimumUnitDuration {
                    let cost = best[i] + option.cost
                    if cost < next[j] {
                        next[j] = cost
                        choice[j] = i
                    }
                }
            }
            best = next
            back[k] = choice
        }
        guard var index = best.indices.min(by: { best[$0] < best[$1] }), best[index].isFinite else {
            return expected
        }
        var times = [TimeInterval](repeating: 0, count: count)
        for k in stride(from: count - 1, through: 0, by: -1) {
            times[k] = options[k][index].time
            if k > 0 { index = back[k][index] }
        }
        return times
    }
}
