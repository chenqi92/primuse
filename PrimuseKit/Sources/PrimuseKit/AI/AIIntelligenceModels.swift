import Foundation

public enum AIProviderKind: String, Codable, CaseIterable, Sendable {
    case builtInLocal
    case openAICompatible
    case appleFoundationModels
    case coreML
}

/// Describes where inference happens. Regional policy is intentionally based
/// on this execution class instead of a provider brand so a future provider can
/// be added without accidentally bypassing the compliance gate.
public enum AIExecutionClass: String, Codable, CaseIterable, Sendable {
    case deterministicLocal
    case localDiscriminativeModel
    case localGenerativeModel
    case appleSystemModel
    case userConfiguredRemote
    case bundledRemote
}

public enum AICapability: String, Codable, CaseIterable, Sendable {
    case semanticSearchInterpretation
    case lyricsTranslation
    case audioTranscription
    case embeddings
    case reranking
    case songAnnotation
    case recommendations
    case commandInterpretation
}

public struct AIProviderDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String
    public var kind: AIProviderKind
    public var executionClass: AIExecutionClass
    public var capabilities: Set<AICapability>
    public var priority: Int
    public var isEnabled: Bool

    public init(
        id: UUID,
        displayName: String,
        kind: AIProviderKind,
        executionClass: AIExecutionClass,
        capabilities: Set<AICapability>,
        priority: Int = 0,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.executionClass = executionClass
        self.capabilities = capabilities
        self.priority = priority
        self.isEnabled = isEnabled
    }
}

public struct AIProviderModel: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var ownedBy: String?
    public var createdAt: Date?

    public init(id: String, ownedBy: String? = nil, createdAt: Date? = nil) {
        self.id = id
        self.ownedBy = ownedBy
        self.createdAt = createdAt
    }
}

public enum AIProviderRuntimeAvailability: Equatable, Sendable {
    case available
    case unavailable(AIProviderUnavailableReason)
}

public enum AIProviderUnavailableReason: String, Codable, Equatable, Sendable {
    case disabled
    case missingConfiguration
    case missingCredential
    case unsupportedDevice
    case modelNotReady
    case regionRestricted
    case temporarilyUnavailable
}

public struct AISemanticSearchRequest: Equatable, Sendable {
    public var query: String
    public var languageCode: String?
    public var maximumExpansionTerms: Int

    public init(
        query: String,
        languageCode: String? = nil,
        maximumExpansionTerms: Int = 8
    ) {
        self.query = query
        self.languageCode = languageCode
        self.maximumExpansionTerms = max(1, min(maximumExpansionTerms, 16))
    }
}

public struct AISemanticSearchPlan: Codable, Equatable, Sendable {
    public var expandedTerms: [String]
    public var themes: [String]
    public var moods: [String]

    public init(
        expandedTerms: [String] = [],
        themes: [String] = [],
        moods: [String] = []
    ) {
        self.expandedTerms = expandedTerms
        self.themes = themes
        self.moods = moods
    }

    public func normalized(for request: AISemanticSearchRequest) -> AISemanticSearchPlan {
        let original = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()

        func clean(_ values: [String], limit: Int) -> [String] {
            var output: [String] = []
            output.reserveCapacity(min(values.count, limit))
            for rawValue in values {
                let value = rawValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")
                guard !value.isEmpty,
                      value.count <= 48,
                      value.caseInsensitiveCompare(original) != .orderedSame else { continue }
                let key = value.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                )
                guard seen.insert(key).inserted else { continue }
                output.append(value)
                if output.count == limit { break }
            }
            return output
        }

        return AISemanticSearchPlan(
            expandedTerms: clean(expandedTerms, limit: request.maximumExpansionTerms),
            themes: clean(themes, limit: 6),
            moods: clean(moods, limit: 6)
        )
    }
}

public enum AISemanticSearchStreamEvent: Equatable, Sendable {
    case reset
    case term(String)
    case completed(AISemanticSearchPlan)
}

