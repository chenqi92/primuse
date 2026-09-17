import Foundation

/// Subtitle containers Primuse reads as lyrics. Transcription tools and
/// streaming captions ship exactly what Primuse already models — a cue window
/// plus optional word timing — so a `.vtt` or `.srt` next to a song becomes
/// `LyricLine` instead of gaining its own playback path.
public enum SubtitleLyricsFormat: String, Sendable {
    /// WebVTT: a `WEBVTT` header, `-->` cue timings with `.` fractions, and
    /// inline `<mm:ss.ttt>` markers plus `<v>` / `<c>` / ruby annotations.
    case webVTT
    /// SubRip: numbered cues with `,` fractions and no inline word markers.
    case subRip
}

/// Parses subtitle documents into lyric lines. Detection is content based so a
/// document reaches the same result through a sidecar file, an embedded tag or
/// a server response. The inline `<mm:ss.ttt>` markers are shaped exactly like
/// ELRC word markers, so recognition keys on the `WEBVTT` header and the `-->`
/// cue timing line and never claims an LRC/ELRC/TTML/`.lys`/`.yrc`/`.qrc`
/// document.
public enum SubtitleLyricsParser {
    /// Rolling captions repeat the line that is scrolling off screen inside a
    /// cue this short. Such a cue never carries a lyric of its own.
    private static let fillerCueDuration: TimeInterval = 0.05

    /// Mirrors the ELRC fallback in `LyricsContentParser`: a word whose end is
    /// unknown gets a short sweep instead of hanging until the next line.
    private static let inferredTailDuration: TimeInterval = 0.4

    /// Tokens transcription tools emit in place of a lyric. Anything else
    /// between brackets stays — `(Yeah)` is a real backing line.
    private static let noiseTokens: Set<String> = [
        "[music]", "(music)", "[音乐]", "[音樂]",
        "[applause]", "[掌声]", "[laughter]",
    ]

    private static let musicNotes: Set<Character> = ["♪", "♫", "♬", "♩"]

    nonisolated(unsafe) private static let timestampPattern =
        /[ \t]*(?:(\d+):)?(\d{1,2}):(\d{2})[.,](\d{1,3})[ \t]*/

    /// An inline word marker. It is kept as an offset into the cleaned text
    /// because tag removal, entity decoding and whitespace collapsing all move
    /// the word it opens.
    private struct InlineMark {
        let offset: Int
        let start: TimeInterval
    }

    private struct PayloadLine {
        let characters: [Character]
        let marks: [InlineMark]

        var text: String { String(characters) }
    }

    private struct Cue {
        let start: TimeInterval
        /// `nil` when the document gave no usable window for this cue.
        let end: TimeInterval?
        let payload: [PayloadLine]
        let voice: String?

        var duration: TimeInterval { max(0, (end ?? start) - start) }
        var isWordTimed: Bool { payload.contains { !$0.marks.isEmpty } }
    }

    public static func detect(_ content: String) -> SubtitleLyricsFormat? {
        let document = normalizedDocument(content)
        let lines = document.split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first, isWebVTTHeader(first) { return .webVTT }

        var inspected = 0
        for line in lines where !line.allSatisfy(\.isWhitespace) {
            if cueTiming(in: line) != nil { return .subRip }
            inspected += 1
            if inspected >= 60 { break }
        }
        return nil
    }

