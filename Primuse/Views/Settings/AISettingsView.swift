import Observation
import PrimuseKit
import SwiftUI

@MainActor
@Observable
final class AISettingsEditorModel {
    enum Operation: Equatable {
        case models
        case settings
    }

    enum Status: Equatable {
        case idle
        case saving
        case saved
        case connectionSucceeded
        case modelsLoaded(Int)
        case modelsEmpty
        case failed(String, Operation)
    }

    enum PrimuseRelayConnectionPresentation: Equatable {
        case notTested
        case testing
        case success
        case degraded
        case failure
    }

    var draftProviderSet: AIRemoteProviderSet
    var selectedProviderID: UUID
    var providerPresets: [UUID: AIProviderPreset] = [:]
    var primuseRelayEnabled = AISettingsStore.defaultPrimuseRelayEnabled
    var semanticSearchEnabled = false
    var recommendationsEnabled = false
    var consent = false
    var listeningContextConsent = false
    var apiKeyDrafts: [UUID: String] = [:]
    var storedAPIKeyScopes: [UUID: String] = [:]
    var availableModelsByProvider: [UUID: [AIProviderModel]] = [:]
    var didLoad = false
    var isLoading = false
    var isWorking = false
    var isFetchingModels = false
    var isTestingPrimuseRelay = false
    var status: Status = .idle
    var primuseRelayConnectionReport: PrimuseAIRelayConnectionReport?

    private var draftGeneration: UInt64 = 0
    private var savedProviderSet: AIRemoteProviderSet
    private var savedPrimuseRelayEnabled = AISettingsStore.defaultPrimuseRelayEnabled
    private var savedSemanticSearchEnabled = false
    private var savedRecommendationsEnabled = false
    private var savedConsent = false
    private var savedListeningContextConsent = false
    private var pendingRemovedProviders: [UUID: AIRemoteProviderConfiguration] = [:]
    @ObservationIgnored private weak var intelligence: MusicIntelligenceService?
    @ObservationIgnored private var autoSaveTask: Task<Void, Never>?
    @ObservationIgnored private var saveRequestedWhileWorking = false

    init() {
        let providerSet = AIRemoteProviderSet()
        draftProviderSet = providerSet
        savedProviderSet = providerSet
        selectedProviderID = providerSet.primaryProviderID
        providerPresets[selectedProviderID] = .custom
    }

    var draftConfiguration: AIRemoteProviderConfiguration {
        get {
            draftProviderSet.providers.first { $0.id == selectedProviderID }
                ?? draftProviderSet.primaryProvider
        }
        set {
            guard let index = draftProviderSet.providers.firstIndex(where: {
                $0.id == selectedProviderID
            }) else { return }
            draftProviderSet.providers[index] = newValue
        }
    }

    var selectedProviderPreset: AIProviderPreset {
        get {
            let preset = providerPresets[selectedProviderID]
                ?? AIProviderPreset.matching(configuration: draftConfiguration)
            guard let intelligence else { return preset }
            return AIProviderPreset.visibleSelection(
                preset,
                for: intelligence.regionAvailability.context.region
            )
        }
        set { providerPresets[selectedProviderID] = newValue }
    }

    var apiKeyDraft: String {
        get { apiKeyDrafts[selectedProviderID] ?? "" }
        set { apiKeyDrafts[selectedProviderID] = newValue }
    }

    var availableModels: [AIProviderModel] {
        get { availableModelsByProvider[selectedProviderID] ?? [] }
        set { availableModelsByProvider[selectedProviderID] = newValue }
    }

    var hasStoredAPIKeyForDraft: Bool {
        storedAPIKeyScopes[selectedProviderID] == draftCredentialScope
    }