public enum AIRecommendationScene: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic
    case driving
    case focus
    case workout
    case relaxation
    case bedtime
}

/// A compact, stable vocabulary for the recommendation ribbon. The semantic
/// descriptions deliberately live outside localized display strings so every
/// provider receives the same intent regardless of the device language.
public enum AIRecommendationIntentPreset: String, Codable, CaseIterable, Hashable, Sendable {
    // Keep the original raw value so existing default selections remain valid
    // across upgrades while the user-facing vocabulary becomes strategy based.
    case balanced = "rightNow"
    case familiarContinuity
    case adjacentDiscovery
    case genreExploration
    case catalogRewind
    case recentCatalog

    public static var userManagedCases: [AIRecommendationIntentPreset] {
        allCases.filter { $0 != .balanced }
    }

    public var selectionID: String {
        "preset:\(rawValue)"
    }

    public var localizedTitle: String {
        PMString("ai_recommendation_intent_\(rawValue)")
    }

    public var localizedDetail: String {
        PMString("ai_recommendation_intent_\(rawValue)_detail")
    }

    public var semanticIntent: String? {
        switch self {
        case .balanced:
            return nil
        case .familiarContinuity:
            return "familiar continuity: favor artists and genres aligned with listening preferences; if preferences are sparse, keep a balanced and varied selection"
        case .adjacentDiscovery:
            return "adjacent discovery: favor artists outside listening preferences but near familiar genres or eras; if metadata is sparse, keep a balanced selection"
        case .genreExploration:
            return "genre exploration: favor genres outside dominant listening preferences and broaden variety; if genre metadata is sparse, keep a balanced selection"
        case .catalogRewind:
            return "catalog rewind: favor earlier known release years across several artists; if year is missing, use balanced selection without inferring age"
        case .recentCatalog:
            return "recent catalog: favor later known release years and artists outside listening preferences; if year is missing, use balanced selection"
        }
    }
}

public enum AIRecommendationIntentSelectionPolicy {
    public static let storageKey = "primuse.ai.recommendationIntent.selected.v1"
    public static let defaultSelectionID =
        "preset:\(AIRecommendationIntentPreset.balanced.rawValue)"

    private static let legacyPresetIDs: Set<String> = [
        "preset:nostalgia",
        "preset:unrequitedLove",
        "preset:nightDrive",
        "preset:quietFocus",
        "preset:rainySolitude",
    ]

    public static func normalizedSelectionID(_ selectionID: String) -> String {
        legacyPresetIDs.contains(selectionID) ? defaultSelectionID : selectionID
    }

    public static func normalizedSelectionID(
        _ selectionID: String,
        availableSelectionIDs: Set<String>
    ) -> String {
        let normalizedID = normalizedSelectionID(selectionID)
        guard !availableSelectionIDs.contains(normalizedID) else {
            return normalizedID
        }

        if normalizedID.hasPrefix("custom:") {
            return defaultSelectionID
        }
        if normalizedID.hasPrefix("preset:") {
            let rawValue = String(normalizedID.dropFirst("preset:".count))
            if AIRecommendationIntentPreset(rawValue: rawValue) != nil {
                return defaultSelectionID
            }
        }
        // Preserve preset IDs created by a newer app version so an older device
        // does not erase a forward-compatible cloud selection.
        return normalizedID
    }
}

public enum AIRecommendationIntentPresetVisibilityPolicy {
    public static let storageKey = "primuse.ai.recommendationIntent.hiddenPresets.v1"

    public static func hiddenPresets(_ rawValue: String) -> Set<AIRecommendationIntentPreset> {
        Set(rawValue.split(separator: ",").compactMap { value in
            guard let preset = AIRecommendationIntentPreset(rawValue: String(value)),
                  preset != .balanced else { return nil }
            return preset
        })
    }

