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

@MainActor
@Observable
final class MusicIntelligenceService {
    let settingsStore: AISettingsStore
    let regionAvailability: AIRegionAvailabilityService

    private let credentialStore: any AICredentialStoring
    private let engine: MusicIntelligenceEngine
    @ObservationIgnored private var semanticPlanCache: [SemanticPlanCacheKey: SemanticPlanCacheEntry] = [:]

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

    private static let semanticPlanCacheLifetime: TimeInterval = 15 * 60
    private static let semanticPlanCacheLimit = 64

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
        }
    }

    var shouldExposeRemoteConfiguration: Bool {
        regionAvailability.remoteProviderDecision.shouldExposeConfiguration
    }

    var isSemanticSearchConfigured: Bool {
        let decision = regionAvailability.remoteProviderDecision
        return settingsStore.semanticSearchEnabled
            && settingsStore.providerSet.routedProviders.contains {
                !$0.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            && settingsStore.hasExplicitRemoteConsent
            && decision.isAllowed
            && (!decision.requiresExplicitConsent || settingsStore.hasExplicitRemoteConsent)
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
        }
        var lastEmptyProvider: (name: String, fallbackDepth: Int)?
        for (fallbackDepth, configuration) in providers.enumerated() {
            guard AIRegionRequestPolicy.canSendRemoteRequest(
                captured: regionSnapshot,
                latest: regionAvailability.snapshot
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
                    requestAuthorization: regionAuthorization(for: regionSnapshot)
                )
                guard AIRegionRequestPolicy.canCommitRemoteResponse(
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot
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
                    latest: regionAvailability.snapshot
                  ) else { continue }
            do {
                let translations = try await engine.translateLyrics(
                    candidates,
                    targetLanguageCode: targetLanguageCode,
                    configuration: configuration,
                    requestAuthorization: regionAuthorization(for: regionSnapshot)
                )
                guard AIRegionRequestPolicy.canCommitRemoteResponse(
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot
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
    }

    func save(
        providerSet: AIRemoteProviderSet,
        semanticSearchEnabled: Bool,
        hasExplicitRemoteConsent: Bool,
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
            hasExplicitRemoteConsent: hasExplicitRemoteConsent
        )
        semanticPlanCache.removeAll(keepingCapacity: true)
    }

    func deleteAPIKey(configuration: AIRemoteProviderConfiguration) async throws {
        try await credentialStore.deleteAPIKey(configuration: configuration)
        semanticPlanCache.removeAll(keepingCapacity: true)
    }

    func availableModels(
        configuration: AIRemoteProviderConfiguration,
        hasExplicitRemoteConsent: Bool,
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
        guard !decision.requiresExplicitConsent || hasExplicitRemoteConsent else {
            throw MusicIntelligenceError.unavailable(.missingConfiguration)
        }
        let models = try await engine.listModels(
            configuration: configuration,
            apiKeyOverride: apiKey,
            requestAuthorization: regionAuthorization(for: regionSnapshot)
        )
        guard AIRegionRequestPolicy.canCommitRemoteResponse(
            captured: regionSnapshot,
            latest: regionAvailability.snapshot
        ) else {
            throw MusicIntelligenceError.unavailable(.temporarilyUnavailable)
        }
        return models
    }

    func testConnection(
        configuration: AIRemoteProviderConfiguration,
        hasExplicitRemoteConsent: Bool,
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
        guard !decision.requiresExplicitConsent || hasExplicitRemoteConsent else {
            throw MusicIntelligenceError.unavailable(.missingConfiguration)
        }

        var enabledConfiguration = configuration
        enabledConfiguration.isEnabled = true
        _ = try await engine.interpretSearch(
            AISemanticSearchRequest(
                query: "quiet evening music",
                languageCode: "en",
                maximumExpansionTerms: 2
            ),
            configuration: enabledConfiguration,
            regionContext: region,
            hasExplicitRemoteConsent: hasExplicitRemoteConsent,
            apiKeyOverride: apiKey,
            requestAuthorization: regionAuthorization(for: regionSnapshot)
        )
        guard AIRegionRequestPolicy.canCommitRemoteResponse(
            captured: regionSnapshot,
            latest: regionAvailability.snapshot
        ) else {
            throw MusicIntelligenceError.unavailable(.temporarilyUnavailable)
        }
    }

    private func regionAuthorization(
        for captured: AIRegionSnapshot
    ) -> @Sendable () async -> Bool {
        let availability = regionAvailability
        return {
            await MainActor.run {
                AIRegionRequestPolicy.canSendRemoteRequest(
                    captured: captured,
                    latest: availability.snapshot
                )
            }
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
        requestAuthorization: @escaping @Sendable () async -> Bool
    ) async throws -> [String: String] {
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
