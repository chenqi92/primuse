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
    case failed(AIRecommendationFallbackReason)
}

enum AIRecommendationFallbackReason: Equatable, Sendable {
    case unavailable
    case empty
    case busy
    case minuteLimit
    case dailyLimit
    case regionRestricted
    case deviceRegistration
    case authentication
    case network
    case upstream

    static func classify(_ error: Error) -> AIRecommendationFallbackReason {
        if error is CancellationError {
            return .upstream
        }
        if error is URLError {
            return .network
        }
        if let relayError = error as? PrimuseAIRelayError {
            if case .requestFailed(let statusCode, let code) = relayError {
                switch code {
                case "concurrency_limited", "upstreams_busy":
                    return .busy
                case "minute_request_limit_exhausted", "edge_rate_limited",
                     "installation_rate_limited":
                    return .minuteLimit
                case "daily_request_limit_exhausted", "daily_quota_exhausted",
                     "feature_quota_exhausted":
                    return .dailyLimit
                case "country_not_allowed", "region_restricted":
                    return .regionRestricted
                default:
                    break
                }
                if statusCode == 451 {
                    return .regionRestricted
                }
                if statusCode == 429 {
                    return .minuteLimit
                }
            }
            switch PrimuseAIRelayDiagnostic.classify(relayError).category {
            case .regionRestriction:
                return .regionRestricted
            case .deviceRegistration:
                return .deviceRegistration
            case .serviceAuthentication:
                return .authentication
            case .upstream:
                return .upstream
            }
        }
        if let intelligenceError = error as? MusicIntelligenceError {
            switch intelligenceError {
            case .unavailable(.regionRestricted):
                return .regionRestricted
            case .unavailable(.unsupportedDevice):
                return .deviceRegistration
            case .unavailable(.missingCredential), .unavailable(.missingConfiguration),
                 .unavailable(.disabled):
                return .authentication
            case .requestFailed(let statusCode) where statusCode == 401 || statusCode == 403:
                return .authentication
            case .requestFailed(let statusCode) where statusCode == 429:
                return .minuteLimit
            case .timedOut:
                return .network
            default:
                return .upstream
            }
        }
        return .upstream
    }

    fileprivate var retriesBriefly: Bool {
        self == .busy
    }
}

actor PrimuseRelayRecommendationCoordinator {
    private struct QueueTail {
        var identifier: UInt64
        var task: Task<Void, Never>
    }

    private let client: PrimuseAIRelayClient
    private let transientRetryDelay: Duration
    private var inFlight: [AIRecommendationRequest: Task<AIRecommendationPlan, Error>] = [:]
    private var queueTail: QueueTail?
    private var nextIdentifier: UInt64 = 0

    init(
        client: PrimuseAIRelayClient,
        transientRetryDelay: Duration = .seconds(1)
    ) {
        self.client = client
        self.transientRetryDelay = transientRetryDelay
    }

    func recommendations(_ request: AIRecommendationRequest) async throws
        -> AIRecommendationPlan {
        if let existing = inFlight[request] {
            return try await existing.value
        }

        nextIdentifier &+= 1
        let identifier = nextIdentifier
        let predecessor = queueTail?.task
        let client = client
        let retryDelay = transientRetryDelay
        let operation = Task<AIRecommendationPlan, Error> {
            if let predecessor {
                await predecessor.value
            }
            do {
                return try await client.recommendations(request)
            } catch {
                guard AIRecommendationFallbackReason.classify(error).retriesBriefly else {
                    throw error
                }
                try await Task.sleep(for: retryDelay)
                return try await client.recommendations(request)
            }
        }
        inFlight[request] = operation
        let completion = Task<Void, Never> {
            _ = try? await operation.value
        }
        queueTail = QueueTail(identifier: identifier, task: completion)

        do {
            let plan = try await operation.value
            finish(request: request, identifier: identifier)
            return plan
        } catch {
            finish(request: request, identifier: identifier)
            throw error
        }
    }

    private func finish(request: AIRecommendationRequest, identifier: UInt64) {
        inFlight[request] = nil
        if queueTail?.identifier == identifier {
            queueTail = nil
        }
    }
}

struct PrimuseAIRelayConnectionReport: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case available(PrimuseAIRelayAuthenticationMethod)
        case unavailable(PrimuseAIRelayDiagnostic)
    }

    enum Fallback: Equatable, Sendable {
        case none
        case remoteProvider(String)
        case localOnly
    }

    var outcome: Outcome
    var fallback: Fallback

    var isDirectlyAvailable: Bool {
        if case .available = outcome { return true }
        return false
    }

    var isDegraded: Bool {
        switch (outcome, fallback) {
        case (.available(.storeKitFallback), _),
             (.unavailable(_), .remoteProvider(_)):
            return true
        default:
            return false
        }
    }
}