    public static func encode(_ hiddenPresets: Set<AIRecommendationIntentPreset>) -> String {
        AIRecommendationIntentPreset.userManagedCases
            .filter { hiddenPresets.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    public static func visiblePresets(_ rawValue: String) -> [AIRecommendationIntentPreset] {
        let hidden = hiddenPresets(rawValue)
        return AIRecommendationIntentPreset.userManagedCases.filter { !hidden.contains($0) }
    }

    public static func hiding(
        _ preset: AIRecommendationIntentPreset,
        in rawValue: String
    ) -> String {
        guard preset != .balanced else { return encode(hiddenPresets(rawValue)) }
        var hidden = hiddenPresets(rawValue)
        hidden.insert(preset)
        return encode(hidden)
    }

    public static func restoringAll() -> String {
        ""
    }
}

public struct AIRecommendationIntentDetails: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var prompt: String?

    public init(id: String, title: String, detail: String, prompt: String?) {
        self.id = id
        self.title = title
        self.detail = detail
        self.prompt = prompt
    }
}

public extension AIRecommendationIntentPreset {
    var intentDetails: AIRecommendationIntentDetails {
        AIRecommendationIntentDetails(
            id: selectionID,
            title: localizedTitle,
            detail: localizedDetail,
            prompt: semanticIntent
        )
    }
}

public extension AICustomRecommendationIntent {
    var selectionID: String {
        "custom:\(id.uuidString)"
    }

    var intentDetails: AIRecommendationIntentDetails {
        AIRecommendationIntentDetails(
            id: selectionID,
            title: title,
            detail: prompt,
            prompt: prompt
        )
    }
}

public struct AICustomRecommendationIntent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var prompt: String

    public init(id: UUID = UUID(), title: String, prompt: String) {
        self.id = id
        self.title = title
        self.prompt = prompt
    }
}

public enum AIRecommendationIntentStoragePolicy {
    public static let storageKey = "primuse.ai.recommendationIntents.v1"
    public static let maximumCustomIntents = 12
    public static let maximumTitleLength = 24
    public static let maximumPromptLength = 160

    public static func decode(_ rawValue: String) -> [AICustomRecommendationIntent] {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(
                [AICustomRecommendationIntent].self,
                from: data
              ) else { return [] }
        return normalized(decoded)
    }

    public static func encode(_ intents: [AICustomRecommendationIntent]) -> String {
        guard let data = try? JSONEncoder().encode(normalized(intents)) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func makeIntent(
        id: UUID = UUID(),
        title: String,
        prompt: String
    ) -> AICustomRecommendationIntent? {
        let title = clean(title, limit: maximumTitleLength)
        let prompt = clean(prompt, limit: maximumPromptLength)
        guard !title.isEmpty, !prompt.isEmpty else { return nil }
        return AICustomRecommendationIntent(id: id, title: title, prompt: prompt)
    }

    private static func normalized(
        _ intents: [AICustomRecommendationIntent]
    ) -> [AICustomRecommendationIntent] {
        var seenIDs = Set<UUID>()
        var seenTitles = Set<String>()
        var output: [AICustomRecommendationIntent] = []
        for intent in intents {
            guard seenIDs.insert(intent.id).inserted,
                  let value = makeIntent(
                    id: intent.id,
                    title: intent.title,
                    prompt: intent.prompt
                  ) else { continue }
            let titleKey = value.title.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seenTitles.insert(titleKey).inserted else { continue }
            output.append(value)
            if output.count == maximumCustomIntents { break }
        }
        return output
    }

    private static func clean(_ rawValue: String, limit: Int) -> String {
        let value = rawValue
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(limit))
    }
}

public enum AIRecommendationSceneResolver {
    public static func resolved(
        _ scene: AIRecommendationScene,
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> AIRecommendationScene {
        guard scene == .automatic else { return scene }
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let isWeekday = (2...6).contains(weekday)
        if hour >= 22 || hour < 6 { return .bedtime }
        if isWeekday, (6..<10).contains(hour) || (17..<20).contains(hour) {
            return .driving
        }
        if isWeekday, (10..<17).contains(hour) { return .focus }
        return .relaxation
    }
}

public struct AIRecommendationPreference: Codable, Hashable, Sendable {
    public var title: String
    public var artist: String
    public var genre: String?
    public var playCount: Int

