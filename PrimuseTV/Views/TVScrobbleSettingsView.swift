#if os(tvOS)
import PrimuseKit
import SwiftUI

/// Apple TV 上的听歌记录(Last.fm / ListenBrainz),和 iPhone、Mac 共用同一套上报服务。
///
/// 电视没有浏览器:Last.fm 显示授权页的二维码,手机扫了在网页上点「允许」,电视隔几秒问一次,
/// 拿到会话就连上。ListenBrainz 的令牌用遥控器或 iPhone 键盘填。两边的账号也能随「扫码直传」
/// 从手机带过来;开不开上报始终在电视上自己决定(电视常是一家人共用)。
struct TVScrobbleSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ScrobbleSettingsStore.shared
    @State private var service = ScrobbleService.shared

    @State private var lastFmConnected = LastFmCredentialsStore.isConnected()
    @State private var lastFmUsername = ""
    @State private var lastFmLogin: LastFmLogin = .idle
    @State private var lastFmTask: Task<Void, Never>?
    @State private var showsSignOutConfirm = false

    @State private var listenBrainzToken = ""
    @State private var listenBrainzStatus: TokenStatus?
    @State private var isValidatingListenBrainz = false
    @State private var showsClearQueueConfirm = false
    @State private var errorMessage: String?

    private enum LastFmLogin: Equatable {
        case idle
        case starting
        case waiting(URL)
        case failed(String)
    }

    private enum TokenStatus {
        case valid, invalid, unconfirmed
    }

    /// Last.fm 的授权 token 一小时内有效,留点余量。
    private static let lastFmTokenLifetime: TimeInterval = 55 * 60
    private static let lastFmPollInterval: Duration = .seconds(3)
    private static let listenBrainzTokenPage = "https://listenbrainz.org/settings/"

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    panel {
                        TVSwitchRow(
                            icon: "dot.radiowaves.left.and.right",
                            title: String(localized: "scrobble_enabled"),
                            isOn: $settings.isEnabled,
                            maxWidth: .infinity
                        )
                        .accessibilityIdentifier("tv.scrobble.enabled")
                        if settings.isEnabled {
                            divider
                            TVSwitchRow(
                                icon: "waveform.badge.magnifyingglass",
                                title: String(localized: "scrobble_send_now_playing"),
                                isOn: $settings.sendNowPlaying,
                                maxWidth: .infinity
                            )
                        }
                    }
                    if settings.isEnabled {
                        lastFmPanel
                        listenBrainzPanel
                        if service.pendingCount > 0 {
                            queuePanel
                        }
                    }
                    Label(String(localized: "tv_scrobble_transfer_hint"), systemImage: "qrcode.viewfinder")
                        .tvFont(.meta)
                        .foregroundStyle(TVColor.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 1400, alignment: .leading)
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(TVColor.text)
        .onAppear(perform: load)
        .onDisappear { lastFmTask?.cancel() }
        .onExitCommand { dismiss() }
        .confirmationDialog(
            String(localized: "scrobble_lastfm_signout_confirm"),
            isPresented: $showsSignOutConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "scrobble_lastfm_signout"), role: .destructive, action: signOutLastFm)
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .confirmationDialog(
            String(localized: "scrobble_clear_queue_confirm"),
            isPresented: $showsClearQueueConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "clear_all"), role: .destructive) { service.clearQueue() }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .alert(
            String(localized: "credential_save_failed_title"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(String(localized: "ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "scrobble_title")).tvFont(.pageTitle)
            Text(String(localized: "scrobble_overall_footer"))
                .tvFont(.caption)
                .foregroundStyle(TVColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Last.fm

    private var lastFmPanel: some View {
        panel {
            TVSwitchRow(icon: "waveform", title: ScrobbleProviderID.lastFm.displayName,
                        isOn: providerBinding(.lastFm), maxWidth: .infinity)
                .accessibilityIdentifier("tv.scrobble.lastFm")
            if settings.enabledProviders.contains(.lastFm) {
                divider
                lastFmContent
                    .padding(.horizontal, 22)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var lastFmContent: some View {
        if lastFmConnected {
            HStack(spacing: 24) {
                let rejected = service.hasRejectedCredential(for: .lastFm)
                Label(lastFmStatusText(rejected: rejected),
                      systemImage: rejected ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .tvFont(.caption, weight: .medium)
                    .foregroundStyle(rejected ? TVColor.bad : TVColor.ok)
                Spacer(minLength: 0)
                TVPillButton(title: String(localized: "scrobble_lastfm_signout"),
                             systemImage: "rectangle.portrait.and.arrow.right") {
                    showsSignOutConfirm = true
                }
            }
        } else {
            switch lastFmLogin {
            case .idle, .failed:
                VStack(alignment: .leading, spacing: 14) {
                    TVPillButton(title: String(localized: "scrobble_lastfm_connect"),
                                 systemImage: "person.badge.shield.checkmark",
                                 style: .solid,
                                 action: connectLastFm)
                        .accessibilityIdentifier("tv.scrobble.lastFm.connect")
                    if case .failed(let message) = lastFmLogin {
                        Text(message)
                            .tvFont(.meta)
                            .foregroundStyle(TVColor.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .starting:
                ProgressView().tint(TVColor.brand)
            case .waiting(let url):
                HStack(alignment: .center, spacing: 40) {
                    TVQRCode(content: url.absoluteString, size: 260)
                    VStack(alignment: .leading, spacing: 18) {
                        Text(String(localized: "tv_scrobble_lastfm_scan_hint"))
                            .tvFont(.body)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            ProgressView().tint(TVColor.brand)
                            Text(String(localized: "tv_scrobble_lastfm_waiting"))
                                .tvFont(.meta)
                                .foregroundStyle(TVColor.textFaint)
                        }
                        TVPillButton(title: String(localized: "cancel"), systemImage: "xmark", action: cancelLastFmLogin)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func lastFmStatusText(rejected: Bool) -> String {
        if rejected { return String(localized: "error_scrobble_invalid_credentials") }
        return lastFmUsername.isEmpty
            ? String(localized: "scrobble_lastfm_connected")
            : String(format: String(localized: "scrobble_lastfm_connected_as_format"), lastFmUsername)
    }

    private func connectLastFm() {
        lastFmTask?.cancel()
        lastFmLogin = .starting
        lastFmTask = Task { @MainActor in
            do {
                let request = try await LastFmAuthService.startLogin()
                guard !Task.isCancelled else { return }
                LastFmCredentialsStore.savePendingAuthToken(request.token)
                lastFmLogin = .waiting(request.url)
                await waitForLastFmAuthorization(token: request.token)
            } catch {
                guard !Task.isCancelled else { return }
                lastFmLogin = .failed(error.localizedDescription)
            }
        }
    }

    /// 手机上点「允许」之前换会话会被拒,隔几秒再问一次;过了有效期就请用户重新生成二维码。
    private func waitForLastFmAuthorization(token: String) async {
        let deadline = Date().addingTimeInterval(Self.lastFmTokenLifetime)
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(for: Self.lastFmPollInterval)
            guard !Task.isCancelled else { return }
            do {
                let username = try await LastFmAuthService.completeLogin(token: token)
                guard !Task.isCancelled else { return }
                didConnectLastFm(username: username)
                return
            } catch LastFmAuthError.credentialPersistenceFailed {
                lastFmLogin = .failed(String(localized: "credential_save_failed_message"))
                return
            } catch {
                continue
            }
        }
        guard !Task.isCancelled else { return }
        LastFmCredentialsStore.savePendingAuthToken(nil)
        lastFmLogin = .failed(String(localized: "tv_scrobble_lastfm_expired"))
    }

    private func didConnectLastFm(username: String) {
        lastFmUsername = username
        lastFmConnected = true
        lastFmLogin = .idle
        NotificationCenter.default.post(name: .scrobbleSettingsChanged, object: nil)
        service.retryPendingNow()
    }

    private func cancelLastFmLogin() {
        lastFmTask?.cancel()
        lastFmTask = nil
        LastFmCredentialsStore.savePendingAuthToken(nil)
        lastFmLogin = .idle
    }

    private func signOutLastFm() {
        guard LastFmCredentialsStore.signOut() else {
            errorMessage = String(localized: "credential_save_failed_message")
            return
        }
        lastFmConnected = false
        lastFmUsername = ""
        lastFmLogin = .idle
        NotificationCenter.default.post(name: .scrobbleSettingsChanged, object: nil)
    }

    // MARK: ListenBrainz

    private var listenBrainzPanel: some View {
        panel {
            TVSwitchRow(icon: "music.note.list", title: ScrobbleProviderID.listenBrainz.displayName,
                        isOn: providerBinding(.listenBrainz), maxWidth: .infinity)
                .accessibilityIdentifier("tv.scrobble.listenBrainz")
            if settings.enabledProviders.contains(.listenBrainz) {
                divider
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 16) {
                        TVTextFieldBox {
                            SecureField(String(localized: "scrobble_lb_token_placeholder"), text: $listenBrainzToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .onSubmit(saveListenBrainzToken)
                        }
                        HStack(spacing: 18) {
                            TVPillButton(title: String(localized: "save"), systemImage: "key.fill",
                                         action: saveListenBrainzToken)
                            TVPillButton(
                                title: isValidatingListenBrainz
                                    ? String(localized: "scrobble_mac_validating")
                                    : String(localized: "scrobble_validate"),
                                systemImage: "checkmark.shield"
                            ) {
                                Task { await validateListenBrainz() }
                            }
                            .disabled(listenBrainzToken.isEmpty || isValidatingListenBrainz)
                            if let listenBrainzStatus {
                                listenBrainzStatusLabel(listenBrainzStatus)
                            }
                        }
                        Text(String(localized: "tv_scrobble_listenbrainz_hint"))
                            .tvFont(.meta)
                            .foregroundStyle(TVColor.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    TVQRCode(content: Self.listenBrainzTokenPage, size: 180)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
            }
        }
    }

    private func listenBrainzStatusLabel(_ status: TokenStatus) -> some View {
        let (key, symbol, color): (String, String, Color) = switch status {
        case .valid: ("scrobble_token_valid", "checkmark.circle.fill", TVColor.ok)
        case .invalid: ("scrobble_token_invalid", "xmark.circle.fill", TVColor.bad)
        case .unconfirmed: ("scrobble_token_unconfirmed", "exclamationmark.circle.fill", TVColor.textMuted)
        }
        return Label(String(localized: String.LocalizationValue(key)), systemImage: symbol)
            .tvFont(.meta, weight: .medium)
            .foregroundStyle(color)
    }

    private func saveListenBrainzToken() {
        let account = ScrobbleProviderID.listenBrainz.keychainAccount
        let trimmed = listenBrainzToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard KeychainService.deletePassword(for: account) else {
                errorMessage = String(localized: "credential_save_failed_message")
                return
            }
            listenBrainzStatus = nil
        } else {
            guard KeychainService.setPassword(trimmed, for: account) else {
                errorMessage = String(localized: "credential_save_failed_message")
                return
            }
            // 换了令牌:被拒期间攒着的记录马上用新令牌补报。
            listenBrainzStatus = service.hasRejectedCredential(for: .listenBrainz) ? .invalid : .valid
            service.retryPendingNow()
        }
    }

    private func validateListenBrainz() async {
        let trimmed = listenBrainzToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isValidatingListenBrainz = true
        defer { isValidatingListenBrainz = false }
        guard KeychainService.setPassword(trimmed, for: ScrobbleProviderID.listenBrainz.keychainAccount) else {
            errorMessage = String(localized: "credential_save_failed_message")
            return
        }
        let result = await ListenBrainzProvider(userToken: trimmed).validateCredentials()
        switch result {
        case true?: listenBrainzStatus = .valid
        case false?: listenBrainzStatus = .invalid
        case nil: listenBrainzStatus = .unconfirmed
        }
        if let result { service.noteCredentialValidation(for: .listenBrainz, isValid: result) }
    }

    // MARK: Queue

    private var queuePanel: some View {
        panel {
            HStack(spacing: 22) {
                Image(systemName: "tray.full")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(TVColor.textFaint)
                    .frame(width: 34)
                Text(String(localized: "scrobble_pending_count")).tvFont(.caption, weight: .medium)
                Text("\(service.pendingCount)")
                    .tvFont(.caption, design: .monospaced)
                    .foregroundStyle(TVColor.textMuted)
                Spacer(minLength: 0)
                TVPillButton(title: String(localized: "scrobble_retry_now"), systemImage: "arrow.clockwise") {
                    service.retryPendingNow()
                }
                TVPillButton(title: String(localized: "scrobble_clear_queue"), systemImage: "trash") {
                    showsClearQueueConfirm = true
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
    }

    // MARK: Helpers

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .tvPanel(radius: 20)
            .focusSection()
    }

    private var divider: some View {
        Rectangle().fill(TVColor.divider).frame(height: 1).padding(.leading, 72)
    }

    private func providerBinding(_ provider: ScrobbleProviderID) -> Binding<Bool> {
        Binding(
            get: { settings.enabledProviders.contains(provider) },
            set: { enabled in
                if enabled { settings.enabledProviders.insert(provider) } else { settings.enabledProviders.remove(provider) }
            }
        )
    }

    private func load() {
        #if DEBUG
        // 截图:TV_SCROBBLE_DEBUG=lastFmQR 直接停在等手机授权那一步(演示地址,不会连上)。
        if ProcessInfo.processInfo.environment["TV_SCROBBLE_DEBUG"] == "lastFmQR",
           let url = URL(string: "https://www.last.fm/api/auth/?api_key=demo&token=demo") {
            lastFmLogin = .waiting(url)
        }
        #endif
        listenBrainzToken = KeychainService.getPassword(for: ScrobbleProviderID.listenBrainz.keychainAccount) ?? ""
        if !listenBrainzToken.isEmpty {
            listenBrainzStatus = service.hasRejectedCredential(for: .listenBrainz) ? .invalid : .valid
        }
        lastFmConnected = LastFmCredentialsStore.isConnected()
        // 上次停在等授权时离开了这一页:手机上可能已经点过「允许」,问一次,没成就当作没开始。
        if !lastFmConnected, let token = LastFmCredentialsStore.loadPendingAuthToken() {
            lastFmTask = Task { @MainActor in
                if let username = try? await LastFmAuthService.completeLogin(token: token) {
                    didConnectLastFm(username: username)
                } else {
                    LastFmCredentialsStore.savePendingAuthToken(nil)
                }
            }
        }
    }
}

extension TVScrobbleSettingsView {
    /// 设置页那一行右边写的:关着写「上报已关闭」,开着写选了哪几个服务。
    @MainActor
    static var summary: String {
        let settings = ScrobbleSettingsStore.shared
        guard settings.isEnabled else { return String(localized: "scrobble_mac_disabled_title") }
        let names = ScrobbleProviderID.allCases
            .filter { settings.enabledProviders.contains($0) }
            .map(\.displayName)
        return names.isEmpty ? String(localized: "tv_scrobble_summary_no_service") : names.joined(separator: " · ")
    }
}
#endif
