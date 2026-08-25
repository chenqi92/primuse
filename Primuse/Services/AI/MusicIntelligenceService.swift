import Foundation
import Observation
import PrimuseKit

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
        let configuration = settingsStore.configuration
        let decision = regionAvailability.remoteProviderDecision
        return configuration.isEnabled
            && !configuration.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && settingsStore.hasExplicitRemoteConsent
            && decision.isAllowed
            && (!decision.requiresExplicitConsent || settingsStore.hasExplicitRemoteConsent)
    }

    func semanticSearchPlan(for query: String) async -> AISemanticSearchPlan? {
        let configuration = settingsStore.configuration
        let consent = settingsStore.hasExplicitRemoteConsent
        let regionSnapshot = regionAvailability.snapshot
        let region = regionSnapshot.context
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSemanticSearchConfigured, !trimmedQuery.isEmpty else { return nil }

        let languageCode = Locale.current.language.languageCode?.identifier ?? ""
        let cacheKey = SemanticPlanCacheKey(
            profileID: configuration.id,
            baseURL: configuration.baseURL,
            model: configuration.generationModel,
            apiStyle: configuration.apiStyle,
            query: trimmedQuery.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            ),
            languageCode: languageCode,
            regionRevision: regionSnapshot.revision
        )
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = semanticPlanCache[cacheKey],
           now - cached.createdAt <= Self.semanticPlanCacheLifetime {
            return cached.plan
        }

        do {
            guard AIRegionRequestPolicy.canSendRemoteRequest(
                captured: regionSnapshot,
                latest: regionAvailability.snapshot
            ) else { return nil }
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
            ) else { return nil }
            guard !plan.expandedTerms.isEmpty || !plan.themes.isEmpty || !plan.moods.isEmpty else {
                return nil
            }
            semanticPlanCache[cacheKey] = SemanticPlanCacheEntry(plan: plan, createdAt: now)
            if semanticPlanCache.count > Self.semanticPlanCacheLimit,
               let oldestKey = semanticPlanCache.min(by: {
                   $0.value.createdAt < $1.value.createdAt
               })?.key {
                semanticPlanCache[oldestKey] = nil
            }
            return plan
        } catch {
            return nil
        }
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
        _ = try AIRemoteEndpointPolicy.validatedBaseURL(
            configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        )
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

    func deleteAPIKey(configuration: AIRemoteProviderConfiguration) async throws {
        try await credentialStore.deleteAPIKey(configuration: configuration)
        semanticPlanCache.removeAll(keepingCapacity: true)
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

    private func withTimeout<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let nanoseconds = UInt64(max(0.1, seconds) * 1_000_000_000)
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
