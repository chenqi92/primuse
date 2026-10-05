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

struct AITagCleanupExecution: Sendable {
    var proposals: [TagCleanupProposal] = []
    /// Batches no service answered; they were skipped.
    var failedBatches = 0
    /// The first service that answered.
    var providerName: String?
    /// The built-in AI stopped taking batches partway (today's allowance
    /// used up, or the service not offered); the rest went to the
    /// listener's own service, or were skipped when there is none.
    var primuseRelayStopped = false
}

struct AISongDiscoveryExecution: Sendable {
    var suggestions: [SongDiscoverySuggestion]
    var providerName: String
}

/// Why a request about library content (new-song discovery, album/artist
/// intros) got no answer.
enum AILibraryContentFailure: Equatable, Sendable {
    /// Neither the built-in AI nor an own service can be asked.
    case notConfigured
    /// A service is there; only the permission to send content is missing.
    case needsConsent
    /// The built-in AI does not offer this feature (yet) and there is no
    /// own service to ask instead.
    case builtInNotOffered
    /// The library has nothing to base the request on.
    case noTasteProfile
    case failed(AIRecommendationFallbackReason)
}

enum AISongDiscoveryOutcome: Sendable {
    case success(AISongDiscoveryExecution)
    case failed(AILibraryContentFailure, retryAt: Date? = nil)
}

enum AILibraryInsightOutcome: Sendable {
    case success(LibraryInsightAIExchange.Answer, providerName: String)
    case failed(AILibraryContentFailure, retryAt: Date? = nil)
}

enum AIListeningMoodOutcome: Sendable {
    case success(ListeningMoodAIExchange.Answer, providerName: String)
    case failed(AILibraryContentFailure, retryAt: Date? = nil)
}

struct AIListeningIntentExecution: Sendable {
    var drafts: [ListeningIntentAIExchange.Draft]
    var providerName: String
}

enum AIListeningIntentOutcome: Sendable {
    case success(AIListeningIntentExecution)
    /// Nothing could be asked, or nobody answered usefully; the device's own
    /// intents stand. `retryAt` is the relay's own back-off when it gave one.
    case unavailable(retryAt: Date? = nil)
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
    /// 内置 AI 今天的听歌识词次数已经用完。
    case limitReached
    /// 内置 AI 这个月(订阅周期)的听歌识词次数已经用完。
    case monthlyLimitReached
    /// 当前套餐没有听歌识词。
    case notInPlan
    /// 内置 AI 只收 10 分钟以内的歌(资料库里没有时长时才会走到服务端才知道)。
    case tooLong
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
    case failed(AIRecommendationFallbackReason, retryAt: Date? = nil)
}

enum AIRecommendationFallbackReason: Equatable, Sendable {
    case unavailable
    case empty
    case busy
    case minuteLimit
    case dailyLimit
    /// 这个月(订阅周期)的次数用完了,要等下个周期。
    case monthlyLimit
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
            if case .requestFailed(let statusCode, let code, _) = relayError {
                switch code {
                case "concurrency_limited", "upstreams_busy":
                    return .busy
                case "minute_request_limit_exhausted", "edge_rate_limited",
                     "installation_rate_limited":
                    return .minuteLimit
                case "daily_request_limit_exhausted", "daily_quota_exhausted",
                     "feature_quota_exhausted":
                    return .dailyLimit
                case "period_quota_exhausted":
                    return .monthlyLimit
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
                if let retryAt = (error as? PrimuseAIRelayError)?.retryAt {
                    guard retryAt.timeIntervalSinceNow <= 2 else { throw error }
                    try await Task.sleep(for: .seconds(max(0, retryAt.timeIntervalSinceNow)))
                } else {
                    try await Task.sleep(for: retryDelay)
                }
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
    /// 内置 AI 的后台有没有配好转写模型(service-info 说的),且当前套餐能用;没问到
    /// 之前当作没有,免得给出一个点了必失败的入口。
    private(set) var builtInTranscriptionOffered = false
    /// 后台开放了听歌识词,但当前套餐没有(免费档不给,或转写线路只留给更高的套餐)。
    private(set) var builtInTranscriptionNotInPlan = false
    @ObservationIgnored private var builtInTranscriptionCheckedAt: Date?

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
    private let recommendationReuseStore: AIRecommendationReuseStore

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
        credentialStore: any AICredentialStoring = AICredentialStore(),
        recommendationReuseDefaults: UserDefaults = .standard
    ) {
        self.settingsStore = settingsStore
        recommendationReuseStore = AIRecommendationReuseStore(defaults: recommendationReuseDefaults)
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
            await self?.refreshBuiltInTranscriptionOffer()
        }
    }

    /// 问一次内置 AI 有没有开放听歌识词;半小时内问过就不再问(`force` 除外)。
    /// 内置 AI 关着时不问。套餐要签名请求才查得到,只在选了内置 AI 识别或打开
    /// 设置页(`force`)时查;查不到套餐就只看后台开没开。
    func refreshBuiltInTranscriptionOffer(force: Bool = false) async {
        guard settingsStore.primuseRelayEnabled,
              PrimuseAIRelayClient.isSupportedOnCurrentDevice else { return }
        if !force, let checkedAt = builtInTranscriptionCheckedAt,
           Date().timeIntervalSince(checkedAt) < 30 * 60 {
            return
        }
        guard let offered = await primuseRelayClient.isAudioTranscriptionOffered() else { return }
        var inPlan = true
        if offered, force || lyricsTranscriptionSettingsStore.usesBuiltIn,
           let planned = await primuseRelayClient.isAudioTranscriptionInPlan() {
            inPlan = planned
        }
        builtInTranscriptionCheckedAt = Date()
        builtInTranscriptionOffered = offered && inPlan
        builtInTranscriptionNotInPlan = offered && !inPlan
    }

    /// 内置 AI 这条路现在能不能用(不看用户选没选它)。
    var isBuiltInTranscriptionReady: Bool {
        settingsStore.primuseRelayEnabled
            && PrimuseAIRelayClient.isSupportedOnCurrentDevice
            && AIAvailabilityPolicy.decision(
                for: .bundledRemote,
                regionContext: regionAvailability.context
            ).isAllowed
            && builtInTranscriptionOffered
    }

    /// 这首歌现在能不能听歌识词:设置都齐了,且按所选的服务看格式和时长。
    /// Apple Music 的歌拿不到音频,CUE 分轨只是整轨文件里的一段。
    func canTranscribeAudio(of song: Song) -> Bool {
        isAudioTranscriptionConfigured
            && song.sourceID != AppleMusicLibraryIdentity.sourceID
            && song.cueSheetPath == nil
            && AIAudioTranscriptionPolicy.canTranscribe(
                format: song.fileFormat,
                duration: song.duration,
                builtIn: lyricsTranscriptionSettingsStore.usesBuiltIn,
                ownKey: !lyricsTranscriptionSettingsStore.usesBuiltIn
            )
    }

    var shouldExposeRemoteConfiguration: Bool {
        regionAvailability.remoteProviderDecision.shouldExposeConfiguration
    }

    var shouldShowRemoteRecommendations: Bool {
        settingsStore.recommendationsEnabled && shouldExposeRemoteConfiguration
    }

    /// 这个功能要不要先问内置 AI:按智能设置里的分工,跟随默认的看内置 AI 开没开。
    private func asksBuiltInFirst(_ feature: AIFeature) -> Bool {
        settingsStore.providerSet.asksBuiltInFirst(
            for: feature,
            relayEnabled: settingsStore.primuseRelayEnabled
        )
    }

    private func isPrimuseRelayAvailable(for feature: AIFeature) -> Bool {
        let decision = AIAvailabilityPolicy.decision(
            for: .bundledRemote,
            regionContext: regionAvailability.context
        )
        return asksBuiltInFirst(feature)
            && PrimuseAIRelayClient.isSupportedOnCurrentDevice
            && decision.isAllowed
    }

    private var primuseRelayProviderName: String {
        String(localized: "ai_primuse_relay_name")
    }

    private func canUsePrimuseRelay(
        feature: AIFeature,
        captured: AIRegionSnapshot,
        latest: AIRegionSnapshot,
        hasRequiredConsent: Bool
    ) -> Bool {
        guard captured == latest,
              hasRequiredConsent,
              asksBuiltInFirst(feature),
              PrimuseAIRelayClient.isSupportedOnCurrentDevice else { return false }
        return AIAvailabilityPolicy.decision(
            for: .bundledRemote,
            regionContext: latest.context
        ).isAllowed
    }

