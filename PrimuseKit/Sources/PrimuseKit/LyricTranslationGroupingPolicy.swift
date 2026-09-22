import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

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

public enum LyricTranslationTerminalState: Equatable, Sendable {
    case notNeeded
    case ready
    case preparationRequired
    case unavailable
}

/// Reduces Translation availability evidence to a UI-independent terminal
/// state. Unknown SDK cases and lookup errors remain recoverable preparation
/// states; `unavailable` is reserved for an explicitly unsupported pair.
public enum LyricTranslationTerminalPolicy {
    public static func resolve(
        pendingCandidateCount: Int,
        availableGroupCount: Int,
        preparationRequiredGroupCount: Int,
        unsupportedCandidateCount: Int,
        encounteredUnknownStatus: Bool = false,
        encounteredError: Bool = false
    ) -> LyricTranslationTerminalState {
        guard pendingCandidateCount > 0 else { return .notNeeded }
        if availableGroupCount > 0 { return .ready }
        if preparationRequiredGroupCount > 0
            || encounteredUnknownStatus
            || encounteredError {
            return .preparationRequired
        }
        if unsupportedCandidateCount >= pendingCandidateCount { return .unavailable }
        return .preparationRequired
    }

    /// Badge state after every currently runnable group finishes. This keeps a
    /// mixed document honest: supported rows may complete first, while any
    /// remaining explicitly unsupported pair is still surfaced afterwards.
    public static func remainingStateAfterAvailableWork(
        preparationRequiredCandidateCount: Int,
        unsupportedCandidateCount: Int,
        encounteredUnknownStatus: Bool = false,
        encounteredError: Bool = false
    ) -> LyricTranslationTerminalState {
        if preparationRequiredCandidateCount > 0
            || encounteredUnknownStatus
            || encounteredError {
            return .preparationRequired
        }
        if unsupportedCandidateCount > 0 { return .unavailable }
        return .notNeeded
    }
}

/// Canonicalizes trusted and container-provided language tags before they are
/// compared or passed to Translation. Foundation handles modern ISO 639 codes;
/// the alias table covers legacy bibliographic codes still common in ID3 tags.
public enum LyricLanguageCodePolicy {
    private static let bibliographicAliases: [String: String] = [
        "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my",
        "chi": "zh", "cze": "cs", "dut": "nl", "fre": "fr",
        "geo": "ka", "ger": "de", "gre": "el", "ice": "is",
        "mac": "mk", "mao": "mi", "may": "ms", "per": "fa",
        "rum": "ro", "slo": "sk", "tib": "bo", "wel": "cy",
    ]
    private static let availableLanguageCodes: Set<String> = Set(
        Locale.availableIdentifiers.compactMap {
            Locale.Language(identifier: $0).languageCode?.identifier.lowercased()
        }
    )

    public static func canonicalIdentifier(_ raw: String) -> String? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }

        var subtags = normalized.split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        guard let primary = subtags.first?.lowercased(),
              (2...3).contains(primary.count),
              primary.unicodeScalars.allSatisfy(CharacterSet.letters.contains),
              subtags.dropFirst().allSatisfy({ subtag in
                  (1...8).contains(subtag.count)
                      && subtag.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
              }) else {
            return nil
        }
        subtags[0] = bibliographicAliases[primary] ?? primary

        let language = Locale.Language(identifier: subtags.joined(separator: "-"))
        guard let languageCode = language.languageCode?.identifier.lowercased(),
              languageCode != "und",
              availableLanguageCodes.contains(languageCode)
                || Locale(identifier: "en").localizedString(
                    forLanguageCode: languageCode
                ) != nil else {
            return nil
        }
        subtags[0] = languageCode
        for index in subtags.indices.dropFirst() {
            let subtag = subtags[index]
            if subtag.count == 4,
               subtag.unicodeScalars.allSatisfy(CharacterSet.letters.contains) {
                subtags[index] = subtag.prefix(1).uppercased()
                    + subtag.dropFirst().lowercased()
            } else if subtag.count == 2,
                      subtag.unicodeScalars.allSatisfy(CharacterSet.letters.contains) {
                subtags[index] = subtag.uppercased()
            } else {
                subtags[index] = subtag.lowercased()
            }
        }
        return subtags.joined(separator: "-")
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

/// Attaches authored translations without involving a machine-translation
/// provider. Synchronized documents are matched only when a timestamp maps
/// uniquely in both directions; plain documents require an exact line-count
/// match before index-based pairing is allowed.
public enum LyricManualTranslationPolicy {
    public static func declaredLanguageCode(in metadataLines: [String]) -> String? {
        LyricTranslationGroupingPolicy.declaredLanguageCode(in: metadataLines)
    }

    public static func merging(
        originalLines: [LyricLine],
        translatedLines: [LyricLine],
        translationLanguageCode: String? = nil,
        source: LyricManualTranslationSource = .embeddedField,
        makePreferred: Bool = true,
        timestampTolerance: TimeInterval = 0.002
    ) -> [LyricLine] {
        guard !originalLines.isEmpty, !translatedLines.isEmpty else {
            return originalLines
        }

        let originalsAreSynchronized = originalLines.allSatisfy(\.isSynchronized)
        let translationsAreSynchronized = translatedLines.allSatisfy(\.isSynchronized)
        if originalsAreSynchronized, translationsAreSynchronized {
            return mergingSynchronized(
                originalLines: originalLines,
                translatedLines: translatedLines,
                translationLanguageCode: translationLanguageCode,
                source: source,
                makePreferred: makePreferred,
                timestampTolerance: max(0, timestampTolerance)
            )
        }

        let originalsArePlain = originalLines.allSatisfy { !$0.isSynchronized }
        let translationsArePlain = translatedLines.allSatisfy { !$0.isSynchronized }
        guard originalsArePlain,
              translationsArePlain,
              originalLines.count == translatedLines.count else {
            return originalLines
        }

        return zip(originalLines, translatedLines).map { original, translated in
            attaching(
                translated,
                to: original,
                translationLanguageCode: translationLanguageCode,
                source: source,
                makePreferred: makePreferred
            )
        }
    }

