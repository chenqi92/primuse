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

    /// Automatic playback may translate every already-installed language pair,
    /// but it should request at most one new language download at a time. A
    /// noisy per-line language classification must never fan out into a series
    /// of system sheets. Prefer the downloadable group covering the most lines,
    /// and only prompt when it represents a meaningful share of the lyric body.
    public static func automaticSessionGroups(
        installed: [LyricTranslationGroup],
        downloadable: [LyricTranslationGroup],
        totalCandidateCount: Int? = nil
    ) -> [LyricTranslationGroup] {
        guard var primaryDownload = downloadable.first else { return installed }
        for group in downloadable.dropFirst()
            where group.candidates.count > primaryDownload.candidates.count {
            primaryDownload = group
        }
        let groupedCount = (installed + downloadable)
            .reduce(into: 0) { $0 += $1.candidates.count }
        let totalCount = max(totalCandidateCount ?? groupedCount, 1)
        guard primaryDownload.candidates.count * 5 >= totalCount else {
            return installed
        }
        return installed + [primaryDownload]
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
