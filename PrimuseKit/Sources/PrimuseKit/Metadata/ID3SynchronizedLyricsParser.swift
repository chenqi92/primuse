import Foundation

/// Decodes the ID3 `SYLT` frame (`SLT` in ID3v2.2), which carries lyrics that
/// are already timed. The frame is rendered as LRC/ELRC text so synchronized
/// tag lyrics travel the same parsing, caching and editing path as a sidecar.
public enum ID3SynchronizedLyricsParser {
    /// `$02` is the only timestamp format that can be honored without decoding
    /// the audio stream; `$01` counts MPEG frames, whose duration depends on
    /// the bitstream.
    private static let millisecondTimestampFormat: UInt8 = 2
    /// Content types `$01` (lyrics) and `$02` (text transcription) are sung
    /// words. Everything else — events, chords, trivia — is not a lyric.
    private static let lyricContentTypes: Set<UInt8> = [1, 2]

    public struct Frame: Equatable, Sendable {
        /// LRC text when every cue starts its own line, ELRC when cues time
        /// individual words inside a line.
        public let text: String
        public let languageCode: String?
        public let descriptor: String

        public init(text: String, languageCode: String?, descriptor: String) {
            self.text = text
            self.languageCode = languageCode
            self.descriptor = descriptor
        }
    }

    private struct Cue {
        let text: String
        let milliseconds: Int
        let startsLine: Bool
    }

    public static func parse(_ payload: Data) -> Frame? {
        parse(payload, decodeText: TextEncodingRepair.decodeID3Text)
    }

