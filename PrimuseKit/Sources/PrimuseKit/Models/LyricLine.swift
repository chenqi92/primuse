import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct LyricSyllable: Codable, Hashable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// The base writing direction of one lyrics document. `natural` deliberately
/// leaves mixed-language lyrics to the platform's Unicode bidi handling.
public enum LyricWritingDirection: String, Codable, Hashable, Sendable {
    case natural
    case leftToRight
    case rightToLeft

    public var isRightToLeft: Bool { self == .rightToLeft }
}

/// Resolves a presentation-only writing direction from an LRC/ELRC `[la:...]`
/// header or, when the header is absent, from strongly dominant RTL text. The
/// result never changes lyric storage order or timing data.
public enum LyricWritingDirectionPolicy {
    /// Script identifiers Foundation can actually resolve on this OS. This
    /// prevents an arbitrary four-letter subtag from being mistaken for a
    /// left-to-right script while still allowing the platform to expand its
    /// supported script set without a library update.
    private static let availableScripts: Set<String> = Set(
        Locale.availableIdentifiers.compactMap {
            Locale.Language(identifier: $0).script?.identifier.lowercased()
        }
    )

    /// Language subtags known to the installed Foundation locale database.
    /// Without this guard Foundation may assign a default Latin script to an
    /// arbitrary but syntactically valid primary subtag.
    private static let availableLanguages: Set<String> = Set(
        Locale.availableIdentifiers.compactMap {
            Locale.Language(identifier: $0).languageCode?.identifier.lowercased()
        }
    )

    /// Scripts whose horizontal character order is right-to-left. Script
    /// subtags take precedence over a language's usual script, so tags such as
    /// `az-Arab` and `fa-Latn` are handled correctly.
    private static let rightToLeftScripts: Set<String> = [
        "adlm", "arab", "aran", "hebr", "mand", "mani", "mend", "merc",
        "mero", "nkoo", "orkh", "phli", "phlp", "phnx", "rohg", "samr",
        "sarb", "sogd", "sogo", "syrc", "thaa", "yezi"
    ]

    /// Legacy/common language identifiers that Foundation can recognize even
    /// when it cannot infer a script on a particular OS release.
    private static let rightToLeftLanguages: Set<String> = [
        "ar", "arc", "ckb", "dv", "fa", "he", "iw", "ji", "ks", "ku",
        "nqo", "ps", "sd", "syr", "ug", "ur", "yi"
    ]

    /// Modern RTL script blocks used by song lyrics. Alphabetic filtering
    /// keeps punctuation and Arabic/Hebrew number forms neutral, matching the
    /// Unicode bidi model's strong-character distinction.
    private static let rightToLeftLetterRanges: [ClosedRange<UInt32>] = [
        0x0590...0x05FF, // Hebrew
        0x0600...0x06FF, // Arabic
        0x0700...0x074F, // Syriac
        0x0750...0x077F, // Arabic Supplement
        0x0780...0x07BF, // Thaana
        0x07C0...0x07FF, // NKo
        0x0800...0x083F, // Samaritan
        0x0840...0x085F, // Mandaic
        0x0860...0x086F, // Syriac Supplement
        0x0870...0x089F, // Arabic Extended-B
        0x08A0...0x08FF, // Arabic Extended-A
        0xFB1D...0xFB4F, // Hebrew Presentation Forms
        0xFB50...0xFDFF, // Arabic Presentation Forms-A
        0xFE70...0xFEFF, // Arabic Presentation Forms-B
        0x10D00...0x10D8F, // Hanifi Rohingya and Garay
        0x10E80...0x10EFF, // Yezidi and Arabic Extended-C
        0x1E800...0x1E95F, // Mende Kikakui and Adlam
        0x1EE00...0x1EEFF, // Arabic Mathematical Alphabetic Symbols
    ]

    private static let maximumInferredLetterCount = 512
    private static let minimumRightToLeftLetterCount = 2

    public static func resolve(in lines: [LyricLine]) -> LyricWritingDirection {
        for line in lines {
            guard let metadataLines = line.metadataLines,
                  let direction = resolveMetadata(metadataLines) else { continue }
            return direction
        }
        return inferDirection(in: lines)
    }

    public static func resolve(metadataLines: [String]) -> LyricWritingDirection {
        resolveMetadata(metadataLines) ?? .natural
    }

    public static func resolve(languageTag: String?) -> LyricWritingDirection {
        guard let normalized = normalizedLanguageTag(languageTag) else { return .natural }

        let subtags = normalized.split(separator: "-").map(String.init)
        let primaryLanguage = subtags[0]
        if let explicitScript = subtags.dropFirst().first(where: {
            $0.count == 4 && $0.unicodeScalars.allSatisfy(CharacterSet.letters.contains)
        })?.lowercased() {
            if rightToLeftScripts.contains(explicitScript) { return .rightToLeft }
            guard availableScripts.contains(explicitScript) else { return .natural }
            return direction(
                from: Locale.Language(identifier: "und-\(explicitScript)").characterDirection
            )
        }

        guard availableLanguages.contains(primaryLanguage)
                || rightToLeftLanguages.contains(primaryLanguage) else {
            return .natural
        }
        let language = Locale.Language(identifier: normalized)
        if language.script != nil {
            let resolved = direction(from: language.characterDirection)
            if resolved != .natural { return resolved }
        }
        return rightToLeftLanguages.contains(primaryLanguage) ? .rightToLeft : .natural
    }

