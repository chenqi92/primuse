import PrimuseKit
import SwiftUI
import UniformTypeIdentifiers

/// 歌词设置页里「罗马音」一组：显示方式、自动生成、生成哪些语言、生成方式。
struct LyricsRomanizationSettingsSection: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    @State private var settings = LyricsRomanizationSettingsStore.shared
    @State private var googleAccount = GoogleCloudRomanizationAccount.shared

    var body: some View {
        Section {
            Picker(selection: $settings.displayMode) {
                ForEach(LyricRomanizationDisplayMode.allCases, id: \.self) { mode in
                    Text(verbatim: mode.localizedTitle).tag(mode)
                }
            } label: {
                SettingsInfoLabel("lyrics_romanization_display") {
                    Text("lyrics_romanization_display_footer")
                }
            }
            .settingsAnchor("lyrics.romanizationDisplay")

            Toggle(isOn: $settings.isAutoGenerationEnabled.animation()) {
                SettingsInfoLabel("lyrics_romanization_auto_generate") {
                    Text("lyrics_romanization_auto_generate_footer")
                }
            }
            .settingsAnchor("lyrics.romanizationAutoGenerate")

            if settings.isAutoGenerationEnabled {
                NavigationLink {
                    LyricsRomanizationLanguagesView()
                } label: {
                    LabeledContent {
                        Text(verbatim: settings.enabledLanguagesSummary)
                            .lineLimit(1)
                    } label: {
                        Text("lyrics_romanization_languages")
                    }
                }
                .settingsAnchor("lyrics.romanizationLanguages")

                Picker(selection: displayedMethod) {
                    ForEach(offeredMethods, id: \.self) { method in
                        Text(verbatim: method.localizedTitle).tag(method)
                    }
                } label: {
                    SettingsInfoLabel("lyrics_romanization_method") {
                        Text("lyrics_romanization_method_footer")
                    }
                }
                .settingsAnchor("lyrics.romanizationMethod")

                switch displayedMethod.wrappedValue {
                case .intelligent:
                    LyricsAIRomanizationReadinessRow()
                case .googleCloud:
                    NavigationLink {
                        LyricsRomanizationGoogleSettingsView()
                    } label: {
                        LabeledContent {
                            Text(verbatim: googleAccount.summary?.clientEmail
                                 ?? String(localized: "lyrics_romanization_google_not_configured"))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } label: {
                            Text("lyrics_romanization_google_title")
                        }
                    }
                    .settingsAnchor("lyrics.romanizationGoogle")
                    if let lastError = googleAccount.lastError {
                        Label(lastError, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .local:
                    EmptyView()
                }
            }
        } header: {
            Text("lyrics_romanization_section")
        } footer: {
            Text("lyrics_romanization_display_only_footer")
        }
    }

    private var offeredMethods: [LyricRomanizationMethod] {
        LyricRomanizationMethod.offeredMethods(
            region: intelligence.regionAvailability.context.region,
            exposesIntelligentServices: intelligence.shouldExposeRemoteConfiguration
        )
    }

    /// 这个地区不提供的方式按本机显示（存下的选择不动，换了地区还在）。
    private var displayedMethod: Binding<LyricRomanizationMethod> {
        Binding(
            get: {
                LyricRomanizationMethodPolicy.effectiveMethod(
                    settings.method,
                    region: intelligence.regionAvailability.context.region,
                    exposesIntelligentServices: intelligence.shouldExposeRemoteConfiguration
                )
            },
            set: { settings.method = $0 }
        )
    }
}

/// 「生成这些语言」：四组语言各自开关。没改过的跟随系统语言（系统里有的语言默认不生成）。
struct LyricsRomanizationLanguagesView: View {
    @State private var settings = LyricsRomanizationSettingsStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(LyricRomanizationLanguage.allCases, id: \.self) { language in
                    Toggle(isOn: Binding(
                        get: { settings.isLanguageEnabled(language) },
                        set: { settings.setLanguage(language, enabled: $0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: language.localizedTitle)
                            if let detail = language.localizedDetail {
                                Text(verbatim: detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } footer: {
                Text("lyrics_romanization_languages_footer")
            }
        }
        .navigationTitle("lyrics_romanization_languages")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

/// 选了智能功能生成罗马音、它却发不出去时：说清楚差哪一步，就地给出解决办法；内置 AI 暂不支持时
/// 说明已经改用本机生成。
struct LyricsAIRomanizationReadinessRow: View {
    @Environment(MusicIntelligenceService.self) private var intelligence
    /// 已经在智能功能页里时不再给「前往智能功能」。
    var linksToIntelligenceSettings = true
    @State private var consentRequest: BuiltInAIConsentRequest?

    var body: some View {
        let readiness = intelligence.lyricsAIRomanizationReadiness
        if readiness != .ready, readiness != .regionUnavailable {
            VStack(alignment: .leading, spacing: 8) {
                Label(readiness.romanizationExplanation, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text("lyrics_romanization_ai_uses_local_meanwhile")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                fixButton(for: readiness)
                    .font(.footnote.weight(.semibold))
            }
            .padding(.vertical, 2)
            .builtInAIConsentSheet($consentRequest)
        } else if intelligence.lyricsRomanizationFellBackFromBuiltIn {
            Label("lyrics_romanization_ai_builtin_unsupported", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func fixButton(for readiness: LyricsAITranslationReadiness) -> some View {
        switch readiness {
        case .needsBuiltInConsent:
            Button("ai_consent_pending_action") {
                consentRequest = BuiltInAIConsentRequest()
            }
        case .needsRemoteConsent:
            Button("lyrics_translation_ai_allow_sending") {
                try? intelligence.grantRemoteConsent()
            }
        case .noService where linksToIntelligenceSettings:
            Button("ai_settings_title") {
                SettingsNavigation.shared.open(SettingsPage.intelligence.id)
            }
        case .noService, .ready, .regionUnavailable:
            EmptyView()
        }
    }
}

/// Google Cloud 生成罗马音：导入服务账号密钥（文件或粘贴），只显示服务账号与项目，可移除、可用当前歌曲测试。
struct LyricsRomanizationGoogleSettingsView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var account = GoogleCloudRomanizationAccount.shared
    @State private var showsImporter = false
    @State private var showsPasteEditor = false
    @State private var pastedJSON = ""
    @State private var importMessage: String?
    @State private var showsRemoveConfirmation = false
    @State private var isTesting = false
    @State private var testOutcome: GoogleCloudRomanizationAccount.TestOutcome?

    var body: some View {
        Form {
            Section {
                if let summary = account.summary {
                    LabeledContent("lyrics_romanization_google_service_account") {
                        Text(verbatim: summary.clientEmail)
                            .font(.callout)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    LabeledContent("lyrics_romanization_google_project") {
                        Text(verbatim: summary.projectID)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    }
                } else {
                    Text("lyrics_romanization_google_not_configured_detail")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("lyrics_romanization_google_key_section")
            } footer: {
                Text("lyrics_romanization_google_key_footer")
            }

            Section {
                Button {
                    showsImporter = true
                } label: {
                    Label("lyrics_romanization_google_import_file", systemImage: "doc.badge.plus")
                }
                Button {
                    pastedJSON = ""
                    showsPasteEditor = true
                } label: {
                    Label("lyrics_romanization_google_paste", systemImage: "doc.on.clipboard")
                }
                if let importMessage {
                    Label(importMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            if account.summary != nil {
                Section {
                    Button {
                        runTest()
                    } label: {
                        HStack {
                            Label("lyrics_romanization_google_test", systemImage: "play.circle")
                            if isTesting {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isTesting)
                    testResultView
                    if let lastError = account.lastError, testOutcome == nil {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("lyrics_romanization_google_last_error")
                                .font(.footnote.weight(.semibold))
                            Text(verbatim: lastError)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            if let date = account.lastErrorDate {
                                Text(date, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("lyrics_romanization_google_test_footer")
                }

                Section {
                    Button("lyrics_romanization_google_remove", role: .destructive) {
                        showsRemoveConfirmation = true
                    }
                    .confirmationDialog(
                        "lyrics_romanization_google_remove_confirm",
                        isPresented: $showsRemoveConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("lyrics_romanization_google_remove", role: .destructive) {
                            account.remove()
                            testOutcome = nil
                        }
                        Button("cancel", role: .cancel) {}
                    }
                }
            }
        }
        .navigationTitle("lyrics_romanization_google_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                importMessage = String(localized: "lyrics_romanization_google_import_not_service_account")
                return
            }
            importKey(data)
        }
        .sheet(isPresented: $showsPasteEditor) {
            pasteEditor
        }
        .onAppear { account.reload() }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("close") { dismiss() }
            }
        }
        #endif
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testOutcome {
        case .success(let samples):
            VStack(alignment: .leading, spacing: 6) {
                Label("lyrics_romanization_google_test_success", systemImage: "checkmark.circle.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.green)
                ForEach(samples) { sample in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: sample.original)
                            .font(.footnote)
                        Text(verbatim: sample.romanized)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    private var pasteEditor: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $pastedJSON)
                        .font(.caption.monospaced())
                        .frame(minHeight: 220)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } footer: {
                    Text("lyrics_romanization_google_paste_footer")
                }
            }
            .navigationTitle("lyrics_romanization_google_paste")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { showsPasteEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") {
                        showsPasteEditor = false
                        importKey(Data(pastedJSON.utf8))
                        pastedJSON = ""
                    }
                    .disabled(pastedJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 360)
        #endif
    }

    private func importKey(_ data: Data) {
        do {
            try account.importKey(data)
            importMessage = nil
            testOutcome = nil
        } catch let error as GoogleCloudRomanizationAccount.ImportError {
            importMessage = GoogleCloudRomanizationAccount.message(for: error)
        } catch {
            importMessage = String(localized: "lyrics_romanization_google_import_not_service_account")
        }
    }

    private func runTest() {
        isTesting = true
        testOutcome = nil
        Task {
            var lines: [LyricLine] = []
            if let songID = player.currentSong?.id {
                lines = await MetadataAssetStore.shared.cachedLyrics(forSongID: songID) ?? []
            }
            testOutcome = await account.test(lines: lines)
            isTesting = false
        }
    }
}
