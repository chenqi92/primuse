import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Whether a syllable end came from the source document or was inferred from
/// the next word marker. Start-only formats such as ELRC need this distinction:
/// a distant next marker may describe silence, while an explicit end may be a
/// deliberately held note.
public enum LyricSyllableEndTiming: String, Codable, Hashable, Sendable {
    case explicit
    case inferred
    /// Cached lyrics written before end provenance was stored. Playback uses a
    /// conservative structural fallback for these values.
    case legacy
}

public struct LyricSyllable: Hashable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var endTiming: LyricSyllableEndTiming
    /// An effective language override for this timed token. `nil` inherits the
    /// containing line/document language.
    public var languageCode: String?

    public init(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        endTiming: LyricSyllableEndTiming = .explicit,
        languageCode: String? = nil
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.endTiming = endTiming
        self.languageCode = languageCode
    }
}

extension LyricSyllable: Codable {
    private enum CodingKeys: String, CodingKey {
        case text, start, end, endTiming, languageCode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        start = try container.decode(TimeInterval.self, forKey: .start)
        end = try container.decode(TimeInterval.self, forKey: .end)
        endTiming = try container.decodeIfPresent(
            LyricSyllableEndTiming.self,
            forKey: .endTiming
        ) ?? .legacy
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(endTiming, forKey: .endTiming)
        try container.encodeIfPresent(languageCode, forKey: .languageCode)
    }
}

/// Resolves the visual sweep duration without rewriting source timestamps.
/// Explicit durations remain authoritative; inferred start-only durations are
/// capped so a silent gap does not turn into a multi-second slow highlight.
public enum LyricSyllablePlaybackTimingPolicy {
    public static let minimumTransitionDuration: TimeInterval = 0.18

    public static func effectiveDuration(
        for syllable: LyricSyllable,
        nextSyllableStart: TimeInterval? = nil
    ) -> TimeInterval {
        let recordedDuration = max(0, syllable.end - syllable.start)
        let uncappedDuration = max(recordedDuration, minimumTransitionDuration)
        let inferredLimit = inferredDurationLimit(for: syllable.text)

        switch syllable.endTiming {
        case .explicit:
            return uncappedDuration
        case .inferred:
            return min(uncappedDuration, inferredLimit)
        case .legacy:
            // Old caches do not carry provenance. Only cap the characteristic
            // start-only shape where this word ends exactly at the next word's
            // start; standalone explicit holds remain untouched.
            guard let nextSyllableStart,
                  abs(syllable.end - nextSyllableStart) <= 0.002,
                  recordedDuration > inferredLimit else {
                return uncappedDuration
            }
            return inferredLimit
        }
    }

    public static func effectiveEnd(
        for syllable: LyricSyllable,
        nextSyllableStart: TimeInterval? = nil
    ) -> TimeInterval {
        syllable.start + effectiveDuration(
            for: syllable,
            nextSyllableStart: nextSyllableStart
        )
    }

    private static func inferredDurationLimit(for text: String) -> TimeInterval {
        let significantScalarCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar) {
                count += 1
            }
        }
        let count = max(1, significantScalarCount)
        return min(0.90, 0.42 + Double(count - 1) * 0.07)
    }
}

/// 逐字歌词里每个字的强调（参照 Apple Music）：唱到的字随演唱浮起、略微放大，唱完
/// 停在那里，整句唱完稍停再一起落回 —— 不是每个字弹一下又缩回去；正在唱的字带一圈
/// 柔光，唱完后慢慢散去。
public enum LyricSyllableEmphasisPolicy {
    /// 唱过的字上浮的高度（相对字号）。
    public static let raisedLiftRatio: Double = 0.07
    /// 唱过的字放大的比例。只给一点：每个字绕自己的中心放大，会吃掉词与词之间的空格，
    /// 放大 5% 时整句唱完空格只剩三成，主要靠上浮。
    public static let raisedScale: Double = 0.02
    public static let sustainedStretch: Double = 0.06
    public static let sustainedLiftRatio: Double = 0.04

    /// 对唱歌词（整首有两个声部，按声部分左右、分色）不做长音强调，全部给 0。
    /// 按演唱者区分显示，再加上按字唱多久超阈值改变浮起、拉伸，会同时落进
    /// US12592007 的两个要件；独唱歌词没有前一项，照常强调。
    public static func sustainedEmphasis(in syllables: [LyricSyllable], isDuet: Bool) -> [Double] {
        guard !isDuet else { return Array(repeating: 0, count: syllables.count) }
        return sustainedEmphasis(in: syllables)
    }

    /// Only a held word gets extra whole-word stretch. Start-only timestamps can
    /// include silence, so they must not be treated as evidence of a held note.
    public static func sustainedEmphasis(in syllables: [LyricSyllable]) -> [Double] {
        let durations: [Double?] = syllables.map { syllable in
            let duration = syllable.end - syllable.start
            guard syllable.endTiming == .explicit, syllable.start.isFinite,
                  duration.isFinite, duration > 0,
                  LyricSyllableLayoutPolicy.units(of: syllable.text).count == 1,
                  syllable.text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return duration
        }
        let sorted = durations.compactMap { $0 }.sorted()
        guard !sorted.isEmpty else { return Array(repeating: 0, count: syllables.count) }
        // The lower median keeps one held note from raising the ordinary-word baseline.
        let ordinaryDuration = sorted.count == 1 ? 0.5 : sorted[(sorted.count - 1) / 2]
        let onset = max(0.9, ordinaryDuration * 1.8)
        return durations.map { duration in
            guard let duration else { return 0 }
            return smoothstep((duration - onset) / max(0.6, ordinaryDuration))
        }
    }
    /// 整句唱完后保持放大的时长。
    public static let settleHold: TimeInterval = 0.2
    /// 整句落回原大小用的时长。
    public static let settleDuration: TimeInterval = 0.3
    /// 柔光亮起的时长。
    public static let glowAttack: TimeInterval = 0.12
    /// 字唱完后柔光散去的时长。
    public static let glowRelease: TimeInterval = 0.45
    /// 柔光的强度。每个字都一样，不按这个字唱多久分强弱。
    public static let glowStrength: Double = 0.7

    /// 这个字已经放大了多少：开唱前 0，随演唱先快后慢地涨，唱完为 1 并保持。
    public static func rise(
        for syllable: LyricSyllable,
        nextSyllableStart: TimeInterval? = nil,
        at now: TimeInterval
    ) -> Double {
        guard now > syllable.start else { return 0 }
        let duration = LyricSyllablePlaybackTimingPolicy.effectiveDuration(
            for: syllable,
            nextSyllableStart: nextSyllableStart
        )
        guard duration > 0, now < syllable.start + duration else { return 1 }
        return easeOut((now - syllable.start) / duration)
    }

    /// 整句还保持放大的比例：最后一个字唱完再停 `settleHold`，然后用
    /// `settleDuration` 落回。下一句接手（`deactivationTime`）之前一定落完，
    /// 切行时不会整句一下子缩回去。
    public static func lineHold(
        syllables: [LyricSyllable],
        deactivationTime: TimeInterval?,
        at now: TimeInterval
    ) -> Double {
        guard let lineEnd = sungEnd(of: syllables) else { return 1 }
        var settleEnd = lineEnd + settleHold + settleDuration
        if let deactivationTime { settleEnd = min(settleEnd, deactivationTime) }
        return 1 - smoothstep((now - (settleEnd - settleDuration)) / settleDuration)
    }

    /// 柔光强度：开唱后很快亮起，唱的过程中保持，唱完后散去。
    ///
    /// 保持统一的柔光亮度；长音强调由整词的上浮和拉伸表达。
    public static func glow(
        for syllable: LyricSyllable,
        nextSyllableStart: TimeInterval? = nil,
        at now: TimeInterval
    ) -> Double {
        let duration = LyricSyllablePlaybackTimingPolicy.effectiveDuration(
            for: syllable,
            nextSyllableStart: nextSyllableStart
        )
        let end = syllable.start + duration
        guard now > syllable.start, now < end + glowRelease else { return 0 }
        let attack = easeOut((now - syllable.start) / glowAttack)
        let release = now <= end ? 1 : 1 - (now - end) / glowRelease
        return attack * release * glowStrength
    }

    /// 整句最后一个字唱完的时刻（按各字的有效时长，不要求按时间排好序）。
    public static func sungEnd(of syllables: [LyricSyllable]) -> TimeInterval? {
        var end: TimeInterval?
        for index in syllables.indices {
            let next = syllables.indices.contains(index + 1) ? syllables[index + 1].start : nil
            let candidate = LyricSyllablePlaybackTimingPolicy.effectiveEnd(
                for: syllables[index],
                nextSyllableStart: next
            )
            end = max(end ?? candidate, candidate)
        }
        return end
    }

    private static func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func easeOut(_ value: Double) -> Double {
        let t = clamp(value)
        return 1 - (1 - t) * (1 - t)
    }

    private static func smoothstep(_ value: Double) -> Double {
        let t = clamp(value)
        return t * t * (3 - 2 * t)
    }
}

/// Applies an LRC/ELRC `[offset:]` header. Jellyfin and OpenSubsonic both
/// report a document offset, and hand-tuned `.lrc` files use the same tag, so
/// the value has to reach the timeline instead of staying in metadata.
public enum LyricDocumentOffsetPolicy {
    /// Past this magnitude the tag is far more likely to be malformed than an
    /// intended correction, so the document is left untouched.
    public static let maximumMagnitude: TimeInterval = 600

    /// The tag records milliseconds. A positive value displays the lyrics
    /// earlier, matching the OpenSubsonic track offset already in use.
    public static func offsetSeconds(in metadataLines: [String]) -> TimeInterval? {
        for line in metadataLines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { continue }
            let body = trimmed.dropFirst().dropLast()
            guard let separator = body.firstIndex(of: ":"),
                  body[..<separator].trimmingCharacters(in: .whitespaces).lowercased() == "offset"
            else { continue }
            var value = body[body.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("+") { value.removeFirst() }
            guard let milliseconds = Double(value), milliseconds.isFinite else { continue }
            let seconds = milliseconds / 1_000
            guard seconds != 0, abs(seconds) <= maximumMagnitude else { return nil }
            return seconds
        }
        return nil
    }

    public static func removingOffsetTag(from metadataLines: [String]) -> [String] {
        metadataLines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"),
                  let separator = trimmed.dropFirst().dropLast().firstIndex(of: ":") else {
                return true
            }
            let key = trimmed.dropFirst().dropLast()[..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return key != "offset"
        }
    }

    public static func applying(offset: TimeInterval, to lines: [LyricLine]) -> [LyricLine] {
        guard offset != 0, offset.isFinite else { return lines }
        return lines.map { shifting($0, by: offset) }
    }

    private static func shifting(_ line: LyricLine, by offset: TimeInterval) -> LyricLine {
        func shiftCues(_ cues: [LyricSyllable]?) -> [LyricSyllable]? {
            cues?.map { syllable in
                var result = syllable
                result.start = moved(syllable.start, by: offset)
                result.end = moved(syllable.end, by: offset)
                return result
            }
        }
        func shiftTranslation(_ translation: LyricManualTranslation) -> LyricManualTranslation {
            var result = translation
            result.syllables = shiftCues(translation.syllables)
            return result
        }
        var shifted = line
        shifted.timestamp = moved(line.timestamp, by: offset)
        shifted.endTimestamp = line.endTimestamp.map { moved($0, by: offset) }
        shifted.syllables = shiftCues(line.syllables)
        shifted.romanizationSyllables = shiftCues(line.romanizationSyllables)
        shifted.manualTranslation = line.manualTranslation.map(shiftTranslation)
        shifted.alternateManualTranslations = line.alternateManualTranslations.map(shiftTranslation)
        shifted.background = line.background?.map { shifting($0, by: offset) }
        return shifted
    }

    /// Millisecond rounding keeps shifted values printable as LRC timestamps
    /// instead of accumulating binary floating-point noise.
    private static func moved(_ time: TimeInterval, by offset: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return time }
        return max(0, ((time - offset) * 1_000).rounded() / 1_000)
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

    /// Resolves one rendered row without allowing a document-wide direction to
    /// reverse an opposite-script row. A leading `[la:]` tag supplies the
    /// document fallback, while strongly LTR or RTL rows keep their own reading
    /// order. Mixed rows use Unicode bidi's first-strong base direction so
    /// separately rendered syllables keep the same order as a single text run;
    /// rows without letters inherit the document fallback.
    public static func resolvePresentationDirection(
        for line: LyricLine,
        documentFallback: LyricWritingDirection = .natural
    ) -> LyricWritingDirection {
        resolvePresentationDirection(
            for: line.text,
            documentFallback: documentFallback
        )
    }