    var hasUsableAPIKey: Bool {
        hasStoredAPIKeyForDraft
            || !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var usesOpenAIPlatformAPI: Bool {
        AIRemoteEndpointPolicy.isOpenAIPlatformEndpoint(
            configuration: draftConfiguration
        )
    }

    var apiKeyTitle: String {
        String(localized: usesOpenAIPlatformAPI
               ? "ai_openai_platform_api_key"
               : "ai_api_key")
    }

    var providerFooterText: String {
        let general = String(localized: "ai_provider_footer")
        guard usesOpenAIPlatformAPI else { return general }
        return "\(general)\n\n\(String(localized: "ai_openai_platform_billing_footer"))"
    }

    var providerListFooterText: String {
        let fallback = String(localized: "ai_fallback_footer")
        guard !AIOpenAIAccountAccessPolicy
            .supportsChatGPTSubscriptionForGeneralResponses else {
            return fallback
        }
        return "\(fallback)\n\n\(String(localized: "ai_openai_platform_billing_footer"))"
    }

    /// 「我的 AI 服务」的说明:内置 AI 开着时先讲清它和自己的服务谁先谁后。
    var serviceListFooterText: String {
        let relation = String(localized: isPrimuseRelayActive
                              ? "ai_provider_list_relay_hint"
                              : "ai_provider_list_tap_hint")
        return "\(relation)\n\n\(providerListFooterText)"
    }

    var isPrimuseRelayActive: Bool {
        primuseRelayEnabled && PrimuseAIRelayClient.isSupportedOnCurrentDevice
    }

    /// 一项服务配到了哪一步。加载完之前钥匙串还没查过,不下结论。
    func setupState(for provider: AIRemoteProviderConfiguration) -> AIProviderSetupState? {
        guard didLoad else { return nil }
        return AIProviderSetupState(
            isEnabled: provider.isEnabled,
            hasAPIKey: hasAPIKey(for: provider),
            generationModel: provider.generationModel
        )
    }

    /// 内置 AI 开关下方的引导:关掉内置 AI 却没有配好的服务时带去填密钥,
    /// 自己的服务已配好而内置 AI 仍开着时说明谁优先。
    var serviceSetupGuidance: AIServiceSetupGuidance {
        guard didLoad else { return .none }
        return AIServiceSetupGuidance.resolve(
            relayEnabled: primuseRelayEnabled,
            relaySupportedOnDevice: PrimuseAIRelayClient.isSupportedOnCurrentDevice,
            primaryProviderID: draftProviderSet.primaryProviderID,
            providers: draftProviderSet.providers.map {
                AIProviderSetupSummary(id: $0.id, state: setupState(for: $0) ?? .disabled)
            }
        )
    }

    private func hasAPIKey(for provider: AIRemoteProviderConfiguration) -> Bool {
        if let draft = apiKeyDrafts[provider.id],
           !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let scope = Self.credentialScope(for: provider) else { return false }
        return storedAPIKeyScopes[provider.id] == scope
    }

    var hasUnsavedChanges: Bool {
        draftProviderSet != savedProviderSet
            || primuseRelayEnabled != savedPrimuseRelayEnabled
            || semanticSearchEnabled != savedSemanticSearchEnabled
            || recommendationsEnabled != savedRecommendationsEnabled
            || consent != savedConsent
            || listeningContextConsent != savedListeningContextConsent
            || !pendingRemovedProviders.isEmpty
            || apiKeyDrafts.values.contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    var canFetchModels: Bool {
        didLoad && !isWorking && !isFetchingModels && hasUsableAPIKey
            && !draftConfiguration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canTestConnection: Bool {
        didLoad && !isWorking && !isFetchingModels && hasUsableAPIKey
            && !draftConfiguration.generationModel
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canTestPrimuseRelayConnection: Bool {
        didLoad && !isWorking && !isFetchingModels && !isTestingPrimuseRelay
    }

    var primuseRelayConnectionPresentation: PrimuseRelayConnectionPresentation {
        if isTestingPrimuseRelay { return .testing }
        guard let report = primuseRelayConnectionReport else { return .notTested }
        if report.isDirectlyAvailable {
            return report.isDegraded ? .degraded : .success
        }
        if case .remoteProvider = report.fallback { return .degraded }
        return .failure
    }

    var primuseRelayConnectionTitle: String {
        if isTestingPrimuseRelay {
            return String(localized: "ai_primuse_relay_test_running")
        }
        guard let report = primuseRelayConnectionReport else {
            return String(localized: "ai_primuse_relay_test_not_run")
        }
        switch report.outcome {
        case .available(.appAttest):
            return String(localized: "ai_primuse_relay_test_success_app_attest")
        case .available(.storeKitFallback):
            return String(localized: "ai_primuse_relay_test_success_storekit")
        case .unavailable(let diagnostic):
            switch diagnostic.category {
            case .regionRestriction:
                return String(localized: "ai_primuse_relay_failure_region_title")
            case .deviceRegistration:
                return String(localized: "ai_primuse_relay_failure_registration_title")
            case .serviceAuthentication:
                return String(localized: "ai_primuse_relay_failure_auth_title")
            case .upstream:
                return String(localized: "ai_primuse_relay_failure_upstream_title")
            }
        }
    }

    var primuseRelayConnectionDetail: String? {
        guard !isTestingPrimuseRelay, let report = primuseRelayConnectionReport else {
            return nil
        }
        switch report.outcome {
        case .available(.appAttest):
            return String(localized: "ai_primuse_relay_test_success_app_attest_detail")
        case .available(.storeKitFallback):
            return String(localized: "ai_primuse_relay_test_success_storekit_detail")
        case .unavailable(let diagnostic):
            var lines = [primuseRelayDiagnosticDetail(for: diagnostic)]
            // App Attest 被拒后 StoreKit 兜底也没成时,两段诊断码都给出来。
            let codes = [diagnostic.code] + (diagnostic.fallbackCode.map { ["StoreKit \($0)"] } ?? [])
            lines.append(String(
                format: String(localized: "ai_primuse_relay_diagnostic_code_format"),
                codes.joined(separator: " · ")
            ))
            switch report.fallback {
            case .none:
                break
            case .remoteProvider(let name):
                lines.append(String(
                    format: String(localized: "ai_primuse_relay_fallback_provider_format"),
                    name
                ))
            case .localOnly:
                lines.append(String(localized: "ai_primuse_relay_fallback_local"))
            }
            return lines.joined(separator: "\n")
        }
    }

    private func primuseRelayDiagnosticDetail(
        for diagnostic: PrimuseAIRelayDiagnostic
    ) -> String {
        switch diagnostic.code {
        case "storekit_transaction_unavailable":
            return String(localized: "ai_primuse_relay_diagnostic_storekit_unavailable_detail")
        case "storekit_transaction_unverified":
            return String(localized: "ai_primuse_relay_diagnostic_storekit_unverified_detail")
        case "storekit_authentication_cancelled":
            return String(localized: "ai_primuse_relay_diagnostic_storekit_cancelled_detail")
        case let code where code.hasPrefix("app_attest_")
            || code == "invalid_attestation"
            || code == "invalid_app_attest_policy":
            return String(localized: "ai_primuse_relay_diagnostic_app_attest_detail")
        case "credential_corrupted", "credential_persistence_failed", "credential_unavailable":
            return String(localized: "ai_primuse_relay_diagnostic_credential_detail")
        default:
            switch diagnostic.category {
            case .regionRestriction:
                return String(localized: "ai_primuse_relay_diagnostic_region_detail")
            case .deviceRegistration:
                return String(localized: "ai_primuse_relay_diagnostic_registration_detail")
            case .serviceAuthentication:
                return String(localized: "ai_primuse_relay_diagnostic_auth_detail")
            case .upstream:
                if diagnostic.code.hasPrefix("network_") {
                    return String(localized: "ai_primuse_relay_diagnostic_network_detail")
                }
                return String(localized: "ai_primuse_relay_diagnostic_upstream_detail")
            }
        }
    }

    func load(using intelligence: MusicIntelligenceService) async {
        guard !didLoad, !isLoading else { return }
        self.intelligence = intelligence
        isLoading = true
        defer { isLoading = false }
        if intelligence.regionAvailability.context.region == .unknown {
            await intelligence.regionAvailability.refresh()
        }
        await intelligence.prepareLyricsTranscriptionCredentialMigration()
        draftProviderSet = intelligence.settingsStore.providerSet
        if !intelligence.settingsStore.hasPersistedSettings,
           let recommendedPreset = AIProviderPreset.recommended(
               for: intelligence.regionAvailability.context.region
           ),
           let firstProvider = draftProviderSet.providers.first {
            draftProviderSet.providers[0] = recommendedPreset.applying(to: firstProvider)
        }
        selectedProviderID = draftProviderSet.primaryProviderID
        primuseRelayEnabled = intelligence.settingsStore.primuseRelayEnabled
        semanticSearchEnabled = intelligence.settingsStore.semanticSearchEnabled
        recommendationsEnabled = intelligence.settingsStore.recommendationsEnabled
        providerPresets = Dictionary(uniqueKeysWithValues: draftProviderSet.providers.map {
            ($0.id, AIProviderPreset.matching(configuration: $0))
        })
        consent = intelligence.settingsStore.hasExplicitRemoteConsent
        listeningContextConsent = intelligence.settingsStore
            .hasExplicitListeningContextConsent
        savedProviderSet = draftProviderSet
        savedPrimuseRelayEnabled = primuseRelayEnabled
        savedSemanticSearchEnabled = semanticSearchEnabled
        savedRecommendationsEnabled = recommendationsEnabled
        savedConsent = consent
        savedListeningContextConsent = listeningContextConsent
        pendingRemovedProviders = [:]
        for provider in draftProviderSet.providers {
            if await intelligence.hasStoredAPIKey(configuration: provider),
               let scope = Self.credentialScope(for: provider) {
                storedAPIKeyScopes[provider.id] = scope
            }
        }
        didLoad = true
    }

    /// Picks up the switches that changed outside this page (the tag tidy-up
    /// prompt, the home page's "turn on" card, another device), so the next
    /// autosave here does not write the old values back. A change the
    /// listener is making here wins.
    func adoptStoredConsent(from intelligence: MusicIntelligenceService) {
        guard didLoad else { return }
        let store = intelligence.settingsStore
        if consent == savedConsent {
            consent = store.hasExplicitRemoteConsent
            savedConsent = consent
        }
        if listeningContextConsent == savedListeningContextConsent {
            listeningContextConsent = store.hasExplicitListeningContextConsent
            savedListeningContextConsent = listeningContextConsent
        }
        if primuseRelayEnabled == savedPrimuseRelayEnabled {
            primuseRelayEnabled = store.primuseRelayEnabled
            savedPrimuseRelayEnabled = primuseRelayEnabled
        }
        if semanticSearchEnabled == savedSemanticSearchEnabled {
            semanticSearchEnabled = store.semanticSearchEnabled
            savedSemanticSearchEnabled = semanticSearchEnabled
        }
        if recommendationsEnabled == savedRecommendationsEnabled {
            recommendationsEnabled = store.recommendationsEnabled
            savedRecommendationsEnabled = recommendationsEnabled
        }
    }

    /// 智能功能此刻由谁来做,设置页第一段的状态行。加载完之前不下结论。
    func activeEngine(hasOfflinePacks: Bool) -> AIActiveEngine? {
        guard didLoad else { return nil }
        return AIActiveEngine.resolve(
            relayEnabled: primuseRelayEnabled,
            relaySupportedOnDevice: PrimuseAIRelayClient.isSupportedOnCurrentDevice,
            primaryProviderID: draftProviderSet.primaryProviderID,
            providers: draftProviderSet.providers.map {
                AIProviderSetupSummary(id: $0.id, state: setupState(for: $0) ?? .disabled)
            },
            hasOfflinePacks: hasOfflinePacks
        )
    }

    /// 状态行的文字:「内置 AI」「我的 AI 服务 · DeepSeek」「离线素材包(仅歌词翻译)」「未开启」。
    func activeEngineTitle(_ engine: AIActiveEngine) -> String {
        switch engine {
        case .builtIn:
            return String(localized: "ai_settings_engine_builtin")
        case .ownService(let providerID):
            let name = draftProviderSet.providers.first { $0.id == providerID }?.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return String(
                format: String(localized: "ai_settings_engine_own_format"),
                name.isEmpty ? String(localized: "ai_provider_default_name") : name
            )
        case .offlinePacks:
            return String(localized: "ai_settings_engine_offline")
        case .none:
            return String(localized: "ai_settings_engine_none")
        }
    }

    // MARK: 功能分工

    /// 「默认使用」:内置 AI,或自己的某项服务(用它的默认模型)。
    enum DefaultEngine: Hashable {
        case builtIn
        case provider(UUID)
    }

    var defaultEngine: DefaultEngine {
        primuseRelayEnabled ? .builtIn : .provider(draftProviderSet.primaryProviderID)
    }

    /// 选一项服务当默认就是关掉内置 AI、把它设为主服务;没启用的顺手启用。
    func chooseDefaultEngine(_ engine: DefaultEngine) {
        switch engine {
        case .builtIn:
            primuseRelayEnabled = true
        case .provider(let id):
            guard let index = draftProviderSet.providers.firstIndex(where: { $0.id == id }) else {
                return
            }
            primuseRelayEnabled = false
            draftProviderSet.primaryProviderID = id
            draftProviderSet.providers[index].isEnabled = true
        }
        draftDidChange()
    }

    func provider(_ id: UUID) -> AIRemoteProviderConfiguration? {
        draftProviderSet.providers.first { $0.id == id }
    }

    func providerTitle(_ provider: AIRemoteProviderConfiguration) -> String {
        let name = provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "ai_provider_default_name") : name
    }

    /// 「DeepSeek · deepseek-chat」;`model` 为空时用这项服务的默认模型,还没有模型就只写服务名。
    func providerModelTitle(_ provider: AIRemoteProviderConfiguration, model: String = "") -> String {
        let chosen = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = chosen.isEmpty
            ? provider.generationModel.trimmingCharacters(in: .whitespacesAndNewlines)
            : chosen
        return resolved.isEmpty ? providerTitle(provider) : "\(providerTitle(provider)) · \(resolved)"
    }

    var defaultEngineTitle: String {
        switch defaultEngine {
        case .builtIn:
            return String(localized: "ai_settings_engine_builtin")
        case .provider(let id):
            return self.provider(id).map { providerModelTitle($0) }
                ?? String(localized: "ai_provider_default_name")
        }
    }

    func route(for feature: AIFeature) -> AIFeatureRoute? {
        draftProviderSet.route(for: feature)
    }

    func setRoute(_ route: AIFeatureRoute?, for feature: AIFeature) {
        guard draftProviderSet.route(for: feature) != route else { return }
        draftProviderSet.setRoute(route, for: feature)
        draftDidChange()
    }

    /// 点名的模型照原样记下,以后改这项服务的默认模型也不会把它换掉。
    func route(_ feature: AIFeature, to provider: AIRemoteProviderConfiguration, model: String) {
        setRoute(.provider(id: provider.id, model: model), for: feature)
    }

    func routeTitle(for feature: AIFeature) -> String {
        switch route(for: feature) {
        case nil:
            return String(
                format: String(localized: "ai_route_follow_default_format"),
                defaultEngineTitle
            )
        case .builtIn:
            return String(localized: "ai_settings_engine_builtin")
        case .provider(let id, let model):
            guard let configuration = self.provider(id) else {
                return String(localized: "ai_route_follow_default")
            }
            return providerModelTitle(configuration, model: model)
        }
    }

    /// 交给了已停用的服务时说一声:眼下由默认服务顶着。
    func routeNote(for feature: AIFeature) -> String? {
        guard case .provider(let id, _)? = route(for: feature),
              let configuration = self.provider(id), !configuration.isEnabled else { return nil }
        return String(format: String(localized: "ai_route_stale_format"), providerTitle(configuration))
    }

    /// 分工菜单里列的服务:启用了的才列,没填密钥的也能先选上。
    var routableProviders: [AIRemoteProviderConfiguration] {
        draftProviderSet.providers.filter(\.isEnabled)
    }

    /// 菜单里这项服务能选的模型。分给某功能后又从列表里拿掉的模型也留着,勾选才看得见。
    func routeModels(
        for provider: AIRemoteProviderConfiguration,
        feature: AIFeature
    ) -> [String] {
        var models = provider.selectableGenerationModels
        if case .provider(let id, let model)? = route(for: feature), id == provider.id {
            let chosen = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !chosen.isEmpty, !models.contains(chosen) { models.append(chosen) }
        }
        return models
    }

    func isRouted(
        _ feature: AIFeature,
        to provider: AIRemoteProviderConfiguration,
        model: String
    ) -> Bool {
        guard case .provider(let id, let routed)? = route(for: feature),
              id == provider.id else { return false }
        let chosen = routed.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = chosen.isEmpty
            ? provider.generationModel.trimmingCharacters(in: .whitespacesAndNewlines)
            : chosen
        return resolved == model
    }

    /// 服务页的「正在用于」:是不是默认、哪些功能点名了它、会不会在别的服务出错时接手。
    /// `providerID` 为 nil 指内置 AI。
    func usageLines(forProvider providerID: UUID?) -> [String] {
        let isDefault = providerID == nil
            ? primuseRelayEnabled
            : !primuseRelayEnabled && draftProviderSet.primaryProviderID == providerID
        let assigned = AIFeature.allCases.filter { feature in
            switch draftProviderSet.route(for: feature) {
            case .builtIn: providerID == nil
            case .provider(let id, _): id == providerID
            case nil: false
            }
        }
        var lines: [String] = []
        if isDefault {
            lines.append(String(localized: "ai_service_usage_default"))
        }
        if !assigned.isEmpty {
            lines.append(String(
                format: String(localized: "ai_service_usage_assigned_format"),
                ListFormatter.localizedString(byJoining: assigned.map(\.localizedTitle))
            ))
        }
        if !isDefault, assigned.isEmpty {
            lines.append(String(localized: "ai_service_usage_none"))
        }
        if let providerID, !isDefault, draftProviderSet.fallbackEnabled,
           provider(providerID)?.isEnabled == true {
            lines.append(String(localized: "ai_service_usage_fallback"))
        }
        return lines
    }

    // MARK: 一项服务的多个模型

    /// 当前服务除默认模型以外、给各功能挑的模型。
    var additionalModels: [String] {
        let defaultModel = draftConfiguration.generationModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return draftConfiguration.selectableGenerationModels.filter { $0 != defaultModel }
    }

    /// 在线模型里还没加进来的,给「添加模型」菜单用。
    var addableModels: [AIProviderModel] {
        let existing = Set(draftConfiguration.selectableGenerationModels)
        return availableModels.filter { !existing.contains($0.id) }
    }

    func addModel(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !draftConfiguration.selectableGenerationModels.contains(trimmed) else { return }
        if draftConfiguration.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftConfiguration.generationModel = trimmed
        } else {
            draftConfiguration.additionalGenerationModels.append(trimmed)
        }
        draftDidChange()
    }

    func removeAdditionalModel(_ model: String) {
        draftConfiguration.additionalGenerationModels.removeAll {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == model
        }
        draftDidChange()
    }

    /// 原来的默认模型挪进其余模型的最前面,还能继续分给功能。
    func makeDefaultModel(_ model: String) {
        var configuration = draftConfiguration
        let previous = configuration.generationModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard previous != model else { return }
        configuration.additionalGenerationModels.removeAll {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == model
        }
        if !previous.isEmpty {
            configuration.additionalGenerationModels.insert(previous, at: 0)
        }
        configuration.generationModel = model
        draftConfiguration = configuration
        draftDidChange()
    }

    func configurationBinding<Value>(
        _ keyPath: WritableKeyPath<AIRemoteProviderConfiguration, Value>,
        clearModels: Bool = false,
        updatesProviderPreset: Bool = false,
        autoSaveDelayNanoseconds: UInt64 = 450_000_000
    ) -> Binding<Value> {
        Binding(
            get: { self.draftConfiguration[keyPath: keyPath] },
            set: { value in
                self.draftConfiguration[keyPath: keyPath] = value
                if updatesProviderPreset {
                    self.selectedProviderPreset = AIProviderPreset.matching(
                        configuration: self.draftConfiguration
                    )
                }
                self.draftDidChange(
                    clearModels: clearModels,
                    autoSaveDelayNanoseconds: autoSaveDelayNanoseconds
                )
            }
        )
    }

    var consentBinding: Binding<Bool> {
        Binding(
            get: { self.consent },
            set: { value in
                self.consent = value
                self.draftDidChange()
            }
        )
    }

    var apiKeyBinding: Binding<String> {
        Binding(
            get: { self.apiKeyDraft },
            set: { value in
                self.apiKeyDraft = value
                self.draftDidChange(
                    clearModels: true,
                    autoSaveDelayNanoseconds: 650_000_000
                )
            }
        )
    }

    var providerPresetBinding: Binding<AIProviderPreset> {
        Binding(
            get: { self.selectedProviderPreset },
            set: { self.applyProviderPreset($0) }
        )
    }

    var semanticSearchBinding: Binding<Bool> {
        Binding(
            get: { self.semanticSearchEnabled },
            set: { value in
                self.semanticSearchEnabled = value
                self.draftDidChange()
            }
        )
    }

    var primuseRelayBinding: Binding<Bool> {
        Binding(
            get: { self.primuseRelayEnabled },
            set: { value in
                self.primuseRelayEnabled = value
                self.draftDidChange()
            }
        )
    }

    var recommendationsBinding: Binding<Bool> {
        Binding(
            get: { self.recommendationsEnabled },
            set: { value in
                self.recommendationsEnabled = value
                self.draftDidChange()
            }
        )
    }

    var listeningContextConsentBinding: Binding<Bool> {
        Binding(
            get: { self.listeningContextConsent },
            set: { value in
                self.listeningContextConsent = value
                self.draftDidChange()
            }
        )
    }

    var fallbackBinding: Binding<Bool> {
        Binding(
            get: { self.draftProviderSet.fallbackEnabled },
            set: { value in
                self.draftProviderSet.fallbackEnabled = value
                self.draftDidChange()
            }
        )
    }

    func providerEnabledBinding(_ providerID: UUID) -> Binding<Bool> {
        Binding(
            get: {
                self.draftProviderSet.providers.first { $0.id == providerID }?.isEnabled ?? false
            },
            set: { value in
                guard let index = self.draftProviderSet.providers.firstIndex(where: {
                    $0.id == providerID
                }) else { return }
                self.draftProviderSet.providers[index].isEnabled = value
                self.draftDidChange()
            }
        )
    }

    func selectProvider(_ providerID: UUID) {
        guard draftProviderSet.providers.contains(where: { $0.id == providerID }) else { return }
        guard selectedProviderID != providerID else {
            status = .idle
            return
        }
        selectedProviderID = providerID
        // Invalidate model/test completions started for the previously selected
        // provider so they cannot update the new provider's UI state.
        draftDidChange()
    }

    func makePrimary(_ providerID: UUID) {
        guard draftProviderSet.providers.contains(where: { $0.id == providerID }) else { return }
        draftProviderSet.primaryProviderID = providerID
        draftDidChange()
    }

    func addProvider() {
        var provider = AIRemoteProviderConfiguration(
            displayName: String(localized: "ai_custom_provider_name"),
            baseURL: "https://api.openai.com/v1",
            isEnabled: true
        )
        while draftProviderSet.providers.contains(where: { $0.id == provider.id }) {
            provider.id = UUID()
        }
        draftProviderSet.providers.append(provider)
        selectedProviderID = provider.id
        selectedProviderPreset = .custom
        draftDidChange(clearModels: true)
    }

    func moveProvider(_ providerID: UUID, offset: Int) {
        guard let source = draftProviderSet.providers.firstIndex(where: {
            $0.id == providerID
        }) else { return }
        let destination = source + offset
        guard draftProviderSet.providers.indices.contains(destination) else { return }
        let provider = draftProviderSet.providers.remove(at: source)
        draftProviderSet.providers.insert(provider, at: destination)
        draftDidChange()
    }

    func removeSelectedProvider() {
        guard draftProviderSet.providers.count > 1,
              let index = draftProviderSet.providers.firstIndex(where: {
                  $0.id == selectedProviderID
              }) else { return }
        let provider = draftProviderSet.providers[index]
        status = .idle
        pendingRemovedProviders[provider.id] = provider
        draftProviderSet.providers.remove(at: index)
        for feature in AIFeature.allCases
        where draftProviderSet.route(for: feature)?.providerID == provider.id {
            draftProviderSet.setRoute(nil, for: feature)
        }
        providerPresets[provider.id] = nil
        apiKeyDrafts[provider.id] = nil
        storedAPIKeyScopes[provider.id] = nil
        availableModelsByProvider[provider.id] = nil
        if draftProviderSet.primaryProviderID == provider.id {
            draftProviderSet.primaryProviderID = draftProviderSet.providers[0].id
        }
        selectedProviderID = draftProviderSet.providers[
            min(index, draftProviderSet.providers.count - 1)
        ].id
        draftDidChange(clearModels: true)
    }

    func applyProviderPreset(_ preset: AIProviderPreset) {
        selectedProviderPreset = preset
        guard preset != .custom else {
            draftConfiguration = preset.applying(to: draftConfiguration)
            draftDidChange()
            return
        }
        draftConfiguration = preset.applying(to: draftConfiguration)
        // 换了服务商,原来那家的其余模型和点名的模型都用不上了,回到它的默认模型。
        draftConfiguration.additionalGenerationModels = []
        for feature in AIFeature.allCases {
            if case .provider(let id, _)? = draftProviderSet.route(for: feature),
               id == selectedProviderID {
                draftProviderSet.setRoute(.provider(id: id, model: ""), for: feature)
            }
        }
        apiKeyDraft = ""
        draftDidChange(clearModels: true)
    }

    var apiStyleBinding: Binding<AICompatibleAPIStyle> {
        Binding(
            get: { self.draftConfiguration.apiStyle },
            set: { value in
                self.draftConfiguration.apiStyle = value
                if !self.draftConfiguration.supportsEmbeddings {
                    self.draftConfiguration.embeddingModel = ""
                }
                self.selectedProviderPreset = AIProviderPreset.matching(
                    configuration: self.draftConfiguration
                )
                self.draftDidChange(clearModels: true)
            }
        )
    }

    var compatibilityModeBinding: Binding<AIProviderCompatibilityMode> {
        Binding(
            get: {
                AIProviderCompatibilityMode(configuration: self.draftConfiguration)
            },
            set: { value in
                self.draftConfiguration = value.applying(to: self.draftConfiguration)
                self.draftConfiguration.prefersCustomConfiguration = true
                self.selectedProviderPreset = .custom
                self.draftDidChange(clearModels: true)
            }
        )
    }

    var resolvedGenerationEndpoint: String? {
        try? AIRemoteEndpointPolicy.generationEndpoint(
            configuration: draftConfiguration
        ).absoluteString
    }

    func fetchModels(using intelligence: MusicIntelligenceService) async {
        let configuration = draftConfiguration
        let apiKey = apiKeyDraft
        let operationGeneration = draftGeneration
        isFetchingModels = true
        status = .idle
        do {
            let models = try await intelligence.availableModels(
                configuration: configuration,
                apiKey: apiKey.isEmpty ? nil : apiKey
            )
            guard canApplyCompletion(operationGeneration) else {
                isFetchingModels = false
                resumePendingAutoSaveIfNeeded()
                return
            }
            availableModels = models
            var updatedConfiguration = draftConfiguration
            let currentModel = updatedConfiguration.generationModel
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let presetDefaultModel = selectedProviderPreset
                .applying(to: updatedConfiguration)
                .generationModel
            let defaultNeedsRefresh = selectedProviderPreset != .custom
                && currentModel == presetDefaultModel
                && !models.contains { $0.id == currentModel }
            if (currentModel.isEmpty || defaultNeedsRefresh),
               let model = Self.preferredGenerationModel(from: models) {
                updatedConfiguration.generationModel = model.id
            }
            if updatedConfiguration.supportsEmbeddings,
               updatedConfiguration.embeddingModel
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let model = Self.preferredEmbeddingModel(from: models) {
                updatedConfiguration.embeddingModel = model.id
            }
            draftConfiguration = updatedConfiguration
            draftDidChange()
            status = models.isEmpty ? .modelsEmpty : .modelsLoaded(models.count)
        } catch {
            if canApplyCompletion(operationGeneration) {
                status = .failed(
                    Self.message(for: error, configuration: configuration),
                    .models
                )
            }
        }
        isFetchingModels = false
        resumePendingAutoSaveIfNeeded()
    }

    func save(using intelligence: MusicIntelligenceService) async {
        self.intelligence = intelligence
        autoSaveTask?.cancel()
        autoSaveTask = nil
        await persistPendingChanges(using: intelligence)
    }

    private func persistPendingChanges(using intelligence: MusicIntelligenceService) async {
        guard didLoad, hasUnsavedChanges else { return }
        if isWorking || isFetchingModels {
            saveRequestedWhileWorking = true
            return
        }
        let providerSet = draftProviderSet
        let primuseRelayEnabled = primuseRelayEnabled
        let semanticSearchEnabled = semanticSearchEnabled
        let recommendationsEnabled = recommendationsEnabled
        let explicitConsent = consent
        let listeningContextConsent = listeningContextConsent
        let apiKeys = apiKeyDrafts
        let removedProviders = pendingRemovedProviders
        let operationGeneration = draftGeneration
        isWorking = true
        status = .saving
        do {
            try await intelligence.save(
                providerSet: providerSet,
                primuseRelayEnabled: primuseRelayEnabled,
                semanticSearchEnabled: semanticSearchEnabled,
                recommendationsEnabled: recommendationsEnabled,
                hasExplicitRemoteConsent: explicitConsent,
                hasExplicitListeningContextConsent: listeningContextConsent,
                apiKeys: apiKeys
            )
            var failedCredentialRemovals: [UUID: AIRemoteProviderConfiguration] = [:]
            for provider in removedProviders.values {
                do {
                    try await intelligence.deleteAPIKey(configuration: provider)
                } catch {
                    failedCredentialRemovals[provider.id] = provider
                }
            }
            var savedScopes: [UUID: String] = [:]
            for provider in providerSet.providers {
                if await intelligence.hasStoredAPIKey(configuration: provider),
                   let scope = Self.credentialScope(for: provider) {
                    savedScopes[provider.id] = scope
                }
            }
            storedAPIKeyScopes = savedScopes
            for (providerID, submittedKey) in apiKeys
            where apiKeyDrafts[providerID] == submittedKey {
                apiKeyDrafts[providerID] = nil
            }
            for providerID in removedProviders.keys
            where failedCredentialRemovals[providerID] == nil {
                pendingRemovedProviders[providerID] = nil
            }
            if draftGeneration == operationGeneration {
                draftProviderSet = intelligence.settingsStore.providerSet
                savedProviderSet = draftProviderSet
            } else {
                savedProviderSet = providerSet
            }
            savedPrimuseRelayEnabled = primuseRelayEnabled
            savedSemanticSearchEnabled = semanticSearchEnabled
            savedRecommendationsEnabled = recommendationsEnabled
            savedConsent = explicitConsent
            savedListeningContextConsent = listeningContextConsent
            for (providerID, provider) in failedCredentialRemovals {
                pendingRemovedProviders[providerID] = provider
            }
            status = failedCredentialRemovals.isEmpty
                ? .saved
                : .failed(String(localized: "ai_error_keychain"), .settings)
        } catch {
            status = .failed(Self.message(for: error), .settings)
        }
        isWorking = false
        let shouldSaveAgain = saveRequestedWhileWorking
            || (draftGeneration != operationGeneration && hasUnsavedChanges)
        saveRequestedWhileWorking = false
        if shouldSaveAgain {
            await persistPendingChanges(using: intelligence)
        }
    }

    func testConnection(using intelligence: MusicIntelligenceService) async {
        let configuration = draftConfiguration
        let apiKey = apiKeyDraft
        let operationGeneration = draftGeneration
        isWorking = true
        status = .idle
        do {
            try await intelligence.testConnection(
                configuration: configuration,
                apiKey: apiKey.isEmpty ? nil : apiKey
            )
            if canApplyCompletion(operationGeneration) {
                status = .connectionSucceeded
            }
        } catch {
            if canApplyCompletion(operationGeneration) {
                status = .failed(
                    Self.message(for: error, configuration: configuration),
                    .settings
                )
            }
        }
        isWorking = false
        resumePendingAutoSaveIfNeeded()
    }

    func testPrimuseRelayConnection(using intelligence: MusicIntelligenceService) async {
        guard canTestPrimuseRelayConnection else { return }
        let providerSet = draftProviderSet
        let apiKeyOverrides = apiKeyDrafts
        isWorking = true
        isTestingPrimuseRelay = true
        status = .idle
        primuseRelayConnectionReport = nil
        primuseRelayConnectionReport = await intelligence.testPrimuseRelayConnection(
            providerSet: providerSet,
            apiKeyOverrides: apiKeyOverrides
        )
        isTestingPrimuseRelay = false
        isWorking = false
        resumePendingAutoSaveIfNeeded()
    }

    func deleteCurrentAPIKey(using intelligence: MusicIntelligenceService) async {
        let configuration = draftConfiguration
        let operationGeneration = draftGeneration
        isWorking = true
        status = .idle
        do {
            try await intelligence.deleteAPIKey(configuration: configuration)
            guard canApplyCompletion(operationGeneration) else {
                isWorking = false
                resumePendingAutoSaveIfNeeded()
                return
            }
            storedAPIKeyScopes[configuration.id] = nil
            availableModels = []
        } catch {
            if canApplyCompletion(operationGeneration) {
                status = .failed(Self.message(for: error), .settings)
            }
        }
        isWorking = false
        resumePendingAutoSaveIfNeeded()
    }

    private var draftCredentialScope: String? {
        Self.credentialScope(for: draftConfiguration)
    }

    private static func credentialScope(
        for configuration: AIRemoteProviderConfiguration
    ) -> String? {
        try? AICredentialStoragePolicy.canonicalScope(configuration: configuration)
    }

    private func draftDidChange(
        clearModels: Bool = false,
        autoSaveDelayNanoseconds: UInt64 = 0
    ) {
        draftGeneration &+= 1
        primuseRelayConnectionReport = nil
        if !isWorking { status = .idle }
        if clearModels { availableModels = [] }
        scheduleAutoSave(afterNanoseconds: autoSaveDelayNanoseconds)
    }

    private func scheduleAutoSave(afterNanoseconds delay: UInt64) {
        guard didLoad, hasUnsavedChanges, let intelligence else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self, weak intelligence] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled, let self, let intelligence else { return }
            self.autoSaveTask = nil
            await self.persistPendingChanges(using: intelligence)
        }
    }