    public init(title: String, artist: String, genre: String? = nil, playCount: Int) {
        self.title = title
        self.artist = artist
        self.genre = genre
        self.playCount = playCount
    }
}

public struct AIRecommendationCandidate: Identifiable, Codable, Hashable, Sendable {
    public var songID: String
    public var title: String
    public var artist: String
    public var genre: String?
    public var year: Int?
    public var durationSeconds: Int

    public var id: String { songID }

    public init(
        songID: String,
        title: String,
        artist: String,
        genre: String? = nil,
        year: Int? = nil,
        durationSeconds: Int = 0
    ) {
        self.songID = songID
        self.title = title
        self.artist = artist
        self.genre = genre
        self.year = year
        self.durationSeconds = durationSeconds
    }
}

public struct AIRecommendationRequest: Hashable, Sendable {
    public var scene: AIRecommendationScene
    public var intent: String?
    public var languageCode: String?
    public var preferences: [AIRecommendationPreference]
    public var candidates: [AIRecommendationCandidate]
    public var maximumResults: Int
    public var minimumResults: Int

    public init(
        scene: AIRecommendationScene,
        intent: String? = nil,
        languageCode: String? = nil,
        preferences: [AIRecommendationPreference],
        candidates: [AIRecommendationCandidate],
        maximumResults: Int = 12,
        minimumResults: Int = 10
    ) {
        self.scene = scene
        let normalizedIntent = intent?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedIntent, !normalizedIntent.isEmpty {
            self.intent = String(normalizedIntent.prefix(160))
        } else {
            self.intent = nil
        }
        self.languageCode = languageCode
        self.preferences = Array(preferences.prefix(12))
        self.candidates = Array(candidates.prefix(36))
        let availableResultCount = max(1, self.candidates.count)
        self.maximumResults = max(1, min(min(maximumResults, 12), availableResultCount))
        self.minimumResults = max(1, min(minimumResults, self.maximumResults))
    }
}

public struct AIRecommendationSelection: Codable, Hashable, Sendable {
    public var songID: String
    public var reason: String

    public init(songID: String, reason: String) {
        self.songID = songID
        self.reason = reason
    }
}

public struct AIRecommendationPlan: Codable, Hashable, Sendable {
    public var summary: String
    public var selections: [AIRecommendationSelection]

    public init(summary: String = "", selections: [AIRecommendationSelection] = []) {
        self.summary = summary
        self.selections = selections
    }

    public func normalized(for request: AIRecommendationRequest) -> AIRecommendationPlan {
        let allowedIDs = Set(request.candidates.map(\.songID))
        var seen = Set<String>()
        let selections = selections.compactMap { selection -> AIRecommendationSelection? in
            guard allowedIDs.contains(selection.songID), seen.insert(selection.songID).inserted else {
                return nil
            }
            let reason = selection.reason
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            guard !reason.isEmpty else { return nil }
            return AIRecommendationSelection(
                songID: selection.songID,
                reason: String(reason.prefix(120))
            )
        }
        let limitedSelections = Array(selections.prefix(request.maximumResults))
        let availableArtistCount = Set(request.candidates.map(Self.artistIdentity)).count
        let selectedArtistCounts = Dictionary(
            grouping: limitedSelections,
            by: { selection in
                guard let candidate = request.candidates.first(where: {
                    $0.songID == selection.songID
                }) else { return "song:\(selection.songID)" }
                return Self.artistIdentity(candidate)
            }
        ).mapValues(\.count)
        let requiredArtistCount = min(4, min(availableArtistCount, limitedSelections.count))
        let hasRequiredCount = limitedSelections.count >= request.minimumResults
        let isSufficientlyDiverse = hasRequiredCount
            && selectedArtistCounts.count >= requiredArtistCount
            && (availableArtistCount < 4 || (selectedArtistCounts.values.max() ?? 0) <= 2)

        return AIRecommendationPlan(
            summary: String(
                summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180)
            ),
            selections: isSufficientlyDiverse ? limitedSelections : []
        )
    }

