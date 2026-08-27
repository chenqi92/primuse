import Foundation
import Observation
import PrimuseKit

struct AISemanticSearchExecution: Sendable {
    var plan: AISemanticSearchPlan
    var providerID: UUID
    var providerName: String
    var fallbackDepth: Int
}

enum AISemanticSearchOutcome: Sendable {
    case unavailable
    case success(AISemanticSearchExecution)
    case empty(providerName: String, fallbackDepth: Int)
    case failed
}

struct AILyricsTranslationExecution: Sendable {
    var translations: [String: String]
    var providerName: String
    var fallbackDepth: Int
}

struct AIAudioTranscriptionExecution: Sendable {
    var result: AIAudioTranscriptionResult
    var providerName: String
    var fallbackDepth: Int
}

enum AIAudioTranscriptionOutcome: Sendable {
    case unavailable
    case success(AIAudioTranscriptionExecution)
    case failed
}

struct AIRecommendationExecution: Sendable {
    var plan: AIRecommendationPlan
    var providerName: String
    var fallbackDepth: Int
    var resolvedScene: AIRecommendationScene
    var isCached: Bool
}

enum AIRecommendationOutcome: Sendable {
    case unavailable
    case success(AIRecommendationExecution)
    case empty(providerName: String, fallbackDepth: Int)
    case failed
}

@MainActor
@Observable
final class MusicIntelligenceService {
    let settingsStore: AISettingsStore
    let regionAvailability: AIRegionAvailabilityService

    private let credentialStore: any AICredentialStoring
    private let engine: MusicIntelligenceEngine
    @ObservationIgnored private var semanticPlanCache: [SemanticPlanCacheKey: SemanticPlanCacheEntry] = [:]
    @ObservationIgnored private var recommendationCache: [
        RecommendationCacheKey: RecommendationCacheEntry
    ] = [:]

    private struct SemanticPlanCacheKey: Hashable {
        var profileID: UUID
        var baseURL: String
        var model: String
        var apiStyle: AICompatibleAPIStyle
        var apiPathMode: AIAPIPathMode
        var authenticationStyle: AIAuthenticationStyle
        var query: String
        var languageCode: String
        var regionRevision: UInt64
    }

    private struct SemanticPlanCacheEntry {
        var plan: AISemanticSearchPlan
        var createdAt: TimeInterval
    }

    private struct RecommendationCacheKey: Hashable {
        var profileID: UUID
        var baseURL: String
        var model: String
        var apiStyle: AICompatibleAPIStyle
        var apiPathMode: AIAPIPathMode
        var authenticationStyle: AIAuthenticationStyle
        var request: AIRecommendationRequest
        var regionRevision: UInt64
    }

    private struct RecommendationCacheEntry {
        var plan: AIRecommendationPlan
        var createdAt: TimeInterval
    }

    private static let semanticPlanCacheLifetime: TimeInterval = 15 * 60
    private static let semanticPlanCacheLimit = 64
    private static let recommendationCacheLifetime: TimeInterval = 6 * 60 * 60
    private static let recommendationCacheLimit = 24

    init(
        settingsStore: AISettingsStore = AISettingsStore(),
        regionAvailability: AIRegionAvailabilityService = AIRegionAvailabilityService(),
        credentialStore: any AICredentialStoring = AICredentialStore()
    ) {
        self.settingsStore = settingsStore
        self.regionAvailability = regionAvailability
        self.credentialStore = credentialStore
        engine = MusicIntelligenceEngine(credentialStore: credentialStore)
    }

    func start() {
        regionAvailability.start { [weak self] in
            self?.semanticPlanCache.removeAll(keepingCapacity: true)
            self?.recommendationCache.removeAll(keepingCapacity: true)
        }
    }

    var shouldExposeRemoteConfiguration: Bool {
        regionAvailability.remoteProviderDecision.shouldExposeConfiguration
    }

    var shouldShowRemoteRecommendations: Bool {
        settingsStore.recommendationsEnabled && shouldExposeRemoteConfiguration
    }

    var isSemanticSearchConfigured: Bool {
        let decision = regionAvailability.remoteProviderDecision
        return settingsStore.semanticSearchEnabled
            && settingsStore.providerSet.routedProviders.contains {
                !$0.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && AIProviderRegionPolicy.allows(
                        configuration: $0,
                        region: regionAvailability.context.region,
                        purpose: .generation
                    )
            }
            && settingsStore.hasExplicitRemoteConsent
            && decision.isAllowed
            && (!decision.requiresExplicitConsent || settingsStore.hasExplicitRemoteConsent)
    }

