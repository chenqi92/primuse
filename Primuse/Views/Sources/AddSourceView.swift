import SwiftUI
import PrimuseKit
#if os(macOS)
import AppKit
#endif

// MARK: - Focus Fields

enum SourceFormField: Hashable {
    case name, host, port, basePath, shareName, exportPath, username, password, sshKey
}

// MARK: - Add / Edit Source View
// Simple form — just fill info and save. Connecting & browsing happens from SourcesView.

struct AddSourceView: View {
    @Environment(\.dismiss) private var dismiss
    let sourceType: MusicSourceType
    var editingSource: MusicSource?
    var prefillDevice: DiscoveredDevice?
    var onSave: (MusicSource) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var useSsl = false
    @State private var username = ""
    @State private var password = ""
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
    #if os(macOS)
    /// Captures the URL chosen via NSOpenPanel so we can persist a
    /// security-scoped bookmark once the source has an ID.
    @State private var pendingLocalFolderURL: URL?
    #endif

    @FocusState private var focusedField: SourceFormField?

    private var isEditing: Bool { editingSource != nil }
    private var supportsAPIKeyAuth: Bool { [.jellyfin, .emby, .plex].contains(sourceType) }
    private var validatedPort: Int? {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...65_535).contains(value) else { return nil }
        return value
    }
    private var canSave: Bool {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if sourceType.requiresHost,
           (host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || validatedPort == nil) {
            return false
        }

        guard sourceType.requiresCredentials else {
            return true
        }

        let hasStoredSecret: Bool
        if let editingSource, editingSource.authType == authType {
            hasStoredSecret = (KeychainService.getPassword(for: editingSource.id)?.isEmpty == false)
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
            updateDefaultPortForSSLChange(from: oldValue, to: newValue)
        }
    }

    /// Follow HTTP's 80/443 defaults only while the field still contains the
    /// previous automatic value. A user-entered custom port (for example
    /// MinIO's 9000 or WebDAV 8443) must never be overwritten by the toggle.
    private func updateDefaultPortForSSLChange(from oldValue: Bool, to newValue: Bool) {
        let oldDefault = sourceType.defaultPort(useSsl: oldValue)
        let newDefault = sourceType.defaultPort(useSsl: newValue)
        guard oldDefault != newDefault else { return }
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == String(oldDefault) else { return }
        port = String(newDefault)
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
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") { saveSource() }
                        .disabled(canSave == false)
                        .fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { focusedField = nil } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                    }
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
                Button("cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(PMColor.cardBorder, lineWidth: 0.5) }

                Button("save") { saveSource() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .disabled(canSave == false)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background((canSave ? PMColor.brand : PMColor.textFaint), in: .rect(cornerRadius: 6))
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
        .onAppear { initializeFields() }
    }

    private var macSheetChrome: some View {
        HStack(spacing: 12) {
            PMWindowTrafficLights(closeOnly: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? String(localized: "edit_source") : sourceType.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(isEditing ? "编辑连接信息" : sourceType.displayName)
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
            macSection("connection_info") {
                macTextRow("host_address", text: $host, focus: .host)
                macTextRow("port", text: $port, focus: .port, width: 120)
                if ![MusicSourceType.smb, .ftp, .sftp, .nfs].contains(sourceType) {
                    macToggleRow("use_ssl", isOn: $useSsl)
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
                        .frame(maxWidth: 260)
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

                if isEditing && authType != .none {
                    macInfoRow("password_edit_hint")
                }
            }
        }

        macSection("advanced") {
            if sourceType.isServerLibrary {
                macTextRow("server_base_path_hint", text: $basePath, focus: .basePath)
            }
            macToggleRow("auto_connect", isOn: $autoConnect)
            if sourceType.supports2FA {
                macToggleRow("remember_device", isOn: $rememberDevice)
            }
        }

        if !isEditing && sourceType.requiresHost {
            macSection(nil) {
                Label("save_then_connect_hint", systemImage: "info.circle")
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
            macSection("webdav_config") {
                macTextRow("base_path_hint", text: $basePath, focus: .basePath)
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
                macTextRow("Endpoint", text: $host, focus: .host)
                macTextRow("Region", text: $basePath)
                macTextRow("Bucket", text: $shareName, focus: .shareName)
                macTextRow("Access Key", text: $username, focus: .username)
                macCustomRow("Secret Key") {
                    RevealableSecureField(title: "Secret Key", text: $password)
                        .focused($focusedField, equals: .password)
                        .frame(maxWidth: 280)
                }
                macToggleRow("use_ssl", isOn: $useSsl)
            }
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .pan115, .pan123:
            macSection("cloud_oauth_config") {
                if BuiltInCloudCredentials.hasBuiltIn(for: sourceType) {
                    Label("已内置官方凭证,保存后直接授权即可", systemImage: "checkmark.seal.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(PMColor.ok)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    DisclosureGroup("使用自定义凭证（高级）") {
                        macTextRow("Client ID / App Key", text: $username, focus: .username)
                        macCustomRow("Client Secret") {
                            RevealableSecureField(title: "Client Secret", text: $password)
                                .focused($focusedField, equals: .password)
                                .frame(maxWidth: 280)
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                } else {
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
            .pmCard(cornerRadius: 10)
        }
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
        .frame(minHeight: 42)
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
            Section("connection_info") {
                TextField("host_address", text: $host)
                    .focused($focusedField, equals: .host)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .port }
                TextField("port", text: $port)
                    .focused($focusedField, equals: .port)
                    .keyboardType(.numberPad)
                if ![MusicSourceType.smb, .ftp, .sftp, .nfs].contains(sourceType) {
                    Toggle("use_ssl", isOn: $useSsl)
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
                if isEditing && authType != .none {
                    Text("password_edit_hint").font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        Section("advanced") {
            if sourceType.isServerLibrary {
                TextField("server_base_path_hint", text: $basePath)
                    .focused($focusedField, equals: .basePath)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            Toggle("auto_connect", isOn: $autoConnect)
            if sourceType.supports2FA {
                Toggle("remember_device", isOn: $rememberDevice)
            }
        }

        if !isEditing && sourceType.requiresHost {
            Section {
                Label("save_then_connect_hint", systemImage: "info.circle")
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
            Section("webdav_config") {
                TextField("base_path_hint", text: $basePath)
                    .focused($focusedField, equals: .basePath)
                    .autocorrectionDisabled().submitLabel(.next)
                    .onSubmit { focusedField = .username }
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
                TextField("Endpoint", text: $host, prompt: Text("s3.amazonaws.com"))
                    .focused($focusedField, equals: .host)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
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
                Toggle("use_ssl", isOn: $useSsl)
            }
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .pan115, .pan123:
            Section("cloud_oauth_config") {
                if BuiltInCloudCredentials.hasBuiltIn(for: sourceType) {
                    // Built-in credentials available — no input needed
                    Label("已内置官方凭证，保存后直接授权即可", systemImage: "checkmark.seal.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    // Still allow override if user wants custom credentials
                    DisclosureGroup("使用自定义凭证（高级）") {
                        TextField("Client ID / App Key", text: $username)
                            .focused($focusedField, equals: .username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        RevealableSecureField(title: "Client Secret", text: $password)
                            .focused($focusedField, equals: .password)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
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
        if let s = editingSource {
            name = s.name; host = s.host ?? ""; port = "\(s.port ?? sourceType.defaultPort)"
            useSsl = s.useSsl; username = s.username ?? ""; basePath = s.basePath ?? ""
            shareName = s.shareName ?? ""; exportPath = s.exportPath ?? ""
            authType = s.authType; autoConnect = s.autoConnect; rememberDevice = s.rememberDevice
            // 兼容旧版“账号密码都留空即匿名”的来源记录。旧记录的 authType
            // 仍可能是 password；迁移成显式访客模式后才能正确清理/忽略旧凭据。
            if sourceType.supportsAnonymous,
               username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               (KeychainService.getPassword(for: s.id) ?? "").isEmpty {
                authType = .none
            }
            ftpEncryption = s.ftpEncryption ?? .none; nfsVersion = s.nfsVersion ?? .auto
        } else if let device = prefillDevice {
            name = device.name
            host = device.host
            port = "\(device.port)"
            useSsl = device.preferredUseSsl ?? sourceType.defaultSSL
            if sourceType == .plex {
                authType = .apiKey
            } else if [.local, .appleMusicLibrary, .nfs, .upnp].contains(sourceType) {
                authType = .none
            }
        } else {
            name = sourceType.displayName
            port = "\(sourceType.defaultPort)"
            useSsl = sourceType.defaultSSL
            if sourceType == .plex {
                authType = .apiKey
            } else if [.local, .appleMusicLibrary, .nfs, .upnp].contains(sourceType) {
                authType = .none
            }
        }
        isInitialized = true
    }

    private func saveSource() {
        // 去除首尾空白/换行: 避免用户名密码混入不可见字符导致 NAS / 服务器认证失败。
        let username = self.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = self.password.trimmingCharacters(in: .whitespacesAndNewlines)

        // S3 special mapping: host=endpoint, basePath=bucket, shareName→basePath,
        // extraConfig=JSON{region, dirs} (region + scanned-directory list).
        let finalHost: String?
        let finalBasePath: String?
        let finalShareName: String?
        let finalUsername: String?
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
            finalUsername = username.isEmpty ? nil : username  // client_id
        } else {
            finalHost = sourceType.requiresHost ? host : nil
            finalBasePath = basePath.isEmpty ? nil : basePath
            finalShareName = shareName.isEmpty ? nil : shareName
            finalUsername = sourceType.requiresCredentials && authType != .apiKey && authType != .none
                ? (username.isEmpty ? nil : username)
                : nil
        }

        let source = MusicSource(
            id: editingSource?.id ?? UUID().uuidString,
            name: name, type: sourceType,
            host: finalHost, port: sourceType.requiresHost ? validatedPort : nil, useSsl: useSsl,
            username: finalUsername,
            basePath: finalBasePath,
            shareName: finalShareName,
            exportPath: exportPath.isEmpty ? nil : exportPath,
            authType: sourceType.isCloudDrive ? .oauth : authType,
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
            isDeleted: editingSource?.isDeleted ?? false,
            deletedAt: editingSource?.deletedAt,
            cloudAccountID: editingSource?.cloudAccountID
        )

        // Save credentials
        if sourceType.isCloudDrive {
            // Store client_id + client_secret via CloudTokenManager
            let tm = CloudTokenManager(sourceID: source.id)
            Task {
                if !username.isEmpty {
                    await tm.saveAppCredentials(.init(
                        clientId: username,
                        clientSecret: password.isEmpty ? nil : password
                    ))
                } else {
                    await tm.deleteAppCredentials()
                }
            }
        } else if authType == .none {
            // 从账号登录切换到访客模式时必须删除旧 Keychain 项；否则连接器仍会
            // 读到旧密码，表面显示“访客”却继续以旧账号认证。
            KeychainService.deletePassword(for: source.id)
        } else if sourceType == .s3 || authType == .password || authType == .apiKey || authType == .cookie || authType == .oauth {
            if !password.isEmpty {
                KeychainService.setPassword(password, for: source.id)
            }
        } else if authType == .sshKey {
            let trimmedKey = sshKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                KeychainService.setPassword(trimmedKey, for: source.id)
            }
        }

        #if os(macOS)
        if sourceType == .local, let pickedURL = pendingLocalFolderURL {
            try? LocalBookmarkStore.save(sourceID: source.id, url: pickedURL)
        }
        #endif

        onSave(source)
        dismiss()
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
