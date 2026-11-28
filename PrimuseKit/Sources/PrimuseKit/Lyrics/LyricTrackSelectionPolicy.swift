import Foundation

/// Distinguishes a subtitle translation displayed beneath the primary lyrics
/// from a replacement primary-language track (Apple Music TTML
/// `<translation type="replacement">` and OpenSubsonic `structuredLyrics[].type`).
public enum LyricManualTranslationKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Displayed beneath the primary lyric line (`type="subtitle"`).
    case subtitle
    /// Replaces the displayed primary lyric line (`type="replacement"`).
    case replacement

    /// Parses a TTML or OpenSubsonic track `type` attribute. Omitted and
    /// unknown values default to `.subtitle` for backward compatibility.
    public static func fromTrackType(_ raw: String?) -> LyricManualTranslationKind {
        guard let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return .subtitle
        }
        return normalized == "replacement" ? .replacement : .subtitle
    }
}

extension LyricManualTranslation: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, text, languageCode, source, syllables, kind
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let text = try container.decode(String.self, forKey: .text)
        let languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)
        let source = try container.decode(LyricManualTranslationSource.self, forKey: .source)
        let syllables = try container.decodeIfPresent([LyricSyllable].self, forKey: .syllables)
        let kind = (try? container.decodeIfPresent(LyricManualTranslationKind.self, forKey: .kind)) ?? .subtitle
        self.init(
            id: id,
            text: text,
            languageCode: languageCode,
            source: source,
            syllables: syllables,
            kind: kind
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(languageCode, forKey: .languageCode)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(syllables, forKey: .syllables)
        if kind != .subtitle {
            try container.encode(kind, forKey: .kind)
        }
    }
}

/// An additional authored transliteration/pronunciation track when a lyric
/// document carries more than one `<transliteration xml:lang="...">` or
/// OpenSubsonic pronunciation track.
public struct LyricTransliteration: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var text: String {
        didSet { if text != oldValue { syllables = nil } }
    }
    public var languageCode: String?
    public var syllables: [LyricSyllable]?

    public init(
        id: String = UUID().uuidString,
        text: String,
        languageCode: String? = nil,
        syllables: [LyricSyllable]? = nil
    ) {
        self.id = id
        self.text = text
        self.languageCode = languageCode
        self.syllables = syllables
    }
}

public extension LyricLine {
    /// Authored subtitle translations (`kind == .subtitle`) attached to this line.
    var subtitleTranslations: [LyricManualTranslation] {
        allManualTranslations.filter { $0.kind == .subtitle }
    }

    /// Authored primary-language replacement tracks (`kind == .replacement`) attached to this line.
    var replacementTracks: [LyricManualTranslation] {
        allManualTranslations.filter { $0.kind == .replacement }
    }

    /// All authored transliterations on this line, starting with the primary
    /// `romanization` field followed by any `alternateRomanizations`.
    var allTransliterations: [LyricTransliteration] {
        var items: [LyricTransliteration] = []
        if let primary = romanization,
           !primary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(LyricTransliteration(
                id: "\(id)#roman:0",
                text: primary,
                languageCode: romanizationLanguageCode,
                syllables: romanizationSyllables
            ))
        }
        items.append(contentsOf: alternateRomanizations)
        return items
    }
}

/// One selectable track within a lyric document (replacement primary track,
/// subtitle translation language, or authored transliteration language).
public struct LyricTrackOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let languageCode: String?

    public init(id: String, languageCode: String?) {
        self.id = id
        self.languageCode = languageCode
    }

    public var isUntagged: Bool { languageCode == nil }
}

/// Summary of all selectable primary-language, subtitle-translation, and
/// transliteration tracks present in a song's lyric document.
public struct LyricTrackCatalog: Equatable, Hashable, Sendable {
    public var originalLanguageCode: String?
    public var replacementTracks: [LyricTrackOption]
    public var subtitleTracks: [LyricTrackOption]
    public var transliterationTracks: [LyricTrackOption]
    public var includesGeneratedTransliteration: Bool

    public init(
        originalLanguageCode: String? = nil,
        replacementTracks: [LyricTrackOption] = [],
        subtitleTracks: [LyricTrackOption] = [],
        transliterationTracks: [LyricTrackOption] = [],
        includesGeneratedTransliteration: Bool = false
    ) {
        self.originalLanguageCode = originalLanguageCode
        self.replacementTracks = replacementTracks
        self.subtitleTracks = subtitleTracks
        self.transliterationTracks = transliterationTracks
        self.includesGeneratedTransliteration = includesGeneratedTransliteration
    }