    var isPersonalizedRecommendationsConfigured: Bool {
        let decision = regionAvailability.remoteProviderDecision
        return settingsStore.recommendationsEnabled
            && settingsStore.providerSet.routedProviders.contains {
                !$0.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && AIProviderRegionPolicy.allows(
                        configuration: $0,
                        region: regionAvailability.context.region,
                        purpose: .generation
                    )
            }
            && settingsStore.hasExplicitListeningContextConsent
            && decision.isAllowed
            && (!decision.requiresExplicitConsent
                || settingsStore.hasExplicitListeningContextConsent)
    }

    var isAudioTranscriptionConfigured: Bool {
        let decision = regionAvailability.remoteProviderDecision
        return settingsStore.audioTranscriptionEnabled
            && settingsStore.providerSet.routedProviders.contains {
                $0.descriptor.capabilities.contains(.audioTranscription)
                    && AIProviderRegionPolicy.allows(
                        configuration: $0,
                        region: regionAvailability.context.region,
                        purpose: .generation
                    )
            }
            && settingsStore.hasExplicitAudioUploadConsent
            && decision.isAllowed
            && (!decision.requiresExplicitConsent
                || settingsStore.hasExplicitAudioUploadConsent)
    }

    func semanticSearchPlan(for query: String) async -> AISemanticSearchPlan? {
        guard case .success(let execution) = await semanticSearchOutcome(for: query) else {
            return nil
        }
        return execution.plan
    }