    /// True only when every non-empty source row has a selected authored
    /// translation. Alternate languages are retained but do not implicitly
    /// change which translation is selected for presentation.
    public static func hasCompleteCoverage(in lines: [LyricLine]) -> Bool {
        let contentLines = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !contentLines.isEmpty else { return false }
        return contentLines.allSatisfy {
            !($0.manualTranslation?.text ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
    }

    /// Selects an authored translation only when it is compatible with the
    /// requested presentation language. An explicitly tagged match wins over
    /// an untagged bilingual-LRC row; a translation tagged as another language
    /// must never suppress work for the requested target.
    public static func preferredTranslation(
        for line: LyricLine,
        targetLanguageCode: String
    ) -> LyricManualTranslation? {
        let candidates = line.allManualTranslations.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !candidates.isEmpty else { return nil }

        let exactMatches = candidates.filter {
            guard let languageCode = $0.languageCode else { return false }
            return LyricTranslationGroupingPolicy.representsSameTranslationLanguage(
                languageCode,
                targetLanguageCode
            )
        }
        if let exactMatch = preferredBySourcePriority(in: exactMatches) {
            return exactMatch
        }

        let untagged = candidates.filter { languageIdentity($0.languageCode) == nil }
        return preferredBySourcePriority(in: untagged)
    }

    public static func hasCompleteCoverage(
        in lines: [LyricLine],
        targetLanguageCode: String
    ) -> Bool {
        let contentLines = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !contentLines.isEmpty else { return false }
        return contentLines.allSatisfy {
            preferredTranslation(
                for: $0,
                targetLanguageCode: targetLanguageCode
            ) != nil
        }
    }

    /// 权威源文本（sidecar/TTML）与缓存的原文结构一致时，只把
    /// 缓存中的人工译文字段合并回权威行。原文数量、顺序、文本或
    /// 基本时间有任何歧义就拒绝合并；行尾、音节和声部可以只由
    /// 权威 TTML 携带，它们不是缓存译文能否补回的前置条件。
    public static func restoringStoredTranslations(
        from storedLines: [LyricLine],
        into authoritativeLines: [LyricLine],
        timestampTolerance: TimeInterval = 0.002
    ) -> [LyricLine]? {
        guard !storedLines.isEmpty,
              storedLines.count == authoritativeLines.count else {
            return nil
        }
        let tolerance = max(0, timestampTolerance)
        guard zip(storedLines, authoritativeLines).allSatisfy({ stored, authoritative in
            originalsAreEquivalent(stored, authoritative, tolerance: tolerance)
                && protectedBackgroundsAreCompatible(stored, authoritative)
        }) else {
            return nil
        }

        return zip(authoritativeLines, storedLines).map {
            mergingTranslationFields(
                from: $1,
                into: $0,
                timestampTolerance: tolerance
            )
        }
    }

    /// 服务端刷新了少数原文行时，保留仍能唯一证明归属的本地/
    /// 容器人工译文。先按完整结构匹配，再对剩余行按唯一原文文本
    /// 匹配（允许服务端只调整时间）。重复副歌和被改写的原文不猜。
    public static func preservingStoredTranslations(
        from storedLines: [LyricLine],
        in authoritativeLines: [LyricLine],
        timestampTolerance: TimeInterval = 0.002
    ) -> [LyricLine]? {
        guard !storedLines.isEmpty, !authoritativeLines.isEmpty else {
            return authoritativeLines
        }
        guard declaredLanguagesAreCompatible(storedLines, authoritativeLines) else {
            return nil
        }
        let tolerance = max(0, timestampTolerance)
        let refreshedSourceLines = rebuildingKnownBilingualLRCStructure(
            from: storedLines,
            in: authoritativeLines,
            timestampTolerance: tolerance
        ) ?? authoritativeLines
        var result = refreshedSourceLines
        var unmatchedStored = Set(storedLines.indices)
        var unmatchedAuthoritative = Set(refreshedSourceLines.indices)

        func uniquePairs(
            matching predicate: (LyricLine, LyricLine) -> Bool
        ) -> [(authoritative: Int, stored: Int)] {
            var pairs: [(authoritative: Int, stored: Int)] = []
            for authoritativeIndex in unmatchedAuthoritative.sorted() {
                let candidates = unmatchedStored.filter {
                    predicate(storedLines[$0], refreshedSourceLines[authoritativeIndex])
                }
                guard candidates.count == 1, let storedIndex = candidates.first else { continue }
                let reverseCandidates = unmatchedAuthoritative.filter {
                    predicate(storedLines[storedIndex], refreshedSourceLines[$0])
                }
                guard reverseCandidates.count == 1 else { continue }
                pairs.append((authoritativeIndex, storedIndex))
            }
            return pairs
        }

        func apply(_ pairs: [(authoritative: Int, stored: Int)]) {
            for pair in pairs
                where unmatchedStored.contains(pair.stored)
                    && unmatchedAuthoritative.contains(pair.authoritative) {
                result[pair.authoritative] = mergingTranslationFields(
                    from: storedLines[pair.stored],
                    into: result[pair.authoritative],
                    allowedStoredSources: [.embeddedField, .localEditor],
                    timestampTolerance: tolerance
                )
                unmatchedStored.remove(pair.stored)
                unmatchedAuthoritative.remove(pair.authoritative)
            }
        }

        apply(uniquePairs {
            originalsAreEquivalent($0, $1, tolerance: tolerance)
                && protectedBackgroundsAreCompatible($0, $1)
        })
        apply(uniquePairs {
            $0.isSynchronized == $1.isSynchronized
                && $0.text == $1.text
                && $0.voice == $1.voice
                && originalLanguagesAreCompatible($0.languageCode, $1.languageCode)
                && protectedBackgroundsAreCompatible($0, $1)
        })

        // A locally authored or container-field translation has no safe new
        // owner when its source row was rewritten, deleted, or became
        // ambiguous. Refuse the document replacement instead of guessing or
        // permanently deleting user-authored content. Source-owned bilingual
        // LRC rows may still be authoritatively replaced by the source.
        let hasUnmatchedProtectedTranslation = unmatchedStored.contains { index in
            containsProtectedStoredTranslation(in: storedLines[index])
        }
        guard !hasUnmatchedProtectedTranslation else { return nil }
        return result
    }

    /// 当前外部写回适配器没有独立译文字段，只有普通行级 LRC
    /// 可以用“原文行 + 同时间戳译文行”保存。字级、纯文本、重叠声部
    /// 或多个译文语言都不能通过这条路径无歧义往返。
    public static func canPersistAsBilingualLRC(_ lines: [LyricLine]) -> Bool {
        for line in lines {
            let preferredText = line.manualTranslation?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let alternates = line.alternateManualTranslations.filter {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let backgroundCarriesTranslations = (line.background ?? []).contains {
                !$0.allManualTranslations.filter {
                    !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }.isEmpty
            }
            guard !backgroundCarriesTranslations else { return false }
            guard !preferredText.isEmpty || !alternates.isEmpty else { continue }
            // 一个时间戳可以承载多行：外语歌的「原文 + 注音 + 译文」按原顺序
            // 写回去，仍能被重新读成同一结构。其它来源的多语言字段没有这种
            // 顺序约定，写成双语 LRC 就分不清哪一行是哪种语言，只能走结构化存储。
            guard alternates.allSatisfy({ $0.source == .bilingualLRC }),
                  !preferredText.isEmpty,
                  line.isSynchronized,
                  !line.isWordLevel,
                  line.voice == .primary,
                  line.background?.isEmpty != false else {
                return false
            }
            let persistedTexts = [preferredText] + alternates.map {
                $0.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard persistedTexts.allSatisfy({
                !$0.contains(where: \.isNewline) && translationTextRoundTripsAsLiteralLRC($0)
            }) else {
                return false
            }
        }
        return true
    }

    private static func translationTextRoundTripsAsLiteralLRC(_ text: String) -> Bool {
        let probe = LyricLine(
            timestamp: 1,
            text: text,
            isSynchronized: true
        )
        let parsed = LyricsContentParser.parseText(
            LyricsContentParser.serialize([probe]),
            options: .literal
        )
        guard parsed.count == 1, let roundTrip = parsed.first else { return false }
        return roundTrip.text == text
            && roundTrip.isSynchronized
            && abs(roundTrip.timestamp - probe.timestamp) <= 0.002
            && !roundTrip.isWordLevel
    }

    private static func originalsAreEquivalent(
        _ lhs: LyricLine,
        _ rhs: LyricLine,
        tolerance: TimeInterval
    ) -> Bool {
        guard lhs.text == rhs.text,
              lhs.isSynchronized == rhs.isSynchronized,
              lhs.voice == rhs.voice,
              originalLanguagesAreCompatible(lhs.languageCode, rhs.languageCode),
              abs(lhs.timestamp - rhs.timestamp) <= tolerance,
              optionalTimesAreCompatible(lhs.endTimestamp, rhs.endTimestamp, tolerance: tolerance),
              syllablesAreEquivalent(lhs.syllables, rhs.syllables, tolerance: tolerance) else {
            return false
        }
        let leftBackground = lhs.background ?? []
        let rightBackground = rhs.background ?? []
        if leftBackground.isEmpty || rightBackground.isEmpty {
            return true
        }
        guard leftBackground.count == rightBackground.count else { return false }
        return zip(leftBackground, rightBackground).allSatisfy {
            originalsAreEquivalent($0, $1, tolerance: tolerance)
        }
    }

    private static func optionalTimesAreCompatible(
        _ lhs: TimeInterval?,
        _ rhs: TimeInterval?,
        tolerance: TimeInterval
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, _), (_, nil):
            return true
        case (.some(let lhs), .some(let rhs)):
            return abs(lhs - rhs) <= tolerance
        }
    }

    private static func syllablesAreEquivalent(
        _ lhs: [LyricSyllable]?,
        _ rhs: [LyricSyllable]?,
        tolerance: TimeInterval
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, _), (_, nil):
            return true
        case (.some(let lhs), .some(let rhs)):
            guard lhs.count == rhs.count else { return false }
            return zip(lhs, rhs).allSatisfy {
                $0.text == $1.text
                    && abs($0.start - $1.start) <= tolerance
                    && abs($0.end - $1.end) <= tolerance
                    && originalLanguagesAreCompatible($0.languageCode, $1.languageCode)
            }
        }
    }