    private static func artistIdentity(_ candidate: AIRecommendationCandidate) -> String {
        let artist = candidate.artist
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return artist.isEmpty ? "song:\(candidate.songID)" : artist
    }
}

public enum AIRecommendationStreamEvent: Hashable, Sendable {
    case reset
    case selection(AIRecommendationSelection)
    case completed(AIRecommendationPlan)
}

public enum AILyricsTranslationStreamEvent: Equatable, Sendable {
    case reset
    case translation(id: String, text: String)
    case completed([String: String])
}

public struct AIRecommendationRefreshState: Hashable, Sendable {
    public var contentRevision: String
    public var isSceneActive: Bool

    public init(contentRevision: String, isSceneActive: Bool) {
        self.contentRevision = contentRevision
        self.isSceneActive = isSceneActive
    }

    public var shouldRefresh: Bool {
        isSceneActive
    }
}

public struct AISemanticLibraryMatchCandidate: Equatable, Sendable {
    public var songID: String
    public var title: String
    public var score: Int
    public var relatedConcept: String
    public var conceptOrder: Int

    public init(
        songID: String,
        title: String,
        score: Int,
        relatedConcept: String,
        conceptOrder: Int
    ) {
        self.songID = songID
        self.title = title
        self.score = score
        self.relatedConcept = relatedConcept
        self.conceptOrder = conceptOrder
    }
}

public enum AISemanticLibraryAggregationPolicy {
    public static func concepts(
        from plan: AISemanticSearchPlan,
        limit: Int = 8
    ) -> [String] {
        guard limit > 0 else { return [] }
        var concepts: [String] = []
        var keys = Set<String>()
        for rawValue in plan.expandedTerms + plan.themes + plan.moods {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = value.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard !value.isEmpty, keys.insert(key).inserted else { continue }
            concepts.append(value)
            if concepts.count == limit { break }
        }
        return concepts
    }

    public static func rankedMatches(
        _ candidates: [AISemanticLibraryMatchCandidate],
        limit: Int = 30
    ) -> [AISemanticLibraryMatchCandidate] {
        guard limit > 0 else { return [] }
        var bestBySongID: [String: AISemanticLibraryMatchCandidate] = [:]
        for candidate in candidates where !candidate.songID.isEmpty {
            guard let current = bestBySongID[candidate.songID] else {
                bestBySongID[candidate.songID] = candidate
                continue
            }
            if candidate.score > current.score
                || (candidate.score == current.score
                    && candidate.conceptOrder < current.conceptOrder) {
                bestBySongID[candidate.songID] = candidate
            }
        }

        let titleLocale = Locale(identifier: "en_US_POSIX")
        return Array(bestBySongID.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let titleOrder = lhs.title.compare(
                rhs.title,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: titleLocale
            )
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.songID < rhs.songID
        }.prefix(limit))
    }
}

public struct LibrarySearchComposition: Equatable, Sendable {
    public var primaryResultIDs: [String]
    public var intelligentSupplementIDs: [String]

    public init(primaryResultIDs: [String], intelligentSupplementIDs: [String]) {
        self.primaryResultIDs = primaryResultIDs
        self.intelligentSupplementIDs = intelligentSupplementIDs
    }
}