@MainActor
@Observable
final class MusicIntelligenceService {
    let settingsStore: AISettingsStore
    let lyricsTranscriptionSettingsStore: LyricsTranscriptionSettingsStore
    let regionAvailability: AIRegionAvailabilityService
    private(set) var lyricsTranscriptionCredentialAvailable = false

    private let credentialStore: any AICredentialStoring
    private let engine: MusicIntelligenceEngine
    private let primuseRelayClient: PrimuseAIRelayClient
    private let primuseRelayRecommendationCoordinator: PrimuseRelayRecommendationCoordinator
    @ObservationIgnored private var semanticPlanCache: [SemanticPlanCacheKey: SemanticPlanCacheEntry] = [:]
    @ObservationIgnored private var recommendationCache: [
        RecommendationCacheKey: RecommendationCacheEntry
    ] = [:]
    @ObservationIgnored private var primuseRelaySemanticPlanCache: [
        PrimuseRelaySemanticCacheKey: SemanticPlanCacheEntry
    ] = [:]
    @ObservationIgnored private var primuseRelayRecommendationCache: [
        PrimuseRelayRecommendationCacheKey: RecommendationCacheEntry
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

    private struct PrimuseRelaySemanticCacheKey: Hashable {
        var query: String
        var languageCode: String
        var regionRevision: UInt64
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

    private struct PrimuseRelayRecommendationCacheKey: Hashable {
        var request: AIRecommendationRequest
        var regionRevision: UInt64
    }

    private static let semanticPlanCacheLifetime: TimeInterval = 15 * 60
    private static let semanticPlanCacheLimit = 64
    private static let recommendationCacheLifetime: TimeInterval = 6 * 60 * 60
    private static let recommendationCacheLimit = 24

    init(
        settingsStore: AISettingsStore = AISettingsStore(),
        lyricsTranscriptionSettingsStore: LyricsTranscriptionSettingsStore? = nil,
        regionAvailability: AIRegionAvailabilityService = AIRegionAvailabilityService(),
        credentialStore: any AICredentialStoring = AICredentialStore()
    ) {
        self.settingsStore = settingsStore
        self.lyricsTranscriptionSettingsStore = lyricsTranscriptionSettingsStore
            ?? LyricsTranscriptionSettingsStore(legacySettingsStore: settingsStore)
        self.regionAvailability = regionAvailability
        self.credentialStore = credentialStore
        engine = MusicIntelligenceEngine(credentialStore: credentialStore)
        let primuseRelayClient = PrimuseAIRelayClient()
        self.primuseRelayClient = primuseRelayClient
        primuseRelayRecommendationCoordinator = PrimuseRelayRecommendationCoordinator(
            client: primuseRelayClient
        )
        let refreshTranscriptionSettings: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.prepareLyricsTranscriptionCredentialMigration()
            }
        }
        self.settingsStore.externalReloadHandler = refreshTranscriptionSettings
        self.lyricsTranscriptionSettingsStore.externalReloadHandler = refreshTranscriptionSettings
    }

    func start() {
        regionAvailability.start { [weak self] in
            self?.semanticPlanCache.removeAll(keepingCapacity: true)
            self?.recommendationCache.removeAll(keepingCapacity: true)
            self?.primuseRelaySemanticPlanCache.removeAll(keepingCapacity: true)
            self?.primuseRelayRecommendationCache.removeAll(keepingCapacity: true)
        }
        Task { @MainActor [weak self] in
            await self?.prepareLyricsTranscriptionCredentialMigration()
        }
    }

    var shouldExposeRemoteConfiguration: Bool {
        regionAvailability.remoteProviderDecision.shouldExposeConfiguration
    }

    var shouldShowRemoteRecommendations: Bool {
        settingsStore.recommendationsEnabled && shouldExposeRemoteConfiguration
    }

    private var isPrimuseRelayAvailable: Bool {
        let decision = AIAvailabilityPolicy.decision(
            for: .bundledRemote,
            regionContext: regionAvailability.context
        )
        return settingsStore.primuseRelayEnabled
            && PrimuseAIRelayClient.isSupportedOnCurrentDevice
            && decision.isAllowed
    }

    private var primuseRelayProviderName: String {
        String(localized: "ai_primuse_relay_name")
    }

    private func canUsePrimuseRelay(
        captured: AIRegionSnapshot,
        latest: AIRegionSnapshot,
        hasRequiredConsent: Bool
    ) -> Bool {
        guard captured == latest,
              hasRequiredConsent,
              settingsStore.primuseRelayEnabled,
              PrimuseAIRelayClient.isSupportedOnCurrentDevice else { return false }
        return AIAvailabilityPolicy.decision(
            for: .bundledRemote,
            regionContext: latest.context
        ).isAllowed
    }

