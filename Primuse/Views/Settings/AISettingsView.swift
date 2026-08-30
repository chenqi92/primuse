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
    var primuseRelayEnabled = false
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
    private var savedPrimuseRelayEnabled = false
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
            providerPresets[selectedProviderID]
                ?? AIProviderPreset.matching(configuration: draftConfiguration)
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
            lines.append(String(
                format: String(localized: "ai_primuse_relay_diagnostic_code_format"),
                diagnostic.code
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
        await intelligence.regionAvailability.refresh()
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

struct AISettingsView: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @State private var editor = AISettingsEditorModel()
    @State private var showsRemoveProviderConfirmation = false

    var body: some View {
        Form {
            if intelligence.regionAvailability.isRefreshing,
               intelligence.regionAvailability.context.region == .unknown {
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
                if !usesCompactMobileLayout {
                    connectionSummary
                }
                primuseRelaySection
                capabilitySection
                providerListSection
                if !usesCompactMobileLayout {
                    providerDetailLinkSection
                }
                privacySection
            }
        }
        .navigationTitle("ai_settings_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await editor.load(using: intelligence) }
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

    private var connectionSummary: some View {
        let usesRelay = editor.primuseRelayEnabled
        let isReady = usesRelay ? primuseRelayIsOperational : editor.hasUsableAPIKey
        let stateColor = usesRelay ? primuseRelayConnectionColor
            : (isReady ? Color.green : Color.secondary.opacity(0.35))
        return Section {
            HStack(spacing: 14) {
                Image(systemName: isReady ? "sparkles" : "key.horizontal")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10)
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(usesRelay
                         ? String(localized: "ai_primuse_relay_name")
                         : (editor.draftConfiguration.displayName.isEmpty
                            ? String(localized: "ai_provider_default_name")
                            : editor.draftConfiguration.displayName))
                        .font(.headline)
                    Text(verbatim: connectionSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)
            }
            .padding(.vertical, 4)
        }
    }

    private var primuseRelaySection: some View {
        Section {
            Toggle("ai_primuse_relay_enabled", isOn: editor.primuseRelayBinding)

            if !usesCompactMobileLayout || editor.primuseRelayEnabled {
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
                if !PrimuseAIRelayClient.isSupportedOnCurrentDevice {
                    Label(
                        "ai_primuse_relay_unsupported",
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            if !usesCompactMobileLayout {
                Text("ai_primuse_relay_section")
            }
        } footer: {
            if !usesCompactMobileLayout {
                Text("ai_primuse_relay_footer")
            }
        }
    }

    private var capabilitySection: some View {
        Section {
            Toggle(
                "ai_enable_semantic_search",
                isOn: editor.semanticSearchBinding
            )
            Toggle(
                "ai_enable_recommendations",
                isOn: editor.recommendationsBinding
            )
        } header: {
            if usesCompactMobileLayout {
                Text("ai_capability_section")
            }
        }
    }

    private var providerListSection: some View {
        Section {
            ForEach(Array(editor.draftProviderSet.providers.enumerated()), id: \.element.id) {
                index, provider in
                HStack(spacing: 12) {
                    Button {
                        editor.selectProvider(provider.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: provider.id == editor.selectedProviderID
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(provider.id == editor.selectedProviderID
                                                 ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName.isEmpty
                                     ? String(localized: "ai_provider_default_name")
                                     : provider.displayName)
                                    .foregroundStyle(.primary)
                                if !usesCompactMobileLayout {
                                    Text(provider.baseURL)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()
                    if provider.id == editor.draftProviderSet.primaryProviderID {
                        Text("ai_primary_provider")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    Toggle("", isOn: editor.providerEnabledBinding(provider.id))
                        .labelsHidden()
                    Menu {
                        if provider.id != editor.draftProviderSet.primaryProviderID {
                            Button("ai_set_primary", systemImage: "star") {
                                editor.makePrimary(provider.id)
                            }
                        }
                        Button("ai_move_up", systemImage: "arrow.up") {
                            editor.moveProvider(provider.id, offset: -1)
                        }
                        .disabled(index == 0)
                        Button("ai_move_down", systemImage: "arrow.down") {
                            editor.moveProvider(provider.id, offset: 1)
                        }
                        .disabled(index == editor.draftProviderSet.providers.count - 1)
                        if editor.draftProviderSet.providers.count > 1 {
                            Divider()
                            Button("ai_remove_provider", systemImage: "trash", role: .destructive) {
                                editor.selectProvider(provider.id)
                                showsRemoveProviderConfirmation = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("ai_provider_actions")
                }
                .aiProviderPrimaryAction(
                    isPrimary: provider.id == editor.draftProviderSet.primaryProviderID
                ) {
                    editor.makePrimary(provider.id)
                }
            }

            Toggle("ai_fallback_enabled", isOn: editor.fallbackBinding)

            HStack {
                Button("ai_add_provider", systemImage: "plus") {
                    editor.addProvider()
                }
                Spacer()
                if editor.selectedProviderID != editor.draftProviderSet.primaryProviderID {
                    Button("ai_set_primary") {
                        editor.makePrimary(editor.selectedProviderID)
                    }
                }
            }

            if usesCompactMobileLayout {
                providerDetailNavigationLink
            }
        } header: {
            Text("ai_provider_list_section")
        } footer: {
            if !usesCompactMobileLayout {
                Text("ai_fallback_footer")
            }
        }
    }

    private var providerDetailLinkSection: some View {
        Section {
            providerDetailNavigationLink
        }
    }

    private var providerDetailNavigationLink: some View {
        NavigationLink {
            Form {
                providerSection
                modelSection
                providerPrivacySection
                actionSection
            }
            .navigationTitle(usesCompactMobileLayout
                             ? String(localized: "ai_provider_actions")
                             : String(localized: "ai_provider_detail_section"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        } label: {
            if usesCompactMobileLayout {
                Label("ai_provider_actions", systemImage: "slider.horizontal.3")
            } else {
                LabeledContent {
                    Text(editor.draftConfiguration.displayName.isEmpty
                         ? String(localized: "ai_provider_default_name")
                         : editor.draftConfiguration.displayName)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("ai_provider_detail_section", systemImage: "slider.horizontal.3")
                }
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

            if !selectedProviderIsAvailableInRegion {
                Label("ai_provider_region_blocked", systemImage: "exclamationmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
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
            if usesCompactMobileLayout {
                if editor.usesOpenAIPlatformAPI {
                    Text("ai_openai_platform_billing_footer")
                }
            } else {
                Text(editor.providerFooterText)
            }
        }
    }

    private var modelSection: some View {
        Section {
            AIModelSelectionField(
                title: String(localized: "ai_generation_model"),
                text: editor.configurationBinding(\.generationModel),
                models: editor.availableModels
            )
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
            Text("ai_models_section")
        }
    }

    private var privacySection: some View {
        Section {
            Toggle("ai_remote_consent", isOn: editor.consentBinding)
            Toggle(
                "ai_listening_context_consent",
                isOn: editor.listeningContextConsentBinding
            )
        } header: {
            Text("ai_privacy_section")
        } footer: {
            if !usesCompactMobileLayout {
                Text("ai_privacy_footer")
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
            Text("ai_privacy_section")
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
        } footer: {
            if !usesCompactMobileLayout {
                Text("ai_key_sync_footer")
            }
        }
    }

    private var usesCompactMobileLayout: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
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

    private var connectionSummaryText: String {
        if editor.primuseRelayEnabled,
           editor.primuseRelayConnectionPresentation != .notTested {
            return editor.primuseRelayConnectionTitle
        }
        switch editor.status {
        case .saving:
            return String(localized: "ai_saving_changes")
        case .saved:
            return String(localized: "ai_settings_saved")
        case .connectionSucceeded:
            return String(localized: "ai_connection_success")
        case .failed(let message, _):
            return message
        default:
            if editor.primuseRelayEnabled {
                return editor.primuseRelayConnectionTitle
            }
            return String(
                format: String(localized: "ai_provider_count_format"),
                editor.draftProviderSet.providers.count
            )
        }
    }

    private var primuseRelayIsOperational: Bool {
        guard let report = editor.primuseRelayConnectionReport else { return false }
        if report.isDirectlyAvailable { return true }
        if case .remoteProvider = report.fallback { return true }
        return false
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
        if !presets.contains(editor.selectedProviderPreset) {
            presets.append(editor.selectedProviderPreset)
        }
        return presets
    }

    private var selectedProviderIsAvailableInRegion: Bool {
        AIProviderRegionPolicy.allows(
            configuration: editor.draftConfiguration,
            region: intelligence.regionAvailability.context.region,
            purpose: .modelCatalog
        )
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

private extension View {
    @ViewBuilder
    func aiProviderPrimaryAction(
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        #if os(tvOS)
        self
        #else
        swipeActions(edge: .leading) {
            if !isPrimary {
                Button("ai_set_primary", action: action)
                    .tint(.accentColor)
            }
        }
        #endif
    }
}

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