/// Keeps deterministic keyword matches as the complete primary result set and
/// treats semantic matches as an optional, deduplicated supplement.
public enum LibrarySearchCompositionPolicy {
    public static func compose(
        primaryResultIDs: [String],
        intelligentResultIDs: [String]?,
        intelligentAvailable: Bool,
        supplementLimit: Int = 30
    ) -> LibrarySearchComposition {
        var seenPrimary = Set<String>()
        let primary = primaryResultIDs.filter {
            !$0.isEmpty && seenPrimary.insert($0).inserted
        }
        guard intelligentAvailable,
              supplementLimit > 0,
              let intelligentResultIDs else {
            return LibrarySearchComposition(
                primaryResultIDs: primary,
                intelligentSupplementIDs: []
            )
        }

        var seen = seenPrimary
        var supplement: [String] = []
        supplement.reserveCapacity(min(supplementLimit, intelligentResultIDs.count))
        for id in intelligentResultIDs where !id.isEmpty && seen.insert(id).inserted {
            supplement.append(id)
            if supplement.count == supplementLimit { break }
        }
        return LibrarySearchComposition(
            primaryResultIDs: primary,
            intelligentSupplementIDs: supplement
        )
    }
}

public struct AIEmbeddingRequest: Equatable, Sendable {
    public var texts: [String]
    public var dimensions: Int?

    public init(texts: [String], dimensions: Int? = nil) {
        self.texts = texts
        self.dimensions = dimensions
    }
}

public struct AIAudioTranscriptionRequest: Equatable, Sendable {
    public var audioFileURL: URL
    public var mimeType: String
    public var displayName: String
    public var languageCodes: [String]
    public var customVocabulary: [String]

    public init(
        audioFileURL: URL,
        mimeType: String,
        displayName: String,
        languageCodes: [String] = [],
        customVocabulary: [String] = []
    ) {
        self.audioFileURL = audioFileURL
        self.mimeType = mimeType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = String(
            displayName
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(120)
        )
        self.languageCodes = Array(languageCodes.lazy.compactMap { rawValue in
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : String(value.prefix(24))
        }.prefix(4))
        var seenVocabulary = Set<String>()
        var sanitizedVocabulary: [String] = []
        sanitizedVocabulary.reserveCapacity(min(customVocabulary.count, 100))
        for rawValue in customVocabulary {
            guard sanitizedVocabulary.count < 100 else { break }
            let value = rawValue
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let boundedValue = String(value.prefix(100))
            let normalized = boundedValue.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard !boundedValue.isEmpty, seenVocabulary.insert(normalized).inserted else {
                continue
            }
            sanitizedVocabulary.append(boundedValue)
        }
        self.customVocabulary = sanitizedVocabulary
    }
}

public struct AIAudioTranscriptionWord: Codable, Equatable, Sendable {
    public var text: String
    public var startTime: TimeInterval
    public var endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = max(0, startTime.isFinite ? startTime : 0)
        self.endTime = max(self.startTime, endTime.isFinite ? endTime : self.startTime)
    }
}

public struct AIAudioTranscriptionResult: Codable, Equatable, Sendable {
    public var transcript: String
    public var words: [AIAudioTranscriptionWord]

    public init(transcript: String = "", words: [AIAudioTranscriptionWord] = []) {
        self.transcript = transcript
        self.words = words
    }

    public var isEmpty: Bool {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && words.isEmpty
    }
}