    private func resumePendingAutoSaveIfNeeded() {
        guard saveRequestedWhileWorking || hasUnsavedChanges else { return }
        saveRequestedWhileWorking = false
        scheduleAutoSave(afterNanoseconds: 0)
    }

    private func canApplyCompletion(_ operationGeneration: UInt64) -> Bool {
        AISettingsOperationPolicy.canApplyCompletion(
            operationGeneration: operationGeneration,
            currentGeneration: draftGeneration
        )
    }

    private static func preferredGenerationModel(
        from models: [AIProviderModel]
    ) -> AIProviderModel? {
        let nonGenerationMarkers = [
            "embed", "rerank", "tts", "speech", "whisper", "asr",
            "transcription", "moderation", "image", "video",
        ]
        return models.first { model in
            let id = model.id.lowercased()
            return !nonGenerationMarkers.contains { id.contains($0) }
        }
    }

    private static func preferredEmbeddingModel(
        from models: [AIProviderModel]
    ) -> AIProviderModel? {
        models.first { model in
            let id = model.id.lowercased()
            return id.contains("embed") || id.contains("bge")
        }
    }

    static func message(
        for error: Error,
        configuration: AIRemoteProviderConfiguration? = nil
    ) -> String {
        if case OpenAICompatibleProviderError.invalidConfiguration(let validationError) = error {
            return message(for: validationError)
        }
        switch error {
        case let validationError as AIRemoteEndpointValidationError:
            return message(for: validationError)
        case OpenAICompatibleProviderError.missingCredential:
            if let configuration,
               AIRemoteEndpointPolicy.isOpenAIPlatformEndpoint(
                   configuration: configuration
               ) {
                return String(localized: "ai_error_missing_openai_platform_key")
            }
            return String(localized: "ai_error_missing_key")
        case OpenAICompatibleProviderError.missingGenerationModel:
            return String(localized: "ai_error_missing_model")
        case OpenAICompatibleProviderError.requestFailed(let statusCode):
            return String(
                format: String(localized: "ai_error_http_status_format"),
                statusCode
            )
        case OpenAICompatibleProviderError.invalidResponse:
            return String(localized: "ai_error_models_response")
        case MusicIntelligenceError.timedOut:
            return String(localized: "ai_error_timeout")
        case MusicIntelligenceError.unavailable(.regionRestricted):
            return String(localized: "ai_error_region_restricted")
        case is AICredentialStoreError:
            return String(localized: "ai_error_keychain")
        default:
            return String(localized: "ai_error_connection")
        }
    }

