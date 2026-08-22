#if os(tvOS)
import PrimuseKit
import SwiftUI

// TV 端「添加 / 编辑音乐源」全屏流程,对照 design/猿音/scenes/tvos.jsx 的
// TVConnectSourceArtboard(协议选择)/ TVConnectFormArtboard(凭据表单)/ TVTwoFactorArtboard(OTP)。
// 文案中文优先(TODO localize)。

/// 表单的 Identifiable 载体:editing == nil 为新增(可带内网发现预填的 host/port/name)。
struct TVSourceForm: Identifiable {
    let id = UUID()
    var editing: MusicSource?
    var type: MusicSourceType
    var prefillHost: String? = nil
    var prefillPort: Int? = nil
    var prefillName: String? = nil
    var prefillUseSsl: Bool? = nil
}

// MARK: - 第 1 步:选择服务类型(全屏玻璃态网格)

struct TVSourceTypePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TVStore.self) private var store
    /// (类型, 可选预填 host/port/name/SSL) —— 内网发现的设备会带预填。
    let onPick: (
        MusicSourceType,
        (host: String, port: Int, name: String, useSsl: Bool?)?
    ) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 24), count: 5)

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: Color(hex: "#1f3a5b"), strength: 0.4)
            TVColor.bg.opacity(0.42).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: PMString("ext.tv.sources.add.step1")).padding(.bottom, 8)
                    Text(PMString("ext.tv.sources.chooseType"))
                        .font(.system(size: 52, weight: .bold)).foregroundStyle(TVColor.text)
                        .padding(.bottom, 8)
                    Text(PMString("ext.tv.sources.chooseTypeBody"))
                        .font(.system(size: 20)).foregroundStyle(TVColor.textFaint)
                        .frame(maxWidth: 1100, alignment: .leading).padding(.bottom, 36)

                    // 内网自动发现的设备(Bonjour)优先展示。
                    if !store.discoveredDevices.isEmpty {
                        TVEyebrow(text: PMString("ext.tv.sources.discovered")).padding(.bottom, 14)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                            ForEach(store.discoveredDevices) { d in
                                typeCard(icon: d.sourceType.iconName, label: d.name,
                                         hint: d.sourceType.isAwaitingPublicAPI ? d.sourceType.subtitle : "\(d.host):\(d.port)",
                                         badge: d.sourceType.isAwaitingPublicAPI
                                             ? PMString("ext.tv.sources.apiPending")
                                             : Self.shortProtocol(d.sourceType),
                                         accentIcon: true,
                                         isEnabled: !d.sourceType.isAwaitingPublicAPI) {
                                    onPick(d.sourceType, (d.host, d.port, d.name, d.preferredUseSsl))
                                }
                            }
                        }
                        .padding(.bottom, 34)
                    }

                    TVEyebrow(text: PMString("ext.tv.sources.allTypes")).padding(.bottom, 14)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(Array(TVStore.addableTypes.enumerated()), id: \.element) { idx, t in
                            typeCard(icon: t.iconName, label: t.displayName, hint: Self.hint(for: t),
                                     badge: t.isAwaitingPublicAPI ? PMString("ext.tv.sources.apiPending") : nil,
                                     accentIcon: idx == 0,
                                     isEnabled: !t.isAwaitingPublicAPI) { onPick(t, nil) }
                        }
                    }
                    Text(PMString("ext.tv.sources.chooseTypeFooter"))
                        .font(.system(size: 16)).foregroundStyle(TVColor.textGhost).padding(.top, 36)
                }
                .padding(.horizontal, 120).padding(.vertical, 90)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { store.startDeviceDiscovery() }
        .onDisappear { store.stopDeviceDiscovery() }
    }

    private func typeCard(icon: String, label: String, hint: String, badge: String? = nil,
                          accentIcon: Bool, isEnabled: Bool = true,
                          action: @escaping () -> Void) -> some View {
        TVFocusButton(radius: 16, scale: 1.08, lift: 10, action: action) { focused in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: icon).font(.system(size: 24, weight: .semibold))
                        .foregroundStyle((focused || accentIcon) ? TVColor.onBrand : TVColor.text).frame(width: 52, height: 52)
                        .background((focused || accentIcon) ? TVColor.brand : TVColor.surfaceStrong,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Spacer(minLength: 0)
                    if let badge {
                        // 内网发现的设备靠这个文字徽标区分协议(SMB/WebDAV 图标相近)。
                        Text(badge).font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(TVColor.onBrand)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(TVColor.brand, in: Capsule())
                    }
                }
                Spacer(minLength: 16)
                Text(label).font(.system(size: 22, weight: .bold))
                    .foregroundStyle(TVColor.text).lineLimit(1)
                Text(hint).font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(TVColor.textMuted).lineLimit(1)
            }
            .padding(22).frame(height: 178, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? TVColor.cardElev : TVColor.card)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.58)
    }

    static func shortProtocol(_ t: MusicSourceType) -> String {
        switch t {
        case .smb: return "SMB"
        case .webdav: return "WebDAV"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        case .nfs: return "NFS"
        case .synology: return "Synology"
        case .qnap: return "QNAP"
        case .fnos: return "fnOS"
        case .fnMusic, .daoliyu, .ugreen: return t.displayName
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        case .subsonic, .navidrome, .airsonic, .gonic: return "Subsonic"
        default: return t.rawValue.uppercased()
        }
    }

    static func hint(for t: MusicSourceType) -> String {
        if t.isAwaitingPublicAPI { return t.subtitle }
        switch t {
        case .smb: return PMString("ext.tv.sources.hint.smb")
        case .webdav: return PMString("ext.tv.sources.hint.webdav")
        case .ftp: return "FTP / FTPS"
        case .sftp: return PMString("ext.tv.sources.hint.sftp")
        case .nfs: return PMString("ext.tv.sources.hint.nfs")
        case .jellyfin, .emby, .plex: return PMString("ext.tv.sources.hint.mediaServer")
        case .subsonic, .navidrome, .airsonic, .gonic:
            return PMString("ext.tv.sources.hint.subsonic")
        case .fnMusic: return PMString("ext.tv.sources.hint.fnMusic")
        case .daoliyu: return PMString("ext.tv.sources.hint.daoliyu")
        case .synology, .qnap, .fnos, .ugreen:
            return PMString("ext.tv.sources.hint.nasSuite")
        default: return t.category.displayName
        }
    }
}

