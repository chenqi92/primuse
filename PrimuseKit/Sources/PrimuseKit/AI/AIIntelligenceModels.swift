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