    /// The decoder is injected so the binary layout can be exercised without
    /// the platform text-repair stack.
    static func parse(
        _ payload: Data,
        decodeText: (Data, UInt8) -> String?
    ) -> Frame? {
        let bytes = [UInt8](payload)
        // encoding + language(3) + timestamp format + content type + a
        // descriptor terminator is the shortest possible header.
        guard bytes.count > 7 else { return nil }

        let encoding = bytes[0]
        guard bytes[4] == millisecondTimestampFormat,
              lyricContentTypes.contains(bytes[5]) else { return nil }

        let terminatorLength = (encoding == 1 || encoding == 2) ? 2 : 1
        guard let descriptorEnd = terminatorEnd(
            in: bytes,
            from: 6,
            terminatorLength: terminatorLength
        ) else { return nil }
        let descriptor = decodeText(
            Data(bytes[6..<(descriptorEnd - terminatorLength)]),
            encoding
        ) ?? ""

        var cues: [Cue] = []
        var cursor = descriptorEnd
        while cursor < bytes.count {
            guard let textEnd = terminatorEnd(
                in: bytes,
                from: cursor,
                terminatorLength: terminatorLength
            ), textEnd + 4 <= bytes.count else { break }

            let rawBytes = bytes[cursor..<(textEnd - terminatorLength)]
            let decoded = decodeText(Data(rawBytes), encoding) ?? ""
            let milliseconds = bytes[textEnd..<(textEnd + 4)].reduce(0) { total, byte in
                total << 8 | Int(byte)
            }
            cursor = textEnd + 4

            // The shared ID3 text decoder trims surrounding whitespace, but in
            // SYLT it is meaningful: a leading newline starts a new line and a
            // leading space separates a word from the one before it.
            let edges = edgeWhitespace(rawBytes, encoding: encoding)
            var raw = decoded
            if raw.first?.isWhitespace != true { raw = edges.leading + raw }
            if raw.last?.isWhitespace != true { raw += edges.trailing }

            // The spec starts every new lyric line with a newline inside the
            // cue text, which is how word cues and line cues are told apart.
            let startsLine = cues.isEmpty || raw.first?.isNewline == true
            // Some writers put a line and its translation in one cue,
            // separated by a newline: each becomes its own line at that time,
            // where the lyric parser pairs them like bilingual LRC.
            let parts = raw
                .drop(while: \.isNewline)
                .split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            for (index, part) in parts.enumerated() {
                cues.append(Cue(
                    text: index == 0 ? part : part.trimmingCharacters(in: .whitespaces),
                    milliseconds: milliseconds,
                    startsLine: index == 0 ? startsLine : true
                ))
            }
        }

        guard !cues.isEmpty else { return nil }
        return Frame(
            text: render(cues),
            languageCode: languageCode(in: bytes),
            descriptor: descriptor.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Whitespace at either end of a cue, read from its bytes.
    private static func edgeWhitespace(
        _ bytes: ArraySlice<UInt8>,
        encoding: UInt8
    ) -> (leading: String, trailing: String) {
        let units: [UInt16]
        switch encoding {
        case 1, 2:
            var bytes = bytes
            var bigEndian = encoding == 2
            if bytes.starts(with: [0xFF, 0xFE]) {
                bigEndian = false
                bytes = bytes.dropFirst(2)
            } else if bytes.starts(with: [0xFE, 0xFF]) {
                bigEndian = true
                bytes = bytes.dropFirst(2)
            }
            let pairs = Array(bytes)
            units = stride(from: 0, to: pairs.count - 1, by: 2).map { index in
                bigEndian
                    ? UInt16(pairs[index]) << 8 | UInt16(pairs[index + 1])
                    : UInt16(pairs[index + 1]) << 8 | UInt16(pairs[index])
            }
        default:
            units = bytes.map(UInt16.init)
        }
        func whitespace(_ unit: UInt16) -> Character? {
            switch unit {
            case 0x20: return " "
            case 0x09: return "\t"
            case 0x0A, 0x0D: return "\n"
            default: return nil
            }
        }
        let leading = String(units.prefix { whitespace($0) != nil }.compactMap(whitespace))
        guard leading.count < units.count else { return (leading, "") }
        let trailing = String(
            units.reversed().prefix { whitespace($0) != nil }.compactMap(whitespace).reversed()
        )
        return (leading, trailing)
    }

    /// Lines are formed in file order (the newline markers decide them), then
    /// placed on the timeline: words inside a line, and lines by their first
    /// cue. Sorting cues globally instead would move a later word of one line
    /// behind a translation line that shares its start time.
    private static func render(_ cues: [Cue]) -> String {
        var groups: [[Cue]] = []
        for cue in cues {
            if cue.startsLine || groups.isEmpty {
                groups.append([cue])
            } else {
                groups[groups.count - 1].append(cue)
            }
        }
        let ordered = groups
            .map(sortedByTime)
            .enumerated()
            .sorted {
                let lhs = $0.element[0].milliseconds
                let rhs = $1.element[0].milliseconds
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }
            .map(\.element)

        return ordered.map { line in
            let first = line[0]
            guard line.count > 1 else {
                return "[\(timestamp(first.milliseconds))]\(first.text)"
            }
            // More than one cue inside a line times individual words.
            let body = line
                .map { "<\(timestamp($0.milliseconds))>\($0.text)" }
                .joined()
            return "[\(timestamp(first.milliseconds))]\(body)"
        }.joined(separator: "\n")
    }

    private static func sortedByTime(_ cues: [Cue]) -> [Cue] {
        cues.enumerated().sorted {
            $0.element.milliseconds == $1.element.milliseconds
                ? $0.offset < $1.offset
                : $0.element.milliseconds < $1.element.milliseconds
        }.map(\.element)
    }

    private static func timestamp(_ milliseconds: Int) -> String {
        let value = max(0, milliseconds)
        return String(
            format: "%02d:%02d.%03d",
            value / 60_000,
            (value % 60_000) / 1_000,
            value % 1_000
        )
    }

    private static func languageCode(in bytes: [UInt8]) -> String? {
        let raw = String(decoding: bytes[1..<4], as: UTF8.self).lowercased()
        guard raw.utf8.count == 3,
              raw.utf8.allSatisfy({ (0x61...0x7A).contains($0) }),
              !["und", "xxx", "zxx"].contains(raw) else { return nil }
        return LyricLanguageCodePolicy.canonicalIdentifier(raw)
    }

    /// Returns the index just past the string terminator, honoring the
    /// two-byte terminator of the UTF-16 encodings.
    private static func terminatorEnd(
        in bytes: [UInt8],
        from start: Int,
        terminatorLength: Int
    ) -> Int? {
        guard start <= bytes.count else { return nil }
        if terminatorLength == 1 {
            guard let index = bytes[start...].firstIndex(of: 0) else { return nil }
            return index + 1
        }
        // UTF-16 code units are two bytes wide and start at `start`, so the
        // terminator can only sit on an even offset from there.
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 { return index + 2 }
            index += 2
        }
        return nil
    }
}