/// Turns provider word annotations into an editable ELRC document. The
/// grouping is deliberately deterministic so changing providers later does
/// not require rewriting the lyrics editor or playback renderer.
public enum AIAudioTranscriptionLyricsFormatter {
    public static func document(
        from result: AIAudioTranscriptionResult,
        maximumLineLength: Int = 32,
        maximumLineDuration: TimeInterval = 8
    ) -> LyricsEditorDocument {
        let words = result.words
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                return $0.endTime < $1.endTime
            }
        guard !words.isEmpty else {
            let lines = result.transcript
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: .newlines)
                .flatMap(splitPlainTranscript)
                .compactMap { rawValue -> EditableLyricLine? in
                    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    return value.isEmpty ? nil : EditableLyricLine(text: value)
                }
            return LyricsEditorDocument(lines: lines)
        }

        let lengthLimit = max(12, min(maximumLineLength, 80))
        let durationLimit = max(2, min(maximumLineDuration, 20))
        var groups: [[AIAudioTranscriptionWord]] = []
        var current: [AIAudioTranscriptionWord] = []

        func flush() {
            guard !current.isEmpty else { return }
            groups.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for word in words {
            if let first = current.first, let previous = current.last {
                let candidate = joinedText(current + [word])
                let duration = word.endTime - first.startTime
                let gap = word.startTime - previous.endTime
                if candidate.count > lengthLimit || duration > durationLimit || gap > 1.2 {
                    flush()
                }
            }
            current.append(word)
            if endsSentence(word.text), joinedText(current).count >= 8 {
                flush()
            }
        }
        flush()

        let lines = groups.compactMap { group -> EditableLyricLine? in
            guard let first = group.first else { return nil }
            let tokens = normalizedTokens(group)
            let text = tokens.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return EditableLyricLine(
                timestamp: first.startTime,
                text: text,
                syllables: zip(group, tokens).map { word, token in
                    LyricSyllable(
                        text: token,
                        start: word.startTime,
                        end: word.endTime
                    )
                }
            )
        }
        return LyricsEditorDocument(lines: lines)
    }

    private static func splitPlainTranscript(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var output: [String] = []
        var current = ""
        for character in trimmed {
            current.append(character)
            if endsSentence(String(character)) || current.count >= 48 {
                output.append(current)
                current = ""
            }
        }
        if !current.isEmpty { output.append(current) }
        return output
    }

    private static func joinedText(_ words: [AIAudioTranscriptionWord]) -> String {
        normalizedTokens(words).joined()
    }

    private static func normalizedTokens(_ words: [AIAudioTranscriptionWord]) -> [String] {
        var output: [String] = []
        for word in words {
            let value = word.text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let needsSpace = output.last.map { previous in
                guard let previousCharacter = previous.last,
                      let nextCharacter = value.first else { return false }
                return !isCJK(previousCharacter)
                    && !isCJK(nextCharacter)
                    && !isClosingPunctuation(nextCharacter)
                    && !previousCharacter.isWhitespace
            } ?? false
            output.append((needsSpace ? " " : "") + value)
        }
        return output
    }

    private static func endsSentence(_ value: String) -> Bool {
        guard let character = value.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return ".!?。！？；;".contains(character)
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        ",.!?:;，。！？：；、)]}）】》」』".contains(character)
    }

    private static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            (0x2E80...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0x20000...0x2FA1F).contains(scalar.value)
        }
    }
}

public struct AIEmbeddingResult: Equatable, Sendable {
    public var vectors: [[Float]]
    public var model: String

    public init(vectors: [[Float]], model: String) {
        self.vectors = vectors
        self.model = model
    }
}

public protocol MusicIntelligenceProvider: Sendable {
    var descriptor: AIProviderDescriptor { get }
    func runtimeAvailability() async -> AIProviderRuntimeAvailability
}

public protocol AISemanticSearchProviding: MusicIntelligenceProvider {
    func interpretSearch(_ request: AISemanticSearchRequest) async throws -> AISemanticSearchPlan
}

public protocol AIRecommendationProviding: MusicIntelligenceProvider {
    func recommendations(_ request: AIRecommendationRequest) async throws -> AIRecommendationPlan
}

public protocol AILyricsTranslationProviding: MusicIntelligenceProvider {
    func translateLyrics(
        _ candidates: [LyricTranslationCandidate],
        targetLanguageCode: String
    ) async throws -> [String: String]
}

public protocol AIAudioTranscriptionProviding: MusicIntelligenceProvider {
    func transcribeAudio(
        _ request: AIAudioTranscriptionRequest
    ) async throws -> AIAudioTranscriptionResult
}

public protocol AIEmbeddingProviding: MusicIntelligenceProvider {
    func embeddings(_ request: AIEmbeddingRequest) async throws -> AIEmbeddingResult
}

public enum MusicIntelligenceError: Error, Equatable, Sendable {
    case unavailable(AIProviderUnavailableReason)
    case invalidConfiguration
    case invalidResponse
    case requestFailed(statusCode: Int)
    case timedOut
}
