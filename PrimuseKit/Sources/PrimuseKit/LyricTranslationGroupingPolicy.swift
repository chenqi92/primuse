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
        guard let detectedIdentity else { return fallbackIdentity }
        guard let fallbackIdentity, detectedIdentity != fallbackIdentity else {
            return detectedIdentity
        }

        if textHasScriptEvidence(for: fallbackIdentity, text: text) {
            return fallbackIdentity
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
}
