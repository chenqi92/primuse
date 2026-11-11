import Foundation

/// A word-timing companion row: an ordinary LRC line followed by a row at the
/// same timestamp that times it character by character.
///
///     [00:12.300]Light on the water
///     [00:12.300][tt]<0,0><240,1><490,2>…<2630,17><2630>
///
/// Each `<offset,index>` marker starts the piece of the line text that begins
/// at character `index`, `offset` milliseconds after the line timestamp; the
/// piece runs until the next marker. A marker whose index equals the length
/// of the text closes the last piece, and a final single `<duration>` gives
/// the length of the whole line.
///
/// Only start times are written, exactly like ELRC word markers, so the
/// result is the line an ELRC reader would build: each word ends where the
/// next one starts, and only the closing marker states an end. That keeps an
/// edited document writable as plain ELRC.
///
/// The companion row never becomes a lyric of its own and never stands in
/// for a translation, even when its markers do not fit the line it follows.
public enum LRCWordTimingCompanion {
    public struct Row: Sendable, Equatable {
        /// The line timestamps the row times, in seconds.
        public let starts: [TimeInterval]
        /// `nil` when the markers do not follow the grammar.
        let timing: Timing?
    }

    struct Mark: Sendable, Equatable {
        let offset: Int
        let index: Int
    }

    struct Timing: Sendable, Equatable {
        let marks: [Mark]
        let duration: Int?
    }

    private static let tag = "[tt]"
    /// Same-time lines are matched on the millisecond the LRC row carries.
    private static let timestampTolerance: TimeInterval = 0.0015
    /// Matches the ELRC fallback for a last word without an end.
    private static let inferredTailDuration: TimeInterval = 0.4
    /// Refuses values no song reaches before they are summed.
    private static let maximumMilliseconds = 1_000_000_000

    /// Whether the document carries at least one companion row.
    public static func containsCompanionRows(_ content: String) -> Bool {
        guard content.range(of: tag, options: .caseInsensitive) != nil else { return false }
        return content.components(separatedBy: .newlines).contains { row($0) != nil }
    }