    public static let empty = LyricTrackCatalog()

    public var hasReplacementTracks: Bool { !replacementTracks.isEmpty }
    public var hasSubtitleTracks: Bool { !subtitleTracks.isEmpty }
    public var hasTransliteration: Bool {
        !transliterationTracks.isEmpty || includesGeneratedTransliteration
    }

    public var isEmpty: Bool {
        !hasReplacementTracks && !hasSubtitleTracks && !hasTransliteration
    }

    public var tracks: LyricBundledTranslationPolicy.Tracks {
        var result: LyricBundledTranslationPolicy.Tracks = []
        if hasSubtitleTracks { result.insert(.translation) }
        if hasTransliteration { result.insert(.romanization) }
        if hasReplacementTracks { result.insert(.replacement) }
        return result
    }

    public func withGeneratedTransliteration(_ available: Bool) -> LyricTrackCatalog {
        var copy = self
        copy.includesGeneratedTransliteration = available
        return copy
    }
}

/// User track picks for a single song. `nil` means default/automatic behavior.
public struct LyricTrackSelection: Equatable, Hashable, Sendable, Codable {
    public var replacementTrackID: String?
    public var subtitleTrackID: String?
    public var transliterationTrackID: String?

    public init(
        replacementTrackID: String? = nil,
        subtitleTrackID: String? = nil,
        transliterationTrackID: String? = nil
    ) {
        self.replacementTrackID = replacementTrackID
        self.subtitleTrackID = subtitleTrackID
        self.transliterationTrackID = transliterationTrackID
    }

    public static let automatic = LyricTrackSelection()

    public var isAutomatic: Bool {
        replacementTrackID == nil && subtitleTrackID == nil && transliterationTrackID == nil
    }
}

/// Catalogs and applies per-track selections (replacement primary language,
/// multi-language subtitle translations, and transliterations) onto display
/// lyric lines without mutating the cached source document.
public enum LyricTrackSelectionPolicy {
    public struct Presentation: Sendable {
        public var lines: [LyricLine]
        public var tracks: LyricBundledTranslationPolicy.Tracks
        public var readingTranslationIDs: Set<String>
        public var catalog: LyricTrackCatalog
        public var activeReplacementTrackID: String?
        public var activeSubtitleTrackID: String?
        public var activeSubtitleLanguageCode: String?
        public var activeTransliterationTrackID: String?

        public var hasBundledTranslations: Bool { tracks.contains(.translation) }
    }

    private static let pinnedSubtitleMetadataPrefix = "[x-primuse-subtitle-lang:"
    private static let untaggedTrackID = "untagged"

