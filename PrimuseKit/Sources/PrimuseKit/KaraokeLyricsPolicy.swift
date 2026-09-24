import Foundation

/// Which singer the user takes in karaoke mode.
public enum KaraokePart: String, Codable, CaseIterable, Sendable {
    /// Every line; the whole lead vocal is reduced.
    case all
    /// The main voice; the duet partner keeps the original vocal.
    case primary
    /// The duet partner; the main voice keeps the original vocal.
    case secondary

    func includes(_ voice: LyricVoice) -> Bool {
        switch self {
        case .all: true
        case .primary: voice == .primary
        case .secondary: voice == .secondary
        }
    }
}

/// The time span in which one synchronized lyric line is sung.
public struct KaraokeLineWindow: Equatable, Sendable {
    public var lineIndex: Int
    public var lineID: String
    public var voice: LyricVoice
    public var start: TimeInterval
    public var end: TimeInterval

    public init(lineIndex: Int, lineID: String, voice: LyricVoice, start: TimeInterval, end: TimeInterval) {
        self.lineIndex = lineIndex
        self.lineID = lineID
        self.voice = voice
        self.start = start
        self.end = end
    }

    public func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

public enum KaraokeLineWindowPolicy {
    /// A line-level row with no explicit end is never assumed to last longer
    /// than this; a long instrumental gap before the next line is not singing.
    public static let maximumInferredLineDuration: TimeInterval = 8
    /// Shortest window a row keeps even when the next row starts at once.
    public static let minimumLineDuration: TimeInterval = 0.3

    /// Windows for every synchronized, non-empty row, in lyric order.
    public static func windows(in lines: [LyricLine]) -> [KaraokeLineWindow] {
        var result: [KaraokeLineWindow] = []
        result.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            guard line.isSynchronized,
                  !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = line.timestamp
            let nextStart = lines[(index + 1)...].first(where: {
                $0.isSynchronized && $0.timestamp > start + 0.002
            })?.timestamp
            let end = resolvedEnd(of: line, nextStart: nextStart)
            result.append(KaraokeLineWindow(
                lineIndex: index,
                lineID: line.id,
                voice: line.voice,
                start: start,
                end: max(start + minimumLineDuration, end)
            ))
        }
        return result
    }

    static func resolvedEnd(of line: LyricLine, nextStart: TimeInterval?) -> TimeInterval {
        if let end = line.endTime, end > line.timestamp {
            return end
        }
        let cap = line.timestamp + maximumInferredLineDuration
        guard let nextStart else { return cap }
        return min(nextStart, cap)
    }

    /// Index into `windows` of the row being sung at `time`, if any.
    public static func activeWindowIndex(
        in windows: [KaraokeLineWindow],
        at time: TimeInterval
    ) -> Int? {
        var lower = 0
        var upper = windows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if windows[middle].start <= time {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        var index = lower - 1
        // Overlapping duet rows: prefer the latest-starting row that still
        // covers `time`.
        while index >= 0 {
            if windows[index].contains(time) { return index }
            if time - windows[index].start > maximumInferredLineDuration * 2 { break }
            index -= 1
        }
        return nil
    }
}

/// Countdown dots shown before the singer's next entry.
public struct KaraokeLeadIn: Equatable, Sendable {
    /// 3, 2 or 1 dots still lit.
    public var remainingBeats: Int
    /// When the next row begins.
    public var entryTime: TimeInterval
    public var nextLineIndex: Int
}

public enum KaraokeLeadInPolicy {
    /// Only gaps at least this long (intro, interlude) get a countdown.
    public static let minimumGap: TimeInterval = 4.5
    public static let countdownDuration: TimeInterval = 3

    public static func leadIn(
        windows: [KaraokeLineWindow],
        at time: TimeInterval
    ) -> KaraokeLeadIn? {
        guard let nextIndex = windows.firstIndex(where: { $0.start > time }) else { return nil }
        let next = windows[nextIndex]
        let remaining = next.start - time
        guard remaining <= countdownDuration else { return nil }
        let previousEnd = windows[..<nextIndex].map(\.end).max() ?? 0
        guard previousEnd <= time, next.start - previousEnd >= minimumGap else { return nil }
        let beats = max(1, min(3, Int(remaining.rounded(.up))))
        return KaraokeLeadIn(remainingBeats: beats, entryTime: next.start, nextLineIndex: next.lineIndex)
    }
}

public enum KaraokeSweepPolicy {
    /// Gives a line-level row evenly spread word timing across its window so
    /// the stage can sweep it like a word-timed row. Word-timed rows are
    /// returned unchanged.
    public static func sweepLine(_ line: LyricLine, window: KaraokeLineWindow) -> LyricLine {
        if let syllables = line.syllables, !syllables.isEmpty { return line }
        let units = sweepUnits(of: line.text)
        guard !units.isEmpty else { return line }

        // Leave a short tail so the last word lands before the row ends.
        let duration = max(0.2, (window.end - window.start) * 0.92)
        let weights = units.map { unit in
            Double(max(1, unit.filter { !$0.isWhitespace }.count))
        }
        let totalWeight = weights.reduce(0, +)
        var cursor = window.start
        var syllables: [LyricSyllable] = []
        syllables.reserveCapacity(units.count)
        for (unit, weight) in zip(units, weights) {
            let length = duration * weight / totalWeight
            syllables.append(LyricSyllable(
                text: unit,
                start: cursor,
                end: cursor + length,
                endTiming: .inferred
            ))
            cursor += length
        }
        var result = line
        result.syllables = syllables
        return result
    }

