import PrimuseKit
import SwiftUI

struct AISettingsView: View {
    @Environment(MusicIntelligenceService.self) private var intelligence

    @State private var draftConfiguration = AIRemoteProviderConfiguration()
    @State private var consent = false
    @State private var apiKeyDraft = ""
    @State private var hasStoredAPIKey = false
    @State private var didLoad = false
    @State private var isWorking = false
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
                profileID: draftConfiguration.id
            )
        }
    }

    @ViewBuilder
    private var providerSections: some View {
        Section {
            Toggle("ai_enable_semantic_search", isOn: $draftConfiguration.isEnabled)
        } footer: {
            Text("ai_enable_semantic_search_footer")
        }

        Section {
            TextField("ai_provider_name", text: $draftConfiguration.displayName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("ai_base_url", text: $draftConfiguration.baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Picker("ai_api_style", selection: $draftConfiguration.apiStyle) {
                Text("ai_api_style_responses").tag(AICompatibleAPIStyle.responses)
                Text("ai_api_style_chat_completions").tag(AICompatibleAPIStyle.chatCompletions)
            }

            TextField("ai_generation_model", text: $draftConfiguration.generationModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            TextField("ai_embedding_model", text: $draftConfiguration.embeddingModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("ai_api_key", text: $apiKeyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if hasStoredAPIKey && apiKeyDraft.isEmpty {
                Label("ai_api_key_stored", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("ai_provider_section")
        } footer: {
            Text("ai_provider_footer")
        }

        Section {
            Toggle("ai_allow_insecure_local_http", isOn: $draftConfiguration.allowInsecureLocalHTTP)
            Toggle("ai_remote_consent", isOn: $consent)
        } footer: {
            Text("ai_privacy_footer")
        }

        Section {
            Button {
                save()
            } label: {
                if isWorking {
                    ProgressView()
                } else {
                    Label("save", systemImage: "square.and.arrow.down")
                }
            }
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
                || (!hasStoredAPIKey && apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        isWorking = true
        status = .idle
        Task {
            do {
                try await intelligence.save(
                    configuration: draftConfiguration,
                    hasExplicitRemoteConsent: consent,
                    apiKey: apiKeyDraft.isEmpty ? nil : apiKeyDraft
                )
                hasStoredAPIKey = await intelligence.hasStoredAPIKey(
                    profileID: draftConfiguration.id
                )
                apiKeyDraft = ""
                status = .saved
            } catch {
                status = .failed(Self.message(for: error))
            }
            isWorking = false
        }
    }

    private func testConnection() {
        isWorking = true
        status = .idle
        Task {
            do {
                try await intelligence.testConnection(
                    configuration: draftConfiguration,
                    hasExplicitRemoteConsent: consent,
                    apiKey: apiKeyDraft.isEmpty ? nil : apiKeyDraft
                )
                status = .connectionSucceeded
            } catch {
                status = .failed(Self.message(for: error))
            }
            isWorking = false
        }
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