    private static func resolveMetadata(
        _ metadataLines: [String]
    ) -> LyricWritingDirection? {
        for metadataLine in metadataLines {
            let trimmed = metadataLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { continue }

            let body = trimmed.dropFirst().dropLast()
            guard let separator = body.firstIndex(of: ":") else { continue }
            let key = body[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.caseInsensitiveCompare("la") == .orderedSame else { continue }

            let value = body[body.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let direction = resolve(languageTag: value)
            if direction != .natural { return direction }
        }
        return nil
    }

    private static func inferDirection(in lines: [LyricLine]) -> LyricWritingDirection {
        var rightToLeftCount = 0
        var otherLetterCount = 0

        for line in lines {
            countDirectionalLetters(
                in: line,
                rightToLeftCount: &rightToLeftCount,
                otherLetterCount: &otherLetterCount
            )
            if rightToLeftCount + otherLetterCount >= maximumInferredLetterCount {
                break
            }
        }

        let totalCount = rightToLeftCount + otherLetterCount
        guard rightToLeftCount >= minimumRightToLeftLetterCount,
              rightToLeftCount * 5 >= totalCount * 3 else {
            return .natural
        }
        return .rightToLeft
    }

    private static func countDirectionalLetters(
        in line: LyricLine,
        rightToLeftCount: inout Int,
        otherLetterCount: inout Int
    ) {
        countDirectionalLetters(
            in: line.text,
            rightToLeftCount: &rightToLeftCount,
            otherLetterCount: &otherLetterCount
        )
        guard rightToLeftCount + otherLetterCount < maximumInferredLetterCount else {
            return
        }
        for backgroundLine in line.background ?? [] {
            countDirectionalLetters(
                in: backgroundLine,
                rightToLeftCount: &rightToLeftCount,
                otherLetterCount: &otherLetterCount
            )
            if rightToLeftCount + otherLetterCount >= maximumInferredLetterCount {
                return
            }
        }
    }

    private static func countDirectionalLetters(
        in text: String,
        rightToLeftCount: inout Int,
        otherLetterCount: inout Int
    ) {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if rightToLeftLetterRanges.contains(where: { $0.contains(scalar.value) }) {
                rightToLeftCount += 1
            } else {
                otherLetterCount += 1
            }
            if rightToLeftCount + otherLetterCount >= maximumInferredLetterCount {
                return
            }
        }
    }

    private static func normalizedLanguageTag(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !normalized.isEmpty else { return nil }

        let subtags = normalized.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = subtags.first,
              (2...8).contains(primary.count),
              primary.unicodeScalars.allSatisfy(CharacterSet.letters.contains),
              subtags.dropFirst().allSatisfy({ subtag in
                  (1...8).contains(subtag.count)
                      && subtag.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
              }) else { return nil }
        return normalized
    }

    private static func direction(
        from languageDirection: Locale.LanguageDirection
    ) -> LyricWritingDirection {
        switch languageDirection {
        case .rightToLeft:
            return .rightToLeft
        case .leftToRight:
            return .leftToRight
        case .unknown, .topToBottom, .bottomToTop:
            return .natural
        @unknown default:
            return .natural
        }
    }
}

public struct LyricFlowItemSize: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct LyricFlowItemPlacement: Equatable, Sendable {
    public let itemIndex: Int
    public let x: Double
    public let y: Double

    public init(itemIndex: Int, x: Double, y: Double) {
        self.itemIndex = itemIndex
        self.x = x
        self.y = y
    }
}

public enum LyricFlowHorizontalAlignment: Sendable {
    case leading
    case center
    case trailing
}

/// Computes physical glyph positions without changing the logical syllable
/// sequence. Leading/trailing alignment mirrors for RTL, while timestamps keep
/// addressing the same original item indexes.
public enum LyricFlowPlacementPolicy {
    public static func placements(
        itemSizes: [LyricFlowItemSize],
        containerWidth: Double,
        spacing: Double = 0,
        isRightToLeft: Bool,
        alignment: LyricFlowHorizontalAlignment = .leading
    ) -> [LyricFlowItemPlacement] {
        guard !itemSizes.isEmpty else { return [] }

        let availableWidth = max(0, containerWidth)
        let itemSpacing = max(0, spacing)
        var rows: [[Int]] = []
        var currentRow: [Int] = []
        var currentRowWidth = 0.0

        for (index, itemSize) in itemSizes.enumerated() {
            let width = max(0, itemSize.width)
            let proposedWidth = currentRowWidth
                + (currentRow.isEmpty ? 0 : itemSpacing)
                + width
            if proposedWidth > availableWidth, !currentRow.isEmpty {
                rows.append(currentRow)
                currentRow = []
                currentRowWidth = 0
            }

            currentRowWidth += (currentRow.isEmpty ? 0 : itemSpacing) + width
            currentRow.append(index)
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }

        var y = 0.0
        var result: [LyricFlowItemPlacement] = []
        result.reserveCapacity(itemSizes.count)

        for row in rows {
            let rowWidth = row.enumerated().reduce(0.0) { partial, pair in
                let itemWidth = max(0, itemSizes[pair.element].width)
                return partial + (pair.offset == 0 ? 0 : itemSpacing) + itemWidth
            }
            let remainingWidth = max(0, availableWidth - rowWidth)
            let originX: Double
            switch alignment {
            case .leading:
                originX = isRightToLeft ? remainingWidth : 0
            case .center:
                originX = remainingWidth / 2
            case .trailing:
                originX = isRightToLeft ? 0 : remainingWidth
            }

            var advance = 0.0
            var rowHeight = 0.0
            for index in row {
                let width = max(0, itemSizes[index].width)
                let height = max(0, itemSizes[index].height)
                let x = isRightToLeft
                    ? originX + rowWidth - advance - width
                    : originX + advance
                result.append(LyricFlowItemPlacement(itemIndex: index, x: x, y: y))
                advance += width + itemSpacing
                rowHeight = max(rowHeight, height)
            }
            y += rowHeight
        }
        return result
    }
}

/// 行所属声部。LRC/A2 没有该信息，预留给 TTML（Apple Music 对唱）等格式。
public enum LyricVoice: String, Codable, Sendable, CaseIterable {
    case primary    // 主声部 / 默认演唱者，左对齐
    case secondary  // 对唱声部，建议右对齐
}

public struct LyricLine: Identifiable, Hashable, Sendable {
    public var id: String
    public var timestamp: TimeInterval
    public var text: String
    /// Whether tapping and playback time may drive this line. Plain-text
    /// lyrics intentionally keep every line unsynchronized even though their
    /// compatibility timestamp is zero.
    public var isSynchronized: Bool
    /// 字级数据；nil 表示行级歌词。
    public var syllables: [LyricSyllable]?
    /// 声部归属，默认主声部。
    public var voice: LyricVoice
    /// 背景和声子行（同一时间窗内附唱）。`background` 内的 background 应永远为 nil。
    public var background: [LyricLine]?
    /// Leading LRC/ELRC document metadata such as `[ti:]`, `[ar:]` and
    /// `[by:]`. Only the first parsed lyric line carries this value so the
    /// existing line-oriented cache and CloudKit snapshot remain compatible
    /// while editable documents can still round-trip their headers.
    public var metadataLines: [String]?