    private static func preferredBySourcePriority(
        in candidates: [LyricManualTranslation]
    ) -> LyricManualTranslation? {
        guard let bestPriority = candidates.map({ sourcePriority($0.source) }).max() else {
            return nil
        }
        return candidates.first { sourcePriority($0.source) == bestPriority }
    }

    private static func declaredLanguagesAreCompatible(
        _ lhs: [LyricLine],
        _ rhs: [LyricLine]
    ) -> Bool {
        let left = lhs.lazy
            .compactMap(\.metadataLines)
            .compactMap(LyricManualTranslationPolicy.declaredLanguageCode(in:))
            .first
        let right = rhs.lazy
            .compactMap(\.metadataLines)
            .compactMap(LyricManualTranslationPolicy.declaredLanguageCode(in:))
            .first
        return originalLanguagesAreCompatible(left, right)
    }

    private static func originalLanguagesAreCompatible(
        _ lhs: String?,
        _ rhs: String?
    ) -> Bool {
        guard let lhs, let rhs else { return true }
        return LyricTranslationGroupingPolicy.representsSameTranslationLanguage(lhs, rhs)
    }

    private static func sourcePriority(_ source: LyricManualTranslationSource) -> Int {
        switch source {
        case .embeddedField:
            return 4
        case .localEditor:
            return 3
        case .bilingualLRC:
            return 2
        }
    }

    private static func mergingTranslationFields(
        from stored: LyricLine,
        into authoritative: LyricLine,
        allowedStoredSources: Set<LyricManualTranslationSource>? = nil,
        timestampTolerance: TimeInterval
    ) -> LyricLine {
        var result = authoritative
        func isAllowed(_ translation: LyricManualTranslation) -> Bool {
            allowedStoredSources?.contains(translation.source) ?? true
        }

        var storedPreferred = stored.manualTranslation.flatMap {
            isAllowed($0) ? $0 : nil
        }
        var storedAlternates = stored.alternateManualTranslations.filter(isAllowed)
        if storedPreferred == nil,
           let promotedIndex = storedAlternates.indices.max(by: {
               sourcePriority(storedAlternates[$0].source)
                   < sourcePriority(storedAlternates[$1].source)
           }) {
            storedPreferred = storedAlternates.remove(at: promotedIndex)
        }

        if let storedPreferred {
            if let authoritativePreferred = result.manualTranslation {
                if occupiesSameSlot(authoritativePreferred, storedPreferred) {
                    if sourcePriority(storedPreferred.source)
                        > sourcePriority(authoritativePreferred.source) {
                        result.manualTranslation = storedPreferred
                    }
                } else if sourcePriority(storedPreferred.source)
                    > sourcePriority(authoritativePreferred.source) {
                    upsertAlternate(
                        authoritativePreferred,
                        in: &result.alternateManualTranslations
                    )
                    result.alternateManualTranslations.removeAll {
                        occupiesSameSlot($0, storedPreferred)
                    }
                    result.manualTranslation = storedPreferred
                } else {
                    upsertAlternate(
                        storedPreferred,
                        in: &result.alternateManualTranslations
                    )
                }
            } else {
                result.alternateManualTranslations.removeAll {
                    occupiesSameSlot($0, storedPreferred)
                }
                result.manualTranslation = storedPreferred
            }
        }
        for alternate in storedAlternates {
            guard result.manualTranslation.map({
                occupiesSameSlot($0, alternate)
            }) != true else { continue }
            upsertAlternate(alternate, in: &result.alternateManualTranslations)
        }

        if let storedBackground = stored.background,
           let authoritativeBackground = result.background,
           storedBackground.count == authoritativeBackground.count {
            let canMergeBackground: Bool
            if allowedStoredSources == nil {
                canMergeBackground = zip(storedBackground, authoritativeBackground)
                    .allSatisfy {
                        originalsAreEquivalent(
                            $0,
                            $1,
                            tolerance: timestampTolerance
                        )
                    }
            } else {
                canMergeBackground = protectedBackgroundsAreCompatible(
                    stored,
                    authoritative,
                    tolerance: timestampTolerance
                )
            }
            if canMergeBackground {
            result.background = zip(storedBackground, authoritativeBackground).map {
                mergingTranslationFields(
                    from: $0,
                    into: $1,
                    allowedStoredSources: allowedStoredSources,
                    timestampTolerance: timestampTolerance
                )
            }
            }
        }
        return result
    }

    /// A conservative parser leaves same-script bilingual LRC as two literal
    /// rows. Once a previous source read has established that exact topology,
    /// it is safe to rebuild the pair and accept a source-side translation
    /// edit without guessing new duet/chorus relationships.
    private static func rebuildingKnownBilingualLRCStructure(
        from storedLines: [LyricLine],
        in authoritativeLines: [LyricLine],
        timestampTolerance: TimeInterval
    ) -> [LyricLine]? {
        guard storedLines.contains(where: { line in
            line.allManualTranslations.contains { $0.source == .bilingualLRC }
        }) else {
            return nil
        }

        var pairsByOriginalIndex: [Int: (translationIndex: Int, languageCode: String?)] = [:]
        var claimedTranslationIndexes: Set<Int> = []
        for stored in storedLines {
            guard let knownTranslation = stored.allManualTranslations.first(where: {
                $0.source == .bilingualLRC
            }) else { continue }
            let exactOriginalCandidates = authoritativeLines.indices.filter {
                authoritativeLines[$0].allManualTranslations.isEmpty
                    && originalsAreEquivalent(
                        stored,
                        authoritativeLines[$0],
                        tolerance: timestampTolerance
                    )
            }
            let textOriginalCandidates = authoritativeLines.indices.filter {
                authoritativeLines[$0].allManualTranslations.isEmpty
                    && stored.text == authoritativeLines[$0].text
                    && stored.isSynchronized == authoritativeLines[$0].isSynchronized
                    && stored.voice == authoritativeLines[$0].voice
            }
            let originalCandidates = exactOriginalCandidates.count == 1
                ? exactOriginalCandidates
                : textOriginalCandidates
            guard originalCandidates.count == 1,
                  let originalIndex = originalCandidates.first,
                  authoritativeLines.indices.contains(originalIndex + 1) else {
                continue
            }
            let reverseStoredMatches = storedLines.filter {
                $0.text == authoritativeLines[originalIndex].text
                    && $0.isSynchronized == authoritativeLines[originalIndex].isSynchronized
                    && $0.voice == authoritativeLines[originalIndex].voice
            }
            guard reverseStoredMatches.count == 1 else { continue }

            let translationIndex = originalIndex + 1
            let original = authoritativeLines[originalIndex]
            let translation = authoritativeLines[translationIndex]
            let consumesAnotherKnownOriginal = storedLines.contains {
                $0.text == translation.text
                    && $0.isSynchronized == translation.isSynchronized
                    && $0.voice == translation.voice
            }
            guard translation.allManualTranslations.isEmpty,
                  (translation.text == knownTranslation.text
                    || confidentlyMatchesKnownTranslationLanguage(
                        translation.text,
                        originalText: original.text,
                        knownTranslation: knownTranslation
                    )),
                  !consumesAnotherKnownOriginal,
                  !claimedTranslationIndexes.contains(translationIndex),
                  pairsByOriginalIndex[translationIndex] == nil,
                  original.isSynchronized,
                  translation.isSynchronized,
                  abs(original.timestamp - translation.timestamp) <= timestampTolerance,
                  !original.isWordLevel,
                  !translation.isWordLevel,
                  original.voice == .primary,
                  translation.voice == .primary,
                  original.background?.isEmpty != false,
                  translation.background?.isEmpty != false,
                  !translation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            pairsByOriginalIndex[originalIndex] = (
                translationIndex,
                knownTranslation.languageCode
            )
            claimedTranslationIndexes.insert(translationIndex)
        }
        guard !pairsByOriginalIndex.isEmpty else { return nil }

        return authoritativeLines.indices.compactMap { index in
            guard !claimedTranslationIndexes.contains(index) else { return nil }
            var line = authoritativeLines[index]
            if let pair = pairsByOriginalIndex[index] {
                let translation = authoritativeLines[pair.translationIndex]
                line.manualTranslation = LyricManualTranslation(
                    id: translation.id,
                    text: translation.text,
                    languageCode: pair.languageCode,
                    source: .bilingualLRC
                )
            }
            return line
        }
    }