    func semanticSearchOutcome(for query: String) async -> AISemanticSearchOutcome {
        let consent = settingsStore.hasExplicitRemoteConsent
        let regionSnapshot = regionAvailability.snapshot
        let region = regionSnapshot.context
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSemanticSearchConfigured, !trimmedQuery.isEmpty else { return .unavailable }

        let languageCode = Locale.current.language.languageCode?.identifier ?? ""
        let now = ProcessInfo.processInfo.systemUptime
        let providers = settingsStore.providerSet.routedProviders.filter {
            !$0.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && AIProviderRegionPolicy.allows(
                    configuration: $0,
                    region: region.region,
                    purpose: .generation
                )
        }
        var lastEmptyProvider: (name: String, fallbackDepth: Int)?
        for (fallbackDepth, configuration) in providers.enumerated() {
            guard AIRegionRequestPolicy.canSendRemoteRequest(
                captured: regionSnapshot,
                latest: regionAvailability.snapshot,
                configuration: configuration
            ) else { return .failed }
            let cacheKey = SemanticPlanCacheKey(
                profileID: configuration.id,
                baseURL: configuration.baseURL,
                model: configuration.generationModel,
                apiStyle: configuration.apiStyle,
                apiPathMode: configuration.apiPathMode,
                authenticationStyle: configuration.authenticationStyle,
                query: trimmedQuery.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: .current
                ),
                languageCode: languageCode,
                regionRevision: regionSnapshot.revision
            )
            if let cached = semanticPlanCache[cacheKey],
               now - cached.createdAt <= Self.semanticPlanCacheLifetime {
                return .success(AISemanticSearchExecution(
                    plan: cached.plan,
                    providerID: configuration.id,
                    providerName: configuration.displayName,
                    fallbackDepth: fallbackDepth
                ))
            }

            do {
                let plan = try await engine.interpretSearch(
                    AISemanticSearchRequest(
                        query: trimmedQuery,
                        languageCode: languageCode.isEmpty ? nil : languageCode
                    ),
                    configuration: configuration,
                    regionContext: region,
                    hasExplicitRemoteConsent: consent,
                    requestAuthorization: regionAuthorization(
                        for: regionSnapshot,
                        configuration: configuration
                    )
                )
                guard AIRegionRequestPolicy.canCommitRemoteResponse(
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    configuration: configuration
                ) else { return .failed }
                guard !plan.expandedTerms.isEmpty || !plan.themes.isEmpty || !plan.moods.isEmpty else {
                    lastEmptyProvider = (configuration.displayName, fallbackDepth)
                    continue
                }
                semanticPlanCache[cacheKey] = SemanticPlanCacheEntry(plan: plan, createdAt: now)
                if semanticPlanCache.count > Self.semanticPlanCacheLimit,
                   let oldestKey = semanticPlanCache.min(by: {
                       $0.value.createdAt < $1.value.createdAt
                   })?.key {
                    semanticPlanCache[oldestKey] = nil
                }
                return .success(AISemanticSearchExecution(
                    plan: plan,
                    providerID: configuration.id,
                    providerName: configuration.displayName,
                    fallbackDepth: fallbackDepth
                ))
            } catch is CancellationError {
                return .failed
            } catch {
                continue
            }
        }
        if let lastEmptyProvider {
            return .empty(
                providerName: lastEmptyProvider.name,
                fallbackDepth: lastEmptyProvider.fallbackDepth
            )
        }
        return .failed
    }

    func translateLyrics(
        _ candidates: [LyricTranslationCandidate],
        targetLanguageCode: String
    ) async -> AILyricsTranslationExecution? {
        let regionSnapshot = regionAvailability.snapshot
        let consent = settingsStore.hasExplicitRemoteConsent
        let decision = AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: regionSnapshot.context
        )
        guard decision.isAllowed,
              consent,
              !candidates.isEmpty else { return nil }

        for (fallbackDepth, configuration) in settingsStore.providerSet.routedProviders.enumerated() {
            guard !configuration.generationModel
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  AIRegionRequestPolicy.canSendRemoteRequest(
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    configuration: configuration
                  ) else { continue }
            do {
                let translations = try await engine.translateLyrics(
                    candidates,
                    targetLanguageCode: targetLanguageCode,
                    configuration: configuration,
                    regionContext: regionSnapshot.context,
                    hasExplicitRemoteConsent: consent,
                    requestAuthorization: regionAuthorization(
                        for: regionSnapshot,
                        configuration: configuration
                    )
                )
                guard AIRegionRequestPolicy.canCommitRemoteResponse(
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    configuration: configuration
                ), !translations.isEmpty else { continue }
                return AILyricsTranslationExecution(
                    translations: translations,
                    providerName: configuration.displayName,
                    fallbackDepth: fallbackDepth
                )
            } catch is CancellationError {
                return nil
            } catch {
                continue
            }
        }
        return nil
    }

    func recommendationOutcome(
        for request: AIRecommendationRequest,
        forceRefresh: Bool = false
    ) async -> AIRecommendationOutcome {
        let regionSnapshot = regionAvailability.snapshot
        guard isPersonalizedRecommendationsConfigured,
              !request.candidates.isEmpty else { return .unavailable }
        if !forceRefresh, let cached = cachedRecommendationOutcome(for: request) {
            return cached
        }

        let now = ProcessInfo.processInfo.systemUptime
        let providers = settingsStore.providerSet.routedProviders.filter {
            !$0.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && AIProviderRegionPolicy.allows(
                    configuration: $0,
                    region: regionSnapshot.context.region,
                    purpose: .generation
                )
        }
        var lastEmptyProvider: (name: String, fallbackDepth: Int)?
        for (fallbackDepth, configuration) in providers.enumerated() {
            guard AIRegionRequestPolicy.canSendRemoteRequest(
                captured: regionSnapshot,
                latest: regionAvailability.snapshot,
                configuration: configuration
            ) else { return .failed }
            let cacheKey = RecommendationCacheKey(
                profileID: configuration.id,
                baseURL: configuration.baseURL,
                model: configuration.generationModel,
                apiStyle: configuration.apiStyle,
                apiPathMode: configuration.apiPathMode,
                authenticationStyle: configuration.authenticationStyle,
                request: request,
                regionRevision: regionSnapshot.revision
            )
            if !forceRefresh,
               let cached = recommendationCache[cacheKey],
               now - cached.createdAt <= Self.recommendationCacheLifetime {
                return .success(AIRecommendationExecution(
                    plan: cached.plan,
                    providerName: configuration.displayName,
                    fallbackDepth: fallbackDepth,
                    resolvedScene: request.scene,
                    isCached: true
                ))
            }

            do {
                let plan = try await engine.recommendations(
                    request,
                    configuration: configuration,
                    regionContext: regionSnapshot.context,
                    hasExplicitListeningContextConsent: settingsStore
                        .hasExplicitListeningContextConsent,
                    requestAuthorization: regionAuthorization(
                        for: regionSnapshot,
                        configuration: configuration
                    )
                )
                guard AIRegionRequestPolicy.canCommitRemoteResponse(
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    configuration: configuration
                ) else { return .failed }
                guard !plan.selections.isEmpty else {
                    lastEmptyProvider = (configuration.displayName, fallbackDepth)
                    continue
                }
                recommendationCache[cacheKey] = RecommendationCacheEntry(
                    plan: plan,
                    createdAt: now
                )
                if recommendationCache.count > Self.recommendationCacheLimit,
                   let oldestKey = recommendationCache.min(by: {
                       $0.value.createdAt < $1.value.createdAt
                   })?.key {
                    recommendationCache[oldestKey] = nil
                }
                return .success(AIRecommendationExecution(
                    plan: plan,
                    providerName: configuration.displayName,
                    fallbackDepth: fallbackDepth,
                    resolvedScene: request.scene,
                    isCached: false
                ))
            } catch is CancellationError {
                return .failed
            } catch {
                continue
            }
        }
        if let lastEmptyProvider {
            return .empty(
                providerName: lastEmptyProvider.name,
                fallbackDepth: lastEmptyProvider.fallbackDepth
            )
        }
        return .failed
    }

    func cachedRecommendationOutcome(
        for request: AIRecommendationRequest
    ) -> AIRecommendationOutcome? {
        let regionSnapshot = regionAvailability.snapshot
        guard isPersonalizedRecommendationsConfigured,
              !request.candidates.isEmpty else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let providers = settingsStore.providerSet.routedProviders.filter {
            !$0.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && AIProviderRegionPolicy.allows(
                    configuration: $0,
                    region: regionSnapshot.context.region,
                    purpose: .generation
                )
        }
        for (fallbackDepth, configuration) in providers.enumerated() {
            let key = RecommendationCacheKey(
                profileID: configuration.id,
                baseURL: configuration.baseURL,
                model: configuration.generationModel,
                apiStyle: configuration.apiStyle,
                apiPathMode: configuration.apiPathMode,
                authenticationStyle: configuration.authenticationStyle,
                request: request,
                regionRevision: regionSnapshot.revision
            )
            guard let cached = recommendationCache[key],
                  now - cached.createdAt <= Self.recommendationCacheLifetime else {
                continue
            }
            return .success(AIRecommendationExecution(
                plan: cached.plan,
                providerName: configuration.displayName,
                fallbackDepth: fallbackDepth,
                resolvedScene: request.scene,
                isCached: true
            ))
        }
        return nil
    }

    func transcribeAudio(
        at audioFileURL: URL,
        mimeType: String,
        displayName: String,
        duration: TimeInterval,
        customVocabulary: [String] = []
    ) async -> AIAudioTranscriptionOutcome {
        let regionSnapshot = regionAvailability.snapshot
        guard isAudioTranscriptionConfigured,
              duration <= 0 || duration <= AIAudioTranscriptionPolicy.maximumDuration else {
            return .unavailable
        }
        let request = AIAudioTranscriptionRequest(
            audioFileURL: audioFileURL,
            mimeType: mimeType,
            displayName: displayName,
            customVocabulary: customVocabulary
        )
        let providers = settingsStore.providerSet.routedProviders.filter {
            $0.descriptor.capabilities.contains(.audioTranscription)
                && AIProviderRegionPolicy.allows(
                    configuration: $0,
                    region: regionSnapshot.context.region,
                    purpose: .generation
                )
        }
        for (fallbackDepth, configuration) in providers.enumerated() {
            guard AIRegionRequestPolicy.canSendRemoteRequest(
                captured: regionSnapshot,
                latest: regionAvailability.snapshot,
                configuration: configuration
            ) else { return .failed }
            do {
                let result = try await engine.transcribeAudio(
                    request,
                    configuration: configuration,
                    regionContext: regionSnapshot.context,
                    hasExplicitAudioUploadConsent: settingsStore
                        .hasExplicitAudioUploadConsent,
                    requestAuthorization: regionAuthorization(
                        for: regionSnapshot,
                        configuration: configuration
                    )
                )
                guard AIRegionRequestPolicy.canCommitRemoteResponse(
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    configuration: configuration
                ) else { return .failed }
                guard !result.isEmpty else { continue }
                return .success(AIAudioTranscriptionExecution(
                    result: result,
                    providerName: configuration.displayName,
                    fallbackDepth: fallbackDepth
                ))
            } catch is CancellationError {
                return .failed
            } catch {
                continue
            }
        }
        return .failed
    }

    func hasStoredAPIKey(configuration: AIRemoteProviderConfiguration) async -> Bool {
        if case .ready = await credentialStore.lookupAPIKey(configuration: configuration) {
            return true
        }
        return false
    }

    func save(
        configuration: AIRemoteProviderConfiguration,
        hasExplicitRemoteConsent: Bool,
        apiKey: String?
    ) async throws {
        let decision = AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: regionAvailability.context
        )
        guard decision.isAllowed else {
            throw MusicIntelligenceError.unavailable(.regionRestricted)
        }
        _ = try AIRemoteEndpointPolicy.generationEndpoint(configuration: configuration)
        if let apiKey,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try await credentialStore.saveAPIKey(apiKey, configuration: configuration)
        }
        try settingsStore.save(
            configuration: configuration,
            hasExplicitRemoteConsent: hasExplicitRemoteConsent
        )
        semanticPlanCache.removeAll(keepingCapacity: true)
        recommendationCache.removeAll(keepingCapacity: true)
    }

    func save(
        providerSet: AIRemoteProviderSet,
        semanticSearchEnabled: Bool,
        recommendationsEnabled: Bool,
        audioTranscriptionEnabled: Bool,
        hasExplicitRemoteConsent: Bool,
        hasExplicitListeningContextConsent: Bool,
        hasExplicitAudioUploadConsent: Bool,
        apiKeys: [UUID: String]
    ) async throws {
        let decision = AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: regionAvailability.context
        )
        guard decision.isAllowed else {
            throw MusicIntelligenceError.unavailable(.regionRestricted)
        }
        let normalized = providerSet.normalized()
        for provider in normalized.providers where provider.isEnabled {
            _ = try AIRemoteEndpointPolicy.generationEndpoint(configuration: provider)
        }
        for provider in normalized.providers {
            guard let apiKey = apiKeys[provider.id],
                  !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            _ = try await credentialStore.saveAPIKey(apiKey, configuration: provider)
        }
        try settingsStore.save(
            providerSet: normalized,
            semanticSearchEnabled: semanticSearchEnabled,
            recommendationsEnabled: recommendationsEnabled,
            audioTranscriptionEnabled: audioTranscriptionEnabled,
            hasExplicitRemoteConsent: hasExplicitRemoteConsent,
            hasExplicitListeningContextConsent: hasExplicitListeningContextConsent,
            hasExplicitAudioUploadConsent: hasExplicitAudioUploadConsent
        )
        semanticPlanCache.removeAll(keepingCapacity: true)
        recommendationCache.removeAll(keepingCapacity: true)
    }

    func deleteAPIKey(configuration: AIRemoteProviderConfiguration) async throws {
        try await credentialStore.deleteAPIKey(configuration: configuration)
        semanticPlanCache.removeAll(keepingCapacity: true)
        recommendationCache.removeAll(keepingCapacity: true)
    }

    func availableModels(
        configuration: AIRemoteProviderConfiguration,
        apiKey: String?
    ) async throws -> [AIProviderModel] {
        let regionSnapshot = regionAvailability.snapshot
        let decision = AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: regionSnapshot.context
        )
        guard decision.isAllowed else {
            throw MusicIntelligenceError.unavailable(.regionRestricted)
        }
        guard AIProviderRegionPolicy.allows(
            configuration: configuration,
            region: regionSnapshot.context.region,
            purpose: .modelCatalog
        ) else {
            throw MusicIntelligenceError.unavailable(.regionRestricted)
        }
        let models = try await engine.listModels(
            configuration: configuration,
            apiKeyOverride: apiKey,
            requestAuthorization: regionAuthorization(
                for: regionSnapshot,
                configuration: configuration,
                purpose: .modelCatalog
            )
        )
        guard AIRegionRequestPolicy.canCommitRemoteResponse(
            captured: regionSnapshot,
            latest: regionAvailability.snapshot,
            configuration: configuration,
            purpose: .modelCatalog
        ) else {
            throw MusicIntelligenceError.unavailable(.temporarilyUnavailable)
        }
        return AIProviderRegionPolicy.filterModels(
            models,
            configuration: configuration,
            region: regionSnapshot.context.region
        )
    }

    func testConnection(
        configuration: AIRemoteProviderConfiguration,
        apiKey: String?
    ) async throws {
        let regionSnapshot = regionAvailability.snapshot
        let region = regionSnapshot.context
        let decision = AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: region
        )
        guard decision.isAllowed else {
            throw MusicIntelligenceError.unavailable(.regionRestricted)
        }
        var enabledConfiguration = configuration
        enabledConfiguration.isEnabled = true
        guard AIProviderRegionPolicy.allows(
            configuration: enabledConfiguration,
            region: region.region,
            purpose: .generation
        ) else {
            throw MusicIntelligenceError.unavailable(.regionRestricted)
        }
        // Connection diagnostics send only this built-in phrase. They never
        // include a search term, lyrics, library metadata, or listening
        // history, so they are independent from content-sharing consent.
        _ = try await engine.interpretSearch(
            AISemanticSearchRequest(
                query: "quiet evening music",
                languageCode: "en",
                maximumExpansionTerms: 2
            ),
            configuration: enabledConfiguration,
            regionContext: region,
            hasExplicitRemoteConsent: true,
            apiKeyOverride: apiKey,
            requestAuthorization: regionAuthorization(
                for: regionSnapshot,
                configuration: enabledConfiguration
            )
        )
        guard AIRegionRequestPolicy.canCommitRemoteResponse(
            captured: regionSnapshot,
            latest: regionAvailability.snapshot,
            configuration: enabledConfiguration
        ) else {
            throw MusicIntelligenceError.unavailable(.temporarilyUnavailable)
        }
    }

    private func regionAuthorization(
        for captured: AIRegionSnapshot,
        configuration: AIRemoteProviderConfiguration,
        purpose: AIProviderRegionPurpose = .generation
    ) -> @Sendable () async -> Bool {
        let availability = regionAvailability
        return {
            await MainActor.run {
                AIRegionRequestPolicy.canSendRemoteRequest(
                    captured: captured,
                    latest: availability.snapshot,
                    configuration: configuration,
                    purpose: purpose
                )
            }
        }
    }
}