    private func primuseRelayFallbackReason(
        captured: AIRegionSnapshot,
        latest: AIRegionSnapshot,
        hasRequiredConsent: Bool
    ) -> AIRecommendationFallbackReason {
        guard hasRequiredConsent, settingsStore.primuseRelayEnabled else {
            return .unavailable
        }
        guard PrimuseAIRelayClient.isSupportedOnCurrentDevice else {
            return .deviceRegistration
        }
        guard captured == latest,
              AIAvailabilityPolicy.decision(
                for: .bundledRemote,
                regionContext: latest.context
              ).isAllowed else {
            return .regionRestricted
        }
        return .unavailable
    }

    var isSemanticSearchConfigured: Bool {
        let decision = regionAvailability.remoteProviderDecision
        guard settingsStore.semanticSearchEnabled,
              settingsStore.hasExplicitRemoteConsent else { return false }
        let hasCustomProvider = settingsStore.providerSet.routedProviders.contains {
                !$0.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && AIProviderRegionPolicy.allows(
                        configuration: $0,
                        region: regionAvailability.context.region,
                        purpose: .generation
                    )
            }
            && decision.isAllowed
            && (!decision.requiresExplicitConsent || settingsStore.hasExplicitRemoteConsent)
        return isPrimuseRelayAvailable || hasCustomProvider
    }

    var isPersonalizedRecommendationsConfigured: Bool {
        let decision = regionAvailability.remoteProviderDecision
        guard settingsStore.recommendationsEnabled,
              settingsStore.hasExplicitListeningContextConsent else { return false }
        let hasCustomProvider = settingsStore.providerSet.routedProviders.contains {
                !$0.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && AIProviderRegionPolicy.allows(
                        configuration: $0,
                        region: regionAvailability.context.region,
                        purpose: .generation
                    )
            }
            && decision.isAllowed
            && (!decision.requiresExplicitConsent
                || settingsStore.hasExplicitListeningContextConsent)
        return isPrimuseRelayAvailable || hasCustomProvider
    }