    public init(
        id: String = UUID().uuidString,
        timestamp: TimeInterval,
        text: String,
        isSynchronized: Bool? = nil,
        syllables: [LyricSyllable]? = nil,
        voice: LyricVoice = .primary,
        background: [LyricLine]? = nil,
        metadataLines: [String]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.isSynchronized = isSynchronized ?? (timestamp > 0 || syllables?.isEmpty == false)
        self.syllables = syllables
        self.voice = voice
        self.background = background
        self.metadataLines = metadataLines
    }

    /// 行结束时间。字级行用最后一字的 end；行级行无信息，外部需要靠下一行 timestamp 推。
    public var endTime: TimeInterval? { syllables?.last?.end }

    public var isWordLevel: Bool { syllables?.isEmpty == false }
}

// MARK: - Codable (custom — 旧 JSON 缺 voice/background 也能解码)

extension LyricLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, text, isSynchronized, syllables, voice, background, metadataLines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        self.text = try c.decode(String.self, forKey: .text)
        self.syllables = try c.decodeIfPresent([LyricSyllable].self, forKey: .syllables)
        self.isSynchronized = try c.decodeIfPresent(Bool.self, forKey: .isSynchronized)
            ?? (timestamp > 0 || syllables?.isEmpty == false)
        self.voice = try c.decodeIfPresent(LyricVoice.self, forKey: .voice) ?? .primary
        self.background = try c.decodeIfPresent([LyricLine].self, forKey: .background)
        self.metadataLines = try c.decodeIfPresent([String].self, forKey: .metadataLines)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(syllables, forKey: .syllables)
        let inferredSynchronization = timestamp > 0 || syllables?.isEmpty == false
        if isSynchronized != inferredSynchronization {
            try c.encode(isSynchronized, forKey: .isSynchronized)
        }
        // voice / background 仅在非默认值时写入，避免老歌词缓存膨胀
        if voice != .primary { try c.encode(voice, forKey: .voice) }
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(metadataLines, forKey: .metadataLines)
    }
}

public enum LyricsFormat: String, Codable, Sendable, CaseIterable {
    case plain      // 无时间戳的纯文本
    case lineLevel  // 行级 LRC：[mm:ss.xx]text
    case wordLevel  // 字级：A2/KRC 扩展 LRC，或带时间 span 的 TTML

    /// 通过扫描内容探测歌词格式。仅看是否存在字级 / 行级时间标记。
    public static func detect(_ content: String?) -> LyricsFormat {
        guard let content, !content.isEmpty else { return .plain }
        if TTMLLyricsParser.looksLikeTTML(content) {
            let lines = TTMLLyricsParser.parse(content)
            if lines.contains(where: \.isWordLevel) { return .wordLevel }
            if lines.contains(where: \.isSynchronized) { return .lineLevel }
            return .plain
        }
        if content.range(of: #"<\d+:\d+(?:[.:]\d+)?>"#, options: .regularExpression) != nil {
            return .wordLevel
        }
        if content.range(of: #"<\d+,\d+(,\d+)?>"#, options: .regularExpression) != nil {
            return .wordLevel
        }
        if content.range(of: #"\[\d+:\d+(?:[.:]\d+)?\]"#, options: .regularExpression) != nil {
            return .lineLevel
        }
        return .plain
    }

    public var isSynced: Bool { self != .plain }
}

public enum LyricsValidationIssueKind: String, Codable, Sendable, Hashable {
    case invalidTimestamp
    case invalidWordTimestamp
    case emptyTimedLine
    case nonMonotonicTimestamp
}

public struct LyricsValidationIssue: Codable, Sendable, Hashable {
    public let lineNumber: Int
    public let kind: LyricsValidationIssueKind

    public init(lineNumber: Int, kind: LyricsValidationIssueKind) {
        self.lineNumber = lineNumber
        self.kind = kind
    }
}

public struct LyricsEditableValidation: Sendable, Hashable {
    public let normalizedContent: String
    public let format: LyricsFormat
    public let lines: [LyricLine]
    public let issues: [LyricsValidationIssue]