    private static func message(for error: AIRemoteEndpointValidationError) -> String {
        switch error {
        case .insecureLocalHTTPRequiresConsent:
            return String(localized: "ai_error_local_http_consent")
        case .insecurePublicHTTP:
            return String(localized: "ai_error_public_http")
        case .unsupportedCapability:
            return String(localized: "ai_error_unsupported_capability")
        default:
            return String(localized: "ai_error_invalid_url")
        }
    }
}

// 电视端不走这套 `Form` 界面:tvOS 有自己的 `TVAISettingsView`(面板行 + 10ft 字号),
// 这里的分组表在 1920 宽的画面上会把标题和控件甩到左右两端。上面的
// `AISettingsEditorModel` 仍然全平台共用。
#if !os(tvOS)
struct AISettingsView: View {
    /// 「功能」管每个功能交给谁,「服务」管每项服务怎么连。
    private enum Tab: Hashable {
        case features
        case services
    }

    /// 「服务」栏正在看的:内置 AI,或自己的某项服务。
    private enum ServiceSelection: Hashable {
        case builtIn
        case provider(UUID)
    }

    @Environment(MusicIntelligenceService.self) private var intelligence
    @State private var editor = AISettingsEditorModel()
    @State private var tab: Tab = .features
    @State private var serviceSelection: ServiceSelection?
    @State private var showsRemoveProviderConfirmation = false
    @State private var showsManualModelEntry = false
    @State private var manualModelDraft = ""
    /// 歌词翻译开关与「歌词」设置页同源。
    @State private var lyricsTranslation = LyricsTranslationSettingsStore.shared
    /// 「为你」由 AI 整理的开关与全部意图页同源。
    @State private var listeningIntents = ListeningIntentService.shared
    /// 首页「为你推荐」的推荐单位:歌曲 / 专辑 / 混合。
    @AppStorage(AIRecommendationUnit.storageKey)
    private var recommendationUnitRawValue = AIRecommendationUnit.defaultUnit.rawValue
    /// 场景推荐多久重新问一次智能服务。
    @AppStorage(AIRecommendationRefreshInterval.storageKey)
    private var recommendationRefreshRawValue = AIRecommendationRefreshInterval.defaultInterval.rawValue
    @Environment(\.settingsFocusedAnchor) private var focusedSettingsAnchor

