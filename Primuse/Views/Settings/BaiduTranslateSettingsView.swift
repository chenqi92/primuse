import PrimuseKit
import SwiftUI

/// 百度翻译的 APP ID 与密钥(#320)。智能功能 › 服务里的「百度翻译」和歌词设置里点进来的页面都是这几个区块。
struct BaiduTranslateSettingsSections: View {
    @State private var account = BaiduTranslateAccount.shared
    @State private var translation = LyricsTranslationSettingsStore.shared
    @State private var appIDDraft = ""
    @State private var secretKeyDraft = ""
    @State private var saveFailed = false
    @State private var isTesting = false
    @State private var testOutcome: BaiduTranslateAccount.TestOutcome?
    @State private var showsRemoveConfirmation = false

    private static let developerConsoleURL = URL(string: "https://fanyi-api.baidu.com/manage/developer")!

    var body: some View {
        Section {
            header
                .settingsAnchor("intelligence.baiduTranslate")
            if translation.mode != .baidu || !translation.isEnabled {
                Button("baidu_translate_use_for_lyrics") {
                    translation.isEnabled = true
                    translation.mode = .baidu
                }
            }
        }

        Section {
            TextField("baidu_translate_app_id", text: $appIDDraft, prompt: Text(account.maskedAppID ?? "20240101000000000"))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                #endif
                .settingsAnchor("lyrics.baiduTranslateAppID")
            SecureField(
                "baidu_translate_secret_key",
                text: $secretKeyDraft,
                prompt: Text(account.isConfigured ? "baidu_translate_secret_key_saved" : "baidu_translate_secret_key_prompt")
            )
            Button("baidu_translate_save") {
                saveFailed = !account.save(appID: appIDDraft, secretKey: secretKeyDraft)
                if !saveFailed {
                    appIDDraft = ""
                    secretKeyDraft = ""
                    testOutcome = nil
                }
            }
            .disabled(!canSave)
            if saveFailed {
                Label("baidu_translate_save_failed", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("baidu_translate_credentials_section")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("baidu_translate_credentials_footer")
                Link(destination: Self.developerConsoleURL) {
                    Text(verbatim: "fanyi-api.baidu.com")
                }
            }
        }

        if account.isConfigured {
            Section {
                Button {
                    runTest()
                } label: {
                    HStack {
                        Text("baidu_translate_test")
                        if isTesting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isTesting)
                testResult
                if let lastError = account.lastError, testOutcome == nil {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: lastError)
                            if let date = account.lastErrorDate {
                                Text(date, format: .relative(presentation: .named))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
                Button("baidu_translate_remove", role: .destructive) {
                    showsRemoveConfirmation = true
                }
                .confirmationDialog(
                    "baidu_translate_remove_confirm",
                    isPresented: $showsRemoveConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("baidu_translate_remove", role: .destructive) {
                        account.remove()
                        testOutcome = nil
                    }
                    Button("cancel", role: .cancel) {}
                }
            } footer: {
                Text("baidu_translate_privacy_footer")
            }
        } else {
            Section {
            } footer: {
                Text("baidu_translate_privacy_footer")
            }
        }
    }

    private var canSave: Bool {
        !appIDDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secretKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "character.bubble")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 38, height: 38)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("baidu_translate_title")
                    .font(.headline)
                if let masked = account.maskedAppID {
                    Text(String(format: String(localized: "baidu_translate_status_ready_format"), masked))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Text("baidu_translate_status_needs_setup")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(translation.mode == .baidu ? Color.orange : Color.secondary)
                }
                Text(translation.mode == .baidu && translation.isEnabled
                     ? "baidu_translate_usage_lyrics"
                     : "baidu_translate_usage_unused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var testResult: some View {
        switch testOutcome {
        case .success(let samples):
            ForEach(samples) { sample in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: sample.original)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(verbatim: sample.translated)
                }
            }
            Label("baidu_translate_test_success", systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        case nil:
            EmptyView()
        }
    }

    private func runTest() {
        isTesting = true
        testOutcome = nil
        Task {
            testOutcome = await account.test(lines: [], targetLanguageCode: translation.targetLanguageCode)
            isTesting = false
        }
    }
}

/// 歌词设置里点「百度翻译」进来的一页。
struct BaiduTranslateSettingsView: View {
    var body: some View {
        Form {
            BaiduTranslateSettingsSections()
        }
        .navigationTitle("baidu_translate_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(macOS)
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 480)
        #endif
        .onAppear { BaiduTranslateAccount.shared.reload() }
    }
}

/// 翻译方式选了百度翻译时，放在方式下面的一行：填没填好，点进去设置。
struct BaiduTranslateStatusRow: View {
    @State private var account = BaiduTranslateAccount.shared

    var body: some View {
        NavigationLink {
            BaiduTranslateSettingsView()
        } label: {
            LabeledContent {
                Text(account.isConfigured ? "baidu_translate_status_ready" : "baidu_translate_status_needs_setup")
                    .font(.caption)
                    .foregroundStyle(account.isConfigured ? Color.secondary : Color.orange)
            } label: {
                Label("baidu_translate_title", systemImage: "character.bubble")
            }
        }
        .settingsAnchor("lyrics.baiduTranslate")
    }
}