    public var isValid: Bool {
        !normalizedContent.isEmpty && !lines.isEmpty && issues.isEmpty
    }

    public init(
        normalizedContent: String,
        format: LyricsFormat,
        lines: [LyricLine],
        issues: [LyricsValidationIssue]
    ) {
        self.normalizedContent = normalizedContent
        self.format = format
        self.lines = lines
        self.issues = issues
    }
}

/// File containers exposed by the macOS lyrics conversion tool. `lrc`
/// preserves word timing as enhanced LRC when the source carries syllables;
/// `plainText` intentionally removes every timing marker.
public enum LyricsFileFormat: String, Codable, Sendable, CaseIterable {
    case lrc
    case ttml
    case plainText
}

public enum LyricsFileConversionError: Error, Equatable, Sendable {
    case emptyInput
    case invalidContent
}

public struct LyricsFileConversionResult: Equatable, Sendable {
    public let sourceFormat: LyricsFormat
    public let targetFormat: LyricsFileFormat
    public let lines: [LyricLine]
    public let output: String

    public init(
        sourceFormat: LyricsFormat,
        targetFormat: LyricsFileFormat,
        lines: [LyricLine],
        output: String
    ) {
        self.sourceFormat = sourceFormat
        self.targetFormat = targetFormat
        self.lines = lines
        self.output = output
    }
}

/// Converts between the lyric formats that the shared parser can represent.
/// Structured targets preserve line and syllable timing. Formats without a
/// voice concept keep secondary/background text but cannot keep its visual
/// alignment; the macOS tool explains that limitation.
public enum LyricsFileConverter {
    public static func convert(
        _ content: String,
        to targetFormat: LyricsFileFormat
    ) throws -> LyricsFileConversionResult {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw LyricsFileConversionError.emptyInput }

        let validation = LyricsContentParser.validateEditableText(normalized)
        guard validation.isValid else { throw LyricsFileConversionError.invalidContent }

        let expandedLines = flattenBackgroundLines(validation.lines)
        let output: String
        switch targetFormat {
        case .lrc:
            output = LyricsContentParser.serialize(expandedLines)
        case .ttml:
            output = LyricsContentParser.serializeTTML(expandedLines)
        case .plainText:
            output = expandedLines.map(\.text).joined(separator: "\n")
        }

        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LyricsFileConversionError.invalidContent
        }
        return LyricsFileConversionResult(
            sourceFormat: validation.format,
            targetFormat: targetFormat,
            lines: validation.lines,
            output: output
        )
    }

    private static func flattenBackgroundLines(_ lines: [LyricLine]) -> [LyricLine] {
        var expanded: [(order: Int, line: LyricLine)] = []
        expanded.reserveCapacity(lines.count)

        for line in lines {
            var primary = line
            primary.background = nil
            expanded.append((expanded.count, primary))

            for background in line.background ?? [] {
                var flattened = background
                flattened.background = nil
                expanded.append((expanded.count, flattened))
            }
        }

        return expanded.sorted {
            if $0.line.timestamp == $1.line.timestamp { return $0.order < $1.order }
            return $0.line.timestamp < $1.line.timestamp
        }.map(\.line)
    }
}