    var isAudioTranscriptionConfigured: Bool {
        let decision = regionAvailability.remoteProviderDecision
        let configuration = lyricsTranscriptionSettingsStore.configuration
        return lyricsTranscriptionSettingsStore.isEnabled
            && AIAudioTranscriptionPolicy.supports(configuration: configuration)
            && lyricsTranscriptionCredentialAvailable
            && AIProviderRegionPolicy.allows(
                configuration: configuration,
                region: regionAvailability.context.region,
                purpose: .generation
            )
            && lyricsTranscriptionSettingsStore.hasExplicitAudioUploadConsent
            && decision.isAllowed
            && (!decision.requiresExplicitConsent
                || lyricsTranscriptionSettingsStore.hasExplicitAudioUploadConsent)
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
        let normalizedQuery = trimmedQuery.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        var lastEmptyProvider: (name: String, fallbackDepth: Int)?
        var customFallbackOffset = 0

        if isPrimuseRelayAvailable {
            guard canUsePrimuseRelay(
                captured: regionSnapshot,
                latest: regionAvailability.snapshot,
                hasRequiredConsent: settingsStore.hasExplicitRemoteConsent
            ) else { return .failed }
            customFallbackOffset = 1
            let cacheKey = PrimuseRelaySemanticCacheKey(
                query: normalizedQuery,
                languageCode: languageCode,
                regionRevision: regionSnapshot.revision
            )
            if let cached = primuseRelaySemanticPlanCache[cacheKey],
               now - cached.createdAt <= Self.semanticPlanCacheLifetime {
                return .success(AISemanticSearchExecution(
                    plan: cached.plan,
                    providerID: PrimuseAIRelayClient.providerID,
                    providerName: primuseRelayProviderName,
                    fallbackDepth: 0
                ))
            }

            do {
                let request = AISemanticSearchRequest(
                    query: trimmedQuery,
                    languageCode: languageCode.isEmpty ? nil : languageCode
                )
                let plan = try await primuseRelayClient.interpretSearch(request)
                guard canUsePrimuseRelay(
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    hasRequiredConsent: settingsStore.hasExplicitRemoteConsent
                ) else { return .failed }
                guard !plan.expandedTerms.isEmpty || !plan.themes.isEmpty || !plan.moods.isEmpty else {
                    lastEmptyProvider = (primuseRelayProviderName, 0)
                    throw PrimuseAIRelayError.invalidResponse
                }
                primuseRelaySemanticPlanCache[cacheKey] = SemanticPlanCacheEntry(
                    plan: plan,
                    createdAt: now
                )
                if primuseRelaySemanticPlanCache.count > Self.semanticPlanCacheLimit,
                   let oldestKey = primuseRelaySemanticPlanCache.min(by: {
                       $0.value.createdAt < $1.value.createdAt
                   })?.key {
                    primuseRelaySemanticPlanCache[oldestKey] = nil
                }
                return .success(AISemanticSearchExecution(
                    plan: plan,
                    providerID: PrimuseAIRelayClient.providerID,
                    providerName: primuseRelayProviderName,
                    fallbackDepth: 0
                ))
            } catch is CancellationError {
                return .failed
            } catch {
                // A user-configured provider remains available as a fallback.
            }
        }

        let providers = settingsStore.providerSet.routedProviders.filter {
            !$0.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && AIProviderRegionPolicy.allows(
                    configuration: $0,
                    region: region.region,
                    purpose: .generation
                )
        }
        for (fallbackDepth, configuration) in providers.enumerated() {
            let effectiveFallbackDepth = fallbackDepth + customFallbackOffset
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
                query: normalizedQuery,
                languageCode: languageCode,
                regionRevision: regionSnapshot.revision
            )
            if let cached = semanticPlanCache[cacheKey],
               now - cached.createdAt <= Self.semanticPlanCacheLifetime {
                return .success(AISemanticSearchExecution(
                    plan: cached.plan,
                    providerID: configuration.id,
                    providerName: configuration.displayName,
                    fallbackDepth: effectiveFallbackDepth
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
                    lastEmptyProvider = (configuration.displayName, effectiveFallbackDepth)
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
                    fallbackDepth: effectiveFallbackDepth
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
        guard consent, !candidates.isEmpty else { return nil }

        var customFallbackOffset = 0
        if isPrimuseRelayAvailable {
            guard canUsePrimuseRelay(
                captured: regionSnapshot,
                latest: regionAvailability.snapshot,
                hasRequiredConsent: settingsStore.hasExplicitRemoteConsent
            ) else { return nil }
            customFallbackOffset = 1
            do {
                let translations = try await primuseRelayClient.translateLyrics(
                    candidates,
                    targetLanguageCode: targetLanguageCode
                )
                guard canUsePrimuseRelay(
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    hasRequiredConsent: settingsStore.hasExplicitRemoteConsent
                ), !translations.isEmpty else { return nil }
                return AILyricsTranslationExecution(
                    translations: translations,
                    providerName: primuseRelayProviderName,
                    fallbackDepth: 0
                )
            } catch is CancellationError {
                return nil
            } catch {
                // Continue with the user's configured fallback providers.
            }
        }

        let decision = AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: regionSnapshot.context
        )
        guard decision.isAllowed else { return nil }

        for (fallbackDepth, configuration) in settingsStore.providerSet.routedProviders.enumerated() {
            let effectiveFallbackDepth = fallbackDepth + customFallbackOffset
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
                    fallbackDepth: effectiveFallbackDepth
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
        var lastEmptyProvider: (name: String, fallbackDepth: Int)?
        var lastFailureReason: AIRecommendationFallbackReason?
        var customFallbackOffset = 0

        if isPrimuseRelayAvailable {
            guard canUsePrimuseRelay(
                captured: regionSnapshot,
                latest: regionAvailability.snapshot,
                hasRequiredConsent: settingsStore.hasExplicitListeningContextConsent
            ) else {
                return .failed(primuseRelayFallbackReason(
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    hasRequiredConsent: settingsStore.hasExplicitListeningContextConsent
                ))
            }
            customFallbackOffset = 1
            let cacheKey = PrimuseRelayRecommendationCacheKey(
                request: request,
                regionRevision: regionSnapshot.revision
            )
            do {
                let plan = try await primuseRelayRecommendationCoordinator
                    .recommendations(request)
                guard canUsePrimuseRelay(
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    hasRequiredConsent: settingsStore.hasExplicitListeningContextConsent
                ) else {
                    return .failed(primuseRelayFallbackReason(
                        captured: regionSnapshot,
                        latest: regionAvailability.snapshot,
                        hasRequiredConsent: settingsStore.hasExplicitListeningContextConsent
                    ))
                }
                guard !plan.selections.isEmpty else {
                    lastEmptyProvider = (primuseRelayProviderName, 0)
                    throw PrimuseAIRelayError.invalidResponse
                }
                primuseRelayRecommendationCache[cacheKey] = RecommendationCacheEntry(
                    plan: plan,
                    createdAt: now
                )
                if primuseRelayRecommendationCache.count > Self.recommendationCacheLimit,
                   let oldestKey = primuseRelayRecommendationCache.min(by: {
                       $0.value.createdAt < $1.value.createdAt
                   })?.key {
                    primuseRelayRecommendationCache[oldestKey] = nil
                }
                return .success(AIRecommendationExecution(
                    plan: plan,
                    providerName: primuseRelayProviderName,
                    fallbackDepth: 0,
                    resolvedScene: request.scene,
                    isCached: false
                ))
            } catch is CancellationError {
                return .failed(.upstream)
            } catch {
                lastFailureReason = AIRecommendationFallbackReason.classify(error)
                // A user-configured provider remains available as a fallback.
            }
        }

        let providers = settingsStore.providerSet.routedProviders.filter {
            !$0.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && AIProviderRegionPolicy.allows(
                    configuration: $0,
                    region: regionSnapshot.context.region,
                    purpose: .generation
                )
        }
        for (fallbackDepth, configuration) in providers.enumerated() {
            let effectiveFallbackDepth = fallbackDepth + customFallbackOffset
            guard AIRegionRequestPolicy.canSendRemoteRequest(
                captured: regionSnapshot,
                latest: regionAvailability.snapshot,
                configuration: configuration
            ) else { return .failed(.regionRestricted) }
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
                    fallbackDepth: effectiveFallbackDepth,
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
                ) else { return .failed(.regionRestricted) }
                guard !plan.selections.isEmpty else {
                    lastEmptyProvider = (configuration.displayName, effectiveFallbackDepth)
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
                    fallbackDepth: effectiveFallbackDepth,
                    resolvedScene: request.scene,
                    isCached: false
                ))
            } catch is CancellationError {
                return .failed(.upstream)
            } catch {
                lastFailureReason = AIRecommendationFallbackReason.classify(error)
                continue
            }
        }
        if let lastEmptyProvider {
            return .empty(
                providerName: lastEmptyProvider.name,
                fallbackDepth: lastEmptyProvider.fallbackDepth
            )
        }
        return .failed(lastFailureReason ?? .upstream)
    }

