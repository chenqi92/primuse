import Foundation

public enum KaraokeGrade: String, Codable, Sendable, CaseIterable {
    case s, a, b, c, d

    public static func grade(for score: Int) -> KaraokeGrade {
        switch score {
        case 90...: .s
        case 80..<90: .a
        case 65..<80: .b
        case 50..<65: .c
        default: .d
        }
    }
}

public struct KaraokeLineScore: Equatable, Sendable, Identifiable {
    public var lineIndex: Int
    public var lineID: String
    /// 0...100.
    public var score: Int
    /// Whether the score came from pitch matching (true) or only from
    /// singing through the line (false, no usable reference melody).
    public var isPitchJudged: Bool

    public var id: String { lineID }
    public var grade: KaraokeGrade { .grade(for: score) }
}

public struct KaraokeScoreSummary: Equatable, Sendable {
    public var totalScore: Int
    public var lines: [KaraokeLineScore]

    public var grade: KaraokeGrade { .grade(for: totalScore) }
    public var bestLine: KaraokeLineScore? {
        lines.max { lhs, rhs in
            lhs.score == rhs.score ? lhs.lineIndex > rhs.lineIndex : lhs.score < rhs.score
        }
    }
    public var isEmpty: Bool { lines.isEmpty }
}

/// A short, time-ordered history of pitch readings, looked up by song time.
public struct KaraokePitchTrack: Sendable {
    public struct Reading: Equatable, Sendable {
        public var time: TimeInterval
        public var midiNote: Double?
    }

    public private(set) var readings: [Reading] = []
    public let capacity: Int

    public init(capacity: Int = 400) {
        self.capacity = capacity
    }

    public mutating func append(time: TimeInterval, midiNote: Double?) {
        if let last = readings.last, time < last.time - 0.5 {
            // Seeking backwards: the old future is no longer valid.
            readings.removeAll(keepingCapacity: true)
        }
        readings.append(Reading(time: time, midiNote: midiNote))
        if readings.count > capacity {
            readings.removeFirst(readings.count - capacity)
        }
    }

    public mutating func removeAll() {
        readings.removeAll(keepingCapacity: true)
    }

    /// The reading closest to `time` within `tolerance`, or nil.
    public func note(at time: TimeInterval, tolerance: TimeInterval = 0.08) -> Double? {
        reading(at: time, tolerance: tolerance)?.midiNote
    }

    /// Like `note(at:)` but tells "no reading here" (nil) apart from "a
    /// reading of silence" (a reading whose note is nil).
    public func reading(at time: TimeInterval, tolerance: TimeInterval = 0.08) -> Reading? {
        guard !readings.isEmpty else { return nil }
        var lower = 0
        var upper = readings.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if readings[middle].time < time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        var best: Reading?
        var bestDistance = Double.infinity
        for index in [lower - 1, lower] where readings.indices.contains(index) {
            let distance = abs(readings[index].time - time)
            if distance < bestDistance {
                bestDistance = distance
                best = readings[index]
            }
        }
        guard bestDistance <= tolerance else { return nil }
        return best
    }
}

/// Scores a sung performance line by line against the reference melody.
///
/// Pitch is judged modulo the octave, so a singer taking a line an octave
/// down is not penalised. Lines with too little reference melody (the
/// vocal estimate was silent or the recording is mono) fall back to
/// judging whether the user sang through the line at all.
public struct KaraokeScorer: Sendable {
    public let windows: [KaraokeLineWindow]

    private struct Accumulator: Sendable {
        var samples = 0
        var voicedSamples = 0
        var pitchSamples = 0
        var pitchScoreSum = 0.0
    }

    private var accumulators: [Accumulator]
    private var lastTime: TimeInterval?

    /// Samples a line needs before it counts (about a quarter second at the
    /// 20 Hz analysis rate).
    public static let minimumSamplesPerLine = 5
    /// Share of a line's samples that must carry a reference pitch for the
    /// line to be judged on pitch.
    public static let minimumPitchCoverage = 0.25
    /// Share of a line spent singing that counts as singing all of it; lines
    /// have breaths and gaps between words.
    public static let fullPresenceRatio = 0.6

