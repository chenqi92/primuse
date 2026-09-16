import Foundation

/// Word-timed lyric documents that carry their timing in milliseconds rather
/// than in LRC timestamps. All three describe the same thing Primuse already
/// models — words with explicit start and end, a duet voice and backing
/// vocals — so they are normalized into `LyricLine` instead of gaining their
/// own playback path.
public enum WordTimedLyricsFormat: String, Sendable {
    /// Lyricify Syllable: `[property]word(start,duration)…`, where the
    /// property digit encodes both the duet voice and the backing group.
    case lys
    /// NetEase word lyrics: `[lineStart,lineDuration](start,duration,0)word…`,
    /// with each marker in front of the word it times.
    case yrc
    /// QQ Music word lyrics: `[lineStart,lineDuration]word(start,duration)…`,
    /// usually delivered inside a `<Lyric_1 LyricContent="…"/>` wrapper.
    case qrc
}

/// Parses the millisecond word-timed lyric formats. Detection is content based
/// so a document reaches the same result through a sidecar file, an embedded
/// tag or a server response.
public enum WordTimedLyricsParser {
    /// Backing vocals are written as a fully parenthesized line in all three
    /// formats. The markers are presentation, not lyrics, so they are removed
    /// once the line is known to be a backing group.
    private static let openingParentheses: Set<Character> = ["(", "（"]
    private static let closingParentheses: Set<Character> = [")", "）"]

    private struct ParsedWord {
        var text: String
        let start: Int
        let duration: Int
    }

    private struct ParsedLine {
        var words: [ParsedWord]
        let start: Int?
        let duration: Int?
        let isDuet: Bool
        var isBackground: Bool
    }

    public static func detect(_ content: String) -> WordTimedLyricsFormat? {
        let body = unwrappingQRCDocument(content) ?? content
        var lysLines = 0
        var yrcLines = 0
        var qrcLines = 0

        for raw in body.components(separatedBy: .newlines).prefix(80) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !isDocumentMetadata(line) else { continue }
            if lysProperty(in: line) != nil, !wordMarkers(in: line, fieldCount: 2).isEmpty {
                lysLines += 1
            } else if lineHeader(in: line) != nil {
                if !wordMarkers(in: line, fieldCount: 3).isEmpty {
                    yrcLines += 1
                } else if !wordMarkers(in: line, fieldCount: 2).isEmpty {
                    qrcLines += 1
                }
            }
        }