    func cachedRecommendationOutcome(
        for request: AIRecommendationRequest
    ) -> AIRecommendationOutcome? {
        let regionSnapshot = regionAvailability.snapshot
        guard isPersonalizedRecommendationsConfigured,
              !request.candidates.isEmpty else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        var customFallbackOffset = 0
        if isPrimuseRelayAvailable {
            customFallbackOffset = 1
            let key = PrimuseRelayRecommendationCacheKey(
                request: request,
                regionRevision: regionSnapshot.revision
            )
            if let cached = primuseRelayRecommendationCache[key],
               now - cached.createdAt <= Self.recommendationCacheLifetime {
                return .success(AIRecommendationExecution(
                    plan: cached.plan,
                    providerName: primuseRelayProviderName,
                    fallbackDepth: 0,
                    resolvedScene: request.scene,
                    isCached: true
                ))
            }
        }
        let providers = settingsStore.providerSet.routedProviders.filter {
            !$0.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && AIProviderRegionPolicy.allows(
                    configuration: $0,
                    region: regionSnapshot.context.region,
                    purpose: .generation
                )
        }
        for (fallbackDepth, configuration) in providers.enumerated() {
            let effectiveFallbackDepth = fallbackDepth + customFallbackOffset
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
                fallbackDepth: effectiveFallbackDepth,
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
        let configuration = await resolvedLyricsTranscriptionConfiguration()
        let decision = regionAvailability.remoteProviderDecision
        guard lyricsTranscriptionSettingsStore.isEnabled,
              AIAudioTranscriptionPolicy.supports(configuration: configuration),
              AIAudioTranscriptionPolicy.supportsInput(mimeType: mimeType),
              AIProviderRegionPolicy.allows(
                  configuration: configuration,
                  region: regionSnapshot.context.region,
                  purpose: .generation
              ),
              lyricsTranscriptionSettingsStore.hasExplicitAudioUploadConsent,
              decision.isAllowed,
              (!decision.requiresExplicitConsent
                  || lyricsTranscriptionSettingsStore.hasExplicitAudioUploadConsent),
              duration <= 0 || duration <= AIAudioTranscriptionPolicy.maximumDuration else {
            return .unavailable
        }
        let request = AIAudioTranscriptionRequest(
            audioFileURL: audioFileURL,
            mimeType: mimeType,
            displayName: displayName,
            customVocabulary: customVocabulary
        )
        let providers = [configuration].filter {
            AIAudioTranscriptionPolicy.supports(configuration: $0)
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
                    hasExplicitAudioUploadConsent: lyricsTranscriptionSettingsStore
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

    func prepareLyricsTranscriptionCredentialMigration() async {
        _ = await hasStoredLyricsTranscriptionAPIKey()
    }

    func hasStoredLyricsTranscriptionAPIKey() async -> Bool {
        let configuration = await resolvedLyricsTranscriptionConfiguration()
        let isAvailable: Bool
        if case .ready = await credentialStore.lookupAPIKey(configuration: configuration) {
            isAvailable = true
        } else {
            isAvailable = false
        }
        lyricsTranscriptionCredentialAvailable = isAvailable
        return isAvailable
    }

    func saveLyricsTranscriptionSettings(
        configuration: AIRemoteProviderConfiguration,
        isEnabled: Bool,
        hasExplicitAudioUploadConsent: Bool,
        apiKey: String?
    ) async throws {
        let normalized = LyricsTranscriptionSettingsStore
            .normalizedGoogleConfiguration(configuration)
        let decision = AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: regionAvailability.context
        )
        guard decision.isAllowed else {
            throw MusicIntelligenceError.unavailable(.regionRestricted)
        }
        guard AIAudioTranscriptionPolicy.isCompatibleEndpoint(
            configuration: normalized
        ) else {
            throw AIRemoteEndpointValidationError.unsupportedCapability
        }

        _ = await resolvedLyricsTranscriptionConfiguration()
        var hasDedicatedCredential = false
        if let apiKey,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try await credentialStore.saveAPIKey(apiKey, configuration: normalized)
            hasDedicatedCredential = true
        } else if case .ready = await credentialStore.lookupAPIKey(
            configuration: normalized
        ) {
            hasDedicatedCredential = true
        }

        try lyricsTranscriptionSettingsStore.save(
            configuration: normalized,
            isEnabled: isEnabled,
            hasExplicitAudioUploadConsent: hasExplicitAudioUploadConsent,
            credentialMigrationCompleted: hasDedicatedCredential
                || lyricsTranscriptionSettingsStore.legacyCredentialConfiguration == nil
        )
        _ = await hasStoredLyricsTranscriptionAPIKey()
    }

    func deleteLyricsTranscriptionAPIKey() async throws {
        try await credentialStore.deleteAPIKey(
            configuration: lyricsTranscriptionSettingsStore.configuration
        )
        lyricsTranscriptionSettingsStore.markCredentialMigrationCompleted()
        lyricsTranscriptionCredentialAvailable = false
    }

    private func resolvedLyricsTranscriptionConfiguration() async
        -> AIRemoteProviderConfiguration {
        _ = lyricsTranscriptionSettingsStore.adoptLegacySettingsIfNeeded(
            from: settingsStore
        )
        let dedicated = lyricsTranscriptionSettingsStore.configuration
        guard !lyricsTranscriptionSettingsStore.credentialMigrationCompleted,
              let legacy = lyricsTranscriptionSettingsStore
                .legacyCredentialConfiguration else {
            return dedicated
        }

        switch await credentialStore.lookupAPIKey(configuration: dedicated) {
        case .ready:
            lyricsTranscriptionSettingsStore.markCredentialMigrationCompleted()
            return dedicated
        case .notConfigured:
            switch await credentialStore.lookupAPIKey(configuration: legacy) {
            case .ready(let apiKey):
                do {
                    _ = try await credentialStore.saveAPIKey(
                        apiKey,
                        configuration: dedicated
                    )
                    lyricsTranscriptionSettingsStore.markCredentialMigrationCompleted()
                    return dedicated
                } catch {
                    return Self.configuration(
                        dedicated,
                        usingCredentialScopeFrom: legacy
                    )
                }
            case .notConfigured:
                lyricsTranscriptionSettingsStore.markCredentialMigrationCompleted()
                return dedicated
            case .temporarilyUnavailable, .failed:
                return Self.configuration(
                    dedicated,
                    usingCredentialScopeFrom: legacy
                )
            }
        case .temporarilyUnavailable, .failed:
            return dedicated
        }
    }

    private static func configuration(
        _ configuration: AIRemoteProviderConfiguration,
        usingCredentialScopeFrom legacy: AIRemoteProviderConfiguration
    ) -> AIRemoteProviderConfiguration {
        var resolved = configuration
        resolved.id = legacy.id
        resolved.baseURL = legacy.baseURL
        resolved.apiStyle = legacy.apiStyle
        resolved.apiPathMode = legacy.apiPathMode
        resolved.authenticationStyle = legacy.authenticationStyle
        resolved.allowInsecureLocalHTTP = legacy.allowInsecureLocalHTTP
        return resolved
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
        await prepareLyricsTranscriptionCredentialMigration()
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
        primuseRelaySemanticPlanCache.removeAll(keepingCapacity: true)
        primuseRelayRecommendationCache.removeAll(keepingCapacity: true)
    }

    func save(
        providerSet: AIRemoteProviderSet,
        primuseRelayEnabled: Bool,
        semanticSearchEnabled: Bool,
        recommendationsEnabled: Bool,
        hasExplicitRemoteConsent: Bool,
        hasExplicitListeningContextConsent: Bool,
        apiKeys: [UUID: String]
    ) async throws {
        let decision = AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: regionAvailability.context
        )
        guard decision.isAllowed else {
            throw MusicIntelligenceError.unavailable(.regionRestricted)
        }
        await prepareLyricsTranscriptionCredentialMigration()
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
        let preservesLegacyAudioSettings = settingsStore.audioTranscriptionEnabled
            && normalized.routedProviders.contains {
                AIAudioTranscriptionPolicy.supports(configuration: $0)
            }
        try settingsStore.save(
            providerSet: normalized,
            primuseRelayEnabled: primuseRelayEnabled,
            semanticSearchEnabled: semanticSearchEnabled,
            recommendationsEnabled: recommendationsEnabled,
            audioTranscriptionEnabled: preservesLegacyAudioSettings,
            hasExplicitRemoteConsent: hasExplicitRemoteConsent,
            hasExplicitListeningContextConsent: hasExplicitListeningContextConsent,
            hasExplicitAudioUploadConsent: preservesLegacyAudioSettings
                && settingsStore.hasExplicitAudioUploadConsent
        )
        semanticPlanCache.removeAll(keepingCapacity: true)
        recommendationCache.removeAll(keepingCapacity: true)
        primuseRelaySemanticPlanCache.removeAll(keepingCapacity: true)
        primuseRelayRecommendationCache.removeAll(keepingCapacity: true)
    }

