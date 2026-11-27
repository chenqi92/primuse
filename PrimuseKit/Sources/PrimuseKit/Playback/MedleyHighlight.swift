import Foundation

/// A song's highlight ("高潮"): the chorus a medley plays when the listener
/// has not chosen a stretch of the song themselves. Times are on the song's
/// own timeline.
public struct MedleyHighlight: Codable, Hashable, Sendable {
    public enum Basis: String, Codable, Sendable {
        /// The most repeated block of synchronized lyrics.
        case lyrics
        /// Repetition and loudness of the audio alone.
        case audio
        /// The lyrics found the chorus; the audio chose its strongest occurrence.
        case lyricsAndAudio
    }

    public var start: TimeInterval
    public var end: TimeInterval
    public var basis: Basis

    public init(start: TimeInterval, end: TimeInterval, basis: Basis) {
        self.start = start
        self.end = end
        self.basis = basis
    }

    public var length: TimeInterval { max(0, end - start) }
}

/// One timed lyric line as the chorus search reads it.
public struct MedleyLyricLine: Equatable, Sendable {
    public var time: TimeInterval
    public var text: String

    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}

/// Finds a song's chorus in its synchronized lyrics: the block of lines sung
/// most often. Lines are compared by their letters and digits only, so
/// punctuation and spacing differences between repeats do not matter.
public enum MedleyLyricChorusDetector {
    /// A stretch of the song that sings the chorus.
    public struct Stretch: Equatable, Sendable {
        public var start: TimeInterval
        public var end: TimeInterval
        /// Start times of the stretch's lines, so it can be cut at a line.
        public var lineStarts: [TimeInterval]

        public init(start: TimeInterval, end: TimeInterval, lineStarts: [TimeInterval]) {
            self.start = start
            self.end = end
            self.lineStarts = lineStarts
        }

        public var length: TimeInterval { max(0, end - start) }
    }

    /// Too few sung lines to tell a chorus from a verse.
    static let minimumSungLines = 8
    static let minimumBlockLines = 2
    /// A repeated block shorter than this is a hook inside the chorus; it is
    /// kept as a seed and grown into the whole chorus.
    static let minimumBlockDuration: TimeInterval = 6
    static let maximumStretchDuration: TimeInterval = 75