public enum LyricsContentParser {
    nonisolated(unsafe) private static let lineHeadPattern = /\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]/
    nonisolated(unsafe) private static let relativeLineHeadPattern = /^\[(\d+),(\d+)\]/
    nonisolated(unsafe) private static let inlineWordPattern = /<(\d+):(\d{2})(?:[.:](\d{1,3}))?>/
    nonisolated(unsafe) private static let relativeWordPattern = /<(\d+),(\d+)(?:,\d+)?>/
    nonisolated(unsafe) private static let metadataPattern = /^\[[A-Za-z][A-Za-z0-9_-]*:.*\]\s*$/

    public static func parse(_ content: String) -> [LyricLine] {
        if TTMLLyricsParser.looksLikeTTML(content) {
            return TTMLLyricsParser.parse(content)
        }

        var lines: [LyricLine] = []
        var metadataLines: [String] = []
        var isLeadingMetadataRegion = true

        for raw in content.components(separatedBy: .newlines) {
            if isLeadingMetadataRegion, raw.firstMatch(of: metadataPattern) != nil {
                metadataLines.append(raw)
                continue
            }
            if isLeadingMetadataRegion, raw.trimmingCharacters(in: .whitespaces).isEmpty,
               !metadataLines.isEmpty {
                metadataLines.append(raw)
                continue
            }

            let heads = raw.matches(of: lineHeadPattern)
            if heads.isEmpty {
                guard let head = raw.firstMatch(of: relativeLineHeadPattern) else { continue }
                isLeadingMetadataRegion = false
                let lineStart = (Double(head.1) ?? 0) / 1000
                let body = String(raw[head.range.upperBound...])
                if let parsed = parseWordLevelLine(
                    body: body,
                    lineStart: lineStart,
                    lineFractionDigits: nil
                ) {
                    lines.append(parsed)
                } else {
                    let text = body.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    lines.append(LyricLine(timestamp: lineStart, text: text, isSynchronized: true))
                }
                continue
            }

            isLeadingMetadataRegion = false
            guard let lastHead = heads.last else { continue }
            let body = String(raw[lastHead.range.upperBound...])
            for head in heads {
                guard let lineStart = parseTimestamp(min: head.1, sec: head.2, frac: head.3) else {
                    continue
                }
                if let parsed = parseWordLevelLine(
                    body: body,
                    lineStart: lineStart,
                    lineFractionDigits: head.3?.count
                ) {
                    lines.append(parsed)
                } else {
                    let text = body.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    lines.append(LyricLine(timestamp: lineStart, text: text, isSynchronized: true))
                }
            }
        }

        lines.sort { $0.timestamp < $1.timestamp }
        if !metadataLines.isEmpty, !lines.isEmpty {
            lines[0].metadataLines = metadataLines
        }
        return lines
    }

    public static func isTTML(_ content: String) -> Bool {
        TTMLLyricsParser.looksLikeTTML(content)
    }

    public static func parseText(_ text: String) -> [LyricLine] {
        if TTMLLyricsParser.looksLikeTTML(text) {
            // Malformed XML must not fall through and surface its tags as
            // unsynchronized lyric lines.
            return TTMLLyricsParser.parse(text)
        }
        let synchronized = parse(text)
        if !synchronized.isEmpty { return synchronized }

        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { LyricLine(timestamp: 0, text: $0.element, isSynchronized: false) }
    }

    /// Convert editable lyric models back to a text representation without
    /// flattening synchronization data. Plain lyrics remain plain, line-level
    /// lyrics use LRC timestamps, and syllable lyrics use ELRC word markers.
    public static func serialize(_ lines: [LyricLine]) -> String {
        let body = lines.map { line in
            guard line.isSynchronized else { return line.text }

            let lineHead = "[\(formatTimestamp(line.timestamp))]"
            guard let syllables = line.syllables, !syllables.isEmpty else {
                return lineHead + line.text
            }

            var body = syllables.map {
                "<\(formatTimestamp($0.start))>\($0.text)"
            }.joined()
            if let end = syllables.last?.end, end > syllables.last!.start {
                body += "<\(formatTimestamp(end))>"
            }
            return lineHead + body
        }.joined(separator: "\n")
        guard let metadata = lines.first?.metadataLines, !metadata.isEmpty else {
            return body
        }
        return (metadata + [body]).joined(separator: "\n")
    }

    /// Serializes the shared lyric model back to the Apple Music-compatible
    /// TTML subset. The editor works in LRC/ELRC, then uses this path only when
    /// the authoritative sidecar is a `.ttml` document.
    public static func serializeTTML(_ lines: [LyricLine]) -> String {
        TTMLLyricsParser.serialize(lines)
    }

    /// Validates the raw structured-text editor without rewriting it. Valid
    /// metadata and blank lines are kept in `normalizedContent`; malformed
    /// time markers are reported with their original 1-based line numbers.
    public static func validateEditableText(_ text: String) -> LyricsEditableValidation {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let format = LyricsFormat.detect(normalized)
        let parsedLines = parseText(normalized)
        guard !normalized.isEmpty else {
            return LyricsEditableValidation(
                normalizedContent: normalized,
                format: format,
                lines: [],
                issues: []
            )
        }

        if TTMLLyricsParser.looksLikeTTML(normalized) {
            let lines = TTMLLyricsParser.parse(normalized)
            return LyricsEditableValidation(
                normalizedContent: normalized,
                format: lines.contains(where: \.isWordLevel)
                    ? .wordLevel
                    : (lines.contains(where: \.isSynchronized) ? .lineLevel : .plain),
                lines: lines,
                issues: lines.isEmpty
                    ? [.init(lineNumber: 1, kind: .invalidTimestamp)]
                    : []
            )
        }

        var issues: [LyricsValidationIssue] = []
        var previousTimestamp: TimeInterval?
        for (offset, raw) in normalized.components(separatedBy: .newlines).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, raw.firstMatch(of: metadataPattern) == nil else { continue }

            let looksTimed = trimmed.hasPrefix("[")
                && trimmed.dropFirst().first?.isNumber == true
            let containsWordDelimiters = (trimmed.contains("<") || trimmed.contains(">"))
                && (looksTimed || format == .wordLevel)
            guard looksTimed || containsWordDelimiters else { continue }

            let parsed = parse(raw)
            if parsed.isEmpty {
                let kind: LyricsValidationIssueKind = containsWordDelimiters
                    ? .invalidWordTimestamp
                    : .invalidTimestamp
                issues.append(.init(lineNumber: offset + 1, kind: kind))
                continue
            }

            if looksTimed,
               parsed.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
                issues.append(.init(lineNumber: offset + 1, kind: .emptyTimedLine))
            }
            if containsWordDelimiters,
               parsed.contains(where: { !$0.isWordLevel }) {
                issues.append(.init(lineNumber: offset + 1, kind: .invalidWordTimestamp))
            }

            for line in parsed {
                if let previousTimestamp, line.timestamp < previousTimestamp {
                    issues.append(.init(lineNumber: offset + 1, kind: .nonMonotonicTimestamp))
                    break
                }
                previousTimestamp = line.timestamp
            }
        }

        return LyricsEditableValidation(
            normalizedContent: normalized,
            format: format,
            lines: parsedLines,
            issues: Array(Set(issues)).sorted {
                if $0.lineNumber == $1.lineNumber { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.lineNumber < $1.lineNumber
            }
        )
    }

    public static func areSemanticallyEquivalent(
        _ lhs: [LyricLine],
        _ rhs: [LyricLine],
        tolerance: TimeInterval = 0.002
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            guard left.text == right.text,
                  left.isSynchronized == right.isSynchronized,
                  abs(left.timestamp - right.timestamp) <= tolerance else {
                return false
            }
            switch (left.syllables, right.syllables) {
            case (nil, nil):
                continue
            case (.some(let leftWords), .some(let rightWords)):
                guard leftWords.count == rightWords.count else { return false }
                for (leftWord, rightWord) in zip(leftWords, rightWords) {
                    guard leftWord.text == rightWord.text,
                          abs(leftWord.start - rightWord.start) <= tolerance,
                          abs(leftWord.end - rightWord.end) <= tolerance else {
                        return false
                    }
                }
            default:
                return false
            }
        }
        return true
    }

    private static func parseWordLevelLine(
        body: String,
        lineStart: TimeInterval,
        lineFractionDigits: Int?
    ) -> LyricLine? {
        let marks = body.matches(of: inlineWordPattern)
        guard !marks.isEmpty else {
            return parseRelativeWordLevelLine(body: body, lineStart: lineStart)
        }

        var syllables: [LyricSyllable] = []
        for (index, mark) in marks.enumerated() {
            let previousStart = syllables.last?.start ?? lineStart
            guard let start = parseEnhancedWordTimestamp(
                min: mark.1,
                sec: mark.2,
                frac: mark.3,
                lineFractionDigits: lineFractionDigits,
                previousStart: previousStart
            ) else {
                continue
            }
            let textStart = mark.range.upperBound
            let textEnd = index + 1 < marks.count ? marks[index + 1].range.lowerBound : body.endIndex
            let chunk = String(body[textStart..<textEnd])
            if chunk.isEmpty {
                if let last = syllables.last {
                    syllables[syllables.count - 1] = LyricSyllable(
                        text: last.text,
                        start: last.start,
                        end: max(last.end, start)
                    )
                }
                continue
            }
            syllables.append(LyricSyllable(text: chunk, start: start, end: start))
        }

        guard !syllables.isEmpty else { return nil }
        for index in 0..<(syllables.count - 1) {
            syllables[index].end = max(syllables[index].end, syllables[index + 1].start)
        }
        if let lastIndex = syllables.indices.last,
           syllables[lastIndex].end <= syllables[lastIndex].start {
            syllables[lastIndex].end = syllables[lastIndex].start + 0.4
        }

        return makeWordLevelLine(lineStart: lineStart, syllables: syllables)
    }

    /// Some ELRC generators write centiseconds throughout a line, then emit
    /// `.100` for the carry into the next second. Interpreting that one marker
    /// as milliseconds moves the word backwards (for example `.92` → `.100`)
    /// and makes karaoke highlighting jump out of order. Only adopt the line's
    /// shorter precision when the standard interpretation would regress and
    /// the adjusted value restores monotonic word timing.
    private static func parseEnhancedWordTimestamp(
        min: Substring,
        sec: Substring,
        frac: Substring?,
        lineFractionDigits: Int?,
        previousStart: TimeInterval
    ) -> TimeInterval? {
        guard let standard = parseTimestamp(min: min, sec: sec, frac: frac),
              standard < previousStart,
              let fraction = frac,
              let lineFractionDigits,
              lineFractionDigits > 0,
              lineFractionDigits < fraction.count,
              let rawFraction = Double(fraction) else {
            return parseTimestamp(min: min, sec: sec, frac: frac)
        }

        let standardFraction = rawFraction / pow(10, Double(fraction.count))
        let linePrecisionFraction = rawFraction / pow(10, Double(lineFractionDigits))
        let adjusted = standard - standardFraction + linePrecisionFraction
        return adjusted >= previousStart ? adjusted : standard
    }

    private static func parseRelativeWordLevelLine(
        body: String,
        lineStart: TimeInterval
    ) -> LyricLine? {
        let marks = body.matches(of: relativeWordPattern)
        guard !marks.isEmpty else { return nil }

        var syllables: [LyricSyllable] = []
        for (index, mark) in marks.enumerated() {
            let offset = (Double(mark.1) ?? 0) / 1000
            let duration = (Double(mark.2) ?? 0) / 1000
            let start = lineStart + offset
            let end = duration > 0 ? start + duration : start
            let textStart = mark.range.upperBound
            let textEnd = index + 1 < marks.count ? marks[index + 1].range.lowerBound : body.endIndex
            let chunk = String(body[textStart..<textEnd])
            if chunk.isEmpty {
                if let last = syllables.last {
                    syllables[syllables.count - 1] = LyricSyllable(
                        text: last.text,
                        start: last.start,
                        end: max(last.end, end)
                    )
                }
                continue
            }
            syllables.append(LyricSyllable(text: chunk, start: start, end: end))
        }

        guard !syllables.isEmpty else { return nil }
        // Relative A2/KRC marks carry an explicit duration. A zero duration is
        // valid (for example, an instantaneous OpenSubsonic cue), so only
        // repair genuinely invalid negative ranges here.
        for index in 0..<(syllables.count - 1) where syllables[index].end < syllables[index].start {
            syllables[index].end = syllables[index + 1].start
        }
        if let lastIndex = syllables.indices.last,
           syllables[lastIndex].end < syllables[lastIndex].start {
            syllables[lastIndex].end = syllables[lastIndex].start + 0.4
        }

        return makeWordLevelLine(lineStart: lineStart, syllables: syllables)
    }

    private static func makeWordLevelLine(
        lineStart: TimeInterval,
        syllables: [LyricSyllable]
    ) -> LyricLine? {
        let text = syllables.map(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return LyricLine(
            timestamp: lineStart,
            text: text,
            isSynchronized: true,
            syllables: syllables
        )
    }

    private static func parseTimestamp(
        min: Substring,
        sec: Substring,
        frac: Substring?
    ) -> TimeInterval? {
        guard let minutes = Double(min), minutes.isFinite, minutes >= 0,
              let seconds = Double(sec), seconds.isFinite, (0..<60).contains(seconds),
              let fraction = Double(frac ?? "0"), fraction.isFinite else {
            return nil
        }
        let divisor = pow(10, Double(frac?.count ?? 2))
        let result = minutes * 60 + seconds + fraction / divisor
        guard result.isFinite, result <= 7 * 24 * 3600 else { return nil }
        return result
    }

    private static func formatTimestamp(_ time: TimeInterval) -> String {
        let milliseconds = max(0, (time * 1_000).rounded()).finiteInt()
        let minutes = milliseconds / 60_000
        let seconds = (milliseconds % 60_000) / 1_000
        let fraction = milliseconds % 1_000
        return String(format: "%02d:%02d.%03d", minutes, seconds, fraction)
    }
}