    public static func resolvePresentationDirection(
        for text: String,
        documentFallback: LyricWritingDirection = .natural
    ) -> LyricWritingDirection {
        return firstStrongDirection(in: text) ?? documentFallback
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

    private static func firstStrongDirection(in text: String) -> LyricWritingDirection? {
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            return rightToLeftLetterRanges.contains(where: { $0.contains(scalar.value) })
                ? .rightToLeft
                : .leftToRight
        }
        return nil
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
    /// 一个字超出容器不到这么多时仍留在本行。逐字歌词按整行自身的宽度报尺寸，
    /// 扫光层再按这个宽度排一次，每一行都正好卡在边界上；而这个宽度经过像素对齐
    /// 或加减外扩边距后，可能比各字宽度之和少零点几个点。严格比较会把最后一个字
    /// 挤到下一行，扫光层整体被居中挪开，和底下的字错位。
    public static let wrapTolerance: Double = 1

    /// 与 `placements` 同一套换行规则算出的内容尺寸，宽度不超过容器。
    public static func contentSize(
        itemSizes: [LyricFlowItemSize],
        containerWidth: Double,
        spacing: Double = 0
    ) -> LyricFlowItemSize {
        let availableWidth = max(0, containerWidth)
        let itemSpacing = max(0, spacing)
        var widestRow = 0.0
        var height = 0.0
        for row in rows(itemSizes: itemSizes, availableWidth: availableWidth, spacing: itemSpacing) {
            widestRow = max(widestRow, width(of: row, itemSizes: itemSizes, spacing: itemSpacing))
            height += row.reduce(0.0) { max($0, max(0, itemSizes[$1].height)) }
        }
        return LyricFlowItemSize(width: min(widestRow, availableWidth), height: height)
    }

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
        var y = 0.0
        var result: [LyricFlowItemPlacement] = []
        result.reserveCapacity(itemSizes.count)

        for row in rows(itemSizes: itemSizes, availableWidth: availableWidth, spacing: itemSpacing) {
            let rowWidth = width(of: row, itemSizes: itemSizes, spacing: itemSpacing)
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

    private static func rows(
        itemSizes: [LyricFlowItemSize],
        availableWidth: Double,
        spacing: Double
    ) -> [[Int]] {
        var rows: [[Int]] = []
        var currentRow: [Int] = []
        var currentRowWidth = 0.0

        for (index, itemSize) in itemSizes.enumerated() {
            let width = max(0, itemSize.width)
            let proposedWidth = currentRowWidth
                + (currentRow.isEmpty ? 0 : spacing)
                + width
            if proposedWidth > availableWidth + wrapTolerance, !currentRow.isEmpty {
                rows.append(currentRow)
                currentRow = []
                currentRowWidth = 0
            }

            currentRowWidth += (currentRow.isEmpty ? 0 : spacing) + width
            currentRow.append(index)
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }

    private static func width(
        of row: [Int],
        itemSizes: [LyricFlowItemSize],
        spacing: Double
    ) -> Double {
        row.enumerated().reduce(0.0) { partial, pair in
            partial + (pair.offset == 0 ? 0 : spacing) + max(0, itemSizes[pair.element].width)
        }
    }
}

/// 逐字歌词排版用的小块。流式排版只在两个时间块之间换行；有的歌词整句或半句只打
/// 一个时间（行尾补结束时间的 ELRC、按词组打轴的 QRC 等），这一块比歌词栏宽时
/// 没法折行，整句从左边伸出右边被裁掉，同一首里句句如此，别的歌却换行正常。
///
/// 这里把这样的块拆到正文换行的粒度：汉字、假名逐字，别的文字按空格分词（韩文也
/// 按词，和系统排正文一样）；句读、小写假名、长音不放到行首，开括号、开引号不留在
/// 行尾。时间按字数分这一块原来的有效时长，扫光与上浮仍按原来的节奏走完整块。
/// 只用于显示：歌词数据、编辑与写回都保持原样。
public enum LyricSyllableLayoutPolicy {
    /// 没有需要拆的块时原样返回。
    public static func layoutSyllables(_ syllables: [LyricSyllable]) -> [LyricSyllable] {
        var result: [LyricSyllable]?
        for index in syllables.indices {
            let syllable = syllables[index]
            let pieces = units(of: syllable.text)
            guard pieces.count > 1 else {
                result?.append(syllable)
                continue
            }
            if result == nil {
                result = Array(syllables[..<index])
            }
            let nextStart = syllables.indices.contains(index + 1) ? syllables[index + 1].start : nil
            result?.append(contentsOf: split(syllable, into: pieces, nextSyllableStart: nextStart))
        }
        return result ?? syllables
    }

    /// 能单独折行的小块，空格跟着前一块（开头的空格跟着第一块）。
    static func units(of text: String) -> [String] {
        var units: [String] = []
        var current = ""
        var currentHasText = false
        var previous: Character?
        for character in text {
            if let previous, currentHasText, allowsBreak(between: previous, and: character) {
                units.append(current)
                current = ""
                currentHasText = false
            }
            current.append(character)
            currentHasText = currentHasText || !character.isWhitespace
            previous = character
        }
        if !current.isEmpty {
            units.append(current)
        }
        return units
    }

    private static func split(
        _ syllable: LyricSyllable,
        into pieces: [String],
        nextSyllableStart: TimeInterval?
    ) -> [LyricSyllable] {
        // 先按原来那一块算出有效结束时刻（推断出来的时长有上限），拆出来的小块都是
        // 这段时间里的明确区间，不再各自套一遍上限。
        let end = LyricSyllablePlaybackTimingPolicy.effectiveEnd(
            for: syllable,
            nextSyllableStart: nextSyllableStart
        )
        let span = max(0, end - syllable.start)
        // 标点不唱，不分时间。
        let weights = pieces.map { piece in
            Double(max(1, piece.filter { $0.isLetter || $0.isNumber }.count))
        }
        let totalWeight = weights.reduce(0, +)
        var result: [LyricSyllable] = []
        result.reserveCapacity(pieces.count)
        var start = syllable.start
        var consumedWeight = 0.0
        for index in pieces.indices {
            consumedWeight += weights[index]
            let pieceEnd = index == pieces.count - 1
                ? end
                : syllable.start + span * consumedWeight / totalWeight
            result.append(LyricSyllable(
                text: pieces[index],
                start: start,
                end: pieceEnd,
                endTiming: .explicit,
                languageCode: syllable.languageCode
            ))
            start = pieceEnd
        }
        return result
    }

    private static func allowsBreak(between previous: Character, and next: Character) -> Bool {
        if next.isWhitespace { return false }
        if lineStartProhibited.contains(next) || lineEndProhibited.contains(previous) {
            return false
        }
        if previous.isWhitespace { return true }
        return breaksPerCharacter(previous) || breaksPerCharacter(next)
    }

    /// 汉字、假名、注音和全角符号逐字可断；韩文按词断，不在这里。
    private static func breaksPerCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, // CJK symbols and punctuation
             0x3040...0x30FF, // Hiragana, Katakana
             0x3100...0x312F, // Bopomofo
             0x31F0...0x31FF, // Katakana phonetic extensions
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified
             0xF900...0xFAFF, // CJK Compatibility
             0xFF01...0xFF60, // Fullwidth forms
             0xFF66...0xFF9D, // Halfwidth Katakana
             0x20000...0x3134F:
            return true
        default:
            return false
        }
    }

    // 々〻写成转义:本地化检查会把字面上的汉字当成界面文案。
    private static let lineStartProhibited: Set<Character> = Set(
        "、。，．,.！!？?：:；;）)］]｝}〕〉》」』】〙〗〟’”｠»…‥・ー〜～ゝゞヽヾ\u{3005}\u{303B}゛゜%％"
            + "ぁぃぅぇぉっゃゅょゎゕゖァィゥェォッャュョヮヵヶㇰㇱㇲㇳㇴㇵㇶㇷㇸㇹㇺㇻㇼㇽㇾㇿ"
    )

    private static let lineEndProhibited: Set<Character> = Set("（(［[｛{〔〈《「『【〘〖〝‘“｟«")
}

/// 行所属声部。LRC/A2 没有该信息，预留给 TTML（Apple Music 对唱）等格式。
public enum LyricVoice: String, Codable, Sendable, CaseIterable {
    case primary    // 主声部 / 默认演唱者，左对齐
    case secondary  // 对唱声部，建议右对齐
}

/// 对唱歌词分左右（参照 Apple Music）：整首有两个声部时，对唱声部的行摆到
/// 另一侧。用户选的对齐方式决定主声部那一侧；选居中时主声部靠前、对唱靠后。
public enum LyricDuetLayoutPolicy {
    public enum Side: Sendable, Equatable {
        case leading
        case center
        case trailing
    }

    public static func side(for voice: LyricVoice, preferred: Side, isDuet: Bool) -> Side {
        guard isDuet else { return preferred }
        let primary: Side = preferred == .trailing ? .trailing : .leading
        guard voice == .secondary else { return primary }
        return primary == .leading ? .trailing : .leading
    }
}

/// A human-authored translation that travels with its source lyric line. This
/// is deliberately separate from transient machine-translation caches: callers
/// can therefore prefer authoritative embedded/bilingual text without treating
/// a provider response as part of the lyric document.
public enum LyricManualTranslationSource: String, Codable, Hashable, Sendable {
    /// A dedicated container field such as `TRANSLATEDLYRICS`, `TRANSLATION`,
    /// or a language-qualified lyrics field.
    case embeddedField
    /// A second adjacent LRC row carrying the same timestamp.
    case bilingualLRC
    /// Authored in Primuse for a local structured cache when no external lyric
    /// adapter can represent the source row and translation as separate data.
    case localEditor
}

public struct LyricManualTranslation: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var text: String {
        didSet { if text != oldValue { syllables = nil } }
    }
    public var languageCode: String?
    public var source: LyricManualTranslationSource
    public var syllables: [LyricSyllable]?

    public init(
        id: String = UUID().uuidString,
        text: String,
        languageCode: String? = nil,
        source: LyricManualTranslationSource,
        syllables: [LyricSyllable]? = nil
    ) {
        self.id = id
        self.text = text
        self.languageCode = languageCode
        self.source = source
        self.syllables = syllables
    }
}

/// 这份歌词是从哪儿读来的(#357):播放页歌词顶上那枚来源标签按它写。
///
/// 和 `documentIsLocalOverride` 一样只记在第一行上,随歌词缓存一起存。旧缓存没有这一项,
/// 读出来是 nil,界面上就不标来源;更新的版本写下的、这里认不出的来源同样读成 nil,
/// 不会让整份歌词读不出来。来源不进 `LyricsDocumentFingerprint`:同一份歌词换个来源记法不算改了内容。
public struct LyricsDocumentSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// 歌曲旁边的歌词文件。`identifier` 是小写、不带点的扩展名。
        case file
        /// 音频文件标签里的歌词。
        case embedded
        /// 音乐服务器给的歌词。`identifier` 是 `MusicSourceType.rawValue`。
        case server
        /// 在线歌词源。`identifier` 是刮削源的 rawValue,`name` 是取到那一刻它的名字
        /// (自定义源后来被删了,还能照这个名字写)。
        case online
        /// 导入「音乐」App 的本机文件里的歌词。
        case appleMusic
        case transcript
    }

    public var kind: Kind
    public var identifier: String?
    public var name: String?

    public init(kind: Kind, identifier: String? = nil, name: String? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.name = name
    }

    /// 歌词文件。`pathOrName` 给文件名或路径都行,只取扩展名。
    public static func file(_ pathOrName: String?) -> LyricsDocumentSource {
        let ext = (pathOrName ?? "")
            .split(separator: "/").last
            .map { String($0) }
            .flatMap { name -> String? in
                guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
                return String(name[name.index(after: dot)...]).lowercased()
            }
        return LyricsDocumentSource(kind: .file, identifier: ext?.isEmpty == false ? ext : nil)
    }

    public static let embedded = LyricsDocumentSource(kind: .embedded)
    public static let appleMusic = LyricsDocumentSource(kind: .appleMusic)
    public static let transcript = LyricsDocumentSource(kind: .transcript)

    public static func server(_ sourceType: String) -> LyricsDocumentSource {
        LyricsDocumentSource(kind: .server, identifier: sourceType)
    }

    public static func online(identifier: String, name: String) -> LyricsDocumentSource {
        LyricsDocumentSource(kind: .online, identifier: identifier, name: name)
    }

    /// 一份歌词记着的来源。记在第一行上;读缓存时双语配对、对唱分组可能把第一行并进别的行
    /// 或挪进和声,所以往后多看几行、连同和声一起找。
    public static func of(_ lines: [LyricLine]) -> LyricsDocumentSource? {
        for line in lines.prefix(4) {
            if let source = line.documentSource { return source }
            if let source = line.background?.lazy.compactMap(\.documentSource).first { return source }
        }
        return nil
    }

    /// 同一份歌词重读一遍后,新的那份是否记下了旧的那份没有(或不同)的来源。
    public static func adds(to current: [LyricLine], from refreshed: [LyricLine]) -> Bool {
        guard let source = of(refreshed) else { return false }
        return of(current) != source
    }

    /// 把来源记到第一行上;空歌词原样返回。产出歌词的地方(读文件、读标签、问服务器、在线取)调它。
    public func stamped(_ lines: [LyricLine]) -> [LyricLine] {
        guard !lines.isEmpty else { return lines }
        var stamped = lines
        stamped[0].documentSource = self
        return stamped
    }
}

/// 歌词顶上那枚来源标签写什么(#357)。本机改过的歌词不论原来从哪儿来,都标成本机修改。
public enum LyricsSourceBadge: Hashable, Sendable {
    case localEdit
    /// `format` 是大写的扩展名(TTML、LRC…),不知道扩展名时为 nil。
    case file(format: String?)
    case embedded
    case server(sourceType: String)
    case online(identifier: String, name: String)
    case appleMusic

    public static func resolve(_ lines: [LyricLine]) -> LyricsSourceBadge? {
        guard let first = lines.first else { return nil }
        if first.documentIsLocalOverride { return .localEdit }
        guard let source = LyricsDocumentSource.of(lines) else { return nil }
        switch source.kind {
        case .file:
            return .file(format: source.identifier.map { $0.uppercased() })
        case .embedded:
            return .embedded
        case .server:
            guard let type = source.identifier, !type.isEmpty else { return nil }
            return .server(sourceType: type)
        case .online:
            guard let identifier = source.identifier, !identifier.isEmpty else { return nil }
            return .online(identifier: identifier, name: source.name ?? "")
        case .appleMusic:
            return .appleMusic
        case .transcript:
            return nil
        }
    }
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
    /// Explicit line end carried by structured formats such as TTML. LRC does
    /// not provide this value. It is kept separately from syllable timing so
    /// overlapping line-level voices can retain their source time windows.
    public var endTimestamp: TimeInterval?
    /// 声部归属，默认主声部。
    public var voice: LyricVoice
    /// 背景和声子行（同一时间窗内附唱）。`background` 内的 background 应永远为 nil。
    public var background: [LyricLine]?
    /// 这一行是写在某一句里面的和声(TTML `x-bg`、LYS/QRC 的和声标记),只出现在 `background` 里。
    /// 旧版本还把和主唱时间重叠的另一声部整句并进过 `background`,那些没有这个标记;
    /// 读旧缓存时据此把它们拆回成自己的一行(见 `LyricVoiceTimelinePolicy.separatingLegacyOverlapGroups`)。
    public var isBackingVocal: Bool
    /// Leading LRC/ELRC document metadata such as `[ti:]`, `[ar:]` and
    /// `[by:]`. Only the first parsed lyric line carries this value so the
    /// existing line-oriented cache and CloudKit snapshot remain compatible
    /// while editable documents can still round-trip their headers.
    public var metadataLines: [String]?
    /// Optional per-line language override from structured formats such as
    /// TTML `xml:lang`. Document-wide language remains in `[la:...]` metadata.
    public var languageCode: String?
    /// Document-level provenance stored on the first line. A local override
    /// must not be replaced by automatic source revalidation until an explicit
    /// conflict-resolution workflow writes a new authoritative document.
    public var documentIsLocalOverride: Bool
    /// 这份歌词从哪儿来,同样只记在第一行上(见 `LyricsDocumentSource`)。
    public var documentSource: LyricsDocumentSource?
    /// An authoritative human translation paired with this source line. Old
    /// caches omit this key and continue to decode with a nil value.
    public var manualTranslation: LyricManualTranslation?
    /// Additional authored translations retained when a container exposes
    /// more than one language-qualified lyrics field. `manualTranslation`
    /// remains the explicitly selected translation used by existing UI.
    public var alternateManualTranslations: [LyricManualTranslation]
    /// An authored romanization of this line, from TTML `x-roman` or a source
    /// that ships a romanized track. It reads the original out loud rather
    /// than translating it, so it belongs to no target language and must not
    /// be offered as a translation.
    public var romanization: String? {
        didSet { if romanization != oldValue { romanizationSyllables = nil } }
    }
    /// Authored pronunciation cues can divide words differently from the sung line.
    public var romanizationSyllables: [LyricSyllable]?