    /// The stretches singing the most repeated block, in song order, or none
    /// when the lyrics are untimed, too short, or repeat nothing.
    public static func stretches(
        in lines: [MedleyLyricLine],
        duration: TimeInterval
    ) -> [Stretch] {
        // Lines at the same time keep their order: the original comes first.
        let timeline = lines.enumerated()
            .filter { $0.element.time.isFinite && $0.element.time >= 0
                && (duration <= 0 || $0.element.time < duration) }
            .sorted { $0.element.time != $1.element.time ? $0.element.time < $1.element.time : $0.offset < $1.offset }
            .map(\.element)
        guard timeline.count >= minimumSungLines else { return [] }

        // Sung lines, one per timestamp: an unpaired bilingual file carries the
        // translation as a second line at the same time.
        var interned: [String: Int] = [:]
        var sung: [Int] = []
        var keys: [Int] = []
        var previousTime = -1.0
        for (index, line) in timeline.enumerated() {
            let key = normalizedKey(line.text)
            guard !key.isEmpty else { continue }
            guard line.time > previousTime + 0.01 else { continue }
            previousTime = line.time
            sung.append(index)
            if let id = interned[key] {
                keys.append(id)
            } else {
                let id = interned.count
                interned[key] = id
                keys.append(id)
            }
        }
        let count = sung.count
        guard count >= minimumSungLines else { return [] }
        // Every line is different: nothing repeats.
        guard interned.count < count else { return [] }

        func lineStart(_ position: Int) -> TimeInterval { timeline[sung[position]].time }
        let typicalLine = typicalLineDuration(sung.map { timeline[$0].time })
        /// Where the line at `position` ends: when the next line, sung or
        /// blank, begins — unless that is far off (an instrumental follows).
        func lineEnd(_ position: Int) -> TimeInterval {
            let start = lineStart(position)
            let longest = max(3, typicalLine * 1.6)
            let timelineIndex = sung[position]
            var end = start + longest
            if timelineIndex + 1 < timeline.count {
                end = min(end, timeline[timelineIndex + 1].time)
            }
            if duration > 0 { end = min(end, duration) }
            return max(end, start + 0.5)
        }
        func span(from first: Int, lines: Int) -> TimeInterval {
            lineEnd(first + lines - 1) - lineStart(first)
        }

        // run[i][j] (i < j): how many lines from i and from j are sung alike.
        let stride = count + 1
        var run = [Int32](repeating: 0, count: stride * stride)
        run.withUnsafeMutableBufferPointer { run in
            keys.withUnsafeBufferPointer { keys in
                var i = count - 1
                while i >= 0 {
                    var j = count - 1
                    while j > i {
                        if keys[i] == keys[j] {
                            run[i * stride + j] = run[(i + 1) * stride + j + 1] + 1
                        }
                        j -= 1
                    }
                    i -= 1
                }
            }
        }

        // The block sung most often; among those, the longest. A block is
        // searched from its first occurrence, so later copies never win.
        var best: (first: Int, lines: Int, occurrences: [Int], span: TimeInterval)?
        run.withUnsafeBufferPointer { run in
            for i in 0..<count {
                var longestRun = 0
                for j in (i + 1)..<count {
                    longestRun = max(longestRun, min(Int(run[i * stride + j]), j - i))
                }
                guard longestRun >= minimumBlockLines else { continue }
                for lines in minimumBlockLines...longestRun {
                    let blockSpan = span(from: i, lines: lines)
                    guard blockSpan >= minimumBlockDuration else { continue }
                    guard blockSpan <= maximumStretchDuration else { break }
                    var occurrences = [i]
                    var last = i
                    for j in (i + 1)..<count where j - last >= lines && Int(run[i * stride + j]) >= lines {
                        occurrences.append(j)
                        last = j
                    }
                    guard occurrences.count >= 2 else { continue }
                    if let current = best {
                        guard occurrences.count > current.occurrences.count
                            || (occurrences.count == current.occurrences.count
                                && blockSpan > current.span + 0.01) else { continue }
                    }
                    best = (i, lines, occurrences, blockSpan)
                }
            }
        }
        guard let best else { return [] }

        // Back-to-back copies are one stretch ("A B A B" sings the hook twice).
        var ranges: [(start: Int, end: Int)] = []
        for occurrence in best.occurrences {
            if let last = ranges.last, last.end == occurrence {
                ranges[ranges.count - 1].end = occurrence + best.lines
            } else {
                ranges.append((occurrence, occurrence + best.lines))
            }
        }

        // Grow every stretch by the lines most of them share, forwards then
        // backwards: a hook found as the most repeated block becomes the whole
        // chorus around it.
        func grow(forward: Bool) {
            while true {
                var candidates: [Int: Int] = [:]
                for (index, range) in ranges.enumerated() {
                    let position = forward ? range.end : range.start - 1
                    guard position >= 0, position < count else { continue }
                    let blocked = forward
                        ? (index + 1 < ranges.count && ranges[index + 1].start == position)
                        : (index > 0 && ranges[index - 1].end == range.start)
                    guard !blocked else { continue }
                    guard span(from: forward ? range.start : position,
                               lines: range.end - range.start + 1) <= maximumStretchDuration else { continue }
                    candidates[keys[position], default: 0] += 1
                }
                // Ties go to the line sung first in the song (lowest id), so the
                // result does not depend on dictionary order.
                guard let top = candidates.max(by: {
                    $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
                }),
                      top.value >= 2 else { return }
                let key = top.key
                var grew = false
                for index in ranges.indices {
                    let position = forward ? ranges[index].end : ranges[index].start - 1
                    guard position >= 0, position < count, keys[position] == key else { continue }
                    let blocked = forward
                        ? (index + 1 < ranges.count && ranges[index + 1].start == position)
                        : (index > 0 && ranges[index - 1].end == ranges[index].start)
                    guard !blocked else { continue }
                    if forward { ranges[index].end += 1 } else { ranges[index].start -= 1 }
                    grew = true
                }
                guard grew else { return }
            }
        }
        grow(forward: true)
        grow(forward: false)

        return ranges.map { range in
            Stretch(
                start: lineStart(range.start),
                end: lineEnd(range.end - 1),
                lineStarts: (range.start..<range.end).map(lineStart)
            )
        }
    }