    public static func parse(
        _ content: String,
        options: LyricsParsingOptions = .automatic
    ) -> [LyricLine] {
        let document = normalizedDocument(content)
        guard detect(document) != nil else { return [] }

        var cues: [Cue] = []
        for (index, block) in blocks(in: document).enumerated() {
            guard !isSkippedBlock(block, isFirstBlock: index == 0),
                  let cue = parseCue(block) else { continue }
            cues.append(cue)
        }
        guard !cues.isEmpty else { return [] }

        // Only YouTube-style rolling captions repeat their previous line; a
        // real lyric document with a repeated chorus must keep both rows. The
        // giveaway is the pairing of word-timed cues with sub-frame fillers.
        let isRollingCaptions = cues.contains(where: \.isWordTimed)
            && cues.contains { $0.duration < fillerCueDuration }

        var lines: [LyricLine] = []
        var cueIndexByLineID: [String: Int] = [:]
        var voiceNames: [String] = []

        for (index, cue) in cues.enumerated() {
            if isRollingCaptions, cue.duration < fillerCueDuration { continue }
            let payload = isRollingCaptions
                ? cue.payload.filter { !$0.marks.isEmpty || $0.text != lines.last?.text }
                : cue.payload
            guard !payload.isEmpty else { continue }

            let voice = resolvedVoice(cue.voice, in: &voiceNames)
            let joined = payload.map(\.text).joined(separator: " ")
            if payload.contains(where: { !$0.marks.isEmpty }) {
                lines.append(
                    wordLevelLine(payload: payload, cue: cue, voice: voice)
                        ?? LyricLine(
                            timestamp: cue.start,
                            text: joined,
                            isSynchronized: true,
                            endTimestamp: cue.end,
                            voice: voice
                        )
                )
                continue
            }
            guard options.detectBilingualLRC else {
                lines.append(LyricLine(
                    timestamp: cue.start,
                    text: joined,
                    isSynchronized: true,
                    endTimestamp: cue.end,
                    voice: voice
                ))
                continue
            }
            // A second payload line is either a translation or a soft wrap.
            // The shared document-level policy decides; whatever it leaves
            // behind is folded back into one line below.
            for line in payload {
                let row = LyricLine(
                    timestamp: cue.start,
                    text: line.text,
                    isSynchronized: true,
                    endTimestamp: cue.end,
                    voice: voice
                )
                cueIndexByLineID[row.id] = index
                lines.append(row)
            }
        }

        if options.detectBilingualLRC {
            lines = LyricBilingualPairingPolicy.pair(lines)
            lines = mergingWrappedCueRows(lines, cueIndexByLineID: cueIndexByLineID)
        }
        return lines.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp == rhs.element.timestamp {
                return lhs.offset < rhs.offset
            }
            return lhs.element.timestamp < rhs.element.timestamp
        }.map(\.element)
    }

    // MARK: - Document structure

    private static func normalizedDocument(_ content: String) -> String {
        var normalized = content
        if normalized.unicodeScalars.first?.value == 0xFEFF {
            normalized.removeFirst()
        }
        return normalized
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func isWebVTTHeader(_ line: Substring) -> Bool {
        guard line.hasPrefix("WEBVTT") else { return false }
        guard let next = line.dropFirst("WEBVTT".count).first else { return true }
        return next == " " || next == "\t"
    }

    private static func blocks(in document: String) -> [[Substring]] {
        var result: [[Substring]] = []
        var current: [Substring] = []
        for line in document.split(separator: "\n", omittingEmptySubsequences: false) {
            // Rolling captions put a lone space on its own line inside almost
            // every cue, so only a truly empty line may end a block.
            guard line.isEmpty else {
                current.append(line)
                continue
            }
            if !current.isEmpty { result.append(current) }
            current = []
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Header, comment and styling blocks describe the document rather than
    /// what is sung.
    private static func isSkippedBlock(_ block: [Substring], isFirstBlock: Bool) -> Bool {
        guard let first = block.first else { return true }
        if isFirstBlock, isWebVTTHeader(first) {
            // A conforming document leaves a blank line after the header. When
            // one is missing, the header lines read as a cue identifier rather
            // than swallowing the first cue.
            return !block.contains { cueTiming(in: $0) != nil }
        }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        if trimmed == "STYLE" || trimmed == "REGION" { return true }
        guard trimmed.hasPrefix("NOTE") else { return false }
        guard let next = trimmed.dropFirst("NOTE".count).first else { return true }
        return next == " " || next == "\t"
    }

    private static func parseCue(_ block: [Substring]) -> Cue? {
        // Everything before the timing line is a cue identifier, including the
        // numeric counter SubRip puts there.
        guard let timingIndex = block.firstIndex(where: { cueTiming(in: $0) != nil }),
              let timing = cueTiming(in: block[timingIndex]) else { return nil }

        var voice: String?
        var payload: [PayloadLine] = []
        for raw in block[block.index(after: timingIndex)...] {
            let cleaned = clean(raw, voice: &voice)
            guard !isDiscardable(cleaned) else { continue }
            payload.append(cleaned)
        }
        guard !payload.isEmpty else { return nil }
        return Cue(
            start: timing.start,
            // An end at or before the start describes no window at all.
            end: timing.end > timing.start ? timing.end : nil,
            payload: payload,
            voice: voice
        )
    }

    private static func cueTiming(in line: Substring) -> (start: TimeInterval, end: TimeInterval)? {
        guard let arrow = line.range(of: "-->"),
              let start = timestamp(from: line[..<arrow.lowerBound]) else { return nil }
        // Cue settings follow the end time. They are presentation, not lyrics,
        // but they must be separated from it by whitespace.
        let trailing = line[arrow.upperBound...].drop { $0 == " " || $0 == "\t" }
        guard let end = timestamp(from: trailing.prefix { $0 != " " && $0 != "\t" }) else {
            return nil
        }
        return (start, end)
    }

    private static func timestamp(from field: Substring) -> TimeInterval? {
        guard let match = field.wholeMatch(of: timestampPattern),
              let minutes = Int(match.2),
              let seconds = Int(match.3),
              let fraction = Int(match.4) else { return nil }
        let hours = match.1.flatMap { Int($0) } ?? 0
        guard hours <= 100_000 else { return nil }
        // A 1- or 2-digit fraction is tenths or hundredths of a second. Whole
        // milliseconds are summed before the conversion so a cue boundary lands
        // on an exact millisecond instead of a binary fraction of one.
        let scale: Int
        switch match.4.count {
        case 1: scale = 100
        case 2: scale = 10
        default: scale = 1
        }
        let total = ((hours * 60 + minutes) * 60 + seconds) * 1_000 + fraction * scale
        return TimeInterval(total) / 1_000
    }

    // MARK: - Payload cleaning

    /// Strips cue markup one character at a time. A chain of replacements
    /// cannot do this: `<rt>` has to drop its content, every other tag has to
    /// keep it, and the inline timestamps must keep pointing at the word they
    /// open after the surrounding text has been rewritten.
    private static func clean(_ raw: Substring, voice: inout String?) -> PayloadLine {
        var characters: [Character] = []
        var marks: [InlineMark] = []

        func append(_ text: String) {
            for character in text {
                guard character.isWhitespace else {
                    characters.append(character)
                    continue
                }
                // Collapse runs; a leading run simply never starts.
                if let last = characters.last, last != " " { characters.append(" ") }
            }
        }

        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            switch character {
            case "<":
                guard let close = raw[index...].firstIndex(of: ">") else {
                    // An unmatched `<` is literal text, not a broken tag.
                    append(String(character))
                    index = raw.index(after: index)
                    continue
                }
                let body = raw[raw.index(after: index)..<close]
                index = raw.index(after: close)
                if let start = timestamp(from: body) {
                    marks.append(InlineMark(offset: characters.count, start: start))
                } else if let name = voiceName(in: body) {
                    if voice == nil { voice = name }
                } else if isRubyAnnotationTag(body) {
                    // A ruby annotation spells the line out; it is not sung.
                    index = skippingRubyAnnotation(in: raw, from: index)
                }
            case "{":
                let bodyStart = raw.index(after: index)
                // `{\an8}` and friends are ASS positioning overrides. A brace
                // that opens anything else is ordinary lyric punctuation.
                guard bodyStart < raw.endIndex, raw[bodyStart] == "\\",
                      let close = raw[bodyStart...].firstIndex(of: "}") else {
                    append(String(character))
                    index = bodyStart
                    continue
                }
                index = raw.index(after: close)
            case "&":
                let entity = decodedEntity(in: raw, from: index)
                append(entity.text)
                index = entity.end
            default:
                append(String(character))
                index = raw.index(after: index)
            }
        }

        while characters.last == " " { characters.removeLast() }
        var leading = characters.startIndex
        while leading < characters.endIndex, isTrimmableEdge(characters[leading]) {
            leading += 1
        }
        var trailing = characters.endIndex
        while trailing > leading, isTrimmableEdge(characters[trailing - 1]) {
            trailing -= 1
        }
        let trimmed = Array(characters[leading..<trailing])
        return PayloadLine(
            characters: trimmed,
            marks: marks.map {
                InlineMark(
                    offset: min(max(0, $0.offset - leading), trimmed.count),
                    start: $0.start
                )
            }
        )
    }

    /// Decorative note symbols and the whitespace around them frame a line
    /// without belonging to it.
    private static func isTrimmableEdge(_ character: Character) -> Bool {
        character == " " || musicNotes.contains(character)
    }

    private static func isDiscardable(_ line: PayloadLine) -> Bool {
        let text = line.text
        return text.isEmpty || noiseTokens.contains(text.lowercased())
    }

    /// `<v Name>` / `<v.loud Name>` names the singer of the cue.
    private static func voiceName(in body: Substring) -> String? {
        guard body.first == "v" || body.first == "V" else { return nil }
        let rest = body.dropFirst()
        guard let separator = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return nil
        }
        let classes = rest[..<separator]
        guard classes.isEmpty || classes.first == "." else { return nil }
        let name = rest[separator...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func isRubyAnnotationTag(_ body: Substring) -> Bool {
        body.prefix { !$0.isWhitespace }.lowercased() == "rt"
    }

    private static func skippingRubyAnnotation(
        in raw: Substring,
        from index: Substring.Index
    ) -> Substring.Index {
        raw.range(of: "</rt>", options: .caseInsensitive, range: index..<raw.endIndex)?
            .upperBound ?? raw.endIndex
    }

    private static func decodedEntity(
        in raw: Substring,
        from index: Substring.Index
    ) -> (text: String, end: Substring.Index) {
        let bodyStart = raw.index(after: index)
        let literal = (String(raw[index]), bodyStart)
        guard let close = raw[bodyStart...].prefix(12).firstIndex(of: ";") else { return literal }
        let name = raw[bodyStart..<close]
        let end = raw.index(after: close)

        switch name.lowercased() {
        case "amp": return ("&", end)
        case "lt": return ("<", end)
        case "gt": return (">", end)
        case "quot": return ("\"", end)
        case "apos": return ("'", end)
        case "nbsp": return (" ", end)
        case "lrm", "rlm":
            // Directional marks are invisible formatting. Keeping them would
            // make two identical caption lines compare as different text.
            return ("", end)
        default:
            break
        }

        guard name.hasPrefix("#") else { return literal }
        let digits = name.dropFirst()
        let value = digits.first == "x" || digits.first == "X"
            ? UInt32(digits.dropFirst(), radix: 16)
            : UInt32(digits, radix: 10)
        guard let value, let scalar = Unicode.Scalar(value) else { return literal }
        return (String(Character(scalar)), end)
    }

    // MARK: - Lines

    /// A wrapped payload is still one sung line, so the markers keep running
    /// across the physical line break.
    private static func wordLevelLine(
        payload: [PayloadLine],
        cue: Cue,
        voice: LyricVoice
    ) -> LyricLine? {
        var characters: [Character] = []
        var marks: [InlineMark] = []
        for line in payload {
            if !characters.isEmpty { characters.append(" ") }
            let offset = characters.count
            marks.append(contentsOf: line.marks.map {
                InlineMark(offset: $0.offset + offset, start: $0.start)
            })
            characters.append(contentsOf: line.characters)
        }

        // Markers that run backwards or leave the cue window describe some
        // other document; a line-level row is then the honest reading.
        guard let first = marks.first, let last = marks.last,
              first.start >= cue.start,
              last.start <= (cue.end ?? .greatestFiniteMagnitude),
              zip(marks, marks.dropFirst()).allSatisfy({ $0.start <= $1.start }) else {
            return nil
        }

        var syllables: [LyricSyllable] = []
        var segmentStart = 0
        var segmentTime = cue.start
        for mark in marks {
            let text = String(characters[segmentStart..<mark.offset])
            if !text.isEmpty {
                syllables.append(LyricSyllable(
                    text: text,
                    start: segmentTime,
                    end: mark.start,
                    endTiming: .inferred
                ))
            }
            segmentStart = mark.offset
            segmentTime = mark.start
        }

        let tail = String(characters[segmentStart...])
        if !tail.isEmpty {
            syllables.append(LyricSyllable(
                text: tail,
                start: segmentTime,
                end: cue.end ?? (segmentTime + inferredTailDuration),
                endTiming: cue.end == nil ? .inferred : .explicit
            ))
        } else if var closing = syllables.last, let end = cue.end, end > closing.start {
            closing.end = end
            closing.endTiming = .explicit
            syllables[syllables.count - 1] = closing
        }

        guard !syllables.isEmpty else { return nil }
        let text = syllables.map(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return LyricLine(
            timestamp: cue.start,
            text: text,
            isSynchronized: true,
            syllables: syllables,
            endTimestamp: cue.end,
            voice: voice
        )
    }

    /// The document's first singer reads as the lead. Only a second distinct
    /// name earns the duet alignment; further names have nowhere to go.
    private static func resolvedVoice(_ name: String?, in names: inout [String]) -> LyricVoice {
        guard let name else { return .primary }
        if let existing = names.firstIndex(of: name) {
            return existing == 1 ? .secondary : .primary
        }
        names.append(name)
        return names.count == 2 ? .secondary : .primary
    }

    /// Rows the bilingual policy did not take were a soft wrap after all, so
    /// the cue becomes one line again.
    private static func mergingWrappedCueRows(
        _ lines: [LyricLine],
        cueIndexByLineID: [String: Int]
    ) -> [LyricLine] {
        guard !cueIndexByLineID.isEmpty else { return lines }
        var result: [LyricLine] = []
        for line in lines {
            guard let cueIndex = cueIndexByLineID[line.id],
                  line.manualTranslation == nil,
                  var previous = result.last,
                  previous.manualTranslation == nil,
                  cueIndexByLineID[previous.id] == cueIndex else {
                result.append(line)
                continue
            }
            previous.text += " " + line.text
            result[result.count - 1] = previous
        }
        return result
    }
}