enum AIRecommendationFeedback: Equatable {
    case idle
    case loading
    case needsConsent
    case success(
        summary: String,
        providerName: String,
        fallbackDepth: Int,
        scene: AIRecommendationScene,
        isCached: Bool
    )
    case localFallback(providerName: String?, fallbackDepth: Int)
}

enum AIRecommendationContextBuilder {
    @MainActor
    static func request(
        scene: AIRecommendationScene,
        intent: String? = nil,
        candidates: [Song],
        history: PlayHistoryStore = .shared,
        now: Date = Date()
    ) -> AIRecommendationRequest? {
        var seen = Set<String>()
        let uniqueCandidates = candidates.filter {
            !$0.id.isEmpty && seen.insert($0.id).inserted
        }
        guard !uniqueCandidates.isEmpty else { return nil }
        let metadataByID = Dictionary(
            uniqueKeysWithValues: uniqueCandidates.map { ($0.id, $0) }
        )
        var preferenceArtistCounts: [String: Int] = [:]
        let preferences = Array(history.topSongs(in: .year, limit: 36).compactMap {
            item -> AIRecommendationPreference? in
            let artist = metadataByID[item.id]?.artistName ?? item.subtitle
            let normalizedArtist = artist
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let artistKey = normalizedArtist.isEmpty ? "song:\(item.id)" : normalizedArtist
            guard preferenceArtistCounts[artistKey, default: 0] < 2 else { return nil }
            preferenceArtistCounts[artistKey, default: 0] += 1
            return AIRecommendationPreference(
                title: item.title,
                artist: artist,
                genre: metadataByID[item.id]?.genre,
                playCount: item.playCount
            )
        }.prefix(12))
        let recommendationCandidates = uniqueCandidates.prefix(36).map { song in
            let durationSeconds: Int
            if song.duration.isFinite {
                durationSeconds = Int(max(0, min(song.duration, 86_400)).rounded())
            } else {
                durationSeconds = 0
            }
            return AIRecommendationCandidate(
                songID: song.id,
                title: song.title,
                artist: song.artistName ?? "",
                genre: song.genre,
                year: song.year,
                durationSeconds: durationSeconds
            )
        }
        return AIRecommendationRequest(
            scene: AIRecommendationSceneResolver.resolved(scene, at: now),
            intent: intent,
            languageCode: Locale.current.language.languageCode?.identifier,
            preferences: preferences,
            candidates: recommendationCandidates,
            maximumResults: min(8, recommendationCandidates.count)
        )
    }
}