    public init(lines: [LyricLine], part: KaraokePart = .all) {
        windows = KaraokeLineWindowPolicy.windows(in: lines).filter { part.includes($0.voice) }
        accumulators = Array(repeating: Accumulator(), count: windows.count)
    }

    /// Per-reading pitch accuracy: 1 within half a semitone, falling to 0
    /// at three semitones, octave errors folded away.
    public static func pitchAccuracy(sung: Double, reference: Double) -> Double {
        var difference = sung - reference
        difference -= 12 * (difference / 12).rounded()
        let error = abs(difference)
        if error <= 0.5 { return 1 }
        if error >= 3 { return 0 }
        return 1 - (error - 0.5) / 2.5
    }

    /// Records one analysis step.
    ///
    /// - Parameters:
    ///   - time: song time the sung reading belongs to.
    ///   - reference: MIDI note of the original vocal at that time, if any.
    ///   - sung: MIDI note the user sang, or nil for silence.
    public mutating func record(time: TimeInterval, reference: Double?, sung: Double?) {
        if let lastTime, time < lastTime - 1 {
            forgetLines(startingAfter: time)
        }
        lastTime = time
        guard let index = KaraokeLineWindowPolicy.activeWindowIndex(in: windows, at: time) else { return }
        var accumulator = accumulators[index]
        accumulator.samples += 1
        if sung != nil { accumulator.voicedSamples += 1 }
        if let reference {
            accumulator.pitchSamples += 1
            if let sung {
                accumulator.pitchScoreSum += Self.pitchAccuracy(sung: sung, reference: reference)
            }
        }
        accumulators[index] = accumulator
    }

    /// A backwards seek re-opens every line after the new position.
    private mutating func forgetLines(startingAfter time: TimeInterval) {
        for index in windows.indices where windows[index].end > time {
            accumulators[index] = Accumulator()
        }
    }

    public mutating func reset() {
        accumulators = Array(repeating: Accumulator(), count: windows.count)
        lastTime = nil
    }

    /// Live score of the line at `time`, when it has enough samples.
    public func lineScore(at time: TimeInterval) -> KaraokeLineScore? {
        guard let index = KaraokeLineWindowPolicy.activeWindowIndex(in: windows, at: time) else { return nil }
        return lineScore(windowIndex: index)
    }

    func lineScore(windowIndex index: Int) -> KaraokeLineScore? {
        let accumulator = accumulators[index]
        guard accumulator.samples >= Self.minimumSamplesPerLine else { return nil }
        let presence = min(1, Double(accumulator.voicedSamples) / Double(accumulator.samples) / Self.fullPresenceRatio)
        let pitchCoverage = Double(accumulator.pitchSamples) / Double(accumulator.samples)
        let window = windows[index]
        if accumulator.pitchSamples >= Self.minimumSamplesPerLine,
           pitchCoverage >= Self.minimumPitchCoverage {
            let pitch = accumulator.pitchScoreSum / Double(accumulator.pitchSamples)
            let score = 100 * (0.8 * pitch + 0.2 * presence)
            return KaraokeLineScore(
                lineIndex: window.lineIndex,
                lineID: window.lineID,
                score: Int(score.rounded()),
                isPitchJudged: true
            )
        }
        return KaraokeLineScore(
            lineIndex: window.lineIndex,
            lineID: window.lineID,
            score: Int((100 * presence).rounded()),
            isPitchJudged: false
        )
    }

    public func summary() -> KaraokeScoreSummary {
        let lines = windows.indices.compactMap(lineScore(windowIndex:))
        guard !lines.isEmpty else { return KaraokeScoreSummary(totalScore: 0, lines: []) }
        let total = Double(lines.map(\.score).reduce(0, +)) / Double(lines.count)
        return KaraokeScoreSummary(totalScore: Int(total.rounded()), lines: lines)
    }
}
