import Foundation

/// SubStation Alpha (`.ssa`) and Advanced SubStation Alpha (`.ass`) subtitles
/// read as lyrics. Karaoke subtitles time each syllable with override tags:
///
///     [Events]
///     Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
///     Dialogue: 0,0:00:12.30,0:00:15.00,Default,,0,0,0,,{\k40}Light {\k35}on {\k60}the {\k90}water
///
/// `\k`, `\K`, `\kf` and `\ko` give the length of the syllable that follows
/// in centiseconds, one after another from the line start; `\kt` moves the
/// running time to an offset from the line start. Every other override is
/// presentation and is dropped. A line without karaoke tags stays a timed
/// line. Lines rendered by a karaoke template (`fx`) are skipped in favor of
/// the `karaoke` comment lines they were generated from.
enum ASSKaraokeLyricsParser {
    private static let defaultFields = [
        "layer", "start", "end", "style", "name",
        "marginl", "marginr", "marginv", "effect", "text",
    ]

    private struct Syllable {
        var text: String
        let start: Int
        let end: Int
    }

    static func isDocument(_ document: String) -> Bool {
        var hasEvents = false
        for line in document.split(separator: "\n", omittingEmptySubsequences: true).prefix(400) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.caseInsensitiveCompare("[Events]") == .orderedSame {
                hasEvents = true
            } else if hasEvents, eventKind(trimmed) != nil {
                return true
            }
        }
        return false
    }

    static func parse(_ document: String, options: LyricsParsingOptions) -> [LyricLine] {
        var inEvents = false
        var fields = defaultFields
        var lines: [LyricLine] = []

        for raw in document.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                inEvents = line.caseInsensitiveCompare("[Events]") == .orderedSame
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                let named = line.dropFirst("format:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                // Text is always the last field; without it the line layout
                // cannot be trusted.
                if named.last == "text" { fields = named }
                continue
            }
            guard let kind = eventKind(line),
                  let parsed = parseEvent(line.dropFirst(kind.prefixLength), kind: kind, fields: fields)
            else { continue }
            lines.append(parsed)
        }

        if options.detectBilingualLRC {
            lines = LyricBilingualPairingPolicy.pair(lines)
        }
        return lines.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp == rhs.element.timestamp {
                return lhs.offset < rhs.offset
            }
            return lhs.element.timestamp < rhs.element.timestamp
        }.map(\.element)
    }

    // MARK: - Events

    private enum EventKind {
        case dialogue
        case comment

        var prefixLength: Int { self == .dialogue ? "Dialogue:".count : "Comment:".count }
    }

    private static func eventKind(_ line: String) -> EventKind? {
        let lowered = line.prefix(9).lowercased()
        if lowered.hasPrefix("dialogue:") { return .dialogue }
        if lowered.hasPrefix("comment:") { return .comment }
        return nil
    }

    private static func parseEvent(
        _ body: Substring,
        kind: EventKind,
        fields: [String]
    ) -> LyricLine? {
        let values = body.split(
            separator: ",",
            maxSplits: max(0, fields.count - 1),
            omittingEmptySubsequences: false
        )
        guard values.count == fields.count,
              let startIndex = fields.firstIndex(of: "start"),
              let endIndex = fields.firstIndex(of: "end"),
              let start = centiseconds(values[startIndex]),
              let end = centiseconds(values[endIndex]) else { return nil }
        let effect = fields.firstIndex(of: "effect")
            .map { values[$0].trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        // A karaoke template keeps its source lines as `karaoke` comments and
        // renders each syllable as an `fx` line; only the source is a lyric.
        switch kind {
        case .dialogue where effect == "fx":
            return nil
        case .comment where effect != "karaoke":
            return nil
        default:
            break
        }

        let (prefix, syllables) = karaokeSyllables(in: String(values[values.count - 1]), lineStart: start)
        let lineEnd = end > start ? seconds(end) : nil
        let timed = syllables.filter { !$0.text.isEmpty }
        guard !timed.isEmpty else {
            let text = collapsedWhitespace(prefix)
            guard !text.isEmpty else { return nil }
            return LyricLine(
                timestamp: seconds(start),
                text: text,
                isSynchronized: true,
                endTimestamp: lineEnd
            )
        }

        var words = timed
        // Text before the first karaoke tag is sung with the first syllable.
        words[0].text = prefix + words[0].text
        let lyricSyllables = words.map {
            LyricSyllable(text: $0.text, start: seconds($0.start), end: seconds($0.end), endTiming: .explicit)
        }
        let text = lyricSyllables.map(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return LyricLine(
            timestamp: seconds(start),
            text: text,
            isSynchronized: true,
            syllables: lyricSyllables,
            endTimestamp: lineEnd
        )
    }

    // MARK: - Karaoke tags

    /// Splits the text field into the untimed text before the first karaoke
    /// tag and the timed syllables after it. Whitespace-only syllables are
    /// folded into the syllable before them so the line keeps its spaces.
    private static func karaokeSyllables(
        in text: String,
        lineStart: Int
    ) -> (prefix: String, syllables: [Syllable]) {
        var prefix = ""
        var syllables: [Syllable] = []
        var current: Syllable?
        var clock = lineStart
        var drawing = false

        func flush() {
            guard let syllable = current else { return }
            current = nil
            if !syllable.text.isEmpty, syllable.text.allSatisfy(\.isWhitespace),
               let last = syllables.indices.last {
                syllables[last].text += syllable.text
                return
            }
            syllables.append(syllable)
        }

        func append(_ string: String) {
            guard !drawing else { return }
            if current != nil {
                current?.text += string
            } else {
                prefix += string
            }
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{", let close = text[index...].firstIndex(of: "}") {
                let block = text[text.index(after: index)..<close]
                for tag in overrideTags(in: block) {
                    switch tag.name {
                    case "k", "K", "kf", "ko":
                        flush()
                        let end = clock + tag.value
                        current = Syllable(text: "", start: clock, end: end)
                        clock = end
                    case "kt":
                        clock = lineStart + tag.value
                    case "p":
                        drawing = tag.value > 0
                    default:
                        break
                    }
                }
                index = text.index(after: close)
                continue
            }
            if character == "\\", let next = text[text.index(after: index)...].first,
               next == "N" || next == "n" || next == "h" {
                append(" ")
                index = text.index(index, offsetBy: 2)
                continue
            }
            append(String(character))
            index = text.index(after: index)
        }
        flush()
        return (prefix, syllables)
    }

    private struct OverrideTag {
        let name: String
        let value: Int
    }

    /// The `\name<number>` tags in one override block. Only tags that carry a
    /// whole number are kept; the karaoke and drawing tags are among them.
    private static func overrideTags(in block: Substring) -> [OverrideTag] {
        var tags: [OverrideTag] = []
        for piece in block.split(separator: "\\").dropFirst(block.hasPrefix("\\") ? 0 : 1) {
            let name = piece.prefix { $0.isASCII && $0.isLetter }
            let digits = piece.dropFirst(name.count).prefix { $0.isASCII && $0.isNumber }
            guard !name.isEmpty, !digits.isEmpty, let value = Int(digits),
                  value <= 1_000_000 else { continue }
            tags.append(OverrideTag(name: String(name), value: value))
        }
        return tags
    }

    // MARK: - Time

    /// `H:MM:SS.cc`. Hundredths are the norm; a writer that keeps
    /// milliseconds is read to the nearest hundredth.
    private static func centiseconds(_ field: Substring) -> Int? {
        let parts = field.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3,
              let hours = Int(parts[0]), let minutes = Int(parts[1]),
              hours >= 0, hours <= 100, (0..<60).contains(minutes) else { return nil }
        let secondParts = parts[2].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(secondParts.count),
              let wholeSeconds = Int(secondParts[0]), (0..<60).contains(wholeSeconds) else { return nil }
        var fraction = 0
        if secondParts.count == 2 {
            let digits = secondParts[1]
            guard (1...3).contains(digits.count), let value = Int(digits) else { return nil }
            switch digits.count {
            case 1: fraction = value * 10
            case 2: fraction = value
            default: fraction = (value + 5) / 10
            }
        }
        return ((hours * 60 + minutes) * 60 + wholeSeconds) * 100 + fraction
    }

    private static func seconds(_ centiseconds: Int) -> TimeInterval {
        TimeInterval(centiseconds) / 100
    }

    private static func collapsedWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