@MainActor
@Observable
final class AIRecommendationViewModel {
    private(set) var feedback: AIRecommendationFeedback = .idle
    private(set) var orderedSongIDs: [String] = []
    private(set) var reasonsBySongID: [String: String] = [:]
    private var generation: UInt64 = 0

    func refresh(
        scene: AIRecommendationScene,
        intent: String? = nil,
        candidates: [Song],
        using intelligence: MusicIntelligenceService,
        forceRefresh: Bool = false
    ) async {
        generation &+= 1
        let operationGeneration = generation
        guard intelligence.settingsStore.recommendationsEnabled else {
            feedback = .idle
            orderedSongIDs = []
            reasonsBySongID = [:]
            return
        }
        guard intelligence.settingsStore.hasExplicitListeningContextConsent else {
            feedback = .needsConsent
            orderedSongIDs = []
            reasonsBySongID = [:]
            return
        }
        guard let request = AIRecommendationContextBuilder.request(
            scene: scene,
            intent: intent,
            candidates: candidates
        ) else {
            feedback = .idle
            orderedSongIDs = []
            reasonsBySongID = [:]
            return
        }

        let outcome: AIRecommendationOutcome
        if !forceRefresh,
           let cached = intelligence.cachedRecommendationOutcome(for: request) {
            outcome = cached
        } else {
            feedback = .loading
            outcome = await intelligence.recommendationOutcome(
                for: request,
                forceRefresh: forceRefresh
            )
        }
        guard operationGeneration == generation, !Task.isCancelled else { return }
        switch outcome {
        case .unavailable:
            feedback = .localFallback(providerName: nil, fallbackDepth: 0)
            orderedSongIDs = []
            reasonsBySongID = [:]
        case .success(let execution):
            orderedSongIDs = execution.plan.selections.map(\.songID)
            reasonsBySongID = Dictionary(
                uniqueKeysWithValues: execution.plan.selections.map {
                    ($0.songID, $0.reason)
                }
            )
            feedback = .success(
                summary: execution.plan.summary,
                providerName: execution.providerName,
                fallbackDepth: execution.fallbackDepth,
                scene: execution.resolvedScene,
                isCached: execution.isCached
            )
        case .empty(let providerName, let fallbackDepth):
            orderedSongIDs = []
            reasonsBySongID = [:]
            feedback = .localFallback(
                providerName: providerName,
                fallbackDepth: fallbackDepth
            )
        case .failed:
            orderedSongIDs = []
            reasonsBySongID = [:]
            feedback = .localFallback(providerName: nil, fallbackDepth: 0)
        }
    }

