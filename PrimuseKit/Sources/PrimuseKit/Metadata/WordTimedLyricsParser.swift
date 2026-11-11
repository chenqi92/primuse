import Foundation

/// Word-timed lyric documents that carry their timing in milliseconds rather
/// than in LRC timestamps. All of them describe the same thing Primuse already
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
    /// Relative word lyrics: `[lineStart,lineDuration]<offset,duration,0>word…`.
    /// Like YRC each marker precedes the word it times, but the offset counts
    /// from the line start instead of from the start of the song. A
    /// `[language:]` header may carry a base64 JSON block with a translation
    /// and a word-by-word romanization of every line.
    case krc
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
        let body = documentBody(content)
        var lysLines = 0
        var yrcLines = 0
        var qrcLines = 0
        var krcLines = 0
        var lrcLines = 0

        for raw in body.components(separatedBy: .newlines).prefix(80) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !isDocumentMetadata(line) else { continue }
            if lysProperty(in: line) != nil, !wordMarkers(in: line, fieldCount: 2).isEmpty {
                lysLines += 1
            } else if lineHeader(in: line) != nil {
                if nextAngleMarker(in: line[...], from: line.startIndex) != nil {
                    krcLines += 1
                } else if !wordMarkers(in: line, fieldCount: 3).isEmpty {
                    yrcLines += 1
                } else if !wordMarkers(in: line, fieldCount: 2).isEmpty {
                    qrcLines += 1
                }
            } else if isLRCTimedLine(line) {
                lrcLines += 1
            }
        }

        let best = max(lysLines, yrcLines, qrcLines, krcLines)
        guard best > 0 else { return nil }
        if best == lysLines { return .lys }
        if best == yrcLines { return .yrc }
        if best == qrcLines { return .qrc }
        // Relative angle markers also turn up as single rows inside an LRC
        // document, which the LRC reader already times row by row. Only a
        // document made of them is read as a whole.
        return krcLines > lrcLines ? .krc : nil
    }

    public static func parse(_ content: String) -> [LyricLine] {
        guard let format = detect(content) else { return [] }
        return parse(content, as: format)
    }

    /// Where a parsed row ended up, so a block that annotates rows by their
    /// order in the file can find it again after backing groups were folded.
    private enum Placement {
        case line(Int)
        case background(host: Int, index: Int)
    }

    public static func parse(
        _ content: String,
        as format: WordTimedLyricsFormat
    ) -> [LyricLine] {
        let body = documentBody(content)
        var metadataLines: [String] = []
        var lines: [LyricLine] = []
        var placements: [(row: Int, placement: Placement)] = []
        var rowCount = 0

        for raw in body.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if isDocumentMetadata(trimmed) {
                if trimmed.hasPrefix("[") { metadataLines.append(trimmed) }
                continue
            }
            let row = rowCount
            if lineHeader(in: trimmed) != nil { rowCount += 1 }
            guard var parsed = parseLine(trimmed, as: format) else { continue }
            resolveBackgroundMarkers(in: &parsed)
            guard let line = makeLine(parsed) else { continue }

            // A backing group belongs to the line it answers, matching how
            // TTML `x-bg` groups are modeled.
            if parsed.isBackground,
               let hostIndex = lines.indices.last {
                let childIndex = lines[hostIndex].background?.count ?? 0
                lines[hostIndex].background = (lines[hostIndex].background ?? []) + [line]
                placements.append((row, .background(host: hostIndex, index: childIndex)))
                continue
            }
            lines.append(line)
            placements.append((row, .line(lines.count - 1)))
        }

        guard !lines.isEmpty else { return [] }
        if format == .krc {
            // The block is only read here, so it does not travel on as a
            // header that would be written back stale after an edit.
            let block = KRCLanguageBlock(metadataLines: metadataLines)
            metadataLines = KRCLanguageBlock.removingTag(from: metadataLines)
            block?.annotate(&lines, placements: placements, rowCount: rowCount)
        }
        // Credit rows are sometimes written after the first sung line with an
        // earlier time. Playback looks lines up by time, so they are ordered
        // the way the LRC reader orders them: by time, ties in file order.
        lines = lines.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp == rhs.element.timestamp {
                return lhs.offset < rhs.offset
            }
            return lhs.element.timestamp < rhs.element.timestamp
        }.map(\.element)
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
        case .krc:
            return parseKRCLine(line)
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

    /// Past this much silence after the last word, a line window is taken for
    /// a damaged header. Real files have been seen whose last line claims the
    /// length of the whole song, which would keep that line lit to the end.
    private static let maximumKRCTrailingSilence = 1_000

    private static func parseKRCLine(_ line: String) -> ParsedLine? {
        guard let header = lineHeader(in: line) else { return nil }
        let content = line[header.contentStart...]
        var words: [ParsedWord] = []
        var cursor = content.startIndex
        var pending: (start: Int, duration: Int, textStart: String.Index)?

        func close(at textEnd: String.Index) {
            guard let marker = pending else { return }
            let text = strippingInlineTags(String(content[marker.textStart..<textEnd]))
            // A whitespace-only word is the gap between two words: it joins
            // the word before it so the line text stays intact without a
            // timed blank of its own.
            if !text.isEmpty, text.allSatisfy(\.isWhitespace) {
                if let last = words.indices.last { words[last].text += text }
                return
            }
            words.append(ParsedWord(text: text, start: marker.start, duration: marker.duration))
        }

        while let marker = nextAngleMarker(in: content, from: cursor) {
            close(at: marker.start)
            let (start, startOverflow) = header.start.addingReportingOverflow(marker.fields[0])
            guard !startOverflow, marker.fields[0] >= 0 else { return nil }
            pending = (start, marker.fields[1], marker.end)
            cursor = marker.end
        }
        close(at: content.endIndex)
        guard !words.isEmpty else { return nil }

        let lastEnd = words.map { $0.start + max(0, $0.duration) }.max() ?? header.start
        let headerEnd = header.start + header.duration
        return ParsedLine(
            words: words,
            start: header.start,
            duration: headerEnd > lastEnd + maximumKRCTrailingSilence ? nil : header.duration,
            isDuet: false,
            isBackground: false
        )
    }

    /// Markup this reader does not know (`<b>`, a stray `<1234>`) is removed
    /// from a word rather than shown as lyrics. Only short ASCII tag shapes
    /// qualify, so text such as `<3` survives.
    private static func strippingInlineTags(_ text: String) -> String {
        guard text.contains("<") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<",
               let close = text[text.index(after: index)...].prefix(33).firstIndex(of: ">"),
               text[text.index(after: index)..<close].allSatisfy(isInlineTagCharacter) {
                index = text.index(after: close)
                continue
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    private static func isInlineTagCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || ",:._/-".contains(character)
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
                if fields.count == fieldCount,
                   fields.allSatisfy({ $0.map(isPlausibleMilliseconds) ?? false }) {
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
              start >= 0, duration >= 0,
              isPlausibleMilliseconds(start), isPlausibleMilliseconds(duration) else { return nil }
        return LineHeader(
            start: start,
            duration: duration,
            contentStart: line.index(after: close)
        )
    }

    /// Times are summed in milliseconds, so a value no song can reach is
    /// refused before that sum could overflow.
    private static func isPlausibleMilliseconds(_ value: Int) -> Bool {
        (-1_000_000_000...1_000_000_000).contains(value)
    }

    /// Finds the next `<a,b,c>` marker of a relative word line. As with the
    /// parenthesized markers, only exactly three integer fields count, so an
    /// angle bracket in the lyrics is left alone.
    private static func nextAngleMarker(
        in text: Substring,
        from index: String.Index
    ) -> Marker? {
        var cursor = index
        while cursor < text.endIndex,
              let open = text[cursor...].firstIndex(of: "<") {
            let afterOpen = text.index(after: open)
            if let close = text[afterOpen...].prefix(40).firstIndex(of: ">") {
                let fields = text[afterOpen..<close]
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { Int($0.trimmingCharacters(in: .whitespaces)) }
                if fields.count == 3,
                   fields.allSatisfy({ $0.map { $0 >= 0 && isPlausibleMilliseconds($0) } ?? false }) {
                    return Marker(
                        fields: fields.compactMap { $0 },
                        start: open,
                        end: text.index(after: close)
                    )
                }
            }
            cursor = afterOpen
        }
        return nil
    }

    /// An ordinary `[mm:ss…]` row. Counted only to keep a mostly-LRC document
    /// with a stray relative row on the LRC reader.
    private static func isLRCTimedLine(_ line: String) -> Bool {
        guard line.hasPrefix("[") else { return false }
        let digits = line.dropFirst().prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return false }
        return line.dropFirst(1 + digits.count).first == ":"
    }

    /// The text the line readers walk: the QRC envelope opened and a leading
    /// byte-order mark removed, which would otherwise hide the first header.
    private static func documentBody(_ content: String) -> String {
        let body = unwrappingQRCDocument(content) ?? content
        guard body.unicodeScalars.first == "\u{FEFF}" else { return body }
        return String(body.unicodeScalars.dropFirst())
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

    // MARK: - Translation and romanization block

    /// The `[language:]` header of a relative word document: base64 of
    /// `{"content":[{"type":…,"lyricContent":[[…],…]}],"version":1}`. Type 1
    /// is a translation with one row per lyric row, usually a single string;
    /// type 0 is a romanization with one reading per word. Rows follow the
    /// lyric rows in file order. A block that does not decode, or whose rows
    /// cannot be lined up with the lyrics, is dropped without touching them.
    private struct KRCLanguageBlock {
        private static let tagName = "language"
        /// Written where a row has no translation.
        private static let emptyTranslationMarker = "//"

        private let translations: [[String]]?
        private let romanizations: [[String]]?

        init?(metadataLines: [String]) {
            guard let value = metadataLines.lazy.compactMap(Self.tagValue).first,
                  let data = Self.base64Data(value),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let content = root["content"] as? [Any] else { return nil }
            var translations: [[String]]?
            var romanizations: [[String]]?
            for case let entry as [String: Any] in content {
                guard let type = (entry["type"] as? Int) ?? (entry["type"] as? NSNumber)?.intValue,
                      let rows = entry["lyricContent"] as? [Any] else { continue }
                let strings = rows.map(Self.strings)
                if type == 1, translations == nil { translations = strings }
                if type == 0, romanizations == nil { romanizations = strings }
            }
            guard translations != nil || romanizations != nil else { return nil }
            self.translations = translations
            self.romanizations = romanizations
        }

        static func removingTag(from metadataLines: [String]) -> [String] {
            metadataLines.filter { tagValue($0) == nil }
        }

        func annotate(
            _ lines: inout [LyricLine],
            placements: [(row: Int, placement: Placement)],
            rowCount: Int
        ) {
            for (order, entry) in placements.enumerated() {
                let translation = translations.flatMap {
                    Self.row(in: $0, row: entry.row, order: order, rowCount: rowCount, lineCount: placements.count)
                }
                .flatMap(Self.translationText)
                let romanization = romanizations.flatMap {
                    Self.row(in: $0, row: entry.row, order: order, rowCount: rowCount, lineCount: placements.count)
                }
                .flatMap(Self.romanizationText)
                guard translation != nil || romanization != nil else { continue }
                Self.update(&lines, at: entry.placement) { line in
                    if let translation {
                        line.manualTranslation = LyricManualTranslation(
                            text: translation,
                            source: .embeddedField
                        )
                    }
                    if let romanization { line.romanization = romanization }
                }
            }
        }

        /// Rows normally match every lyric row in the file, empty ones
        /// included; some writers skip the rows that carry no words. Any
        /// other count cannot be lined up and the block is not used.
        private static func row(
            in rows: [[String]],
            row: Int,
            order: Int,
            rowCount: Int,
            lineCount: Int
        ) -> [String]? {
            if rows.count == rowCount, rows.indices.contains(row) { return rows[row] }
            if rows.count == lineCount, rows.indices.contains(order) { return rows[order] }
            return nil
        }

        private static func translationText(_ row: [String]) -> String? {
            let text = row.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != emptyTranslationMarker else { return nil }
            return text
        }

        /// Readings come one per word, each usually ending in a space; they
        /// are joined into one line with single spaces.
        private static func romanizationText(_ row: [String]) -> String? {
            let text = row.joined()
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return text.isEmpty ? nil : text
        }

        private static func update(
            _ lines: inout [LyricLine],
            at placement: Placement,
            _ change: (inout LyricLine) -> Void
        ) {
            switch placement {
            case .line(let index):
                guard lines.indices.contains(index) else { return }
                change(&lines[index])
            case .background(let host, let index):
                guard lines.indices.contains(host),
                      var background = lines[host].background,
                      background.indices.contains(index) else { return }
                change(&background[index])
                lines[host].background = background
            }
        }

        private static func tagValue(_ line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"),
                  let separator = trimmed.firstIndex(of: ":"),
                  trimmed[trimmed.index(after: trimmed.startIndex)..<separator]
                    .lowercased() == tagName else { return nil }
            return String(trimmed[trimmed.index(after: separator)..<trimmed.index(before: trimmed.endIndex)])
        }

        private static func base64Data(_ value: String) -> Data? {
            var text = value.filter { !$0.isWhitespace }
            guard !text.isEmpty else { return nil }
            if text.count % 4 != 0 {
                text += String(repeating: "=", count: 4 - text.count % 4)
            }
            return Data(base64Encoded: text)
        }

        /// A row is an array of strings; a nested array is read as the
        /// pieces of one string.
        private static func strings(_ row: Any) -> [String] {
            guard let items = row as? [Any] else {
                return (row as? String).map { [$0] } ?? []
            }
            return items.map { item in
                if let text = item as? String { return text }
                if let pieces = item as? [Any] { return pieces.compactMap { $0 as? String }.joined() }
                return ""
            }
        }
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