    private static func confidentlyMatchesKnownTranslationLanguage(
        _ candidateText: String,
        originalText: String,
        knownTranslation: LyricManualTranslation
    ) -> Bool {
        guard let knownLanguage = languageIdentity(knownTranslation.languageCode),
              let candidateLanguage = confidentlyDetectedLanguage(in: candidateText),
              let originalLanguage = confidentlyDetectedLanguage(in: originalText) else {
            return false
        }
        return candidateLanguage == knownLanguage
            && originalLanguage != knownLanguage
    }

    private static func confidentlyDetectedLanguage(in text: String) -> String? {
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let hypothesis = recognizer
            .languageHypotheses(withMaximum: 2)
            .max(by: { $0.value < $1.value }),
              hypothesis.value >= 0.65 else { return nil }
        return languageIdentity(hypothesis.key.rawValue)
        #else
        return nil
        #endif
    }

    private static func containsProtectedStoredTranslation(in line: LyricLine) -> Bool {
        line.allManualTranslations.contains { translation in
            !translation.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && translation.source != .bilingualLRC
        } || (line.background?.contains(where: containsProtectedStoredTranslation) ?? false)
    }

    private static func protectedBackgroundsAreCompatible(
        _ stored: LyricLine,
        _ authoritative: LyricLine,
        tolerance: TimeInterval = 0.002
    ) -> Bool {
        let storedBackground = stored.background ?? []
        guard storedBackground.contains(where: containsProtectedStoredTranslation) else {
            return true
        }
        let authoritativeBackground = authoritative.background ?? []
        guard storedBackground.count == authoritativeBackground.count else { return false }
        let storedIdentityCounts = Dictionary(
            grouping: storedBackground,
            by: protectedBackgroundIdentity
        ).mapValues(\.count)
        let authoritativeIdentityCounts = Dictionary(
            grouping: authoritativeBackground,
            by: protectedBackgroundIdentity
        ).mapValues(\.count)

        return zip(storedBackground, authoritativeBackground).allSatisfy { pair in
            let identity = protectedBackgroundIdentity(pair.0)
            guard identity == protectedBackgroundIdentity(pair.1) else { return false }
            let isAmbiguous = (storedIdentityCounts[identity] ?? 0) > 1
                || (authoritativeIdentityCounts[identity] ?? 0) > 1
            return (!isAmbiguous || protectedBackgroundTimingMatches(
                pair.0,
                pair.1,
                tolerance: tolerance
            )) && protectedBackgroundsAreCompatible(
                pair.0,
                pair.1,
                tolerance: tolerance
            )
        }
    }

    private struct ProtectedBackgroundIdentity: Hashable {
        let text: String
        let isSynchronized: Bool
        let voice: LyricVoice
        let languageCode: String?
    }

    private static func protectedBackgroundIdentity(
        _ line: LyricLine
    ) -> ProtectedBackgroundIdentity {
        ProtectedBackgroundIdentity(
            text: line.text,
            isSynchronized: line.isSynchronized,
            voice: line.voice,
            languageCode: line.languageCode
        )
    }

    private static func protectedBackgroundTimingMatches(
        _ stored: LyricLine,
        _ authoritative: LyricLine,
        tolerance: TimeInterval
    ) -> Bool {
        guard abs(stored.timestamp - authoritative.timestamp) <= tolerance,
              strictOptionalTimesMatch(
                stored.endTimestamp,
                authoritative.endTimestamp,
                tolerance: tolerance
              ) else { return false }
        switch (stored.syllables, authoritative.syllables) {
        case (nil, nil):
            return true
        case (.some(let storedWords), .some(let authoritativeWords)):
            guard storedWords.count == authoritativeWords.count else { return false }
            return zip(storedWords, authoritativeWords).allSatisfy {
                $0.text == $1.text
                    && abs($0.start - $1.start) <= tolerance
                    && abs($0.end - $1.end) <= tolerance
                    && $0.endTiming == $1.endTiming
            }
        case (.none, .some), (.some, .none):
            return false
        }
    }

