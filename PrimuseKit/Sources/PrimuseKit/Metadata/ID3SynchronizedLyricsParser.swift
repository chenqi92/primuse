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

            let raw = decodeText(Data(bytes[cursor..<(textEnd - terminatorLength)]), encoding) ?? ""
            let milliseconds = bytes[textEnd..<(textEnd + 4)].reduce(0) { total, byte in
                total << 8 | Int(byte)
            }
            cursor = textEnd + 4

            // The spec starts every new lyric line with a newline inside the
            // cue text, which is how word cues and line cues are told apart.
            let startsLine = cues.isEmpty || raw.first?.isNewline == true
            let text = raw.trimmingCharacters(in: .newlines)
            guard !text.isEmpty else { continue }
            cues.append(Cue(text: text, milliseconds: milliseconds, startsLine: startsLine))
        }

        guard !cues.isEmpty else { return nil }
        return Frame(
            text: render(cues.enumerated().sorted {
                $0.element.milliseconds == $1.element.milliseconds
                    ? $0.offset < $1.offset
                    : $0.element.milliseconds < $1.element.milliseconds
            }.map(\.element)),
            languageCode: languageCode(in: bytes),
            descriptor: descriptor.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func render(_ cues: [Cue]) -> String {
        var lines: [String] = []
        var current: [Cue] = []

        func flush() {
            guard let first = current.first else { return }
            if current.count == 1 {
                lines.append("[\(timestamp(first.milliseconds))]\(first.text)")
            } else {
                // More than one cue inside a line times individual words.
                let body = current
                    .map { "<\(timestamp($0.milliseconds))>\($0.text)" }
                    .joined()
                lines.append("[\(timestamp(first.milliseconds))]\(body)")
            }
            current = []
        }

        for cue in cues {
            if cue.startsLine { flush() }
            current.append(cue)
        }
        flush()
        return lines.joined(separator: "\n")
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
