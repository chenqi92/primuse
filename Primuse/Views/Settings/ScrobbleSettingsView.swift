import SwiftUI
import PrimuseKit

/// 听歌记录上报 (scrobble) 设置 — Last.fm / ListenBrainz 等。
/// v1 完整支持 ListenBrainz (用户 token 直接粘贴), Last.fm 受限 (需要
/// app 维护方注册 API key, UI 已有但未启用)。
struct ScrobbleSettingsView: View {
    @State private var settings = ScrobbleSettingsStore.shared
    @State private var service = ScrobbleService.shared

    @State private var listenBrainzToken: String = ""
    @State private var listenBrainzValid: Bool? = nil  // nil=未测试, true=有效, false=无效
    @State private var isValidatingLB = false

    @State private var showLastFmPlaceholderAlert = false
    @State private var showClearQueueConfirm = false

    var body: some View {
        Form {
            Section {
                Toggle("scrobble_enabled", isOn: $settings.isEnabled)
                if settings.isEnabled {
                    Toggle("scrobble_send_now_playing", isOn: $settings.sendNowPlaying)
                }
            } footer: {
                Text("scrobble_overall_footer")
            }

            if settings.isEnabled {
                listenBrainzSection
                lastFmSection
                queueSection
            }
        }
        .navigationTitle("scrobble_title")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { loadStoredTokens() }
        .alert("scrobble_lastfm_placeholder_title", isPresented: $showLastFmPlaceholderAlert) {
            Button("ok", role: .cancel) {}
        } message: {
            Text("scrobble_lastfm_placeholder_msg")
        }
        .confirmationDialog("scrobble_clear_queue_confirm", isPresented: $showClearQueueConfirm, titleVisibility: .visible) {
            Button("clear_all", role: .destructive) {
                service.clearQueue()
            }
            Button("cancel", role: .cancel) {}
        }
    }

    // MARK: - ListenBrainz

    private var listenBrainzSection: some View {
        Section {
            HStack {
                Image(systemName: "music.note.list")
                    .foregroundStyle(.purple)
                Text("ListenBrainz")
                    .fontWeight(.medium)
                Spacer()
                Toggle("", isOn: providerToggleBinding(.listenBrainz))
                    .labelsHidden()
            }

            if settings.enabledProviders.contains(.listenBrainz) {
                SecureField("scrobble_lb_token_placeholder", text: $listenBrainzToken)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .onSubmit { saveListenBrainzToken() }

                HStack {
                    Button {
                        Task { await validateListenBrainz() }
                    } label: {
                        if isValidatingLB {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("scrobble_validate")
                        }
                    }
                    .disabled(listenBrainzToken.isEmpty || isValidatingLB)

                    Spacer()

                    if let v = listenBrainzValid {
                        if v {
                            Label("scrobble_token_valid", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        } else {
                            Label("scrobble_token_invalid", systemImage: "xmark.circle.fill")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                Link(destination: URL(string: "https://listenbrainz.org/profile/")!) {
                    Label("scrobble_lb_get_token", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            }
        } header: {
            Text("scrobble_provider_section")
        } footer: {
            if settings.enabledProviders.contains(.listenBrainz) {
                Text("scrobble_lb_footer")
            }
        }
    }

    // MARK: - Last.fm (placeholder, 等 API key)

    private var lastFmSection: some View {
        Section {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                Text("Last.fm")
                    .fontWeight(.medium)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settings.enabledProviders.contains(.lastFm) },
                    set: { newVal in
                        if newVal {
                            // 还没有 API key, 不让真启用 — 弹一个说明 alert。
                            showLastFmPlaceholderAlert = true
                        } else {
                            settings.enabledProviders.remove(.lastFm)
                        }
                    }
                ))
                .labelsHidden()
            }
        } footer: {
            Text("scrobble_lastfm_coming_soon")
        }
    }

    // MARK: - Failed queue

    private var queueSection: some View {
        Section {
            HStack {
                Label("scrobble_pending_count", systemImage: "tray.full")
                Spacer()
                Text("\(service.pendingCount)").foregroundStyle(.secondary).monospacedDigit()
            }
            if service.pendingCount > 0 {
                Button("scrobble_retry_now") {
                    service.retryPendingNow()
                }
                Button("scrobble_clear_queue", role: .destructive) {
                    showClearQueueConfirm = true
                }
            }
        } header: {
            Text("scrobble_queue_section")
        }
    }

    // MARK: - Helpers

    private func providerToggleBinding(_ pid: ScrobbleProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.enabledProviders.contains(pid) },
            set: { newVal in
                if newVal { settings.enabledProviders.insert(pid) }
                else { settings.enabledProviders.remove(pid) }
            }
        )
    }

    private func loadStoredTokens() {
        listenBrainzToken = KeychainService.getPassword(for: ScrobbleProviderID.listenBrainz.keychainAccount) ?? ""
        // 已有 token 默认显示 valid (不强制立即触发网络验证)。
        if !listenBrainzToken.isEmpty {
            listenBrainzValid = true
        }
    }

    private func saveListenBrainzToken() {
        let trimmed = listenBrainzToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainService.deletePassword(for: ScrobbleProviderID.listenBrainz.keychainAccount)
            listenBrainzValid = nil
        } else {
            KeychainService.setPassword(trimmed, for: ScrobbleProviderID.listenBrainz.keychainAccount)
        }
    }

    private func validateListenBrainz() async {
        let trimmed = listenBrainzToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isValidatingLB = true
        defer { isValidatingLB = false }
        // 先存 (validate 用的就是 Keychain 内的 token via provider factory),
        // 失败也保留让用户改。
        KeychainService.setPassword(trimmed, for: ScrobbleProviderID.listenBrainz.keychainAccount)
        let provider = ListenBrainzProvider(userToken: trimmed)
        let result = await provider.validateCredentials()
        listenBrainzValid = result
    }
}
