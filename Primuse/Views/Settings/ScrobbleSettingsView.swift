import SwiftUI
import SafariServices
import PrimuseKit

/// 听歌记录上报 (scrobble) 设置 — Last.fm / ListenBrainz。
/// Last.fm 走 desktop auth flow (in-app Safari + 内置 API key);
/// ListenBrainz 走用户 token 直接粘贴。
struct ScrobbleSettingsView: View {
    @State private var settings = ScrobbleSettingsStore.shared
    @State private var service = ScrobbleService.shared

    @State private var listenBrainzToken: String = ""
    @State private var listenBrainzValid: Bool? = nil  // nil=未测试, true=有效, false=无效
    @State private var isValidatingLB = false

    @State private var lastFmAPIKey: String = ""
    @State private var lastFmAPISecret: String = ""
    @State private var lastFmConnected: Bool = false
    @State private var lastFmUsername: String = ""
    @State private var isLoggingInLastFm: Bool = false
    @State private var lastFmError: String?
    @State private var showLastFmSignOutConfirm = false
    /// 「使用自己的 application」高级区是否展开。如果用户已经粘过自己的
    /// key, 默认展开让他们能看见; 否则收起 (大部分人用 app 内置 default)。
    @State private var showLastFmAdvanced = false
    /// 两步授权流程暂存的 token —— 第一步打开 Last.fm 授权页时拿到,
    /// 第二步在网页关闭/返回应用后拿这个去换 sessionKey。
    /// nil = 还没开始 / 已经完成 / 取消; non-nil = 等待用户授权确认中。
    @State private var lastFmPendingToken: String?
    @State private var lastFmAuthSession: LastFmAuthSession?

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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard lastFmPendingToken != nil,
                  !lastFmConnected,
                  !isLoggingInLastFm else { return }
            Task { await confirmLastFmAuthorization(showError: false) }
        }
        .sheet(item: $lastFmAuthSession, onDismiss: {
            guard lastFmPendingToken != nil,
                  !lastFmConnected,
                  !isLoggingInLastFm else { return }
            Task { await confirmLastFmAuthorization(showError: true) }
        }) { session in
            LastFmAuthSafariView(url: session.url)
                .ignoresSafeArea()
        }
        .alert("scrobble_lastfm_signout_confirm", isPresented: $showLastFmSignOutConfirm) {
            Button("scrobble_lastfm_signout", role: .destructive) {
                LastFmCredentialsStore.signOut()
                lastFmConnected = false
                lastFmUsername = ""
                lastFmPendingToken = nil
                NotificationCenter.default.post(name: .scrobbleSettingsChanged, object: nil)
            }
            Button("cancel", role: .cancel) {}
        }
        .alert(String(localized: "scrobble_lastfm_err_title"),
               isPresented: Binding(get: { lastFmError != nil },
                                    set: { if !$0 { lastFmError = nil } })) {
            Button("ok", role: .cancel) {}
        } message: { Text(lastFmError ?? "") }
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
                RevealableSecureField(title: "scrobble_lb_token_placeholder", text: $listenBrainzToken)
                    .textContentType(.password)
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

    // MARK: - Last.fm

    private var lastFmSection: some View {
        Section {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(.red)
                Text("Last.fm")
                    .fontWeight(.medium)
                Spacer()
                Toggle("", isOn: providerToggleBinding(.lastFm))
                    .labelsHidden()
            }

            if settings.enabledProviders.contains(.lastFm) {
                if lastFmConnected {
                    // 已登录: 显示用户名 + 登出
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(lastFmUsername.isEmpty
                             ? String(localized: "scrobble_lastfm_connected")
                             : String(format: String(localized: "scrobble_lastfm_connected_as_format"), lastFmUsername))
                            .font(.subheadline)
                        Spacer()
                    }
                    Button(role: .destructive) {
                        showLastFmSignOutConfirm = true
                    } label: {
                        Label("scrobble_lastfm_signout", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else if let token = lastFmPendingToken {
                    // Step 2: 已经打开过授权页, 等用户回来后检查授权状态。
                    HStack {
                        Image(systemName: "safari").foregroundStyle(.blue)
                        Text("scrobble_lastfm_pending_hint").font(.subheadline)
                        Spacer()
                    }
                    Button {
                        reopenLastFmAuthorization(token: token)
                    } label: {
                        Label("scrobble_lastfm_reopen_authorization", systemImage: "safari")
                    }
                    .disabled(isLoggingInLastFm)
                    Button {
                        Task { await confirmLastFmAuthorization(showError: true) }
                    } label: {
                        HStack {
                            if isLoggingInLastFm {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "checkmark.shield")
                            }
                            Text("scrobble_lastfm_confirm_authorized")
                        }
                    }
                    .disabled(isLoggingInLastFm)
                    Button("scrobble_lastfm_cancel_pending", role: .destructive) {
                        lastFmPendingToken = nil
                        LastFmCredentialsStore.savePendingAuthToken(nil)
                    }
                    .disabled(isLoggingInLastFm)
                } else {
                    // Step 1: 拿 token + 在 App 内打开 Last.fm 授权页。Last.fm
                    // 会在同一网页内处理登录, 授权后用户点 Done 回到 App。
                    Button {
                        Task { await beginLastFmAuthorization() }
                    } label: {
                        HStack {
                            if isLoggingInLastFm {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "person.badge.shield.checkmark")
                            }
                            Text("scrobble_lastfm_connect")
                        }
                    }
                    .disabled(isLoggingInLastFm
                              || (LastFmCredentialsStore.effectiveAPIKey().isEmpty)
                              || (LastFmCredentialsStore.effectiveAPISecret().isEmpty))

                    DisclosureGroup(isExpanded: $showLastFmAdvanced) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("scrobble_lastfm_advanced_hint")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            RevealableSecureField(title: "scrobble_lastfm_api_key_placeholder", text: $lastFmAPIKey)
                                .textContentType(.password)
                                .onChange(of: lastFmAPIKey) { _, newVal in
                                    LastFmCredentialsStore.saveAPIKey(newVal)
                                }
                            RevealableSecureField(title: "scrobble_lastfm_api_secret_placeholder", text: $lastFmAPISecret)
                                .textContentType(.password)
                                .onChange(of: lastFmAPISecret) { _, newVal in
                                    LastFmCredentialsStore.saveAPISecret(newVal)
                                }
                            Link(destination: URL(string: "https://www.last.fm/api/account/create")!) {
                                Label("scrobble_lastfm_register_app", systemImage: "arrow.up.right.square")
                                    .font(.caption)
                            }
                        }
                        .padding(.top, 4)
                    } label: {
                        Label("scrobble_lastfm_advanced_title", systemImage: "key")
                            .font(.subheadline)
                    }
                }
            }
        } header: {
            Text("Last.fm")
        } footer: {
            if settings.enabledProviders.contains(.lastFm), !lastFmConnected {
                Text("scrobble_lastfm_default_footer")
            }
        }
    }

    /// Step 1: 拿 token + 打开 Last.fm 授权页。完成后 token 暂存到
    /// `lastFmPendingToken`, UI 切到 Step 2 (等用户返回后检查授权状态)。
    private func beginLastFmAuthorization() async {
        isLoggingInLastFm = true
        defer { isLoggingInLastFm = false }
        do {
            let request = try await LastFmAuthService.startLogin()
            LastFmCredentialsStore.savePendingAuthToken(request.token)
            lastFmPendingToken = request.token
            lastFmAuthSession = LastFmAuthSession(token: request.token, url: request.url)
        } catch {
            lastFmError = error.localizedDescription
        }
    }

    private func reopenLastFmAuthorization(token: String) {
        do {
            let url = try LastFmAuthService.authorizationURL(token: token)
            lastFmAuthSession = LastFmAuthSession(token: token, url: url)
        } catch {
            lastFmError = error.localizedDescription
        }
    }

    /// Step 2: 用户在 Last.fm 点完 Allow 后关闭网页/回到 app, 用暂存
    /// 的 token 换 sessionKey。`showError=false` 用于 foreground 自动探测,
    /// 未授权时保持 pending, 不打扰用户。
    private func confirmLastFmAuthorization(showError: Bool) async {
        guard let token = lastFmPendingToken else { return }
        isLoggingInLastFm = true
        defer { isLoggingInLastFm = false }
        do {
            let username = try await LastFmAuthService.completeLogin(token: token)
            lastFmUsername = username
            lastFmConnected = true
            lastFmPendingToken = nil
            NotificationCenter.default.post(name: .scrobbleSettingsChanged, object: nil)
        } catch {
            if showError {
                lastFmError = error.localizedDescription
            }
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

        lastFmAPIKey = LastFmCredentialsStore.loadAPIKey()
        lastFmAPISecret = LastFmCredentialsStore.loadAPISecret()
        lastFmConnected = LastFmCredentialsStore.isConnected()
        lastFmPendingToken = lastFmConnected ? nil : LastFmCredentialsStore.loadPendingAuthToken()
        // 用户已经粘过自己的 key, 默认展开高级让他们看见; 否则收起
        showLastFmAdvanced = LastFmCredentialsStore.usingCustomKeys
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

private struct LastFmAuthSession: Identifiable {
    let token: String
    let url: URL

    var id: String { token }
}

private struct LastFmAuthSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