        let best = max(lysLines, yrcLines, qrcLines)
        guard best > 0 else { return nil }
        if best == lysLines { return .lys }
        if best == yrcLines { return .yrc }
        return .qrc
    }

    public static func parse(_ content: String) -> [LyricLine] {
        guard let format = detect(content) else { return [] }
        return parse(content, as: format)
    }

    public static func parse(
        _ content: String,
        as format: WordTimedLyricsFormat
    ) -> [LyricLine] {
        let body = unwrappingQRCDocument(content) ?? content
        var metadataLines: [String] = []
        var lines: [LyricLine] = []

        for raw in body.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if isDocumentMetadata(trimmed) {
                if trimmed.hasPrefix("[") { metadataLines.append(trimmed) }
                continue
            }
            guard var parsed = parseLine(trimmed, as: format) else { continue }
            resolveBackgroundMarkers(in: &parsed)
            guard let line = makeLine(parsed) else { continue }

            // A backing group belongs to the line it answers, matching how
            // TTML `x-bg` groups are modeled.
            if parsed.isBackground,
               let hostIndex = lines.indices.last {
                lines[hostIndex].background = (lines[hostIndex].background ?? []) + [line]
                continue
            }
            lines.append(line)
        }

        guard !lines.isEmpty else { return [] }
        if let offset = LyricDocumentOffsetPolicy.offsetSeconds(in: metadataLines) {
            lines = LyricDocumentOffsetPolicy.applying(offset: offset, to: lines)
            metadataLines = LyricDocumentOffsetPolicy.removingOffsetTag(from: metadataLines)
        }
        if !metadataLines.isEmpty {
            lines[0].metadataLines = metadataLines
        }
        return lines
    }

    // MARK: - Line parsing

    private static func parseLine(
        _ line: String,
        as format: WordTimedLyricsFormat
    ) -> ParsedLine? {
        switch format {
        case .lys:
            return parseLYSLine(line)
        case .qrc:
            return parseQRCLine(line)
        case .yrc:
            return parseYRCLine(line)
        }
    }

    private static func parseLYSLine(_ line: String) -> ParsedLine? {
        guard let property = lysProperty(in: line) else { return nil }
        let content = String(line[property.contentStart...])
        let words = trailingTimedWords(in: content)
        guard !words.isEmpty else { return nil }
        return ParsedLine(
            words: words,
            start: words.first?.start,
            duration: nil,
            isDuet: property.isDuet,
            // An unset property falls back to the parenthesis convention.
            isBackground: property.isBackground ?? false
        )
    }

    private static func parseQRCLine(_ line: String) -> ParsedLine? {
        guard let header = lineHeader(in: line) else { return nil }
        let words = trailingTimedWords(in: String(line[header.contentStart...]))
        guard !words.isEmpty else { return nil }
        return ParsedLine(
            words: words,
            start: header.start,
            duration: header.duration,
            isDuet: false,
            isBackground: false
        )
    }

    private static func parseYRCLine(_ line: String) -> ParsedLine? {
        guard let header = lineHeader(in: line) else { return nil }
        let words = leadingTimedWords(in: String(line[header.contentStart...]))
        guard !words.isEmpty else { return nil }
        return ParsedLine(
            words: words,
            start: header.start,
            duration: header.duration,
            isDuet: false,
            isBackground: false
        )
    }

    /// LYS and QRC place the marker after the word it times.
    private static func trailingTimedWords(in content: String) -> [ParsedWord] {
        var words: [ParsedWord] = []
        var cursor = content.startIndex
        var textStart = content.startIndex

        while let marker = nextMarker(in: content, from: cursor, fieldCount: 2) {
            words.append(ParsedWord(
                text: String(content[textStart..<marker.start]),
                start: marker.fields[0],
                duration: marker.fields[1]
            ))
            cursor = marker.end
            textStart = marker.end
        }
        return words
    }

    /// YRC places the marker in front of the word it times, so the text of a
    /// word runs until the next marker or the end of the line.
    private static func leadingTimedWords(in content: String) -> [ParsedWord] {
        var markers: [(start: Int, duration: Int, textStart: String.Index)] = []
        var cursor = content.startIndex
        var textEnds: [String.Index] = []

        while let marker = nextMarker(in: content, from: cursor, fieldCount: 3) {
            if !markers.isEmpty { textEnds.append(marker.start) }
            markers.append((marker.fields[0], marker.fields[1], marker.end))
            cursor = marker.end
        }
        guard !markers.isEmpty else { return [] }
        textEnds.append(content.endIndex)

        return zip(markers, textEnds).map { marker, textEnd in
            ParsedWord(
                text: String(content[marker.textStart..<textEnd]),
                start: marker.start,
                duration: marker.duration
            )
        }
    }

    private static func makeLine(_ parsed: ParsedLine) -> LyricLine? {
        let syllables = parsed.words.compactMap { word -> LyricSyllable? in
            guard !word.text.isEmpty else { return nil }
            // Milliseconds are summed before the conversion so an end lands on
            // an exact millisecond instead of a binary fraction of one.
            return LyricSyllable(
                text: word.text,
                start: seconds(word.start),
                end: seconds(word.start + max(0, word.duration)),
                endTiming: .explicit
            )
        }
        guard !syllables.isEmpty else { return nil }

        let text = syllables.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let timestamp = parsed.start.map(seconds) ?? syllables[0].start
        var headerEnd: TimeInterval?
        if let start = parsed.start, let duration = parsed.duration {
            headerEnd = seconds(start + duration)
        }
        return LyricLine(
            timestamp: timestamp,
            text: text,
            isSynchronized: true,
            syllables: syllables,
            endTimestamp: max(headerEnd ?? 0, syllables[syllables.count - 1].end),
            voice: parsed.isDuet || parsed.isBackground ? .secondary : .primary
        )
    }

    /// Every one of these formats writes a backing group as a line wrapped in
    /// parentheses. LYS may state it in the property digit instead, in which
    /// case the stated value wins.
    private static func resolveBackgroundMarkers(in parsed: inout ParsedLine) {
        guard let firstIndex = parsed.words.firstIndex(where: { !$0.text.isEmpty }),
              let lastIndex = parsed.words.lastIndex(where: { !$0.text.isEmpty }) else {
            return
        }
        let opensWithParenthesis = parsed.words[firstIndex].text
            .trimmingCharacters(in: .whitespaces)
            .first
            .map(openingParentheses.contains) ?? false
        let closesWithParenthesis = parsed.words[lastIndex].text
            .trimmingCharacters(in: .whitespaces)
            .last
            .map(closingParentheses.contains) ?? false
        let isParenthesized = opensWithParenthesis && closesWithParenthesis
        guard parsed.isBackground || isParenthesized else { return }

        parsed.isBackground = true
        guard isParenthesized else { return }
        parsed.words[firstIndex].text = removingLeadingParenthesis(
            from: parsed.words[firstIndex].text
        )
        parsed.words[lastIndex].text = removingTrailingParenthesis(
            from: parsed.words[lastIndex].text
        )
    }

    private static func removingLeadingParenthesis(from text: String) -> String {
        guard let index = text.firstIndex(where: { !$0.isWhitespace }),
              openingParentheses.contains(text[index]) else { return text }
        return String(text[text.startIndex..<index]) + String(text[text.index(after: index)...])
    }

    private static func removingTrailingParenthesis(from text: String) -> String {
        guard let index = text.lastIndex(where: { !$0.isWhitespace }),
              closingParentheses.contains(text[index]) else { return text }
        return String(text[text.startIndex..<index]) + String(text[text.index(after: index)...])
    }

    // MARK: - Tokens

    private struct Marker {
        let fields: [Int]
        let start: String.Index
        let end: String.Index
    }

    /// Finds the next `(a,b)` / `(a,b,c)` marker. Lyrics legitimately contain
    /// parentheses, so a candidate only counts when it holds exactly the
    /// expected number of integer fields.
    private static func nextMarker(
        in text: String,
        from index: String.Index,
        fieldCount: Int
    ) -> Marker? {
        var cursor = index
        while let open = text[cursor...].firstIndex(where: { openingParentheses.contains($0) }) {
            if text[open] == "(",
               let close = text[open...].firstIndex(of: ")") {
                let fields = text[text.index(after: open)..<close]
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { Int($0.trimmingCharacters(in: .whitespaces)) }
                if fields.count == fieldCount, fields.allSatisfy({ $0 != nil }) {
                    return Marker(
                        fields: fields.compactMap { $0 },
                        start: open,
                        end: text.index(after: close)
                    )
                }
            }
            guard open < text.endIndex else { return nil }
            cursor = text.index(after: open)
        }
        return nil
    }

    private struct LYSProperty {
        let isDuet: Bool
        let isBackground: Bool?
        let contentStart: String.Index
    }

    private static func lysProperty(in line: String) -> LYSProperty? {
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]") else { return nil }
        let digits = line[line.index(after: line.startIndex)..<close]
        guard digits.count == 1, let property = Int(digits), (0...8).contains(property) else {
            return nil
        }
        // Property groups: 0-2 leave the backing flag unset, 3-5 are lead
        // voices and 6-8 are backing groups; within a group the remainder
        // selects the duet voice.
        return LYSProperty(
            isDuet: property % 3 == 2,
            isBackground: property <= 2 ? nil : property >= 6,
            contentStart: line.index(after: close)
        )
    }

    private struct LineHeader {
        let start: Int
        let duration: Int
        let contentStart: String.Index
    }

    private static func lineHeader(in line: String) -> LineHeader? {
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]") else { return nil }
        let fields = line[line.index(after: line.startIndex)..<close]
            .split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let start = Int(fields[0].trimmingCharacters(in: .whitespaces)),
              let duration = Int(fields[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, duration >= 0 else { return nil }
        return LineHeader(
            start: start,
            duration: duration,
            contentStart: line.index(after: close)
        )
    }

    private static func wordMarkers(in line: String, fieldCount: Int) -> [Marker] {
        var markers: [Marker] = []
        var cursor = line.startIndex
        while let marker = nextMarker(in: line, from: cursor, fieldCount: fieldCount) {
            markers.append(marker)
            cursor = marker.end
        }
        return markers
    }

    /// LRC-style headers and the JSON credit rows NetEase puts at the top of a
    /// `.yrc` file describe the document, not a sung line.
    private static func isDocumentMetadata(_ line: String) -> Bool {
        if line.hasPrefix("{") { return true }
        guard line.hasPrefix("["), line.hasSuffix("]"),
              let separator = line.firstIndex(of: ":") else { return false }
        let key = line[line.index(after: line.startIndex)..<separator]
        return !key.isEmpty && key.allSatisfy { $0.isLetter }
    }

    /// QQ Music ships `.qrc` content inside a small XML envelope.
    private static func unwrappingQRCDocument(_ content: String) -> String? {
        guard content.range(of: "LyricContent", options: .caseInsensitive) != nil,
              let attribute = content.range(
                  of: "LyricContent=\"",
                  options: .caseInsensitive
              ),
              let close = content[attribute.upperBound...].firstIndex(of: "\"") else {
            return nil
        }
        let escaped = content[attribute.upperBound..<close]
        return escaped
            .replacingOccurrences(of: "&#10;", with: "\n")
            .replacingOccurrences(of: "&#13;", with: "")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func seconds(_ milliseconds: Int) -> TimeInterval {
        TimeInterval(milliseconds) / 1_000
    }
}
