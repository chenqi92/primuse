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
    case lyricsGeneration
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
    case rightNow
    case nostalgia
    case unrequitedLove
    case nightDrive
    case quietFocus
    case rainySolitude

    public var semanticIntent: String? {
        switch self {
        case .rightNow:
            return nil
        case .nostalgia:
            return "nostalgic songs that evoke home, memory, distance, and returning"
        case .unrequitedLove:
            return "love that remains unspoken or unreturned, restrained and bittersweet"
        case .nightDrive:
            return "a flowing night drive with momentum, neon atmosphere, and no abrupt mood changes"
        case .quietFocus:
            return "quiet concentration with low distraction, steady pacing, and gentle energy"
        case .rainySolitude:
            return "rainy solitude, reflective stillness, and a soft sense of emotional distance"
        }
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

    public init(
        scene: AIRecommendationScene,
        intent: String? = nil,
        languageCode: String? = nil,
        preferences: [AIRecommendationPreference],
        candidates: [AIRecommendationCandidate],
        maximumResults: Int = 8
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
        self.maximumResults = max(1, min(maximumResults, 12))
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
        return AIRecommendationPlan(
            summary: String(
                summary.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180)
            ),
            selections: Array(selections.prefix(request.maximumResults))
        )
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

public struct AIEmbeddingRequest: Equatable, Sendable {
    public var texts: [String]
    public var dimensions: Int?

    public init(texts: [String], dimensions: Int? = nil) {
        self.texts = texts
        self.dimensions = dimensions
    }
}

public struct AILyricsGenerationRequest: Equatable, Sendable {
    public var songTitle: String
    public var albumTitle: String?
    public var genre: String?
    public var languageCode: String?
    public var maximumLines: Int

    public init(
        songTitle: String,
        albumTitle: String? = nil,
        genre: String? = nil,
        languageCode: String? = nil,
        maximumLines: Int = 24
    ) {
        self.songTitle = Self.clean(songTitle, limit: 160) ?? "Untitled"
        self.albumTitle = Self.clean(albumTitle, limit: 160)
        self.genre = Self.clean(genre, limit: 100)
        self.languageCode = Self.clean(languageCode, limit: 24)
        self.maximumLines = max(8, min(maximumLines, 48))
    }

    private static func clean(_ rawValue: String?, limit: Int) -> String? {
        let value = rawValue?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : String(value.prefix(limit))
    }
}

public struct AILyricsGenerationResult: Codable, Equatable, Sendable {
    public var draftTitle: String
    public var lines: [String]

    public init(draftTitle: String = "", lines: [String] = []) {
        self.draftTitle = draftTitle
        self.lines = lines
    }

    public func normalized(for request: AILyricsGenerationRequest) -> AILyricsGenerationResult {
        let title = draftTitle
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = lines.compactMap { rawLine -> String? in
            let line = rawLine
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return nil }
            return String(line.prefix(240))
        }
        return AILyricsGenerationResult(
            draftTitle: String(title.prefix(120)),
            lines: Array(lines.prefix(request.maximumLines))
        )
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

public protocol AILyricsGenerationProviding: MusicIntelligenceProvider {
    func generateLyrics(
        _ request: AILyricsGenerationRequest
    ) async throws -> AILyricsGenerationResult
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