    static func normalizedKey(_ text: String) -> String {
        var key = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars
        where CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
            key.append(scalar)
        }
        return String(key)
    }

    /// The usual gap between one sung line and the next.
    static func typicalLineDuration(_ starts: [TimeInterval]) -> TimeInterval {
        let gaps = zip(starts, starts.dropFirst())
            .map { $1 - $0 }
            .filter { $0 > 0.3 && $0 < 15 }
            .sorted()
        guard !gaps.isEmpty else { return 4 }
        return gaps[gaps.count / 2]
    }
}

/// Picks a song's highlight from whatever is known about it: synchronized
/// lyrics locate the chorus most reliably, the audio decides which chorus is
/// the strongest and stands in when there are no lyrics.
public enum MedleyHighlightDetector {
    /// A chorus stretch longer than this is trimmed to its strongest part; a
    /// repeated verse-and-chorus pair is one stretch in the lyrics.
    static let preferredMaximumLength: TimeInterval = 40
    static let trimmedLength: TimeInterval = 30
    static let minimumLength: TimeInterval = 12
    /// Occurrences this close in loudness count as equally strong; the
    /// earliest one is played.
    static let loudnessTolerance: Float = 1.5

    public static func highlight(
        duration: TimeInterval,
        lyrics: [MedleyLyricLine],
        audio: MedleyAudioFeatures?,
        sectionStarts: [TimeInterval] = []
    ) -> MedleyHighlight? {
        guard duration.isFinite, duration > 0 else { return nil }
        let stretches = MedleyLyricChorusDetector.stretches(in: lyrics, duration: duration)
            .filter { $0.start < duration - minimumLength / 2 }
        if !stretches.isEmpty {
            var chosen = stretches[0]
            if let audio {
                let loudness = stretches.map { audio.meanLoudness(from: $0.start, to: $0.end) ?? -.infinity }
                if let strongest = loudness.max(), strongest.isFinite,
                   let index = loudness.firstIndex(where: { $0 >= strongest - loudnessTolerance }) {
                    chosen = stretches[index]
                }
            }
            var window = trimmed(chosen, audio: audio)
            window.end = min(duration, max(window.end, window.start + minimumLength))
            return MedleyHighlight(
                start: window.start,
                end: window.end,
                basis: audio == nil ? .lyrics : .lyricsAndAudio
            )
        }
        guard let audio else { return nil }
        return MedleyAudioHighlightDetector.highlight(
            in: audio,
            duration: duration,
            sectionStarts: sectionStarts
        )
    }

