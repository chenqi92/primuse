import SwiftUI
import PrimuseKit
#if os(macOS)
import AppKit
#endif

// MARK: - Focus Fields

enum SourceFormField: Hashable {
    case name, host, port, publicHost, publicPort, vendorIdentifier
    case basePath, publicBasePath, shareName, exportPath, username, password, sshKey
}

enum AddSourceSubmitIntent {
    case save
    case continueToConnection
}

// MARK: - Add / Edit Source View
// Simple form — just fill info and save. Connecting & browsing happens from SourcesView.

struct AddSourceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeService.self) private var theme
    @Environment(SourceManager.self) private var sourceManager
    let sourceType: MusicSourceType
    var editingSource: MusicSource?
    var prefillDevice: DiscoveredDevice?
    var submitIntent: AddSourceSubmitIntent = .save
    var onValidatedMediaServerSave: ((MusicSource) throws -> Void)? = nil
    /// 上次没填完、进程又被系统结束的那张表，打开时原样填回。
    var restoredDraft: AddSourceDraftRestoration.Pending? = nil
    var onSave: (MusicSource) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var useSsl = false
    @State private var publicHost = ""
    @State private var publicPort = ""
    @State private var publicUseSsl = true
    @State private var localPathPrefix = ""
    @State private var publicBasePath = ""
    @State private var vendorIdentifier = ""
    @State private var synologyConnectionMode: SynologyConnectionMode = .quickConnect
    @State private var fnMusicConnectionMode: FnMusicConnectionMode = .fnConnect
    @State private var username = ""
    @State private var password = ""
    @State private var fnConnectAccessCode = ""
    @State private var basePath = ""
    @State private var shareName = ""
    @State private var exportPath = ""
    @State private var authType: SourceAuthType = .password
    @State private var sshKey = ""
    @State private var ftpEncryption: FTPEncryption = .none
    @State private var nfsVersion: NFSVersion = .auto
    @State private var autoConnect = false
    @State private var rememberDevice = false
    @State private var isInitialized = false
    /// 编辑已有源时钥匙串里到底有没有存过密钥。初始化时读一次就够 ——
    /// 这个答案在表单打开期间不会变,而 `canSave` 是被 body 反复求值的。
    @State private var editingSourceHasStoredSecret = false
    @State private var showCredentialSaveError = false
    @State private var credentialValidationSource: MusicSource?
    @State private var validatedCredentialSource: MusicSource?
    @State private var mediaServerCreationTransaction = MediaServerSourceCreationTransaction()
    /// Plex 账号登录：选中服务器后填进下面三项再走原来的保存路径。
    @State private var plexSignIn = PlexAccountSignInModel()
    @State private var plexServerIdentifier: String?
    @State private var plexAccountToken = ""
    /// 按库选「音乐 / 有声 / 不同步」(Jellyfin / Emby / Plex 这类按库组织的服务器,
    /// 编辑已有源时才有连接器能列出库)。
    @State private var serverLibraries: [ServerLibraryDescriptor] = []
    @State private var serverLibraryChoices: [String: ServerLibraryChoice] = [:]
    @State private var serverLibrariesLoad: ServerLibrariesLoadState = .idle
    /// id 寻址、没有目录可标的源:整个来源都是有声内容。
    @State private var wholeSourceSpokenWord = false
    /// 用户填的那一到两行地址。上面那组 host/port/useSsl/publicHost/… 仍然是
    /// 保存路径唯一读取的字段 —— 提交时由 `applyAddressPlan` 一次性写回。
    @State private var addressRows: [SourceAddressRow] = [SourceAddressRow()]
    /// 打开编辑页时回显出来的那一份。地址、手填端口、手选协议都没动过就不探测:
    /// 离线改个名字、换个密码不该因为服务器此刻不在线而失败。
    @State private var addressBaseline: [SourceAddressFormPolicy.AddressDraft]?
    @State private var addressProbe = SourceAddressProbeController()
    @State private var addressSubmitTask: Task<Void, Never>?
    #if os(macOS)
    /// Captures the URL chosen via NSOpenPanel so we can persist a
    /// security-scoped bookmark once the source has an ID.
    @State private var pendingLocalFolderURL: URL?
    #endif
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    /// 表单刚打开时的样子。退到后台时只有和它不一样才值得存一份草稿。
    @State private var draftBaseline: AddSourceDraftBaseline?
    #endif

    @FocusState private var focusedField: SourceFormField?

    private var isEditing: Bool { editingSource != nil }
    private var requiresAuthenticatedMediaServerPreflight: Bool {
        MediaServerSourceCreationPolicy.requiresPreflight(
            for: sourceType,
            isEditing: isEditing
        )
    }
    private var continuesToConnectionAfterSave: Bool {
        !isEditing
            && submitIntent == .continueToConnection
            && sourceType.continuesToConnectionAfterCreation
    }
    private var submitButtonTitle: LocalizedStringKey {
        continuesToConnectionAfterSave ? "Next" : "save"
    }
    private var supportsAPIKeyAuth: Bool { [.jellyfin, .emby, .plex, .audiobookshelf].contains(sourceType) }
    private var showsServerLibrarySection: Bool {
        isEditing && sourceType.organizesCatalogByServerLibrary
    }
    private var showsWholeSourceSpokenWordToggle: Bool {
        sourceType.supportsWholeSourceSpokenWordTag
    }
    private var supportsAdaptiveConnections: Bool { sourceType.supportsAdaptiveConnections }
    private var supportsSSLToggle: Bool {
        ![MusicSourceType.smb, .ftp, .sftp, .nfs].contains(sourceType)
    }
    private var validatedPort: Int? {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...65_535).contains(value) else { return nil }
        return value
    }
    private var validatedPublicPort: Int? {
        let trimmed = publicPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...65_535).contains(value) else { return nil }
        return value
    }
    private var remoteUsesVendor: Bool {
        if sourceType.usesSynologyConnectionMode { return synologyConnectionMode == .quickConnect }
        if sourceType == .fnMusic { return fnMusicConnectionMode == .fnConnect }
        return false
    }

    /// 地址框读出来的结果。纯函数、不发请求,所以每次 body 求值重算一遍也不贵。
    private var addressReading: SourceAddressFormPolicy.FormReading {
        SourceAddressFormPolicy.read(addressRows.map(\.draft), sourceType: sourceType)
    }

    /// 至少有一条能用的地址,而且没有哪一行写坏了(含高级选项里的端口)。
    private var addressFormIsValid: Bool {
        addressReading.isSubmittable
            && addressRows.contains(where: \.hasInvalidManualPort) == false
    }

    /// 这个源当前是不是走厂商中转。地址框里填了 QuickConnect ID / FN ID 就是。
    private var usesVendorRemoteAccess: Bool {
        supportsAdaptiveConnections
            ? addressReading.placement.usesVendorRemoteAccess
            : remoteUsesVendor
    }

    /// 钥匙串里有没有这个源的密钥。**不要在 body 里直接查钥匙串** ——
    /// `SecItemCopyMatching` 是一次同步的 securityd 往返(读不到时还要查两遍,
    /// 并且不进内存缓存),而这个判断被 `canSave` 带进每一次界面更新里:
    /// 编辑页上敲一个字、动一下焦点就要敲好几次钥匙串。
    private func storedSecretExists(for source: MusicSource) -> Bool {
        guard isInitialized else { return Self.readStoredSecretExists(for: source.id) }
        return editingSourceHasStoredSecret
    }

    private static func readStoredSecretExists(for sourceID: String) -> Bool {
        switch KeychainService.passwordLookup(for: sourceID) {
        case .found(let secret):
            return secret.isEmpty == false
        case .notFound:
            return false
        case .temporarilyUnavailable, .failed:
            // Preserve an existing edit without forcing the user to
            // overwrite a credential that is merely unreadable right now.
            return true
        }
    }

    private var canSave: Bool {
        if sourceType.requiresHost {
            if supportsAdaptiveConnections {
                guard addressFormIsValid else { return false }
            } else {
                let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedHost.isEmpty else { return false }
                if sourceType == .synology, synologyConnectionMode == .quickConnect {
                    guard SynologyQuickConnectResolver.isValidQuickConnectID(trimmedHost) else { return false }
                } else if sourceType == .fnMusic, fnMusicConnectionMode == .fnConnect {
                    guard FnConnectResolver.isValidFNID(trimmedHost) else { return false }
                } else if validatedPort == nil {
                    return false
                }
            }
        }

        guard sourceType.requiresCredentials else {
            return true
        }

        let hasStoredSecret: Bool
        if let editingSource, editingSource.authType == authType {
            hasStoredSecret = storedSecretExists(for: editingSource)
        } else {
            hasStoredSecret = false
        }

        switch authType {
        case .sshKey:
            return sshKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || hasStoredSecret
        case .password:
            guard username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return false
            }
            // Jellyfin and Emby both support named users with an empty
            // password. Requiring a Keychain value here made those perfectly
            // valid accounts impossible to save.
            if sourceType == .jellyfin || sourceType == .emby {
                return true
            }
            return password.isEmpty == false || hasStoredSecret
        case .apiKey, .cookie, .oauth:
            return password.isEmpty == false || hasStoredSecret
        case .none:
            return sourceType.supportsAnonymous
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            iOSBody
            #else
            macOSBody
            #endif
        }
        // 自适应连接的表单里已经没有 SSL 开关了 —— 协议跟着地址走。这两条
        // 跟随规则只服务于老的单地址表单;留着会在写回探测结果时把刚定下来的
        // 端口当成"上一个默认值"改掉。
        .onChange(of: useSsl) { oldValue, newValue in
            guard !supportsAdaptiveConnections else { return }
            updateDefaultPortForSSLChange(
                port: $port,
                from: oldValue,
                to: newValue
            )
        }
        .onChange(of: publicUseSsl) { oldValue, newValue in
            guard !supportsAdaptiveConnections else { return }
            updateDefaultPortForSSLChange(
                port: $publicPort,
                from: oldValue,
                to: newValue
            )
        }
        // 地址一改,正在跑的那一轮探测和它的结论就都作废 —— 留着会让用户以为
        // 新地址也试过了,而那一轮拿回来的端点对应的已经是旧输入。只盯真正影响
        // "连到哪里"的那几项,展开高级选项不该清空失败清单。
        .onChange(of: addressProbeSignature) { _, _ in
            cancelAddressProbe()
        }
        .onChange(of: synologyConnectionMode) { _, newValue in
            guard !supportsAdaptiveConnections,
                  sourceType == .synology,
                  newValue == .quickConnect else { return }
            useSsl = true
            port = String(MusicSourceType.synology.defaultPort(useSsl: true))
        }
        .onChange(of: fnMusicConnectionMode) { _, newValue in
            guard !supportsAdaptiveConnections,
                  sourceType == .fnMusic,
                  newValue == .fnConnect else { return }
            useSsl = true
        }
        .alert(String(localized: "credential_save_failed_title"), isPresented: $showCredentialSaveError) {
            Button("ok", role: .cancel) {}
        } message: {
            Text("credential_save_failed_message")
        }
        .sheet(item: $credentialValidationSource, onDismiss: finishCredentialValidation) { source in
            SynologyCredentialRecoveryView(source: source, initialPassword: password) { updated in
                validatedCredentialSource = updated
            }
        }
        .alert(
            mediaServerCreationTransaction.failure?.title ?? String(localized: "connection_failed"),
            isPresented: Binding(
                get: { mediaServerCreationTransaction.failure != nil },
                set: { isPresented in
                    if !isPresented { mediaServerCreationTransaction.clearFailure() }
                }
            )
        ) {
            Button("ok", role: .cancel) {
                mediaServerCreationTransaction.clearFailure()
            }
        } message: {
            Text(mediaServerCreationTransaction.failure?.message ?? "")
        }
        .onDisappear {
            addressSubmitTask?.cancel()
            addressSubmitTask = nil
            plexSignIn.cancel()
            if requiresAuthenticatedMediaServerPreflight {
                mediaServerCreationTransaction.cancel()
            }
            #if os(iOS)
            // 表单是真的关掉了(保存、取消、下滑关闭、换成选目录那一步)。
            // 进程被结束不会走到这里, 草稿正是留给那种情况的。
            AddSourceDraftStore.clear()
            #endif
        }
        #if os(iOS)
        // 切去别的 App 复制地址或密码时存一份: 挂起的进程随时可能被系统结束。
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            persistDraftIfNeeded()
        }
        #endif
    }

    private var addressProbeSignature: String {
        addressRows.map(\.draft.probeSignature).joined(separator: "\n")
    }

    /// Follow HTTP's 80/443 defaults only while the field still contains the
    /// previous automatic value. A user-entered custom port (for example
    /// MinIO's 9000 or WebDAV 8443) must never be overwritten by the toggle.
    private func updateDefaultPortForSSLChange(
        port: Binding<String>,
        from oldValue: Bool,
        to newValue: Bool
    ) {
        let oldDefault = sourceType.defaultPort(useSsl: oldValue)
        let newDefault = sourceType.defaultPort(useSsl: newValue)
        guard oldDefault != newDefault else { return }
        let trimmed = port.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == String(oldDefault) else { return }
        port.wrappedValue = String(newDefault)
    }

    private var connectionHostLabel: LocalizedStringKey {
        if sourceType == .synology {
            switch synologyConnectionMode {
            case .quickConnect: return "synology_quickconnect_id"
            case .address: return "synology_address"
            }
        }
        if sourceType == .fnMusic, fnMusicConnectionMode == .fnConnect {
            return "fnmusic_fnid"
        }
        return "host_address"
    }

    @ViewBuilder
    private var synologyConnectionModeOptions: some View {
        Text("synology_connection_quickconnect").tag(SynologyConnectionMode.quickConnect)
        Text("synology_connection_address").tag(SynologyConnectionMode.address)
    }

    private var synologyConnectionModePicker: some View {
        Picker("", selection: $synologyConnectionMode) {
            synologyConnectionModeOptions
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder
    private var fnMusicConnectionModeOptions: some View {
        Text("fnmusic_connection_fnconnect").tag(FnMusicConnectionMode.fnConnect)
        Text("fnmusic_connection_address").tag(FnMusicConnectionMode.address)
    }

    private var fnMusicConnectionModePicker: some View {
        Picker("", selection: $fnMusicConnectionMode) {
            fnMusicConnectionModeOptions
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    #if os(iOS)
    private var iOSBody: some View {
        NavigationStack {
            Form { formSections }
            .scrollDismissesKeyboard(.interactively)
            .floatingInputPanelClearance()
            .navigationTitle(isEditing ? String(localized: "edit_source") : sourceType.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { cancelAndDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitButtonTitle) { submit() }
                        .disabled(isSubmitDisabled)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { initializeFields() }
            .task { await loadServerLibrariesIfNeeded() }
        }
    }
    #else
    private var macOSBody: some View {
        VStack(spacing: 0) {
            macSheetChrome

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    macFormContent
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .padding(.bottom, 80)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("cancel") { cancelAndDismiss() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(PMColor.cardBorder, lineWidth: 0.5) }

                Button(submitButtonTitle) { submit() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSubmitDisabled)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background((canSave ? theme.uiAccentColor : PMColor.textFaint), in: .rect(cornerRadius: 6))
                    .pmAnimation(.hover, value: canSave)
            }
            .padding(.horizontal, 24)
            .frame(height: 64)
            .background(PMColor.bg)
            .overlay(alignment: .top) {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
            }
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 500, idealHeight: 660)
        .background(PMColor.bg.ignoresSafeArea())
        .foregroundStyle(PMColor.text)
        .tint(theme.uiAccentColor)
        .onAppear { initializeFields() }
        .task { await loadServerLibrariesIfNeeded() }
    }

    private var macSheetChrome: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? String(localized: "edit_source") : sourceType.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(isEditing ? String(localized: "edit_connection_info") : sourceType.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
            }
            Spacer()
        }
        .frame(height: 56)
        .padding(.horizontal, 18)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var macFormContent: some View {
        if sourceType == .plex {
            macSection("plex_account_section") {
                PlexAccountSignInPanel(
                    model: plexSignIn,
                    style: .card,
                    isLinked: plexServerIdentifier != nil,
                    onPick: applyPlexServer
                )
                macInfoRow(PlexAccountSignInPanel.footerKey(
                    model: plexSignIn,
                    isLinked: plexServerIdentifier != nil
                ))
            }
        }

        macSection("source_info") {
            macTextRow("source_name", text: $name, focus: .name)
        }

        if sourceType.requiresHost {
            if supportsAdaptiveConnections {
                macAdaptiveConnectionSections
            } else {
                macSection("connection_info") {
                    if sourceType == .synology {
                        macCustomRow("synology_connection_method") {
                            synologyConnectionModePicker
                                .frame(maxWidth: 320)
                        }
                        macTextRow(connectionHostLabel, text: $host, focus: .host)
                        if synologyConnectionMode == .quickConnect {
                            macInfoRow("synology_quickconnect_hint")
                        } else {
                            macTextRow("port", text: $port, focus: .port, width: 120)
                            macToggleRow("use_ssl", isOn: $useSsl)
                        }
                    } else if sourceType == .fnMusic {
                        macCustomRow("fnmusic_connection_method") {
                            fnMusicConnectionModePicker
                                .frame(maxWidth: 320)
                        }
                        macTextRow(connectionHostLabel, text: $host, focus: .host)
                        if fnMusicConnectionMode == .fnConnect {
                            macInfoRow("fnmusic_fnconnect_hint")
                        } else {
                            macTextRow("port", text: $port, focus: .port, width: 120)
                            macToggleRow("use_ssl", isOn: $useSsl)
                        }
                    } else {
                        macTextRow("host_address", text: $host, focus: .host)
                        macTextRow("port", text: $port, focus: .port, width: 120)
                        if supportsSSLToggle {
                            macToggleRow("use_ssl", isOn: $useSsl)
                        }
                    }
                }
            }
        }

        macTypeSpecificSections

        if sourceType.requiresCredentials {
            macSection("credentials") {
                if sourceType == .sftp || supportsAPIKeyAuth || sourceType.supportsAnonymous {
                    macCustomRow("auth_method") {
                        Picker("", selection: $authType) {
                            Text("password").tag(SourceAuthType.password)
                            if sourceType.supportsAnonymous {
                                Text("guest_access").tag(SourceAuthType.none)
                            } else if supportsAPIKeyAuth {
                                Text("api_key").tag(SourceAuthType.apiKey)
                            } else {
                                Text("ssh_key").tag(SourceAuthType.sshKey)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 260, alignment: .trailing)
                    }
                }

                if authType != .apiKey && authType != .none {
                    macTextRow("username", text: $username, focus: .username)
                }

                if authType == .none {
                    macInfoRow("anonymous_login_hint")
                } else if authType == .sshKey && sourceType == .sftp {
                    macCustomBlock("ssh_key") {
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $sshKey)
                                .focused($focusedField, equals: .sshKey)
                                .frame(minHeight: 88)
                                .font(.system(.caption, design: .monospaced))
                                .scrollContentBackground(.hidden)
                            if sshKey.isEmpty {
                                Text("ssh_key_placeholder")
                                    .foregroundStyle(PMColor.textFaint)
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .padding(8)
                        .background(PMColor.rowHover, in: .rect(cornerRadius: 8))
                    }
                } else {
                    macCustomRow(authType == .apiKey ? "api_key" : "password") {
                        RevealableSecureField(title: authType == .apiKey ? "api_key" : "password", text: $password)
                            .focused($focusedField, equals: .password)
                            .frame(maxWidth: 280)
                    }
                }

                if sourceType == .fnMusic {
                    macInfoRow("fnmusic_account_hint")
                    // 访问码只在地址被认成 FN ID 时才有意义 —— 不再靠分段选择器。
                    if usesVendorRemoteAccess {
                        macCustomRow("fnmusic_access_code") {
                            RevealableSecureField(
                                title: "fnmusic_access_code",
                                text: $fnConnectAccessCode
                            )
                            .frame(maxWidth: 280)
                        }
                        macInfoRow("fnmusic_access_code_hint")
                    }
                }

                if isEditing && authType != .none {
                    macInfoRow("password_edit_hint")
                }
            }
        }

        if showsServerLibrarySection {
            macSection("server_libraries_section") {
                macServerLibraryRows
                macInfoRow("server_libraries_footer")
            }
        }

        macSection("advanced") {
            if sourceType.isServerLibrary
                && !sourceType.supportsEndpointSpecificPath
                && !(sourceType == .fnMusic && usesVendorRemoteAccess) {
                macTextRow(
                    sourceType == .fnMusic
                        ? "fnmusic_server_base_path_hint"
                        : "server_base_path_hint",
                    text: $basePath,
                    focus: .basePath
                )
            }
            macToggleRow("auto_connect", isOn: $autoConnect)
            if sourceType.supports2FA {
                macToggleRow("remember_device", isOn: $rememberDevice)
            }
            if showsWholeSourceSpokenWordToggle {
                macToggleRow("whole_source_spoken_word", isOn: $wholeSourceSpokenWord)
                macInfoRow("whole_source_spoken_word_hint")
            }
        }

        if !isEditing && sourceType.requiresHost && !continuesToConnectionAfterSave {
            macSection(nil) {
                Label(
                    sourceType.scansEntireLibrary
                        ? "save_then_scan_library_hint"
                        : "save_then_connect_hint",
                    systemImage: "info.circle"
                )
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    @ViewBuilder
    private var macTypeSpecificSections: some View {
        switch sourceType {
        case .smb:
            macSection("smb_config") {
                macTextRow("share_name", text: $shareName, focus: .shareName)
            }
        case .webdav:
            if !supportsAdaptiveConnections {
                macSection("webdav_config") {
                    macTextRow("base_path_hint", text: $basePath, focus: .basePath)
                }
            }
        case .jellyfin, .emby, .plex, .subsonic, .navidrome, .airsonic, .gonic:
            EmptyView()
        case .ftp:
            macSection("ftp_config") {
                macCustomRow("encryption") {
                    Picker("", selection: $ftpEncryption) {
                        ForEach(FTPEncryption.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                macTextRow("initial_path", text: $basePath, focus: .basePath)
            }
        case .sftp:
            macSection("sftp_config") {
                macTextRow("initial_path", text: $basePath, focus: .basePath)
            }
        case .local:
            macSection("local_folder") {
                HStack(spacing: 12) {
                    Text(basePath.isEmpty ? String(localized: "no_folder_selected") : basePath)
                        .font(.system(size: 12.5))
                        .foregroundStyle(basePath.isEmpty ? PMColor.textFaint : PMColor.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("choose_folder") { pickLocalFolder() }
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        case .appleMusicLibrary:
            macSection(nil) {
                Label("apple_music_library_hint", systemImage: "music.note.house")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        case .nfs:
            macSection("nfs_config") {
                macTextRow("export_path", text: $exportPath, focus: .exportPath)
                macCustomRow("nfs_version") {
                    Picker("", selection: $nfsVersion) {
                        ForEach(NFSVersion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
        case .s3:
            macSection("S3") {
                macTextRow("s3_region", text: $basePath)
                macTextRow("s3_bucket", text: $shareName, focus: .shareName)
                macTextRow("s3_access_key", text: $username, focus: .username)
                macCustomRow("s3_secret_key") {
                    RevealableSecureField(title: "s3_secret_key", text: $password)
                        .focused($focusedField, equals: .password)
                        .frame(maxWidth: 280)
                }
            }
        case .drime:
            macSection("drime_token_section") {
                macCustomRow("drime_access_token") {
                    RevealableSecureField(title: "drime_access_token", text: $password)
                        .focused($focusedField, equals: .password)
                        .frame(maxWidth: 280)
                }
                macInfoRow(isEditing ? "drime_token_edit_hint" : "drime_token_hint")
                macInfoRow("drime_token_permission_hint")
            }
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .pan115, .pan123, .guangya:
            if !BuiltInCloudCredentials.hasBuiltIn(for: sourceType) {
                macSection("cloud_oauth_config") {
                    macTextRow("cloud_client_id_or_app_key", text: $username, focus: .username)
                    macCustomRow("cloud_client_secret") {
                        RevealableSecureField(title: "cloud_client_secret_optional", text: $password)
                            .focused($focusedField, equals: .password)
                            .frame(maxWidth: 280)
                    }
                    macInfoRow("cloud_oauth_hint")
                }
            }
        default:
            EmptyView()
        }
    }

    /// 与 iOS 同一套内容、同一份判断,换成 Mac 表单的卡片行。
    @ViewBuilder
    private var macAdaptiveConnectionSections: some View {
        let reading = addressReading
        macSection("source_address_section") {
            ForEach($addressRows) { $row in
                MacSourceAddressRowView(
                    row: $row,
                    reading: addressRowReading(reading, for: row.id),
                    sourceType: sourceType,
                    attempts: addressProbe.attempts[row.id] ?? [],
                    canRemove: addressRows.count > 1,
                    onRemove: { removeAddressRow(row.id) }
                )
            }
            macAddressActionRow
            if let note = unconfirmedServiceNote {
                macInfoText(note)
            }
            macInfoRow("source_address_section_footer")
        }
    }

    private var macAddressActionRow: some View {
        HStack(spacing: 10) {
            if addressRows.count < SourceAddressFormPolicy.maximumAddressCount {
                Button("source_address_add_alternate") { addAddressRow() }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
            }
            Spacer(minLength: 12)
            macAddressProgress
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var macAddressProgress: some View {
        if addressProbe.isProbing {
            ProgressView().controlSize(.small)
                .pmAppearFade(.contentAppear)
            Text("source_address_probing")
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textFaint)
                .pmAppearFade(.contentAppear)
            Button("cancel") { cancelAddressProbe() }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
                .pmAppearFade(.contentAppear)
        } else if addressProbe.phase == .unresolved {
            Button("source_address_probe_save_anyway") { saveWithoutProbing() }
                .buttonStyle(.link)
                .font(.system(size: 11.5))
                .pmAppearFade(.contentAppear)
        }
    }

    /// 与 `macInfoRow` 同样的外观,但内容是运行时算出来的字符串而不是文案键。
    private func macInfoText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(PMColor.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .top) {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
            }
    }

    private func macSection<Content: View>(_ title: LocalizedStringKey?,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(PMColor.textFaint)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pmCard(cornerRadius: 10, overOpaqueBackground: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func macTextRow(_ title: LocalizedStringKey,
                            text: Binding<String>,
                            focus: SourceFormField? = nil,
                            width: CGFloat? = nil) -> some View {
        macCustomRow(title) {
            TextField("", text: text)
                .focused($focusedField, equals: focus)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .multilineTextAlignment(.trailing)
                .frame(width: width)
        }
    }

    private func macToggleRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        macCustomRow(title) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func macInfoRow(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11.5))
            .foregroundStyle(PMColor.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .top) {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
            }
    }

    private func macCustomRow<Content: View>(_ title: LocalizedStringKey,
                                             @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 14) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(PMColor.text)
            Spacer(minLength: 20)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private func macCustomBlock<Content: View>(_ title: LocalizedStringKey,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(PMColor.text)
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }
    @ViewBuilder
    private var macServerLibraryRows: some View {
        switch serverLibrariesLoad {
        case .idle, .loading:
            macInfoRow("server_libraries_loading")
        case .failed:
            macInfoRow("server_libraries_unavailable")
        case .loaded:
            if serverLibraries.isEmpty {
                macInfoRow("server_libraries_empty")
            } else {
                ForEach(serverLibraries) { library in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: library.name)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(PMColor.text)
                            Text(serverLibraryKindCaption(library.kind))
                                .font(.system(size: 11))
                                .foregroundStyle(PMColor.textFaint)
                        }
                        Spacer(minLength: 20)
                        serverLibraryChoicePicker(library.id)
                            .fixedSize()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .overlay(alignment: .top) {
                        Rectangle().fill(PMColor.divider).frame(height: 0.5)
                    }
                }
            }
        }
    }
    #endif

    // MARK: - Server libraries (音乐 / 有声 / 不同步)

    @ViewBuilder
    private var serverLibraryRows: some View {
        switch serverLibrariesLoad {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("server_libraries_loading")
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Text("server_libraries_unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .loaded:
            if serverLibraries.isEmpty {
                Text("server_libraries_empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(serverLibraries) { library in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: library.name)
                            Text(serverLibraryKindCaption(library.kind))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        serverLibraryChoicePicker(library.id)
                            .fixedSize()
                    }
                }
            }
        }
    }

    private func serverLibraryChoicePicker(_ libraryID: String) -> some View {
        Picker("", selection: serverLibraryChoiceBinding(libraryID)) {
            // 有声书服务器里没有音乐库,只剩「同步成有声 / 不同步」两种。
            if sourceType.declaredListeningContentKind == nil {
                Text("library_kind_music").tag(ServerLibraryChoice.music)
            }
            Text("library_kind_spoken_word").tag(ServerLibraryChoice.spokenWord)
            Text("library_kind_excluded").tag(ServerLibraryChoice.excluded)
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }

    private func serverLibraryChoiceBinding(_ libraryID: String) -> Binding<ServerLibraryChoice> {
        Binding(
            get: { serverLibraryChoices[libraryID] ?? .music },
            set: { serverLibraryChoices[libraryID] = $0 }
        )
    }

    private func serverLibraryKindCaption(_ kind: ServerLibraryContentKind) -> LocalizedStringKey {
        switch kind {
        case .music: return "library_kind_caption_music"
        case .mixed: return "library_kind_caption_mixed"
        case .audiobooks: return "library_kind_caption_audiobooks"
        case .podcasts: return "library_kind_caption_podcasts"
        case .other: return "library_kind_caption_other"
        }
    }

    /// 编辑已有源时问服务器有哪些库,再按已存的标签和排除项填好每一行的选择。
    private func loadServerLibrariesIfNeeded() async {
        guard showsServerLibrarySection, let editingSource, serverLibrariesLoad == .idle else { return }
        serverLibrariesLoad = .loading
        do {
            let libraries = try await sourceManager.fetchServerLibraries(for: editingSource)
            let store = SpokenWordStore.shared
            let excluded = Set(editingSource.excludedServerLibraryIDs)
            var choices: [String: ServerLibraryChoice] = [:]
            for library in libraries {
                if excluded.contains(library.id) {
                    choices[library.id] = .excluded
                } else if Self.libraryIsSpokenWord(library, sourceID: editingSource.id, store: store) {
                    choices[library.id] = .spokenWord
                } else {
                    choices[library.id] = .music
                }
            }
            serverLibraries = libraries
            serverLibraryChoices = choices
            serverLibrariesLoad = .loaded
        } catch {
            plog("⚠️ Server libraries could not be listed source=\(editingSource.id.prefix(8))… \(error.localizedDescription)")
            serverLibrariesLoad = .failed
        }
    }

    /// 已标成有声,或服务端说是有声书库而用户还没定过(第一次见到就按有声算)。
    private static func libraryIsSpokenWord(
        _ library: ServerLibraryDescriptor,
        sourceID: String,
        store: SpokenWordStore
    ) -> Bool {
        store.isSpokenWordLibrary(sourceID: sourceID, libraryID: library.id)
            || (library.defaultsToSpokenWord
                && !store.hasSpokenWordLibraryDecision(sourceID: sourceID, libraryID: library.id))
    }

    /// 保存时落标签:整源开关直接写;按库的选择只在列表真的加载过时写,没加载到就保持原样。
    private func applySpokenWordChoices(sourceID: String) {
        let store = SpokenWordStore.shared
        if showsWholeSourceSpokenWordToggle {
            store.setWholeSourceSpokenWord(wholeSourceSpokenWord, sourceID: sourceID)
        }
        // 源类型已经声明了内容种类(有声书服务器),库标签没有意义;只有排除项要存。
        guard serverLibrariesLoad == .loaded, sourceType.declaredListeningContentKind == nil else { return }
        for library in serverLibraries {
            switch serverLibraryChoices[library.id] ?? .music {
            case .spokenWord:
                store.setSpokenWordLibrary(true, sourceID: sourceID, libraryID: library.id)
            case .music:
                // 只在它现在算有声时才写一条显式的「音乐」,免得给每个音乐库都留一条记录。
                if Self.libraryIsSpokenWord(library, sourceID: sourceID, store: store) {
                    store.setSpokenWordLibrary(false, sourceID: sourceID, libraryID: library.id)
                }
            case .excluded:
                break
            }
        }
    }

    /// Form body extracted so iOS / macOS chrome can share it.
    @ViewBuilder
    private var formSections: some View {
        if sourceType == .plex {
            Section {
                PlexAccountSignInPanel(
                    model: plexSignIn,
                    style: .form,
                    isLinked: plexServerIdentifier != nil,
                    onPick: applyPlexServer
                )
            } header: {
                Text("plex_account_section")
            } footer: {
                Text(PlexAccountSignInPanel.footerKey(
                    model: plexSignIn,
                    isLinked: plexServerIdentifier != nil
                ))
            }
        }

        Section("source_info") {
            TextField("source_name", text: $name)
                .focused($focusedField, equals: .name)
                .submitLabel(.next)
                .onSubmit { focusedField = sourceType.requiresHost ? .host : .username }
        }

        if sourceType.requiresHost {
            if supportsAdaptiveConnections {
                adaptiveConnectionFormSections
            } else {
                Section("connection_info") {
                    if sourceType == .synology {
                        Picker("synology_connection_method", selection: $synologyConnectionMode) {
                            synologyConnectionModeOptions
                        }
                        .pickerStyle(.segmented)
                    }
                    if sourceType == .fnMusic {
                        Picker("fnmusic_connection_method", selection: $fnMusicConnectionMode) {
                            fnMusicConnectionModeOptions
                        }
                        .pickerStyle(.segmented)
                    }
                    TextField(connectionHostLabel, text: $host)
                        .focused($focusedField, equals: .host)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.next)
                        .onSubmit {
                            focusedField = (sourceType == .synology && synologyConnectionMode == .quickConnect)
                                || (sourceType == .fnMusic && fnMusicConnectionMode == .fnConnect)
                                ? .username
                                : .port
                        }
                    if sourceType == .synology, synologyConnectionMode == .quickConnect {
                        Text("synology_quickconnect_hint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if sourceType == .fnMusic, fnMusicConnectionMode == .fnConnect {
                        Text("fnmusic_fnconnect_hint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("port", text: $port)
                            .focused($focusedField, equals: .port)
                            .keyboardType(.numberPad)
                        if supportsSSLToggle {
                            Toggle("use_ssl", isOn: $useSsl)
                        }
                    }
                }
            }
        }

        typeSpecificSection

        if sourceType.requiresCredentials {
            Section("credentials") {
                if sourceType == .sftp || supportsAPIKeyAuth || sourceType.supportsAnonymous {
                    Picker("auth_method", selection: $authType) {
                        Text("password").tag(SourceAuthType.password)
                        if sourceType.supportsAnonymous {
                            Text("guest_access").tag(SourceAuthType.none)
                        } else if supportsAPIKeyAuth {
                            Text("api_key").tag(SourceAuthType.apiKey)
                        } else {
                            Text("ssh_key").tag(SourceAuthType.sshKey)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                if authType != .apiKey && authType != .none {
                    TextField("username", text: $username)
                        .focused($focusedField, equals: .username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                }
                if authType == .none {
                    Text("anonymous_login_hint").font(.caption).foregroundStyle(.secondary)
                } else if authType == .sshKey && sourceType == .sftp {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $sshKey)
                            .focused($focusedField, equals: .sshKey)
                            .frame(minHeight: 80)
                            .font(.system(.caption, design: .monospaced))
                        if sshKey.isEmpty {
                            Text("ssh_key_placeholder")
                                .foregroundStyle(.tertiary)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                } else {
                    RevealableSecureField(title: authType == .apiKey ? "api_key" : "password", text: $password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                }
                if sourceType == .audiobookshelf {
                    Text("audiobookshelf_credentials_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if sourceType == .fnMusic {
                    Text("fnmusic_account_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // 访问码只在地址被认成 FN ID 时才有意义 —— 不再靠分段选择器。
                    if usesVendorRemoteAccess {
                        RevealableSecureField(
                            title: "fnmusic_access_code",
                            text: $fnConnectAccessCode
                        )
                        Text("fnmusic_access_code_hint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if isEditing && authType != .none {
                    Text("password_edit_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        if showsServerLibrarySection {
            Section {
                serverLibraryRows
            } header: {
                Text("server_libraries_section")
            } footer: {
                Text("server_libraries_footer")
            }
        }

        Section("advanced") {
            if sourceType.isServerLibrary
                && !sourceType.supportsEndpointSpecificPath
                && !(sourceType == .fnMusic && usesVendorRemoteAccess) {
                TextField(
                    sourceType == .fnMusic
                        ? "fnmusic_server_base_path_hint"
                        : "server_base_path_hint",
                    text: $basePath
                )
                    .focused($focusedField, equals: .basePath)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Toggle("auto_connect", isOn: $autoConnect)
            if sourceType.supports2FA {
                Toggle("remember_device", isOn: $rememberDevice)
            }
            if showsWholeSourceSpokenWordToggle {
                Toggle("whole_source_spoken_word", isOn: $wholeSourceSpokenWord)
                Text("whole_source_spoken_word_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if !isEditing && sourceType.requiresHost && !continuesToConnectionAfterSave {
            Section {
                Label(
                    sourceType.scansEntireLibrary
                        ? "save_then_scan_library_hint"
                        : "save_then_connect_hint",
                    systemImage: "info.circle"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 一个地址框,下面一行实时解读。内网 / 公网不再是两个常驻区块 —— 地址归
    /// 哪个位置由 `SourceAddressFormPolicy` 判断,用户只要把地址贴进来。
    @ViewBuilder
    private var adaptiveConnectionFormSections: some View {
        let reading = addressReading
        ForEach($addressRows) { $row in
            Section {
                SourceAddressRowView(
                    row: $row,
                    reading: addressRowReading(reading, for: row.id),
                    sourceType: sourceType,
                    attempts: addressProbe.attempts[row.id] ?? [],
                    canRemove: addressRows.count > 1,
                    onRemove: { removeAddressRow(row.id) }
                )
            } header: {
                // 分成两个分支而不是三元:`Text(条件 ? "a" : "b")` 会被推断成
                // `Text(String)`,那个初始化器不做本地化。
                if addressRows.first?.id == row.id {
                    Text("source_address_section")
                } else {
                    Text("source_address_alternate_section")
                }
            }
        }

        Section {
            addressActionRows
        } footer: {
            Text("source_address_section_footer")
        }
    }

    @ViewBuilder
    private var addressActionRows: some View {
        if addressRows.count < SourceAddressFormPolicy.maximumAddressCount {
            Button("source_address_add_alternate") { addAddressRow() }
        }
        if addressProbe.isProbing {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("source_address_probing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("cancel") { cancelAddressProbe() }
                    .buttonStyle(.borderless)
            }
            .pmFadeTransition(motion: .contentAppear)
        }
        if addressProbe.phase == .unresolved {
            Button("source_address_probe_save_anyway") { saveWithoutProbing() }
                .pmFadeTransition(motion: .contentAppear)
        }
        if let note = unconfirmedServiceNote {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .pmFadeTransition(motion: .contentAppear)
        }
    }

    // MARK: - Type-specific

    @ViewBuilder
    private var typeSpecificSection: some View {
        switch sourceType {
        case .smb:
            Section("smb_config") {
                TextField("share_name", text: $shareName)
                    .focused($focusedField, equals: .shareName)
                    .autocorrectionDisabled().submitLabel(.next)
                    .onSubmit { focusedField = .username }
            }
        case .webdav:
            if !supportsAdaptiveConnections {
                Section("webdav_config") {
                    TextField("base_path_hint", text: $basePath)
                        .focused($focusedField, equals: .basePath)
                        .autocorrectionDisabled().submitLabel(.next)
                        .onSubmit { focusedField = .username }
                }
            }
        case .jellyfin, .emby, .plex, .subsonic, .navidrome, .airsonic, .gonic:
            EmptyView()
        case .ftp:
            Section("ftp_config") {
                Picker("encryption", selection: $ftpEncryption) {
                    ForEach(FTPEncryption.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("initial_path", text: $basePath)
                    .focused($focusedField, equals: .basePath)
                    .autocorrectionDisabled().submitLabel(.next)
                    .onSubmit { focusedField = .username }
            }
        case .sftp:
            Section("sftp_config") {
                TextField("initial_path", text: $basePath)
                    .focused($focusedField, equals: .basePath)
                    .autocorrectionDisabled().submitLabel(.next)
                    .onSubmit { focusedField = .username }
            }
        case .local:
            #if os(macOS)
            Section("local_folder") {
                HStack {
                    Text(basePath.isEmpty ? String(localized: "no_folder_selected") : basePath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(basePath.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("choose_folder") { pickLocalFolder() }
                }
            }
            #else
            EmptyView()
            #endif
        case .appleMusicLibrary:
            Section {
                Label("apple_music_library_hint", systemImage: "music.note.house")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .nfs:
            Section("nfs_config") {
                TextField("export_path", text: $exportPath)
                    .focused($focusedField, equals: .exportPath)
                    .autocorrectionDisabled().submitLabel(.done)
                    .onSubmit { focusedField = nil }
                Picker("nfs_version", selection: $nfsVersion) {
                    ForEach(NFSVersion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        case .s3:
            Section("S3") {
                TextField("s3_region", text: $basePath, prompt: Text("us-east-1"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("s3_bucket", text: $shareName)
                    .focused($focusedField, equals: .shareName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("s3_access_key", text: $username)
                    .focused($focusedField, equals: .username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                RevealableSecureField(title: "s3_secret_key", text: $password)
                    .focused($focusedField, equals: .password)
            }
        case .drime:
            Section("drime_token_section") {
                RevealableSecureField(title: "drime_access_token", text: $password)
                    .focused($focusedField, equals: .password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Label(isEditing ? "drime_token_edit_hint" : "drime_token_hint", systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("drime_token_permission_hint", systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .pan115, .pan123, .guangya:
            if !BuiltInCloudCredentials.hasBuiltIn(for: sourceType) {
                Section("cloud_oauth_config") {
                    TextField("cloud_client_id_or_app_key", text: $username)
                        .focused($focusedField, equals: .username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    RevealableSecureField(title: "cloud_client_secret_optional", text: $password)
                        .focused($focusedField, equals: .password)
                    Label("cloud_oauth_hint", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        default: EmptyView()
        }
    }

    // MARK: - Init & Save

    private func initializeFields() {
        guard !isInitialized else { return }
        useSsl = sourceType.defaultSSL
        port = "\(sourceType.defaultPort(useSsl: useSsl))"
        publicUseSsl = supportsSSLToggle ? true : sourceType.defaultSSL
        publicPort = "\(sourceType.defaultPort(useSsl: publicUseSsl))"

        if let s = editingSource {
            name = s.name
            username = s.username ?? ""
            basePath = s.basePath ?? ""
            plexServerIdentifier = s.plexServerIdentifier
            wholeSourceSpokenWord = SpokenWordStore.shared.isWholeSourceSpokenWord(sourceID: s.id)
            if supportsAdaptiveConnections {
                loadAdaptiveConnectionFields(from: s)
            } else {
                host = s.host ?? ""
                port = "\(s.port ?? sourceType.defaultPort)"
                useSsl = s.useSsl
                basePath = s.basePath ?? ""
                if sourceType == .synology {
                    synologyConnectionMode = s.effectiveSynologyConnectionMode
                }
                if sourceType == .fnMusic {
                    fnMusicConnectionMode = s.effectiveFnMusicConnectionMode
                }
            }
            shareName = s.shareName ?? ""; exportPath = s.exportPath ?? ""
            if sourceType == .s3 {
                basePath = s.s3Region ?? "us-east-1"
                shareName = s.basePath ?? ""
            }
            authType = s.authType; autoConnect = s.autoConnect; rememberDevice = s.rememberDevice
            // 兼容旧版“账号密码都留空即匿名”的来源记录。旧记录的 authType
            // 仍可能是 password；迁移成显式访客模式后才能正确清理/忽略旧凭据。
            if sourceType.supportsAnonymous,
               username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                switch KeychainService.passwordLookup(for: s.id) {
                case .notFound, .found(""):
                    authType = .none
                case .found(_), .temporarilyUnavailable(_), .failed(_):
                    break
                }
            }
            ftpEncryption = s.ftpEncryption ?? .none; nfsVersion = s.nfsVersion ?? .auto
            editingSourceHasStoredSecret = Self.readStoredSecretExists(for: s.id)
        } else if let device = prefillDevice {
            name = device.name
            host = device.host
            port = "\(device.port)"
            useSsl = device.preferredUseSsl ?? sourceType.defaultSSL
            // 发现来的端口是实测到的,所以连协议一起写死在地址里 —— 候选只剩
            // 一个,提交时不会再去试别的。
            addressRows = [SourceAddressRow(
                address: SourceAddressFormPolicy.exactAddress(
                    host: device.host,
                    port: device.port,
                    useSsl: useSsl,
                    sourceType: sourceType
                )
            )]
            if sourceType == .synology {
                synologyConnectionMode = .address
            }
            if sourceType == .fnMusic {
                fnMusicConnectionMode = .address
            }
            if sourceType == .plex {
                authType = .apiKey
            } else if [.local, .appleMusicLibrary, .nfs, .upnp].contains(sourceType) {
                authType = .none
            }
        } else {
            name = sourceType.displayName
            if sourceType == .s3 {
                basePath = "us-east-1"
                publicHost = "s3.amazonaws.com"
                addressRows = [SourceAddressRow(address: "s3.amazonaws.com")]
            }
            if sourceType == .synology {
                synologyConnectionMode = .quickConnect
            }
            if sourceType == .fnMusic {
                fnMusicConnectionMode = .fnConnect
            }
            if sourceType == .plex {
                authType = .apiKey
            } else if [.local, .appleMusicLibrary, .nfs, .upnp].contains(sourceType) {
                authType = .none
            }
        }
        #if os(iOS)
        // 基线取「填回草稿之前」: 恢复出来的表就算原样没动, 再切出去也要接着保住。
        draftBaseline = AddSourceDraftBaseline(draft: currentDraft, secrets: currentDraftSecrets)
        if let restoredDraft,
           restoredDraft.draft.sourceType == sourceType.rawValue,
           restoredDraft.draft.editingSourceID == editingSource?.id {
            applyRestoredDraft(restoredDraft)
            plog("📝 Restored unfinished source form type=\(sourceType.rawValue) editing=\(isEditing)")
        }
        #endif
        isInitialized = true
    }

    #if os(iOS)
    private var currentDraft: AddSourceDraft {
        AddSourceDraft(
            sourceType: sourceType.rawValue,
            editingSourceID: editingSource?.id,
            name: name,
            host: host,
            port: port,
            useSsl: useSsl,
            publicHost: publicHost,
            publicPort: publicPort,
            publicUseSsl: publicUseSsl,
            localPathPrefix: localPathPrefix,
            publicBasePath: publicBasePath,
            vendorIdentifier: vendorIdentifier,
            synologyConnectionMode: synologyConnectionMode.rawValue,
            fnMusicConnectionMode: fnMusicConnectionMode.rawValue,
            username: username,
            basePath: basePath,
            shareName: shareName,
            exportPath: exportPath,
            authType: authType.rawValue,
            ftpEncryption: ftpEncryption.rawValue,
            nfsVersion: nfsVersion.rawValue,
            autoConnect: autoConnect,
            rememberDevice: rememberDevice,
            addressRows: addressRows.map {
                AddSourceDraft.AddressRow(
                    address: $0.address,
                    portText: $0.portText,
                    transport: $0.transport.rawValue,
                    showsAdvancedOptions: $0.showsAdvancedOptions,
                    treatDotlessTokenAsHostname: $0.treatDotlessTokenAsHostname
                )
            }
        )
    }

    private var currentDraftSecrets: AddSourceDraftSecrets {
        AddSourceDraftSecrets(
            password: password,
            sshKey: sshKey,
            fnConnectAccessCode: fnConnectAccessCode
        )
    }

    private func persistDraftIfNeeded() {
        guard isInitialized, let draftBaseline else { return }
        let draft = currentDraft
        let secrets = currentDraftSecrets
        guard AddSourceDraftPolicy.shouldPersist(
            current: draft,
            currentSecrets: secrets,
            pristine: draftBaseline.draft,
            pristineSecrets: draftBaseline.secrets
        ) else { return }
        AddSourceDraftStore.save(draft, secrets: secrets)
    }

    private func applyRestoredDraft(_ restored: AddSourceDraftRestoration.Pending) {
        let draft = restored.draft
        name = draft.name
        host = draft.host
        port = draft.port
        useSsl = draft.useSsl
        publicHost = draft.publicHost
        publicPort = draft.publicPort
        publicUseSsl = draft.publicUseSsl
        localPathPrefix = draft.localPathPrefix
        publicBasePath = draft.publicBasePath
        vendorIdentifier = draft.vendorIdentifier
        synologyConnectionMode = SynologyConnectionMode(rawValue: draft.synologyConnectionMode)
            ?? synologyConnectionMode
        fnMusicConnectionMode = FnMusicConnectionMode(rawValue: draft.fnMusicConnectionMode)
            ?? fnMusicConnectionMode
        username = draft.username
        basePath = draft.basePath
        shareName = draft.shareName
        exportPath = draft.exportPath
        authType = SourceAuthType(rawValue: draft.authType) ?? authType
        ftpEncryption = FTPEncryption(rawValue: draft.ftpEncryption) ?? ftpEncryption
        nfsVersion = NFSVersion(rawValue: draft.nfsVersion) ?? nfsVersion
        autoConnect = draft.autoConnect
        rememberDevice = draft.rememberDevice
        if !draft.addressRows.isEmpty {
            addressRows = draft.addressRows.map { saved in
                var row = SourceAddressRow(address: saved.address)
                row.portText = saved.portText
                row.transport = SourceAddressTransportChoice(rawValue: saved.transport) ?? .automatic
                row.showsAdvancedOptions = saved.showsAdvancedOptions
                row.treatDotlessTokenAsHostname = saved.treatDotlessTokenAsHostname
                return row
            }
        }
        password = restored.secrets.password
        sshKey = restored.secrets.sshKey
        fnConnectAccessCode = restored.secrets.fnConnectAccessCode
    }
    #endif

    private func loadAdaptiveConnectionFields(from source: MusicSource) {
        let configuration = source.effectiveConnectionConfiguration
            ?? SourceConnectionConfiguration()

        if let endpoint = configuration.localEndpoint {
            host = endpoint.host
            port = String(endpoint.port)
            useSsl = endpoint.useSsl
            if sourceType.supportsEndpointPathPrefix {
                localPathPrefix = endpoint.pathPrefix ?? ""
            }
        } else {
            host = ""
            if !sourceType.supportsEndpointSpecificPath {
                basePath = source.basePath ?? ""
            }
        }

        if let endpoint = configuration.publicEndpoint {
            publicHost = endpoint.host
            publicPort = String(endpoint.port)
            publicUseSsl = endpoint.useSsl
            publicBasePath = endpoint.pathPrefix ?? ""
        }
        vendorIdentifier = configuration.vendorIdentifier ?? ""

        if sourceType.usesSynologyConnectionMode {
            synologyConnectionMode = configuration.remoteAccessMode == .vendor
                ? .quickConnect
                : .address
        } else if sourceType == .fnMusic {
            fnMusicConnectionMode = configuration.remoteAccessMode == .vendor
                ? .fnConnect
                : .address
        }

        // 已存的端点渲染回地址串,协议与端口都写在里面,再读一遍能原样回到同一个
        // 端点。留一份基线:这几行没被动过就不重新探测。
        let drafts = SourceAddressFormPolicy.drafts(for: configuration, sourceType: sourceType)
        addressRows = drafts.isEmpty ? [SourceAddressRow()] : drafts.map(SourceAddressRow.init(draft:))
        addressBaseline = drafts.isEmpty ? nil : drafts
    }

    // MARK: - 地址行

    private var isSubmitDisabled: Bool {
        canSave == false
            || mediaServerCreationTransaction.isRunning
            || addressProbe.isProbing
    }

    private func addressRowReading(
        _ reading: SourceAddressFormPolicy.FormReading,
        for id: UUID
    ) -> SourceAddressFormPolicy.Reading {
        guard let index = addressRows.firstIndex(where: { $0.id == id }),
              index < reading.rows.count else {
            return .empty
        }
        return reading.rows[index]
    }

    /// 选中的候选只是"有人应答"而不是"确认是这个服务"时,如实说一句。
    private var unconfirmedServiceNote: String? {
        for row in addressRows {
            if let note = SourceAddressReadingText.unconfirmedNote(
                addressProbe.verdicts[row.id],
                sourceType: sourceType
            ) {
                return note
            }
        }
        return nil
    }

    private func addAddressRow() {
        guard addressRows.count < SourceAddressFormPolicy.maximumAddressCount else { return }
        addressRows.append(SourceAddressRow())
    }

    private func removeAddressRow(_ id: UUID) {
        guard addressRows.count > 1 else { return }
        addressRows.removeAll { $0.id == id }
    }

    private func cancelAddressProbe() {
        addressSubmitTask?.cancel()
        addressSubmitTask = nil
        addressProbe.invalidate()
    }

    // MARK: - 提交

    /// 提交分三步:识别 → (需要时)探测 → 把结果写回旧表单那组 @State,再走原来的
    /// `saveSource()`。凭据事务、媒体服务器预检、S3 字段映射都在那里,一个字没动。
    private func submit() {
        guard supportsAdaptiveConnections, sourceType.requiresHost else {
            autoAssignNameIfNeeded(preferred: host)
            saveSource()
            return
        }

        let reading = addressReading
        guard reading.isSubmittable else { return }

        // 逐行判断要不要探:编辑已有源时没动过的那几行原样留着 —— 否则在外网
        // 给源补一条备用地址,会连带去探那条此刻动不了的内网地址。
        let probing = Set(
            zip(
                addressRows,
                SourceAddressFormPolicy.rowsRequiringProbe(
                    drafts: addressRows.map(\.draft),
                    baseline: addressBaseline
                )
            ).compactMap { row, needsProbe in needsProbe ? row.id : nil }
        )
        plog(
            "🔎 Source address submit type=\(sourceType.rawValue) editing=\(editingSource != nil) "
                + "rows=\(addressRows.count) probing=\(probing.count)"
        )
        guard probing.isEmpty == false else {
            // 编辑已有源且地址没动过:已存的端口与协议本来就是明确的,原样留着。
            applyAddressPlan(reading, selected: [:])
            saveSource()
            return
        }

        addressSubmitTask?.cancel()
        addressSubmitTask = Task { @MainActor in
            let outcome = await addressProbe.probe(
                rows: addressRows,
                reading: reading,
                sourceType: sourceType,
                probing: probing
            )
            guard outcome.isCancelled == false, Task.isCancelled == false else {
                plog("🔎 Source address submit cancelled")
                return
            }
            // 内网地址在外网探不通是实话而不是错。只要还有一行给出了结论,这次
            // 保存就照常进行:探不通的那一行按它自己的解读存回去(没动过的行读
            // 回来只有一个候选,就是它原来那个端点)。
            //
            // 一行都没应答才停下来 —— 尝试清单已经内联列在地址下面了,让用户
            // 接着改,或者按「仍然保存」坚持用第一个候选,不弹模态框打断。
            guard outcome.selected.isEmpty == false || outcome.unresolvedRowIDs.isEmpty else {
                plog("🔎 Source address submit halted: no address responded rows=\(outcome.unresolvedRowIDs.count)")
                return
            }
            plog(
                "🔎 Source address submit saving resolved=\(outcome.selected.count) "
                    + "unresolved=\(outcome.unresolvedRowIDs.count)"
            )
            applyAddressPlan(reading, selected: outcome.selected)
            saveSource()
        }
    }

    /// 探测不通也要存:已经探到的行用它探到的候选,没应答的行用第一个候选。
    private func saveWithoutProbing() {
        let reading = addressReading
        guard reading.isSubmittable else { return }
        // `cancelAddressProbe` 会清掉控制器上的结论,先取出来再取消。
        let selected = addressProbe.selectedCandidates
        plog("🔎 Source address saved without a full probe verdict resolved=\(selected.count)")
        cancelAddressProbe()
        applyAddressPlan(reading, selected: selected)
        saveSource()
    }

    /// 把识别 + 探测的结果写回 host / port / useSsl / publicHost / … 这组
    /// `@State`。保存路径读的仍然是这些字段,所以它的语义一点没变。
    private func applyAddressPlan(
        _ reading: SourceAddressFormPolicy.FormReading,
        selected: [UUID: SourceConnectionCandidatePlanner.Candidate]
    ) {
        var localEndpoint: SourceConnectionEndpoint?
        var publicEndpoint: SourceConnectionEndpoint?
        var resolvedVendorIdentifier: String?

        for (index, row) in addressRows.enumerated() where index < reading.rows.count {
            switch reading.rows[index] {
            case let .vendor(vendor):
                guard reading.placement.slots[index] == .vendor else { continue }
                resolvedVendorIdentifier = vendor.id
            case let .endpoint(endpoint):
                let candidate = selected[row.id] ?? endpoint.preferred
                guard let slot = endpoint.slot, let candidate else { continue }
                let value = SourceConnectionCandidatePlanner.endpoint(
                    for: endpoint.input,
                    candidate: candidate
                )
                if slot == .local {
                    localEndpoint = value
                } else {
                    publicEndpoint = value
                }
            case .empty, .invalid:
                continue
            }
        }

        host = localEndpoint?.host ?? ""
        port = localEndpoint.map { String($0.port) } ?? ""
        useSsl = localEndpoint?.useSsl ?? sourceType.defaultSSL
        localPathPrefix = localEndpoint?.pathPrefix ?? ""

        publicHost = publicEndpoint?.host ?? ""
        publicPort = publicEndpoint.map { String($0.port) } ?? ""
        publicUseSsl = publicEndpoint?.useSsl ?? (supportsSSLToggle ? true : sourceType.defaultSSL)
        publicBasePath = publicEndpoint?.pathPrefix ?? ""

        vendorIdentifier = resolvedVendorIdentifier ?? ""
        let usesVendor = resolvedVendorIdentifier != nil
        if sourceType.usesSynologyConnectionMode {
            synologyConnectionMode = usesVendor ? .quickConnect : .address
        }
        if sourceType == .fnMusic {
            fnMusicConnectionMode = usesVendor ? .fnConnect : .address
        }

        applyAddressPath(localEndpoint?.pathPrefix ?? publicEndpoint?.pathPrefix)
        autoAssignNameIfNeeded(
            preferred: resolvedVendorIdentifier ?? localEndpoint?.host ?? publicEndpoint?.host
        )
    }

    /// `smb://nas/music` 里的那截路径不属于端点:SMB 的共享名、NFS 的导出路径、
    /// FTP/SFTP 的起始目录都是源级别的字段。用户没单独填时就用地址里写的那段。
    private func applyAddressPath(_ rawPath: String?) {
        guard sourceType.supportsEndpointPathPrefix == false,
              let path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.isEmpty == false,
              path != "/" else {
            return
        }
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard relative.isEmpty == false else { return }

        switch sourceType {
        case .smb:
            // 共享名只有一段,更深的目录留给浏览器去选。
            guard shareName.isEmpty else { return }
            shareName = relative.split(separator: "/").first.map(String.init) ?? relative
        case .nfs:
            guard exportPath.isEmpty else { return }
            exportPath = path
        default:
            guard basePath.isEmpty else { return }
            basePath = path
        }
    }

    /// 在 Plex 账号的服务器清单里点中一台:线路、令牌、名字一次填好,再走和「保存」按钮同一条路。
    /// 地址框回显成选中的线路并记为基线,提交时不再探测 —— 这些地址就是服务器自己报给 plex.tv 的。
    private func applyPlexServer(_ selection: PlexServerSelection) {
        plexSignIn.cancel()
        loadAdaptiveConnectionFields(from: MusicSource(
            name: name,
            type: .plex,
            connectionConfiguration: selection.routes.connectionConfiguration
        ))
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName == sourceType.displayName {
            name = selection.resource.name
        }
        authType = .apiKey
        password = selection.serverToken
        plexAccountToken = selection.accountToken
        plexServerIdentifier = selection.resource.clientIdentifier
        plog(
            "🎞️ Plex server picked owned=\(selection.resource.isOwned) "
                + "local=\(selection.routes.local != nil) remote=\(selection.routes.remote != nil) "
                + "relayOnly=\(selection.routes.reachesOnlyThroughRelay)"
        )
        submit()
    }

    /// 名称留空时替用户取一个:主机名最好认,退回类型名。
    private func autoAssignNameIfNeeded(preferred: String?) {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let candidate = preferred?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        name = candidate.isEmpty ? sourceType.displayName : candidate
    }

    private func saveSource() {
        // 用户名做常规规范化；密码必须逐字节保留，因为首尾空白可能是
        // 服务端凭据本身的一部分。
        let username = self.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = self.password

        // S3 special mapping: host=endpoint, basePath=bucket, shareName→basePath,
        // extraConfig=JSON{region, dirs} (region + scanned-directory list).
        let finalHost: String?
        let finalBasePath: String?
        let finalShareName: String?
        let finalUsername: String?
        let adaptiveConfiguration = makeAdaptiveConnectionConfiguration()
        var extraConfig = editingSource?.extraConfig

        if sourceType == .s3 {
            finalHost = host.isEmpty ? "s3.amazonaws.com" : host
            finalBasePath = shareName  // bucket name
            finalShareName = nil
            finalUsername = username    // access key
            let region = basePath.isEmpty ? "us-east-1" : basePath
            // Merge into the existing config so the scanned-directory list that
            // shares this slot survives an edit instead of being overwritten.
            extraConfig = MusicSource.encodeS3Region(region, into: editingSource?.extraConfig)
        } else if sourceType.isCloudDrive {
            finalHost = nil
            finalBasePath = basePath.isEmpty ? nil : basePath
            finalShareName = nil
            finalUsername = sourceType == .drime ? nil : (username.isEmpty ? nil : username)  // client_id
        } else if supportsAdaptiveConnections {
            finalHost = nil
            if sourceType.supportsEndpointSpecificPath {
                finalBasePath = adaptiveConfiguration?.localEndpoint?.pathPrefix
                    ?? adaptiveConfiguration?.publicEndpoint?.pathPrefix
            } else {
                finalBasePath = basePath.isEmpty ? nil : basePath
            }
            finalShareName = shareName.isEmpty ? nil : shareName
            finalUsername = sourceType.requiresCredentials && authType != .apiKey && authType != .none
                ? (username.isEmpty ? nil : username)
                : nil
        } else {
            if sourceType == .synology, synologyConnectionMode == .quickConnect {
                finalHost = SynologyQuickConnectResolver.quickConnectID(from: host)
            } else if sourceType == .fnMusic, fnMusicConnectionMode == .fnConnect {
                finalHost = FnConnectResolver.fnID(from: host)
            } else {
                let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
                finalHost = sourceType.requiresHost ? trimmedHost : nil
            }
            finalBasePath = sourceType == .fnMusic && fnMusicConnectionMode == .fnConnect
                ? nil
                : (basePath.isEmpty ? nil : basePath)
            finalShareName = shareName.isEmpty ? nil : shareName
            finalUsername = sourceType.requiresCredentials && authType != .apiKey && authType != .none
                ? (username.isEmpty ? nil : username)
                : nil
        }

        var source = MusicSource(
            id: editingSource?.id ?? UUID().uuidString,
            name: name, type: sourceType,
            host: finalHost,
            port: supportsAdaptiveConnections
                ? nil
                : (sourceType.requiresHost
                ? ((sourceType == .synology && synologyConnectionMode == .quickConnect)
                    || (sourceType == .fnMusic && fnMusicConnectionMode == .fnConnect)
                    ? sourceType.defaultPort(useSsl: true)
                    : validatedPort)
                : nil),
            useSsl: supportsAdaptiveConnections
                ? useSsl
                : ((sourceType == .synology && synologyConnectionMode == .quickConnect)
                || (sourceType == .fnMusic && fnMusicConnectionMode == .fnConnect)
                ? true
                : useSsl),
            synologyConnectionMode: sourceType.usesSynologyConnectionMode ? synologyConnectionMode : nil,
            fnMusicConnectionMode: sourceType == .fnMusic ? fnMusicConnectionMode : nil,
            connectionConfiguration: adaptiveConfiguration,
            username: finalUsername,
            basePath: finalBasePath,
            shareName: finalShareName,
            exportPath: exportPath.isEmpty ? nil : exportPath,
            authType: sourceType == .drime ? .apiKey : (sourceType.isCloudDrive ? .oauth : authType),
            ftpEncryption: sourceType == .ftp ? ftpEncryption : nil,
            nfsVersion: sourceType == .nfs ? nfsVersion : nil,
            autoConnect: autoConnect, rememberDevice: rememberDevice,
            deviceId: editingSource?.deviceId,
            // 编辑时透传表单未覆盖的字段: 否则整体写回会把扫描计数/启用状态/
            // 云盘账号绑定/上次扫描时间静默重置成 init 默认值。
            lastScannedAt: editingSource?.lastScannedAt,
            isEnabled: editingSource?.isEnabled ?? true,
            songCount: editingSource?.songCount ?? 0,
            extraConfig: extraConfig,
            scannedDirectoryDisplayNames: editingSource?.scannedDirectoryDisplayNames ?? [:],
            isDeleted: editingSource?.isDeleted ?? false,
            deletedAt: editingSource?.deletedAt,
            restoredAt: editingSource?.restoredAt,
            cloudAccountID: editingSource?.cloudAccountID,
            plexServerIdentifier: sourceType == .plex ? plexServerIdentifier : nil,
            excludedServerLibraryIDs: serverLibrariesLoad == .loaded
                ? serverLibraryChoices.filter { $0.value == .excluded }.keys.sorted()
                : (editingSource?.excludedServerLibraryIDs ?? [])
        )
        if supportsAdaptiveConnections {
            source = source.projectingPreferredConnectionForLegacy()
        }

        // Validate against the edited address and account before replacing the
        // stored password. The shared flow also handles DSM two-step sign-in.
        if sourceType.usesSynologyConnectionMode, isEditing, !password.isEmpty {
            validatedCredentialSource = nil
            credentialValidationSource = source
            return
        }

        if requiresAuthenticatedMediaServerPreflight {
            mediaServerCreationTransaction.submit(
                source: source,
                secret: password,
                persistCredential: { sourceID, secret in
                    guard (try? sourceManager.credentialsWillChange(for: sourceID)) != nil else {
                        return false
                    }
                    let persisted: Bool
                    if secret.isEmpty {
                        persisted = KeychainService.deletePassword(for: sourceID)
                    } else {
                        persisted = KeychainService.setPassword(secret, for: sourceID)
                    }
                    guard persisted else {
                        // Bool cannot distinguish an unchanged failure from a
                        // durable target write followed by cleanup failure.
                        // Keep the prepared scope blocked in either case.
                        sourceManager.credentialsChangeOutcomeUncertain(for: sourceID)
                        return false
                    }
                    do {
                        try sourceManager.credentialsDidChange(for: sourceID)
                        return true
                    } catch {
                        sourceManager.credentialsChangeOutcomeUncertain(for: sourceID)
                        return false
                    }
                },
                removeCredential: { sourceID in
                    // Rollback is itself a credential mutation. If the failed
                    // write left a prepared transition active, commit that
                    // transition after deletion instead of trusting old bytes.
                    _ = try? sourceManager.credentialsWillChange(for: sourceID)
                    guard KeychainService.deletePassword(for: sourceID) else {
                        sourceManager.credentialsChangeOutcomeUncertain(for: sourceID)
                        return false
                    }
                    do {
                        try sourceManager.credentialsDidChange(for: sourceID)
                        return true
                    } catch {
                        sourceManager.credentialsChangeOutcomeUncertain(for: sourceID)
                        return false
                    }
                },
                persistSource: { source in
                    guard let onValidatedMediaServerSave else {
                        throw MediaServerSourceCreationError.missingPersistenceHandler
                    }
                    try onValidatedMediaServerSave(source)
                },
                onCommit: { _ in
                    dismiss()
                }
            )
            return
        }

        // Save credentials
        var preparedCredentialChange = false
        func prepareCredentialChange() -> Bool {
            guard !preparedCredentialChange else { return true }
            do {
                try sourceManager.credentialsWillChange(for: source.id)
                preparedCredentialChange = true
                return true
            } catch {
                plog("⚠️ Source credential revision could not be persisted source=\(source.id.prefix(8))… error=\(error.localizedDescription)")
                showCredentialSaveError = true
                return false
            }
        }
        if sourceType == .drime {
            let tm = CloudTokenManager(sourceID: source.id)
            let token = password.trimmingCharacters(in: .whitespacesAndNewlines)
            let changesCredential = !token.isEmpty || editingSource == nil
            if changesCredential {
                guard prepareCredentialChange() else { return }
            }
            Task { @MainActor in
                let persisted: Bool
                if !token.isEmpty {
                    persisted = await tm.saveTokens(.init(accessToken: token))
                } else if editingSource == nil {
                    persisted = await tm.deleteTokens()
                } else {
                    persisted = true
                }
                guard persisted else {
                    if changesCredential {
                        sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                    }
                    showCredentialSaveError = true
                    return
                }
                if changesCredential {
                    do {
                        try sourceManager.credentialsDidChange(for: source.id)
                    } catch {
                        sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                        showCredentialSaveError = true
                        return
                    }
                }
                completeSave(source)
            }
            return
        } else if sourceType.isCloudDrive {
            // Store client_id + client_secret via CloudTokenManager
            let tm = CloudTokenManager(sourceID: source.id)
            let changesCredential = !BuiltInCloudCredentials.hasBuiltIn(for: sourceType)
            if changesCredential {
                guard prepareCredentialChange() else { return }
            }
            Task { @MainActor in
                let persisted: Bool
                if BuiltInCloudCredentials.hasBuiltIn(for: sourceType) {
                    // Built-in providers hide this configuration entirely.
                    // Preserve any legacy per-source override instead of
                    // rewriting its hidden secret during an unrelated edit.
                    persisted = true
                } else if !username.isEmpty {
                    persisted = await tm.saveAppCredentials(.init(
                        clientId: username,
                        clientSecret: password.isEmpty ? nil : password
                    ))
                } else {
                    persisted = await tm.deleteAppCredentials()
                }
                guard persisted else {
                    if changesCredential {
                        sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                    }
                    showCredentialSaveError = true
                    return
                }
                if changesCredential {
                    do {
                        try sourceManager.credentialsDidChange(for: source.id)
                    } catch {
                        sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                        showCredentialSaveError = true
                        return
                    }
                }
                completeSave(source)
            }
            return
        } else if authType == .none {
            // 从账号登录切换到访客模式时必须删除旧 Keychain 项；否则连接器仍会
            // 读到旧密码，表面显示“访客”却继续以旧账号认证。
            if let editingSource, editingSource.authType != .none {
                guard prepareCredentialChange() else { return }
            }
            guard KeychainService.deletePassword(for: source.id) else {
                if preparedCredentialChange {
                    sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                }
                showCredentialSaveError = true
                return
            }
        } else if sourceType == .s3 || authType == .password || authType == .apiKey || authType == .cookie || authType == .oauth {
            if !password.isEmpty {
                guard prepareCredentialChange() else { return }
                guard KeychainService.setPassword(password, for: source.id) else {
                    sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                    showCredentialSaveError = true
                    return
                }
            }
        } else if authType == .sshKey {
            let trimmedKey = sshKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                guard prepareCredentialChange() else { return }
                guard KeychainService.setPassword(trimmedKey, for: source.id) else {
                    sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                    showCredentialSaveError = true
                    return
                }
            }
        }

        if sourceType == .fnMusic,
           fnMusicConnectionMode == .fnConnect,
           !fnConnectAccessCode.isEmpty {
            guard prepareCredentialChange() else { return }
            guard KeychainService.setPassword(
                fnConnectAccessCode,
                for: FnMusicAPIProtocol.fnConnectAccessCodeAccount(sourceID: source.id)
            ) else {
                sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                showCredentialSaveError = true
                return
            }
        }

        if preparedCredentialChange {
            do {
                try sourceManager.credentialsDidChange(for: source.id)
            } catch {
                sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                showCredentialSaveError = true
                return
            }
        }

        // 账号 token 只用来日后重新查服务器的地址，连接器不读它，所以不走凭据变更那一套；
        // 写不进去也不拦保存，只是这个源以后跟不上服务器换地址。
        if sourceType == .plex, !plexAccountToken.isEmpty,
           !KeychainService.setPassword(
               plexAccountToken,
               for: PlexAccountAPI.accountTokenKeychainAccount(sourceID: source.id)
           ) {
            plog("⚠️ Plex account token could not be stored source=\(source.id.prefix(8))…")
        }

        #if os(macOS)
        if sourceType == .local, let pickedURL = pendingLocalFolderURL {
            try? LocalBookmarkStore.save(sourceID: source.id, url: pickedURL)
        }
        #endif

        completeSave(source)
    }

    private func cancelAndDismiss() {
        addressSubmitTask?.cancel()
        addressSubmitTask = nil
        if requiresAuthenticatedMediaServerPreflight {
            mediaServerCreationTransaction.cancel()
        }
        dismiss()
    }

    private func completeSave(_ source: MusicSource) {
        applySpokenWordChoices(sourceID: source.id)
        onSave(source)
        // The main Sources flow keeps this sheet alive and replaces the form
        // with the existing connection / OTP / directory UI. Sources whose
        // creation is transactional decide there whether to commit or roll
        // back the credentials written for this temporary source ID.
        if !continuesToConnectionAfterSave {
            dismiss()
        }
    }

    private func finishCredentialValidation() {
        guard let source = validatedCredentialSource else { return }
        validatedCredentialSource = nil
        password = ""
        completeSave(source)
    }

    private func makeAdaptiveConnectionConfiguration() -> SourceConnectionConfiguration? {
        guard supportsAdaptiveConnections else { return nil }

        let localHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let remoteHost = publicHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let localEndpoint = localHost.isEmpty ? nil : validatedPort.map {
            SourceConnectionEndpoint(
                host: localHost,
                port: $0,
                useSsl: useSsl,
                pathPrefix: sourceType.supportsEndpointPathPrefix
                    ? normalizedOptionalPath(localPathPrefix)
                    : nil
            ).normalized
        }
        let publicEndpoint = remoteHost.isEmpty ? nil : validatedPublicPort.map {
            SourceConnectionEndpoint(
                host: remoteHost,
                port: $0,
                useSsl: publicUseSsl,
                pathPrefix: sourceType.supportsEndpointPathPrefix
                    ? normalizedOptionalPath(publicBasePath)
                    : nil
            ).normalized
        }

        let rawVendorIdentifier = vendorIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVendorIdentifier: String?
        if rawVendorIdentifier.isEmpty {
            normalizedVendorIdentifier = nil
        } else if sourceType.usesSynologyConnectionMode {
            normalizedVendorIdentifier = SynologyQuickConnectResolver.quickConnectID(
                from: rawVendorIdentifier
            ) ?? rawVendorIdentifier
        } else if sourceType == .fnMusic {
            normalizedVendorIdentifier = FnConnectResolver.fnID(from: rawVendorIdentifier)
                ?? rawVendorIdentifier
        } else {
            normalizedVendorIdentifier = nil
        }

        // A save from this form always writes an unrestricted configuration:
        // whatever the user left filled in is what gets used.
        return SourceConnectionConfiguration(
            localEndpoint: localEndpoint,
            publicEndpoint: publicEndpoint,
            remoteAccessMode: remoteUsesVendor ? .vendor : .direct,
            vendorIdentifier: normalizedVendorIdentifier
        )
    }

    private func normalizedOptionalPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    #if os(macOS)
    private func pickLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "choose_folder")
        if panel.runModal() == .OK, let url = panel.url {
            pendingLocalFolderURL = url
            basePath = url.path
            if name.isEmpty { name = url.lastPathComponent }
        }
    }
    #endif
}

// MARK: - Unfinished form

/// 表单刚打开时的内容, 用来判断退到后台时有没有改过。
struct AddSourceDraftBaseline {
    let draft: AddSourceDraft
    let secrets: AddSourceDraftSecrets
}

/// 没填完的添加 / 编辑音乐源表单。普通字段进 UserDefaults; 密码、私钥、
/// FN Connect 访问码只进不同步的本机钥匙串, 表单关掉或草稿过期就一起删掉。
@MainActor
enum AddSourceDraftStore {
    private static let recordKey = "primuse.addSourceDraft.v1"
    private static let passwordItem = "primuse.addSourceDraft.password"
    private static let sshKeyItem = "primuse.addSourceDraft.sshKey"
    private static let accessCodeItem = "primuse.addSourceDraft.fnAccessCode"

    /// 先写记录再写密钥, 清除时反过来: 有密钥就一定有记录, 清除只看记录在不在,
    /// 不用每次关表单都去敲三次钥匙串。
    static func save(_ draft: AddSourceDraft, secrets: AddSourceDraftSecrets, now: Date = Date()) {
        guard let data = AddSourceDraftPolicy.encode(draft, savedAt: now) else { return }
        UserDefaults.standard.set(data, forKey: recordKey)
        storeSecret(secrets.password, item: passwordItem)
        storeSecret(secrets.sshKey, item: sshKeyItem)
        storeSecret(secrets.fnConnectAccessCode, item: accessCodeItem)
    }

    /// 还值得接着填的那份; 过期或读不出来的当场连密钥一起删掉。
    static func restorable(now: Date = Date()) -> AddSourceDraftRestoration.Pending? {
        guard let data = UserDefaults.standard.data(forKey: recordKey) else { return nil }
        guard let draft = AddSourceDraftPolicy.restorableDraft(from: data, now: now),
              MusicSourceType(rawValue: draft.sourceType) != nil else {
            clear()
            return nil
        }
        return AddSourceDraftRestoration.Pending(
            draft: draft,
            secrets: AddSourceDraftSecrets(
                password: readSecret(passwordItem),
                sshKey: readSecret(sshKeyItem),
                fnConnectAccessCode: readSecret(accessCodeItem)
            )
        )
    }

    static func clear() {
        guard UserDefaults.standard.object(forKey: recordKey) != nil else { return }
        for item in [passwordItem, sshKeyItem, accessCodeItem] {
            _ = KeychainService.deletePassword(for: item)
        }
        UserDefaults.standard.removeObject(forKey: recordKey)
    }

    private static func storeSecret(_ value: String, item: String) {
        if value.isEmpty {
            _ = KeychainService.deletePassword(for: item)
        } else {
            KeychainService.setLocalOnlyPassword(value, for: item)
        }
    }

    private static func readSecret(_ item: String) -> String {
        if case .found(let value) = KeychainService.localOnlyPasswordLookup(for: item) {
            return value
        }
        return ""
    }
}

/// 启动时把上次没填完的表单交给「设置 › 音乐源」: 新建的经选类型页直接打开
/// 那一种的表单, 编辑的直接打开那个源的编辑页。每次启动只看一次。
@MainActor
@Observable
final class AddSourceDraftRestoration {
    struct Pending: Equatable {
        let draft: AddSourceDraft
        let secrets: AddSourceDraftSecrets

        var sourceType: MusicSourceType? { MusicSourceType(rawValue: draft.sourceType) }
    }

    static let shared = AddSourceDraftRestoration()
    private(set) var pending: Pending?
    @ObservationIgnored private var hasChecked = false

    #if os(iOS)
    func restoreIfNeeded() {
        guard !hasChecked else { return }
        hasChecked = true
        guard let restored = AddSourceDraftStore.restorable() else { return }
        pending = restored
        plog("📝 Unfinished source form found type=\(restored.draft.sourceType) editing=\(restored.draft.editingSourceID != nil); reopening Sources")
        SettingsNavigation.shared.open(SettingsPage.sources.id)
    }
    #endif

    /// 交给某个音乐源页之后就不再留着, 免得同时在的另一个音乐源页再开一次。
    func take() -> Pending? {
        defer { pending = nil }
        return pending
    }
}

/// 源设置里一个服务端资料库的去向。
enum ServerLibraryChoice: Hashable {
    case music
    case spokenWord
    case excluded
}

enum ServerLibrariesLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed
}