    /// 设置搜索要定位到这些项目时,先切到「服务」栏。
    private static let serviceAnchors: Set<String> = [
        "intelligence.relayTest",
        "intelligence.providers",
        "intelligence.addProvider",
    ]

    var body: some View {
        Form {
            if !intelligence.shouldExposeRemoteConfiguration,
               intelligence.regionAvailability.isRefreshing {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("ai_region_checking")
                    }
                }
            } else if !intelligence.shouldExposeRemoteConfiguration {
                Section {
                    ContentUnavailableView(
                        "ai_region_unavailable_title",
                        systemImage: "globe.asia.australia.fill",
                        description: Text("ai_region_unavailable_description")
                    )
                }
            } else {
                tabPicker
                switch tab {
                case .features:
                    defaultEngineSection
                    automaticFeatureSection
                    onDemandFeatureSection
                    privacySection
                case .services:
                    switch resolvedServiceSelection {
                    case .builtIn:
                        builtInServiceSection
                        primuseRelayConnectionSection
                    case .provider:
                        providerHeaderSection
                        providerSection
                        modelSection
                        actionSection
                        providerManagementSection
                        providerPrivacySection
                    }
                }
            }
        }
        .onAppear(perform: followFocusedSetting)
        .onChange(of: focusedSettingsAnchor) { _, _ in followFocusedSetting() }
        .navigationTitle("ai_settings_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if tab == .services, intelligence.shouldExposeRemoteConfiguration {
                    serviceSwitcher
                }
            }
        }
        .onChange(of: intelligence.settingsStore.revision) {
            editor.adoptStoredConsent(from: intelligence)
        }
        .task { await editor.load(using: intelligence) }
        .alert("ai_model_add", isPresented: $showsManualModelEntry) {
            TextField("ai_model_name_prompt", text: $manualModelDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("cancel", role: .cancel) { manualModelDraft = "" }
            Button("add") {
                editor.addModel(manualModelDraft)
                manualModelDraft = ""
            }
        }
    }

    private var tabPicker: some View {
        Section {
            Picker("ai_settings_title", selection: $tab) {
                Text("ai_settings_tab_features").tag(Tab.features)
                Text("ai_settings_tab_services").tag(Tab.services)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("ai.settings.tab")
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func followFocusedSetting() {
        guard let focusedSettingsAnchor,
              focusedSettingsAnchor.hasPrefix("intelligence.") else { return }
        if Self.serviceAnchors.contains(focusedSettingsAnchor) {
            if focusedSettingsAnchor == "intelligence.relayTest" {
                serviceSelection = .builtIn
            }
            tab = .services
        } else {
            tab = .features
        }
    }

    // MARK: 功能

    private var defaultEngineSection: some View {
        Section {
            LabeledContent {
                Menu {
                    defaultEngineMenuItems
                } label: {
                    menuValueLabel(editor.defaultEngineTitle)
                }
            } label: {
                SettingsInfoLabel("ai_default_engine_label") {
                    Text("ai_default_engine_footer")
                }
            }
            .settingsAnchor("intelligence.relay")
            .accessibilityIdentifier("ai.settings.defaultEngine")

            serviceGuidanceRow

            Toggle("ai_fallback_enabled", isOn: editor.fallbackBinding)
                .settingsAnchor("intelligence.fallback")

            if !PrimuseAIRelayClient.isSupportedOnCurrentDevice {
                Label("ai_primuse_relay_unsupported", systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            // 内置 AI 可能限流、下线或改收费,这段提醒不收进圈问号。
            if editor.defaultEngine == .builtIn {
                Text("ai_builtin_service_footer")
            }
        }
    }

    @ViewBuilder
    private var defaultEngineMenuItems: some View {
        Button {
            withAnimation { editor.chooseDefaultEngine(.builtIn) }
        } label: {
            AIMenuChoiceLabel(
                title: String(localized: "ai_settings_engine_builtin"),
                isSelected: editor.defaultEngine == .builtIn
            )
        }
        .disabled(!PrimuseAIRelayClient.isSupportedOnCurrentDevice)
        Section {
            ForEach(editor.draftProviderSet.providers) { provider in
                Button {
                    withAnimation { editor.chooseDefaultEngine(.provider(provider.id)) }
                } label: {
                    AIMenuChoiceLabel(
                        title: editor.providerModelTitle(provider),
                        detail: providerMenuDetail(provider),
                        isSelected: editor.defaultEngine == .provider(provider.id)
                    )
                }
            }
        }
    }

    /// 菜单里服务名下面那行:没配好的说缺什么。
    private func providerMenuDetail(_ provider: AIRemoteProviderConfiguration) -> String? {
        guard let state = editor.setupState(for: provider), state != .ready else { return nil }
        return state.localizedTitle
    }

    private var automaticFeatureSection: some View {
        Section {
            Toggle("ai_enable_recommendations", isOn: editor.recommendationsBinding.animation())
                .settingsAnchor("intelligence.recommendations")
            Picker("ai_recommendation_unit", selection: $recommendationUnitRawValue) {
                ForEach([AIRecommendationUnit.songs, .albums, .mixed], id: \.self) { unit in
                    Text(verbatim: unit.localizedTitle).tag(unit.rawValue)
                }
            }
            .settingsAnchor("intelligence.recommendationUnit")
            Picker("ai_recommendation_refresh_interval", selection: $recommendationRefreshRawValue) {
                ForEach(AIRecommendationRefreshInterval.pickerCases, id: \.self) { interval in
                    Text(verbatim: interval.displayTitle(
                        automatic: intelligence.automaticRecommendationRefreshInterval
                    )).tag(interval.rawValue)
                }
            }
            .settingsAnchor("intelligence.recommendationRefresh")
            if editor.recommendationsEnabled {
                routeRow(.recommendations)
            }

            Toggle("ai_enable_semantic_search", isOn: editor.semanticSearchBinding.animation())
                .settingsAnchor("intelligence.semanticSearch")
            if editor.semanticSearchEnabled {
                routeRow(.semanticSearch)
            }

            Toggle("lyrics_translation_enabled", isOn: $lyricsTranslation.isEnabled.animation())
                .settingsAnchor("intelligence.lyricsTranslation")
            if lyricsTranslation.isEnabled {
                Picker("lyrics_translation_mode", selection: $lyricsTranslation.mode.animation()) {
                    Text("lyrics_translation_mode_system")
                        .tag(LyricsTranslationMode.system)
                    Text("lyrics_translation_mode_intelligent")
                        .tag(LyricsTranslationMode.intelligentWithSystemFallback)
                }
                if lyricsTranslation.mode == .intelligentWithSystemFallback {
                    routeRow(.lyricsTranslation)
                }
            }

            Toggle("listening_intent_ai_toggle", isOn: listeningIntentCurationBinding.animation())
            if listeningIntents.isAICurationEnabled {
                routeRow(.listeningIntents)
            }
        } header: {
            SettingsInfoHeader("ai_capability_section") {
                Text("ai_recommendation_unit_footer")
                Text("ai_recommendation_refresh_footer")
                Text("ai_settings_lyrics_translation_footer")
            }
        }
    }

    private var listeningIntentCurationBinding: Binding<Bool> {
        Binding(
            get: { listeningIntents.isAICurationEnabled },
            set: { listeningIntents.setAICurationEnabled($0) }
        )
    }

    private var onDemandFeatureSection: some View {
        Section {
            routeRow(.tagCleanup, title: AIFeature.tagCleanup.localizedTitle)
                .settingsAnchor("intelligence.routes")
            routeRow(.songDiscovery, title: AIFeature.songDiscovery.localizedTitle)
            routeRow(.libraryInsight, title: AIFeature.libraryInsight.localizedTitle)
            routeRow(.listeningMood, title: AIFeature.listeningMood.localizedTitle)
        } header: {
            SettingsInfoHeader("ai_features_on_demand_section") {
                Text("ai_features_on_demand_footer")
            }
        }
    }

    /// 一个功能交给谁。开关下面的那种标题是「由谁处理」,按需功能直接用功能名。
    private func routeRow(_ feature: AIFeature, title: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            LabeledContent {
                Menu {
                    AIFeatureRouteMenuItems(editor: editor, feature: feature)
                } label: {
                    menuValueLabel(editor.routeTitle(for: feature))
                }
            } label: {
                Text(verbatim: title ?? String(localized: "ai_route_label"))
            }
            if let note = editor.routeNote(for: feature) {
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityIdentifier("ai.settings.route.\(feature.rawValue)")
    }

    private func menuValueLabel(_ value: String) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: value)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var serviceGuidanceRow: some View {
        switch editor.serviceSetupGuidance {
        case .none:
            EmptyView()
        case .configureOwnService(let providerID):
            Button {
                showService(.provider(providerID))
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ai_setup_needs_service_title")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("ai_setup_needs_service_detail")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    disclosureChevron
                }
                .contentShape(Rectangle())
            }
            .accessibilityHint(Text("ai_setup_configure_action"))
        case .relayTakesPriority:
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.green)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ai_setup_relay_first_title")
                        .font(.subheadline.weight(.semibold))
                    Text("ai_setup_relay_first_detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("ai_setup_use_own_service") {
                    withAnimation { useReadyServiceAsDefault() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    /// 「改用我的服务」:默认改成配好了的服务,主服务配好了就用它。
    private func useReadyServiceAsDefault() {
        let ready = editor.draftProviderSet.providers.filter {
            editor.setupState(for: $0) == .ready
        }
        guard let target = ready.first(where: {
            $0.id == editor.draftProviderSet.primaryProviderID
        }) ?? ready.first else { return }
        editor.chooseDefaultEngine(.provider(target.id))
    }

    private var disclosureChevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private var privacySection: some View {
        Section {
            Toggle("ai_remote_consent", isOn: editor.consentBinding)
            Toggle(
                "ai_listening_context_consent",
                isOn: editor.listeningContextConsentBinding
            )
        } header: {
            SettingsInfoHeader("ai_privacy_section") {
                Text("ai_privacy_footer")
            }
            .settingsAnchor("intelligence.privacy")
        }
    }

    // MARK: 服务

    private var resolvedServiceSelection: ServiceSelection {
        switch serviceSelection {
        case .builtIn:
            return .builtIn
        case .provider(let id) where editor.provider(id) != nil:
            return .provider(id)
        default:
            return .provider(editor.selectedProviderID)
        }
    }

    private func showService(_ selection: ServiceSelection) {
        if case .provider(let id) = selection {
            editor.selectProvider(id)
        }
        serviceSelection = selection
        tab = .services
    }

    private var currentServiceTitle: String {
        switch resolvedServiceSelection {
        case .builtIn:
            return String(localized: "ai_settings_engine_builtin")
        case .provider:
            return editor.providerTitle(editor.draftConfiguration)
        }
    }

    /// 右上角:切换正在看的服务、添加服务。
    private var serviceSwitcher: some View {
        Menu {
            Button {
                showService(.builtIn)
            } label: {
                AIMenuChoiceLabel(
                    title: String(localized: "ai_settings_engine_builtin"),
                    detail: editor.defaultEngine == .builtIn
                        ? String(localized: "ai_primary_provider") : nil,
                    isSelected: resolvedServiceSelection == .builtIn
                )
            }
            Section {
                ForEach(editor.draftProviderSet.providers) { provider in
                    Button {
                        showService(.provider(provider.id))
                    } label: {
                        AIMenuChoiceLabel(
                            title: editor.providerTitle(provider),
                            detail: serviceMenuDetail(provider),
                            isSelected: resolvedServiceSelection == .provider(provider.id)
                        )
                    }
                }
            }
            Section {
                Button {
                    editor.addProvider()
                    showService(.provider(editor.selectedProviderID))
                } label: {
                    Label("ai_add_provider", systemImage: "plus")
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: currentServiceTitle)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: 200)
        }
        .accessibilityLabel(Text("ai_service_switcher"))
        .accessibilityValue(Text(verbatim: currentServiceTitle))
        .accessibilityIdentifier("ai.settings.serviceSwitcher")
    }

    private func serviceMenuDetail(_ provider: AIRemoteProviderConfiguration) -> String? {
        var parts: [String] = []
        if editor.defaultEngine == .provider(provider.id) {
            parts.append(String(localized: "ai_primary_provider"))
        }
        if let state = editor.setupState(for: provider), state != .ready {
            parts.append(state.localizedTitle)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 服务页最上面:是谁、配到哪一步、正在用于哪些功能。
    private func serviceHeader(
        title: String,
        systemImage: String,
        state: AIProviderSetupState?,
        usage: [String]
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(
                    Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(.headline)
                if let state {
                    Text(verbatim: state.localizedTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(providerStateColor(state))
                }
                ForEach(usage, id: \.self) { line in
                    Text(verbatim: line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// 别的功能用不到它时,缺密钥不算问题,不用橙色催。
    private func providerStateColor(_ state: AIProviderSetupState) -> Color {
        switch state {
        case .ready:
            return .green
        case .needsAPIKey, .needsModel:
            return editor.defaultEngine == .provider(editor.selectedProviderID)
                ? .orange : .secondary
        case .disabled:
            return .secondary
        }
    }

    private var builtInServiceSection: some View {
        Section {
            serviceHeader(
                title: String(localized: "ai_primuse_relay_name"),
                systemImage: "sparkles",
                state: nil,
                usage: editor.usageLines(forProvider: nil)
            )
            if editor.defaultEngine != .builtIn {
                Button("ai_set_primary", systemImage: "star") {
                    withAnimation { editor.chooseDefaultEngine(.builtIn) }
                }
                .disabled(!PrimuseAIRelayClient.isSupportedOnCurrentDevice)
            }
            if !PrimuseAIRelayClient.isSupportedOnCurrentDevice {
                Label("ai_primuse_relay_unsupported", systemImage: "exclamationmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("ai_builtin_service_footer")
        }
    }

    /// 内置 AI 的连接测试与结果。
    private var primuseRelayConnectionSection: some View {
        Section {
            Button {
                Task { await editor.testPrimuseRelayConnection(using: intelligence) }
            } label: {
                HStack(spacing: 8) {
                    if editor.isTestingPrimuseRelay {
                        ProgressView()
                    } else {
                        Image(systemName: "network")
                    }
                    Text("ai_primuse_relay_test_connection")
                }
                .settingsAnchor("intelligence.relayTest")
            }
            .disabled(!editor.canTestPrimuseRelayConnection)

            if editor.primuseRelayConnectionPresentation != .notTested {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: primuseRelayConnectionIcon)
                        .foregroundStyle(primuseRelayConnectionColor)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: editor.primuseRelayConnectionTitle)
                            .font(.subheadline.weight(.semibold))
                        if let detail = editor.primuseRelayConnectionDetail {
                            Text(verbatim: detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        } header: {
            Text("ai_connection_section")
        }
    }

    private var providerHeaderSection: some View {
        Section {
            serviceHeader(
                title: editor.providerTitle(editor.draftConfiguration),
                systemImage: "key.horizontal",
                state: editor.setupState(for: editor.draftConfiguration),
                usage: editor.usageLines(forProvider: editor.selectedProviderID)
            )
        }
        .settingsAnchor("intelligence.providers")
    }

    private var providerManagementSection: some View {
        let providerID = editor.selectedProviderID
        let providers = editor.draftProviderSet.providers
        let index = providers.firstIndex { $0.id == providerID } ?? 0
        return Section {
            Toggle("ai_provider_enabled", isOn: editor.providerEnabledBinding(providerID))
            if editor.defaultEngine != .provider(providerID) {
                Button("ai_set_primary", systemImage: "star") {
                    withAnimation { editor.chooseDefaultEngine(.provider(providerID)) }
                }
            }
            if providers.count > 1 {
                Button("ai_move_up", systemImage: "arrow.up") {
                    editor.moveProvider(providerID, offset: -1)
                }
                .disabled(index == 0)
                Button("ai_move_down", systemImage: "arrow.down") {
                    editor.moveProvider(providerID, offset: 1)
                }
                .disabled(index == providers.count - 1)
                Button("ai_remove_provider", systemImage: "trash", role: .destructive) {
                    showsRemoveProviderConfirmation = true
                }
                // 挂在按钮上才从这一行弹出;挂在整页上,iOS 26 起会锚到页面顶部或底部。
                .confirmationDialog(
                    "ai_remove_provider_confirm",
                    isPresented: $showsRemoveProviderConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("ai_remove_provider", role: .destructive) {
                        editor.removeSelectedProvider()
                    }
                    Button("cancel", role: .cancel) {}
                }
            }
        } header: {
            SettingsInfoHeader("ai_service_manage_section") {
                Text("ai_fallback_footer")
            }
        }
    }

    private var providerSection: some View {
        Section {
            Picker("ai_provider_preset", selection: editor.providerPresetBinding) {
                ForEach(visibleProviderPresets, id: \.self) { preset in
                    Text(preset.localizedTitle).tag(preset)
                }
            }

            if editor.selectedProviderPreset == .custom {
                TextField(
                    "ai_provider_name",
                    text: editor.configurationBinding(\.displayName)
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                TextField(
                    "ai_base_url",
                    text: editor.configurationBinding(
                        \.baseURL,
                        clearModels: true,
                        updatesProviderPreset: true
                    )
                )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Picker("ai_compatibility_mode", selection: editor.compatibilityModeBinding) {
                    ForEach(AIProviderCompatibilityMode.allCases, id: \.self) { mode in
                        Text(mode.localizedTitle).tag(mode)
                    }
                }
            } else {
                LabeledContent("ai_service_address") {
                    Text(verbatim: editor.draftConfiguration.baseURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }

            SecureField(editor.apiKeyTitle, text: editor.apiKeyBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if editor.hasStoredAPIKeyForDraft && editor.apiKeyDraft.isEmpty {
                Label("ai_api_key_stored", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            // 订阅不含 API 用量、要单独计费,这条直接摆出来;发送范围的说明在下面隐私分区的圈问号里。
            if editor.usesOpenAIPlatformAPI {
                Text("ai_openai_platform_billing_footer")
            }
        }
    }

    private var modelSection: some View {
        Section {
            AIModelSelectionField(
                title: String(localized: "ai_default_model"),
                text: editor.configurationBinding(\.generationModel),
                models: editor.availableModels
            )
            ForEach(editor.additionalModels, id: \.self) { model in
                Text(verbatim: model)
                    .contextMenu {
                        Button("ai_model_make_default", systemImage: "star") {
                            editor.makeDefaultModel(model)
                        }
                        Button("ai_model_remove", systemImage: "trash", role: .destructive) {
                            editor.removeAdditionalModel(model)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("ai_model_remove", systemImage: "trash", role: .destructive) {
                            editor.removeAdditionalModel(model)
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("ai_model_make_default", systemImage: "star") {
                            editor.makeDefaultModel(model)
                        }
                        .tint(.accentColor)
                    }
            }
            addModelControl

            if editor.draftConfiguration.supportsEmbeddings {
                AIModelSelectionField(
                    title: String(localized: "ai_embedding_model"),
                    text: editor.configurationBinding(\.embeddingModel),
                    models: editor.availableModels
                )
            } else {
                Label("ai_embedding_unsupported", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await editor.fetchModels(using: intelligence) }
            } label: {
                HStack {
                    Label("ai_fetch_models", systemImage: "arrow.triangle.2.circlepath")
                    if editor.isFetchingModels {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(!editor.canFetchModels)

            statusView(onlyModelStatus: true)
        } header: {
            SettingsInfoHeader("ai_models_section") {
                Text("ai_models_routing_footer")
            }
        }
    }

    /// 拉过在线模型就从里面挑,也能手动输入。
    @ViewBuilder
    private var addModelControl: some View {
        if editor.addableModels.isEmpty {
            Button {
                manualModelDraft = ""
                showsManualModelEntry = true
            } label: {
                Label("ai_model_add", systemImage: "plus")
            }
        } else {
            Menu {
                ForEach(editor.addableModels) { model in
                    Button(model.id) { editor.addModel(model.id) }
                }
                Divider()
                Button("ai_model_add_manual") {
                    manualModelDraft = ""
                    showsManualModelEntry = true
                }
            } label: {
                Label("ai_model_add", systemImage: "plus")
            }
        }
    }

    private var providerPrivacySection: some View {
        Section {
            Toggle(
                "ai_allow_insecure_local_http",
                isOn: editor.configurationBinding(
                    \.allowInsecureLocalHTTP,
                    clearModels: true,
                    autoSaveDelayNanoseconds: 0
                )
            )
        } header: {
            SettingsInfoHeader("ai_privacy_section") {
                Text("ai_provider_footer")
                Text("ai_key_sync_footer")
            }
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await editor.testConnection(using: intelligence) }
            } label: {
                Label("ai_test_connection", systemImage: "network")
            }
            .disabled(!editor.canTestConnection)

            if editor.hasStoredAPIKeyForDraft {
                Button("ai_delete_current_api_key", role: .destructive) {
                    Task { await editor.deleteCurrentAPIKey(using: intelligence) }
                }
                .disabled(editor.isWorking || editor.isFetchingModels)
            }

            statusView(onlyModelStatus: false)
        }
    }

    @ViewBuilder
    private func statusView(onlyModelStatus: Bool) -> some View {
        switch editor.status {
        case .idle:
            EmptyView()
        case .saving where !onlyModelStatus:
            HStack {
                ProgressView()
                Text("ai_saving_changes")
            }
        case .modelsLoaded(let count) where onlyModelStatus:
            Label(
                String(format: String(localized: "ai_models_loaded_format"), count),
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
        case .modelsEmpty where onlyModelStatus:
            Label("ai_models_empty", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        case .saved where !onlyModelStatus:
            Label("ai_settings_saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .connectionSucceeded where !onlyModelStatus:
            Label("ai_connection_success", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message, .models) where onlyModelStatus:
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .failed(let message, .settings) where !onlyModelStatus:
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private var primuseRelayConnectionIcon: String {
        switch editor.primuseRelayConnectionPresentation {
        case .notTested:
            return "questionmark.circle"
        case .testing:
            return "arrow.triangle.2.circlepath"
        case .success:
            return "checkmark.circle.fill"
        case .degraded:
            return "arrow.down.right.circle.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        }
    }

    private var primuseRelayConnectionColor: Color {
        switch editor.primuseRelayConnectionPresentation {
        case .success:
            return .green
        case .degraded:
            return .orange
        case .failure:
            return .red
        case .notTested, .testing:
            return .secondary
        }
    }

    private var visibleProviderPresets: [AIProviderPreset] {
        var presets = [AIProviderPreset.custom]
        presets.append(contentsOf: AIProviderPreset.catalog(
            for: intelligence.regionAvailability.context.region
        ))
        return presets
    }
}

/// 一个功能「由谁处理」的菜单内容:跟随默认、内置 AI,再按服务分组列出各自的模型。
/// iPhone 与 Mac 的设置页共用。
struct AIFeatureRouteMenuItems: View {
    let editor: AISettingsEditorModel
    let feature: AIFeature

    var body: some View {
        Button {
            editor.setRoute(nil, for: feature)
        } label: {
            AIMenuChoiceLabel(
                title: String(
                    format: String(localized: "ai_route_follow_default_format"),
                    editor.defaultEngineTitle
                ),
                isSelected: editor.route(for: feature) == nil
            )
        }
        Button {
            editor.setRoute(.builtIn, for: feature)
        } label: {
            AIMenuChoiceLabel(
                title: String(localized: "ai_settings_engine_builtin"),
                isSelected: editor.route(for: feature) == .builtIn
            )
        }
        .disabled(!PrimuseAIRelayClient.isSupportedOnCurrentDevice)
        ForEach(editor.routableProviders) { provider in
            Section(sectionTitle(provider)) {
                let models = editor.routeModels(for: provider, feature: feature)
                if models.isEmpty {
                    Button("ai_route_no_model") {}
                        .disabled(true)
                }
                ForEach(models, id: \.self) { model in
                    Button {
                        editor.route(feature, to: provider, model: model)
                    } label: {
                        AIMenuChoiceLabel(
                            title: modelTitle(model, of: provider),
                            isSelected: editor.isRouted(feature, to: provider, model: model)
                        )
                    }
                }
            }
        }
    }

    private func sectionTitle(_ provider: AIRemoteProviderConfiguration) -> String {
        let name = editor.providerTitle(provider)
        guard let state = editor.setupState(for: provider), state != .ready else { return name }
        return "\(name) · \(state.localizedTitle)"
    }

    private func modelTitle(_ model: String, of provider: AIRemoteProviderConfiguration) -> String {
        guard model == provider.generationModel.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return model
        }
        return String(format: String(localized: "ai_route_default_model_format"), model)
    }
}

/// 菜单里可勾选的一项:选中的带勾(macOS 27 起菜单默认不画图标,勾要显式要求)。
/// 第二行文字是副标题。
struct AIMenuChoiceLabel: View {
    let title: String
    var detail: String?
    let isSelected: Bool

    var body: some View {
        if isSelected {
            Label {
                titleLines
            } icon: {
                Image(systemName: "checkmark")
            }
            .labelStyle(.titleAndIcon)
        } else {
            titleLines
        }
    }

    @ViewBuilder
    private var titleLines: some View {
        Text(verbatim: title)
        if let detail {
            Text(verbatim: detail)
        }
    }
}

#endif

extension AIFeature {
    var localizedTitle: String {
        switch self {
        case .recommendations: String(localized: "ai_enable_recommendations")
        case .semanticSearch: String(localized: "ai_enable_semantic_search")
        case .lyricsTranslation: String(localized: "lyrics_translation_title")
        case .listeningIntents: String(localized: "ai_feature_listening_intents")
        case .tagCleanup: String(localized: "ai_feature_tag_cleanup")
        case .songDiscovery: String(localized: "ai_song_discovery_title")
        case .libraryInsight: String(localized: "ai_feature_library_insight")
        case .listeningMood: String(localized: "ai_feature_listening_mood")
        }
    }
}

extension AIProviderSetupState {
    var localizedTitle: String {
        switch self {
        case .disabled: String(localized: "ai_provider_state_disabled")
        case .needsAPIKey: String(localized: "ai_provider_state_needs_key")
        case .needsModel: String(localized: "ai_provider_state_needs_model")
        case .ready: String(localized: "ai_provider_state_ready")
        }
    }
}

extension AIProviderPreset {
    var localizedTitle: String {
        switch self {
        case .custom: String(localized: "ai_provider_preset_custom")
        case .openAI: String(localized: "ai_provider_preset_openai")
        case .anthropic: String(localized: "ai_provider_preset_anthropic")
        case .gemini: String(localized: "ai_provider_preset_gemini")
        case .deepSeekOpenAI: String(localized: "ai_provider_preset_deepseek")
        case .deepSeekAnthropic: String(localized: "ai_provider_preset_deepseek_anthropic")
        case .qwen: String(localized: "ai_provider_preset_qwen")
        case .zhipu: String(localized: "ai_provider_preset_zhipu")
        case .xiaomiMiMo: String(localized: "ai_provider_preset_xiaomi_mimo")
        case .kimi: String(localized: "ai_provider_preset_kimi")
        case .miniMax: String(localized: "ai_provider_preset_minimax")
        case .volcengineArk: String(localized: "ai_provider_preset_volcengine_ark")
        case .tencentTokenHub: String(localized: "ai_provider_preset_tencent_tokenhub")
        case .baiduQianfan: String(localized: "ai_provider_preset_baidu_qianfan")
        case .stepFun: String(localized: "ai_provider_preset_stepfun")
        case .siliconFlow: String(localized: "ai_provider_preset_siliconflow")
        case .senseNova: String(localized: "ai_provider_preset_sensenova")
        case .agnesAI: String(localized: "ai_provider_preset_agnes")
        case .agnesAIMainland: String(localized: "ai_provider_preset_agnes_mainland")
        case .openRouter: String(localized: "ai_provider_preset_openrouter")
        case .nvidiaNIM: String(localized: "ai_provider_preset_nvidia_nim")
        case .xAI: String(localized: "ai_provider_preset_xai")
        case .mistral: String(localized: "ai_provider_preset_mistral")
        case .groq: String(localized: "ai_provider_preset_groq")
        case .togetherAI: String(localized: "ai_provider_preset_together")
        case .fireworksAI: String(localized: "ai_provider_preset_fireworks")
        }
    }
}

extension AIProviderCompatibilityMode {
    var localizedTitle: String {
        switch self {
        case .openAIResponses: String(localized: "ai_compatibility_openai_responses")
        case .openAIChatCompletions: String(localized: "ai_compatibility_openai_chat")
        case .anthropicMessages: String(localized: "ai_compatibility_anthropic")
        case .geminiGenerateContent: String(localized: "ai_compatibility_gemini")
        }
    }
}

#if !os(tvOS)
private struct AIModelSelectionField: View {
    let title: String
    @Binding var text: String
    let models: [AIProviderModel]

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $text, prompt: Text(verbatim: title))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            if !models.isEmpty {
                Menu {
                    ForEach(models) { model in
                        Button(model.id) { text = model.id }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
            }
        }
    }
}
#endif