    public init(
        id: String = UUID().uuidString,
        timestamp: TimeInterval,
        text: String,
        isSynchronized: Bool? = nil,
        syllables: [LyricSyllable]? = nil,
        endTimestamp: TimeInterval? = nil,
        voice: LyricVoice = .primary,
        background: [LyricLine]? = nil,
        metadataLines: [String]? = nil,
        languageCode: String? = nil,
        documentIsLocalOverride: Bool = false,
        manualTranslation: LyricManualTranslation? = nil,
        alternateManualTranslations: [LyricManualTranslation] = [],
        romanization: String? = nil,
        romanizationSyllables: [LyricSyllable]? = nil,
        documentSource: LyricsDocumentSource? = nil,
        isBackingVocal: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.isSynchronized = isSynchronized ?? (timestamp > 0 || syllables?.isEmpty == false)
        self.syllables = syllables
        self.endTimestamp = endTimestamp
        self.voice = voice
        self.background = background
        self.metadataLines = metadataLines
        self.languageCode = languageCode
        self.documentIsLocalOverride = documentIsLocalOverride
        self.manualTranslation = manualTranslation
        self.alternateManualTranslations = alternateManualTranslations
        self.romanization = romanization
        self.romanizationSyllables = romanizationSyllables
        self.documentSource = documentSource
        self.isBackingVocal = isBackingVocal
    }

    /// 行结束时间。结构化行末与最后一字取较晚者；普通 LRC 无信息，外部仍需靠下一行推断。
    public var endTime: TimeInterval? {
        let candidates = [endTimestamp, syllables?.last?.end]
            .compactMap { $0 }
            .filter { $0 >= timestamp }
        return candidates.max()
    }

    public var isWordLevel: Bool { syllables?.isEmpty == false }

    public var containsWordLevelContent: Bool {
        isWordLevel || (background?.contains(where: \.containsWordLevelContent) ?? false)
    }

    public var allManualTranslations: [LyricManualTranslation] {
        (manualTranslation.map { [$0] } ?? []) + alternateManualTranslations
    }
}

enum LyricAnnotationKind {
    case translation, romanization

    func attach(_ annotation: LyricLine, language: String?, to line: inout LyricLine) {
        guard !annotation.text.isEmpty else { return }
        switch self {
        case .romanization:
            if line.romanization == nil { line.romanization = annotation.text }
            if line.romanization == annotation.text, line.romanizationSyllables == nil {
                line.romanizationSyllables = annotation.syllables
            }
        case .translation:
            var translations = line.allManualTranslations
            if let index = translations.firstIndex(where: { $0.text == annotation.text && $0.languageCode == language }) {
                if translations[index].syllables == nil { translations[index].syllables = annotation.syllables }
            } else {
                translations.append(LyricManualTranslation(
                    id: annotation.id, text: annotation.text, languageCode: language, source: .embeddedField,
                    syllables: annotation.syllables
                ))
            }
            line.manualTranslation = translations.first
            line.alternateManualTranslations = Array(translations.dropFirst())
        }
    }
}

/// 不同声部各走各的时间轴。TTML 里两个 `ttm:agent` 时间重叠时(对唱里一人还没唱完另一人
/// 已经开口,或两人同时唱)各自仍是独立的一行,此刻谁在唱由
/// `LyricConcurrentVoicePolicy` 判定;只有写在一句里面的和声(`x-bg`)才收进那一句的 `background`。
public enum LyricVoiceTimelinePolicy {
    /// 旧版本读 TTML(和读缓存)时,把和主唱时间重叠的另一声部整句并进了主唱那一行的
    /// `background`,缓存里存的就是并过的样子。读出来时把认得出是独立一句的拆回成自己的一行:
    /// 只看对唱的歌词(另一声部还有自己的行),只看没有 `isBackingVocal` 标记的子行,
    /// 并且它和主唱同时开口、同时唱完,或唱到主唱那一句结束以后——写在一句里面的和声不会这样。
    /// 认不出的照旧留作和声。新解析的歌词没有这种子行,原样返回。
    public static func separatingLegacyOverlapGroups(in lines: [LyricLine]) -> [LyricLine] {
        guard lines.contains(where: { $0.voice == .secondary && $0.isSynchronized }),
              lines.contains(where: { line in
                  line.voice == .primary
                      && line.background?.contains(where: { isLegacyGroupCandidate($0) }) == true
              }) else { return lines }

        var ordered: [(order: Int, line: LyricLine)] = []
        ordered.reserveCapacity(lines.count)
        var separatedAny = false
        for line in lines {
            guard line.voice == .primary, let children = line.background, !children.isEmpty else {
                ordered.append((ordered.count, line))
                continue
            }
            var kept: [LyricLine] = []
            var separated: [LyricLine] = []
            for child in children {
                if isLegacyGroupCandidate(child), looksLikeOwnLine(child, beside: line) {
                    separated.append(child)
                } else {
                    kept.append(child)
                }
            }
            var host = line
            if !separated.isEmpty {
                host.background = kept.isEmpty ? nil : kept
                separatedAny = true
            }
            ordered.append((ordered.count, host))
            for child in separated {
                ordered.append((ordered.count, child))
            }
        }
        guard separatedAny else { return lines }
        return ordered.sorted {
            if $0.line.timestamp == $1.line.timestamp { return $0.order < $1.order }
            return $0.line.timestamp < $1.line.timestamp
        }.map(\.line)
    }

    private static func isLegacyGroupCandidate(_ child: LyricLine) -> Bool {
        child.voice == .secondary && !child.isBackingVocal && child.isSynchronized
    }

    /// 写在一句里面的和声时间落在那一句之内,通常晚于主唱开口、早于主唱收尾。
    private static func looksLikeOwnLine(_ child: LyricLine, beside host: LyricLine) -> Bool {
        let tolerance = 0.05
        guard host.isSynchronized else { return false }
        if abs(child.timestamp - host.timestamp) <= tolerance { return true }
        guard let childEnd = child.endTime else { return false }
        if let hostEnd = host.endTime, childEnd > hostEnd + tolerance { return true }
        if let hostLastWord = host.syllables?.last?.end,
           let childLastWord = child.syllables?.last?.end,
           abs(childLastWord - hostLastWord) <= tolerance {
            return true
        }
        return false
    }

    public static func flattenedLines(_ lines: [LyricLine]) -> [LyricLine] {
        var flattened: [(order: Int, line: LyricLine)] = []
        for line in lines {
            var primary = line
            primary.background = nil
            flattened.append((flattened.count, primary))

            for background in line.background ?? [] {
                var child = background
                child.background = nil
                flattened.append((flattened.count, child))
            }
        }
        return flattened.sorted {
            if $0.line.timestamp == $1.line.timestamp { return $0.order < $1.order }
            return $0.line.timestamp < $1.line.timestamp
        }.map(\.line)
    }

    public static func isActive(
        _ line: LyricLine,
        at time: TimeInterval,
        lookahead: TimeInterval = 0
    ) -> Bool {
        guard time + max(0, lookahead) >= line.timestamp else { return false }
        guard let end = line.endTime else { return true }
        return time < end
    }
}

// MARK: - Codable (custom — 旧 JSON 缺 voice/background 也能解码)

extension LyricLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, text, isSynchronized, syllables, endTimestamp
        case voice, background, metadataLines, languageCode, documentIsLocalOverride
        case manualTranslation, alternateManualTranslations, romanization, romanizationSyllables
        case documentSource
        case isBackingVocal = "backingVocal"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        self.text = try c.decode(String.self, forKey: .text)
        self.syllables = try c.decodeIfPresent([LyricSyllable].self, forKey: .syllables)
        self.endTimestamp = try c.decodeIfPresent(TimeInterval.self, forKey: .endTimestamp)
        self.isSynchronized = try c.decodeIfPresent(Bool.self, forKey: .isSynchronized)
            ?? (timestamp > 0 || syllables?.isEmpty == false)
        self.voice = try c.decodeIfPresent(LyricVoice.self, forKey: .voice) ?? .primary
        self.background = try c.decodeIfPresent([LyricLine].self, forKey: .background)
        self.metadataLines = try c.decodeIfPresent([String].self, forKey: .metadataLines)
        self.languageCode = try c.decodeIfPresent(String.self, forKey: .languageCode)
        self.documentIsLocalOverride = try c.decodeIfPresent(
            Bool.self,
            forKey: .documentIsLocalOverride
        ) ?? false
        self.manualTranslation = try c.decodeIfPresent(
            LyricManualTranslation.self,
            forKey: .manualTranslation
        )
        self.alternateManualTranslations = try c.decodeIfPresent(
            [LyricManualTranslation].self,
            forKey: .alternateManualTranslations
        ) ?? []
        self.romanization = try c.decodeIfPresent(String.self, forKey: .romanization)
        self.romanizationSyllables = try c.decodeIfPresent([LyricSyllable].self, forKey: .romanizationSyllables)
        // 认不出的来源(更新的版本写的)当作没记,不让整份歌词解码失败。
        self.documentSource = try? c.decodeIfPresent(
            LyricsDocumentSource.self,
            forKey: .documentSource
        )
        self.isBackingVocal = try c.decodeIfPresent(Bool.self, forKey: .isBackingVocal) ?? false

        // Older parsers cached square-bracket word lyrics as unsynchronized
        // source text. Recover only that lossless shape, retaining row identity
        // and authored metadata across every cache reader.
        if timestamp == 0, !isSynchronized, syllables?.isEmpty != false,
           LyricsContentParser.squareWordTimestampIssue(text) == nil,
           let recovered = LyricsContentParser.parseSquareWordLevelLine(text) {
            timestamp = recovered.timestamp
            text = recovered.text
            isSynchronized = true
            syllables = recovered.syllables
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(syllables, forKey: .syllables)
        try c.encodeIfPresent(endTimestamp, forKey: .endTimestamp)
        let inferredSynchronization = timestamp > 0 || syllables?.isEmpty == false
        if isSynchronized != inferredSynchronization {
            try c.encode(isSynchronized, forKey: .isSynchronized)
        }
        // voice / background 仅在非默认值时写入，避免老歌词缓存膨胀
        if voice != .primary { try c.encode(voice, forKey: .voice) }
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(metadataLines, forKey: .metadataLines)
        try c.encodeIfPresent(languageCode, forKey: .languageCode)
        if documentIsLocalOverride {
            try c.encode(true, forKey: .documentIsLocalOverride)
        }
        try c.encodeIfPresent(manualTranslation, forKey: .manualTranslation)
        if !alternateManualTranslations.isEmpty {
            try c.encode(alternateManualTranslations, forKey: .alternateManualTranslations)
        }
        try c.encodeIfPresent(romanization, forKey: .romanization)
        try c.encodeIfPresent(romanizationSyllables, forKey: .romanizationSyllables)
        try c.encodeIfPresent(documentSource, forKey: .documentSource)
        if isBackingVocal { try c.encode(true, forKey: .isBackingVocal) }
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
            if lines.contains(where: \.containsWordLevelContent) { return .wordLevel }
            if lines.contains(where: \.isSynchronized) { return .lineLevel }
            return .plain
        }
        if let wordTimedFormat = WordTimedLyricsParser.detect(content),
           WordTimedLyricsParser.parse(content, as: wordTimedFormat)
            .contains(where: \.containsWordLevelContent) {
            return .wordLevel
        }
        if SubtitleLyricsParser.detect(content) != nil {
            let subtitleLines = SubtitleLyricsParser.parse(content)
            if subtitleLines.contains(where: \.containsWordLevelContent) { return .wordLevel }
            if !subtitleLines.isEmpty { return .lineLevel }
        }
        if LRCWordTimingCompanion.containsCompanionRows(content) {
            // `<offset,index>` markers would otherwise pass for relative word
            // marks even when they fit no line.
            let lines = LyricsContentParser.parse(content)
            if lines.contains(where: \.containsWordLevelContent) { return .wordLevel }
            if lines.contains(where: \.isSynchronized) { return .lineLevel }
            return .plain
        }
        if content.range(of: #"<\d+:\d+(?:[.:]\d+)?>"#, options: .regularExpression) != nil {
            return .wordLevel
        }
        if content.range(of: #"<\d+,\d+(,\d+)?>"#, options: .regularExpression) != nil {
            return .wordLevel
        }
        if content.components(separatedBy: .newlines).contains(where: {
            LyricsContentParser.usesSquareWordTimestamps($0)
        }) {
            return .wordLevel
        }
        if content.range(of: #"\[\d+:\d+(?:[.:]\d+)?\]"#, options: .regularExpression) != nil {
            return .lineLevel
        }
        if LyricsContentParser.looksLikeLyricifyLines(content) {
            return .lineLevel
        }
        return .plain
    }

    public var isSynced: Bool { self != .plain }
}

public struct LyricsParsingOptions: Hashable, Sendable {
    public var detectBilingualLRC: Bool

    public init(detectBilingualLRC: Bool = true) {
        self.detectBilingualLRC = detectBilingualLRC
    }