// MARK: - 第 2 步:填写连接信息(双栏)

struct TVSourceFormView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let editing: MusicSource?
    let type: MusicSourceType
    var prefillHost: String? = nil
    var prefillPort: Int? = nil
    var prefillName: String? = nil
    var prefillUseSsl: Bool? = nil

    @State private var name = ""
    @State private var host = ""
    @State private var portText = ""
    @State private var useSsl = false
    @State private var publicHost = ""
    @State private var publicPortText = ""
    @State private var publicUseSsl = true
    @State private var localPathPrefix = ""
    @State private var publicPathPrefix = ""
    @State private var vendorIdentifier = ""
    @State private var synologyConnectionMode: SynologyConnectionMode = .quickConnect
    @State private var fnMusicConnectionMode: FnMusicConnectionMode = .fnConnect
    @State private var username = ""
    @State private var password = ""
    @State private var fnConnectAccessCode = ""
    @State private var useGuestAccess = false
    @State private var pathText = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var saveFailed = false

    private var showsSSL: Bool { type.category == .mediaServer || type.category == .nas || type == .webdav }
    private var supportsAdaptiveConnections: Bool { type.supportsAdaptiveConnections }
    private var showsAuth: Bool { type != .nfs }
    private var validatedPort: Int? {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...65_535).contains(value) else { return nil }
        return value
    }
    private var validatedPublicPort: Int? {
        let trimmed = publicPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...65_535).contains(value) else { return nil }
        return value
    }
    private var remoteUsesVendor: Bool {
        if type == .synology { return synologyConnectionMode == .quickConnect }
        if type == .fnMusic { return fnMusicConnectionMode == .fnConnect }
        return false
    }
    private var localEndpointIsValid: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && validatedPort != nil
    }
    private var publicEndpointIsValid: Bool {
        !publicHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validatedPublicPort != nil
    }
    private var vendorIdentifierIsValid: Bool {
        let value = vendorIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == .synology { return SynologyQuickConnectResolver.isValidQuickConnectID(value) }
        if type == .fnMusic { return FnConnectResolver.isValidFNID(value) }
        return false
    }
    private var activeRemoteEndpointIsValid: Bool {
        remoteUsesVendor ? vendorIdentifierIsValid : publicEndpointIsValid
    }
    private var adaptiveConnectionIsValid: Bool {
        let localConfigured = !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let publicConfigured = !publicHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let vendorConfigured = !vendorIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if localConfigured && validatedPort == nil { return false }
        if !remoteUsesVendor, publicConfigured && validatedPublicPort == nil { return false }
        if remoteUsesVendor, vendorConfigured && !vendorIdentifierIsValid { return false }
        return localEndpointIsValid || activeRemoteEndpointIsValid
    }
    private var canSave: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let legacyConnectionIsValid = !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ((type == .synology && synologyConnectionMode == .quickConnect)
                ? SynologyQuickConnectResolver.isValidQuickConnectID(host)
                : ((type == .fnMusic && fnMusicConnectionMode == .fnConnect)
                    ? FnConnectResolver.isValidFNID(host)
                    : validatedPort != nil))
        let connectionIsValid = hasName
            && (supportsAdaptiveConnections ? adaptiveConnectionIsValid : legacyConnectionIsValid)
        guard connectionIsValid else { return false }
        if type == .fnMusic || type == .daoliyu {
            guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            if editing == nil && password.isEmpty { return false }
        }
        if type.supportsAnonymous && !useGuestAccess {
            guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if editing == nil && password.isEmpty { return false }
        }
        return true
    }
    private var pathLabel: String {
        switch type {
        case .smb: return PMString("ext.tv.sources.form.share")
        case .nfs: return PMString("ext.tv.sources.form.exportPath")
        default: return PMString("ext.tv.sources.form.basePath")
        }
    }
    private var connectionAddressLabel: String {
        if type == .nfs { return PMString("ext.tv.sources.form.serverAddress") }
        if type == .synology {
            switch synologyConnectionMode {
            case .quickConnect: return PMString("synology_quickconnect_id")
            case .address: return PMString("synology_address")
            }
        }
        if type == .fnMusic, fnMusicConnectionMode == .fnConnect {
            return PMString("fnmusic_fnid")
        }
        return PMString("ext.tv.sources.form.host")
    }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: Color(hex: "#1f3a5b"), strength: 0.4)
            TVColor.bg.opacity(0.42).ignoresSafeArea()
            // 只让左列字段在自己列里滚动;右列作为撑满高度的固定侧栏,从任意字段往右都能到达
            //(右侧焦点区 frame 必须满高,否则下方字段往右无候选)。
            HStack(alignment: .top, spacing: 90) {
                ScrollView(.vertical, showsIndicators: false) {
                    leftFields
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 96)
                }
                .focusSection()
                rightPanel
                    .frame(width: 360)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .focusSection()
            }
            .padding(.horizontal, 120).padding(.vertical, 80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear(perform: prefill)
        .onChange(of: useSsl) { oldValue, newValue in
            updateDefaultPortForSSLChange(
                port: $portText,
                from: oldValue,
                to: newValue
            )
        }
        .onChange(of: publicUseSsl) { oldValue, newValue in
            updateDefaultPortForSSLChange(
                port: $publicPortText,
                from: oldValue,
                to: newValue
            )
        }
        .onChange(of: synologyConnectionMode) { _, newValue in
            guard !supportsAdaptiveConnections,
                  type == .synology,
                  newValue == .quickConnect else { return }
            useSsl = true
            portText = String(MusicSourceType.synology.defaultPort(useSsl: true))
        }
        .onChange(of: fnMusicConnectionMode) { _, newValue in
            guard !supportsAdaptiveConnections,
                  type == .fnMusic,
                  newValue == .fnConnect else { return }
            useSsl = true
        }
        .alert(PMString("ext.tv.sources.cred.saveFailedTitle"), isPresented: $saveFailed) {
            Button(PMString("ext.tv.sources.ok"), role: .cancel) {}
        } message: {
            Text(PMString("ext.tv.sources.cred.saveFailedBody"))
        }
    }

    private func updateDefaultPortForSSLChange(
        port: Binding<String>,
        from oldValue: Bool,
        to newValue: Bool
    ) {
        let oldDefault = type.defaultPort(useSsl: oldValue)
        let newDefault = type.defaultPort(useSsl: newValue)
        guard oldDefault != newDefault else { return }
        let trimmed = port.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == String(oldDefault) else { return }
        port.wrappedValue = String(newDefault)
    }

    private var leftFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Image(systemName: type.iconName).font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(LinearGradient(colors: [TVColor.brand, .black.opacity(0.5)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    TVEyebrow(
                        text: editing == nil
                            ? PMString("ext.tv.sources.add.step2")
                            : PMString("ext.tv.sources.editConnection")
                    )
                    Text(PMString("ext.tv.sources.connectionTitle", type.displayName))
                        .font(.system(size: 36, weight: .bold)).foregroundStyle(TVColor.text)
                }
            }
            .padding(.bottom, 8)

            TVFormField(label: PMString("ext.tv.sources.form.name"), text: $name, autofocus: true)
            if supportsAdaptiveConnections {
                adaptiveConnectionFields
            } else {
                if type == .synology {
                    Picker(PMString("synology_connection_method"), selection: $synologyConnectionMode) {
                        Text(PMString("synology_connection_quickconnect"))
                            .tag(SynologyConnectionMode.quickConnect)
                        Text(PMString("synology_connection_address"))
                            .tag(SynologyConnectionMode.address)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 720)
                }
                if type == .fnMusic {
                    Picker(PMString("fnmusic_connection_method"), selection: $fnMusicConnectionMode) {
                        Text(PMString("fnmusic_connection_fnconnect"))
                            .tag(FnMusicConnectionMode.fnConnect)
                        Text(PMString("fnmusic_connection_address"))
                            .tag(FnMusicConnectionMode.address)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 720)
                }
                TVFormField(label: connectionAddressLabel, text: $host, mono: true)
                if type == .synology, synologyConnectionMode == .quickConnect {
                    connectionHint("synology_quickconnect_hint")
                } else if type == .fnMusic, fnMusicConnectionMode == .fnConnect {
                    connectionHint("fnmusic_fnconnect_hint")
                } else {
                    TVFormField(label: PMString("ext.tv.sources.form.port"), text: $portText, mono: true)
                }
                if showsSSL
                    && !(type == .synology && synologyConnectionMode == .quickConnect)
                    && !(type == .fnMusic && fnMusicConnectionMode == .fnConnect) {
                    connectionSSLToggle(isOn: $useSsl)
                }
            }
            if showsAuth {
                if type.supportsAnonymous {
                    Toggle(isOn: $useGuestAccess) {
                        Label(PMString("ext.tv.sources.form.guest"), systemImage: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 21, weight: .medium)).foregroundStyle(TVColor.text)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 14).frame(maxWidth: 720, alignment: .leading)
                    .background(TVColor.surfaceSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if !useGuestAccess {
                    TVFormField(label: PMString("ext.tv.sources.cred.username"), text: $username, mono: true)
                    TVFormField(
                        label: editing == nil
                            ? PMString("ext.tv.sources.cred.password")
                            : PMString("ext.tv.sources.form.passwordKeep"),
                        text: $password,
                        secure: true
                    )
                    if type == .fnMusic {
                        Text(PMString("fnmusic_account_hint"))
                            .font(.system(size: 16))
                            .foregroundStyle(TVColor.textFaint)
                        if fnMusicConnectionMode == .fnConnect {
                            TVFormField(
                                label: PMString("fnmusic_access_code"),
                                text: $fnConnectAccessCode,
                                secure: true
                            )
                            Text(PMString("fnmusic_access_code_hint"))
                                .font(.system(size: 16))
                                .foregroundStyle(TVColor.textFaint)
                        }
                    }
                }
            }
            if type != .fnMusic && !type.supportsEndpointSpecificPath {
                TVFormField(label: pathLabel, text: $pathText, mono: true)
            }

            HStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.system(size: 15)).foregroundStyle(TVColor.brand)
                Text(PMString("ext.tv.sources.form.passwordStorage"))
                    .font(.system(size: 16)).foregroundStyle(TVColor.textFaint)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder
    private var adaptiveConnectionFields: some View {
        connectionHint("source_connection_intro")

        TVEyebrow(text: PMString("source_connection_local_optional"))
        TVFormField(label: PMString("source_connection_local_address"), text: $host, mono: true)
        TVFormField(label: PMString("source_connection_local_port"), text: $portText, mono: true)
        if showsSSL { connectionSSLToggle(isOn: $useSsl) }
        if type.supportsEndpointPathPrefix {
            TVFormField(
                label: PMString("source_connection_path_prefix"),
                text: $localPathPrefix,
                mono: true
            )
        }

        TVEyebrow(text: PMString("source_connection_remote_optional"))
        if type == .synology {
            Picker(PMString("source_connection_remote_method"), selection: $synologyConnectionMode) {
                Text(PMString("source_connection_public_direct"))
                    .tag(SynologyConnectionMode.address)
                Text(PMString("synology_connection_quickconnect"))
                    .tag(SynologyConnectionMode.quickConnect)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 720)
        } else if type == .fnMusic {
            Picker(PMString("source_connection_remote_method"), selection: $fnMusicConnectionMode) {
                Text(PMString("source_connection_public_direct"))
                    .tag(FnMusicConnectionMode.address)
                Text(PMString("fnmusic_connection_fnconnect"))
                    .tag(FnMusicConnectionMode.fnConnect)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 720)
        }

        if remoteUsesVendor {
            TVFormField(
                label: PMString(type == .synology ? "synology_quickconnect_id" : "fnmusic_fnid"),
                text: $vendorIdentifier,
                mono: true
            )
            connectionHint(type == .synology ? "synology_quickconnect_hint" : "fnmusic_fnconnect_hint")
        } else {
            TVFormField(
                label: PMString("source_connection_public_address"),
                text: $publicHost,
                mono: true
            )
            TVFormField(
                label: PMString("source_connection_public_port"),
                text: $publicPortText,
                mono: true
            )
            if showsSSL { connectionSSLToggle(isOn: $publicUseSsl) }
            if type.supportsEndpointPathPrefix {
                TVFormField(
                    label: PMString("source_connection_path_prefix"),
                    text: $publicPathPrefix,
                    mono: true
                )
            }
            connectionHint("source_connection_public_hint")
        }
    }

    private func connectionHint(_ key: String) -> some View {
        Text(PMString(key))
            .font(.system(size: 16))
            .foregroundStyle(TVColor.textFaint)
            .frame(maxWidth: 720, alignment: .leading)
    }

    private func connectionSSLToggle(isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(PMString("ext.tv.sources.form.useSSL"), systemImage: "lock.shield")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(TVColor.text)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: 720, alignment: .leading)
        .background(
            TVColor.surfaceSubtle,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private var rightPanel: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Image(systemName: "keyboard").font(.system(size: 44)).foregroundStyle(TVColor.text)
                Text(PMString("ext.tv.sources.form.iphoneInput"))
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(TVColor.text)
                Text(PMString("ext.tv.sources.form.iphoneInputBody"))
                    .font(.system(size: 16)).foregroundStyle(TVColor.textFaint)
                    .multilineTextAlignment(.center).lineSpacing(4)
            }
            .padding(28).frame(maxWidth: .infinity)
            .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(TVColor.cardBorder, lineWidth: 0.5) }

            if let testResult {
                Text(testResult).font(.system(size: 16)).foregroundStyle(TVColor.textMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }

            HStack(spacing: 14) {
                TVFocusButton(radius: 14, scale: 1.04, lift: 0, action: runTest) { f in
                    Group {
                        if testing { ProgressView().tint(TVColor.brand) }
                        else { Text(PMString("ext.tv.sources.testConnection")) }
                    }
                        .font(.system(size: 20, weight: .medium)).foregroundStyle(TVColor.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(f ? TVColor.surfaceStrong : TVColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!canSave || testing)
                TVFocusButton(radius: 14, accent: TVColor.brand, scale: 1.05, lift: 0, action: save) { f in
                    Text(
                        editing == nil
                            ? PMString("ext.tv.sources.form.add")
                            : PMString("ext.tv.sources.form.save")
                    )
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(canSave ? TVColor.onBrand : TVColor.textGhost)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(canSave ? TVColor.brand.opacity(f ? 1 : 0.88) : TVColor.surface,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!canSave)
            }
            TVFocusButton(radius: 14, scale: 1.04, lift: 0, action: { dismiss() }) { f in
                Text(PMString("ext.tv.sources.cancel"))
                    .font(.system(size: 19, weight: .medium)).foregroundStyle(TVColor.text)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(f ? TVColor.surfaceStrong : TVColor.surfaceSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func prefill() {
        useSsl = type.defaultSSL
        portText = String(type.defaultPort(useSsl: useSsl))
        publicUseSsl = showsSSL ? true : type.defaultSSL
        publicPortText = String(type.defaultPort(useSsl: publicUseSsl))

        if let e = editing {
            name = e.name
            username = e.username ?? ""
            if supportsAdaptiveConnections {
                let configuration = e.effectiveConnectionConfiguration
                    ?? SourceConnectionConfiguration()
                if let endpoint = configuration.localEndpoint {
                    host = endpoint.host
                    portText = String(endpoint.port)
                    useSsl = endpoint.useSsl
                    localPathPrefix = endpoint.pathPrefix ?? ""
                }
                if let endpoint = configuration.publicEndpoint {
                    publicHost = endpoint.host
                    publicPortText = String(endpoint.port)
                    publicUseSsl = endpoint.useSsl
                    publicPathPrefix = endpoint.pathPrefix ?? ""
                }
                vendorIdentifier = configuration.vendorIdentifier ?? ""
                if type == .synology {
                    synologyConnectionMode = configuration.remoteAccessMode == .vendor
                        ? .quickConnect
                        : .address
                } else if type == .fnMusic {
                    fnMusicConnectionMode = configuration.remoteAccessMode == .vendor
                        ? .fnConnect
                        : .address
                }
            } else {
                host = e.host ?? ""
                portText = String(e.port ?? type.defaultPort)
                useSsl = e.useSsl
                if type == .synology {
                    synologyConnectionMode = e.effectiveSynologyConnectionMode
                }
                if type == .fnMusic {
                    fnMusicConnectionMode = e.effectiveFnMusicConnectionMode
                }
            }
            useGuestAccess = type.supportsAnonymous && e.authType == .none
            switch type {
            case .smb: pathText = e.shareName ?? ""
            case .nfs: pathText = e.exportPath ?? ""
            default: pathText = e.basePath ?? ""
            }
        } else {
            host = prefillHost ?? ""
            useSsl = prefillUseSsl ?? type.defaultSSL
            portText = String(prefillPort ?? type.defaultPort(useSsl: useSsl))
            name = prefillName ?? type.displayName
            if type == .synology {
                if let prefillHost, !prefillHost.isEmpty {
                    synologyConnectionMode = .address
                } else {
                    synologyConnectionMode = .quickConnect
                    useSsl = true
                    portText = String(type.defaultPort(useSsl: true))
                }
            }
            if type == .fnMusic {
                if let prefillHost, !prefillHost.isEmpty {
                    fnMusicConnectionMode = .address
                } else {
                    fnMusicConnectionMode = .fnConnect
                    useSsl = true
                }
            }
        }
    }

    private func runTest() {
        guard canSave, let source = draftSource() else { return }
        let draftPassword = password.isEmpty ? nil : password
        testing = true; testResult = nil
        Task {
            testResult = await store.testConnection(
                source: source,
                password: draftPassword
            )
            testing = false
        }
    }

    private func draftSource() -> MusicSource? {
        guard canSave else { return nil }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let trimmedPath = pathText.trimmingCharacters(in: .whitespaces)

        var src = editing ?? MusicSource(name: trimmedName, type: type)
        src.name = trimmedName
        if supportsAdaptiveConnections {
            src.connectionConfiguration = adaptiveConnectionConfiguration()
            src.synologyConnectionMode = type == .synology ? synologyConnectionMode : nil
            src.fnMusicConnectionMode = type == .fnMusic ? fnMusicConnectionMode : nil
            src = src.projectingPreferredConnectionForLegacy()
        } else {
            if type == .synology, synologyConnectionMode == .quickConnect {
                src.host = SynologyQuickConnectResolver.quickConnectID(from: trimmedHost)
            } else if type == .fnMusic, fnMusicConnectionMode == .fnConnect {
                src.host = FnConnectResolver.fnID(from: trimmedHost)
            } else {
                src.host = trimmedHost
            }
            let usesResolvedConnection = (type == .synology && synologyConnectionMode == .quickConnect)
                || (type == .fnMusic && fnMusicConnectionMode == .fnConnect)
            src.port = usesResolvedConnection ? type.defaultPort(useSsl: true) : validatedPort
            src.useSsl = usesResolvedConnection ? true : (showsSSL ? useSsl : type.defaultSSL)
            src.synologyConnectionMode = type == .synology ? synologyConnectionMode : nil
            src.fnMusicConnectionMode = type == .fnMusic ? fnMusicConnectionMode : nil
        }
        if showsAuth {
            src.username = useGuestAccess ? nil : (trimmedUser.isEmpty ? nil : trimmedUser)
            src.authType = useGuestAccess ? .none : .password
        } else {
            src.username = nil; src.authType = .none
        }
        switch type {
        case .smb: src.shareName = trimmedPath.isEmpty ? nil : trimmedPath
        case .nfs: src.exportPath = trimmedPath.isEmpty ? nil : trimmedPath
        default:
            if !type.supportsEndpointSpecificPath {
                src.basePath = type == .fnMusic && fnMusicConnectionMode == .fnConnect
                    ? nil
                    : (trimmedPath.isEmpty ? nil : trimmedPath)
            }
        }
        src.modifiedAt = Date()
        return src
    }

    private func adaptiveConnectionConfiguration() -> SourceConnectionConfiguration {
        let localAddress = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicAddress = publicHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let localEndpoint = localAddress.isEmpty ? nil : validatedPort.map {
            SourceConnectionEndpoint(
                host: localAddress,
                port: $0,
                useSsl: useSsl,
                pathPrefix: type.supportsEndpointPathPrefix
                    ? normalizedPath(localPathPrefix)
                    : nil
            ).normalized
        }
        let publicEndpoint = publicAddress.isEmpty ? nil : validatedPublicPort.map {
            SourceConnectionEndpoint(
                host: publicAddress,
                port: $0,
                useSsl: publicUseSsl,
                pathPrefix: type.supportsEndpointPathPrefix
                    ? normalizedPath(publicPathPrefix)
                    : nil
            ).normalized
        }

        let rawVendorID = vendorIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedVendorID: String?
        if rawVendorID.isEmpty {
            normalizedVendorID = nil
        } else if type == .synology {
            normalizedVendorID = SynologyQuickConnectResolver.quickConnectID(from: rawVendorID)
                ?? rawVendorID
        } else if type == .fnMusic {
            normalizedVendorID = FnConnectResolver.fnID(from: rawVendorID) ?? rawVendorID
        } else {
            normalizedVendorID = nil
        }

        return SourceConnectionConfiguration(
            localEndpoint: localEndpoint,
            publicEndpoint: publicEndpoint,
            remoteAccessMode: remoteUsesVendor ? .vendor : .direct,
            vendorIdentifier: normalizedVendorID
        )
    }

    private func normalizedPath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func save() {
        guard let src = draftSource() else { return }

        let passwordToSave = useGuestAccess || password.isEmpty ? nil : password
        let accessCodeToSave = type == .fnMusic
            && fnMusicConnectionMode == .fnConnect
            && !fnConnectAccessCode.isEmpty
            ? fnConnectAccessCode
            : nil
        let didSave = editing == nil
            ? store.addSource(src, password: passwordToSave, fnConnectAccessCode: accessCodeToSave)
            : store.updateSource(src, password: passwordToSave, fnConnectAccessCode: accessCodeToSave)
        guard didSave else {
            saveFailed = true
            return
        }
        dismiss()
    }
}

// MARK: - 文本字段(单层原生输入框)

/// 单层原生输入框:tvOS 的 `TextField` / `SecureField` 自带一个圆角输入框,聚焦后唤起系统
/// 键盘。之前用「自绘底框 + 近透明真 TextField」叠出暗色样式,会出现「大框套小框」且高度异常,
/// 故改为直接使用原生输入框本身作为唯一的框,标题在上方。
struct TVFormField: View {
    let label: String
    @Binding var text: String
    var secure: Bool = false
    var mono: Bool = false
    var autofocus: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 16)).foregroundStyle(TVColor.textFaint)
            Group {
                if secure { SecureField("", text: $text) }
                else { TextField("", text: $text) }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.system(size: 24, weight: .medium, design: mono ? .monospaced : .default))
            .frame(maxWidth: 720, alignment: .leading)
            .focused($focused)
        }
        .onAppear { if autofocus { focused = true } }
    }
}

// MARK: - 两步验证(6 格 OTP + 数字键盘)

struct TVOTPEntryView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: TVSource

    @State private var code = ""
    @State private var error: String?
    @State private var busy = false

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "✓"]

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: Color(hex: "#264a6e"), strength: 0.45)
            TVColor.bg.opacity(0.38).ignoresSafeArea()
            HStack(alignment: .center, spacing: 100) {
                leftPrompt
                numberPad
            }
            .padding(.horizontal, 120).padding(.vertical, 90)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var leftPrompt: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: "lock.shield.fill").font(.system(size: 30, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(LinearGradient(colors: [Color(hex: "#4d9a4d"), Color(hex: "#2a6a2a")],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.bottom, 24)
            TVEyebrow(text: PMString("ext.tv.otp.title", source.name)).padding(.bottom, 8)
            Text(PMString("ext.tv.otp.enterCode"))
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(TVColor.text)
                .padding(.bottom, 16)
            Text(PMString("ext.tv.otp.body"))
                .font(.system(size: 20)).foregroundStyle(TVColor.textMuted)
                .frame(maxWidth: 520, alignment: .leading).lineSpacing(5).padding(.bottom, 36)

            HStack(spacing: 14) {
                ForEach(0..<6, id: \.self) { i in
                    let ch = i < code.count ? String(Array(code)[i]) : ""
                    Text(ch.isEmpty ? "·" : ch)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundStyle(ch.isEmpty ? TVColor.textGhost : TVColor.text)
                        .frame(width: 72, height: 92)
                        .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(i == code.count ? TVColor.brand : TVColor.cardBorder,
                                              lineWidth: i == code.count ? 3 : 0.5)
                        }
                }
            }
            if let error {
                Text(error).font(.system(size: 17)).foregroundStyle(TVColor.bad).padding(.top, 24)
            } else if busy {
                HStack(spacing: 12) {
                    ProgressView().tint(TVColor.brand)
                    Text(PMString("ext.tv.otp.verifying")).foregroundStyle(TVColor.textFaint)
                }
                    .padding(.top, 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var numberPad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(100), spacing: 16), count: 3), spacing: 16) {
            ForEach(keys, id: \.self) { k in
                TVFocusButton(radius: 50, accent: k == "✓" ? TVColor.brand : TVColor.focusRing, scale: 1.12, lift: 6,
                              action: { tap(k) }) { focused in
                    Text(k)
                        .font(.system(size: k.count > 1 ? 30 : 40, weight: .semibold))
                        .foregroundStyle((focused || k == "✓") ? TVColor.onBrand : TVColor.text)
                        .frame(width: 100, height: 100)
                        .background((focused || k == "✓") ? TVColor.brand : TVColor.surface,
                                    in: Circle())
                }
            }
        }
        .frame(width: 332)
    }

    private func tap(_ k: String) {
        error = nil
        switch k {
        case "⌫": if !code.isEmpty { code.removeLast() }
        case "✓": submit()
        default: if code.count < 6 { code.append(k) }
        }
    }

    private func submit() {
        guard code.trimmingCharacters(in: .whitespaces).count >= 4, !busy else { return }
        busy = true; error = nil
        Task {
            let err = await store.login2FA(sourceID: source.id, otp: code)
            busy = false
            if let err { error = err; code = "" } else { dismiss() }
        }
    }
}