    /// A long stretch cut to its strongest part at line starts: the loudest
    /// window when the audio is known, otherwise its last lines — a stretch
    /// holding a verse and its chorus ends on the chorus.
    static func trimmed(
        _ stretch: MedleyLyricChorusDetector.Stretch,
        audio: MedleyAudioFeatures?
    ) -> (start: TimeInterval, end: TimeInterval) {
        guard stretch.length > preferredMaximumLength, stretch.lineStarts.count > 1 else {
            return (stretch.start, stretch.end)
        }
        let cuts = stretch.lineStarts + [stretch.end]
        var windows: [(start: TimeInterval, end: TimeInterval)] = []
        for first in cuts.indices {
            for last in cuts.indices where last > first {
                let length = cuts[last] - cuts[first]
                if length >= minimumLength, length <= preferredMaximumLength {
                    windows.append((cuts[first], cuts[last]))
                }
            }
        }
        guard !windows.isEmpty else {
            return (max(stretch.start, stretch.end - trimmedLength), stretch.end)
        }
        if let audio {
            // Loudest per second, with a nudge towards the usual chorus length
            // so a single loud line does not win on its own.
            func score(_ window: (start: TimeInterval, end: TimeInterval)) -> Double {
                let loudness = Double(audio.meanLoudness(from: window.start, to: window.end) ?? -120)
                return loudness - abs((window.end - window.start) - trimmedLength) / 10
            }
            if let best = windows.max(by: { score($0) < score($1) }) { return best }
        }
        let ending = windows.filter { abs($0.end - stretch.end) < 0.01 }
        return ending.min { abs(($0.end - $0.start) - trimmedLength) < abs(($1.end - $1.start) - trimmedLength) }
            ?? windows[0]
    }
}

/// What was found for one song, kept so a later medley does not analyse it again.
public struct MedleyHighlightRecord: Codable, Equatable, Sendable {
    /// Raised when the detection changes, so older findings are redone.
    public static let currentVersion = 1

    public var version: Int
    /// The length the song had when it was analysed; a changed file is redone.
    public var songDuration: TimeInterval
    /// Nil when nothing usable was found.
    public var highlight: MedleyHighlight?
    public var includesAudio: Bool
    public var includesLyrics: Bool
    public var analyzedAt: Date

    public init(
        version: Int = MedleyHighlightRecord.currentVersion,
        songDuration: TimeInterval,
        highlight: MedleyHighlight?,
        includesAudio: Bool,
        includesLyrics: Bool,
        analyzedAt: Date = Date()
    ) {
        self.version = version
        self.songDuration = songDuration
        self.highlight = highlight
        self.includesAudio = includesAudio
        self.includesLyrics = includesLyrics
        self.analyzedAt = analyzedAt
    }
}

public enum MedleyHighlightRecordPolicy {
    static let durationTolerance: TimeInterval = 1.5
    /// Records kept on a device; the oldest analyses go first.
    public static let maximumRecordCount = 4000

    public static func isCurrent(_ record: MedleyHighlightRecord, songDuration: TimeInterval) -> Bool {
        record.version == MedleyHighlightRecord.currentVersion
            && songDuration.isFinite
            && abs(record.songDuration - songDuration) <= durationTolerance
    }

    /// The highlight recorded for a song of `songDuration`, when it still fits.
    public static func highlight(
        from record: MedleyHighlightRecord?,
        songDuration: TimeInterval
    ) -> MedleyHighlight? {
        guard let record, isCurrent(record, songDuration: songDuration),
              let highlight = record.highlight,
              highlight.start >= 0, highlight.end <= songDuration + 0.5,
              highlight.length >= MedleySegmentPolicy.minimumHighlightLength else { return nil }
        return highlight
    }

    /// Whether analysing now could find more than the record holds: it is
    /// missing or stale, or audio or lyrics have become available since.
    public static func needsAnalysis(
        _ record: MedleyHighlightRecord?,
        songDuration: TimeInterval,
        audioAvailable: Bool,
        lyricsAvailable: Bool
    ) -> Bool {
        guard let record, isCurrent(record, songDuration: songDuration) else { return true }
        return (audioAvailable && !record.includesAudio)
            || (lyricsAvailable && !record.includesLyrics)
    }

    /// The ids to drop so at most `maximumRecordCount` remain.
    public static func evictedIDs(
        _ records: [String: MedleyHighlightRecord],
        limit: Int = maximumRecordCount
    ) -> [String] {
        guard records.count > limit else { return [] }
        return records
            .sorted { $0.value.analyzedAt < $1.value.analyzedAt }
            .prefix(records.count - limit)
            .map(\.key)
    }
}