    public static let automatic = LyricsParsingOptions(detectBilingualLRC: true)
    public static let literal = LyricsParsingOptions(detectBilingualLRC: false)
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

/// File containers exposed by the lyrics conversion tool. `lrc` preserves word
/// timing as enhanced LRC when the source carries syllables; `srt` writes
/// SubRip cues for timed documents; `plainText` removes every timing marker.
public enum LyricsFileFormat: String, Codable, Sendable, CaseIterable {
    case lrc
    case ttml
    case srt
    case plainText
}

/// Concrete source container detected for display and diagnostics in the
/// lyrics converter.
public enum LyricsDetectedSourceFormat: String, Equatable, Hashable, Sendable {
    case empty
    case lrc
    case elrc
    case ttml
    case lys
    case yrc
    case qrc
    case krc
    case lyl
    case webVTT
    case subRip
    case substationAlpha
    case plain
    case invalid
}

public enum LyricsFileConversionError: Error, Equatable, Sendable {
    case emptyInput
    case invalidContent
    case requiresTiming
}

public enum LyricsFileDecodeError: Error, Equatable, Sendable {
    case emptyFile
    case tooLarge
    case encryptedKRC
    case binaryOrUnreadable
}

public struct LyricsFileConversionResult: Equatable, Sendable {
    public let sourceFormat: LyricsFormat
    public let detectedFormat: LyricsDetectedSourceFormat
    public let targetFormat: LyricsFileFormat
    public let lines: [LyricLine]
    public let output: String
    public let flattensVoices: Bool
    public let dropsCompanionWordTiming: Bool

    public init(
        sourceFormat: LyricsFormat,
        detectedFormat: LyricsDetectedSourceFormat = .lrc,
        targetFormat: LyricsFileFormat,
        lines: [LyricLine],
        output: String,
        flattensVoices: Bool = false,
        dropsCompanionWordTiming: Bool = false
    ) {
        self.sourceFormat = sourceFormat
        self.detectedFormat = detectedFormat
        self.targetFormat = targetFormat
        self.lines = lines
        self.output = output
        self.flattensVoices = flattensVoices
        self.dropsCompanionWordTiming = dropsCompanionWordTiming
    }
}

/// Converts between the lyric formats that the shared parser can represent.
/// Structured targets preserve line and syllable timing. TTML retains nested
/// backing vocals, duet voices, and companion word timings; flat targets
/// (LRC, SRT, plain text) flatten voice alignment and companion word cues.
public enum LyricsFileConverter {
    public static let maximumFileBytes = 4 * 1_024 * 1_024

    /// Known binary container headers that must never be coerced into Latin-1
    /// plain text when opened in the converter.
    private static let binaryMagicPrefixes: [[UInt8]] = [
        [0x89, 0x50, 0x4E, 0x47], // PNG
        [0xFF, 0xD8, 0xFF],       // JPEG
        [0x50, 0x4B, 0x03, 0x04], // ZIP / Office / JAR
        [0x25, 0x50, 0x44, 0x46], // PDF
        [0x1F, 0x8B],             // GZIP
        [0x49, 0x44, 0x33],       // ID3
        [0x66, 0x4C, 0x61, 0x43], // FLAC
        [0x4F, 0x67, 0x67, 0x53], // OGG
        [0x52, 0x49, 0x46, 0x46], // RIFF / WAV / WEBP
    ]

    private static let encryptedKRCMagic: [UInt8] = [0x6B, 0x72, 0x63, 0x31] // "krc1"

    /// Decodes a standalone lyric file into text while rejecting encrypted KRC
    /// binaries and arbitrary binary files that Latin-1 would otherwise decode
    /// as mojibake.
    public static func decodeText(from data: Data) throws -> String {
        guard !data.isEmpty else { throw LyricsFileDecodeError.emptyFile }
        guard data.count <= maximumFileBytes else { throw LyricsFileDecodeError.tooLarge }

        let head = Array(data.prefix(8))
        if head.starts(with: encryptedKRCMagic) {
            throw LyricsFileDecodeError.encryptedKRC
        }
        if binaryMagicPrefixes.contains(where: { head.starts(with: $0) }) {
            throw LyricsFileDecodeError.binaryOrUnreadable
        }

        // UTF-16 with explicit BOM.
        if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) {
            guard var text = String(data: data, encoding: .utf16),
                  !containsDisallowedControlScalars(text, rejectC1Controls: false) else {
                throw LyricsFileDecodeError.binaryOrUnreadable
            }
            if text.first == "\u{FEFF}" { text.removeFirst() }
            return text
        }

        // UTF-8 (with or without BOM).
        if var utf8 = String(data: data, encoding: .utf8) {
            guard !containsDisallowedControlScalars(utf8, rejectC1Controls: false) else {
                throw LyricsFileDecodeError.binaryOrUnreadable
            }
            if utf8.first == "\u{FEFF}" { utf8.removeFirst() }
            return utf8
        }

        // Non-UTF-8 data containing raw NUL bytes is either BOM-less UTF-16 or binary.
        if data.contains(0x00) {
            if data.count.isMultiple(of: 2) {
                for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian] {
                    if var candidate = String(data: data, encoding: encoding),
                       !candidate.contains("\u{FFFD}"),
                       !containsDisallowedControlScalars(candidate, rejectC1Controls: true) {
                        if candidate.first == "\u{FEFF}" { candidate.removeFirst() }
                        return candidate
                    }
                }
            }
            throw LyricsFileDecodeError.binaryOrUnreadable
        }

        guard var decoded = TextEncodingRepair.bestDecoding(
            of: data,
            encodings: [
                TextEncodingRepair.gb18030,
                TextEncodingRepair.big5,
                .shiftJIS,
                TextEncodingRepair.eucKR,
                .windowsCP1252,
                .isoLatin1,
            ]
        ),
        !containsDisallowedControlScalars(decoded, rejectC1Controls: true) else {
            throw LyricsFileDecodeError.binaryOrUnreadable
        }
        if decoded.first == "\u{FEFF}" { decoded.removeFirst() }
        return decoded
    }

    /// Identifies the concrete input lyric format using the exact same parser
    /// precedence as `convert(_:to:)`.
    public static func detectFormat(_ content: String) -> LyricsDetectedSourceFormat {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .empty }
        let validation = LyricsContentParser.validateEditableText(normalized)
        guard validation.isValid else { return .invalid }
        return detectedFormat(forNormalized: normalized, validation: validation)
    }

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

        let detected = detectedFormat(forNormalized: normalized, validation: validation)
        let hasVoices = validation.lines.contains { line in
            line.voice == .secondary || !(line.background?.isEmpty ?? true)
        }
        let hasCompanionWordTiming = validation.lines.contains(where: carriesCompanionWordTiming)

        let output: String
        switch targetFormat {
        case .lrc:
            let expandedLines = LyricVoiceTimelinePolicy.flattenedLines(validation.lines)
            output = LyricsContentParser.serialize(expandedLines)
        case .ttml:
            let prepared = prepareForTTML(validation.lines)
            output = LyricsContentParser.serializeTTML(prepared)
        case .srt:
            let expandedLines = LyricVoiceTimelinePolicy.flattenedLines(validation.lines)
            guard let subRip = LyricsExportPolicy.subRip(expandedLines) else {
                throw LyricsFileConversionError.requiresTiming
            }
            output = subRip.trimmingCharacters(in: .newlines)
        case .plainText:
            let expandedLines = LyricVoiceTimelinePolicy.flattenedLines(validation.lines)
            output = expandedLines.map(\.text).joined(separator: "\n")
        }

        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LyricsFileConversionError.invalidContent
        }
        let preservesStructure = targetFormat == .ttml
        return LyricsFileConversionResult(
            sourceFormat: validation.format,
            detectedFormat: detected,
            targetFormat: targetFormat,
            lines: validation.lines,
            output: output,
            flattensVoices: !preservesStructure && hasVoices,
            dropsCompanionWordTiming: !preservesStructure && hasCompanionWordTiming
        )
    }

    private static func detectedFormat(
        forNormalized normalized: String,
        validation: LyricsEditableValidation
    ) -> LyricsDetectedSourceFormat {
        if LyricsContentParser.isTTML(normalized) { return .ttml }
        if let wordTimed = WordTimedLyricsParser.detect(normalized) {
            switch wordTimed {
            case .lys: return .lys
            case .yrc: return .yrc
            case .qrc: return .qrc
            case .krc: return .krc
            }
        }
        if let subtitle = SubtitleLyricsParser.detect(normalized) {
            switch subtitle {
            case .webVTT: return .webVTT
            case .subRip: return .subRip
            case .substationAlpha: return .substationAlpha
            }
        }
        if LyricsContentParser.looksLikeLyricifyLines(normalized) { return .lyl }
        switch validation.format {
        case .plain: return .plain
        case .lineLevel: return .lrc
        case .wordLevel: return .elrc
        }
    }

    /// Prepares parsed lines for TTML export without losing nested backing vocals:
    /// promotes bilingual LRC romanized reading rows into `x-roman` and fills
    /// missing `<p end="...">` attributes from word-level end times.
    private static func prepareForTTML(_ lines: [LyricLine]) -> [LyricLine] {
        let readingIDs = LyricRomanizedReadingPolicy.readingIDs(
            in: LyricVoiceTimelinePolicy.flattenedLines(lines)
        )
        return lines.map { prepareLineForTTML($0, readingIDs: readingIDs) }
    }

    private static func prepareLineForTTML(
        _ line: LyricLine,
        readingIDs: Set<String>
    ) -> LyricLine {
        var prepared = line
        if prepared.romanization?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           !readingIDs.isEmpty,
           let readingIndex = prepared.allManualTranslations.firstIndex(where: { readingIDs.contains($0.id) }) {
            var remaining = prepared.allManualTranslations
            let reading = remaining.remove(at: readingIndex)
            prepared.romanization = reading.text
            prepared.romanizationSyllables = reading.syllables
            prepared.manualTranslation = remaining.first
            prepared.alternateManualTranslations = Array(remaining.dropFirst())
        }
        if prepared.endTimestamp == nil,
           let inferredEnd = prepared.endTime,
           inferredEnd >= prepared.timestamp {
            prepared.endTimestamp = inferredEnd
        }
        if let background = prepared.background {
            prepared.background = background.map { prepareLineForTTML($0, readingIDs: readingIDs) }
        }
        return prepared
    }

    private static func carriesCompanionWordTiming(_ line: LyricLine) -> Bool {
        if line.romanizationSyllables?.isEmpty == false { return true }
        if line.allManualTranslations.contains(where: { $0.syllables?.isEmpty == false }) { return true }
        return line.background?.contains(where: carriesCompanionWordTiming) ?? false
    }

    private static func containsDisallowedControlScalars(
        _ text: String,
        rejectC1Controls: Bool
    ) -> Bool {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0x09 || value == 0x0A || value == 0x0D { continue }
            if value < 0x20 || value == 0x7F { return true }
            if rejectC1Controls, (0x80...0x9F).contains(value) { return true }
        }
        return false
    }
}

/// Some servers and lyric sites hand out LRC text that was XML-escaped once
/// too often, so rows arrive as `There&apos;s`. Plain LRC has no entity
/// syntax of its own, which makes decoding the common forms safe. It happens
/// in a single pass so `&amp;apos;` becomes the literal `&apos;` it encodes.
public enum LyricTextEntityPolicy {
    private static let namedEntities: [Substring: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
    ]

    public static func decoded(_ text: String) -> String {
        decoded(text, allowsLineBreaks: false)
    }

    static func decoded(_ text: String, allowsLineBreaks: Bool) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                  let (replacement, next) = entity(in: text, at: index, allowsLineBreaks: allowsLineBreaks) else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            result.append(replacement)
            index = next
        }
        return result
    }

    public static func decoded(_ line: LyricLine) -> LyricLine {
        var line = line
        line.text = decoded(line.text)
        line.syllables = line.syllables?.map(decoded)
        line.background = line.background?.map { decoded($0) }
        let readingCues = line.romanizationSyllables
        line.romanization = line.romanization.map { decoded($0) }
        line.romanizationSyllables = readingCues?.map(decoded)
        line.manualTranslation = line.manualTranslation.map(decoded)
        line.alternateManualTranslations = line.alternateManualTranslations.map(decoded)
        return line
    }

    private static func decoded(_ word: LyricSyllable) -> LyricSyllable {
        var result = word
        result.text = decoded(word.text)
        return result
    }

    private static func decoded(_ translation: LyricManualTranslation) -> LyricManualTranslation {
        var result = translation
        result.text = decoded(translation.text)
        result.syllables = translation.syllables?.map(decoded)
        return result
    }

    private static func entity(
        in text: String,
        at ampersand: String.Index,
        allowsLineBreaks: Bool
    ) -> (Character, String.Index)? {
        let nameStart = text.index(after: ampersand)
        guard let semicolon = text[nameStart...].prefix(9).firstIndex(of: ";") else {
            return nil
        }
        let name = text[nameStart..<semicolon]
        let next = text.index(after: semicolon)
        if let named = namedEntities[name] { return (named, next) }
        guard name.first == "#" else { return nil }
        let digits = name.dropFirst()
        let value: UInt32?
        if digits.first == "x" || digits.first == "X" {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value, value >= 0x20 || value == 0x09 || (allowsLineBreaks && (value == 10 || value == 13)),
              let scalar = Unicode.Scalar(value) else { return nil }
        return (Character(scalar), next)
    }
}