// MARK: - 回收站

struct TVRecycleBinView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: Color(hex: "#1f3a5b"), strength: 0.35)
            TVColor.bg.opacity(0.38).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    TVEyebrow(text: PMString("ext.tv.sources.recycleBin"))
                    Text(PMString("ext.tv.sources.recycleTitle"))
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(TVColor.text)
                        .padding(.bottom, 8)
                    let deleted = store.deletedSources
                    if deleted.isEmpty {
                        TVEmptyState(
                            icon: "trash",
                            title: PMString("ext.tv.sources.recycleEmpty"),
                            subtitle: ""
                        )
                        .frame(minHeight: 520)
                    } else {
                        ForEach(deleted) { s in
                            TVFocusButton(radius: TVRadius.card, scale: 1.0, lift: 0,
                                          action: { store.restoreSource(s.id) }) { focused in
                                HStack(spacing: 18) {
                                    Image(systemName: s.iconName).font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(.white).frame(width: 46, height: 46)
                                        .background(s.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(s.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(TVColor.text)
                                        Text(s.type.uppercased()).font(.system(size: 15, design: .monospaced)).foregroundStyle(TVColor.textFaint)
                                    }
                                    Spacer(minLength: 0)
                                    Label(PMString("ext.tv.sources.restore"), systemImage: "arrow.uturn.backward")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(focused ? TVColor.ok : TVColor.textFaint)
                                }
                                .padding(.horizontal, 22).padding(.vertical, 16).frame(maxWidth: .infinity)
                                .background(focused ? TVColor.surfaceStrong : TVColor.card)
                            }
                        }
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(.horizontal, 120).padding(.vertical, 80)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}
#endif
