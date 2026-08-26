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
        case saved
        case connectionSucceeded
        case modelsLoaded(Int)
        case modelsEmpty
        case failed(String, Operation)
    }

    var draftConfiguration = AIRemoteProviderConfiguration()
    var consent = false
    var apiKeyDraft = ""
    var hasStoredAPIKey = false
    var storedAPIKeyScope: String?
    var availableModels: [AIProviderModel] = []
    var didLoad = false
    var isWorking = false
    var isFetchingModels = false
    var status: Status = .idle

    private var draftGeneration: UInt64 = 0

    var hasStoredAPIKeyForDraft: Bool {
        hasStoredAPIKey && storedAPIKeyScope == draftCredentialScope
    }

    var hasUsableAPIKey: Bool {
        hasStoredAPIKeyForDraft
            || !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canFetchModels: Bool {
        !isWorking && !isFetchingModels && consent && hasUsableAPIKey
            && !draftConfiguration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canTestConnection: Bool {
        !isWorking && !isFetchingModels && consent && hasUsableAPIKey
            && !draftConfiguration.generationModel
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func load(using intelligence: MusicIntelligenceService) async {
        guard !didLoad else { return }
        didLoad = true
        await intelligence.regionAvailability.refresh()
        draftConfiguration = intelligence.settingsStore.configuration
        consent = intelligence.settingsStore.hasExplicitRemoteConsent
        hasStoredAPIKey = await intelligence.hasStoredAPIKey(configuration: draftConfiguration)
        storedAPIKeyScope = hasStoredAPIKey ? draftCredentialScope : nil
    }

    func configurationBinding<Value>(
        _ keyPath: WritableKeyPath<AIRemoteProviderConfiguration, Value>,
        clearModels: Bool = false
    ) -> Binding<Value> {
        Binding(
            get: { self.draftConfiguration[keyPath: keyPath] },
            set: { value in
                self.draftConfiguration[keyPath: keyPath] = value
                self.draftDidChange(clearModels: clearModels)
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
                self.draftDidChange(clearModels: true)
            }
        )
    }

    var providerPresetBinding: Binding<AIProviderPreset> {
        Binding(
            get: { AIProviderPreset.matching(configuration: self.draftConfiguration) },
            set: { preset in
                guard preset != .custom else { return }
                self.draftConfiguration = preset.applying(to: self.draftConfiguration)
                self.apiKeyDraft = ""
                self.draftDidChange(clearModels: true)
            }
        )
    }

    var apiStyleBinding: Binding<AICompatibleAPIStyle> {
        Binding(
            get: { self.draftConfiguration.apiStyle },
            set: { value in
                self.draftConfiguration.apiStyle = value
                if !self.draftConfiguration.supportsEmbeddings {
                    self.draftConfiguration.embeddingModel = ""
                }
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
        let explicitConsent = consent
        let operationGeneration = draftGeneration
        isFetchingModels = true
        status = .idle
        do {
            let models = try await intelligence.availableModels(
                configuration: configuration,
                hasExplicitRemoteConsent: explicitConsent,
                apiKey: apiKey.isEmpty ? nil : apiKey
            )
            guard canApplyCompletion(operationGeneration) else {
                isFetchingModels = false
                return
            }
            availableModels = models
            status = models.isEmpty ? .modelsEmpty : .modelsLoaded(models.count)
        } catch {
            if canApplyCompletion(operationGeneration) {
                status = .failed(Self.message(for: error), .models)
            }
        }
        isFetchingModels = false
    }

    func save(using intelligence: MusicIntelligenceService) async {
        let configuration = draftConfiguration
        let explicitConsent = consent
        let apiKey = apiKeyDraft
        let operationGeneration = draftGeneration
        isWorking = true
        status = .idle
        do {
            try await intelligence.save(
                configuration: configuration,
                hasExplicitRemoteConsent: explicitConsent,
                apiKey: apiKey.isEmpty ? nil : apiKey
            )
            let storedAPIKey = await intelligence.hasStoredAPIKey(configuration: configuration)
            guard canApplyCompletion(operationGeneration) else {
                isWorking = false
                return
            }
            hasStoredAPIKey = storedAPIKey
            storedAPIKeyScope = storedAPIKey ? Self.credentialScope(for: configuration) : nil
            apiKeyDraft = ""
            status = .saved
        } catch {
            if canApplyCompletion(operationGeneration) {
                status = .failed(Self.message(for: error), .settings)
            }
        }
        isWorking = false
    }

    func testConnection(using intelligence: MusicIntelligenceService) async {
        let configuration = draftConfiguration
        let explicitConsent = consent
        let apiKey = apiKeyDraft
        let operationGeneration = draftGeneration
        isWorking = true
        status = .idle
        do {
            try await intelligence.testConnection(
                configuration: configuration,
                hasExplicitRemoteConsent: explicitConsent,
                apiKey: apiKey.isEmpty ? nil : apiKey
            )
            if canApplyCompletion(operationGeneration) {
                status = .connectionSucceeded
            }
        } catch {
            if canApplyCompletion(operationGeneration) {
                status = .failed(Self.message(for: error), .settings)
            }
        }
        isWorking = false
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
                return
            }
            hasStoredAPIKey = false
            storedAPIKeyScope = nil
            availableModels = []
        } catch {
            if canApplyCompletion(operationGeneration) {
                status = .failed(Self.message(for: error), .settings)
            }
        }
        isWorking = false
    }

    private var draftCredentialScope: String? {
        Self.credentialScope(for: draftConfiguration)
    }

    private static func credentialScope(
        for configuration: AIRemoteProviderConfiguration
    ) -> String? {
        try? AICredentialStoragePolicy.canonicalScope(configuration: configuration)
    }

    private func draftDidChange(clearModels: Bool = false) {
        draftGeneration &+= 1
        status = .idle
        if clearModels { availableModels = [] }
    }

    private func canApplyCompletion(_ operationGeneration: UInt64) -> Bool {
        AISettingsOperationPolicy.canApplyCompletion(
            operationGeneration: operationGeneration,
            currentGeneration: draftGeneration
        )
    }

    static func message(for error: Error) -> String {
        if case OpenAICompatibleProviderError.invalidConfiguration(let validationError) = error {
            return message(for: validationError)
        }
        switch error {
        case let validationError as AIRemoteEndpointValidationError:
            return message(for: validationError)
        case OpenAICompatibleProviderError.missingCredential:
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
                connectionSummary
                capabilitySection
                providerSection
                modelSection
                privacySection
                actionSection
            }
        }
        .navigationTitle("ai_settings_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await editor.load(using: intelligence) }
    }

    private var connectionSummary: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: editor.hasUsableAPIKey ? "sparkles" : "key.horizontal")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                VStack(alignment: .leading, spacing: 3) {
                    Text(editor.draftConfiguration.displayName.isEmpty
                         ? String(localized: "ai_provider_default_name")
                         : editor.draftConfiguration.displayName)
                        .font(.headline)
                    Text(verbatim: String(localized: editor.hasUsableAPIKey
                         ? "ai_connection_ready"
                         : "ai_connection_needs_key"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Circle()
                    .fill(editor.hasUsableAPIKey ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
            }
            .padding(.vertical, 4)
        }
    }

    private var capabilitySection: some View {
        Section {
            Toggle(
                "ai_enable_semantic_search",
                isOn: editor.configurationBinding(\.isEnabled)
            )
        } footer: {
            Text("ai_enable_semantic_search_footer")
        }
    }

    private var providerSection: some View {
        Section {
            Picker("ai_provider_preset", selection: editor.providerPresetBinding) {
                Text("ai_provider_preset_custom").tag(AIProviderPreset.custom)
                Text("ai_provider_preset_openai").tag(AIProviderPreset.openAI)
                Text("ai_provider_preset_anthropic").tag(AIProviderPreset.anthropic)
                Text("ai_provider_preset_deepseek_openai")
                    .tag(AIProviderPreset.deepSeekOpenAI)
                Text("ai_provider_preset_deepseek_anthropic")
                    .tag(AIProviderPreset.deepSeekAnthropic)
            }

            TextField(
                "ai_provider_name",
                text: editor.configurationBinding(\.displayName)
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            TextField(
                "ai_base_url",
                text: editor.configurationBinding(\.baseURL, clearModels: true)
            )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("ai_api_key", text: editor.apiKeyBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if editor.hasStoredAPIKeyForDraft && editor.apiKeyDraft.isEmpty {
                Label("ai_api_key_stored", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("ai_api_style", selection: editor.apiStyleBinding) {
                Text("ai_api_style_responses").tag(AICompatibleAPIStyle.responses)
                Text("ai_api_style_chat_completions").tag(AICompatibleAPIStyle.chatCompletions)
                Text("ai_api_style_anthropic_messages")
                    .tag(AICompatibleAPIStyle.anthropicMessages)
            }

            Picker(
                "ai_path_mode",
                selection: editor.configurationBinding(\.apiPathMode, clearModels: true)
            ) {
                Text("ai_path_mode_automatic").tag(AIAPIPathMode.automatic)
                Text("ai_path_mode_as_entered").tag(AIAPIPathMode.asEntered)
                Text("ai_path_mode_append_v1").tag(AIAPIPathMode.appendV1)
            }

            Picker(
                "ai_authentication_style",
                selection: editor.configurationBinding(\.authenticationStyle, clearModels: true)
            ) {
                Text("ai_authentication_style_automatic")
                    .tag(AIAuthenticationStyle.automatic)
                Text("ai_authentication_style_bearer")
                    .tag(AIAuthenticationStyle.bearer)
                Text("ai_authentication_style_x_api_key")
                    .tag(AIAuthenticationStyle.xAPIKey)
            }

            if let endpoint = editor.resolvedGenerationEndpoint {
                LabeledContent("ai_resolved_endpoint") {
                    Text(verbatim: endpoint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("ai_connection_section")
        } footer: {
            Text("ai_provider_footer")
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
        } footer: {
            Text(editor.draftConfiguration.supportsEmbeddings
                 ? "ai_models_footer" : "ai_models_footer_generation_only")
        }
    }

    private var privacySection: some View {
        Section {
            Toggle(
                "ai_allow_insecure_local_http",
                isOn: editor.configurationBinding(
                    \.allowInsecureLocalHTTP,
                    clearModels: true
                )
            )
            Toggle("ai_remote_consent", isOn: editor.consentBinding)
        } header: {
            Text("ai_privacy_section")
        } footer: {
            Text("ai_privacy_footer")
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                Task { await editor.save(using: intelligence) }
            } label: {
                HStack {
                    Label("save", systemImage: "square.and.arrow.down")
                    if editor.isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(editor.isWorking || editor.isFetchingModels)

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