    /// Splits text into sweep units: one per CJK/kana/hangul character, one
    /// per space-separated word elsewhere. Trailing spaces stay attached so
    /// joining the units restores the original text.
    static func sweepUnits(of text: String) -> [String] {
        var units: [String] = []
        var current = ""
        for character in text {
            if character.isWhitespace {
                // Spaces trail whatever came before them.
                if current.isEmpty, !units.isEmpty {
                    units[units.count - 1].append(character)
                } else {
                    current.append(character)
                }
                continue
            }
            if isIdeographicUnit(character) {
                if !current.isEmpty { units.append(current); current = "" }
                units.append(String(character))
                continue
            }
            if let last = current.last, last.isWhitespace {
                units.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty {
            if current.allSatisfy(\.isWhitespace), !units.isEmpty {
                units[units.count - 1] += current
            } else {
                units.append(current)
            }
        }
        return units
    }

    static func isIdeographicUnit(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified
             0xAC00...0xD7AF, // Hangul syllables
             0xF900...0xFAFF, // CJK Compatibility
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

public enum KaraokeDuetGatePolicy {
    /// The partner's vocal opens slightly before their row so the first
    /// consonant is not clipped, and closes slightly after it.
    public static let partnerPreRoll: TimeInterval = 0.15
    public static let partnerPostRoll: TimeInterval = 0.3

    /// Whether the lyrics mark two alternating singers.
    public static func hasDuetParts(_ lines: [LyricLine]) -> Bool {
        var sawPrimary = false
        var sawSecondary = false
        for line in lines where line.isSynchronized {
            switch line.voice {
            case .primary: sawPrimary = true
            case .secondary: sawSecondary = true
            }
            if sawPrimary && sawSecondary { return true }
        }
        return false
    }

    /// How much of the vocal to remove at `time` for the chosen part, as a
    /// fraction of the user's vocal-removal setting: 1 while the user's part
    /// (or nobody) sings, 0 while only the partner sings.
    public static func reductionFactor(
        windows: [KaraokeLineWindow],
        part: KaraokePart,
        at time: TimeInterval
    ) -> Float {
        guard part != .all else { return 1 }
        var partnerSings = false
        for window in windows {
            if window.start - partnerPreRoll > time { break }
            guard time < window.end + partnerPostRoll else { continue }
            if part.includes(window.voice) {
                // The user's own row always wins, including overlaps.
                if window.contains(time) { return 1 }
            } else {
                partnerSings = true
            }
        }
        return partnerSings ? 0 : 1
    }
}

public enum KaraokeKeyShiftPolicy {
    public static let range: ClosedRange<Int> = -6...6

    public static func clamped(_ semitones: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, semitones))
    }

    /// `AVAudioUnitTimePitch.pitch` takes cents.
    public static func cents(forSemitones semitones: Int) -> Float {
        Float(clamped(semitones) * 100)
    }
}

/// Why karaoke processing cannot run on what is playing now.
public enum KaraokeAvailability: Equatable, Sendable {
    case available
    case noSong
    /// Apple Music plays through the system player, which exposes no audio.
    case appleMusic
    /// Audio leaves the device before any local processing.
    case casting
    /// The bit-perfect output graph contains no effect units.
    case highFidelityOutput

    public static func resolve(
        hasSong: Bool,
        isAppleMusic: Bool,
        isCasting: Bool,
        isHighFidelityOutput: Bool
    ) -> KaraokeAvailability {
        if !hasSong { return .noSong }
        if isAppleMusic { return .appleMusic }
        if isCasting { return .casting }
        if isHighFidelityOutput { return .highFidelityOutput }
        return .available
    }
}

/// Lines the two recorded streams up so the voice sits on the beat the
/// singer actually heard.
public enum KaraokeRecordingAlignment {
    /// Frames to drop from the start of the microphone file (negative: pad
    /// the microphone with silence instead).
    ///
    /// - Parameters:
    ///   - accompanimentFirstHostSeconds: host time of the first rendered
    ///     accompaniment frame.
    ///   - microphoneFirstHostSeconds: host time the first microphone frame
    ///     was delivered.
    ///   - outputLatency: render → speaker delay.
    ///   - inputLatency: microphone → delivery delay.
    public static func microphoneLeadFrames(
        accompanimentFirstHostSeconds: Double,
        microphoneFirstHostSeconds: Double,
        outputLatency: Double,
        inputLatency: Double,
        sampleRate: Double
    ) -> Int {
        // The first accompaniment frame is heard at accompaniment + output
        // latency; the microphone frame captured then is delivered
        // inputLatency later.
        let matchingMicrophoneHostSeconds = accompanimentFirstHostSeconds + outputLatency + inputLatency
        let lead = matchingMicrophoneHostSeconds - microphoneFirstHostSeconds
        return Int((lead * sampleRate).rounded())
    }
}