    /// Reads one raw row as a companion row: one or more LRC time tags, then
    /// `[tt]`, then markers. Any other row returns `nil`.
    public static func row(_ raw: String) -> Row? {
        guard raw.range(of: tag, options: .caseInsensitive) != nil else { return nil }
        var rest = raw.drop { $0 == "\u{FEFF}" || $0.isWhitespace }

        var starts: [TimeInterval] = []
        while rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            rest = rest[rest.index(after: close)...]
            if inner.lowercased() == "tt" {
                guard !starts.isEmpty else { return nil }
                return Row(starts: starts, timing: timing(in: rest))
            }
            guard let start = timestamp(inner) else { return nil }
            starts.append(start)
            rest = rest.drop { $0 == " " || $0 == "\t" }
        }
        return nil
    }

    /// Applies every companion row to the line it times. `position` is the
    /// number of lyric lines read before the row: the closest earlier line at
    /// the same time is tried first, then the lines after it, and the first
    /// one whose text the markers fit wins. Lines that already carry word
    /// timing are left alone.
    public static func applying(
        _ rows: [(row: Row, position: Int)],
        to lines: [LyricLine]
    ) -> [LyricLine] {
        var lines = lines
        for (row, position) in rows {
            guard let timing = row.timing else { continue }
            let pivot = min(max(0, position), lines.count)
            for start in row.starts {
                let candidates = Array(lines.indices[..<pivot].reversed())
                    + Array(lines.indices[pivot...])
                for index in candidates
                where abs(lines[index].timestamp - start) <= timestampTolerance
                    && !lines[index].isWordLevel {
                    if let timed = timed(lines[index], by: timing) {
                        lines[index] = timed
                        break
                    }
                }
            }
        }
        return lines
    }

    /// The line with its words timed, or `nil` when the markers do not fit
    /// its text: indices out of order or past the end, times running
    /// backwards, or a first marker that does not open the line.
    static func timed(_ line: LyricLine, by timing: Timing) -> LyricLine? {
        let text = line.text
        let marks = timing.marks
        guard line.isSynchronized, !text.isEmpty,
              let first = marks.first, let last = marks.last,
              first.index == 0, first.offset >= 0 else { return nil }
        for (current, next) in zip(marks, marks.dropFirst())
        where next.index <= current.index || next.offset < current.offset {
            return nil
        }
        if let duration = timing.duration, duration < last.offset { return nil }
        guard let boundaries = boundaries(of: text, lastIndex: last.index) else { return nil }

        let lineStart = (line.timestamp * 1_000).rounded()
        func seconds(_ offset: Int) -> TimeInterval { (lineStart + Double(offset)) / 1_000 }

        var syllables: [LyricSyllable] = []
        for (position, mark) in marks.enumerated() {
            let next = marks.indices.contains(position + 1) ? marks[position + 1] : nil
            guard let lower = boundaries[mark.index] else { return nil }
            let upper: String.Index
            if let next {
                guard let bound = boundaries[next.index] else { return nil }
                upper = bound
            } else {
                upper = text.endIndex
            }
            guard lower < upper else { continue }
            let start = seconds(mark.offset)
            let end: TimeInterval
            let endTiming: LyricSyllableEndTiming
            if let next {
                // Only the closing marker states where the last word ends.
                let closesLine = next.index == boundaries.count - 1
                    && position + 1 == marks.count - 1
                end = seconds(next.offset)
                endTiming = closesLine ? .explicit : .inferred
            } else if let duration = timing.duration {
                end = seconds(duration)
                endTiming = .explicit
            } else {
                end = start + inferredTailDuration
                endTiming = .inferred
            }
            syllables.append(LyricSyllable(
                text: String(text[lower..<upper]),
                start: start,
                end: end,
                endTiming: endTiming
            ))
        }
        guard !syllables.isEmpty else { return nil }
        var timed = line
        timed.syllables = syllables
        return timed
    }

    /// String positions for every index the markers can name, counted in the
    /// unit the writer used. Characters are the norm; a writer that counted
    /// UTF-16 units or scalars is recognized by its closing marker landing
    /// exactly on that count. A position inside a character is refused.
    private static func boundaries(of text: String, lastIndex: Int) -> [String.Index?]? {
        if lastIndex <= text.count {
            return Array(text.indices) + [text.endIndex]
        }
        if lastIndex == text.unicodeScalars.count {
            return positions(text.unicodeScalars.indices, in: text)
        }
        if lastIndex == text.utf16.count {
            return positions(text.utf16.indices, in: text)
        }
        return nil
    }

    /// A unit inside a character maps to `nil`, so a marker naming it makes
    /// the whole line fall back instead of splitting the character.
    private static func positions(
        _ indices: some Sequence<String.Index>,
        in text: String
    ) -> [String.Index?] {
        indices.map { $0.samePosition(in: text) } + [text.endIndex]
    }

    private static func timing(in rest: Substring) -> Timing? {
        var marks: [Mark] = []
        var duration: Int?
        var cursor = rest.drop { $0.isWhitespace }
        while !cursor.isEmpty {
            guard duration == nil, cursor.hasPrefix("<"),
                  let close = cursor.firstIndex(of: ">") else { return nil }
            let fields = cursor[cursor.index(after: cursor.startIndex)..<close]
                .split(separator: ",", omittingEmptySubsequences: false)
                .map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard fields.allSatisfy({ ($0 ?? -1) >= 0 && ($0 ?? 0) <= maximumMilliseconds }) else {
                return nil
            }
            switch fields.count {
            case 2:
                marks.append(Mark(offset: fields[0] ?? 0, index: fields[1] ?? 0))
            case 1:
                duration = fields[0]
            default:
                return nil
            }
            cursor = cursor[cursor.index(after: close)...].drop { $0.isWhitespace }
        }
        return marks.isEmpty ? nil : Timing(marks: marks, duration: duration)
    }

    /// `mm:ss`, `mm:ss.xx` or `mm:ss.xxx`, read the way the LRC reader does.
    private static func timestamp(_ text: Substring) -> TimeInterval? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let minutes = text[..<colon]
        var rest = text[text.index(after: colon)...]
        let seconds = rest.prefix(2)
        rest = rest.dropFirst(seconds.count)
        guard !minutes.isEmpty, minutes.allSatisfy(\.isASCIINumber),
              seconds.count == 2, seconds.allSatisfy(\.isASCIINumber),
              let minuteValue = Double(minutes), let secondValue = Double(seconds),
              secondValue < 60 else { return nil }
        var fraction = 0.0
        if let separator = rest.first {
            let digits = rest.dropFirst()
            guard separator == "." || separator == ":",
                  (1...3).contains(digits.count), digits.allSatisfy(\.isASCIINumber),
                  let value = Double(digits) else { return nil }
            fraction = value / pow(10, Double(digits.count))
        }
        return minuteValue * 60 + secondValue + fraction
    }
}

private extension Character {
    var isASCIINumber: Bool { isASCII && isNumber }
}