    func orderedSongs(from candidates: [Song]) -> [Song] {
        guard !orderedSongIDs.isEmpty else { return candidates }
        let byID = Dictionary(
            candidates.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        return orderedSongIDs.compactMap { byID[$0] }
    }

    func reason(for songID: String) -> String? {
        reasonsBySongID[songID]
    }

    var statusText: String {
        switch feedback {
        case .idle:
            return String(localized: "ai_recommendation_status_local")
        case .loading:
            return String(localized: "ai_recommendation_status_loading")
        case .needsConsent:
            return String(localized: "ai_recommendation_status_needs_consent")
        case .success(_, let providerName, let fallbackDepth, let scene, let isCached):
            if isCached {
                return String(
                    format: String(localized: "ai_recommendation_status_cached_format"),
                    providerName,
                    scene.localizedName
                )
            }
            let key = fallbackDepth > 0
                ? "ai_recommendation_status_fallback_format"
                : "ai_recommendation_status_success_format"
            return String(
                format: String(localized: String.LocalizationValue(key)),
                providerName,
                scene.localizedName
            )
        case .localFallback:
            return String(localized: "ai_recommendation_status_failed_local")
        }
    }

    var summaryText: String? {
        guard case .success(let summary, _, _, _, _) = feedback else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension AIRecommendationScene {
    var localizedName: String {
        switch self {
        case .automatic: String(localized: "ai_recommendation_scene_automatic")
        case .driving: String(localized: "ai_recommendation_scene_driving")
        case .focus: String(localized: "ai_recommendation_scene_focus")
        case .workout: String(localized: "ai_recommendation_scene_workout")
        case .relaxation: String(localized: "ai_recommendation_scene_relaxation")
        case .bedtime: String(localized: "ai_recommendation_scene_bedtime")
        }
    }
}

private actor MusicIntelligenceEngine {
    private let credentialStore: any AICredentialStoring

    init(credentialStore: any AICredentialStoring) {
        self.credentialStore = credentialStore
    }

    func interpretSearch(
        _ request: AISemanticSearchRequest,
        configuration: AIRemoteProviderConfiguration,
        regionContext: AIRegionContext,
        hasExplicitRemoteConsent: Bool,
        apiKeyOverride: String? = nil,
        requestAuthorization: @escaping @Sendable () async -> Bool = { true }
    ) async throws -> AISemanticSearchPlan {
        let candidates = AIProviderRoutingPolicy.candidates(
            from: [configuration.descriptor],
            capability: .semanticSearchInterpretation,
            regionContext: regionContext,
            hasExplicitRemoteConsent: hasExplicitRemoteConsent
        )
        guard candidates.first?.id == configuration.id else {
            let reason: AIProviderUnavailableReason = regionContext.region == .mainlandChina
                ? .regionRestricted
                : .disabled
            throw MusicIntelligenceError.unavailable(reason)
        }

        let provider = OpenAICompatibleProvider(
            configuration: configuration,
            credentialStore: credentialStore,
            apiKeyOverride: apiKeyOverride,
            requestAuthorization: requestAuthorization
        )
        switch await provider.runtimeAvailability() {
        case .available:
            break
        case .unavailable(let reason):
            throw MusicIntelligenceError.unavailable(reason)
        }

        return try await withTimeout(seconds: configuration.requestTimeout) {
            try await provider.interpretSearch(request)
        }
    }

    func listModels(
        configuration: AIRemoteProviderConfiguration,
        apiKeyOverride: String?,
        requestAuthorization: @escaping @Sendable () async -> Bool
    ) async throws -> [AIProviderModel] {
        let provider = OpenAICompatibleProvider(
            configuration: configuration,
            credentialStore: credentialStore,
            apiKeyOverride: apiKeyOverride,
            requestAuthorization: requestAuthorization
        )
        return try await withTimeout(seconds: configuration.requestTimeout) {
            try await provider.listModels()
        }
    }

    func translateLyrics(
        _ candidates: [LyricTranslationCandidate],
        targetLanguageCode: String,
        configuration: AIRemoteProviderConfiguration,
        regionContext: AIRegionContext,
        hasExplicitRemoteConsent: Bool,
        requestAuthorization: @escaping @Sendable () async -> Bool
    ) async throws -> [String: String] {
        let routed = AIProviderRoutingPolicy.candidates(
            from: [configuration.descriptor],
            capability: .lyricsTranslation,
            regionContext: regionContext,
            hasExplicitRemoteConsent: hasExplicitRemoteConsent
        )
        guard routed.first?.id == configuration.id else {
            let reason: AIProviderUnavailableReason = regionContext.region == .mainlandChina
                ? .regionRestricted
                : .disabled
            throw MusicIntelligenceError.unavailable(reason)
        }

        let provider = OpenAICompatibleProvider(
            configuration: configuration,
            credentialStore: credentialStore,
            requestAuthorization: requestAuthorization
        )
        switch await provider.runtimeAvailability() {
        case .available:
            break
        case .unavailable(let reason):
            throw MusicIntelligenceError.unavailable(reason)
        }
        return try await withTimeout(seconds: configuration.requestTimeout) {
            try await provider.translateLyrics(
                candidates,
                targetLanguageCode: targetLanguageCode
            )
        }
    }

    func recommendations(
        _ request: AIRecommendationRequest,
        configuration: AIRemoteProviderConfiguration,
        regionContext: AIRegionContext,
        hasExplicitListeningContextConsent: Bool,
        requestAuthorization: @escaping @Sendable () async -> Bool
    ) async throws -> AIRecommendationPlan {
        let candidates = AIProviderRoutingPolicy.candidates(
            from: [configuration.descriptor],
            capability: .recommendations,
            regionContext: regionContext,
            hasExplicitRemoteConsent: hasExplicitListeningContextConsent
        )
        guard candidates.first?.id == configuration.id else {
            let reason: AIProviderUnavailableReason = regionContext.region == .mainlandChina
                ? .regionRestricted
                : .disabled
            throw MusicIntelligenceError.unavailable(reason)
        }

        let provider = OpenAICompatibleProvider(
            configuration: configuration,
            credentialStore: credentialStore,
            requestAuthorization: requestAuthorization
        )
        switch await provider.runtimeAvailability() {
        case .available:
            break
        case .unavailable(let reason):
            throw MusicIntelligenceError.unavailable(reason)
        }
        return try await withTimeout(seconds: configuration.requestTimeout) {
            try await provider.recommendations(request)
        }
    }

    func transcribeAudio(
        _ request: AIAudioTranscriptionRequest,
        configuration: AIRemoteProviderConfiguration,
        regionContext: AIRegionContext,
        hasExplicitAudioUploadConsent: Bool,
        requestAuthorization: @escaping @Sendable () async -> Bool
    ) async throws -> AIAudioTranscriptionResult {
        let candidates = AIProviderRoutingPolicy.candidates(
            from: [configuration.descriptor],
            capability: .audioTranscription,
            regionContext: regionContext,
            hasExplicitRemoteConsent: hasExplicitAudioUploadConsent
        )
        guard candidates.first?.id == configuration.id else {
            let reason: AIProviderUnavailableReason = regionContext.region == .mainlandChina
                ? .regionRestricted
                : .disabled
            throw MusicIntelligenceError.unavailable(reason)
        }

        let provider = GeminiAudioTranscriptionProvider(
            configuration: configuration,
            credentialStore: credentialStore,
            requestAuthorization: requestAuthorization
        )
        switch await provider.runtimeAvailability() {
        case .available:
            break
        case .unavailable(let reason):
            throw MusicIntelligenceError.unavailable(reason)
        }
        return try await provider.transcribeAudio(request)
    }

    private func withTimeout<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let nanoseconds = AIRequestTimeoutPolicy.nanoseconds(seconds) else {
            throw MusicIntelligenceError.invalidConfiguration
        }
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw MusicIntelligenceError.timedOut
            }
            guard let result = try await group.next() else {
                throw MusicIntelligenceError.timedOut
            }
            group.cancelAll()
            return result
        }
    }
}
