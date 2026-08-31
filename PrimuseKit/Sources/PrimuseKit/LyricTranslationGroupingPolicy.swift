import Foundation

public struct LyricTranslationCandidate: Equatable, Sendable {
    public let id: String
    public let text: String
    public let sourceLanguageCode: String?

    public init(id: String, text: String, sourceLanguageCode: String?) {
        self.id = id
        self.text = text
        self.sourceLanguageCode = sourceLanguageCode
    }
}

public struct LyricTranslationGroup: Equatable, Sendable {
    public let id: String
    public let sourceLanguageCode: String?
    public let candidates: [LyricTranslationCandidate]

    public init(
        id: String,
        sourceLanguageCode: String?,
        candidates: [LyricTranslationCandidate]
    ) {
        self.id = id
        self.sourceLanguageCode = sourceLanguageCode
        self.candidates = candidates
    }
}

/// One-shot authorization for starting system UI that may prepare or download a
/// Translation language pair. The authorization is intentionally process-local:
/// persisted translation settings must never recreate a system prompt after an
/// app launch or view remount.
public struct LyricTranslationPreparationRequestGate: Sendable {
    public private(set) var revision: UInt = 0
    private var issuedAt: Date?
    private var consumedRevision: UInt = 0

    public init() {}

    @discardableResult
    public mutating func issue(at date: Date = Date()) -> UInt {
        revision &+= 1
        if revision == 0 {
            revision = 1
            consumedRevision = 0
        }
        issuedAt = date
        return revision
    }

    public mutating func consume(
        revision requestedRevision: UInt,
        at date: Date = Date(),
        maximumAge: TimeInterval = 30
    ) -> Bool {
        guard requestedRevision != 0,
              requestedRevision == revision,
              requestedRevision != consumedRevision,
              let issuedAt else {
            return false
        }
        consumedRevision = requestedRevision
        guard date.timeIntervalSince(issuedAt) >= 0,
              date.timeIntervalSince(issuedAt) <= maximumAge else {
            return false
        }
        return true
    }

    public mutating func invalidate() {
        consumedRevision = revision
        issuedAt = nil
    }
}

/// Produces one Translation batch per source language. Apple Translation
/// requires every request in a batch to use the same source language, while a
/// line whose language cannot be identified safely follows the language of the
/// surrounding lyrics when one is available. Remaining unknown lines share one
/// auto-detected session so they cannot trigger a separate system prompt per
/// short line.
public enum LyricTranslationGroupingPolicy {
    private static let availableLanguageCodes: Set<String> = Set(
        Locale.availableIdentifiers.compactMap {
            Locale.Language(identifier: $0).languageCode?.identifier.lowercased()
        }
    )

    /// Words that provide useful Persian evidence even when a file was written
    /// with Arabic Yeh/Kaf instead of their Persian code points. Requiring more
    /// than one marker for an untagged document avoids treating an isolated
    /// shared Arabic-script word as Persian.
    private static let persianLexicalMarkers: Set<String> = [
        "اگر", "است", "این", "برای", "بود", "باشد", "ترانه", "دارم",
        "دارد", "داری", "دوست", "شده", "فارسی", "من", "نیست", "نوشته",
        "همیشه", "هست", "یک",
    ]