    private static func strictOptionalTimesMatch(
        _ lhs: TimeInterval?,
        _ rhs: TimeInterval?,
        tolerance: TimeInterval
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case (.some(let lhs), .some(let rhs)):
            return abs(lhs - rhs) <= tolerance
        case (.none, .some), (.some, .none):
            return false
        }
    }

    private static func upsertAlternate(
        _ translation: LyricManualTranslation,
        in alternates: inout [LyricManualTranslation]
    ) {
        if let index = alternates.firstIndex(where: {
            occupiesSameSlot($0, translation)
        }) {
            if sourcePriority(translation.source) > sourcePriority(alternates[index].source) {
                alternates[index] = translation
            }
            return
        }
        appendIfNeeded(translation, to: &alternates)
    }

    private static func mergingSynchronized(
        originalLines: [LyricLine],
        translatedLines: [LyricLine],
        translationLanguageCode: String?,
        source: LyricManualTranslationSource,
        makePreferred: Bool,
        timestampTolerance: TimeInterval
    ) -> [LyricLine] {
        let nonEmptyTranslationIndexes = translatedLines.indices.filter {
            !translatedLines[$0].text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        }
        let candidatesByOriginal = originalLines.indices.map { originalIndex in
            nonEmptyTranslationIndexes.filter { translationIndex in
                abs(
                    originalLines[originalIndex].timestamp
                        - translatedLines[translationIndex].timestamp
                ) <= timestampTolerance
            }
        }
        var originalCountByTranslationIndex: [Int: Int] = [:]
        for candidates in candidatesByOriginal {
            for translationIndex in candidates {
                originalCountByTranslationIndex[translationIndex, default: 0] += 1
            }
        }

        return originalLines.enumerated().map { originalIndex, original in
            let candidates = candidatesByOriginal[originalIndex]
            guard candidates.count == 1,
                  let translationIndex = candidates.first,
                  originalCountByTranslationIndex[translationIndex] == 1 else {
                return original
            }
            return attaching(
                translatedLines[translationIndex],
                to: original,
                translationLanguageCode: translationLanguageCode,
                source: source,
                makePreferred: makePreferred
            )
        }
    }

    private static func attaching(
        _ translatedLine: LyricLine,
        to originalLine: LyricLine,
        translationLanguageCode: String?,
        source: LyricManualTranslationSource,
        makePreferred: Bool
    ) -> LyricLine {
        let text = translatedLine.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return originalLine }

        let trimmedLanguageCode = translationLanguageCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = LyricManualTranslation(
            id: translatedLine.id,
            text: text,
            languageCode: trimmedLanguageCode?.isEmpty == false ? trimmedLanguageCode : nil,
            source: source
        )
        var result = originalLine

        if makePreferred {
            if let previous = result.manualTranslation,
               !occupiesSameSlot(previous, translation) {
                appendIfNeeded(previous, to: &result.alternateManualTranslations)
            }
            result.alternateManualTranslations.removeAll {
                occupiesSameSlot($0, translation)
            }
            result.manualTranslation = translation
            return result
        }

        if let preferred = result.manualTranslation,
           occupiesSameSlot(preferred, translation) {
            return result
        }
        if let existingIndex = result.alternateManualTranslations.firstIndex(where: {
            occupiesSameSlot($0, translation)
        }) {
            result.alternateManualTranslations[existingIndex] = translation
        } else {
            appendIfNeeded(translation, to: &result.alternateManualTranslations)
        }
        return result
    }

    private static func appendIfNeeded(
        _ translation: LyricManualTranslation,
        to translations: inout [LyricManualTranslation]
    ) {
        guard !translations.contains(where: {
            $0.text == translation.text
                && $0.languageCode == translation.languageCode
                && $0.source == translation.source
        }) else { return }
        translations.append(translation)
    }

    private static func occupiesSameSlot(
        _ lhs: LyricManualTranslation,
        _ rhs: LyricManualTranslation
    ) -> Bool {
        if lhs.id == rhs.id { return true }
        guard lhs.source == rhs.source else { return false }
        let leftLanguage = normalizedLanguageCode(lhs.languageCode)
        let rightLanguage = normalizedLanguageCode(rhs.languageCode)
        switch (leftLanguage, rightLanguage) {
        case (nil, nil):
            return true
        case (.some(let left), .some(let right)):
            return LyricTranslationGroupingPolicy.representsSameTranslationLanguage(left, right)
        default:
            return false
        }
    }

    private static func normalizedLanguageCode(_ code: String?) -> String? {
        guard let code else { return nil }
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        if LyricLanguageCodePolicy.canonicalIdentifier(normalized) != nil {
            return LyricTranslationGroupingPolicy.languageIdentity(normalized)
        }
        return normalized
    }

    private static func languageIdentity(_ code: String?) -> String? {
        guard let code,
              LyricLanguageCodePolicy.canonicalIdentifier(code) != nil else {
            return nil
        }
        return LyricTranslationGroupingPolicy.languageIdentity(code)
    }
}

/// Conservatively recognizes the common bilingual-LRC convention where an
/// authored translation immediately follows its source at the same timestamp.
/// A single pair is never enough: the document must first establish a stable
/// structure — the same number of rows per timestamp, with the companion rows
/// written in the same scripts — across multiple distinct clusters. Clusters
/// that cannot be classified on their own then follow that proven structure,
/// which is how mainstream players read these files. Repeated chorus rows,
/// explicit voice timelines, and common speaker-prefixed duet rows remain
/// unmodified; callers can use literal parsing for inherently ambiguous
/// unlabelled duets.
public enum LyricBilingualPairingPolicy {
    public static func pair(
        _ lines: [LyricLine],
        enabled: Bool = true,
        timestampTolerance: TimeInterval = 0.002
    ) -> [LyricLine] {
        guard enabled, lines.count >= 4 else { return lines }

        let tolerance = max(0, timestampTolerance)
        let clusters = adjacentTimestampClusters(in: lines, tolerance: tolerance)
        // 只有同一个时间戳上重复出现的行才存在「是不是双语」的歧义。单独成行的
        // 歌词不参与分母 —— 否则一首中文歌里只夹了几句外语和它们的译文时，比例
        // 永远达不到门槛，那几句的原文就一直高亮不了。
        var repeatedClusterCounts: [Int: Int] = [:]
        for cluster in clusters where cluster.count >= 2
            && cluster.contains(where: { isPairableSourceLine(lines[$0]) }) {
            repeatedClusterCounts[cluster.count, default: 0] += 1
        }

        let candidates = clusters.compactMap { makeCandidate(cluster: $0, in: lines) }
        let candidatesByRowCount = Dictionary(grouping: candidates, by: \.rowCount)
        var accepted: [PairCandidate] = []
        var provenSignatures: [[ScriptFamily]] = []
        for (rowCount, group) in candidatesByRowCount {
            guard let structure = dominantStructure(
                in: group,
                repeatedClusterCount: repeatedClusterCounts[rowCount] ?? group.count
            ) else { continue }
            accepted.append(contentsOf: structure.candidates)
            provenSignatures.append(structure.signature)
        }
        // 某个行数只出现过一次时投不出票，但它同样会把高亮落到译文上。
        if candidatesByRowCount.values.contains(where: { $0.count == 1 }) {
            accepted.append(contentsOf: loneTranslatedCandidates(
                in: candidatesByRowCount,
                provenSignatures: provenSignatures,
                documentScript: documentScript(in: lines, clusters: clusters)
            ))
        }
        guard !accepted.isEmpty else { return lines }

        let candidateBySourceIndex = Dictionary(
            uniqueKeysWithValues: accepted.map { ($0.sourceIndex, $0) }
        )
        let absorbedIndexes = Set(accepted.flatMap(\.companionIndexes))
        return lines.enumerated().compactMap { index, line in
            guard !absorbedIndexes.contains(index) else { return nil }
            guard let candidate = candidateBySourceIndex[index] else { return line }

            // 文件里的先后顺序就是作者想要的阅读顺序：注音写在译文前面就先显示
            // 注音。这里不去猜哪一条是注音、哪一条是翻译，只把第一条当首选译文。
            let companions = candidate.companionIndexes.map { companionIndex in
                LyricManualTranslation(
                    id: lines[companionIndex].id,
                    text: lines[companionIndex].text,
                    source: .bilingualLRC
                )
            }
            var sourceLine = line
            sourceLine.manualTranslation = companions.first
            sourceLine.alternateManualTranslations = Array(companions.dropFirst())
            return sourceLine
        }
    }

    /// 一句原文最多吸收三条附属行。外语歌常见「原文 + 注音 + 译文」，也有
    /// 「原文 + 注音 + 中译 + 英译」四行共用一个时间戳；再多就更可能是多声部
    /// 叠唱，吞掉任何一行都会真的丢内容。
    private static let maximumRowCount = 4