public enum LyricsContentParser {
    nonisolated(unsafe) private static let lineHeadPattern = /\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]/
    nonisolated(unsafe) private static let relativeLineHeadPattern = /^\[(\d+),(\d+)\]/
    nonisolated(unsafe) private static let inlineWordPattern = /<(\d+):(\d{2})(?:[.:](\d{1,3}))?>/
    nonisolated(unsafe) private static let relativeWordPattern = /<(\d+),(\d+)(?:,\d+)?>/
    nonisolated(unsafe) private static let metadataPattern = /^\[[A-Za-z][A-Za-z0-9_-]*:.*\]\s*$/

    public static func parse(
        _ content: String,
        options: LyricsParsingOptions = .automatic
    ) -> [LyricLine] {
        let content = removingByteOrderMark(content)
        if let lines = SourceLyricsDocument.decode(content) { return lines }
        if TTMLLyricsParser.looksLikeTTML(content) {
            return TTMLLyricsParser.parse(content)
        }
        // Millisecond word-timed documents (.lys / .yrc / .qrc) are recognized
        // by content so the sidecar, embedded-tag and server paths all read
        // them without a separate loader.
        if let format = WordTimedLyricsParser.detect(content) {
            let wordTimedLines = WordTimedLyricsParser.parse(content, as: format)
            if !wordTimedLines.isEmpty { return wordTimedLines }
        }
        // Subtitle documents (.vtt / .srt) must be recognized before the LRC
        // path: their inline `<mm:ss.ttt>` markers are shaped exactly like
        // ELRC word markers, so the LRC reader would keep the cue timing lines
        // as lyric text.
        if SubtitleLyricsParser.detect(content) != nil {
            return SubtitleLyricsParser.parse(content, options: options)
        }

        var lines: [LyricLine] = []
        var metadataLines: [String] = []
        var isLeadingMetadataRegion = true
        var companionRows: [(row: LRCWordTimingCompanion.Row, position: Int)] = []

        for raw in content.components(separatedBy: .newlines) {
            if raw.firstMatch(of: metadataPattern) != nil {
                metadataLines.append(raw)
                continue
            }
            if isLeadingMetadataRegion, raw.trimmingCharacters(in: .whitespaces).isEmpty,
               !metadataLines.isEmpty {
                metadataLines.append(raw)
                continue
            }

            // A `[tt]` row times the line next to it; it is never a lyric or
            // a translation row of its own.
            if let companion = LRCWordTimingCompanion.row(raw) {
                isLeadingMetadataRegion = false
                companionRows.append((companion, lines.count))
                continue
            }

            if let parsed = parseSquareWordLevelLine(raw) {
                isLeadingMetadataRegion = false
                lines.append(parsed)
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

        lines = lines.map { LyricTextEntityPolicy.decoded($0) }
        if !companionRows.isEmpty {
            // Character indices count the decoded text, and the rows must be
            // gone before same-time rows are paired as translations.
            lines = LRCWordTimingCompanion.applying(companionRows, to: lines)
        }
        if options.detectBilingualLRC {
            lines = LyricBilingualPairingPolicy.pair(lines)
        }
        lines = lines.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp == rhs.element.timestamp {
                return lhs.offset < rhs.offset
            }
            return lhs.element.timestamp < rhs.element.timestamp
        }.map(\.element)
        if !metadataLines.isEmpty, !lines.isEmpty {
            // `[offset:]` belongs to the document's timeline, not to playback
            // preferences. Applying it here keeps every surface — rendering,
            // seeking, the editor and writeback — on one set of timestamps.
            if let offset = LyricDocumentOffsetPolicy.offsetSeconds(in: metadataLines) {
                lines = LyricDocumentOffsetPolicy.applying(offset: offset, to: lines)
                metadataLines = LyricDocumentOffsetPolicy.removingOffsetTag(from: metadataLines)
            }
            lines[0].metadataLines = metadataLines.isEmpty ? nil : metadataLines
        }
        return lines
    }

    public static func isTTML(_ content: String) -> Bool {
        TTMLLyricsParser.looksLikeTTML(content)
    }

    /// Whether the document is a subtitle file read as lyrics. Like TTML it
    /// must travel through the shared model before it reaches a surface that
    /// expects LRC text — the editor never shows cue markup.
    public static func isSubtitleDocument(_ content: String) -> Bool {
        SubtitleLyricsParser.detect(content) != nil
    }

    fileprivate static func usesSquareWordTimestamps(_ raw: String) -> Bool {
        let marks = raw.matches(of: lineHeadPattern)
        guard let first = marks.first,
              raw[..<first.range.lowerBound].allSatisfy({
                  $0.isWhitespace || $0 == "\u{FEFF}"
              }) else { return false }
        // Adjacent timestamps repeat a whole LRC line; text between them
        // instead identifies word starts, including a final end-only marker.
        return zip(marks, marks.dropFirst()).contains { left, right in
            !raw[left.range.upperBound..<right.range.lowerBound].allSatisfy(\.isWhitespace)
        }
    }

    fileprivate static func parseSquareWordLevelLine(_ raw: String) -> LyricLine? {
        guard usesSquareWordTimestamps(raw),
              let first = raw.firstMatch(of: lineHeadPattern),
              let lineStart = parseTimestamp(min: first.1, sec: first.2, frac: first.3) else {
            return nil
        }
        return parseWordLevelLine(
            body: raw,
            lineStart: lineStart,
            lineFractionDigits: first.3?.count,
            squareBrackets: true
        )
    }

    fileprivate static func squareWordTimestampIssue(_ raw: String) -> LyricsValidationIssueKind? {
        let marks = raw.matches(of: lineHeadPattern)
        var previousStart: TimeInterval = 0
        for mark in marks {
            guard let start = parseEnhancedWordTimestamp(
                min: mark.1,
                sec: mark.2,
                frac: mark.3,
                lineFractionDigits: marks.first?.3?.count,
                previousStart: previousStart
            ) else { return .invalidWordTimestamp }
            if start < previousStart { return .nonMonotonicTimestamp }
            previousStart = start
        }
        return nil
    }

    public static func parseText(
        _ text: String,
        options: LyricsParsingOptions = .automatic
    ) -> [LyricLine] {
        let text = removingByteOrderMark(text)
        if let lines = SourceLyricsDocument.decode(text) { return lines }
        if TTMLLyricsParser.looksLikeTTML(text) {
            // Malformed XML must not fall through and surface its tags as
            // unsynchronized lyric lines.
            return TTMLLyricsParser.parse(text)
        }
        if WordTimedLyricsParser.detect(text) != nil {
            // A word-timed document must not degrade into plain rows carrying
            // its own timing markers as text.
            let wordTimedLines = WordTimedLyricsParser.parse(text)
            if !wordTimedLines.isEmpty { return wordTimedLines }
        }
        if SubtitleLyricsParser.detect(text) != nil {
            // Same for a subtitle document: its cue timing lines are not lyrics.
            return SubtitleLyricsParser.parse(text, options: options)
        }
        let synchronized = parse(text, options: options)
        if !synchronized.isEmpty { return synchronized }

        return text.components(separatedBy: .newlines)
            .map { LyricTextEntityPolicy.decoded($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { LyricLine(timestamp: 0, text: $0.element, isSynchronized: false) }
    }

    private static func removingByteOrderMark(_ text: String) -> String {
        guard text.unicodeScalars.first == "\u{FEFF}" else { return text }
        return String(text.unicodeScalars.dropFirst())
    }

    /// Whether the document uses Lyricify Lines millisecond line windows
    /// (`[startMs,endMs]text`) without millisecond word-timed markers.
    public static func looksLikeLyricifyLines(_ content: String) -> Bool {
        guard !TTMLLyricsParser.looksLikeTTML(content),
              WordTimedLyricsParser.detect(content) == nil,
              SubtitleLyricsParser.detect(content) == nil else { return false }
        var relativeCount = 0
        var lrcCount = 0
        for raw in content.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed.firstMatch(of: metadataPattern) == nil else { continue }
            if trimmed.firstMatch(of: relativeLineHeadPattern) != nil {
                relativeCount += 1
            } else if trimmed.firstMatch(of: lineHeadPattern) != nil {
                lrcCount += 1
            }
        }
        return relativeCount > 0 && relativeCount >= lrcCount
    }

    private static func looksLikeMalformedQRCEnvelope(_ content: String) -> Bool {
        let trimmed = content.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        guard trimmed.first == "<" else { return false }
        let prefix = String(trimmed.prefix(256)).lowercased()
        if prefix.contains("<qrcinfos") || prefix.contains("<lyric_1") {
            return true
        }
        if prefix.hasPrefix("<?xml") && content.range(of: #"\bLyricContent\s*="#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        return false
    }

    /// Convert editable lyric models back to a text representation without
    /// flattening synchronization data. Plain lyrics remain plain, line-level
    /// lyrics use LRC timestamps, and syllable lyrics use ELRC word markers.
    public static func serialize(
        _ lines: [LyricLine],
        includeManualTranslations: Bool = true
    ) -> String {
        let body = lines.flatMap { line -> [String] in
            var serializedLines = [serializeLine(line)]
            if includeManualTranslations {
                let primaryText = flattenedCompanionText(line.text)
                var seen: Set<String> = primaryText.isEmpty ? [] : [primaryText]
                var companionRows: [String] = []
                if let romanization = line.romanization.map(flattenedCompanionText),
                   !romanization.isEmpty,
                   seen.insert(romanization).inserted {
                    companionRows.append(romanization)
                }
                for companion in line.allManualTranslations {
                    let text = flattenedCompanionText(companion.text)
                    guard !text.isEmpty, seen.insert(text).inserted else { continue }
                    companionRows.append(text)
                }
                for companionText in companionRows {
                    if line.isSynchronized {
                        serializedLines.append(
                            "[\(formatTimestamp(line.timestamp))]\(companionText)"
                        )
                    } else {
                        serializedLines.append(companionText)
                    }
                }
            }
            return serializedLines
        }.joined(separator: "\n")
        guard let metadata = lines.first?.metadataLines, !metadata.isEmpty else {
            return body
        }
        return (metadata + [body]).joined(separator: "\n")
    }

    private static func flattenedCompanionText(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func serializeLine(_ line: LyricLine) -> String {
        guard line.isSynchronized else { return line.text }

        let lineHead = "[\(formatTimestamp(line.timestamp))]"
        guard let syllables = line.syllables, !syllables.isEmpty else {
            return lineHead + line.text
        }

        var body = syllables.map {
            "<\(formatTimestamp($0.start))>\($0.text)"
        }.joined()
        if let last = syllables.last,
           last.endTiming == .explicit,
           last.end >= last.start {
            body += "<\(formatTimestamp(last.end))>"
        }
        return lineHead + body
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
        let normalized = removingByteOrderMark(text)
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
                format: lines.contains(where: \.containsWordLevelContent)
                    ? .wordLevel
                    : (lines.contains(where: \.isSynchronized) ? .lineLevel : .plain),
                lines: lines,
                issues: lines.isEmpty
                    ? [.init(lineNumber: 1, kind: .invalidTimestamp)]
                    : []
            )
        }

        if WordTimedLyricsParser.detect(normalized) != nil {
            // Millisecond word-timed documents (`.lys`, `.yrc`, `.qrc`, `.krc`)
            // have their own grammar and may carry XML envelopes, JSON credit
            // rows, or overlapping backing rows that LRC line validation would
            // misreport as broken timestamps.
            return LyricsEditableValidation(
                normalizedContent: normalized,
                format: parsedLines.contains(where: \.containsWordLevelContent)
                    ? .wordLevel
                    : (parsedLines.contains(where: \.isSynchronized) ? .lineLevel : .plain),
                lines: parsedLines,
                issues: parsedLines.isEmpty
                    ? [.init(lineNumber: 1, kind: .invalidTimestamp)]
                    : []
            )
        }

        if looksLikeMalformedQRCEnvelope(normalized) {
            return LyricsEditableValidation(
                normalizedContent: normalized,
                format: .plain,
                lines: [],
                issues: [.init(lineNumber: 1, kind: .invalidTimestamp)]
            )
        }

        if SubtitleLyricsParser.detect(normalized) != nil {
            // Cue markup is not malformed LRC. Validating it line by line would
            // report every payload row as a broken word timestamp.
            return LyricsEditableValidation(
                normalizedContent: normalized,
                format: format,
                lines: parsedLines,
                issues: parsedLines.isEmpty
                    ? [.init(lineNumber: 1, kind: .invalidTimestamp)]
                    : []
            )
        }

        var issues: [LyricsValidationIssue] = []
        var previousTimestamp: TimeInterval?
        for (offset, raw) in normalized.components(separatedBy: .newlines).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, raw.firstMatch(of: metadataPattern) == nil else { continue }
            // A companion row has no lyric of its own; markers that do not fit
            // leave its line untimed rather than broken.
            if LRCWordTimingCompanion.row(raw) != nil { continue }

            let looksTimed = trimmed.hasPrefix("[")
                && trimmed.dropFirst().first?.isNumber == true
            let squareWords = usesSquareWordTimestamps(raw)
            let containsWordDelimiters = squareWords
                || ((trimmed.contains("<") || trimmed.contains(">"))
                    && (looksTimed || format == .wordLevel))
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
            if squareWords, let issue = squareWordTimestampIssue(raw) {
                issues.append(.init(lineNumber: offset + 1, kind: issue))
            }

            for line in parsed {
                if let words = line.syllables,
                   zip(words, words.dropFirst()).contains(where: { $0.start > $1.start }) {
                    issues.append(.init(lineNumber: offset + 1, kind: .nonMonotonicTimestamp))
                }
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
                  left.voice == right.voice,
                  left.languageCode == right.languageCode,
                  normalizedMetadata(left.metadataLines)
                    == normalizedMetadata(right.metadataLines),
                  abs(left.timestamp - right.timestamp) <= tolerance,
                  optionalTimesEqual(left.endTimestamp, right.endTimestamp, tolerance: tolerance),
                  manualTranslationsEqual(left.manualTranslation, right.manualTranslation, tolerance: tolerance),
                  left.alternateManualTranslations.count == right.alternateManualTranslations.count,
                  zip(left.alternateManualTranslations, right.alternateManualTranslations).allSatisfy({
                      $0.languageCode == $1.languageCode && $0.source == $1.source
                          && manualTranslationsEqual($0, $1, tolerance: tolerance)
                  }),
                  left.romanization == right.romanization,
                  syllablesEqual(left.syllables, right.syllables, tolerance: tolerance),
                  syllablesEqual(left.romanizationSyllables, right.romanizationSyllables, tolerance: tolerance),
                  areSemanticallyEquivalent(
                    left.background ?? [],
                    right.background ?? [],
                    tolerance: tolerance
                  ) else {
                return false
            }
        }
        return true
    }

    private static func syllablesEqual(
        _ lhs: [LyricSyllable]?, _ rhs: [LyricSyllable]?, tolerance: TimeInterval
    ) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { left, right in
            left.text == right.text && abs(left.start - right.start) <= tolerance
                && abs(left.end - right.end) <= tolerance && left.endTiming == right.endTiming
                && left.languageCode == right.languageCode
        }
    }

    /// Compares two complete lyric documents after removing transport-only
    /// differences. Every meaningful source row must be represented by the
    /// parser before structural comparison is allowed, so a missing timed row,
    /// an extra untimed row, or malformed trailing content cannot be hidden by
    /// the parser's normal best-effort behaviour.
    public static func areContentsSemanticallyEquivalent(
        _ lhs: String,
        _ rhs: String,
        tolerance: TimeInterval = 0.002
    ) -> Bool {
        let left = normalizedComparisonContent(lhs)
        let right = normalizedComparisonContent(rhs)
        guard !left.isEmpty, !right.isEmpty else { return left == right }
        if left == right { return true }

        // Sidecar writes preserve TTML bytes. Falling back to the best-effort
        // XML parser here could hide unsupported metadata or text nodes that
        // were dropped during a remote rewrite.
        if TTMLLyricsParser.looksLikeTTML(left)
            || TTMLLyricsParser.looksLikeTTML(right) {
            return false
        }

        // A subtitle document is read-only, so it is never the text Primuse
        // wrote. Comparing it through the parser could bless a write that
        // silently dropped cue settings, voices or noise rows.
        if SubtitleLyricsParser.detect(left) != nil
            || SubtitleLyricsParser.detect(right) != nil {
            return false
        }

        guard isCompletelyRepresentedForComparison(left),
              isCompletelyRepresentedForComparison(right) else {
            return false
        }

        for options in [LyricsParsingOptions.automatic, .literal] {
            let leftLines = parseText(left, options: options)
            let rightLines = parseText(right, options: options)
            if areSemanticallyEquivalent(leftLines, rightLines, tolerance: tolerance) {
                return true
            }
        }
        return false
    }

    private static func normalizedComparisonContent(_ content: String) -> String {
        var normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.unicodeScalars.first?.value == 0xFEFF {
            normalized.removeFirst()
        }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCompletelyRepresentedForComparison(_ content: String) -> Bool {
        if TTMLLyricsParser.looksLikeTTML(content) { return false }
        guard LyricsFormat.detect(content) != .plain else { return true }

        var representedLineCount = 0
        for raw in content.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if raw.firstMatch(of: metadataPattern) != nil {
                continue
            }
            if LRCWordTimingCompanion.row(raw) != nil {
                continue
            }

            if usesSquareWordTimestamps(raw) {
                guard parseSquareWordLevelLine(raw) != nil,
                      squareWordTimestampIssue(raw) == nil else {
                    return false
                }
                representedLineCount += 1
                continue
            }

            let absoluteHeads = raw.matches(of: lineHeadPattern)
            if !absoluteHeads.isEmpty {
                guard let firstHead = absoluteHeads.first,
                      raw[..<firstHead.range.lowerBound].allSatisfy(\.isWhitespace) else {
                    return false
                }
                for (leftHead, rightHead) in zip(
                    absoluteHeads,
                    absoluteHeads.dropFirst()
                ) where !raw[leftHead.range.upperBound..<rightHead.range.lowerBound]
                    .allSatisfy(\.isWhitespace) {
                    return false
                }
                guard let lastHead = absoluteHeads.last else { return false }
                let body = String(raw[lastHead.range.upperBound...])
                guard isLyricBodyCompletelyRepresented(body) else { return false }
                let parsed = parse(raw, options: .literal)
                guard parsed.count == absoluteHeads.count else { return false }
                representedLineCount += parsed.count
                continue
            }
            if raw.firstMatch(of: relativeLineHeadPattern) != nil {
                guard let head = raw.firstMatch(of: relativeLineHeadPattern),
                      isLyricBodyCompletelyRepresented(
                        String(raw[head.range.upperBound...])
                      ) else { return false }
                let parsed = parse(raw, options: .literal)
                guard parsed.count == 1 else { return false }
                representedLineCount += 1
                continue
            }

            // A timed document with an unclassified non-empty row would be
            // silently dropped by `parseText`; treating it as equivalent could
            // therefore bless a partial or wrong write.
            return false
        }
        return representedLineCount > 0
    }

    private static func isLyricBodyCompletelyRepresented(_ body: String) -> Bool {
        guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if let firstWord = body.firstMatch(of: inlineWordPattern) {
            return body[..<firstWord.range.lowerBound].allSatisfy(\.isWhitespace)
        }
        if let firstWord = body.firstMatch(of: relativeWordPattern) {
            return body[..<firstWord.range.lowerBound].allSatisfy(\.isWhitespace)
        }
        return true
    }

    private static func normalizedMetadata(_ metadataLines: [String]?) -> [String] {
        (metadataLines ?? []).compactMap { line in
            let normalized = line
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func manualTranslationsEqual(
        _ lhs: LyricManualTranslation?,
        _ rhs: LyricManualTranslation?,
        tolerance: TimeInterval
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (.some(let lhs), .some(let rhs)):
            // LRC can retain the authored text but has no standard field for
            // its provenance or language tag.
            return lhs.text == rhs.text && syllablesEqual(lhs.syllables, rhs.syllables, tolerance: tolerance)
        default:
            return false
        }
    }

    private static func optionalTimesEqual(
        _ lhs: TimeInterval?,
        _ rhs: TimeInterval?,
        tolerance: TimeInterval
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (.some(let lhs), .some(let rhs)):
            return abs(lhs - rhs) <= tolerance
        default:
            return false
        }
    }

    private static func parseWordLevelLine(
        body: String,
        lineStart: TimeInterval,
        lineFractionDigits: Int?,
        squareBrackets: Bool = false
    ) -> LyricLine? {
        let marks = body.matches(of: squareBrackets ? lineHeadPattern : inlineWordPattern)
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
            if chunk.isEmpty || (index == marks.count - 1 && chunk.allSatisfy(\.isWhitespace)) {
                if let last = syllables.last {
                    syllables[syllables.count - 1] = LyricSyllable(
                        text: last.text,
                        start: last.start,
                        end: max(last.end, start),
                        endTiming: .explicit,
                        languageCode: last.languageCode
                    )
                }
                continue
            }
            syllables.append(LyricSyllable(
                text: chunk,
                start: start,
                end: start,
                endTiming: .inferred
            ))
        }

        guard !syllables.isEmpty else { return nil }
        for index in 0..<(syllables.count - 1) {
            syllables[index].end = max(syllables[index].end, syllables[index + 1].start)
        }
        if let lastIndex = syllables.indices.last,
           syllables[lastIndex].endTiming != .explicit,
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
                        end: max(last.end, end),
                        endTiming: .explicit,
                        languageCode: last.languageCode
                    )
                }
                continue
            }
            syllables.append(LyricSyllable(
                text: chunk,
                start: start,
                end: end,
                endTiming: .explicit
            ))
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
        var text: String
        let start: TimeInterval
        let explicitEnd: TimeInterval?
        let languageCode: String?
    }

    /// A `ttm:role` Apple Music actually ships inside a lyric paragraph. Only
    /// the default role is sung by the lead voice, so every other role must
    /// stay out of the main line's text and syllable timeline.
    private enum SpanRole {
        /// `x-bg` — a backing vocal group singing on its own time window.
        case background
        /// `x-translation` — an authored translation of the enclosing line.
        case translation
        /// `x-roman` — a romanization of the enclosing line.
        case romanization

        init?(rawValue: String) {
            for token in rawValue.lowercased().split(whereSeparator: \.isWhitespace) {
                switch token {
                case "x-bg": self = .background
                case "x-translation": self = .translation
                case "x-roman", "x-romaji", "x-romanization": self = .romanization
                default: continue
                }
                return
            }
            return nil
        }
    }

    private enum RubyRole: String {
        case container, textContainer, text, delimiter, base, baseContainer, none
    }

    private struct Reading {
        let text: String
        let syllables: [LyricSyllable]?
    }

    private typealias AnnotationKind = LyricAnnotationKind

    private struct HeadAnnotation {
        let kind: AnnotationKind
        let languageCode: String?
        let line: LyricLine
    }

    private struct SpanContext {
        var pendingText = ""
        var segments: [SpanSegment] = []
        var translations: [LyricManualTranslation] = []
        var romanization: Reading?
        var rubyText: [SpanSegment] = []
        let ruby: RubyRole?
        let role: SpanRole?
        let begin: TimeInterval?
        let end: TimeInterval?
        let languageCode: String?
    }

    private struct SpanSegment {
        let text: String
        let begin: TimeInterval?
        let end: TimeInterval?
        let preservesWhitespace: Bool
        let languageCode: String?
        var rubyReading: [SpanSegment]? = nil

        init(
            text: String,
            begin: TimeInterval?,
            end: TimeInterval?,
            preservesWhitespace: Bool = false,
            languageCode: String? = nil,
            rubyReading: [SpanSegment]? = nil
        ) {
            self.text = text
            self.begin = begin
            self.end = end
            self.preservesWhitespace = preservesWhitespace
            self.languageCode = languageCode
            self.rubyReading = rubyReading
        }

        var isTimed: Bool { begin != nil }
    }

    private struct Element {
        let name: String
        let language: String?
        var begin: TimeInterval?
        var end: TimeInterval?
        var lastChildEnd: TimeInterval?
        var startsCue = false
        var usesRelativeChildren = false
        var sequential = false
    }

    private var parsedLines: [(order: Int, line: LyricLine)] = []
    private var nextLineOrder = 0
    private var sawTTMLRoot = false
    private var documentLanguageCode: String?
    private var elements: [Element] = []
    private var annotationsByKey: [String: [HeadAnnotation]] = [:]
    private var rubyStyles: [String: (role: RubyRole?, references: [String])] = [:]
    private var ignoredDepth = 0
    private var timing = TimingParameters()

    private var paragraphDepth: Int?
    private var insideParagraph: Bool { paragraphDepth != nil }
    private var currentKey: String?
    private var currentAnnotationKind: AnnotationKind?
    private var currentLineBegin: TimeInterval?
    private var currentLineEnd: TimeInterval?
    private var inheritedLineBegin: TimeInterval?
    private var inheritedLineEnd: TimeInterval?
    private var currentLineVoice: LyricVoice = .primary
    private var currentLineLanguageCode: String?
    private var primaryAgent: String?
    private var currentSegments: [SpanSegment] = []
    private var currentDirectText = ""
    private var currentUntimedPrefix = ""
    private var currentSyllables: [PendingSyllable] = []
    private var currentTranslations: [LyricManualTranslation] = []
    private var currentRomanization: Reading?
    private var currentBackgroundLines: [LyricLine] = []
    private var spanStack: [SpanContext] = []

    static func looksLikeTTML(_ content: String) -> Bool {
        var rest = content.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        while rest.hasPrefix("<?") || rest.hasPrefix("<!--") {
            let terminator = rest.hasPrefix("<?") ? "?>" : "-->"
            guard let end = rest.range(of: terminator) else { return false }
            rest = rest[end.upperBound...].drop(while: \.isWhitespace)
        }
        if rest.hasPrefix("<!DOCTYPE") { rest = rest.dropFirst(9).drop(while: \.isWhitespace) }
        else if rest.first == "<" { rest = rest.dropFirst() }
        else { return false }
        let root = rest.prefix { !$0.isWhitespace && $0 != ">" && $0 != "/" }
        return root.split(separator: ":").last?.lowercased() == "tt"
    }

    static func parse(_ content: String) -> [LyricLine] {
        guard looksLikeTTML(content),
              content.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              content.range(of: "<!ENTITY", options: .caseInsensitive) == nil else { return [] }

        let delegate = TTMLLyricsParser()
        // Tag readers have already decoded the bytes. Keep XMLParser from reinterpreting
        // the UTF-8 buffer according to a declaration copied from the original file.
        let xml = content.drop(while: { $0.isWhitespace || $0 == "\u{FEFF}" })
        var data: Data
        if xml.hasPrefix("<?xml"), xml.dropFirst(5).first?.isWhitespace == true,
           let end = xml.range(of: "?>") {
            let declaration = String(xml[..<end.upperBound]).replacingOccurrences(
                of: #"\s+encoding\s*=\s*(?:"[^"]*"|'[^']*')"#, with: "", options: [.regularExpression, .caseInsensitive]
            )
            data = Data(declaration.utf8)
            data.append(contentsOf: xml[end.upperBound...].utf8)
        } else {
            data = Data(xml.utf8)
        }
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        guard parser.parse(), delegate.sawTTMLRoot else { return [] }
        var orderedLines = delegate.parsedLines
            .sorted {
                if $0.line.timestamp == $1.line.timestamp { return $0.order < $1.order }
                return $0.line.timestamp < $1.line.timestamp
            }
            .map(\.line)
        if let languageCode = delegate.documentLanguageCode,
           !orderedLines.isEmpty {
            var metadata = orderedLines[0].metadataLines ?? []
            if LyricManualTranslationPolicy.declaredLanguageCode(in: metadata) == nil {
                metadata.insert("[la:\(languageCode)]", at: 0)
                orderedLines[0].metadataLines = metadata
            }
        }
        return orderedLines
    }

    static func serialize(_ lines: [LyricLine]) -> String {
        let usesSecondaryVoice = lines.contains { $0.voice == .secondary }
        let declaredLanguageCode = lines.lazy
            .compactMap(\.metadataLines)
            .compactMap(LyricManualTranslationPolicy.declaredLanguageCode(in:))
            .first
        let languageAttribute = declaredLanguageCode.map { " xml:lang=\"\($0)\"" } ?? ""
        let agentMetadata = usesSecondaryVoice
            ? """
                <ttm:agent xml:id="v1" type="person"/>
                <ttm:agent xml:id="v2" type="person"/>
              """
            : "    <ttm:agent xml:id=\"v1\" type=\"person\"/>"
        let paragraphs = lines.compactMap { line -> String? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            var attributes: [String] = []
            if line.isSynchronized {
                attributes.append("begin=\"\(formatTimestamp(line.timestamp))\"")
            }
            if let end = line.endTimestamp, end >= line.timestamp {
                attributes.append("end=\"\(formatTimestamp(end))\"")
            }
            let agent = line.voice == .secondary ? "v2" : "v1"
            attributes.append("ttm:agent=\"\(agent)\"")
            if let lineLanguageCode = line.languageCode,
               lineLanguageCode != declaredLanguageCode {
                attributes.append("xml:lang=\"\(lineLanguageCode)\"")
            }
            let attributeText = attributes.isEmpty ? "" : " " + attributes.joined(separator: " ")

            let effectiveLineLanguage = line.languageCode ?? declaredLanguageCode
            if line.isBackingVocal {
                let backing = backgroundSpan(line, parentLanguageCode: effectiveLineLanguage, indent: "        ")
                return "      <p\(attributeText)>\n\(backing)\n      </p>"
            }
            var children = syllableSpans(
                line.syllables,
                lineLanguageCode: effectiveLineLanguage,
                indent: "        "
            )
            children += (line.background ?? []).map { background in
                backgroundSpan(
                    background,
                    parentLanguageCode: effectiveLineLanguage,
                    indent: "        "
                )
            }
            children += translationSpans(
                in: line,
                lineLanguageCode: effectiveLineLanguage,
                indent: "        "
            )
            if let romanizationSpan = romanizationSpan(in: line, indent: "        ") {
                children.append(romanizationSpan)
            }

            guard !children.isEmpty else {
                return "      <p\(attributeText)>\(escapeTTMLText(text))</p>"
            }
            // A line-level row keeps its own text; word-level rows carry it in
            // their syllable spans already.
            let inlineText = line.syllables?.isEmpty == false ? "" : escapeTTMLText(text)
            return """
                  <p\(attributeText)>\(inlineText)
            \(children.joined(separator: "\n"))
                  </p>
            """
        }.joined(separator: "\n")

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata"\(languageAttribute)>
          <head>
            <metadata>
        \(agentMetadata)
            </metadata>
          </head>
          <body>
            <div>
        \(paragraphs)
            </div>
          </body>
        </tt>
        """
    }

    private static func syllableSpans(
        _ syllables: [LyricSyllable]?,
        lineLanguageCode: String?,
        indent: String
    ) -> [String] {
        guard let syllables else { return [] }
        return syllables.map { syllable in
            var attributes = "begin=\"\(formatTimestamp(syllable.start))\""
            if syllable.endTiming == .explicit, syllable.end >= syllable.start {
                attributes += " end=\"\(formatTimestamp(syllable.end))\""
            }
            if let syllableLanguageCode = syllable.languageCode,
               syllableLanguageCode != lineLanguageCode {
                attributes += " xml:lang=\"\(syllableLanguageCode)\""
            }
            return "\(indent)<span \(attributes)>\(escapeTTMLText(syllable.text))</span>"
        }
    }

    private static func annotationContent(_ text: String, syllables: [LyricSyllable]?, languageCode: String?) -> String {
        guard let syllables, !syllables.isEmpty,
              syllables.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == text
        else { return escapeTTMLText(text) }
        return syllableSpans(syllables, lineLanguageCode: languageCode, indent: "").joined()
    }

    private static func translationSpans(
        in line: LyricLine,
        lineLanguageCode: String?,
        indent: String
    ) -> [String] {
        line.allManualTranslations.compactMap { translation in
            let text = translation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var attributes = "ttm:role=\"x-translation\""
            if let languageCode = translation.languageCode,
               languageCode != lineLanguageCode {
                attributes += " xml:lang=\"\(languageCode)\""
            } else if translation.languageCode == nil, lineLanguageCode != nil {
                attributes += " xml:lang=\"\""
            }
            if let last = translation.syllables?.last, last.endTiming == .inferred {
                attributes += " end=\"\(formatTimestamp(last.end))\""
            }
            let content = annotationContent(text, syllables: translation.syllables, languageCode: translation.languageCode)
            return "\(indent)<span \(attributes)>\(content)</span>"
        }
    }

    private static func romanizationSpan(in line: LyricLine, indent: String) -> String? {
        let text = (line.romanization ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let content = annotationContent(text, syllables: line.romanizationSyllables, languageCode: nil)
        let endAttribute = line.romanizationSyllables?.last.flatMap { last in
            last.endTiming == .inferred ? " end=\"\(formatTimestamp(last.end))\"" : nil
        } ?? ""
        return "\(indent)<span ttm:role=\"x-roman\"\(endAttribute)>\(content)</span>"
    }

    /// Backing vocals stay nested in their lead paragraph so a round trip
    /// keeps them off the lead line's own timeline.
    private static func backgroundSpan(
        _ line: LyricLine,
        parentLanguageCode: String?,
        indent: String
    ) -> String {
        var attributes = "ttm:role=\"x-bg\""
        if line.isSynchronized {
            attributes += " begin=\"\(formatTimestamp(line.timestamp))\""
        }
        if let end = line.endTime, end >= line.timestamp {
            attributes += " end=\"\(formatTimestamp(end))\""
        }
        let languageCode = line.languageCode
        if let languageCode, languageCode != parentLanguageCode {
            attributes += " xml:lang=\"\(languageCode)\""
        }

        let childIndent = indent + "  "
        var children = syllableSpans(
            line.syllables,
            lineLanguageCode: languageCode ?? parentLanguageCode,
            indent: childIndent
        )
        children += translationSpans(
            in: line,
            lineLanguageCode: languageCode ?? parentLanguageCode,
            indent: childIndent
        )
        if let romanizationSpan = romanizationSpan(in: line, indent: childIndent) {
            children.append(romanizationSpan)
        }

        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !children.isEmpty else {
            return "\(indent)<span \(attributes)>\(escapeTTMLText(text))</span>"
        }
        let inlineText = line.syllables?.isEmpty == false ? "" : escapeTTMLText(text)
        return """
        \(indent)<span \(attributes)>\(inlineText)
        \(children.joined(separator: "\n"))
        \(indent)</span>
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
        if ignoredDepth > 0 { ignoredDepth += 1; return }
        if insideParagraph && (namespaceURI == "http://www.w3.org/ns/ttml#metadata"
            || ["metadata", "styling", "layout", "set", "animate", "resources", "image", "audio", "data"].contains(name))
            || name == "metadata" && elements.contains(where: { $0.name == "body" }) {
            ignoredDepth = 1
            return
        }
        let languageAttribute = Self.attribute("lang", in: attributeDict)
        // xml:lang="" explicitly clears an inherited language (e.g. an untagged translation).
        let languageCode = languageAttribute == "" ? nil :
            (languageAttribute.flatMap(LyricLanguageCodePolicy.canonicalIdentifier) ?? elements.last?.language)
        elements.append(element(named: name, language: languageCode, attributes: attributeDict))
        switch name {
        case "tt":
            sawTTMLRoot = true
            documentLanguageCode = languageCode
            timing = TimingParameters(attributes: attributeDict)
        case "style" where elements.contains(where: { $0.name == "styling" }):
            if let id = Self.attribute("id", in: attributeDict) {
                rubyStyles[id] = (Self.attribute("ruby", in: attributeDict).flatMap(RubyRole.init(rawValue:)),
                                  Self.styleReferences(in: attributeDict))
            }
        case "p" where !insideParagraph && elements.contains(where: { $0.name == "body" }):
            startParagraph(attributes: attributeDict, languageCode: languageCode)
            currentKey = Self.attribute("key", in: attributeDict)
        case "text" where !insideParagraph:
            let path = elements.suffix(6).map(\.name)
            let kind: AnnotationKind
            switch path {
            case ["head", "metadata", "itunesmetadata", "translations", "translation", "text"]:
                kind = .translation
            case ["head", "metadata", "itunesmetadata", "transliterations", "transliteration", "text"]:
                kind = .romanization
            default:
                return
            }
            guard let key = Self.attribute("for", in: attributeDict), !key.isEmpty else { return }
            startParagraph(attributes: attributeDict, languageCode: languageCode)
            currentKey = key
            currentAnnotationKind = kind
        case "span":
            startSpan(attributes: attributeDict, languageCode: languageCode)
        case "br":
            appendLineBreak()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if ignoredDepth == 0 { appendText(string) }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if ignoredDepth == 0 { appendText(String(decoding: CDATABlock, as: UTF8.self)) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if ignoredDepth > 0 { ignoredDepth -= 1; return }
        if paragraphDepth == elements.count {
            endParagraph()
        } else if elements.last?.name == "span" {
            endSpan()
        }
        let node = elements.removeLast()
        if let end = node.end ?? node.lastChildEnd, !elements.isEmpty {
            let last = elements.count - 1
            elements[last].lastChildEnd = max(elements[last].lastChildEnd ?? end, end)
        }
    }

    private func element(named name: String, language: String?, attributes: [String: String]) -> Element {
        let parent = elements.last
        var node = Element(name: name, language: language, begin: parent?.begin,
                           usesRelativeChildren: parent?.usesRelativeChildren == true)
        guard ["body", "div", "p", "span", "text"].contains(name) else { return node }
        let sequentialParent = parent?.sequential == true
        let reference = sequentialParent ? (parent?.lastChildEnd ?? parent?.begin ?? 0) : (parent?.begin ?? 0)
        // Apple lyric documents use song-absolute cues at every level. Explicit TTML
        // time containers use offsets from their parent or from the preceding sibling.
        let origin = node.usesRelativeChildren ? reference : 0
        let begin = timeAttribute("begin", in: attributes).map { origin + $0 }
        let end = timeAttribute("end", in: attributes).map { origin + $0 }
        let duration = timeAttribute("dur", in: attributes)
        node.startsCue = begin != nil || sequentialParent || end != nil || duration != nil
        node.begin = begin ?? (node.startsCue ? reference : parent?.begin)
        node.end = end
        if let duration {
            let durationEnd = (node.begin ?? 0) + duration
            node.end = min(end ?? durationEnd, durationEnd)
        }
        // A total song duration by itself does not turn static lyrics into timed lyrics.
        if name == "body", begin == nil { node.begin = nil }
        if let container = Self.attribute("timeContainer", in: attributes), container == "seq" || container == "par" {
            node.usesRelativeChildren = true
            node.sequential = container == "seq"
        }
        return node
    }

    private func startParagraph(
        attributes: [String: String],
        languageCode: String?
    ) {
        // Malformed nested paragraphs should not leak the outer state into the
        // inner one. XMLParser will still ultimately report the document error.
        resetParagraph()
        paragraphDepth = elements.count
        let node = elements.last
        currentLineBegin = node?.startsCue == true ? node?.begin : nil
        currentLineEnd = node?.end
        inheritedLineBegin = node?.begin
        if inheritedLineBegin != nil {
            inheritedLineEnd = elements.dropLast().last(where: { $0.name == "div" || $0.name == "body" })?.end
        }
        currentLineLanguageCode = languageCode

        if let agent = Self.attribute("agent", in: attributes)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !agent.isEmpty {
            switch agent.lowercased() {
            case "v1":
                currentLineVoice = .primary
            case "v2":
                currentLineVoice = .secondary
            default:
                if primaryAgent == nil { primaryAgent = agent }
                currentLineVoice = agent == primaryAgent ? .primary : .secondary
            }
        }
    }

    private static func styleReferences(in attributes: [String: String]) -> [String] {
        attribute("style", in: attributes)?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
    }

    private func rubyRole(in attributes: [String: String]) -> RubyRole? {
        if let raw = Self.attribute("ruby", in: attributes), let role = RubyRole(rawValue: raw) { return role }
        guard !rubyStyles.isEmpty else { return nil }
        var references = Self.styleReferences(in: attributes)
        var visited = Set<String>()
        while let id = references.popLast() {
            guard visited.insert(id).inserted, let style = rubyStyles[id] else { continue }
            if let role = style.role { return role }
            references.append(contentsOf: style.references)
        }
        return nil
    }

    private func startSpan(
        attributes: [String: String],
        languageCode: String?
    ) {
        guard insideParagraph else { return }
        if spanStack.isEmpty {
            flushDirectText(beforeSpan: true)
        } else {
            flushPendingSpanText(at: spanStack.count - 1)
        }
        let node = elements.last
        spanStack.append(SpanContext(
            ruby: rubyRole(in: attributes),
            role: Self.attribute("role", in: attributes).flatMap(SpanRole.init(rawValue:)),
            begin: node?.startsCue == true ? node?.begin : nil,
            end: node?.end,
            languageCode: languageCode
        ))
    }

    private func appendText(_ text: String) {
        guard insideParagraph else { return }
        if spanStack.isEmpty {
            currentDirectText += text
        } else {
            spanStack[spanStack.count - 1].pendingText += text
        }
    }

    private func appendLineBreak() {
        guard insideParagraph else { return }
        if spanStack.isEmpty {
            // Discard formatting indentation accumulated before `<br/>`, then
            // attach only the semantic break to the surrounding timed token.
            flushDirectText()
            currentSegments.append(SpanSegment(text: "\n", begin: nil, end: nil))
            if currentSyllables.isEmpty {
                currentUntimedPrefix += "\n"
            } else {
                currentSyllables[currentSyllables.count - 1].text += "\n"
            }
        } else {
            flushPendingSpanText(at: spanStack.count - 1)
            spanStack[spanStack.count - 1].segments.append(SpanSegment(
                text: "\n",
                begin: nil,
                end: nil,
                preservesWhitespace: true,
                languageCode: spanStack.last?.languageCode
            ))
        }
    }

    private func endSpan() {
        guard insideParagraph, !spanStack.isEmpty else { return }
        flushPendingSpanText(at: spanStack.count - 1)
        let span = spanStack.removeLast()
        let segments = span.segments.filter { segment in
            segment.preservesWhitespace
                || !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !segment.text.contains(where: \.isNewline)
        }
        let text = segments.map(\.text).joined()
        guard !text.isEmpty else { return }

        // A timed descendant is the more precise cue. An untimed/style-only
        // subtree inherits the enclosing span's timing as one cue instead.
        var resolvedSegments: [SpanSegment]
        if segments.contains(where: \.isTimed) {
            resolvedSegments = segments.enumerated().map { index, segment in
                guard !segment.isTimed,
                      !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return segment }

                let previousTimed = segments[..<index].last(where: \.isTimed)
                let nextTimed = segments.dropFirst(index + 1).first(where: \.isTimed)
                let begin = previousTimed?.end ?? previousTimed?.begin ?? span.begin
                guard let begin else { return segment }
                return SpanSegment(
                    text: segment.text,
                    begin: begin,
                    end: nextTimed == nil ? span.end : nil,
                    preservesWhitespace: segment.preservesWhitespace,
                    languageCode: segment.languageCode,
                    rubyReading: segment.rubyReading
                )
            }
        } else {
            let effectiveLanguages = Set(segments.map {
                ($0.languageCode ?? span.languageCode) ?? ""
            })
            if effectiveLanguages.count > 1 {
                resolvedSegments = segments.map { segment in
                    SpanSegment(
                        text: segment.text,
                        begin: span.begin,
                        end: span.end,
                        preservesWhitespace: segment.preservesWhitespace,
                        languageCode: segment.languageCode ?? span.languageCode,
                        rubyReading: segment.rubyReading
                    )
                }
            } else {
                let soleLanguage = effectiveLanguages.first.flatMap {
                    $0.isEmpty ? nil : $0
                }
                resolvedSegments = [SpanSegment(
                    text: text,
                    begin: span.begin,
                    end: span.end,
                    preservesWhitespace: segments.contains(where: \.preservesWhitespace),
                    languageCode: soleLanguage,
                    rubyReading: Self.rubySegments(in: segments)
                )]
            }
        }

        if span.ruby == .delimiter { return }
        if span.ruby == .textContainer
            || span.ruby == .text && !spanStack.contains(where: { $0.ruby == .textContainer }) {
            if let base = spanStack.lastIndex(where: { $0.ruby == .container }) {
                // For double-sided ruby the player uses the first reading group.
                if span.ruby == .text || spanStack[base].rubyText.isEmpty {
                    spanStack[base].rubyText.append(contentsOf: resolvedSegments)
                }
                return
            }
        }
        if span.ruby == .container, !span.rubyText.isEmpty {
            if !resolvedSegments.contains(where: \.isTimed),
               let first = span.rubyText.first(where: \.isTimed) {
                // Some files time the pronunciation alone. Its interval also locates the base word.
                resolvedSegments = [SpanSegment(text: text, begin: first.begin,
                    end: span.rubyText.last(where: \.isTimed)?.end, languageCode: span.languageCode)]
            }
            for index in resolvedSegments.indices {
                resolvedSegments[index].rubyReading = index == 0 ? span.rubyText : []
            }
        }

        switch span.role {
        case .romanization, .translation:
            let syllables = timedSyllables(in: resolvedSegments, language: span.languageCode, lineEnd: span.end ?? currentLineEnd)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let backing = spanStack.lastIndex { $0.role == .background }
            if span.role == .romanization {
                let reading = Reading(text: trimmed, syllables: syllables)
                if let backing {
                    spanStack[backing].romanization = spanStack[backing].romanization ?? reading
                } else {
                    currentRomanization = currentRomanization ?? reading
                }
            } else {
                let translation = LyricManualTranslation(
                    text: trimmed, languageCode: span.languageCode, source: .embeddedField, syllables: syllables
                )
                if let backing {
                    spanStack[backing].translations.append(translation)
                } else {
                    currentTranslations.append(translation)
                }
            }
            return
        case .background:
            // Backing vocals run on their own time window and frequently
            // overlap the lead words. Inlining them would make one rendered
            // row sweep backwards, so they become a background sub-line.
            if let background = makeBackgroundLine(from: span, segments: resolvedSegments) {
                currentBackgroundLines.append(background)
            }
            return
        case nil:
            break
        }

        if !spanStack.isEmpty {
            spanStack[spanStack.count - 1].segments.append(contentsOf: resolvedSegments)
            return
        }

        resolvedSegments.forEach(consumeSpanSegment)
    }

    private static func rubySegments(in segments: [SpanSegment]) -> [SpanSegment]? {
        guard segments.contains(where: { $0.rubyReading != nil }) else { return nil }
        return segments.flatMap { segment -> [SpanSegment] in
            guard let reading = segment.rubyReading else { return [segment] }
            guard !reading.isEmpty, !reading.contains(where: \.isTimed), let begin = segment.begin else {
                return reading
            }
            return [SpanSegment(text: reading.map(\.text).joined(), begin: begin, end: segment.end,
                                languageCode: reading.first?.languageCode)]
        }
    }

    private func rubyReading(in segments: [SpanSegment], lineEnd: TimeInterval?) -> Reading? {
        guard let reading = Self.rubySegments(in: segments) else { return nil }
        let text = reading.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return Reading(text: text, syllables: timedSyllables(in: reading, language: nil, lineEnd: lineEnd))
    }

    private func timedSyllables(
        in segments: [SpanSegment], language: String?, lineEnd: TimeInterval?
    ) -> [LyricSyllable]? {
        var syllables: [PendingSyllable] = []
        var untimedPrefix = ""
        for segment in segments where !segment.text.isEmpty {
            guard let begin = segment.begin else {
                if syllables.isEmpty {
                    untimedPrefix += segment.text
                } else {
                    syllables[syllables.count - 1].text += segment.text
                }
                continue
            }
            syllables.append(PendingSyllable(
                text: untimedPrefix + segment.text,
                start: begin,
                explicitEnd: segment.end,
                languageCode: segment.languageCode == language ? nil : segment.languageCode
            ))
            untimedPrefix = ""
        }

        return syllables.isEmpty ? nil : normalizedSyllables(syllables, lineEnd: lineEnd)
    }

    private func makeBackgroundLine(
        from span: SpanContext,
        segments: [SpanSegment]
    ) -> LyricLine? {
        let text = segments.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let languageCode = span.languageCode ?? currentLineLanguageCode
        let syllables = timedSyllables(in: segments, language: languageCode, lineEnd: span.end)
        let reading = span.romanization ?? rubyReading(in: segments, lineEnd: span.end)
        return LyricLine(
            timestamp: span.begin ?? syllables?.first?.start ?? currentLineBegin ?? inheritedLineBegin ?? 0,
            text: text,
            isSynchronized: span.begin != nil || syllables != nil || currentLineBegin != nil || inheritedLineBegin != nil,
            syllables: syllables,
            endTimestamp: span.end ?? syllables?.last?.end ?? currentLineEnd,
            voice: .secondary,
            languageCode: languageCode == documentLanguageCode ? nil : languageCode,
            manualTranslation: span.translations.first,
            alternateManualTranslations: Array(span.translations.dropFirst()),
            romanization: reading?.text,
            romanizationSyllables: reading?.syllables,
            isBackingVocal: true
        )
    }

    private static func attach(_ annotation: HeadAnnotation, to line: inout LyricLine) {
        annotation.kind.attach(annotation.line, language: annotation.languageCode, to: &line)
        guard var backing = line.background, let tracks = annotation.line.background else { return }
        var assigned = Set<Int>()
        for (position, track) in tracks.enumerated() {
            let matchingStart = backing.indices.first {
                !assigned.contains($0) && backing[$0].isSynchronized && track.isSynchronized
                    && abs(backing[$0].timestamp - track.timestamp) < 0.002
            }
            let index = matchingStart ?? (tracks.count == backing.count && !assigned.contains(position) ? position : nil)
            guard let index else { continue }
            annotation.kind.attach(track, language: annotation.languageCode, to: &backing[index])
            assigned.insert(index)
        }
        line.background = backing
    }

    private func flushPendingSpanText(at index: Int) {
        guard spanStack.indices.contains(index),
              !spanStack[index].pendingText.isEmpty else { return }
        let text = removingTrailingFormattingIndentation(
            from: spanStack[index].pendingText
        )
        spanStack[index].pendingText = ""
        guard !text.isEmpty else { return }
        spanStack[index].segments.append(SpanSegment(
            text: text,
            begin: nil,
            end: nil,
            languageCode: spanStack[index].languageCode
        ))
    }

    private func consumeSpanSegment(_ segment: SpanSegment) {
        currentSegments.append(segment)
        if let begin = segment.begin, !segment.text.isEmpty {
            currentSyllables.append(PendingSyllable(
                text: currentUntimedPrefix + segment.text,
                start: begin,
                explicitEnd: segment.end,
                languageCode: segment.languageCode == currentLineLanguageCode
                    ? nil
                    : segment.languageCode
            ))
            currentUntimedPrefix = ""
        } else if !segment.text.isEmpty {
            if currentSyllables.isEmpty {
                currentUntimedPrefix += segment.text
            } else {
                currentSyllables[currentSyllables.count - 1].text += segment.text
            }
        }
    }

    private func endParagraph() {
        guard insideParagraph else { return }

        // A valid document cannot leave spans open here, but clearing them
        // keeps a partially parsed malformed document from contaminating later
        // delegate callbacks before XMLParser reports failure.
        spanStack.removeAll(keepingCapacity: true)
        flushDirectText()

        let text = currentSegments.map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty || !currentBackgroundLines.isEmpty {
            let syllables = normalizedSyllables(currentSyllables, lineEnd: currentLineEnd)
            let timestamp = currentLineBegin ?? syllables.first?.start ?? inheritedLineBegin ?? 0
            let reading = currentRomanization ?? rubyReading(in: currentSegments, lineEnd: currentLineEnd)
            var line = LyricLine(
                timestamp: timestamp,
                text: text,
                isSynchronized: inheritedLineBegin != nil || !syllables.isEmpty,
                syllables: syllables.isEmpty ? nil : syllables,
                endTimestamp: currentLineEnd ?? (currentLineBegin == nil && syllables.isEmpty ? inheritedLineEnd : nil),
                voice: currentLineVoice,
                background: currentBackgroundLines.isEmpty ? nil : currentBackgroundLines,
                languageCode: currentLineLanguageCode == documentLanguageCode
                    ? nil
                    : currentLineLanguageCode,
                manualTranslation: currentTranslations.first,
                alternateManualTranslations: Array(currentTranslations.dropFirst()),
                romanization: reading?.text,
                romanizationSyllables: reading?.syllables
            )
            if let kind = currentAnnotationKind, let key = currentKey {
                annotationsByKey[key, default: []].append(HeadAnnotation(
                    kind: kind, languageCode: currentLineLanguageCode, line: line
                ))
            } else {
                for annotation in currentKey.flatMap({ annotationsByKey[$0] }) ?? [] {
                    Self.attach(annotation, to: &line)
                }
                // A paragraph containing only backing vocals retains each secondary row.
                let rows = text.isEmpty ? line.background ?? [] : [line]
                for row in rows {
                    parsedLines.append((order: nextLineOrder, line: row))
                    nextLineOrder += 1
                }
            }
        }

        resetParagraph()
    }

    private func flushDirectText(beforeSpan: Bool = false) {
        guard !currentDirectText.isEmpty else { return }
        let text: String
        if currentAnnotationKind == .romanization, beforeSpan, !currentSyllables.isEmpty,
           currentDirectText.allSatisfy(\.isWhitespace), currentDirectText.contains(where: \.isNewline) {
            // Some Apple Latin-script tracks separate words with an indented XML newline.
            text = " "
        } else {
            text = removingTrailingFormattingIndentation(from: currentDirectText)
        }
        currentDirectText = ""
        guard !text.isEmpty else { return }

        // Pretty-printed TTML places indentation between timed spans. It is
        // markup whitespace rather than lyric content and must not be inserted
        // between words. Meaningful mixed text is kept verbatim.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           text.contains(where: { $0.isNewline }) {
            return
        }
        currentSegments.append(SpanSegment(text: text, begin: nil, end: nil))
        if currentSyllables.isEmpty {
            currentUntimedPrefix += text
        } else {
            currentSyllables[currentSyllables.count - 1].text += text
        }
    }

    private func removingTrailingFormattingIndentation(from text: String) -> String {
        guard let newline = text.lastIndex(where: \.isNewline),
              text[newline...].allSatisfy(\.isWhitespace) else { return text }
        return String(text[..<newline])
    }

    private func resetParagraph() {
        paragraphDepth = nil
        currentKey = nil
        currentAnnotationKind = nil
        currentLineBegin = nil
        currentLineEnd = nil
        inheritedLineBegin = nil
        inheritedLineEnd = nil
        currentLineVoice = .primary
        currentLineLanguageCode = nil
        currentSegments.removeAll(keepingCapacity: true)
        currentDirectText = ""
        currentUntimedPrefix = ""
        currentSyllables.removeAll(keepingCapacity: true)
        currentTranslations.removeAll(keepingCapacity: true)
        currentRomanization = nil
        currentBackgroundLines.removeAll(keepingCapacity: true)
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
            let validExplicitEnd = syllable.explicitEnd.flatMap {
                $0 >= syllable.start ? $0 : nil
            }
            let inferredEnd = [validExplicitEnd, nextStart, lineEnd]
                .compactMap { $0 }
                .first { $0 >= syllable.start }
                ?? (syllable.start + 0.4)
            return LyricSyllable(
                text: syllable.text,
                start: syllable.start,
                end: inferredEnd,
                endTiming: validExplicitEnd != nil
                    ? .explicit
                    : .inferred,
                languageCode: syllable.languageCode
            )
        }
    }

    private func timeAttribute(
        _ name: String,
        in attributes: [String: String]
    ) -> TimeInterval? {
        Self.attribute(name, in: attributes).flatMap(parseTimestamp)
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

    private struct TimingParameters {
        let nominalFrames: Double
        let frames: Double
        let subframes: Double
        let ticks: Double

        init(attributes: [String: String] = [:]) {
            func positive(_ key: String) -> Double? {
                guard let value = TTMLLyricsParser.attribute(key, in: attributes).flatMap(Int.init), value > 0 else { return nil }
                return Double(value)
            }
            let specifiedFrames = positive("frameRate")
            nominalFrames = specifiedFrames ?? 30
            subframes = positive("subFrameRate") ?? 1
            let multiplier = TTMLLyricsParser.attribute("frameRateMultiplier", in: attributes)?
                .split(whereSeparator: \.isWhitespace)
            if let multiplier, multiplier.count == 2,
               let numerator = Int(multiplier[0]), numerator > 0,
               let denominator = Int(multiplier[1]), denominator > 0 {
                frames = nominalFrames * Double(numerator) / Double(denominator)
            } else {
                frames = nominalFrames
            }
            let defaultTicks = specifiedFrames != nil ? frames * subframes : 1
            ticks = positive("tickRate") ?? defaultTicks
        }
    }

    private func parseTimestamp(_ rawValue: String) -> TimeInterval? {
        let value = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty else { return nil }

        let units: [(suffix: String, multiplier: Double)] = [
            ("ms", 0.001),
            ("h", 3_600),
            ("m", 60),
            ("s", 1),
            ("f", 1 / timing.frames),
            ("t", 1 / timing.ticks),
        ]
        for unit in units where value.hasSuffix(unit.suffix) {
            guard let amount = Double(value.dropLast(unit.suffix.count)) else { return nil }
            return Self.validatedTime(amount * unit.multiplier)
        }

        let components = value
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":", omittingEmptySubsequences: false)
        if components.count == 4 {
            let frameParts = components[3].split(separator: ".", omittingEmptySubsequences: false)
            guard let hours = Int(components[0]), hours >= 0,
                  let mins = Int(components[1]), (0..<60).contains(mins),
                  let secs = Int(components[2]), (0..<60).contains(secs),
                  (1...2).contains(frameParts.count),
                  let frame = Int(frameParts[0]), (0..<timing.nominalFrames).contains(Double(frame)) else { return nil }
            let subframe = frameParts.count == 2 ? Int(frameParts[1]) : 0
            guard let subframe, (0..<timing.subframes).contains(Double(subframe)) else { return nil }
            let seconds = Double(hours) * 3600 + Double(mins * 60 + secs)
            return Self.validatedTime(seconds + (Double(frame) + Double(subframe) / timing.subframes) / timing.frames)
        }
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
        return Self.validatedTime(result)
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

    private static func escapeTTMLText(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { escapeXML(String($0)) }
            .joined(separator: "<br/>")
    }
}