    private func primuseRelayFallbackReason(
        feature: AIFeature,
        captured: AIRegionSnapshot,
        latest: AIRegionSnapshot,
        hasRequiredConsent: Bool
    ) -> AIRecommendationFallbackReason {
        guard hasRequiredConsent, asksBuiltInFirst(feature) else {
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
        let hasCustomProvider = settingsStore.providerSet.routedProviders(for: .semanticSearch).contains {
                !$0.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && AIProviderRegionPolicy.allows(
                        configuration: $0,
                        region: regionAvailability.context.region,
                        purpose: .generation
                    )
            }
            && decision.isAllowed
            && (!decision.requiresExplicitConsent || settingsStore.hasExplicitRemoteConsent)
        return isPrimuseRelayAvailable(for: .semanticSearch) || hasCustomProvider
    }

    var isPersonalizedRecommendationsConfigured: Bool {
        let decision = regionAvailability.remoteProviderDecision
        guard settingsStore.recommendationsEnabled,
              settingsStore.hasExplicitListeningContextConsent else { return false }
        let hasCustomProvider = settingsStore.providerSet.routedProviders(for: .recommendations).contains {
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
        return isPrimuseRelayAvailable(for: .recommendations) || hasCustomProvider
    }

    var isAudioTranscriptionConfigured: Bool {
        if lyricsTranscriptionSettingsStore.usesBuiltIn {
            return lyricsTranscriptionSettingsStore.isEnabled
                && lyricsTranscriptionSettingsStore.hasExplicitAudioUploadConsent
                && isBuiltInTranscriptionReady
        }
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

    func semanticSearchOutcome(
        for query: String,
        onStreamEvent: ((AISemanticSearchStreamEvent) async -> Void)? = nil
    ) async -> AISemanticSearchOutcome {
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

        if isPrimuseRelayAvailable(for: .semanticSearch) {
            guard canUsePrimuseRelay(
                feature: .semanticSearch,
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
                let plan: AISemanticSearchPlan
                if let onStreamEvent {
                    var completedPlan: AISemanticSearchPlan?
                    for try await event in await primuseRelayClient.semanticSearchEvents(request) {
                        try Task.checkCancellation()
                        guard canUsePrimuseRelay(
                            feature: .semanticSearch,
                            captured: regionSnapshot,
                            latest: regionAvailability.snapshot,
                            hasRequiredConsent: settingsStore.hasExplicitRemoteConsent
                        ) else { return .failed }
                        switch event {
                        case .reset, .term:
                            await onStreamEvent(event)
                        case .completed(let value):
                            completedPlan = value
                        }
                    }
                    guard let completedPlan else {
                        throw PrimuseAIRelayError.invalidResponse
                    }
                    plan = completedPlan
                } else {
                    plan = try await primuseRelayClient.interpretSearch(request)
                }
                guard canUsePrimuseRelay(
                    feature: .semanticSearch,
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

        let providers = settingsStore.providerSet.routedProviders(for: .semanticSearch).filter {
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
        targetLanguageCode: String,
        onStreamEvent: ((AILyricsTranslationStreamEvent) -> Void)? = nil
    ) async -> AILyricsTranslationExecution? {
        let regionSnapshot = regionAvailability.snapshot
        let consent = settingsStore.hasExplicitRemoteConsent
        guard consent, !candidates.isEmpty else { return nil }

        var customFallbackOffset = 0
        if isPrimuseRelayAvailable(for: .lyricsTranslation) {
            guard canUsePrimuseRelay(
                feature: .lyricsTranslation,
                captured: regionSnapshot,
                latest: regionAvailability.snapshot,
                hasRequiredConsent: settingsStore.hasExplicitRemoteConsent
            ) else { return nil }
            customFallbackOffset = 1
            do {
                let translations: [String: String]
                if let onStreamEvent {
                    var completedTranslations: [String: String]?
                    for try await event in await primuseRelayClient.lyricsTranslationEvents(
                        candidates,
                        targetLanguageCode: targetLanguageCode
                    ) {
                        try Task.checkCancellation()
                        guard canUsePrimuseRelay(
                            feature: .lyricsTranslation,
                            captured: regionSnapshot,
                            latest: regionAvailability.snapshot,
                            hasRequiredConsent: settingsStore.hasExplicitRemoteConsent
                        ) else { return nil }
                        switch event {
                        case .reset, .translation:
                            onStreamEvent(event)
                        case .completed(let value):
                            completedTranslations = value
                        }
                    }
                    guard let completedTranslations else {
                        throw PrimuseAIRelayError.invalidResponse
                    }
                    translations = completedTranslations
                } else {
                    translations = try await primuseRelayClient.translateLyrics(
                        candidates,
                        targetLanguageCode: targetLanguageCode
                    )
                }
                guard canUsePrimuseRelay(
                    feature: .lyricsTranslation,
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

        for (fallbackDepth, configuration) in settingsStore.providerSet.routedProviders(for: .lyricsTranslation).enumerated() {
            let effectiveFallbackDepth = fallbackDepth + customFallbackOffset
            guard !configuration.generationModel
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  AIRegionRequestPolicy.canSendRemoteRequest(
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    configuration: configuration
                  ) else { continue }
            do {
                let engine = engine
                let regionContext = regionSnapshot.context
                let requestAuthorization = regionAuthorization(
                    for: regionSnapshot,
                    configuration: configuration
                )
                let translate: @Sendable (
                    (@Sendable (_ id: String, _ text: String) -> Void)?
                ) async throws -> [String: String] = { onTranslation in
                    try await engine.translateLyrics(
                        candidates,
                        targetLanguageCode: targetLanguageCode,
                        configuration: configuration,
                        regionContext: regionContext,
                        hasExplicitRemoteConsent: consent,
                        requestAuthorization: requestAuthorization,
                        onTranslation: onTranslation
                    )
                }
                let translations: [String: String]
                if let onStreamEvent {
                    translations = try await Self.forwardingProgress(
                        { report in try await translate { id, text in report((id, text)) } },
                        to: { [regionAvailability] line in
                            guard AIRegionRequestPolicy.canCommitRemoteResponse(
                                captured: regionSnapshot,
                                latest: regionAvailability.snapshot,
                                configuration: configuration
                            ) else { return }
                            onStreamEvent(.translation(id: line.0, text: line.1))
                        }
                    )
                } else {
                    translations = try await translate(nil)
                }
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

    /// Whether tag cleanup has an AI service to ask: the built-in AI, or a
    /// user-configured provider with a generation model. Either way remote
    /// processing must be agreed to and the region must allow it.
    var isTagCleanupAvailable: Bool { isLibraryContentAvailable(for: .tagCleanup) }

    /// Tag cleanup has a service to ask and only the permission to send
    /// content is missing: the tidy-up page offers to turn it on in place.
    var tagCleanupNeedsRemoteConsent: Bool { libraryContentNeedsRemoteConsent(for: .tagCleanup) }

    /// A library-content feature (tag cleanup, discovery, intros, "for you"
    /// intents) has the service its route names, or a fallback, to ask.
    private func isLibraryContentAvailable(for feature: AIFeature) -> Bool {
        guard settingsStore.hasExplicitRemoteConsent else { return false }
        if isPrimuseRelayAvailable(for: feature) { return true }
        return canUseOwnProviders(for: feature, regionContext: regionAvailability.snapshot.context)
    }

    private func libraryContentNeedsRemoteConsent(for feature: AIFeature) -> Bool {
        !settingsStore.hasExplicitRemoteConsent
            && (isPrimuseRelayAvailable(for: feature)
                || canUseOwnProviders(for: feature, regionContext: regionAvailability.snapshot.context))
    }

    /// Turns on sending content to AI services from a feature's own prompt,
    /// keeping every other stored setting as it is.
    func grantRemoteConsent() throws {
        guard !settingsStore.hasExplicitRemoteConsent else { return }
        try settingsStore.save(
            providerSet: settingsStore.providerSet,
            primuseRelayEnabled: settingsStore.primuseRelayEnabled,
            semanticSearchEnabled: settingsStore.semanticSearchEnabled,
            recommendationsEnabled: settingsStore.recommendationsEnabled,
            audioTranscriptionEnabled: settingsStore.audioTranscriptionEnabled,
            hasExplicitRemoteConsent: true,
            hasExplicitListeningContextConsent: settingsStore.hasExplicitListeningContextConsent,
            hasExplicitAudioUploadConsent: settingsStore.hasExplicitAudioUploadConsent
        )
    }

    /// 首页指引卡上的「开启」:打开内置 AI、语义搜索与场景推荐,连同这两项能力
    /// 需要的两项授权(卡片上写明了会发送什么);自己的服务和其它设置原样保留。
    func enableBuiltInIntelligence() throws {
        try settingsStore.save(
            providerSet: settingsStore.providerSet,
            primuseRelayEnabled: true,
            semanticSearchEnabled: true,
            recommendationsEnabled: true,
            audioTranscriptionEnabled: settingsStore.audioTranscriptionEnabled,
            hasExplicitRemoteConsent: true,
            hasExplicitListeningContextConsent: true,
            hasExplicitAudioUploadConsent: settingsStore.hasExplicitAudioUploadConsent
        )
    }

    private func canUseOwnProviders(for feature: AIFeature, regionContext: AIRegionContext) -> Bool {
        guard AIAvailabilityPolicy.decision(
            for: .userConfiguredRemote,
            regionContext: regionContext
        ).isAllowed else { return false }
        return settingsStore.providerSet.routedProviders(for: feature).contains {
            !$0.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Asks for tag corrections batch by batch: the built-in AI first, then
    /// the listener's own services, as everywhere else. A batch nobody
    /// answers is skipped and counted, so a partial result is still usable.
    /// `onProgress` gets (batches done, batches total).
    func tagCleanupProposals(
        for songs: [TagCleanupSong],
        onProgress: @escaping @MainActor (Int, Int) -> Void
    ) async -> AITagCleanupExecution {
        var execution = AITagCleanupExecution()
        guard isTagCleanupAvailable, !songs.isEmpty else { return execution }
        let consent = settingsStore.hasExplicitRemoteConsent
        // Reasons come back in the language the review screen is shown in.
        let languageCode = Bundle.main.preferredLocalizations.first ?? "en"
        let currentYear = Calendar.current.component(.year, from: Date())
        let limited = Array(songs.prefix(TagCleanupAIExchange.maximumSongs))
        let batches = stride(from: 0, to: limited.count, by: TagCleanupAIExchange.batchSize).map {
            Array(limited[$0..<min($0 + TagCleanupAIExchange.batchSize, limited.count)])
        }
        var usesPrimuseRelay = isPrimuseRelayAvailable(for: .tagCleanup)
        onProgress(0, batches.count)
        for (index, batch) in batches.enumerated() {
            if Task.isCancelled { break }
            let regionSnapshot = regionAvailability.snapshot
            var answered = false

            if usesPrimuseRelay, canUsePrimuseRelay(
                feature: .tagCleanup,
                captured: regionSnapshot,
                latest: regionAvailability.snapshot,
                hasRequiredConsent: settingsStore.hasExplicitRemoteConsent
            ) {
                do {
                    let proposals = try await primuseRelayClient.tagCleanup(
                        batch,
                        languageCode: languageCode,
                        currentYear: currentYear
                    )
                    if canUsePrimuseRelay(
                        feature: .tagCleanup,
                        captured: regionSnapshot,
                        latest: regionAvailability.snapshot,
                        hasRequiredConsent: settingsStore.hasExplicitRemoteConsent
                    ) {
                        execution.proposals += proposals
                        execution.providerName = execution.providerName ?? primuseRelayProviderName
                        answered = true
                    }
                } catch is CancellationError {
                    return execution
                } catch {
                    if Self.primuseRelayStopsTagCleanup(after: error) {
                        usesPrimuseRelay = false
                        execution.primuseRelayStopped = true
                    }
                }
            }

            if !answered, canUseOwnProviders(for: .tagCleanup, regionContext: regionSnapshot.context) {
                for configuration in settingsStore.providerSet.routedProviders(for: .tagCleanup) {
                    guard !configuration.generationModel
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          AIRegionRequestPolicy.canSendRemoteRequest(
                            captured: regionSnapshot,
                            latest: regionAvailability.snapshot,
                            configuration: configuration
                          ) else { continue }
                    do {
                        let proposals = try await engine.proposeTagCleanup(
                            batch,
                            languageCode: languageCode,
                            currentYear: currentYear,
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
                        ) else { continue }
                        execution.proposals += proposals
                        execution.providerName = execution.providerName ?? configuration.displayName
                        answered = true
                        break
                    } catch is CancellationError {
                        return execution
                    } catch {
                        continue
                    }
                }
            }
            if !answered { execution.failedBatches += 1 }
            onProgress(index + 1, batches.count)
        }
        return execution
    }

    /// Failures after which the built-in AI will not take the next batch
    /// either: today's allowance is spent, the service does not offer tag
    /// cleanup, or this device cannot sign in. A busy upstream, a bad answer
    /// or a batch refused for its content says nothing about the next one.
    nonisolated static func primuseRelayStopsTagCleanup(after error: Error) -> Bool {
        guard let relayError = error as? PrimuseAIRelayError else { return false }
        switch relayError {
        case .requestFailed(let statusCode, let code, _):
            if [
                "daily_quota_exhausted",
                "feature_quota_exhausted",
                "daily_request_limit_exhausted",
                "period_quota_exhausted",
            ].contains(code) { return true }
            return [400, 401, 403, 404, 501].contains(statusCode)
        case .invalidResponse, .responseTooLarge:
            return false
        case .unsupportedDevice, .credentialUnavailable, .credentialCorrupted,
             .credentialPersistenceFailed, .storeKitTransactionUnavailable,
             .storeKitTransactionUnverified, .storeKitAuthenticationCancelled:
            return true
        }
    }

    /// Whether new-song discovery has an AI service to ask. It sends the
    /// library's genre/artist/decade profile, so it takes the same consent
    /// as other library content (tag cleanup, semantic search).
    var isSongDiscoveryAvailable: Bool { isLibraryContentAvailable(for: .songDiscovery) }

    var songDiscoveryNeedsRemoteConsent: Bool { libraryContentNeedsRemoteConsent(for: .songDiscovery) }

    /// Real songs outside the library that fit its taste: the built-in AI
    /// first, then the listener's own services. The answer is validated
    /// and still has to be checked against the library by the caller.
    func discoverSongs(_ request: SongDiscoveryAIExchange.Request) async -> AISongDiscoveryOutcome {
        let currentYear = Calendar.current.component(.year, from: Date())
        let run = await runLibraryContentRequest(
            feature: .songDiscovery,
            label: "Song discovery",
            relay: { try await self.primuseRelayClient.songDiscovery(request, currentYear: currentYear) },
            custom: { configuration, snapshot, consent in
                try await self.engine.discoverSongs(
                    request,
                    currentYear: currentYear,
                    configuration: configuration,
                    regionContext: snapshot.context,
                    hasExplicitRemoteConsent: consent,
                    requestAuthorization: self.regionAuthorization(for: snapshot, configuration: configuration)
                )
            }
        )
        switch run {
        case .success(let suggestions, let providerName):
            return .success(AISongDiscoveryExecution(suggestions: suggestions, providerName: providerName))
        case .failure(let failure, let retryAt):
            return .failed(failure, retryAt: retryAt)
        }
    }

    /// Album/artist intros take the same consent and services as the other
    /// library-content requests.
    var isLibraryInsightAvailable: Bool { isLibraryContentAvailable(for: .libraryInsight) }

    var libraryInsightNeedsRemoteConsent: Bool { libraryContentNeedsRemoteConsent(for: .libraryInsight) }

    /// A short intro for one album or artist: the built-in AI first, then the
    /// listener's own services. An answer saying the AI does not know the
    /// album/artist is a success with `known == false`.
    func libraryInsight(_ request: LibraryInsightAIExchange.Request) async -> AILibraryInsightOutcome {
        let run = await runLibraryContentRequest(
            feature: .libraryInsight,
            label: "Library insight",
            relay: { try await self.primuseRelayClient.libraryInsight(request) },
            custom: { configuration, snapshot, consent in
                try await self.engine.libraryInsight(
                    request,
                    configuration: configuration,
                    regionContext: snapshot.context,
                    hasExplicitRemoteConsent: consent,
                    requestAuthorization: self.regionAuthorization(for: snapshot, configuration: configuration)
                )
            }
        )
        switch run {
        case .success(let answer, let providerName):
            return .success(answer, providerName: providerName)
        case .failure(let failure, let retryAt):
            return .failed(failure, retryAt: retryAt)
        }
    }

    /// 听歌状态解读要发的是播放习惯（时长、时段、常听的艺人），所以除了发送内容的授权，
    /// 还要「发送听歌情况」那一项。
    var isListeningMoodAvailable: Bool {
        settingsStore.hasExplicitListeningContextConsent && isLibraryContentAvailable(for: .listeningMood)
    }

    /// 有服务可问、只差授权：状态卡上就地给出开启的按钮。
    var listeningMoodNeedsConsent: Bool {
        let hasService = isPrimuseRelayAvailable(for: .listeningMood)
            || canUseOwnProviders(for: .listeningMood, regionContext: regionAvailability.snapshot.context)
        return hasService
            && (!settingsStore.hasExplicitRemoteConsent || !settingsStore.hasExplicitListeningContextConsent)
    }

    /// 状态卡上的「开启」：只补上这项功能要的两项授权，其余设置原样保留。
    func grantListeningMoodConsent() throws {
        guard !settingsStore.hasExplicitRemoteConsent
                || !settingsStore.hasExplicitListeningContextConsent else { return }
        try settingsStore.save(
            providerSet: settingsStore.providerSet,
            primuseRelayEnabled: settingsStore.primuseRelayEnabled,
            semanticSearchEnabled: settingsStore.semanticSearchEnabled,
            recommendationsEnabled: settingsStore.recommendationsEnabled,
            audioTranscriptionEnabled: settingsStore.audioTranscriptionEnabled,
            hasExplicitRemoteConsent: true,
            hasExplicitListeningContextConsent: true,
            hasExplicitAudioUploadConsent: settingsStore.hasExplicitAudioUploadConsent
        )
    }

    /// 最近 30 天的听歌状态：内置 AI 先，再是自己的服务。
    func listeningMood(_ request: ListeningMoodAIExchange.Request) async -> AIListeningMoodOutcome {
        guard settingsStore.hasExplicitListeningContextConsent else {
            return .failed(listeningMoodNeedsConsent ? .needsConsent : .notConfigured)
        }
        let run = await runLibraryContentRequest(
            feature: .listeningMood,
            label: "Listening mood",
            relay: { try await self.primuseRelayClient.listeningMood(request) },
            custom: { configuration, snapshot, consent in
                try await self.engine.listeningMood(
                    request,
                    configuration: configuration,
                    regionContext: snapshot.context,
                    hasExplicitRemoteConsent: consent,
                    requestAuthorization: self.regionAuthorization(for: snapshot, configuration: configuration)
                )
            }
        )
        switch run {
        case .success(let answer, let providerName):
            return .success(answer, providerName: providerName)
        case .failure(let failure, let retryAt):
            return .failed(failure, retryAt: retryAt)
        }
    }

    private enum LibraryContentRun<Value: Sendable> {
        case success(Value, providerName: String)
        case failure(AILibraryContentFailure, retryAt: Date?)
    }

    /// The built-in AI first, then each of the listener's own services with a
    /// generation model, under the remote-content consent. The failure that
    /// is reported is the own service's when one was asked, else the relay's.
    private func runLibraryContentRequest<Value: Sendable>(
        feature: AIFeature,
        label: String,
        relay: () async throws -> Value,
        custom: (AIRemoteProviderConfiguration, AIRegionSnapshot, Bool) async throws -> Value
    ) async -> LibraryContentRun<Value> {
        guard settingsStore.hasExplicitRemoteConsent else {
            return .failure(
                libraryContentNeedsRemoteConsent(for: feature) ? .needsConsent : .notConfigured,
                retryAt: nil
            )
        }
        let consent = settingsStore.hasExplicitRemoteConsent
        let regionSnapshot = regionAvailability.snapshot
        var relayError: Error?
        var customError: Error?

        if isPrimuseRelayAvailable(for: feature), canUsePrimuseRelay(
            feature: feature,
            captured: regionSnapshot,
            latest: regionAvailability.snapshot,
            hasRequiredConsent: consent
        ) {
            do {
                let value = try await relay()
                if canUsePrimuseRelay(
                    feature: feature,
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    hasRequiredConsent: settingsStore.hasExplicitRemoteConsent
                ) {
                    return .success(value, providerName: primuseRelayProviderName)
                }
            } catch is CancellationError {
                return .failure(.failed(.upstream), retryAt: nil)
            } catch {
                relayError = error
                plog("🎵 \(label): built-in AI failed reason=\(AIRecommendationFallbackReason.classify(error)) unsupported=\(Self.primuseRelayDoesNotOfferFeature(error))")
            }
        }

        if canUseOwnProviders(for: feature, regionContext: regionSnapshot.context) {
            for configuration in settingsStore.providerSet.routedProviders(for: feature) {
                guard !configuration.generationModel
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      AIRegionRequestPolicy.canSendRemoteRequest(
                        captured: regionSnapshot,
                        latest: regionAvailability.snapshot,
                        configuration: configuration
                      ) else { continue }
                do {
                    let value = try await custom(configuration, regionSnapshot, consent)
                    guard AIRegionRequestPolicy.canCommitRemoteResponse(
                        captured: regionSnapshot,
                        latest: regionAvailability.snapshot,
                        configuration: configuration
                    ) else { continue }
                    return .success(value, providerName: configuration.displayName)
                } catch is CancellationError {
                    return .failure(.failed(.upstream), retryAt: nil)
                } catch {
                    customError = error
                    plog("🎵 \(label): own service failed reason=\(AIRecommendationFallbackReason.classify(error))")
                }
            }
        }

        if let customError {
            return .failure(.failed(AIRecommendationFallbackReason.classify(customError)), retryAt: nil)
        }
        if let relayError {
            if Self.primuseRelayDoesNotOfferFeature(relayError) {
                return .failure(.builtInNotOffered, retryAt: nil)
            }
            return .failure(
                .failed(AIRecommendationFallbackReason.classify(relayError)),
                retryAt: (relayError as? PrimuseAIRelayError)?.retryAt
            )
        }
        return .failure(.notConfigured, retryAt: nil)
    }

    /// The relay answers 404/501 for a path it does not serve (an older
    /// deployment), and 403 with these codes when the app or plan has not
    /// been given this feature.
    nonisolated static func primuseRelayDoesNotOfferFeature(_ error: Error) -> Bool {
        guard case .requestFailed(let statusCode, let code, _) = error as? PrimuseAIRelayError else {
            return false
        }
        return statusCode == 404 || statusCode == 501
            || ["feature_disabled", "feature_not_in_plan"].contains(code)
    }

    /// Whether "for you" intents can be curated by an AI service: the same
    /// library content and consent as tag cleanup.
    var isListeningIntentCurationAvailable: Bool { isLibraryContentAvailable(for: .listeningIntents) }

    /// Whether play figures may go along (listening context consent).
    var allowsListeningContextForCuration: Bool { settingsStore.hasExplicitListeningContextConsent }

    /// Chosen and named "for you" intents: the built-in AI first, then the
    /// listener's own services. Any failure is the cue to keep the device's
    /// own intents, never an error to show.
    func curateListeningIntents(_ request: ListeningIntentAIExchange.Request) async -> AIListeningIntentOutcome {
        guard settingsStore.hasExplicitRemoteConsent else { return .unavailable() }
        let consent = settingsStore.hasExplicitRemoteConsent
        let regionSnapshot = regionAvailability.snapshot
        var relayRetryAt: Date?

        if isPrimuseRelayAvailable(for: .listeningIntents), canUsePrimuseRelay(
            feature: .listeningIntents,
            captured: regionSnapshot,
            latest: regionAvailability.snapshot,
            hasRequiredConsent: consent
        ) {
            do {
                let drafts = try await primuseRelayClient.listeningIntents(request)
                if !drafts.isEmpty, canUsePrimuseRelay(
                    feature: .listeningIntents,
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    hasRequiredConsent: settingsStore.hasExplicitRemoteConsent
                ) {
                    return .success(AIListeningIntentExecution(drafts: drafts, providerName: primuseRelayProviderName))
                }
            } catch is CancellationError {
                return .unavailable()
            } catch {
                relayRetryAt = (error as? PrimuseAIRelayError)?.retryAt
                plog("🎯 Listening intents: built-in AI failed reason=\(AIRecommendationFallbackReason.classify(error)) unsupported=\(Self.primuseRelayDoesNotOfferFeature(error))")
            }
        }

        if canUseOwnProviders(for: .listeningIntents, regionContext: regionSnapshot.context) {
            for configuration in settingsStore.providerSet.routedProviders(for: .listeningIntents) {
                guard !configuration.generationModel
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      AIRegionRequestPolicy.canSendRemoteRequest(
                        captured: regionSnapshot,
                        latest: regionAvailability.snapshot,
                        configuration: configuration
                      ) else { continue }
                do {
                    let drafts = try await engine.curateListeningIntents(
                        request,
                        configuration: configuration,
                        regionContext: regionSnapshot.context,
                        hasExplicitRemoteConsent: consent,
                        requestAuthorization: regionAuthorization(
                            for: regionSnapshot,
                            configuration: configuration
                        )
                    )
                    guard !drafts.isEmpty, AIRegionRequestPolicy.canCommitRemoteResponse(
                        captured: regionSnapshot,
                        latest: regionAvailability.snapshot,
                        configuration: configuration
                    ) else { continue }
                    return .success(AIListeningIntentExecution(drafts: drafts, providerName: configuration.displayName))
                } catch is CancellationError {
                    return .unavailable()
                } catch {
                    plog("🎯 Listening intents: own service failed reason=\(AIRecommendationFallbackReason.classify(error))")
                }
            }
        }
        return .unavailable(retryAt: relayRetryAt)
    }

    /// `reuseSlot` 是哪一处推荐(`AIRecommendationReusePolicy.slotKey`):给了就在刷新间隔内
    /// 沿用这一处上次的结果,问到新结果也记在这一处。翻页追加、生成歌单不给。
    func recommendationOutcome(
        for request: AIRecommendationRequest,
        forceRefresh: Bool = false,
        reuseSlot: String? = nil,
        onStreamEvent: ((AIRecommendationStreamEvent) -> Void)? = nil
    ) async -> AIRecommendationOutcome {
        let regionSnapshot = regionAvailability.snapshot
        guard isPersonalizedRecommendationsConfigured,
              !request.candidates.isEmpty else { return .unavailable }
        if !forceRefresh,
           let cached = cachedRecommendationOutcome(for: request, reuseSlot: reuseSlot) {
            return cached
        }

        let now = ProcessInfo.processInfo.systemUptime
        var lastEmptyProvider: (name: String, fallbackDepth: Int)?
        var lastFailureReason: AIRecommendationFallbackReason?
        var lastRetryAt: Date?
        var customFallbackOffset = 0
        var streamedSelections: [AIRecommendationSelection] = []
        var streamedSelectionIDs = Set<String>()

        if isPrimuseRelayAvailable(for: .recommendations) {
            guard canUsePrimuseRelay(
                feature: .recommendations,
                captured: regionSnapshot,
                latest: regionAvailability.snapshot,
                hasRequiredConsent: settingsStore.hasExplicitListeningContextConsent
            ) else {
                return .failed(primuseRelayFallbackReason(
                    feature: .recommendations,
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
                let plan: AIRecommendationPlan
                if let onStreamEvent {
                    var completedPlan: AIRecommendationPlan?
                    for try await event in await primuseRelayClient.recommendationEvents(request) {
                        try Task.checkCancellation()
                        guard canUsePrimuseRelay(
                            feature: .recommendations,
                            captured: regionSnapshot,
                            latest: regionAvailability.snapshot,
                            hasRequiredConsent: settingsStore.hasExplicitListeningContextConsent
                        ) else {
                            return .failed(primuseRelayFallbackReason(
                                feature: .recommendations,
                                captured: regionSnapshot,
                                latest: regionAvailability.snapshot,
                                hasRequiredConsent: settingsStore
                                    .hasExplicitListeningContextConsent
                            ))
                        }
                        switch event {
                        case .reset:
                            if streamedSelections.isEmpty {
                                onStreamEvent(event)
                            }
                        case .selection(let selection):
                            guard streamedSelectionIDs.insert(selection.itemID).inserted else {
                                continue
                            }
                            streamedSelections.append(selection)
                            onStreamEvent(event)
                        case .completed(let value):
                            completedPlan = Self.mergingStreamedRecommendations(
                                streamedSelections,
                                into: value,
                                for: request
                            )
                        }
                    }
                    guard let completedPlan else {
                        throw PrimuseAIRelayError.invalidResponse
                    }
                    plan = completedPlan
                } else {
                    plan = try await primuseRelayRecommendationCoordinator
                        .recommendations(request)
                }
                guard canUsePrimuseRelay(
                    feature: .recommendations,
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    hasRequiredConsent: settingsStore.hasExplicitListeningContextConsent
                ) else {
                    return .failed(primuseRelayFallbackReason(
                        feature: .recommendations,
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
                rememberRecommendation(
                    plan,
                    providerName: primuseRelayProviderName,
                    fallbackDepth: 0,
                    route: Self.builtInRecommendationRoute,
                    request: request,
                    slot: reuseSlot
                )
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
                lastRetryAt = (error as? PrimuseAIRelayError)?.retryAt
                if !Task.isCancelled, !streamedSelections.isEmpty,
                   canUsePrimuseRelay(
                    feature: .recommendations,
                    captured: regionSnapshot,
                    latest: regionAvailability.snapshot,
                    hasRequiredConsent: settingsStore.hasExplicitListeningContextConsent
                   ) {
                    let partial = AIRecommendationPlan(
                        selections: streamedSelections,
                        isPartial: true
                    ).normalized(for: request)
                    if !partial.selections.isEmpty {
                        primuseRelayRecommendationCache[cacheKey] = RecommendationCacheEntry(
                            plan: partial,
                            createdAt: now
                        )
                        if primuseRelayRecommendationCache.count > Self.recommendationCacheLimit,
                           let oldestKey = primuseRelayRecommendationCache.min(by: {
                               $0.value.createdAt < $1.value.createdAt
                           })?.key {
                            primuseRelayRecommendationCache[oldestKey] = nil
                        }
                        rememberRecommendation(
                            partial,
                            providerName: primuseRelayProviderName,
                            fallbackDepth: 0,
                            route: Self.builtInRecommendationRoute,
                            request: request,
                            slot: reuseSlot
                        )
                        return .success(AIRecommendationExecution(
                            plan: partial,
                            providerName: primuseRelayProviderName,
                            fallbackDepth: 0,
                            resolvedScene: request.scene,
                            isCached: false
                        ))
                    }
                }
                // A user-configured provider remains available as a fallback.
            }
        }

        let providers = settingsStore.providerSet.routedProviders(for: .recommendations).filter {
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
                let engine = engine
                let regionContext = regionSnapshot.context
                let hasConsent = settingsStore.hasExplicitListeningContextConsent
                let requestAuthorization = regionAuthorization(
                    for: regionSnapshot,
                    configuration: configuration
                )
                let recommend: @Sendable (
                    (@Sendable (AIRecommendationSelection) -> Void)?
                ) async throws -> AIRecommendationPlan = { onSelection in
                    try await engine.recommendations(
                        request,
                        configuration: configuration,
                        regionContext: regionContext,
                        hasExplicitListeningContextConsent: hasConsent,
                        requestAuthorization: requestAuthorization,
                        onSelection: onSelection
                    )
                }
                let providerPlan: AIRecommendationPlan
                if let onStreamEvent {
                    providerPlan = try await Self.forwardingProgress(
                        { report in try await recommend(report) },
                        to: { [regionAvailability] selection in
                            guard AIRegionRequestPolicy.canCommitRemoteResponse(
                                captured: regionSnapshot,
                                latest: regionAvailability.snapshot,
                                configuration: configuration
                            ), streamedSelectionIDs.insert(selection.itemID).inserted else { return }
                            streamedSelections.append(selection)
                            onStreamEvent(.selection(selection))
                        }
                    )
                } else {
                    providerPlan = try await recommend(nil)
                }
                let plan = Self.mergingStreamedRecommendations(
                    streamedSelections,
                    into: providerPlan,
                    for: request
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
                rememberRecommendation(
                    plan,
                    providerName: configuration.displayName,
                    fallbackDepth: effectiveFallbackDepth,
                    route: Self.recommendationRoute(for: configuration),
                    request: request,
                    slot: reuseSlot
                )
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
                lastRetryAt = (error as? PrimuseAIRelayError)?.retryAt
                continue
            }
        }
        if let lastEmptyProvider {
            return .empty(
                providerName: lastEmptyProvider.name,
                fallbackDepth: lastEmptyProvider.fallbackDepth
            )
        }
        return .failed(lastFailureReason ?? .upstream, retryAt: lastRetryAt)
    }

    /// Runs a provider call whose progress callback fires off the main actor,
    /// delivering that progress here in order before the result is returned.
    private static func forwardingProgress<Progress: Sendable, Value: Sendable>(
        _ operation: @escaping @Sendable (@escaping @Sendable (Progress) -> Void) async throws -> Value,
        to receive: (Progress) -> Void
    ) async throws -> Value {
        let (stream, continuation) = AsyncStream.makeStream(of: Progress.self)
        let producer = Task {
            defer { continuation.finish() }
            return try await operation { continuation.yield($0) }
        }
        return try await withTaskCancellationHandler {
            for await progress in stream { receive(progress) }
            return try await producer.value
        } onCancel: {
            producer.cancel()
        }
    }

    nonisolated static func mergingStreamedRecommendations(
        _ streamed: [AIRecommendationSelection],
        into completed: AIRecommendationPlan,
        for request: AIRecommendationRequest
    ) -> AIRecommendationPlan {
        guard !streamed.isEmpty else { return completed }
        var seen = Set<String>()
        var selections: [AIRecommendationSelection] = []
        // Songs and albums share one key space (`itemID`); `normalized` below
        // caps each kind at its own limit.
        for selection in streamed + completed.selections
        where seen.insert(selection.itemID).inserted {
            selections.append(selection)
        }
        let merged = AIRecommendationPlan(
            summary: completed.summary,
            selections: selections,
            isPartial: completed.isPartial
        ).normalized(for: request)
        return merged.selections.isEmpty ? completed : merged
    }

    func cachedRecommendationOutcome(
        for request: AIRecommendationRequest,
        reuseSlot: String? = nil
    ) -> AIRecommendationOutcome? {
        let regionSnapshot = regionAvailability.snapshot
        guard isPersonalizedRecommendationsConfigured,
              !request.candidates.isEmpty else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        var customFallbackOffset = 0
        if isPrimuseRelayAvailable(for: .recommendations) {
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
        let providers = settingsStore.providerSet.routedProviders(for: .recommendations).filter {
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
        if let reuseSlot,
           let entry = recommendationReuseStore.entry(for: reuseSlot),
           let plan = AIRecommendationReusePolicy.reusablePlan(
               entry,
               for: request,
               routes: recommendationRoutes(providers: providers),
               interval: recommendationRefreshInterval,
               now: Date()
           ) {
            return .success(AIRecommendationExecution(
                plan: plan,
                providerName: entry.providerName,
                fallbackDepth: entry.fallbackDepth,
                resolvedScene: entry.scene,
                isCached: true
            ))
        }
        return nil
    }

    /// 智能推荐实际的刷新档位:设置里选的,「自动」按这时谁先回答换算。
    var recommendationRefreshInterval: AIRecommendationRefreshInterval {
        AIRecommendationRefreshInterval.stored(
            recommendationReuseStore.defaults.string(forKey: AIRecommendationRefreshInterval.storageKey)
        ).resolved(usesBuiltIn: isPrimuseRelayAvailable(for: .recommendations))
    }

    /// 「自动」此刻相当于哪一档,设置里写在选项上。
    var automaticRecommendationRefreshInterval: AIRecommendationRefreshInterval {
        AIRecommendationRefreshInterval.automatic
            .resolved(usesBuiltIn: isPrimuseRelayAvailable(for: .recommendations))
    }

    private static let builtInRecommendationRoute = "builtIn"

    private static func recommendationRoute(for configuration: AIRemoteProviderConfiguration) -> String {
        "provider:\(configuration.id.uuidString):\(configuration.generationModel):\(configuration.baseURL)"
    }

    /// 此刻还能给推荐的服务;别的服务给的旧结果不沿用。
    private func recommendationRoutes(providers: [AIRemoteProviderConfiguration]) -> Set<String> {
        var routes = Set(providers.map(Self.recommendationRoute(for:)))
        if isPrimuseRelayAvailable(for: .recommendations) {
            routes.insert(Self.builtInRecommendationRoute)
        }
        return routes
    }

    private func rememberRecommendation(
        _ plan: AIRecommendationPlan,
        providerName: String,
        fallbackDepth: Int,
        route: String,
        request: AIRecommendationRequest,
        slot: String?
    ) {
        guard let slot else { return }
        recommendationReuseStore.store(
            AIRecommendationReuseEntry(
                plan: plan,
                providerName: providerName,
                fallbackDepth: fallbackDepth,
                route: route,
                scene: request.scene,
                createdAt: Date()
            ),
            for: slot
        )
    }

    func transcribeAudio(
        at audioFileURL: URL,
        mimeType: String,
        displayName: String,
        duration: TimeInterval,
        customVocabulary: [String] = []
    ) async -> AIAudioTranscriptionOutcome {
        if lyricsTranscriptionSettingsStore.usesBuiltIn {
            return await transcribeAudioWithBuiltIn(at: audioFileURL, duration: duration)
        }
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

    /// 内置 AI:先在本机转成 22.05 kHz、48 kbps 的 M4A(能播的格式都能转),
    /// 整份交给中转;中转从文件里读时长、按首扣套餐次数。临时文件用完即删。
    private func transcribeAudioWithBuiltIn(
        at audioFileURL: URL,
        duration: TimeInterval
    ) async -> AIAudioTranscriptionOutcome {
        #if os(tvOS)
        return .unavailable
        #else
        let regionSnapshot = regionAvailability.snapshot
        guard lyricsTranscriptionSettingsStore.isEnabled,
              lyricsTranscriptionSettingsStore.hasExplicitAudioUploadConsent,
              isBuiltInTranscriptionReady else {
            return .unavailable
        }
        guard duration <= 0 || duration <= AIAudioTranscriptionPolicy.builtInMaximumDuration else {
            return .tooLong
        }
        let compact: OfflineAudioCompactor.Output
        do {
            compact = try await OfflineAudioCompactor.encodeForTranscription(
                original: audioFileURL,
                expectedDuration: duration > 0 ? duration : nil
            )
        } catch is CancellationError {
            return .failed
        } catch {
            plog("[transcription] encode failed: \(error)")
            return .failed
        }
        defer { try? FileManager.default.removeItem(at: compact.url) }
        guard compact.byteCount <= Int64(AIAudioTranscriptionPolicy.builtInMaximumUploadBytes) else {
            return .tooLong
        }
        guard regionSnapshot == regionAvailability.snapshot,
              lyricsTranscriptionSettingsStore.hasExplicitAudioUploadConsent,
              isBuiltInTranscriptionReady else {
            return .failed
        }
        do {
            let result = try await primuseRelayClient.transcribeAudio(fileURL: compact.url)
            guard regionSnapshot == regionAvailability.snapshot else { return .failed }
            return .success(AIAudioTranscriptionExecution(
                result: result,
                providerName: String(localized: "ai_primuse_relay_name"),
                fallbackDepth: 0
            ))
        } catch is CancellationError {
            return .failed
        } catch let error as PrimuseAIRelayError {
            guard case .requestFailed(let statusCode, let code, _) = error else { return .failed }
            plog("[transcription] built-in AI refused: \(statusCode) \(code)")
            switch code {
            case "feature_quota_exhausted", "daily_request_limit_exhausted", "daily_quota_exhausted":
                return .limitReached
            case "period_quota_exhausted":
                return .monthlyLimitReached
            case "audio_too_long", "request_too_large":
                return .tooLong
            case "feature_not_in_plan":
                // 当前套餐没有听歌识词:入口收起来,设置里说明原因,自己的密钥照常能用。
                builtInTranscriptionOffered = false
                builtInTranscriptionNotInPlan = true
                builtInTranscriptionCheckedAt = Date()
                return .notInPlan
            case "feature_disabled", "feature_unavailable", "route_not_found":
                // 后台撤了转写模型:入口先收起来,下次问到开放再出现。
                builtInTranscriptionOffered = false
                builtInTranscriptionCheckedAt = Date()
                return .unavailable
            default:
                return .failed
            }
        } catch {
            return .failed
        }
        #endif
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
        usesBuiltIn: Bool,
        apiKey: String?
    ) async throws {
        let normalized = LyricsTranscriptionSettingsStore
            .normalizedGoogleConfiguration(configuration)
        let decision = AIAvailabilityPolicy.decision(
            for: usesBuiltIn ? .bundledRemote : .userConfiguredRemote,
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
            usesBuiltIn: usesBuiltIn,
            credentialMigrationCompleted: hasDedicatedCredential
                || lyricsTranscriptionSettingsStore.legacyCredentialConfiguration == nil
        )
        _ = await hasStoredLyricsTranscriptionAPIKey()
        if usesBuiltIn { await refreshBuiltInTranscriptionOffer(force: true) }
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
        _ = try AIRemoteEndpointPolicy.validatedBaseURL(
            configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        )
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
        _ = try AIRemoteEndpointPolicy.validatedBaseURL(
            enabledConfiguration.baseURL,
            allowInsecureLocalHTTP: enabledConfiguration.allowInsecureLocalHTTP
        )
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
            var diagnostic = PrimuseAIRelayDiagnostic.classify(error)
            if diagnostic.category == .deviceRegistration {
                diagnostic.fallbackCode = await primuseRelayClient.lastEnrollmentFallbackCode
            }
            return PrimuseAIRelayConnectionReport(
                outcome: .unavailable(diagnostic),
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

/// 各处智能推荐上一次的结果。存在本机(不同步),重开 App 也接着沿用到刷新间隔结束。
@MainActor
final class AIRecommendationReuseStore {
    static let storageKey = "primuse.ai.recommendationReuse.v1"

    let defaults: UserDefaults
    private var entries: [String: AIRecommendationReuseEntry]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.storageKey).flatMap {
            try? JSONDecoder().decode([String: AIRecommendationReuseEntry].self, from: $0)
        } ?? [:]
    }

    func entry(for slot: String) -> AIRecommendationReuseEntry? {
        entries[slot]
    }

    func store(_ entry: AIRecommendationReuseEntry, for slot: String) {
        entries = AIRecommendationReusePolicy.storing(entry, for: slot, in: entries)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.storageKey)
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

    /// 推荐语跟界面语言走，并且带上字形：只给 `zh` 时模型会跟着候选歌曲的
    /// 语言写，粤语歌一多整段推荐语就变成繁体（#161）。
    static var recommendationLanguageCode: String {
        LyricTranslationGroupingPolicy.languageIdentity(
            Bundle.main.preferredLocalizations.first ?? Locale.current.identifier
        )
    }

    @MainActor
    static func request(
        scene: AIRecommendationScene,
        intent: String? = nil,
        candidates: [Song],
        maximumResults: Int = 12,
        minimumResults: Int = 10,
        unit: AIRecommendationUnit = .songs,
        albumCandidates: [AIRecommendationAlbumCandidate] = [],
        history: PlayHistoryStore = .shared,
        now: Date = Date()
    ) -> AIRecommendationRequest? {
        var seen = Set<String>()
        let uniqueCandidates = candidates.filter {
            !$0.id.isEmpty && seen.insert($0.id).inserted
        }
        let albums = unit.includesAlbums ? albumCandidates : []
        guard !uniqueCandidates.isEmpty || !albums.isEmpty else { return nil }
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
            languageCode: Self.recommendationLanguageCode,
            preferences: preferences,
            candidates: recommendationCandidates,
            maximumResults: maximumResults,
            minimumResults: minimumResults,
            unit: unit,
            albumCandidates: albums
        )
    }
}

@MainActor
@Observable
final class AIRecommendationViewModel {
    private(set) var feedback: AIRecommendationFeedback = .idle
    private(set) var orderedSongIDs: [String] = []
    private(set) var reasonsBySongID: [String: String] = [:]
    /// Whole albums the service picked, in its order (only when asked for albums).
    private(set) var orderedAlbumKeys: [String] = []
    private(set) var reasonsByAlbumKey: [String: String] = [:]
    private(set) var isStreaming = false
    private(set) var isPartial = false
    private(set) var retryAvailableAt: Date?
    private(set) var streamedSongCount = 0
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
        appending: Bool = false,
        unit: AIRecommendationUnit = .songs,
        albumCandidates: [AIRecommendationAlbumCandidate] = [],
        reuseSurface: AIRecommendationSurface? = nil
    ) async -> Bool {
        finishRetryCooldown()
        generation &+= 1
        let operationGeneration = generation
        let previousFeedback = feedback
        let previousPartial = isPartial
        guard intelligence.settingsStore.recommendationsEnabled else {
            isStreaming = false
            if !appending {
                feedback = .idle
                orderedSongIDs = []
                reasonsBySongID = [:]
                clearAlbums()
            }
            return false
        }
        guard intelligence.settingsStore.hasExplicitListeningContextConsent else {
            isStreaming = false
            if !appending {
                feedback = .needsConsent
                orderedSongIDs = []
                reasonsBySongID = [:]
                clearAlbums()
            }
            return false
        }
        guard let request = AIRecommendationContextBuilder.request(
            scene: scene,
            intent: intent,
            candidates: candidates,
            maximumResults: maximumResults,
            minimumResults: minimumResults,
            unit: unit,
            albumCandidates: albumCandidates
        ) else {
            isStreaming = false
            if !appending {
                feedback = .idle
                orderedSongIDs = []
                reasonsBySongID = [:]
                clearAlbums()
            }
            return false
        }

        // 翻页追加问的是剩下的候选,不能顶替这一处的整份结果。
        let reuseSlot = appending ? nil : reuseSurface.map {
            AIRecommendationReusePolicy.slotKey(surface: $0, sceneSelection: scene, request: request)
        }
        let startingSongIDs = orderedSongIDs
        let startingIDs = Set(startingSongIDs)
        let startingReasons = reasonsBySongID
        let startingAlbumKeys = orderedAlbumKeys
        let startingAlbumReasons = reasonsByAlbumKey
        let outcome: AIRecommendationOutcome
        if !forceRefresh,
           let cached = intelligence.cachedRecommendationOutcome(for: request, reuseSlot: reuseSlot) {
            isStreaming = false
            outcome = cached
        } else {
            if let retryAvailableAt, retryAvailableAt > Date() { return false }
            feedback = .loading
            isPartial = false
            streamedSongCount = 0
            isStreaming = true
            var hasReceivedStreamingSelection = false
            outcome = await intelligence.recommendationOutcome(
                for: request,
                forceRefresh: forceRefresh,
                reuseSlot: reuseSlot,
                onStreamEvent: { [weak self] event in
                    guard let self,
                          operationGeneration == self.generation,
                          !Task.isCancelled else { return }
                    switch event {
                    case .reset:
                        if appending {
                            self.orderedSongIDs.removeAll { !startingIDs.contains($0) }
                            self.reasonsBySongID = self.reasonsBySongID.filter {
                                startingIDs.contains($0.key)
                            }
                        } else {
                            self.orderedSongIDs = startingSongIDs
                            self.reasonsBySongID = startingReasons
                        }
                        self.orderedAlbumKeys = startingAlbumKeys
                        self.reasonsByAlbumKey = startingAlbumReasons
                        hasReceivedStreamingSelection = false
                    case .selection(let selection):
                        if !appending, !hasReceivedStreamingSelection {
                            self.orderedSongIDs = []
                            self.reasonsBySongID = [:]
                            self.clearAlbums()
                        }
                        hasReceivedStreamingSelection = true
                        if selection.kind == .album {
                            guard let albumKey = selection.albumKey,
                                  !self.orderedAlbumKeys.contains(albumKey) else { return }
                            self.orderedAlbumKeys.append(albumKey)
                            self.reasonsByAlbumKey[albumKey] = selection.reason
                            return
                        }
                        guard !self.orderedSongIDs.contains(selection.songID) else { return }
                        self.orderedSongIDs.append(selection.songID)
                        self.reasonsBySongID[selection.songID] = selection.reason
                        self.streamedSongCount += 1
                    case .completed:
                        break
                    }
                }
            )
        }
        guard operationGeneration == generation, !Task.isCancelled else {
            if operationGeneration == generation {
                isStreaming = false
                orderedSongIDs = startingSongIDs
                reasonsBySongID = startingReasons
                orderedAlbumKeys = startingAlbumKeys
                reasonsByAlbumKey = startingAlbumReasons
                feedback = previousFeedback
                isPartial = previousPartial
            }
            return false
        }
        isStreaming = false
        switch outcome {
        case .unavailable:
            orderedSongIDs = startingSongIDs
            reasonsBySongID = startingReasons
            orderedAlbumKeys = startingAlbumKeys
            reasonsByAlbumKey = startingAlbumReasons
            feedback = .localFallback(
                providerName: nil,
                fallbackDepth: 0,
                reason: .unavailable
            )
            return false
        case .success(let execution):
            isPartial = execution.plan.isPartial
            if appending {
                // Paging only ever adds songs; the albums stay as they were.
                orderedAlbumKeys = startingAlbumKeys
                reasonsByAlbumKey = startingAlbumReasons
                let additions = execution.plan.songSelections.filter {
                    !startingIDs.contains($0.songID)
                }
                guard !additions.isEmpty else {
                    orderedSongIDs = startingSongIDs
                    reasonsBySongID = startingReasons
                    feedback = previousFeedback
                    return false
                }
                orderedSongIDs = startingSongIDs + additions.map(\.songID)
                reasonsBySongID = startingReasons
                for selection in additions {
                    reasonsBySongID[selection.songID] = selection.reason
                }
            } else {
                let songs = execution.plan.songSelections
                orderedSongIDs = songs.map(\.songID)
                reasonsBySongID = Dictionary(
                    songs.map { ($0.songID, $0.reason) },
                    uniquingKeysWith: { first, _ in first }
                )
                let albums = execution.plan.albumSelections.compactMap { selection in
                    selection.albumKey.map { ($0, selection.reason) }
                }
                orderedAlbumKeys = albums.map { $0.0 }
                reasonsByAlbumKey = Dictionary(albums, uniquingKeysWith: { first, _ in first })
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
            orderedSongIDs = startingSongIDs
            reasonsBySongID = startingReasons
            orderedAlbumKeys = startingAlbumKeys
            reasonsByAlbumKey = startingAlbumReasons
            feedback = .localFallback(
                providerName: providerName,
                fallbackDepth: fallbackDepth,
                reason: .empty
            )
            return false
        case .failed(let reason, let retryAt):
            retryAvailableAt = retryAt
            orderedSongIDs = startingSongIDs
            reasonsBySongID = startingReasons
            orderedAlbumKeys = startingAlbumKeys
            reasonsByAlbumKey = startingAlbumReasons
            feedback = .localFallback(
                providerName: nil,
                fallbackDepth: 0,
                reason: reason
            )
            return false
        }
    }

    #if DEBUG
    /// 截图钩子:不问服务,直接放进一份排好的结果。
    func debugApply(_ selections: [AIRecommendationSelection]) {
        generation &+= 1
        isStreaming = false
        isPartial = false
        let songs = selections.filter { $0.kind == .song }
        orderedSongIDs = songs.map(\.songID)
        reasonsBySongID = Dictionary(
            songs.map { ($0.songID, $0.reason) },
            uniquingKeysWith: { first, _ in first }
        )
        let albums = selections.compactMap { selection in
            selection.albumKey.map { ($0, selection.reason) }
        }
        orderedAlbumKeys = albums.map { $0.0 }
        reasonsByAlbumKey = Dictionary(albums, uniquingKeysWith: { first, _ in first })
        feedback = .success(
            summary: "",
            providerName: "Debug",
            fallbackDepth: 0,
            scene: .automatic,
            isCached: true
        )
    }
    #endif

    func orderedSongs(from candidates: [Song]) -> [Song] {
        guard !orderedSongIDs.isEmpty else {
            return isStreaming ? [] : candidates
        }
        let byID = Dictionary(
            candidates.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        return orderedSongIDs.compactMap { byID[$0] }
    }

    func reason(for songID: String) -> String? {
        reasonsBySongID[songID]
    }

    func albumReason(for albumKey: String) -> String? {
        reasonsByAlbumKey[albumKey]
    }

    private func clearAlbums() {
        orderedAlbumKeys = []
        reasonsByAlbumKey = [:]
    }

    func finishRetryCooldown() {
        if let retryAvailableAt, retryAvailableAt <= Date() {
            self.retryAvailableAt = nil
        }
    }

    var statusText: String {
        if isPartial, !orderedSongIDs.isEmpty {
            return String(
                format: String(localized: "ai_recommendation_stream_partial_format"),
                orderedSongIDs.count
            )
        }
        switch feedback {
        case .idle:
            return String(localized: "ai_recommendation_status_local")
        case .loading:
            if streamedSongCount > 0 {
                return String(
                    format: String(localized: "ai_recommendation_stream_progress_format"),
                    streamedSongCount
                )
            }
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
            if !orderedSongIDs.isEmpty {
                return String(
                    format: String(localized: "ai_recommendation_stream_retained_format"),
                    orderedSongIDs.count
                )
            }
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
            case .monthlyLimit:
                key = "ai_recommendation_status_monthly_limit_local"
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

extension AIRecommendationUnit {
    var localizedTitle: String {
        switch self {
        case .songs: String(localized: "ai_recommendation_unit_songs")
        case .albums: String(localized: "ai_recommendation_unit_albums")
        case .mixed: String(localized: "ai_recommendation_unit_mixed")
        }
    }

    /// 电视设置里按一下换到的下一档。
    var next: AIRecommendationUnit {
        switch self {
        case .mixed: .songs
        case .songs: .albums
        case .albums: .mixed
        }
    }
}

extension AIRecommendationRefreshInterval {
    static let pickerCases: [AIRecommendationRefreshInterval] = [
        .automatic, .realtime, .hourly, .sixHours, .daily,
    ]

    var localizedTitle: String {
        switch self {
        case .automatic: String(localized: "ai_recommendation_refresh_automatic")
        case .realtime: String(localized: "ai_recommendation_refresh_realtime")
        case .hourly: String(localized: "ai_recommendation_refresh_hourly")
        case .sixHours: String(localized: "ai_recommendation_refresh_six_hours")
        case .daily: String(localized: "ai_recommendation_refresh_daily")
        }
    }

    /// 选项上的名字;「自动」带上它此刻相当于哪一档。
    func displayTitle(automatic resolved: AIRecommendationRefreshInterval) -> String {
        guard self == .automatic else { return localizedTitle }
        return String(
            format: String(localized: "ai_recommendation_refresh_automatic_format"),
            resolved.localizedTitle
        )
    }

    /// 电视设置里按一下换到的下一档。
    var next: AIRecommendationRefreshInterval {
        let cases = Self.pickerCases
        let index = cases.firstIndex(of: self) ?? 0
        return cases[(index + 1) % cases.count]
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
        requestAuthorization: @escaping @Sendable () async -> Bool,
        onTranslation: (@Sendable (_ id: String, _ text: String) -> Void)? = nil
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
                targetLanguageCode: targetLanguageCode,
                onTranslation: onTranslation
            )
        }
    }

    /// Tag cleanup is plain text generation over song titles and names —
    /// the same data and the same consent as lyric translation — so it is
    /// routed through that capability rather than a new one.
    func proposeTagCleanup(
        _ songs: [TagCleanupSong],
        languageCode: String,
        currentYear: Int,
        configuration: AIRemoteProviderConfiguration,
        regionContext: AIRegionContext,
        hasExplicitRemoteConsent: Bool,
        requestAuthorization: @escaping @Sendable () async -> Bool
    ) async throws -> [TagCleanupProposal] {
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
        // A batch answer is long; give it more room than a single request.
        return try await withTimeout(seconds: max(configuration.requestTimeout, 45)) {
            try await provider.proposeTagCleanup(
                songs,
                languageCode: languageCode,
                currentYear: currentYear
            )
        }
    }

    /// New-song discovery is plain text generation over aggregated genre
    /// and artist names — library content under the same consent as tag
    /// cleanup — so it is routed through the same capability.
    func discoverSongs(
        _ request: SongDiscoveryAIExchange.Request,
        currentYear: Int,
        configuration: AIRemoteProviderConfiguration,
        regionContext: AIRegionContext,
        hasExplicitRemoteConsent: Bool,
        requestAuthorization: @escaping @Sendable () async -> Bool
    ) async throws -> [SongDiscoverySuggestion] {
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
        // A list of thirty songs with reasons is a long answer.
        return try await withTimeout(seconds: max(configuration.requestTimeout, 45)) {
            try await provider.discoverSongs(request, currentYear: currentYear)
        }
    }

    /// Intent curation is plain text generation over aggregated library
    /// names, routed like new-song discovery.
    func curateListeningIntents(
        _ request: ListeningIntentAIExchange.Request,
        configuration: AIRemoteProviderConfiguration,
        regionContext: AIRegionContext,
        hasExplicitRemoteConsent: Bool,
        requestAuthorization: @escaping @Sendable () async -> Bool
    ) async throws -> [ListeningIntentAIExchange.Draft] {
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
        return try await withTimeout(seconds: max(configuration.requestTimeout, 45)) {
            try await provider.curateListeningIntents(request)
        }
    }

    /// Album/artist intros are short text generation over library names,
    /// routed like tag cleanup and new-song discovery.
    func libraryInsight(
        _ request: LibraryInsightAIExchange.Request,
        configuration: AIRemoteProviderConfiguration,
        regionContext: AIRegionContext,
        hasExplicitRemoteConsent: Bool,
        requestAuthorization: @escaping @Sendable () async -> Bool
    ) async throws -> LibraryInsightAIExchange.Answer {
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
        return try await withTimeout(seconds: max(configuration.requestTimeout, 30)) {
            try await provider.libraryInsight(request)
        }
    }

    /// 听歌状态解读同样是一小段文字生成，和简介走同一类服务。
    func listeningMood(
        _ request: ListeningMoodAIExchange.Request,
        configuration: AIRemoteProviderConfiguration,
        regionContext: AIRegionContext,
        hasExplicitRemoteConsent: Bool,
        requestAuthorization: @escaping @Sendable () async -> Bool
    ) async throws -> ListeningMoodAIExchange.Answer {
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
        return try await withTimeout(seconds: max(configuration.requestTimeout, 30)) {
            try await provider.listeningMood(request)
        }
    }

    func recommendations(
        _ request: AIRecommendationRequest,
        configuration: AIRemoteProviderConfiguration,
        regionContext: AIRegionContext,
        hasExplicitListeningContextConsent: Bool,
        requestAuthorization: @escaping @Sendable () async -> Bool,
        onSelection: (@Sendable (AIRecommendationSelection) -> Void)? = nil
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
            try await provider.recommendations(request, onSelection: onSelection)
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
