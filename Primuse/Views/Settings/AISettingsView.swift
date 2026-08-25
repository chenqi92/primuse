import PrimuseKit
import SwiftUI

struct AISettingsView: View {
    @Environment(MusicIntelligenceService.self) private var intelligence

    @State private var draftConfiguration = AIRemoteProviderConfiguration()
    @State private var consent = false
    @State private var apiKeyDraft = ""
    @State private var hasStoredAPIKey = false
    @State private var storedAPIKeyOrigin: String?
    @State private var didLoad = false
    @State private var isWorking = false
    @State private var draftGeneration: UInt64 = 0
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case saved
        case connectionSucceeded
        case failed(String)
    }

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
                providerSections
                    .disabled(isWorking)
            }
        }
        .navigationTitle("ai_settings_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard !didLoad else { return }
            didLoad = true
            await intelligence.regionAvailability.refresh()
            draftConfiguration = intelligence.settingsStore.configuration
            consent = intelligence.settingsStore.hasExplicitRemoteConsent
            hasStoredAPIKey = await intelligence.hasStoredAPIKey(
                configuration: draftConfiguration
            )
            storedAPIKeyOrigin = hasStoredAPIKey ? draftCredentialOrigin : nil
        }
    }

    @ViewBuilder
    private var providerSections: some View {
        Section {
            Toggle(
                "ai_enable_semantic_search",
                isOn: configurationBinding(\.isEnabled)
            )
        } footer: {
            Text("ai_enable_semantic_search_footer")
        }

        Section {
            TextField(
                "ai_provider_name",
                text: configurationBinding(\.displayName)
            )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField(
                "ai_base_url",
                text: configurationBinding(\.baseURL)
            )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Picker(
                "ai_api_style",
                selection: configurationBinding(\.apiStyle)
            ) {
                Text("ai_api_style_responses").tag(AICompatibleAPIStyle.responses)
                Text("ai_api_style_chat_completions").tag(AICompatibleAPIStyle.chatCompletions)
            }

            TextField(
                "ai_generation_model",
                text: configurationBinding(\.generationModel)
            )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField(
                "ai_embedding_model",
                text: configurationBinding(\.embeddingModel)
            )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("ai_api_key", text: apiKeyBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if hasStoredAPIKeyForDraft && apiKeyDraft.isEmpty {
                Label("ai_api_key_stored", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if hasStoredAPIKeyForDraft {
                Button("ai_delete_current_api_key", role: .destructive) {
                    deleteCurrentAPIKey()
                }
                .disabled(isWorking)
            }
        } header: {
            Text("ai_provider_section")
        } footer: {
            Text("ai_provider_footer")
        }

        Section {
            Toggle(
                "ai_allow_insecure_local_http",
                isOn: configurationBinding(\.allowInsecureLocalHTTP)
            )
            Toggle("ai_remote_consent", isOn: consentBinding)
        } footer: {
            Text("ai_privacy_footer")
        }

        Section {
            Button {
                save()
            } label: {
                HStack {
                    Label("save", systemImage: "square.and.arrow.down")
                    if isWorking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .accessibilityLabel(Text("save"))
            .disabled(isWorking)

            Button {
                testConnection()
            } label: {
                Label("ai_test_connection", systemImage: "network")
            }
            .disabled(
                isWorking
                || !consent
                || draftConfiguration.generationModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (!hasStoredAPIKeyForDraft && apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            )

            switch status {
            case .idle:
                EmptyView()
            case .saved:
                Label("ai_settings_saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .connectionSucceeded:
                Label("ai_connection_success", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func save() {
        let configuration = draftConfiguration
        let consent = consent
        let apiKey = apiKeyDraft
        let operationGeneration = draftGeneration
        isWorking = true
        status = .idle
        Task {
            do {
                try await intelligence.save(
                    configuration: configuration,
                    hasExplicitRemoteConsent: consent,
                    apiKey: apiKey.isEmpty ? nil : apiKey
                )
                let storedAPIKey = await intelligence.hasStoredAPIKey(
                    configuration: configuration
                )
                guard canApplyCompletion(operationGeneration) else {
                    isWorking = false
                    return
                }
                hasStoredAPIKey = storedAPIKey
                storedAPIKeyOrigin = storedAPIKey
                    ? Self.credentialOrigin(for: configuration)
                    : nil
                apiKeyDraft = ""
                status = .saved
            } catch {
                if canApplyCompletion(operationGeneration) {
                    status = .failed(Self.message(for: error))
                }
            }
            isWorking = false
        }
    }

    private func deleteCurrentAPIKey() {
        let configuration = draftConfiguration
        let operationGeneration = draftGeneration
        isWorking = true
        status = .idle
        Task {
            do {
                try await intelligence.deleteAPIKey(configuration: configuration)
                guard canApplyCompletion(operationGeneration) else {
                    isWorking = false
                    return
                }
                hasStoredAPIKey = false
                storedAPIKeyOrigin = nil
            } catch {
                if canApplyCompletion(operationGeneration) {
                    status = .failed(Self.message(for: error))
                }
            }
            isWorking = false
        }
    }

    private var draftCredentialOrigin: String? {
        Self.credentialOrigin(for: draftConfiguration)
    }

    private var hasStoredAPIKeyForDraft: Bool {
        hasStoredAPIKey && storedAPIKeyOrigin == draftCredentialOrigin
    }

    private static func credentialOrigin(
        for configuration: AIRemoteProviderConfiguration
    ) -> String? {
        try? AICredentialStoragePolicy.canonicalOrigin(
            baseURL: configuration.baseURL,
            allowInsecureLocalHTTP: configuration.allowInsecureLocalHTTP
        )
    }

    private func testConnection() {
        let configuration = draftConfiguration
        let consent = consent
        let apiKey = apiKeyDraft
        let operationGeneration = draftGeneration
        isWorking = true
        status = .idle
        Task {
            do {
                try await intelligence.testConnection(
                    configuration: configuration,
                    hasExplicitRemoteConsent: consent,
                    apiKey: apiKey.isEmpty ? nil : apiKey
                )
                if canApplyCompletion(operationGeneration) {
                    status = .connectionSucceeded
                }
            } catch {
                if canApplyCompletion(operationGeneration) {
                    status = .failed(Self.message(for: error))
                }
            }
            isWorking = false
        }
    }

    private func configurationBinding<Value>(
        _ keyPath: WritableKeyPath<AIRemoteProviderConfiguration, Value>
    ) -> Binding<Value> {
        Binding(
            get: { draftConfiguration[keyPath: keyPath] },
            set: { value in
                draftConfiguration[keyPath: keyPath] = value
                draftDidChange()
            }
        )
    }

    private var consentBinding: Binding<Bool> {
        Binding(
            get: { consent },
            set: { value in
                consent = value
                draftDidChange()
            }
        )
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { apiKeyDraft },
            set: { value in
                apiKeyDraft = value
                draftDidChange()
            }
        )
    }

    private func draftDidChange() {
        draftGeneration &+= 1
        status = .idle
    }

    private func canApplyCompletion(_ operationGeneration: UInt64) -> Bool {
        AISettingsOperationPolicy.canApplyCompletion(
            operationGeneration: operationGeneration,
            currentGeneration: draftGeneration
        )
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AIRemoteEndpointValidationError.insecureLocalHTTPRequiresConsent:
            return String(localized: "ai_error_local_http_consent")
        case AIRemoteEndpointValidationError.insecurePublicHTTP:
            return String(localized: "ai_error_public_http")
        case is AIRemoteEndpointValidationError:
            return String(localized: "ai_error_invalid_url")
        case OpenAICompatibleProviderError.missingCredential:
            return String(localized: "ai_error_missing_key")
        case OpenAICompatibleProviderError.missingGenerationModel:
            return String(localized: "ai_error_missing_model")
        case OpenAICompatibleProviderError.requestFailed(let statusCode):
            return String(
                format: String(localized: "ai_error_http_status_format"),
                statusCode
            )
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
}