    /// Reconciles a per-line NaturalLanguage result with the language detected
    /// from the complete lyric body. Short metadata lines frequently combine a
    /// local-script label with a Latin name (for example a composer credit),
    /// which can otherwise be classified as an unrelated language.
    public static func reconciledLineLanguageCode(
        text: String,
        detectedLanguageCode: String?,
        confidence: Double,
        alternativeConfidence: Double = 0,
        fallbackSourceLanguageCode: String?
    ) -> String? {
        let detectedIdentity = detectedLanguageCode.map(languageIdentity)
        let fallbackIdentity = fallbackSourceLanguageCode.map(languageIdentity)
        if let corrected = correctedPersianLanguageCode(
            text: text,
            detectedLanguageCode: detectedIdentity,
            fallbackSourceLanguageCode: fallbackIdentity
        ) {
            return corrected
        }
        guard let detectedIdentity else { return fallbackIdentity }
        guard let fallbackIdentity, detectedIdentity != fallbackIdentity else {
            return detectedIdentity
        }

        if textHasScriptEvidence(for: fallbackIdentity, text: text) {
            return fallbackIdentity
        }

        if lineWritingDirectionMatchesDetectedLanguage(
            text: text,
            detectedLanguageCode: detectedIdentity,
            fallbackLanguageCode: fallbackIdentity
        ) {
            return detectedIdentity
        }

        let letterCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) { count += 1 }
        }
        let confidenceMargin = confidence - alternativeConfidence
        if letterCount < 12, (confidence < 0.80 || confidenceMargin < 0.25) {
            return fallbackIdentity
        }
        return detectedIdentity
    }

    /// Corrects NaturalLanguage's common Persian-as-Arabic result only when the
    /// text carries additional Persian orthographic or lexical evidence. Plain
    /// Arabic remains Arabic, including Arabic text typed with Persian Yeh/Kaf.
    /// A detected Persian document fallback lowers the evidence threshold. An
    /// explicit `[la:fa]` declaration also resolves shared Arabic-script words,
    /// while opposite-script lines keep their own detected language.
    public static func correctedPersianLanguageCode(
        text: String,
        detectedLanguageCode: String?,
        fallbackSourceLanguageCode: String? = nil,
        declaredSourceLanguageCode: String? = nil
    ) -> String? {
        let detectedIdentity = detectedLanguageCode.map(languageIdentity)
        let fallbackIdentity = fallbackSourceLanguageCode.map(languageIdentity)
        let declaredIdentity = declaredSourceLanguageCode.map(languageIdentity)
        let detectedPrimary = detectedIdentity.map(primaryLanguageCode)
        let fallbackIsPersianArabic = isPersianArabicScript(fallbackIdentity)
        let declaredIsPersianArabic = isPersianArabicScript(declaredIdentity)
        guard detectedPrimary == "ar"
                || fallbackIsPersianArabic
                || declaredIsPersianArabic else {
            return nil
        }

        let evidence = persianOrthographyEvidence(in: text)
        guard evidence.arabicScriptLetterCount > 0 else { return nil }

        if declaredIsPersianArabic,
           detectedPrimary == "ar" || detectedPrimary == "ur" || detectedPrimary == "fa" {
            return declaredIdentity
        }

        if fallbackIsPersianArabic, evidence.supportsPersianFallback {
            return fallbackIdentity
        }
        guard detectedPrimary == "ar", evidence.isStrong else { return nil }
        return "fa"
    }

    /// Returns a normalized language identity from an LRC/ELRC `[la:...]`
    /// metadata line. Unknown and malformed tags are ignored so untrusted lyric
    /// metadata cannot force Translation to construct an invalid language pair.
    public static func declaredLanguageCode(in metadataLines: [String]) -> String? {
        for metadataLine in metadataLines {
            let trimmed = metadataLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { continue }

            let body = trimmed.dropFirst().dropLast()
            guard let separator = body.firstIndex(of: ":") else { continue }
            let key = body[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.caseInsensitiveCompare("la") == .orderedSame else { continue }

            let value = body[body.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let normalized = normalizedLanguageTag(value) else { continue }
            let primary = normalized.split(separator: "-", maxSplits: 1)
                .first
                .map(String.init)
            guard let primary, availableLanguageCodes.contains(primary) else { continue }
            return languageIdentity(normalized)
        }
        return nil
    }

    /// Unknown whole-lyric languages should still be attempted, but a confident
    /// match with the target language is a no-op and must not start Translation.
    public static func needsTranslation(
        detectedSourceLanguageCode: String?,
        targetLanguageCode: String
    ) -> Bool {
        guard let detectedSourceLanguageCode else { return true }
        return languageIdentity(detectedSourceLanguageCode)
            != languageIdentity(targetLanguageCode)
    }

    public static func groups(
        candidates: [LyricTranslationCandidate],
        targetLanguageCode: String,
        fallbackSourceLanguageCode: String? = nil
    ) -> [LyricTranslationGroup] {
        let targetIdentity = languageIdentity(targetLanguageCode)
        let fallbackSourceIdentity = fallbackSourceLanguageCode.map(languageIdentity)
        var orderedKeys: [String] = []
        var groupsByKey: [String: [LyricTranslationCandidate]] = [:]
        var sourceByKey: [String: String?] = [:]

        for candidate in candidates {
            let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let normalizedSource = candidate.sourceLanguageCode.map(languageIdentity)
                ?? fallbackSourceIdentity
            if let normalizedSource, normalizedSource == targetIdentity {
                continue
            }

            let key = normalizedSource ?? "auto"
            if groupsByKey[key] == nil {
                orderedKeys.append(key)
                sourceByKey[key] = normalizedSource
            }
            groupsByKey[key, default: []].append(
                LyricTranslationCandidate(
                    id: candidate.id,
                    text: text,
                    sourceLanguageCode: normalizedSource
                )
            )
        }

        return orderedKeys.compactMap { key in
            guard let groupedCandidates = groupsByKey[key], !groupedCandidates.isEmpty else {
                return nil
            }
            return LyricTranslationGroup(
                id: key,
                sourceLanguageCode: sourceByKey[key] ?? nil,
                candidates: groupedCandidates
            )
        }
    }

    /// Automatic playback may only use a known, already-installed language pair.
    /// A supported-but-not-installed pair and an unknown source language both
    /// require a separate, explicit user request before a Translation session is
    /// created, because either case may present system UI.
    public static func automaticSessionGroups(
        installed: [LyricTranslationGroup]
    ) -> [LyricTranslationGroup] {
        installed.filter { $0.sourceLanguageCode != nil }
    }

    /// An explicit user action may prepare one language pair at a time. Choosing
    /// only the largest group prevents one tap from cascading through multiple
    /// system download or source-language sheets.
    public static func explicitlyRequestedSessionGroup(
        preparationRequired: [LyricTranslationGroup]
    ) -> LyricTranslationGroup? {
        preparationRequired.max { lhs, rhs in
            lhs.candidates.count < rhs.candidates.count
        }
    }

    public static func languageIdentity(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map(String.init)
        guard let primary = parts.first?.lowercased(), !primary.isEmpty else {
            return normalized.lowercased()
        }

        if primary == "zh" {
            let lower = normalized.lowercased()
            if lower.contains("hant") || lower.contains("-tw")
                || lower.contains("-hk") || lower.contains("-mo") {
                return "zh-Hant"
            }
            if lower.contains("hans") || lower.contains("-cn")
                || lower.contains("-sg") {
                return "zh-Hans"
            }
            return "zh"
        }

        if parts.count >= 2, parts[1].count == 4 {
            let script = parts[1].prefix(1).uppercased() + parts[1].dropFirst().lowercased()
            return "\(primary)-\(script)"
        }
        return primary
    }

    private struct PersianOrthographyEvidence {
        var arabicScriptLetterCount = 0
        var distinctiveLetterCount = 0
        var persianVariantLetterCount = 0
        var lexicalMarkerCount = 0
        var hasZeroWidthNonJoiner = false

        var isStrong: Bool {
            lexicalMarkerCount >= 2
                || distinctiveLetterCount >= 2
                || (distinctiveLetterCount >= 1 && lexicalMarkerCount >= 1)
                || (persianVariantLetterCount >= 2 && lexicalMarkerCount >= 1)
                || (hasZeroWidthNonJoiner && lexicalMarkerCount >= 1)
        }

        var supportsPersianFallback: Bool {
            lexicalMarkerCount >= 1
                || distinctiveLetterCount >= 1
                || persianVariantLetterCount >= 3
                || hasZeroWidthNonJoiner
        }

    }

    private static func persianOrthographyEvidence(
        in text: String
    ) -> PersianOrthographyEvidence {
        var evidence = PersianOrthographyEvidence()
        var normalized = ""

        for scalar in text.unicodeScalars {
            if CharacterSet.nonBaseCharacters.contains(scalar) { continue }

            switch scalar.value {
            case 0x067E, 0x0686, 0x0698, 0x06AF: // Peh, Tcheh, Jeh, Gaf
                evidence.distinctiveLetterCount += 1
            case 0x06A9, 0x06CC: // Keheh and Farsi Yeh
                evidence.persianVariantLetterCount += 1
            case 0x200C:
                evidence.hasZeroWidthNonJoiner = true
            default:
                break
            }

            if scalar.properties.isAlphabetic,
               isArabicScriptScalar(scalar.value) {
                evidence.arabicScriptLetterCount += 1
            }

            switch scalar.value {
            case 0x0643: // Arabic Kaf -> Keheh
                normalized.unicodeScalars.append(UnicodeScalar(0x06A9)!)
            case 0x0649, 0x064A: // Alef Maksura / Arabic Yeh -> Farsi Yeh
                normalized.unicodeScalars.append(UnicodeScalar(0x06CC)!)
            case 0x200C:
                normalized.append(" ")
            default:
                normalized.unicodeScalars.append(scalar)
            }
        }

        let tokens = normalized.components(separatedBy: CharacterSet.letters.inverted)
        evidence.lexicalMarkerCount = tokens.reduce(into: 0) { count, token in
            if persianLexicalMarkers.contains(token) { count += 1 }
        }
        return evidence
    }

    private static func isArabicScriptScalar(_ value: UInt32) -> Bool {
        switch value {
        case 0x0600...0x06FF,
             0x0750...0x077F,
             0x0870...0x089F,
             0x08A0...0x08FF,
             0xFB50...0xFDFF,
             0xFE70...0xFEFF:
            return true
        default:
            return false
        }
    }

    private static func normalizedLanguageTag(_ raw: String) -> String? {
        let normalized = raw
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
              }) else {
            return nil
        }
        return normalized
    }

    private static func primaryLanguageCode(_ identity: String) -> String {
        identity.split(separator: "-", maxSplits: 1).first.map(String.init) ?? identity
    }

    private static func isPersianArabicScript(_ identity: String?) -> Bool {
        guard let identity, primaryLanguageCode(identity) == "fa" else { return false }
        return !identity.lowercased().contains("-latn")
    }

    private static func textHasScriptEvidence(for languageCode: String, text: String) -> Bool {
        let primaryLanguage = languageIdentity(languageCode)
            .split(separator: "-")
            .first
            .map(String.init)
        var hanCount = 0
        var containsKana = false
        var containsHangul = false

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                hanCount += 1
            case 0x3040...0x30FF, 0x31F0...0x31FF:
                containsKana = true
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF:
                containsHangul = true
            default:
                break
            }
        }

        switch primaryLanguage {
        case "zh":
            return hanCount >= 2 && !containsKana
        case "ja":
            return containsKana
        case "ko":
            return containsHangul
        default:
            return false
        }
    }

    private static func lineWritingDirectionMatchesDetectedLanguage(
        text: String,
        detectedLanguageCode: String,
        fallbackLanguageCode: String
    ) -> Bool {
        let detectedDirection = LyricWritingDirectionPolicy.resolve(
            languageTag: detectedLanguageCode
        )
        let fallbackDirection = LyricWritingDirectionPolicy.resolve(
            languageTag: fallbackLanguageCode
        )
        guard detectedDirection != .natural,
              fallbackDirection != .natural,
              detectedDirection != fallbackDirection else {
            return false
        }
        return LyricWritingDirectionPolicy.resolvePresentationDirection(for: text)
            == detectedDirection
    }
}