    private static func makeCandidate(
        cluster: [Int],
        in lines: [LyricLine]
    ) -> PairCandidate? {
        guard cluster.count >= 2, cluster.count <= maximumRowCount else { return nil }

        let sourceIndex = cluster[0]
        let source = lines[sourceIndex]
        // 原文允许自带逐字时间轴：不少工具(如 Lyrico)会把逐字原文和整行
        // 译文写成同一个时间戳的相邻两行。此前原文因为带音节而被排除在配对
        // 之外，译文于是留成独立一行 —— 它和原文时间戳相同又排在后面，
        // 高亮便落到译文上，原文的逐字扫光和点按都随之失效。
        guard isPairableSourceLine(source),
              !appearsSpeakerAttributed(source.text),
              !isFullyBracketed(source.text),
              source.manualTranslation == nil,
              source.alternateManualTranslations.isEmpty else {
            return nil
        }

        let sourceEvidence = leadingScript(in: source.text)
        let sourceText = normalizedText(source.text)
        var companionFamilies: [ScriptFamily?] = []
        var companionTexts: [String] = []
        for companionIndex in cluster.dropFirst() {
            let companion = lines[companionIndex]
            guard isOrdinarySynchronizedLine(companion),
                  !appearsSpeakerAttributed(companion.text),
                  companion.manualTranslation == nil,
                  companion.alternateManualTranslations.isEmpty else {
                return nil
            }
            let companionEvidence = leadingScript(in: companion.text)
            var family = companionEvidence?.family
            if let companionEvidence,
               let sourceEvidence,
               companionEvidence.family == sourceEvidence.family {
                // 两行几乎整行都是同一种文字：双声部或者同一句写了两遍，
                // 吞掉一行会真的丢内容。
                guard !(sourceEvidence.isDominant && companionEvidence.isDominant) else {
                    return nil
                }
                // 原文里夹着几个同种文字的字（英文句里的地名之类）说明不了
                // 这一行是不是译文，交给整篇的结构去判断。
                family = nil
            }
            let text = normalizedText(companion.text)
            guard text != sourceText, !companionTexts.contains(text) else { return nil }
            companionFamilies.append(family)
            companionTexts.append(text)
        }

        return PairCandidate(
            sourceIndex: sourceIndex,
            companionIndexes: Array(cluster.dropFirst()),
            sourceFamily: sourceEvidence?.family,
            sourceFamilyIsExclusive: sourceEvidence?.isDominant == true,
            companionFamilies: companionFamilies,
            sourceText: sourceText,
            companionTexts: companionTexts
        )
    }

    /// 同一时间戳上行数相同的候选各自投票。一份文档里既可能整篇都是「原文 +
    /// 译文」，也可能整篇都是「原文 + 注音 + 译文」，两种结构分开计票才不会
    /// 互相拉低比例。
    ///
    /// 票面只看附属行的文字构成（注音是拉丁、译文是汉字……），不看原文自己是
    /// 哪种文字 —— 混合语的原文、以及整篇里夹的那几句外语，文字构成本来就和
    /// 主体不同，把它算进票面只会让这些句子因为「少数派」被判掉。
    private static func dominantStructure(
        in candidates: [PairCandidate],
        repeatedClusterCount: Int
    ) -> (signature: [ScriptFamily], candidates: [PairCandidate])? {
        let confident = candidates.filter { $0.signature != nil }
        guard confident.count >= 2 else { return nil }

        var countBySignature: [[ScriptFamily]: Int] = [:]
        for candidate in confident {
            guard let signature = candidate.signature else { continue }
            countBySignature[signature, default: 0] += 1
        }
        guard let highestCount = countBySignature.values.max(),
              highestCount >= 2 else {
            return nil
        }
        let dominantSignatures = countBySignature.compactMap { signature, count in
            count == highestCount ? signature : nil
        }
        guard dominantSignatures.count == 1,
              let dominantSignature = dominantSignatures.first else {
            return nil
        }

        let dominant = confident.filter { $0.signature == dominantSignature }
        // 结构一旦成立，同一形状里证据不足的那几簇也跟着走：短感叹词、只有
        // 符号或数字的行、以及没有收录的文字都分不出文字构成，但它们和整篇
        // 是同一个作者写的同一种结构。市面上的播放器读双语 LRC 就是只看结构。
        let adopted = candidates.filter {
            $0.signature == nil && $0.fits(dominantSignature)
        }
        let paired = dominant + adopted

        // 整段重复的副歌无法区分「译文」和「同一句唱了两遍」，因此原文和每一条
        // 附属行都要至少出现两种不同文本。
        let companionTextsAreVaried = dominantSignature.indices.allSatisfy { slot in
            Set(dominant.map { $0.companionTexts[slot] }).count >= 2
        }
        guard Set(dominant.map(\.sourceText)).count >= 2,
              companionTextsAreVaried,
              dominant.count * 5 >= confident.count * 4,
              paired.count * 5 >= repeatedClusterCount * 3 else {
            return nil
        }
        return (dominantSignature, paired)
    }

    /// 某个行数整篇只出现一次的那一簇：凑不出第二票，但它同样会把高亮落到
    /// 译文上。两种证据足以认定它是译文而不是另一个声部 ——
    ///
    /// - 整篇已经证明了自己的结构，这一簇只是少了一条附属行（夹在韩语歌里的
    ///   英文句不需要注音），剩下的位置仍然对得上；
    /// - 或者整篇是单语歌词、只夹了这一句外语：附属行用的正是整篇歌词的文字，
    ///   原文不是。
    private static func loneTranslatedCandidates(
        in candidatesByRowCount: [Int: [PairCandidate]],
        provenSignatures: [[ScriptFamily]],
        documentScript: ScriptFamily?
    ) -> [PairCandidate] {
        candidatesByRowCount.values.compactMap { group in
            guard group.count == 1,
                  let candidate = group.first,
                  let signature = candidate.signature,
                  let sourceFamily = candidate.sourceFamily,
                  !signature.contains(sourceFamily) else {
                return nil
            }
            let matchesProvenStructure = provenSignatures.contains {
                $0.count > signature.count
                    && ($0.starts(with: signature)
                        || Array($0.suffix(signature.count)) == signature)
            }
            let translatesIntoTheDocumentScript = documentScript.map {
                signature.contains($0) && sourceFamily != $0
            } ?? false
            guard matchesProvenStructure || translatesIntoTheDocumentScript else {
                return nil
            }
            return candidate
        }
    }

    /// 整篇歌词自己用的文字。只数单独成行的歌词 —— 它们不涉及配对歧义，
    /// 因此最能代表这份文件是用哪种文字写的。
    private static func documentScript(
        in lines: [LyricLine],
        clusters: [[Int]]
    ) -> ScriptFamily? {
        var counts: [ScriptFamily: Int] = [:]
        for cluster in clusters where cluster.count == 1 {
            guard let evidence = leadingScript(in: lines[cluster[0]].text) else { continue }
            counts[evidence.family, default: 0] += 1
        }
        guard let highestCount = counts.values.max(), highestCount >= 2 else { return nil }
        let leading = counts.compactMap { family, count in
            count == highestCount ? family : nil
        }
        return leading.count == 1 ? leading.first : nil
    }

    private struct PairCandidate {
        var sourceIndex: Int
        var companionIndexes: [Int]
        var sourceFamily: ScriptFamily?
        /// 原文几乎整行都是 `sourceFamily`。混合语的原文不是，所以它不能拿来
        /// 否决一条同种文字的附属行。
        var sourceFamilyIsExclusive: Bool
        var companionFamilies: [ScriptFamily?]
        var sourceText: String
        var companionTexts: [String]

        var rowCount: Int { companionIndexes.count + 1 }

        /// 每一条附属行的文字都认得出来时，这一簇才能自己投票。
        var signature: [ScriptFamily]? {
            let known = companionFamilies.compactMap { $0 }
            return known.count == companionFamilies.count ? known : nil
        }

        /// 证据不足的一簇能否按整篇的结构解析：认出来的每一条都要落在对应的
        /// 位置上，而原文不能和任何一条附属行同种文字。
        func fits(_ signature: [ScriptFamily]) -> Bool {
            guard companionFamilies.count == signature.count else { return false }
            if sourceFamilyIsExclusive,
               let sourceFamily,
               signature.contains(sourceFamily) {
                return false
            }
            return zip(companionFamilies, signature).allSatisfy { family, expected in
                family == nil || family == expected
            }
        }
    }

    private enum ScriptFamily: Hashable {
        case latin
        case han
        case japanese
        case hangul
        case arabic
        case hebrew
        case cyrillic
        case greek
        case armenian
        case georgian
        case devanagari
        case bengali
        case gurmukhi
        case gujarati
        case oriya
        case tamil
        case telugu
        case kannada
        case malayalam
        case sinhala
        case thaana
        case thai
        case lao
        case tibetan
        case myanmar
        case khmer
        case ethiopic
        case cherokee
        case mongolian
    }

