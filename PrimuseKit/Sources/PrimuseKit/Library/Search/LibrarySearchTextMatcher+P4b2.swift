import Foundation

// 资料库搜索的文本匹配(原 App 里 `MusicLibrary.swift` 顶部的 `LibrarySearchMatcher` 与
// `LibrarySearchMatchKind`,原样搬进 Kit):专辑、艺人的预处理文本存进搜索库后,打分要与 App
// 用同一份规则,也要能在 Kit 测试里比对。

public enum LibrarySearchMatchKind: CaseIterable, Sendable {
    case metadata
    case path
    case lyrics
    case fuzzy

    public static let all = Set(allCases)
}

public struct LibrarySearchTextMatcher: Sendable {
    public let rawQuery: String
    public let normalizedQuery: String
    private let shouldTransliterateCandidates: Bool

    public var isValid: Bool { !normalizedQuery.isEmpty }
    public var normalizedLength: Int { normalizedQuery.count }
    public var requiresPinyinCandidates: Bool { shouldTransliterateCandidates }

    public init(query: String) {
        rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // A Han query can be matched in its original script. Transliteration
        // is only useful when the user typed Latin pinyin/initials; avoiding it
        // for normal Chinese queries prevents thousands of unnecessary ICU
        // transforms in a large library.
        shouldTransliterateCandidates = !Self.containsHan(rawQuery)
        normalizedQuery = Self.normalized(rawQuery, transliterateHan: false)
    }

    public func score(candidate: String) -> (score: Int, kind: LibrarySearchMatchKind)? {
        guard !candidate.isEmpty else { return nil }

        if candidate.localizedCaseInsensitiveContains(rawQuery) {
            return (120, .metadata)
        }
        guard isValid else { return nil }

        let normalizedCandidate = Self.normalized(
            candidate,
            transliterateHan: shouldTransliterateCandidates
        )
        guard !normalizedCandidate.isEmpty else { return nil }

        if normalizedCandidate.contains(normalizedQuery) {
            return (110, .metadata)
        }

        if shouldTransliterateCandidates {
            let initials = Self.initials(candidate)
            if !initials.isEmpty, initials.contains(normalizedQuery) {
                return (100, .metadata)
            }
        }

        if normalizedQuery.count >= 3,
           Self.isSubsequence(normalizedQuery, of: normalizedCandidate) {
            return (55, .fuzzy)
        }

        return nil
    }

    public struct PreparedText: Sendable, Equatable {
        public let raw: String
        public let original: String
        public let latin: String
        public let initials: String
        public let semantic: String
        public let includesPinyin: Bool

        /// 从存下的各列还原(搜索库里的专辑、艺人文本)。
        public init(raw: String, original: String, latin: String, initials: String, semantic: String, includesPinyin: Bool) {
            self.raw = raw
            self.original = original
            self.latin = latin
            self.initials = initials
            self.semantic = semantic
            self.includesPinyin = includesPinyin
        }

        public init(_ text: String, includesPinyin: Bool = true) {
            raw = text
            original = LibrarySearchTextMatcher.normalized(text, transliterateHan: false)
            semantic = ListeningSpaceSearchPolicy.normalized(text)
            self.includesPinyin = includesPinyin
            if includesPinyin {
                let transliterated = LibrarySearchTextMatcher.containsHan(text)
                    ? (text.applyingTransform(.mandarinToLatin, reverse: false)?
                        .applyingTransform(.stripDiacritics, reverse: false) ?? text)
                    : text
                latin = LibrarySearchTextMatcher.normalized(transliterated, transliterateHan: false)
                initials = LibrarySearchTextMatcher.initials(transliterated)
            } else {
                latin = original
                initials = ""
            }
        }

        public var characters: Set<Unicode.Scalar> {
            Set((original + latin + initials + semantic).unicodeScalars)
        }
    }

    public func score(prepared: PreparedText) -> Int? {
        if prepared.raw.localizedCaseInsensitiveContains(rawQuery) { return 120 }
        let candidate = shouldTransliterateCandidates ? prepared.latin : prepared.original
        guard !candidate.isEmpty else { return nil }
        if candidate.contains(normalizedQuery) { return 110 }
        if shouldTransliterateCandidates, prepared.initials.contains(normalizedQuery) { return 100 }
        if normalizedLength >= 3, Self.isSubsequence(normalizedQuery, of: candidate) { return 55 }
        return nil
    }

    public func lyricsMatch(in lines: [LyricLine], contextLines: Int = 1) -> (snippet: String, timestamp: TimeInterval)? {
        let indexedLines = lines
            .enumerated()
            .map { (offset: $0.offset, line: $0.element, text: $0.element.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }
        guard !indexedLines.isEmpty else { return nil }

        var matchPosition: Int?
        for (index, item) in indexedLines.enumerated() {
            guard !Task.isCancelled else { return nil }
            if lyricsContainQuery(item.text) {
                matchPosition = index
                break
            }
        }

        guard let matchPosition else { return nil }
        let lowerBound = max(0, matchPosition - contextLines)
        let upperBound = min(indexedLines.count - 1, matchPosition + contextLines)
        var snippetLines = Array(indexedLines[lowerBound...upperBound].map(\.text))
        if lowerBound > 0 { snippetLines[0] = "..." + snippetLines[0] }
        if upperBound < indexedLines.count - 1 {
            snippetLines[snippetLines.count - 1] += "..."
        }
        return (snippetLines.joined(separator: "\n"), indexedLines[matchPosition].line.timestamp)
    }

    public func lyricsContainQuery(_ text: String) -> Bool {
        guard !rawQuery.isEmpty else { return false }
        // Lyrics search is literal full-text search. Pinyin matching remains
        // available for title/artist/album metadata, but transliterating every
        // lyric line is prohibitively expensive and was the source of a
        // MetricKit CPU exception on a 5K-file lyrics library.
        return text.range(
            of: rawQuery,
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        ) != nil
    }

    private static func normalized(_ text: String, transliterateHan: Bool) -> String {
        let latin: String
        if text.unicodeScalars.allSatisfy(\.isASCII) {
            latin = text.lowercased()
        } else if transliterateHan, containsHan(text) {
            latin = text
                .applyingTransform(.mandarinToLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false)
                ?? text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        } else {
            latin = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        }

        let allowed = CharacterSet.alphanumerics
        let scalars = latin.lowercased().unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func initials(_ text: String) -> String {
        let latin: String
        if containsHan(text) {
            latin = text
                .applyingTransform(.mandarinToLatin, reverse: false)?
                .applyingTransform(.stripDiacritics, reverse: false)
                ?? text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        } else {
            latin = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        }

        let allowed = CharacterSet.alphanumerics
        var result = String.UnicodeScalarView()
        var shouldTakeNext = true
        for scalar in latin.lowercased().unicodeScalars {
            if allowed.contains(scalar) {
                if shouldTakeNext {
                    result.append(scalar)
                    shouldTakeNext = false
                }
            } else {
                shouldTakeNext = true
            }
        }
        return String(result)
    }

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF,
                 0x4E00...0x9FFF,
                 0xF900...0xFAFF,
                 0x20000...0x2FA1F:
                return true
            default:
                return false
            }
        }
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = needle[...]
        for char in haystack {
            if remaining.first == char {
                remaining.removeFirst()
                if remaining.isEmpty { return true }
            }
        }
        return remaining.isEmpty
    }
}
