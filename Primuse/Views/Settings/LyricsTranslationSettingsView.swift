import Observation
import SwiftUI
import PrimuseKit

/// 歌词翻译设置 — 用 Apple Translation Framework 离线翻译。
/// 已安装语言包自动工作；缺少语言包时播放器先显示显式翻译操作，只有用户
/// 点击后才允许系统展示下载或源语言确认界面。
struct LyricsSettingsView: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @State private var settings = LyricsTranslationSettingsStore.shared
    @State private var languageCatalog = LyricsTranslationLanguageCatalog.shared
    @State private var cacheCount: Int = 0
    @State private var showClearConfirm = false

    var body: some View {
        Form {
            Section {
                Toggle("lyrics_translation_enabled", isOn: $settings.isEnabled)
            } footer: {
                Text("lyrics_translation_overall_footer")
            }

            if settings.isEnabled {
                Section {
                    Picker("lyrics_translation_mode", selection: displayedMode) {
                        Text("lyrics_translation_mode_system")
                            .tag(LyricsTranslationMode.system)
                        if intelligence.shouldExposeRemoteConfiguration {
                            Text("lyrics_translation_mode_intelligent")
                                .tag(LyricsTranslationMode.intelligentWithSystemFallback)
                        }
                    }
                } footer: {
                    Text(displayedMode.wrappedValue == .system
                         ? "lyrics_translation_mode_system_footer"
                         : "lyrics_translation_mode_intelligent_footer")
                }

                Section("lyrics_translation_target_language") {
                    Picker("lyrics_translation_target", selection: $settings.targetLanguageCode) {
                        ForEach(
                            languageCatalog.options(including: settings.targetLanguageCode),
                            id: \.self
                        ) { code in
                            Text(languageCatalog.displayName(for: code)).tag(code)
                        }
                    }
                }

                Section {
                    HStack {
                        Label("lyrics_translation_cached", systemImage: "internaldrive")
                        Spacer()
                        Text("\(cacheCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if cacheCount > 0 {
                        Button("lyrics_translation_clear_cache", role: .destructive) {
                            showClearConfirm = true
                        }
                    }
                } header: {
                    Text("lyrics_translation_cache_section")
                } footer: {
                    Text("lyrics_translation_cache_footer")
                }
            }

            Section {
                NavigationLink {
                    GoogleLyricsTranscriptionSettingsView()
                } label: {
                    LabeledContent {
                        Text(intelligence.isAudioTranscriptionConfigured
                             ? "lyrics_transcription_status_ready"
                             : "lyrics_transcription_status_needs_setup")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label(
                            "lyrics_transcription_settings_title",
                            systemImage: "waveform.badge.mic"
                        )
                    }
                }
            } header: {
                Text("lyrics_audio_tools_section")
            } footer: {
                Text("lyrics_audio_tools_footer")
            }
        }
        .navigationTitle("lyrics_settings_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            cacheCount = LyricsTranslationCache.shared.count
        }
        .task {
            await languageCatalog.refresh()
        }
        .confirmationDialog(
            "lyrics_translation_clear_confirm",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("clear_all", role: .destructive) {
                LyricsTranslationCache.shared.clearAll()
                cacheCount = 0
            }
            Button("cancel", role: .cancel) {}
        }
        #if os(macOS)
        .macReadablePane(maxWidth: 720)
        #endif
    }

    private var displayedMode: Binding<LyricsTranslationMode> {
        Binding(
            get: {
                intelligence.shouldExposeRemoteConfiguration ? settings.mode : .system
            },
            set: { settings.mode = $0 }
        )
    }
}

@MainActor
@Observable
final class LyricsTranscriptionSettingsEditorModel {
    enum Status: Equatable {
        case idle
        case modelsLoaded(Int)
        case modelsEmpty
        case saved
        case failed(String)
    }

    var configuration = LyricsTranscriptionSettingsStore.defaultConfiguration()
    var isEnabled = false
    var hasExplicitAudioUploadConsent = false
    var apiKeyDraft = ""
    var hasStoredAPIKey = false
    var availableModels: [AIProviderModel] = []
    var isWorking = false
    var isFetchingModels = false
    var isLoading = false
    var didLoad = false
    var status: Status = .idle