    func deleteAPIKey(configuration: AIRemoteProviderConfiguration) async throws {
        _ = lyricsTranscriptionSettingsStore.adoptLegacySettingsIfNeeded(
            from: settingsStore
        )
        if !lyricsTranscriptionSettingsStore.credentialMigrationCompleted,
           lyricsTranscriptionSettingsStore.legacyCredentialConfiguration?.id
                == configuration.id {
            await prepareLyricsTranscriptionCredentialMigration()
            guard lyricsTranscriptionSettingsStore.credentialMigrationCompleted else {
                throw AICredentialStoreError.persistenceFailed
            }
        }
        try await credentialStore.deleteAPIKey(configuration: configuration)
        semanticPlanCache.removeAll(keepingCapacity: true)
        recommendationCache.removeAll(keepingCapacity: true)
        primuseRelaySemanticPlanCache.removeAll(keepingCapacity: true)
        primuseRelayRecommendationCache.removeAll(keepingCapacity: true)
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

    func testPrimuseRelayConnection(
        providerSet: AIRemoteProviderSet,
        apiKeyOverrides: [UUID: String]
    ) async -> PrimuseAIRelayConnectionReport {
        let regionSnapshot = regionAvailability.snapshot
        let decision = AIAvailabilityPolicy.decision(
            for: .bundledRemote,
            regionContext: regionSnapshot.context
        )
        guard decision.isAllowed else {
            let code = decision.denialReason == .regionRestricted
                ? "region_restricted"
                : "region_undetermined"
            return PrimuseAIRelayConnectionReport(
                outcome: .unavailable(PrimuseAIRelayDiagnostic(
                    category: .regionRestriction,
                    code: code
                )),
                fallback: await verifiedPrimuseRelayFallback(
                    providerSet: providerSet,
                    apiKeyOverrides: apiKeyOverrides
                )
            )
        }

        do {
            let authenticationMethod = try await primuseRelayClient.testConnection()
            guard regionSnapshot == regionAvailability.snapshot,
                  AIAvailabilityPolicy.decision(
                    for: .bundledRemote,
                    regionContext: regionAvailability.context
                  ).isAllowed else {
                return PrimuseAIRelayConnectionReport(
                    outcome: .unavailable(PrimuseAIRelayDiagnostic(
                        category: .regionRestriction,
                        code: "region_changed"
                    )),
                    fallback: await verifiedPrimuseRelayFallback(
                        providerSet: providerSet,
                        apiKeyOverrides: apiKeyOverrides
                    )
                )
            }
            return PrimuseAIRelayConnectionReport(
                outcome: .available(authenticationMethod),
                fallback: .none
            )
        } catch {
            return PrimuseAIRelayConnectionReport(
                outcome: .unavailable(PrimuseAIRelayDiagnostic.classify(error)),
                fallback: await verifiedPrimuseRelayFallback(
                    providerSet: providerSet,
                    apiKeyOverrides: apiKeyOverrides
                )
            )
        }
    }

    private func verifiedPrimuseRelayFallback(
        providerSet: AIRemoteProviderSet,
        apiKeyOverrides: [UUID: String]
    ) async -> PrimuseAIRelayConnectionReport.Fallback {
        let decision = AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: regionAvailability.context
        )
        guard decision.isAllowed else { return .localOnly }

        var candidates: [(index: Int, provider: AIRemoteProviderConfiguration, apiKey: String?)] = []
        for (index, configuredProvider) in providerSet.routedProviders.enumerated() {
            var provider = configuredProvider
            guard !provider.generationModel
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  AIProviderRegionPolicy.allows(
                    configuration: provider,
                    region: regionAvailability.context.region,
                    purpose: .generation
                  ) else { continue }
            provider.requestTimeout = min(
                max(provider.requestTimeout, AIRequestTimeoutPolicy.minimum),
                6
            )
            let draftKey = apiKeyOverrides[provider.id]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            candidates.append((
                index: index,
                provider: provider,
                apiKey: draftKey?.isEmpty == false ? draftKey : nil
            ))
        }
        guard !candidates.isEmpty else { return .localOnly }

        return await withTaskGroup(
            of: (Int, String?).self,
            returning: PrimuseAIRelayConnectionReport.Fallback.self
        ) { group in
            for candidate in candidates {
                group.addTask { [weak self] in
                    guard let self else { return (candidate.index, nil) }
                    do {
                        try await self.testConnection(
                            configuration: candidate.provider,
                            apiKey: candidate.apiKey
                        )
                        let name = candidate.provider.displayName
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        return (
                            candidate.index,
                            name.isEmpty
                                ? String(localized: "ai_provider_default_name")
                                : name
                        )
                    } catch {
                        return (candidate.index, nil)
                    }
                }
            }
            var verified: [(index: Int, name: String)] = []
            for await (index, name) in group {
                if let name { verified.append((index, name)) }
            }
            guard let best = verified.min(by: { $0.index < $1.index }) else {
                return .localOnly
            }
            return .remoteProvider(best.name)
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
    case localFallback(
        providerName: String?,
        fallbackDepth: Int,
        reason: AIRecommendationFallbackReason
    )
}

enum AIRecommendationContextBuilder {
    @MainActor
    static func request(
        scene: AIRecommendationScene,
        intent: String? = nil,
        candidates: [Song],
        maximumResults: Int = 12,
        minimumResults: Int = 10,
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
            maximumResults: maximumResults,
            minimumResults: minimumResults
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

    @discardableResult
    func refresh(
        scene: AIRecommendationScene,
        intent: String? = nil,
        candidates: [Song],
        using intelligence: MusicIntelligenceService,
        forceRefresh: Bool = false,
        maximumResults: Int = 12,
        minimumResults: Int = 10,
        appending: Bool = false
    ) async -> Bool {
        generation &+= 1
        let operationGeneration = generation
        let previousFeedback = feedback
        guard intelligence.settingsStore.recommendationsEnabled else {
            if !appending {
                feedback = .idle
                orderedSongIDs = []
                reasonsBySongID = [:]
            }
            return false
        }
        guard intelligence.settingsStore.hasExplicitListeningContextConsent else {
            if !appending {
                feedback = .needsConsent
                orderedSongIDs = []
                reasonsBySongID = [:]
            }
            return false
        }
        guard let request = AIRecommendationContextBuilder.request(
            scene: scene,
            intent: intent,
            candidates: candidates,
            maximumResults: maximumResults,
            minimumResults: minimumResults
        ) else {
            if !appending {
                feedback = .idle
                orderedSongIDs = []
                reasonsBySongID = [:]
            }
            return false
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
        guard operationGeneration == generation, !Task.isCancelled else { return false }
        switch outcome {
        case .unavailable:
            feedback = .localFallback(
                providerName: nil,
                fallbackDepth: 0,
                reason: .unavailable
            )
            return false
        case .success(let execution):
            if appending {
                let existingIDs = Set(orderedSongIDs)
                let additions = execution.plan.selections.filter {
                    !existingIDs.contains($0.songID)
                }
                guard !additions.isEmpty else {
                    feedback = previousFeedback
                    return false
                }
                orderedSongIDs.append(contentsOf: additions.map(\.songID))
                for selection in additions {
                    reasonsBySongID[selection.songID] = selection.reason
                }
            } else {
                orderedSongIDs = execution.plan.selections.map(\.songID)
                reasonsBySongID = Dictionary(
                    uniqueKeysWithValues: execution.plan.selections.map {
                        ($0.songID, $0.reason)
                    }
                )
            }
            feedback = .success(
                summary: execution.plan.summary,
                providerName: execution.providerName,
                fallbackDepth: execution.fallbackDepth,
                scene: execution.resolvedScene,
                isCached: execution.isCached
            )
            return true
        case .empty(let providerName, let fallbackDepth):
            feedback = .localFallback(
                providerName: providerName,
                fallbackDepth: fallbackDepth,
                reason: .empty
            )
            return false
        case .failed(let reason):
            feedback = .localFallback(
                providerName: nil,
                fallbackDepth: 0,
                reason: reason
            )
            return false
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
        case .localFallback(_, _, let reason):
            let key: String
            switch reason {
            case .unavailable, .empty:
                key = "ai_recommendation_status_failed_local"
            case .busy:
                key = "ai_recommendation_status_busy_local"
            case .minuteLimit:
                key = "ai_recommendation_status_minute_limit_local"
            case .dailyLimit:
                key = "ai_recommendation_status_daily_limit_local"
            case .regionRestricted:
                key = "ai_recommendation_status_region_restricted_local"
            case .deviceRegistration:
                key = "ai_recommendation_status_device_registration_local"
            case .authentication:
                key = "ai_recommendation_status_authentication_local"
            case .network:
                key = "ai_recommendation_status_network_local"
            case .upstream:
                key = "ai_recommendation_status_upstream_local"
            }
            return String(localized: String.LocalizationValue(key))
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
