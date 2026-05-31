import SwiftUI
#if os(iOS)
import SafariServices
#elseif os(macOS)
import AppKit
#endif
import PrimuseKit

/// 听歌记录上报 (scrobble) 设置 — Last.fm / ListenBrainz。
/// Last.fm 走 desktop auth flow (in-app Safari + 内置 API key);
/// ListenBrainz 走用户 token 直接粘贴。
struct ScrobbleSettingsView: View {
    @Environment(\.dismiss) private var dismiss
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
        Group {
            #if os(macOS)
            macBody
            #else
            iosBody
            #endif
        }
        .onAppear { loadStoredTokens() }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            guard lastFmPendingToken != nil,
                  !lastFmConnected,
                  !isLoggingInLastFm else { return }
            Task { await confirmLastFmAuthorization(showError: false) }
        }
        #else
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard lastFmPendingToken != nil,
                  !lastFmConnected,
                  !isLoggingInLastFm else { return }
            Task { await confirmLastFmAuthorization(showError: false) }
        }
        #endif
        .sheet(item: $lastFmAuthSession, onDismiss: {
            guard lastFmPendingToken != nil,
                  !lastFmConnected,
                  !isLoggingInLastFm else { return }
            Task { await confirmLastFmAuthorization(showError: true) }
        }) { session in
            #if os(iOS)
            LastFmAuthSafariView(url: session.url)
                .ignoresSafeArea()
            #else
            // macOS 直接走系统默认浏览器, sheet 弹一个简短提示后立即 dismiss。
            LastFmAuthOpenInBrowser(url: session.url)
            #endif
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

    private var iosBody: some View {
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
    }


    #if os(macOS)
    /// 工具弹框 —— 整面板铺满 `PMColor.bg` (浅色=米色 / 深色=炭色), 卡片用
    /// 实色 `bgElev` 抬一层, 而不是之前那种半透明白面板叠白卡 (浅色下糊成
    /// 一片白 → 设计反馈的「太白」)。结构: 顶栏 + 滚动卡片区 + 底栏。
    private var macBody: some View {
        VStack(spacing: 0) {
            macHeader

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    macMasterCard

                    if settings.isEnabled {
                        macLastFmCard
                        macListenBrainzCard
                        macRulesCard
                        macQueueCard
                        macRecentReportsCard
                    } else {
                        macDisabledState
                    }
                }
                .padding(18)
            }

            macFooter
        }
        .frame(width: 560, height: 660)
        .background(PMColor.bg)
    }

    private var macFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: service.recentReports.isEmpty ? "lock.shield" : "checkmark.seal.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(service.recentReports.isEmpty ? PMColor.textFaint : PMColor.ok)
            Text(verbatim: macFooterStatus)
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textMuted)
                .lineLimit(1)

            Spacer()

            Button("done") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(PMColor.brand, in: .rect(cornerRadius: 6))
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(PMColor.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private var macFooterStatus: String {
        let n = service.recentReports.count
        if n == 0 { return String(localized: "scrobble_mac_footer_empty") }
        return String(format: String(localized: "scrobble_mac_footer_success_format"), n)
    }

    private var macHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PMColor.brand.opacity(0.16))
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text("scrobble_mac_title")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text("scrobble_mac_subtitle")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
            }

            Spacer()

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 26, height: 26)
                    .background(PMColor.glassBtn, in: .circle)
            }
            .buttonStyle(.plain)
            .help(Text("close"))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var macMasterCard: some View {
        VStack(spacing: 0) {
            macRow(icon: "dot.radiowaves.left.and.right", title: String(localized: "scrobble_enabled"), subtitle: String(localized: "scrobble_mac_enabled_subtitle")) {
                macSwitch(isOn: $settings.isEnabled)
            }
            if settings.isEnabled {
                Divider().overlay(PMColor.divider).padding(.leading, 44)
                macRow(icon: "waveform.badge.magnifyingglass", title: String(localized: "scrobble_send_now_playing"), subtitle: String(localized: "scrobble_mac_now_playing_subtitle")) {
                    macSwitch(isOn: $settings.sendNowPlaying)
                }
            }
        }
        .background(PMColor.bgElev, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var macListenBrainzCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            macProviderHeader(
                icon: "music.note.list",
                title: "ListenBrainz",
                subtitle: listenBrainzValid == true ? String(localized: "scrobble_mac_token_saved") : String(localized: "scrobble_mac_user_token_login"),
                tint: PMColor.brand,
                isOn: providerToggleBinding(.listenBrainz)
            )

            if settings.enabledProviders.contains(.listenBrainz) {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("User token", text: $listenBrainzToken)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5, design: .monospaced))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(PMColor.bg, in: .rect(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                        }
                        .onSubmit { saveListenBrainzToken() }

                    HStack(spacing: 8) {
                        macTinyButton(String(localized: "save"), icon: "key.fill") {
                            saveListenBrainzToken()
                        }
                        macTinyButton(isValidatingLB ? String(localized: "scrobble_mac_validating") : String(localized: "scrobble_validate"), icon: "checkmark.shield") {
                            Task { await validateListenBrainz() }
                        }
                        .disabled(listenBrainzToken.isEmpty || isValidatingLB)

                        if let valid = listenBrainzValid {
                            Label(valid ? String(localized: "scrobble_token_valid") : String(localized: "scrobble_token_invalid"), systemImage: valid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(valid ? PMColor.ok : PMColor.bad)
                        }

                        Spacer()

                        Link(destination: URL(string: "https://listenbrainz.org/profile/")!) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(PMColor.textMuted)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(PMColor.bgElev, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var macLastFmCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            macProviderHeader(
                icon: "waveform",
                title: "Last.fm",
                subtitle: lastFmSubtitle,
                tint: PMColor.bad,
                isOn: providerToggleBinding(.lastFm)
            )

            if settings.enabledProviders.contains(.lastFm) {
                if lastFmConnected {
                    HStack(spacing: 8) {
                        Label(lastFmUsername.isEmpty ? String(localized: "scrobble_lastfm_connected") : String(format: String(localized: "scrobble_lastfm_connected_as_format"), lastFmUsername),
                              systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(PMColor.ok)
                        Spacer()
                        macTinyButton(String(localized: "scrobble_lastfm_signout"), icon: "rectangle.portrait.and.arrow.right", tint: PMColor.bad) {
                            showLastFmSignOutConfirm = true
                        }
                    }
                } else if let token = lastFmPendingToken {
                    HStack(spacing: 8) {
                        Text("scrobble_mac_waiting_browser_auth")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(PMColor.text)
                        Spacer()
                        macTinyButton(String(localized: "scrobble_lastfm_reopen_authorization"), icon: "safari") {
                            reopenLastFmAuthorization(token: token)
                        }
                        macTinyButton(isLoggingInLastFm ? String(localized: "scrobble_mac_confirming") : String(localized: "scrobble_mac_i_authorized"), icon: "checkmark.shield") {
                            Task { await confirmLastFmAuthorization(showError: true) }
                        }
                        .disabled(isLoggingInLastFm)
                    }
                } else {
                    HStack(spacing: 8) {
                        macTinyButton(isLoggingInLastFm ? String(localized: "scrobble_mac_connecting") : String(localized: "scrobble_lastfm_connect"), icon: "person.badge.shield.checkmark", tint: PMColor.bad) {
                            // 没有可用的 API Key/Secret 时, 不要把按钮静默禁用
                            // (plain 按钮禁用后外观不变, 用户只会觉得"点不动")。
                            // 改成点了就展开「高级密钥」引导填写, 并给一句说明。
                            if LastFmCredentialsStore.effectiveAPIKey().isEmpty
                                || LastFmCredentialsStore.effectiveAPISecret().isEmpty {
                                withAnimation { showLastFmAdvanced = true }
                                lastFmError = String(localized: "scrobble_lastfm_err_missing_creds")
                            } else {
                                Task { await beginLastFmAuthorization() }
                            }
                        }
                        .disabled(isLoggingInLastFm)

                        Spacer()

                        Link(destination: URL(string: "https://www.last.fm/api/account/create")!) {
                            Text("scrobble_mac_create_api_app")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(PMColor.textMuted)
                        }
                    }

                    DisclosureGroup(isExpanded: $showLastFmAdvanced) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("scrobble_lastfm_advanced_hint")
                                .font(.system(size: 11.5))
                                .foregroundStyle(PMColor.textFaint)
                            macSecretField("API Key", text: $lastFmAPIKey)
                                .onChange(of: lastFmAPIKey) { _, newVal in
                                    LastFmCredentialsStore.saveAPIKey(newVal)
                                }
                            macSecretField("API Secret", text: $lastFmAPISecret)
                                .onChange(of: lastFmAPISecret) { _, newVal in
                                    LastFmCredentialsStore.saveAPISecret(newVal)
                                }
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("scrobble_lastfm_advanced_title", systemImage: "key")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(PMColor.textMuted)
                    }
                }
            }
        }
        .padding(14)
        .background(PMColor.bgElev, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var macRulesCard: some View {
        VStack(spacing: 0) {
            macRow(icon: "timer", title: String(localized: "scrobble_mac_rules_title"), subtitle: String(localized: "scrobble_mac_rules_subtitle")) {
                Text("50% · 4m")
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PMColor.textMuted)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(PMColor.glassBtn, in: .capsule)
            }
        }
        .background(PMColor.bgElev, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var macQueueCard: some View {
        VStack(spacing: 0) {
            macRow(icon: "tray.full", title: String(localized: "scrobble_queue_section"), subtitle: String(localized: "scrobble_mac_queue_subtitle")) {
                HStack(spacing: 8) {
                    Text("\(service.pendingCount)")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(PMColor.textMuted)
                    if service.pendingCount > 0 {
                        macTinyButton(String(localized: "scrobble_retry_now"), icon: "arrow.clockwise") {
                            service.retryPendingNow()
                        }
                        macTinyButton(String(localized: "scrobble_clear_queue"), icon: "trash", tint: PMColor.bad) {
                            showClearQueueConfirm = true
                        }
                    }
                }
            }
        }
        .background(PMColor.bgElev, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var macRecentReportsCard: some View {
        VStack(spacing: 0) {
            macRow(icon: "clock.arrow.circlepath", title: String(localized: "scrobble_mac_recent_reports_title"), subtitle: String(localized: "scrobble_mac_recent_reports_subtitle")) {
                Text("\(service.recentReports.count)")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PMColor.textMuted)
            }

            if service.recentReports.isEmpty {
                Divider().overlay(PMColor.divider).padding(.leading, 44)
                Text("scrobble_mac_no_recent_reports")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            } else {
                ForEach(Array(service.recentReports.prefix(5))) { report in
                    Divider().overlay(PMColor.divider).padding(.leading, 44)
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: report.entry.title)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(PMColor.text)
                                .lineLimit(1)
                            Text(verbatim: "\(report.entry.artist) · \(relativeReportTime(report.submittedAt))")
                                .font(.system(size: 11))
                                .foregroundStyle(PMColor.textMuted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(verbatim: report.provider.displayName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                            .padding(.horizontal, 7)
                            .frame(height: 21)
                            .background(PMColor.brand.opacity(0.12), in: .capsule)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                }
            }
        }
        .background(PMColor.bgElev, in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var macDisabledState: some View {
        VStack(spacing: 10) {
            Image(systemName: "pause.circle")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(PMColor.textFaint)
            Text("scrobble_mac_disabled_title")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PMColor.text)
            Text("scrobble_mac_disabled_desc")
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(PMColor.bgElev.opacity(0.6), in: .rect(cornerRadius: 12))
    }

    private var lastFmSubtitle: String {
        if lastFmConnected {
            return lastFmUsername.isEmpty ? String(localized: "scrobble_mac_session_saved") : "@\(lastFmUsername)"
        }
        if lastFmPendingToken != nil { return String(localized: "scrobble_mac_waiting_authorization") }
        return String(localized: "scrobble_mac_browser_oauth")
    }

    private func macProviderHeader(icon: String,
                                   title: String,
                                   subtitle: String,
                                   tint: Color,
                                   isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.14), in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textFaint)
            }
            Spacer()
            macSwitch(isOn: isOn)
        }
    }

    private func macRow<Trailing: View>(icon: String,
                                        title: String,
                                        subtitle: String,
                                        @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(PMColor.textMuted)
                .frame(width: 32, height: 32)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(PMColor.text)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func macSwitch(isOn: Binding<Bool>) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(PMColor.brand)
    }

    private func macTinyButton(_ title: String,
                               icon: String,
                               tint: Color = PMColor.brand,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 9)
                .frame(height: 25)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func macSecretField(_ title: String, text: Binding<String>) -> some View {
        SecureField(title, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: .monospaced))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(PMColor.bg.opacity(0.72), in: .rect(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }
    }
    #endif

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

            if !service.recentReports.isEmpty {
                ForEach(Array(service.recentReports.prefix(5))) { report in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.entry.title)
                            .lineLimit(1)
                        Text("\(report.provider.displayName) · \(report.entry.artist) · \(relativeReportTime(report.submittedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
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

    private func relativeReportTime(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return String(localized: "Just now") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
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

#if os(iOS)
private struct LastFmAuthSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
#else
/// macOS 不支持 SFSafariViewController, 改用 NSWorkspace 打开默认浏览器, 然后
/// 立即 dismiss sheet。用户在浏览器里完成 OAuth 后回到 app, onDismiss 走
/// confirmLastFmAuthorization 兑换 sessionKey。
private struct LastFmAuthOpenInBrowser: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("scrobble_lastfm_signin_browser_prompt")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(width: 320, height: 160)
        .onAppear {
            NSWorkspace.shared.open(url)
            dismiss()
        }
    }
}
#endif