    private static func adjacentTimestampClusters(
        in lines: [LyricLine],
        tolerance: TimeInterval
    ) -> [[Int]] {
        var result: [[Int]] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            var cluster = [index]
            var nextIndex = lines.index(after: index)
            while nextIndex < lines.endIndex,
                  lines[index].isSynchronized,
                  lines[nextIndex].isSynchronized,
                  abs(lines[nextIndex].timestamp - lines[index].timestamp) <= tolerance {
                cluster.append(nextIndex)
                nextIndex = lines.index(after: nextIndex)
            }
            result.append(cluster)
            index = nextIndex
        }
        return result
    }

    /// 可以充当译文的行：必须是纯行级歌词。
    ///
    /// 译文侧不放宽到逐字 —— 两行都带音节时更可能是双声部或对唱，
    /// 把其中一行吞成翻译会真的丢内容。
    private static func isOrdinarySynchronizedLine(_ line: LyricLine) -> Bool {
        line.isSynchronized
            && line.voice == .primary
            && line.syllables?.isEmpty != false
            && line.background?.isEmpty != false
            && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 可以充当原文的行：与译文侧的唯一区别是允许携带逐字时间轴，
    /// 配对后这条时间轴会原样保留，逐字扫光照常工作。
    private static func isPairableSourceLine(_ line: LyricLine) -> Bool {
        line.isSynchronized
            && line.voice == .primary
            && line.background?.isEmpty != false
            && !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static let bracketPairs: [Character: Character] = [
        "(": ")", "（": "）", "[": "]", "【": "】", "<": ">", "〈": "〉",
    ]

    /// 整行都被同一对括号包住的行是注记（「(合唱)」「(Guitar solo)」），
    /// 不能当原文。行首括号后面还接着正文的不算 —— 「(Hey) 두고 봐 Babe」
    /// 在韩语歌里就是正常的一句，把它判成注记会让整句配不上译文。
    private static func isFullyBracketed(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let opening = trimmed.first,
              let closing = bracketPairs[opening],
              trimmed.last == closing else {
            return false
        }
        var depth = 0
        for (offset, character) in trimmed.enumerated() {
            if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 { return offset == trimmed.count - 1 }
            }
        }
        return false
    }

    private static func appearsSpeakerAttributed(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        guard let separator = trimmed.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return false
        }
        let prefix = trimmed[..<separator]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !prefix.isEmpty, prefix.count <= 16 else { return false }
        if prefix.count == 1 { return true }

        let compact = prefix.filter { $0.isLetter || $0.isNumber }
        let speakerLabels: Set<String> = [
            "male", "female", "man", "woman", "boy", "girl", "singer",
            "lead", "backing", "chorus", "duet", "vocal", "voice",
            "男", "女", "主唱", "副唱", "合唱", "和声", "独唱", "对唱",
        ]
        return speakerLabels.contains(compact)
    }

    /// 一行歌词的主体文字。
    ///
    /// 非拉丁语系的歌词里夹英文单词是常态（「두고 봐 Babe」「夢の中の
    /// Wonderland」「你是我的 baby」），所以拉丁字母永远不会盖过真正出现的
    /// 其它文字 —— 只有整行没有别的文字时它才是主体。这样混合语的原文才认得
    /// 出来，它的注音（纯拉丁）和译文（汉字等）也才分得开。
    ///
    /// 真的混了两种非拉丁文字、或者只有孤零零一个非拉丁字符夹在英文里时不猜：
    /// 这一簇交给整篇的结构去覆盖，比猜错一次好。
    private static func leadingScript(in text: String) -> ScriptEvidence? {
        var counts: [ScriptFamily: Int] = [:]
        var hanCount = 0
        var kanaCount = 0
        var latinCount = 0
        var alphabeticCount = 0

        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            alphabeticCount += 1
            guard let family = scriptFamily(for: scalar.value) else { continue }
            switch family {
            case .han:
                hanCount += 1
            case .japanese:
                kanaCount += 1
            case .latin:
                latinCount += 1
            default:
                counts[family, default: 0] += 1
            }
        }

        if kanaCount > 0 {
            counts[.japanese] = hanCount + kanaCount
        } else if hanCount > 0 {
            counts[.han] = hanCount
        }

        if let highestCount = counts.values.max() {
            let leading = counts.compactMap { family, count in
                count == highestCount ? family : nil
            }
            guard leading.count == 1, let family = leading.first else { return nil }
            guard highestCount >= 2 || latinCount == 0 else { return nil }
            return ScriptEvidence(
                family: family,
                isDominant: isDominant(highestCount, of: alphabeticCount)
            )
        }
        guard latinCount >= 2 || (latinCount == 1 && alphabeticCount == 1) else {
            return nil
        }
        return ScriptEvidence(
            family: .latin,
            isDominant: isDominant(latinCount, of: alphabeticCount)
        )
    }

    /// 七成以上的字母都是同一种文字时，这一行就只算这种文字写的。
    private static func isDominant(_ count: Int, of alphabeticCount: Int) -> Bool {
        alphabeticCount > 0 && Double(count) / Double(alphabeticCount) >= 0.7
    }

    private struct ScriptEvidence {
        var family: ScriptFamily
        var isDominant: Bool
    }

    private static func scriptFamily(for value: UInt32) -> ScriptFamily? {
        switch value {
        case 0x0041...0x005A, 0x0061...0x007A,
             0x00C0...0x024F, 0x0250...0x02AF,
             0x1E00...0x1EFF, 0x2C60...0x2C7F,
             0xA720...0xA7FF, 0xAB30...0xAB6F,
             0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return .latin
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x3134F:
            return .han
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
            return .japanese
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F,
             0xAC00...0xD7AF, 0xD7B0...0xD7FF, 0xFFA0...0xFFDC:
            return .hangul
        case 0x0600...0x06FF, 0x0750...0x077F, 0x0870...0x089F,
             0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return .arabic
        case 0x0590...0x05FF, 0xFB1D...0xFB4F:
            return .hebrew
        case 0x0400...0x052F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return .cyrillic
        case 0x0370...0x03FF, 0x1F00...0x1FFF:
            return .greek
        case 0x0530...0x058F, 0xFB13...0xFB17:
            return .armenian
        case 0x10A0...0x10FF, 0x1C90...0x1CBF, 0x2D00...0x2D2F:
            return .georgian
        case 0x0900...0x097F, 0xA8E0...0xA8FF:
            return .devanagari
        case 0x0980...0x09FF:
            return .bengali
        case 0x0A00...0x0A7F:
            return .gurmukhi
        case 0x0A80...0x0AFF:
            return .gujarati
        case 0x0B00...0x0B7F:
            return .oriya
        case 0x0B80...0x0BFF:
            return .tamil
        case 0x0C00...0x0C7F:
            return .telugu
        case 0x0C80...0x0CFF:
            return .kannada
        case 0x0D00...0x0D7F:
            return .malayalam
        case 0x0D80...0x0DFF:
            return .sinhala
        case 0x0780...0x07BF:
            return .thaana
        case 0x0E00...0x0E7F:
            return .thai
        case 0x0E80...0x0EFF:
            return .lao
        case 0x0F00...0x0FFF:
            return .tibetan
        case 0x1000...0x109F:
            return .myanmar
        case 0x1780...0x17FF:
            return .khmer
        case 0x1200...0x139F:
            return .ethiopic
        case 0x13A0...0x13FF:
            return .cherokee
        case 0x1800...0x18AF:
            return .mongolian
        default:
            return nil
        }
    }
}

/// Produces one Translation batch per source language. Apple Translation
/// requires every request in a batch to use the same source language, while a
/// line whose language cannot be identified safely follows the language of the
/// surrounding lyrics when one is available. Remaining unknown lines share one
/// auto-detected session so they cannot trigger a separate system prompt per
/// short line.
public enum LyricTranslationGroupingPolicy {
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