    var hasUsableAPIKey: Bool {
        hasStoredAPIKey
            || !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canFetchModels: Bool {
        didLoad && !isWorking && !isFetchingModels && hasUsableAPIKey
    }

    var canSave: Bool {
        guard didLoad, !isWorking, !isFetchingModels else { return false }
        guard isEnabled else { return true }
        return hasExplicitAudioUploadConsent
            && hasUsableAPIKey
            && AIAudioTranscriptionPolicy.supports(configuration: configuration)
    }

    func load(using intelligence: MusicIntelligenceService) async {
        guard !didLoad, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        await intelligence.regionAvailability.refresh()
        await intelligence.prepareLyricsTranscriptionCredentialMigration()
        let store = intelligence.lyricsTranscriptionSettingsStore
        configuration = store.configuration
        isEnabled = store.isEnabled
        hasExplicitAudioUploadConsent = store.hasExplicitAudioUploadConsent
        hasStoredAPIKey = await intelligence.hasStoredLyricsTranscriptionAPIKey()
        didLoad = true
    }

    func fetchModels(using intelligence: MusicIntelligenceService) async {
        guard canFetchModels else { return }
        isFetchingModels = true
        status = .idle
        do {
            let models = try await intelligence.availableModels(
                configuration: configuration,
                apiKey: apiKeyDraft.isEmpty ? nil : apiKeyDraft
            )
            let transcriptionModels = AIAudioTranscriptionPolicy.supportedModels(
                from: models
            )
            availableModels = transcriptionModels
            if let first = transcriptionModels.first,
               !transcriptionModels.contains(where: {
                   AIAudioTranscriptionPolicy.normalizedModel($0.id)
                       == AIAudioTranscriptionPolicy.normalizedModel(
                           configuration.transcriptionModel
                       )
               }) {
                configuration.transcriptionModel = first.id
            }
            status = transcriptionModels.isEmpty
                ? .modelsEmpty
                : .modelsLoaded(transcriptionModels.count)
        } catch {
            status = .failed(AISettingsEditorModel.message(
                for: error,
                configuration: configuration
            ))
        }
        isFetchingModels = false
    }

    func save(using intelligence: MusicIntelligenceService) async {
        guard canSave else { return }
        isWorking = true
        status = .idle
        do {
            try await intelligence.saveLyricsTranscriptionSettings(
                configuration: configuration,
                isEnabled: isEnabled,
                hasExplicitAudioUploadConsent: hasExplicitAudioUploadConsent,
                apiKey: apiKeyDraft.isEmpty ? nil : apiKeyDraft
            )
            configuration = intelligence.lyricsTranscriptionSettingsStore.configuration
            apiKeyDraft = ""
            hasStoredAPIKey = await intelligence.hasStoredLyricsTranscriptionAPIKey()
            status = .saved
        } catch {
            status = .failed(AISettingsEditorModel.message(
                for: error,
                configuration: configuration
            ))
        }
        isWorking = false
    }

    func deleteAPIKey(using intelligence: MusicIntelligenceService) async {
        isWorking = true
        status = .idle
        do {
            try await intelligence.deleteLyricsTranscriptionAPIKey()
            hasStoredAPIKey = false
            apiKeyDraft = ""
        } catch {
            status = .failed(AISettingsEditorModel.message(for: error))
        }
        isWorking = false
    }
}

struct GoogleLyricsTranscriptionSettingsView: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.dismiss) private var dismiss
    @State private var editor = LyricsTranscriptionSettingsEditorModel()

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
                Section {
                    LabeledContent("lyrics_transcription_provider") {
                        Text(verbatim: "Google")
                    }
                    LabeledContent("lyrics_transcription_service_address") {
                        Text(verbatim: "generativelanguage.googleapis.com")
                            .font(.caption.monospaced())
                    }
                } footer: {
                    Text("lyrics_transcription_google_footer")
                }

                Section {
                    SecureField("lyrics_transcription_api_key", text: $editor.apiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if editor.hasStoredAPIKey && editor.apiKeyDraft.isEmpty {
                        Label("ai_api_key_stored", systemImage: "checkmark.shield")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await editor.fetchModels(using: intelligence) }
                    } label: {
                        HStack {
                            Label("lyrics_transcription_fetch_models", systemImage: "arrow.triangle.2.circlepath")
                            if editor.isFetchingModels {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!editor.canFetchModels)

                    if !editor.availableModels.isEmpty {
                        Picker(
                            "lyrics_transcription_model",
                            selection: $editor.configuration.transcriptionModel
                        ) {
                            ForEach(editor.availableModels) { model in
                                Text(verbatim: model.id).tag(model.id)
                            }
                        }
                    } else if !editor.configuration.transcriptionModel.isEmpty {
                        LabeledContent("lyrics_transcription_model") {
                            Text(verbatim: editor.configuration.transcriptionModel)
                                .font(.caption.monospaced())
                        }
                    }
                } header: {
                    Text("lyrics_transcription_configuration_section")
                } footer: {
                    Text("lyrics_transcription_model_footer")
                }

                Section {
                    Toggle("lyrics_transcription_enabled", isOn: $editor.isEnabled)
                    Toggle(
                        "lyrics_transcription_audio_consent",
                        isOn: $editor.hasExplicitAudioUploadConsent
                    )
                } footer: {
                    Text("lyrics_transcription_consent_footer")
                }

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
                    .disabled(!editor.canSave)

                    if editor.hasStoredAPIKey {
                        Button("ai_delete_current_api_key", role: .destructive) {
                            Task { await editor.deleteAPIKey(using: intelligence) }
                        }
                        .disabled(editor.isWorking || editor.isFetchingModels)
                    }

                    statusView
                }
            }
        }
        .navigationTitle("lyrics_transcription_settings_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await editor.load(using: intelligence) }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 600)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("close") { dismiss() }
            }
        }
        #endif
    }

    @ViewBuilder
    private var statusView: some View {
        switch editor.status {
        case .idle:
            EmptyView()
        case .modelsLoaded(let count):
            Label(
                String(
                    format: String(localized: "lyrics_transcription_models_loaded_format"),
                    count
                ),
                systemImage: "checkmark.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .modelsEmpty:
            Label("lyrics_transcription_models_empty", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .saved:
            Label("lyrics_transcription_saved", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