    public static func trackID(forLanguageCode raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return untaggedTrackID
        }
        let identity = LyricTranslationGroupingPolicy.languageIdentity(raw)
        return identity.isEmpty ? untaggedTrackID : "lang:\(identity.lowercased())"
    }

    /// Inspects a raw lyric document (including nested backing vocals) and
    /// discovers all selectable replacement, subtitle, and transliteration tracks.
    public static func catalog(
        for lines: [LyricLine],
        includesGeneratedTransliteration: Bool = false
    ) -> LyricTrackCatalog {
        let flattened = LyricVoiceTimelinePolicy.flattenedLines(lines)
        let hasManual = flattened.contains {
            $0.manualTranslation != nil || !$0.alternateManualTranslations.isEmpty
        }
        let readingIDs = hasManual ? LyricRomanizedReadingPolicy.readingIDs(in: flattened) : []
        return catalog(
            inFlattened: flattened,
            sourceLines: lines,
            readingIDs: readingIDs,
            includesGeneratedTransliteration: includesGeneratedTransliteration
        )
    }

    /// Produces display-ready lyric lines for the chosen primary replacement,
    /// subtitle language, and transliteration tracks.
    public static func presenting(
        _ lines: [LyricLine],
        selection: LyricTrackSelection,
        showsBundledTranslations: Bool,
        targetLanguageCode: String? = nil,
        preferredLanguages: [String] = []
    ) -> Presentation {
        let flattened = LyricVoiceTimelinePolicy.flattenedLines(lines)
        let hasManual = flattened.contains {
            $0.manualTranslation != nil || !$0.alternateManualTranslations.isEmpty
        }
        let readingIDs = hasManual ? LyricRomanizedReadingPolicy.readingIDs(in: flattened) : []
        let catalog = catalog(
            inFlattened: flattened,
            sourceLines: lines,
            readingIDs: readingIDs,
            includesGeneratedTransliteration: false
        )

        let activeReplacementID = selection.replacementTrackID.flatMap { id in
            catalog.replacementTracks.contains(where: { $0.id == id }) ? id : nil
        }

        let explicitSubtitleID = selection.subtitleTrackID.flatMap { id in
            catalog.subtitleTracks.contains(where: { $0.id == id }) ? id : nil
        }
        let activeSubtitleID: String? = showsBundledTranslations
            ? resolvedSubtitleTrackID(
                in: catalog,
                selected: explicitSubtitleID,
                targetLanguageCode: targetLanguageCode,
                preferredLanguages: preferredLanguages
            )
            : nil
        let activeSubtitleLanguage = activeSubtitleID.flatMap { id in
            catalog.subtitleTracks.first(where: { $0.id == id })?.languageCode
        }

        let activeTransliterationID = resolvedTransliterationTrackID(
            in: catalog,
            selected: selection.transliterationTrackID
        )

        let needsSubtitleFilter = catalog.hasSubtitleTracks && (
            !showsBundledTranslations
                || explicitSubtitleID != nil
                || catalog.subtitleTracks.count > 1
        )
        let needsTransliterationSwitch = activeTransliterationID != nil
            && activeTransliterationID != catalog.transliterationTracks.first?.id

        var displayed = lines
        if activeReplacementID != nil || catalog.hasReplacementTracks
            || needsSubtitleFilter || needsTransliterationSwitch {
            displayed = lines.map {
                transformLine(
                    $0,
                    activeReplacementID: activeReplacementID,
                    showsBundledTranslations: showsBundledTranslations,
                    activeSubtitleID: activeSubtitleID,
                    explicitSubtitleSelected: explicitSubtitleID != nil,
                    filterSingleSubtitleTrack: catalog.subtitleTracks.count > 1 || explicitSubtitleID != nil,
                    activeTransliterationID: needsTransliterationSwitch ? activeTransliterationID : nil,
                    readingIDs: readingIDs
                )
            }
        }

        if showsBundledTranslations,
           explicitSubtitleID != nil,
           let pinnedLanguage = activeSubtitleLanguage,
           !displayed.isEmpty {
            var metadata = displayed[0].metadataLines ?? []
            metadata.removeAll { $0.hasPrefix(pinnedSubtitleMetadataPrefix) }
            metadata.append("\(pinnedSubtitleMetadataPrefix)\(pinnedLanguage)]")
            displayed[0].metadataLines = metadata
        }

        return Presentation(
            lines: displayed,
            tracks: catalog.tracks,
            readingTranslationIDs: readingIDs,
            catalog: catalog,
            activeReplacementTrackID: activeReplacementID,
            activeSubtitleTrackID: activeSubtitleID,
            activeSubtitleLanguageCode: activeSubtitleLanguage,
            activeTransliterationTrackID: activeTransliterationID
        )
    }

    /// Resolves which subtitle track is active when `showsBundledTranslations`
    /// is enabled: explicit user pick first, then `targetLanguageCode`, then
    /// `preferredLanguages`, then the first available subtitle track.
    public static func resolvedSubtitleTrackID(
        in catalog: LyricTrackCatalog,
        selected: String?,
        targetLanguageCode: String? = nil,
        preferredLanguages: [String] = []
    ) -> String? {
        guard !catalog.subtitleTracks.isEmpty else { return nil }
        if let selected, catalog.subtitleTracks.contains(where: { $0.id == selected }) {
            return selected
        }
        if let targetLanguageCode,
           let matched = matchingTrack(in: catalog.subtitleTracks, languageCode: targetLanguageCode) {
            return matched.id
        }
        for preferred in preferredLanguages {
            if let matched = matchingTrack(in: catalog.subtitleTracks, languageCode: preferred) {
                return matched.id
            }
        }
        return catalog.subtitleTracks.first?.id
    }

    public static func resolvedTransliterationTrackID(
        in catalog: LyricTrackCatalog,
        selected: String?
    ) -> String? {
        guard !catalog.transliterationTracks.isEmpty else { return nil }
        if let selected, catalog.transliterationTracks.contains(where: { $0.id == selected }) {
            return selected
        }
        return catalog.transliterationTracks.first?.id
    }

    /// Reads the display-only pinned subtitle language stamped when the user
    /// explicitly selected a bundled subtitle track in the top bar.
    public static func pinnedSubtitleLanguageCode(in lines: [LyricLine]) -> String? {
        guard let metadata = lines.first?.metadataLines else { return nil }
        for entry in metadata where entry.hasPrefix(pinnedSubtitleMetadataPrefix) && entry.hasSuffix("]") {
            let start = entry.index(entry.startIndex, offsetBy: pinnedSubtitleMetadataPrefix.count)
            let end = entry.index(before: entry.endIndex)
            let value = String(entry[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// Localized display name for a language tag (e.g. `zh-Hans`, `en-US`, `ja-Latn`).
    public static func displayName(
        forLanguageCode languageCode: String?,
        fallback: String,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard let languageCode,
              !languageCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        if let localized = locale.localizedString(forIdentifier: languageCode),
           !localized.isEmpty {
            return localized
        }
        let identity = LyricTranslationGroupingPolicy.languageIdentity(languageCode)
        if !identity.isEmpty,
           let localized = locale.localizedString(forIdentifier: identity),
           !localized.isEmpty {
            return localized
        }
        return languageCode
    }

    /// Display label for the original primary lyrics option inside the Language menu.
    /// Falls back to `originalFallback` when untagged or when its localized name
    /// would collide with a replacement track's label.
    public static func originalDisplayName(
        for catalog: LyricTrackCatalog,
        originalFallback: String,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard let originalCode = catalog.originalLanguageCode else {
            return originalFallback
        }
        let label = displayName(forLanguageCode: originalCode, fallback: originalFallback, locale: locale)
        let replacementLabels = Set(catalog.replacementTracks.map {
            displayName(forLanguageCode: $0.languageCode, fallback: "", locale: locale).lowercased()
        })
        return replacementLabels.contains(label.lowercased()) ? originalFallback : label
    }

    // MARK: - Private helpers

    private static func catalog(
        inFlattened flattened: [LyricLine],
        sourceLines: [LyricLine],
        readingIDs: Set<String>,
        includesGeneratedTransliteration: Bool
    ) -> LyricTrackCatalog {
        let declaredMetadataLanguage = sourceLines.lazy
            .compactMap(\.metadataLines)
            .compactMap(LyricManualTranslationPolicy.declaredLanguageCode(in:))
            .first
        let originalLanguage = declaredMetadataLanguage
            ?? flattened.first(where: { $0.languageCode != nil })?.languageCode

        var replacementTracks: [LyricTrackOption] = []
        var replacementSeen = Set<String>()
        var subtitleTracks: [LyricTrackOption] = []
        var subtitleSeen = Set<String>()
        var transliterationTracks: [LyricTrackOption] = []
        var transliterationSeen = Set<String>()

        func record(_ option: LyricTrackOption, into list: inout [LyricTrackOption], seen: inout Set<String>) {
            guard seen.insert(option.id).inserted else { return }
            list.append(option)
        }

        for line in flattened {
            for translation in line.allManualTranslations {
                let text = translation.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if readingIDs.contains(translation.id) {
                    record(
                        LyricTrackOption(id: untaggedTrackID, languageCode: nil),
                        into: &transliterationTracks,
                        seen: &transliterationSeen
                    )
                    continue
                }
                let id = trackID(forLanguageCode: translation.languageCode)
                let option = LyricTrackOption(id: id, languageCode: translation.languageCode)
                switch translation.kind {
                case .replacement:
                    record(option, into: &replacementTracks, seen: &replacementSeen)
                case .subtitle:
                    record(option, into: &subtitleTracks, seen: &subtitleSeen)
                }
            }
            for reading in line.allTransliterations {
                let id = trackID(forLanguageCode: reading.languageCode)
                record(
                    LyricTrackOption(id: id, languageCode: reading.languageCode),
                    into: &transliterationTracks,
                    seen: &transliterationSeen
                )
            }
        }

        return LyricTrackCatalog(
            originalLanguageCode: originalLanguage,
            replacementTracks: replacementTracks,
            subtitleTracks: subtitleTracks,
            transliterationTracks: transliterationTracks,
            includesGeneratedTransliteration: includesGeneratedTransliteration
        )
    }

    private static func matchingTrack(
        in tracks: [LyricTrackOption],
        languageCode: String
    ) -> LyricTrackOption? {
        if let exact = tracks.first(where: { track in
            guard let code = track.languageCode else { return false }
            return LyricTranslationGroupingPolicy.representsSameTranslationLanguage(code, languageCode)
        }) {
            return exact
        }
        let requestedPrimary = languageCode
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first?
            .lowercased()
        guard let requestedPrimary, requestedPrimary != "zh" else { return nil }
        return tracks.first { track in
            track.languageCode?
                .replacingOccurrences(of: "_", with: "-")
                .split(separator: "-")
                .first?
                .lowercased() == requestedPrimary
        }
    }

    private static func transformLine(
        _ line: LyricLine,
        activeReplacementID: String?,
        showsBundledTranslations: Bool,
        activeSubtitleID: String?,
        explicitSubtitleSelected: Bool,
        filterSingleSubtitleTrack: Bool,
        activeTransliterationID: String?,
        readingIDs: Set<String>
    ) -> LyricLine {
        var result = line

        // 1. Primary language replacement (text + word-level syllables)
        if let activeReplacementID,
           let replacement = line.replacementTracks.first(where: {
               trackID(forLanguageCode: $0.languageCode) == activeReplacementID
                   && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
           }) {
            let trimmed = replacement.text.trimmingCharacters(in: .whitespacesAndNewlines)
            result.endTimestamp = line.endTime
            result.text = trimmed
            result.syllables = validatedSyllables(replacement.syllables, matching: trimmed)
            if let replacementLanguage = replacement.languageCode {
                result.languageCode = replacementLanguage
            }
        }

        // 2. Subtitle translations (never keep `.replacement` entries on display lines)
        let readings = line.allManualTranslations.filter { readingIDs.contains($0.id) }
        let subtitles = line.subtitleTranslations.filter { !readingIDs.contains($0.id) }
        if !showsBundledTranslations {
            result.manualTranslation = readings.first
            result.alternateManualTranslations = Array(readings.dropFirst())
        } else if filterSingleSubtitleTrack, let activeSubtitleID {
            let selected = subtitles.filter { trackID(forLanguageCode: $0.languageCode) == activeSubtitleID }
            let combined: [LyricManualTranslation]
            if explicitSubtitleSelected {
                combined = selected + readings
            } else {
                let matched = selected.isEmpty ? Array(subtitles.prefix(1)) : selected
                combined = matched + readings
            }
            result.manualTranslation = combined.first
            result.alternateManualTranslations = Array(combined.dropFirst())
        } else {
            // Preserve all subtitle translations & readings, stripping only `.replacement`.
            let kept = line.allManualTranslations.filter {
                $0.kind == .subtitle || readingIDs.contains($0.id)
            }
            result.manualTranslation = kept.first
            result.alternateManualTranslations = Array(kept.dropFirst())
        }

        // 3. Multi-track transliteration selection
        if let activeTransliterationID,
           let chosen = line.allTransliterations.first(where: {
               trackID(forLanguageCode: $0.languageCode) == activeTransliterationID
           }) {
            result.romanization = chosen.text
            result.romanizationSyllables = validatedSyllables(chosen.syllables, matching: chosen.text)
            result.romanizationLanguageCode = chosen.languageCode
        }

        // 4. Recurse into nested backing vocals
        if let background = line.background {
            result.background = background.map {
                transformLine(
                    $0,
                    activeReplacementID: activeReplacementID,
                    showsBundledTranslations: showsBundledTranslations,
                    activeSubtitleID: activeSubtitleID,
                    explicitSubtitleSelected: explicitSubtitleSelected,
                    filterSingleSubtitleTrack: filterSingleSubtitleTrack,
                    activeTransliterationID: activeTransliterationID,
                    readingIDs: readingIDs
                )
            }
        }

        return result
    }

    private static func validatedSyllables(
        _ syllables: [LyricSyllable]?,
        matching expectedText: String
    ) -> [LyricSyllable]? {
        guard let syllables, !syllables.isEmpty else { return nil }
        guard syllables.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.end >= $0.start }) else {
            return nil
        }
        guard !zip(syllables, syllables.dropFirst()).contains(where: { $0.start > $1.start }) else {
            return nil
        }
        let joined = syllables.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard joined == expectedText else { return nil }
        return syllables
    }
}