/// Parses the timed-text subset used by Apple Music lyrics. TTML is much
/// broader than the representation Primuse needs, so styling and section
/// metadata are intentionally ignored while line, syllable, and singer timing
/// is retained.
private final class TTMLLyricsParser: NSObject, XMLParserDelegate {
    private struct PendingSyllable {
        let text: String
        let start: TimeInterval
        let explicitEnd: TimeInterval?
    }

    private struct SpanContext {
        var text = ""
        let begin: TimeInterval?
        let end: TimeInterval?
    }

    private var parsedLines: [(order: Int, line: LyricLine)] = []
    private var nextLineOrder = 0
    private var sawTTMLRoot = false

    private var insideParagraph = false
    private var currentLineBegin: TimeInterval?
    private var currentLineEnd: TimeInterval?
    private var currentLineVoice: LyricVoice = .primary
    private var primaryAgent: String?
    private var currentTextFragments: [String] = []
    private var currentDirectText = ""
    private var currentSyllables: [PendingSyllable] = []
    private var spanStack: [SpanContext] = []

    static func looksLikeTTML(_ content: String) -> Bool {
        content.range(
            of: #"<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?tt(?:\s|>)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    static func parse(_ content: String) -> [LyricLine] {
        guard looksLikeTTML(content),
              content.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              content.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              let data = content.data(using: .utf8) else { return [] }

        let delegate = TTMLLyricsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse(), delegate.sawTTMLRoot else { return [] }
        return delegate.parsedLines
            .sorted {
                if $0.line.timestamp == $1.line.timestamp { return $0.order < $1.order }
                return $0.line.timestamp < $1.line.timestamp
            }
            .map(\.line)
    }

    static func serialize(_ lines: [LyricLine]) -> String {
        let paragraphs = lines.compactMap { line -> String? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            var attributes: [String] = []
            if line.isSynchronized {
                attributes.append("begin=\"\(formatTimestamp(line.timestamp))\"")
            }
            if let end = line.endTime, end > line.timestamp {
                attributes.append("end=\"\(formatTimestamp(end))\"")
            }
            let agent = line.voice == .secondary ? "v2" : "v1"
            attributes.append("ttm:agent=\"\(agent)\"")
            let attributeText = attributes.isEmpty ? "" : " " + attributes.joined(separator: " ")

            guard let syllables = line.syllables, !syllables.isEmpty else {
                return "      <p\(attributeText)>\(escapeXML(text))</p>"
            }

            let spans = syllables.map { syllable -> String in
                var spanAttributes = "begin=\"\(formatTimestamp(syllable.start))\""
                if syllable.end > syllable.start {
                    spanAttributes += " end=\"\(formatTimestamp(syllable.end))\""
                }
                return "        <span \(spanAttributes)>\(escapeXML(syllable.text))</span>"
            }.joined(separator: "\n")
            return """
                  <p\(attributeText)>
            \(spans)
                  </p>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body>
            <div>
        \(paragraphs)
            </div>
          </body>
        </tt>
        """
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let name = Self.localName(qName ?? elementName)
        switch name {
        case "tt":
            sawTTMLRoot = true
        case "p":
            startParagraph(attributes: attributeDict)
        case "span":
            startSpan(attributes: attributeDict)
        case "br":
            appendText("\n")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        appendText(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch Self.localName(qName ?? elementName) {
        case "span":
            endSpan()
        case "p":
            endParagraph()
        default:
            break
        }
    }

    private func startParagraph(attributes: [String: String]) {
        // Malformed nested paragraphs should not leak the outer state into the
        // inner one. XMLParser will still ultimately report the document error.
        resetParagraph()
        insideParagraph = true
        currentLineBegin = Self.timeAttribute("begin", in: attributes)
        currentLineEnd = Self.endTime(
            in: attributes,
            elementBegin: currentLineBegin,
            inheritedBegin: nil
        )

        if let agent = Self.attribute("agent", in: attributes)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !agent.isEmpty {
            if primaryAgent == nil { primaryAgent = agent }
            currentLineVoice = agent == primaryAgent ? .primary : .secondary
        }
    }

    private func startSpan(attributes: [String: String]) {
        guard insideParagraph else { return }
        if spanStack.isEmpty { flushDirectText() }
        let begin = Self.timeAttribute("begin", in: attributes)
        spanStack.append(SpanContext(
            begin: begin,
            end: Self.endTime(
                in: attributes,
                elementBegin: begin,
                inheritedBegin: currentLineBegin
            )
        ))
    }

    private func appendText(_ text: String) {
        guard insideParagraph else { return }
        if spanStack.isEmpty {
            currentDirectText += text
        } else {
            spanStack[spanStack.count - 1].text += text
        }
    }

    private func endSpan() {
        guard insideParagraph, let span = spanStack.popLast() else { return }

        // Nested spans are normally style wrappers. Bubble their text into the
        // parent and let the outermost span own the timing so text is not
        // duplicated in the rendered line.
        if !spanStack.isEmpty {
            spanStack[spanStack.count - 1].text += span.text
            return
        }

        currentTextFragments.append(span.text)
        if let begin = span.begin, !span.text.isEmpty {
            currentSyllables.append(PendingSyllable(
                text: span.text,
                start: begin,
                explicitEnd: span.end
            ))
        }
    }

    private func endParagraph() {
        guard insideParagraph else { return }

        // A valid document cannot leave spans open here, but clearing them
        // keeps a partially parsed malformed document from contaminating later
        // delegate callbacks before XMLParser reports failure.
        spanStack.removeAll(keepingCapacity: true)
        flushDirectText()

        let text = currentTextFragments
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            let syllables = normalizedSyllables(currentSyllables, lineEnd: currentLineEnd)
            let timestamp = currentLineBegin ?? syllables.first?.start ?? 0
            parsedLines.append((
                order: nextLineOrder,
                line: LyricLine(
                    timestamp: timestamp,
                    text: text,
                    isSynchronized: currentLineBegin != nil || !syllables.isEmpty,
                    syllables: syllables.isEmpty ? nil : syllables,
                    voice: currentLineVoice
                )
            ))
            nextLineOrder += 1
        }

        resetParagraph()
    }

    private func flushDirectText() {
        guard !currentDirectText.isEmpty else { return }
        defer { currentDirectText = "" }

        // Pretty-printed TTML places indentation between timed spans. It is
        // markup whitespace rather than lyric content and must not be inserted
        // between words. Meaningful mixed text is kept verbatim.
        if currentDirectText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           currentDirectText.contains(where: { $0.isNewline }) {
            return
        }
        currentTextFragments.append(currentDirectText)
    }

    private func resetParagraph() {
        insideParagraph = false
        currentLineBegin = nil
        currentLineEnd = nil
        currentLineVoice = .primary
        currentTextFragments.removeAll(keepingCapacity: true)
        currentDirectText = ""
        currentSyllables.removeAll(keepingCapacity: true)
        spanStack.removeAll(keepingCapacity: true)
    }

    private func normalizedSyllables(
        _ syllables: [PendingSyllable],
        lineEnd: TimeInterval?
    ) -> [LyricSyllable] {
        syllables.enumerated().map { index, syllable in
            let nextStart = syllables.indices.contains(index + 1)
                ? syllables[index + 1].start
                : nil
            let inferredEnd = [syllable.explicitEnd, nextStart, lineEnd]
                .compactMap { $0 }
                .first { $0 > syllable.start }
                ?? (syllable.start + 0.5)
            return LyricSyllable(
                text: syllable.text,
                start: syllable.start,
                end: inferredEnd
            )
        }
    }

    private static func endTime(
        in attributes: [String: String],
        elementBegin: TimeInterval?,
        inheritedBegin: TimeInterval?
    ) -> TimeInterval? {
        if let end = timeAttribute("end", in: attributes) { return end }
        guard let begin = elementBegin ?? inheritedBegin,
              let duration = timeAttribute("dur", in: attributes) else { return nil }
        let end = begin + duration
        return end.isFinite ? end : nil
    }

    private static func timeAttribute(
        _ name: String,
        in attributes: [String: String]
    ) -> TimeInterval? {
        attribute(name, in: attributes).flatMap(parseTimestamp)
    }

    private static func attribute(
        _ name: String,
        in attributes: [String: String]
    ) -> String? {
        attributes.first { localName($0.key) == name.lowercased() }?.value
    }

    private static func localName(_ qualifiedName: String) -> String {
        qualifiedName.split(separator: ":", omittingEmptySubsequences: false)
            .last
            .map(String.init)?
            .lowercased() ?? qualifiedName.lowercased()
    }

    /// Apple Music commonly emits `HH:MM:SS.fff`, while TTML also permits
    /// offset times such as `1.5s`, `1500ms`, `2m`, and `1h`.
    private static func parseTimestamp(_ rawValue: String) -> TimeInterval? {
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty else { return nil }

        let units: [(suffix: String, multiplier: Double)] = [
            ("ms", 0.001),
            ("h", 3_600),
            ("m", 60),
            ("s", 1),
        ]
        for unit in units where value.hasSuffix(unit.suffix) {
            guard let amount = Double(value.dropLast(unit.suffix.count)) else { return nil }
            return validatedTime(amount * unit.multiplier)
        }

        let components = value
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count),
              let last = components.last.flatMap({ Double($0) }),
              last >= 0 else { return nil }

        let result: Double
        switch components.count {
        case 1:
            result = last
        case 2:
            guard let minutes = Double(components[0]), minutes >= 0, last < 60 else { return nil }
            result = minutes * 60 + last
        case 3:
            guard let hours = Double(components[0]), hours >= 0,
                  let minutes = Double(components[1]), (0..<60).contains(minutes),
                  last < 60 else { return nil }
            result = hours * 3_600 + minutes * 60 + last
        default:
            return nil
        }
        return validatedTime(result)
    }

    private static func validatedTime(_ value: TimeInterval) -> TimeInterval? {
        guard value.isFinite, value >= 0, value <= 7 * 24 * 3_600 else { return nil }
        return value
    }

    private static func formatTimestamp(_ time: TimeInterval) -> String {
        let milliseconds = max(0, (time * 1_000).rounded()).finiteInt()
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds % 3_600_000) / 60_000
        let seconds = (milliseconds % 60_000) / 1_000
        let fraction = milliseconds % 1_000
        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, fraction)
    }

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
