import SwiftUI
import PrimuseKit

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

    @FocusState private var focusedField: SourceFormField?

    private var isEditing: Bool { editingSource != nil }
    private var supportsAPIKeyAuth: Bool { [.jellyfin, .emby, .plex].contains(sourceType) }

    var body: some View {
        NavigationStack {
            Form {
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
                            .onSubmit { focusedField = sourceType == .smb ? .shareName : .port }
                        if sourceType != .smb {
                            TextField("port", text: $port)
                                .focused($focusedField, equals: .port)
                                .keyboardType(.numberPad)
                        }
                        if ![MusicSourceType.smb, .ftp, .sftp, .nfs].contains(sourceType) {
                            Toggle("use_ssl", isOn: $useSsl)
                        }
                    }
                }

                typeSpecificSection

                if sourceType.requiresCredentials {
                    Section("credentials") {
                        if sourceType == .sftp || supportsAPIKeyAuth {
                            Picker("auth_method", selection: $authType) {
                                Text("password").tag(SourceAuthType.password)
                                if supportsAPIKeyAuth {
                                    Text("api_key").tag(SourceAuthType.apiKey)
                                } else {
                                    Text("ssh_key").tag(SourceAuthType.sshKey)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        if authType != .apiKey {
                            TextField("username", text: $username)
                                .focused($focusedField, equals: .username)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .password }
                        }
                        if authType == .sshKey && sourceType == .sftp {
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
                            SecureField(authType == .apiKey ? "api_key" : "password", text: $password)
                                .focused($focusedField, equals: .password)
                                .submitLabel(.done)
                                .onSubmit { focusedField = nil }
                        }
                        if isEditing {
                            Text("password_edit_hint").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("advanced") {
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
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(isEditing ? String(localized: "edit_source") : sourceType.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") { saveSource() }
                        .disabled(name.isEmpty || (sourceType.requiresHost && host.isEmpty))
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
        case .jellyfin, .emby, .plex:
            Section("server_config") {
                TextField("base_path_hint", text: $basePath)
                    .focused($focusedField, equals: .basePath)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .onSubmit {
                        focusedField = authType == .apiKey ? .password : .username
                    }
            }
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
            ftpEncryption = s.ftpEncryption ?? .none; nfsVersion = s.nfsVersion ?? .auto
        } else {
            name = sourceType.displayName
            port = "\(sourceType.defaultPort)"
            useSsl = sourceType.defaultSSL
            if sourceType == .plex {
                authType = .apiKey
            }
        }
        isInitialized = true
    }

    private func saveSource() {
        let source = MusicSource(
            id: editingSource?.id ?? UUID().uuidString,
            name: name, type: sourceType,
            host: sourceType.requiresHost ? host : nil, port: Int(port), useSsl: useSsl,
            username: sourceType.requiresCredentials && authType != .apiKey ? username : nil,
            basePath: basePath.isEmpty ? nil : basePath,
            shareName: shareName.isEmpty ? nil : shareName,
            exportPath: exportPath.isEmpty ? nil : exportPath,
            authType: authType,
            ftpEncryption: sourceType == .ftp ? ftpEncryption : nil,
            nfsVersion: sourceType == .nfs ? nfsVersion : nil,
            autoConnect: autoConnect, rememberDevice: rememberDevice,
            deviceId: editingSource?.deviceId,
            extraConfig: editingSource?.extraConfig
        )
        if !password.isEmpty { KeychainService.setPassword(password, for: source.id) }
        onSave(source)
        dismiss()
    }
}
