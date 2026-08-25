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
    let sourceType: MusicSourceType
    var editingSource: MusicSource?
    var prefillDevice: DiscoveredDevice?
    var submitIntent: AddSourceSubmitIntent = .save
    var onValidatedJellyfinSave: ((MusicSource) throws -> Void)? = nil
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
    @State private var showCredentialSaveError = false
    @State private var showSynologyPasswordValidationInfo = false
    @State private var jellyfinCreationTransaction = JellyfinSourceCreationTransaction()
    #if os(macOS)
    /// Captures the URL chosen via NSOpenPanel so we can persist a
    /// security-scoped bookmark once the source has an ID.
    @State private var pendingLocalFolderURL: URL?
    #endif

    @FocusState private var focusedField: SourceFormField?

    private var isEditing: Bool { editingSource != nil }
    private var requiresAuthenticatedJellyfinPreflight: Bool {
        JellyfinSourceCreationPolicy.requiresPreflight(
            for: sourceType,
            isEditing: isEditing
        )
    }
    private var continuesToConnectionAfterSave: Bool {
        !isEditing
            && submitIntent == .continueToConnection
            && sourceType.continuesToDirectorySelectionAfterCreation
    }
    private var submitButtonTitle: LocalizedStringKey {
        continuesToConnectionAfterSave ? "Next" : "save"
    }
    private var supportsAPIKeyAuth: Bool { [.jellyfin, .emby, .plex].contains(sourceType) }
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
        if sourceType == .synology { return synologyConnectionMode == .quickConnect }
        if sourceType == .fnMusic { return fnMusicConnectionMode == .fnConnect }
        return false
    }
    private var localEndpointIsConfigured: Bool {
        host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    private var publicEndpointIsConfigured: Bool {
        publicHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    private var vendorIdentifierIsConfigured: Bool {
        vendorIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    private var localEndpointIsValid: Bool {
        localEndpointIsConfigured && validatedPort != nil
    }
    private var publicEndpointIsValid: Bool {
        publicEndpointIsConfigured && validatedPublicPort != nil
    }
    private var vendorIdentifierIsValid: Bool {
        let value = vendorIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if sourceType == .synology { return SynologyQuickConnectResolver.isValidQuickConnectID(value) }
        if sourceType == .fnMusic { return FnConnectResolver.isValidFNID(value) }
        return false
    }
    private var activeRemoteEndpointIsValid: Bool {
        remoteUsesVendor ? vendorIdentifierIsValid : publicEndpointIsValid
    }
    private var adaptiveConnectionIsValid: Bool {
        if localEndpointIsConfigured && validatedPort == nil { return false }
        if !remoteUsesVendor, publicEndpointIsConfigured && validatedPublicPort == nil { return false }
        if remoteUsesVendor, vendorIdentifierIsConfigured && !vendorIdentifierIsValid { return false }
        // Filling in either side is enough; both filled simply means the router
        // gets two routes to choose from.
        return localEndpointIsValid || activeRemoteEndpointIsValid
    }
    private var canSave: Bool {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if sourceType.requiresHost {
            if supportsAdaptiveConnections {
                guard adaptiveConnectionIsValid else { return false }
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
            switch KeychainService.passwordLookup(for: editingSource.id) {
            case .found(let secret):
                hasStoredSecret = !secret.isEmpty
            case .notFound:
                hasStoredSecret = false
            case .temporarilyUnavailable, .failed:
                // Preserve an existing edit without forcing the user to
                // overwrite a credential that is merely unreadable right now.
                hasStoredSecret = true
            }
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
        .onChange(of: useSsl) { oldValue, newValue in
            updateDefaultPortForSSLChange(
                port: $port,
                from: oldValue,
                to: newValue
            )
        }
        .onChange(of: publicUseSsl) { oldValue, newValue in
            updateDefaultPortForSSLChange(
                port: $publicPort,
                from: oldValue,
                to: newValue
            )
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
        .alert(
            String(localized: "synology_password_edit_validation_title"),
            isPresented: $showSynologyPasswordValidationInfo
        ) {
            Button("ok", role: .cancel) {}
        } message: {
            Text("synology_password_edit_validation_hint")
        }
        .alert(
            jellyfinCreationTransaction.failure?.title ?? String(localized: "connection_failed"),
            isPresented: Binding(
                get: { jellyfinCreationTransaction.failure != nil },
                set: { isPresented in
                    if !isPresented { jellyfinCreationTransaction.clearFailure() }
                }
            )
        ) {
            Button("ok", role: .cancel) {
                jellyfinCreationTransaction.clearFailure()
            }
        } message: {
            Text(jellyfinCreationTransaction.failure?.message ?? "")
        }
        .onDisappear {
            if requiresAuthenticatedJellyfinPreflight {
                jellyfinCreationTransaction.cancel()
            }
        }
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
            .navigationTitle(isEditing ? String(localized: "edit_source") : sourceType.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { cancelAndDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitButtonTitle) { saveSource() }
                        .disabled(canSave == false || jellyfinCreationTransaction.isRunning)
                        .fontWeight(.semibold)
                }
            }
            .onAppear { initializeFields() }
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

                Button(submitButtonTitle) { saveSource() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(canSave == false || jellyfinCreationTransaction.isRunning)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background((canSave ? theme.uiAccentColor : PMColor.textFaint), in: .rect(cornerRadius: 6))
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
                            .disabled(sourceType == .synology && isEditing)
                    }
                }

                if sourceType == .fnMusic {
                    macInfoRow("fnmusic_account_hint")
                    if fnMusicConnectionMode == .fnConnect {
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
                    macInfoRow(credentialEditHint)
                }
            }
        }

        macSection("advanced") {
            if sourceType.isServerLibrary
                && !sourceType.supportsEndpointSpecificPath
                && !(sourceType == .fnMusic && fnMusicConnectionMode == .fnConnect) {
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
                macTextRow("Region", text: $basePath)
                macTextRow("Bucket", text: $shareName, focus: .shareName)
                macTextRow("Access Key", text: $username, focus: .username)
                macCustomRow("Secret Key") {
                    RevealableSecureField(title: "Secret Key", text: $password)
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
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .pan115, .pan123:
            if !BuiltInCloudCredentials.hasBuiltIn(for: sourceType) {
                macSection("cloud_oauth_config") {
                    macTextRow("Client ID / App Key", text: $username, focus: .username)
                    macCustomRow("Client Secret") {
                        RevealableSecureField(title: "Client Secret (optional)", text: $password)
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

    @ViewBuilder
    private var macAdaptiveConnectionSections: some View {
        macSection("source_connection_local_optional") {
            macInfoRow("source_connection_intro")
            macTextRow("source_connection_local_address", text: $host, focus: .host)
            macTextRow("source_connection_local_port", text: $port, focus: .port, width: 120)
            if supportsSSLToggle {
                macToggleRow("use_ssl", isOn: $useSsl)
            }
            if sourceType.supportsEndpointPathPrefix {
                macTextRow(
                    "source_connection_path_prefix",
                    text: $localPathPrefix,
                    focus: .basePath
                )
            }
        }

        macSection("source_connection_remote_optional") {
            if sourceType == .synology {
                macCustomRow("source_connection_remote_method") {
                    Picker("", selection: $synologyConnectionMode) {
                        Text("source_connection_public_direct").tag(SynologyConnectionMode.address)
                        Text("synology_connection_quickconnect").tag(SynologyConnectionMode.quickConnect)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
            } else if sourceType == .fnMusic {
                macCustomRow("source_connection_remote_method") {
                    Picker("", selection: $fnMusicConnectionMode) {
                        Text("source_connection_public_direct").tag(FnMusicConnectionMode.address)
                        Text("fnmusic_connection_fnconnect").tag(FnMusicConnectionMode.fnConnect)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 320)
                }
            }

            if remoteUsesVendor {
                macTextRow(
                    sourceType == .synology ? "synology_quickconnect_id" : "fnmusic_fnid",
                    text: $vendorIdentifier,
                    focus: .vendorIdentifier
                )
                macInfoRow(
                    sourceType == .synology
                        ? "synology_quickconnect_hint"
                        : "fnmusic_fnconnect_hint"
                )
            } else {
                macTextRow("source_connection_public_address", text: $publicHost, focus: .publicHost)
                macTextRow("source_connection_public_port", text: $publicPort, focus: .publicPort, width: 120)
                if supportsSSLToggle {
                    macToggleRow("use_ssl", isOn: $publicUseSsl)
                }
                if sourceType.supportsEndpointPathPrefix {
                    macTextRow(
                        "source_connection_path_prefix",
                        text: $publicBasePath,
                        focus: .publicBasePath
                    )
                }
                macInfoRow("source_connection_public_hint")
            }
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
            .pmCard(cornerRadius: 10)
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
    #endif

    /// Form body extracted so iOS / macOS chrome can share it.
    @ViewBuilder
    private var formSections: some View {
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
                        .disabled(sourceType == .synology && isEditing)
                }
                if sourceType == .fnMusic {
                    Text("fnmusic_account_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if fnMusicConnectionMode == .fnConnect {
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
                    Text(credentialEditHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section("advanced") {
            if sourceType.isServerLibrary
                && !sourceType.supportsEndpointSpecificPath
                && !(sourceType == .fnMusic && fnMusicConnectionMode == .fnConnect) {
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

    @ViewBuilder
    private var adaptiveConnectionFormSections: some View {
        Section {
            Text("source_connection_intro")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("source_connection_local_optional") {
            TextField("source_connection_local_address", text: $host)
                .focused($focusedField, equals: .host)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.next)
                .onSubmit { focusedField = .port }
            TextField("source_connection_local_port", text: $port)
                .focused($focusedField, equals: .port)
                .keyboardType(.numberPad)
            if supportsSSLToggle {
                Toggle("use_ssl", isOn: $useSsl)
            }
            if sourceType.supportsEndpointPathPrefix {
                TextField("source_connection_path_prefix", text: $localPathPrefix)
                    .focused($focusedField, equals: .basePath)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }

        Section("source_connection_remote_optional") {
            if sourceType == .synology {
                Picker("source_connection_remote_method", selection: $synologyConnectionMode) {
                    Text("source_connection_public_direct").tag(SynologyConnectionMode.address)
                    Text("synology_connection_quickconnect").tag(SynologyConnectionMode.quickConnect)
                }
                .pickerStyle(.segmented)
            } else if sourceType == .fnMusic {
                Picker("source_connection_remote_method", selection: $fnMusicConnectionMode) {
                    Text("source_connection_public_direct").tag(FnMusicConnectionMode.address)
                    Text("fnmusic_connection_fnconnect").tag(FnMusicConnectionMode.fnConnect)
                }
                .pickerStyle(.segmented)
            }

            if remoteUsesVendor {
                TextField(
                    sourceType == .synology ? "synology_quickconnect_id" : "fnmusic_fnid",
                    text: $vendorIdentifier
                )
                .focused($focusedField, equals: .vendorIdentifier)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                if sourceType == .synology {
                    Text("synology_quickconnect_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("fnmusic_fnconnect_hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField("source_connection_public_address", text: $publicHost)
                    .focused($focusedField, equals: .publicHost)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .publicPort }
                TextField("source_connection_public_port", text: $publicPort)
                    .focused($focusedField, equals: .publicPort)
                    .keyboardType(.numberPad)
                if supportsSSLToggle {
                    Toggle("use_ssl", isOn: $publicUseSsl)
                }
                if sourceType.supportsEndpointPathPrefix {
                    TextField("source_connection_path_prefix", text: $publicBasePath)
                        .focused($focusedField, equals: .publicBasePath)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Text("source_connection_public_hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                TextField("Region", text: $basePath, prompt: Text("us-east-1"))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Bucket", text: $shareName)
                    .focused($focusedField, equals: .shareName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Access Key", text: $username)
                    .focused($focusedField, equals: .username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                RevealableSecureField(title: "Secret Key", text: $password)
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
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .pan115, .pan123:
            if !BuiltInCloudCredentials.hasBuiltIn(for: sourceType) {
                Section("cloud_oauth_config") {
                    TextField("Client ID / App Key", text: $username)
                        .focused($focusedField, equals: .username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    RevealableSecureField(title: "Client Secret (optional)", text: $password)
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
        } else if let device = prefillDevice {
            name = device.name
            host = device.host
            port = "\(device.port)"
            useSsl = device.preferredUseSsl ?? sourceType.defaultSSL
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
        isInitialized = true
    }

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

        if sourceType == .synology {
            synologyConnectionMode = configuration.remoteAccessMode == .vendor
                ? .quickConnect
                : .address
        } else if sourceType == .fnMusic {
            fnMusicConnectionMode = configuration.remoteAccessMode == .vendor
                ? .fnConnect
                : .address
        }
    }

    private func saveSource() {
        // 用户名做常规规范化；密码必须逐字节保留，因为首尾空白可能是
        // 服务端凭据本身的一部分。
        let username = self.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = self.password

        // An edited Synology source already has a last known-good credential.
        // Replacing it from this form would bypass DSM login/2FA/SSL validation.
        // Credential rotation therefore happens only through ConnectionFlowView.
        if sourceType == .synology, editingSource != nil, !password.isEmpty {
            self.password = ""
            showSynologyPasswordValidationInfo = true
            return
        }

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
            synologyConnectionMode: sourceType == .synology ? synologyConnectionMode : nil,
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
            cloudAccountID: editingSource?.cloudAccountID
        )
        if supportsAdaptiveConnections {
            source = source.projectingPreferredConnectionForLegacy()
        }

        if requiresAuthenticatedJellyfinPreflight {
            jellyfinCreationTransaction.submit(
                source: source,
                secret: password,
                persistCredential: { sourceID, secret in
                    if secret.isEmpty {
                        return KeychainService.deletePassword(for: sourceID)
                    }
                    return KeychainService.setPassword(secret, for: sourceID)
                },
                removeCredential: { sourceID in
                    KeychainService.deletePassword(for: sourceID)
                },
                persistSource: { source in
                    guard let onValidatedJellyfinSave else {
                        throw JellyfinSourceCreationError.missingPersistenceHandler
                    }
                    try onValidatedJellyfinSave(source)
                },
                onCommit: { _ in
                    dismiss()
                }
            )
            return
        }

        // Save credentials
        if sourceType == .drime {
            let tm = CloudTokenManager(sourceID: source.id)
            let token = password.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    showCredentialSaveError = true
                    return
                }
                completeSave(source)
            }
            return
        } else if sourceType.isCloudDrive {
            // Store client_id + client_secret via CloudTokenManager
            let tm = CloudTokenManager(sourceID: source.id)
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
                    showCredentialSaveError = true
                    return
                }
                completeSave(source)
            }
            return
        } else if authType == .none {
            // 从账号登录切换到访客模式时必须删除旧 Keychain 项；否则连接器仍会
            // 读到旧密码，表面显示“访客”却继续以旧账号认证。
            guard KeychainService.deletePassword(for: source.id) else {
                showCredentialSaveError = true
                return
            }
        } else if sourceType == .s3 || authType == .password || authType == .apiKey || authType == .cookie || authType == .oauth {
            if !password.isEmpty {
                guard KeychainService.setPassword(password, for: source.id) else {
                    showCredentialSaveError = true
                    return
                }
            }
        } else if authType == .sshKey {
            let trimmedKey = sshKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                guard KeychainService.setPassword(trimmedKey, for: source.id) else {
                    showCredentialSaveError = true
                    return
                }
            }
        }

        if sourceType == .fnMusic,
           fnMusicConnectionMode == .fnConnect,
           !fnConnectAccessCode.isEmpty {
            guard KeychainService.setPassword(
                fnConnectAccessCode,
                for: FnMusicAPIProtocol.fnConnectAccessCodeAccount(sourceID: source.id)
            ) else {
                showCredentialSaveError = true
                return
            }
        }

        #if os(macOS)
        if sourceType == .local, let pickedURL = pendingLocalFolderURL {
            try? LocalBookmarkStore.save(sourceID: source.id, url: pickedURL)
        }
        #endif

        completeSave(source)
    }

    private func cancelAndDismiss() {
        if requiresAuthenticatedJellyfinPreflight {
            jellyfinCreationTransaction.cancel()
        }
        dismiss()
    }

    private func completeSave(_ source: MusicSource) {
        onSave(source)
        // The main Sources flow keeps this sheet alive and replaces the form
        // with the existing connection / OTP / directory UI. Sources whose
        // creation is transactional decide there whether to commit or roll
        // back the credentials written for this temporary source ID.
        if !continuesToConnectionAfterSave {
            dismiss()
        }
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
        } else if sourceType == .synology {
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

    private var credentialEditHint: LocalizedStringKey {
        sourceType == .synology
            ? "synology_password_edit_validation_hint"
            : "password_edit_hint"
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