        if hasDistinctScriptEvidence(
            text: text,
            languageCode: detectedIdentity,
            comparedWith: fallbackIdentity
        ) {
            return detectedIdentity
        }

        if lineWritingDirectionMatchesDetectedLanguage(
            text: text,
            detectedLanguageCode: detectedIdentity,
            fallbackLanguageCode: fallbackIdentity
        ) {
            return detectedIdentity
        }

        if hasDistinctScriptEvidence(
            text: text,
            languageCode: fallbackIdentity,
            comparedWith: detectedIdentity
        ) {
            return fallbackIdentity
        }

        let letterCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
            if CharacterSet.letters.contains(scalar) { count += 1 }
        }
        if letterCount < 12 {
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
            guard LyricLanguageCodePolicy.canonicalIdentifier(value) != nil else { continue }
            return languageIdentity(value)
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
        return !representsSameTranslationLanguage(
            detectedSourceLanguageCode,
            targetLanguageCode
        )
    }

    /// Primuse does not advertise or construct an Apple Translation session
    /// for Persian. Persian lyrics may use only the separately authorized
    /// intelligent/custom-provider route; unknown source languages continue to
    /// rely on the SDK's local availability check.
    public static func permitsAppleSystemTranslation(
        sourceLanguageCode: String?,
        targetLanguageCode: String
    ) -> Bool {
        guard primaryLanguageCode(languageIdentity(targetLanguageCode)) != "fa" else {
            return false
        }
        guard let sourceLanguageCode else { return true }
        return primaryLanguageCode(languageIdentity(sourceLanguageCode)) != "fa"
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
            if let normalizedSource,
               representsSameTranslationLanguage(normalizedSource, targetIdentity) {
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
        let rawNormalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        let rawParts = rawNormalized.split(separator: "-").map(String.init)
        if rawParts.first?.lowercased() == "zh" {
            let lower = rawNormalized.lowercased()
            if lower.contains("hant") || lower.contains("-tw")
                || lower.contains("-hk") || lower.contains("-mo") {
                return "zh-Hant"
            }
            if lower.contains("hans") || lower.contains("-cn")
                || lower.contains("-sg") {
                return "zh-Hans"
            }
        }

        let normalized = LyricLanguageCodePolicy.canonicalIdentifier(raw) ?? rawNormalized
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

    /// Translation equivalence is slightly broader than storage identity.
    /// Persian's ordinary Arabic script may be written explicitly as
    /// `fa-Arab`; it is the same translation language as `fa`. A Latin-script
    /// Persian transliteration remains distinct so it can still request a
    /// script conversion. Chinese script variants likewise remain distinct.
    public static func representsSameTranslationLanguage(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        let left = languageIdentity(lhs)
        let right = languageIdentity(rhs)
        if left == right { return true }
        guard primaryLanguageCode(left) == "fa",
              primaryLanguageCode(right) == "fa" else {
            return false
        }
        func isOrdinaryPersianScript(_ identity: String) -> Bool {
            let parts = identity.lowercased().split(separator: "-")
            guard parts.count > 1 else { return true }
            return parts[1] == "arab"
        }
        return isOrdinaryPersianScript(left) && isOrdinaryPersianScript(right)
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

    private static func primaryLanguageCode(_ identity: String) -> String {
        identity.split(separator: "-", maxSplits: 1).first.map(String.init) ?? identity
    }

    private static func isPersianArabicScript(_ identity: String?) -> Bool {
        guard let identity, primaryLanguageCode(identity) == "fa" else { return false }
        return !identity.lowercased().contains("-latn")
    }

    private enum LineScript: Hashable {
        case latin
        case han
        case japanese
        case hangul
        case arabic
        case hebrew
        case cyrillic
        case devanagari
        case thai
    }

    private static func hasDistinctScriptEvidence(
        text: String,
        languageCode: String,
        comparedWith otherLanguageCode: String
    ) -> Bool {
        guard let expectedScript = lineScript(for: languageCode),
              let otherScript = lineScript(for: otherLanguageCode),
              expectedScript != otherScript else {
            return false
        }
        return textHasScriptEvidence(expectedScript, text: text)
    }

    private static func lineScript(for languageCode: String) -> LineScript? {
        let identity = languageIdentity(languageCode)
        let lowercasedIdentity = identity.lowercased()
        let subtags = lowercasedIdentity.split(separator: "-").map(String.init)
        if let explicitScript = subtags.dropFirst().first(where: { $0.count == 4 }) {
            switch explicitScript {
            case "latn": return .latin
            case "hans", "hant", "hani": return .han
            case "jpan", "kana", "hira": return .japanese
            case "kore", "hang": return .hangul
            case "arab": return .arabic
            case "hebr": return .hebrew
            case "cyrl": return .cyrillic
            case "deva": return .devanagari
            case "thai": return .thai
            default: break
            }
        }

        guard let primary = subtags.first else { return nil }
        switch primary {
        case "zh":
            return .han
        case "ja":
            return .japanese
        case "ko":
            return .hangul
        case "ar", "fa", "ps", "sd", "ug", "ur":
            return .arabic
        case "he", "yi":
            return .hebrew
        case "be", "bg", "kk", "ky", "mk", "mn", "ru", "sr", "uk":
            return .cyrillic
        case "hi", "mr", "ne", "sa":
            return .devanagari
        case "th":
            return .thai
        case "af", "az", "ca", "cs", "cy", "da", "de", "en", "es", "et",
             "eu", "fi", "fr", "ga", "gl", "hr", "hu", "id", "is", "it",
             "la", "lt", "lv", "ms", "nb", "nl", "nn", "no", "pl", "pt",
             "ro", "sk", "sl", "sq", "sv", "sw", "tl", "tr", "uz", "vi":
            return .latin
        default:
            return nil
        }
    }

    private static func textHasScriptEvidence(_ expected: LineScript, text: String) -> Bool {
        var totalAlphabeticCount = 0
        var counts: [LineScript: Int] = [:]
        var hanCount = 0
        var kanaCount = 0

        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            totalAlphabeticCount += 1
            guard let script = lineScript(for: scalar.value) else { continue }
            switch script {
            case .han:
                hanCount += 1
            case .japanese:
                kanaCount += 1
            default:
                counts[script, default: 0] += 1
            }
        }
        counts[.han] = hanCount
        counts[.japanese] = hanCount + kanaCount

        let expectedCount: Int
        if expected == .japanese {
            guard kanaCount > 0 else { return false }
            expectedCount = counts[.japanese, default: 0]
        } else {
            expectedCount = counts[expected, default: 0]
        }
        return expectedCount >= 2
            && totalAlphabeticCount > 0
            && Double(expectedCount) / Double(totalAlphabeticCount) >= 0.7
    }

    private static func lineScript(for value: UInt32) -> LineScript? {
        switch value {
        case 0x0041...0x005A, 0x0061...0x007A,
             0x00C0...0x024F, 0x1E00...0x1EFF,
             0xAB30...0xAB6F, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            return .latin
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x3134F:
            return .han
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D:
            return .japanese
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F,
             0xAC00...0xD7AF, 0xD7B0...0xD7FF:
            return .hangul
        case 0x0600...0x06FF, 0x0750...0x077F, 0x0870...0x089F,
             0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF:
            return .arabic
        case 0x0590...0x05FF, 0xFB1D...0xFB4F:
            return .hebrew
        case 0x0400...0x052F, 0x2DE0...0x2DFF, 0xA640...0xA69F:
            return .cyrillic
        case 0x0900...0x097F, 0xA8E0...0xA8FF:
            return .devanagari
        case 0x0E00...0x0E7F:
            return .thai
        default:
            return nil
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
