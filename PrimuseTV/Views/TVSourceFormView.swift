#if os(tvOS)
import Observation
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

enum TVSourceEditPolicy {
    /// TV can safely edit address-backed sources represented by this form.
    /// OAuth/cookie providers and S3 have provider-specific state that this
    /// compact TV form must not rewrite.
    static func canEdit(_ source: MusicSource) -> Bool {
        source.type.requiresHost
            && !source.type.isAwaitingPublicAPI
            && StreamResolverRegistry.tvSupportedTypes.contains(source.type)
            && source.type != .s3
            && source.authType != .oauth
            && source.authType != .cookie
    }
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

    private var locallyAddableDevices: [DiscoveredDevice] {
        store.discoveredDevices.filter { TVStore.canBuildLibraryOnTV($0.sourceType) }
    }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.4)
            TVColor.bg.opacity(0.42).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: PMString("ext.tv.sources.add.step1")).padding(.bottom, 8)
                    Text(PMString("ext.tv.sources.chooseType"))
                        .tvFont(size: 52, weight: .bold, relativeTo: .title).foregroundStyle(TVColor.text)
                        .padding(.bottom, 8)
                    Text(PMString("ext.tv.sources.chooseTypeBody"))
                        .tvFont(.meta).foregroundStyle(TVColor.textFaint)
                        .frame(maxWidth: 1100, alignment: .leading).padding(.bottom, 36)

                    // 内网自动发现的设备(Bonjour)优先展示。
                    if !locallyAddableDevices.isEmpty {
                        TVEyebrow(text: PMString("ext.tv.sources.discovered")).padding(.bottom, 14)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                            ForEach(locallyAddableDevices) { d in
                                typeCard(icon: d.sourceType.iconName, label: d.name,
                                         hint: "\(d.host):\(d.port)",
                                         badge: Self.shortProtocol(d.sourceType),
                                         accentIcon: true,
                                         isEnabled: true) {
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
                                     badge: Self.shortProtocol(t),
                                     accentIcon: idx == 0,
                                     isEnabled: true) { onPick(t, nil) }
                        }
                    }
                    Text(PMString("ext.tv.sources.chooseTypeFooter"))
                        .tvFont(.meta).foregroundStyle(TVColor.textGhost).padding(.top, 36)
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
                        Text(badge).tvFont(.meta, weight: .heavy)
                            .foregroundStyle(TVColor.onBrand)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(TVColor.brand, in: Capsule())
                    }
                }
                Spacer(minLength: 16)
                Text(label).tvFont(.rowTitle, weight: .bold)
                    .foregroundStyle(TVColor.text).lineLimit(1)
                Text(hint).tvFont(.meta, design: .monospaced)
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
        case .synologyAudioStation: return "Audio Station"
        case .qnap: return "QNAP"
        case .fnos: return "fnOS"
        case .fnMusic, .daoliyu, .songloft, .ugreen: return t.displayName
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        case .subsonic, .navidrome, .airsonic, .gonic: return "Subsonic"
        case .upnp: return "UPnP"
        case .s3: return "S3"
        // 云盘的角标写「云盘」类别,原始枚举名大写(ALIYUNDRIVE)既难读又超宽。
        case _ where t.isCloudDrive: return t.category.displayName
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
        case .songloft: return "Songloft REST API"
        case .synology, .synologyAudioStation, .qnap, .fnos, .ugreen:
            return PMString("ext.tv.sources.hint.nasSuite")
        case .upnp: return PMString("ext.tv.sources.hint.upnp")
        case .drime: return PMString("ext.tv.sources.hint.cloudToken")
        case _ where t.isCloudDrive: return PMString("ext.tv.sources.hint.cloudScan")
        default: return t.category.displayName
        }
    }
}

// MARK: - 第 2 步:填写连接信息(双栏)

struct TVSourceFormView: View {
    private struct CloudAuthRequest: Identifiable {
        let source: MusicSource
        let clientID: String
        let clientSecret: String?

        var id: String { source.id }
    }

    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let editing: MusicSource?
    let type: MusicSourceType
    var prefillHost: String? = nil
    var prefillPort: Int? = nil
    var prefillName: String? = nil
    var prefillUseSsl: Bool? = nil
    let onSaved: (MusicSource, Bool) -> Void

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
    @State private var authType: SourceAuthType = .password
    @State private var fnConnectAccessCode = ""
    @State private var useGuestAccess = false
    @State private var pathText = ""
    /// 云盘:内置 client 凭据缺位时由用户自带(阿里云盘就是这种),
    /// Drime 则是用户在网页后台自建的 API token。
    @State private var cloudClientID = ""
    @State private var cloudClientSecret = ""
    @State private var cloudAPIToken = ""
    @State private var cloudAuthRequest: CloudAuthRequest?
    @State private var testResult: String?
    @State private var testing = false
    @State private var saveFailed = false
    /// 用户填的那一到两行地址。上面那组 host/portText/useSsl/publicHost/… 仍然是
    /// `draftSource()` 唯一读取的字段 —— 提交时由 `applyAddressPlan` 一次性写回。
    @State private var addressRows: [TVSourceAddressRow] = [TVSourceAddressRow()]
    /// 打开编辑页时回显出来的那一份。地址、手填端口、手选协议都没动过就不探测:
    /// 遥控器上改个名字、换个密码不该因为服务器此刻不在线而失败。
    @State private var addressBaseline: [SourceAddressFormPolicy.AddressDraft]?
    @State private var addressProbe = TVSourceAddressProbeController()
    @State private var addressSubmitTask: Task<Void, Never>?
    /// 上一轮探测定下来的候选。电视这边「测试连接」与「保存」是两个按钮,刚探完
    /// 就按保存不该再等一轮十几秒;而重新取「第一个候选」会把刚探到的结果悄悄
    /// 换掉,所以把结果连同它对应的输入一起记下来。
    @State private var resolvedSelection: ResolvedAddressSelection?

    private var showsSSL: Bool { type.category == .mediaServer || type.category == .nas || type == .webdav }
    private var isCloudDrive: Bool { type.isCloudDrive }
    /// Drime 用用户自建的 API token,没有授权页。
    private var usesCloudAPIToken: Bool { type == .drime }
    /// 本机没有内置 client_id 的云盘(阿里云盘),要用户自己到开放平台申请后填进来。
    private var needsCustomCloudClient: Bool {
        isCloudDrive && !usesCloudAPIToken && !BuiltInCloudCredentials.hasBuiltIn(for: type)
    }
    /// 该云盘是否走扫码 / 设备码授权。123 云盘直接用 clientID+Secret 换 token,不需要。
    private var usesCloudDeviceAuth: Bool {
        isCloudDrive && CloudDeviceAuthSupport.providers.contains(type)
    }
    private var supportsAdaptiveConnections: Bool { type.supportsAdaptiveConnections }
    private var showsAuth: Bool { type.requiresCredentials }
    private var supportsAPIKeyAuth: Bool {
        type == .jellyfin || type == .emby || type == .plex
    }
    private var showsAuthPicker: Bool { type == .sftp || supportsAPIKeyAuth }
    private var effectiveAuthType: SourceAuthType {
        useGuestAccess ? .none : authType
    }
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
        if type.usesSynologyConnectionMode { return synologyConnectionMode == .quickConnect }
        if type == .fnMusic { return fnMusicConnectionMode == .fnConnect }
        return false
    }

    /// 地址框读出来的结果。纯函数、不发请求,所以每次 body 求值重算一遍也不贵。
    private var addressReading: SourceAddressFormPolicy.FormReading {
        SourceAddressFormPolicy.read(addressRows.map(\.draft), sourceType: type)
    }

    /// 至少有一条能用的地址,而且没有哪一行写坏了(含高级选项里的端口)。
    private var addressFormIsValid: Bool {
        addressReading.isSubmittable
            && addressRows.contains(where: \.hasInvalidManualPort) == false
    }

    /// 这个源当前是不是走厂商中转。地址框里填了 QuickConnect ID / FN ID 就是 ——
    /// 用它而不是 `remoteUsesVendor`,是因为那两个 mode 要等到提交时才被写回,
    /// 而访问码这类字段必须在用户打字的当下就出现。
    private var usesVendorRemoteAccess: Bool {
        supportsAdaptiveConnections
            ? addressReading.placement.usesVendorRemoteAccess
            : remoteUsesVendor
    }

    private var canSave: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasName else { return false }
        if isCloudDrive {
            if usesCloudAPIToken {
                // 编辑已有源时可以不重填 token(钥匙串里已经有了)。
                return editing != nil || !cloudAPIToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if needsCustomCloudClient {
                return !cloudClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !cloudClientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return true
        }
        let legacyConnectionIsValid = !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ((type.usesSynologyConnectionMode && synologyConnectionMode == .quickConnect)
                ? SynologyQuickConnectResolver.isValidQuickConnectID(host)
                : ((type == .fnMusic && fnMusicConnectionMode == .fnConnect)
                    ? FnConnectResolver.isValidFNID(host)
                    : validatedPort != nil))
        if type.requiresHost {
            let connectionIsValid = supportsAdaptiveConnections
                ? addressFormIsValid
                : legacyConnectionIsValid
            guard connectionIsValid else { return false }
        }
        guard showsAuth else { return true }

        let keepsStoredSecret = editing?.authType == effectiveAuthType && password.isEmpty
        switch effectiveAuthType {
        case .none:
            return type.supportsAnonymous
        case .password:
            guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            if type == .jellyfin || type == .emby { return true }
            return keepsStoredSecret || !password.isEmpty
        case .sshKey:
            return !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (keepsStoredSecret || !password.isEmpty)
        case .apiKey:
            return keepsStoredSecret || !password.isEmpty
        case .cookie, .oauth:
            return keepsStoredSecret
        }
    }
    private var canTestConnection: Bool { type.requiresHost && canSave }
    /// 探测跑着的时候不让再按一次:第二轮会把上一轮刚定下来的端点丢掉。
    private var canSubmitNow: Bool { canSave && !addressProbe.isProbing }
    /// 取出来放在这里,免得按钮的 label 里出现三层嵌套三元 —— 那种表达式在
    /// Apple 端的类型检查里是超时常客。
    private var saveButtonTitle: String {
        if usesCloudDeviceAuth { return PMString("ext.tv.sources.form.cloudSignIn") }
        return editing == nil
            ? PMString("ext.tv.sources.form.add")
            : PMString("ext.tv.sources.form.save")
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
        if type.usesSynologyConnectionMode {
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
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.4)
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
        // 自适应连接的表单里已经没有 SSL 开关了 —— 协议跟着地址走。这两条跟随
        // 规则只服务于老的单地址表单;留着会在写回探测结果时把刚定下来的端口
        // 当成"上一个默认值"改掉。
        .onChange(of: useSsl) { oldValue, newValue in
            guard !supportsAdaptiveConnections else { return }
            updateDefaultPortForSSLChange(
                port: $portText,
                from: oldValue,
                to: newValue
            )
        }
        .onChange(of: publicUseSsl) { oldValue, newValue in
            guard !supportsAdaptiveConnections else { return }
            updateDefaultPortForSSLChange(
                port: $publicPortText,
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
                  type.usesSynologyConnectionMode,
                  newValue == .quickConnect else { return }
            useSsl = true
            portText = String(type.defaultPort(useSsl: true))
        }
        .onChange(of: fnMusicConnectionMode) { _, newValue in
            guard !supportsAdaptiveConnections,
                  type == .fnMusic,
                  newValue == .fnConnect else { return }
            useSsl = true
        }
        .fullScreenCover(item: $cloudAuthRequest) { request in
            TVCloudAuthView(
                source: request.source,
                clientID: request.clientID,
                clientSecret: request.clientSecret,
                onAuthorized: {
                    cloudAuthRequest = nil
                    commitCloudDrive(request.source)
                }
            )
        }
        .alert(PMString("ext.tv.sources.saveFailed"), isPresented: $saveFailed) {
            Button(PMString("ext.tv.sources.ok"), role: .cancel) {}
        } message: {
            Text(PMString("ext.tv.sources.saveFailedBody"))
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
                        .tvFont(.pageTitle).foregroundStyle(TVColor.text)
                }
            }
            .padding(.bottom, 8)

            TVFormField(label: PMString("ext.tv.sources.form.name"), text: $name, autofocus: true)
            if type.requiresHost {
                if supportsAdaptiveConnections {
                    adaptiveConnectionFields
                } else {
                    if type.usesSynologyConnectionMode {
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
                    if type.usesSynologyConnectionMode, synologyConnectionMode == .quickConnect {
                        connectionHint("synology_quickconnect_hint")
                    } else if type == .fnMusic, fnMusicConnectionMode == .fnConnect {
                        connectionHint("fnmusic_fnconnect_hint")
                    } else {
                        TVFormField(label: PMString("ext.tv.sources.form.port"), text: $portText, mono: true)
                    }
                    if showsSSL
                        && !(type.usesSynologyConnectionMode && synologyConnectionMode == .quickConnect)
                        && !(type == .fnMusic && fnMusicConnectionMode == .fnConnect) {
                        connectionSSLToggle(isOn: $useSsl)
                    }
                }
            }
            if showsAuth {
                if type.supportsAnonymous {
                    TVSwitchRow(icon: "person.crop.circle.badge.checkmark",
                                title: PMString("ext.tv.sources.form.guest"),
                                isOn: $useGuestAccess)
                }
                if !useGuestAccess {
                    if showsAuthPicker {
                        Picker(PMString("auth_method"), selection: $authType) {
                            Text(PMString("password")).tag(SourceAuthType.password)
                            if supportsAPIKeyAuth {
                                Text(PMString("api_key")).tag(SourceAuthType.apiKey)
                            }
                            if type == .sftp {
                                Text(PMString("ssh_key")).tag(SourceAuthType.sshKey)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 720)
                    }
                    if authType == .password || authType == .sshKey {
                        TVFormField(label: PMString("ext.tv.sources.cred.username"), text: $username, mono: true)
                    }
                    if authType != .oauth && authType != .cookie {
                        let credentialLabel = authType == .apiKey
                            ? PMString("api_key")
                            : (authType == .sshKey
                                ? PMString("ssh_key")
                                : (editing == nil
                                    ? PMString("ext.tv.sources.cred.password")
                                    : PMString("ext.tv.sources.form.passwordKeep")))
                        TVFormField(
                            label: credentialLabel,
                            text: $password,
                            secure: true
                        )
                    }
                    if type == .fnMusic {
                        Text(PMString("fnmusic_account_hint"))
                            .tvFont(.meta)
                            .foregroundStyle(TVColor.textFaint)
                        // 访问码只有走 FN Connect 中转时才用得上,而那取决于地址
                        // 框里这一刻读出来的是不是 FN ID。
                        if usesVendorRemoteAccess {
                            TVFormField(
                                label: PMString("fnmusic_access_code"),
                                text: $fnConnectAccessCode,
                                secure: true
                            )
                            Text(PMString("fnmusic_access_code_hint"))
                                .tvFont(.meta)
                                .foregroundStyle(TVColor.textFaint)
                        }
                    }
                }
            }
            if isCloudDrive {
                cloudCredentialFields
            } else if type != .fnMusic && !type.supportsEndpointSpecificPath {
                TVFormField(label: pathLabel, text: $pathText, mono: true)
            }

            if showsAuth && effectiveAuthType != .none {
                HStack(spacing: 12) {
                    Image(systemName: "lock.fill").font(.system(size: 20)).foregroundStyle(TVColor.brand)
                    Text(PMString("ext.tv.sources.form.passwordStorage"))
                        .tvFont(.caption).foregroundStyle(TVColor.textFaint)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    /// 云盘要填的东西:要么是 API token(Drime),要么是开放平台的 client 凭据
    /// (内置缺位时,如阿里云盘)。其余都有内置 client,扫码即可,不用填。
    @ViewBuilder
    private var cloudCredentialFields: some View {
        if usesCloudAPIToken {
            TVFormField(
                label: PMString("ext.tv.sources.form.cloudAPIToken"),
                text: $cloudAPIToken,
                secure: true
            )
            Text(PMString("ext.tv.sources.form.cloudAPITokenHint"))
                .tvFont(.meta).foregroundStyle(TVColor.textFaint)
        } else if needsCustomCloudClient {
            TVFormField(
                label: PMString("ext.tv.sources.form.cloudClientID"),
                text: $cloudClientID,
                mono: true
            )
            TVFormField(
                label: PMString("ext.tv.sources.form.cloudClientSecret"),
                text: $cloudClientSecret,
                secure: true
            )
            Text(PMString("ext.tv.sources.form.cloudClientHint"))
                .tvFont(.meta).foregroundStyle(TVColor.textFaint)
        }
        if usesCloudDeviceAuth {
            HStack(spacing: 12) {
                Image(systemName: "qrcode").font(.system(size: 20)).foregroundStyle(TVColor.brand)
                Text(PMString("ext.tv.sources.form.cloudScanHint"))
                    .tvFont(.caption).foregroundStyle(TVColor.textFaint)
            }
            .padding(.top, 4)
        }
    }

    /// 一个地址框,下面一行实时解读。内网 / 公网不再是两个常驻区块 —— 地址归哪个
    /// 位置由 `SourceAddressFormPolicy` 判断,用户只要把地址填进来。
    ///
    /// 电视上这件事的收益比手机大得多:少一个端口框、少一个 SSL 开关、少一次
    /// QuickConnect / FN Connect 的分段选择,就是少三轮用方向键挪来挪去的输入。
    @ViewBuilder
    private var adaptiveConnectionFields: some View {
        let reading = addressReading
        ForEach($addressRows) { $row in
            TVSourceAddressRowView(
                row: $row,
                reading: addressRowReading(reading, for: row.id),
                sourceType: type,
                attempts: addressProbe.attempts[row.id] ?? [],
                label: addressRows.first?.id == row.id
                    ? PMString("source_address_section")
                    : PMString("source_address_alternate_section"),
                canRemove: addressRows.count > 1,
                onRemove: { removeAddressRow(row.id) }
            )
        }
        addressActionRow
        if let note = unconfirmedServiceNote {
            connectionHintText(note)
        }
        connectionHint("source_address_section_footer")
    }

    /// 地址块下面那一排次要动作:添加备用地址、探测进行中(可取消)、探测不通时
    /// 的「仍然保存」。都留在左列地址下方,不用弹层打断。
    @ViewBuilder
    private var addressActionRow: some View {
        HStack(spacing: 14) {
            if addressRows.count < SourceAddressFormPolicy.maximumAddressCount {
                TVSourceAddressActionButton(title: PMString("source_address_add_alternate")) {
                    addAddressRow()
                }
            }
            if addressProbe.isProbing {
                ProgressView().tint(TVColor.brand)
                Text(PMString("source_address_probing"))
                    .tvFont(.meta)
                    .foregroundStyle(TVColor.textFaint)
                TVSourceAddressActionButton(title: PMString("ext.tv.sources.cancel")) {
                    cancelAddressProbe()
                }
            }
            if addressProbe.phase == .unresolved {
                TVSourceAddressActionButton(title: PMString("source_address_probe_save_anyway")) {
                    saveWithoutProbing()
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func connectionHint(_ key: String) -> some View {
        connectionHintText(PMString(key))
    }

    /// 与 `connectionHint` 同样的外观,但内容是运行时算出来的字符串而不是文案键。
    private func connectionHintText(_ text: String) -> some View {
        Text(text)
            .tvFont(.meta)
            .foregroundStyle(TVColor.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 720, alignment: .leading)
    }

    private func connectionSSLToggle(isOn: Binding<Bool>) -> some View {
        TVSwitchRow(icon: "lock.shield", title: PMString("ext.tv.sources.form.useSSL"), isOn: isOn)
    }

    private var rightPanel: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Image(systemName: "keyboard").font(.system(size: 44)).foregroundStyle(TVColor.text)
                Text(PMString("ext.tv.sources.form.iphoneInput"))
                    .tvFont(.eyebrow, weight: .bold).foregroundStyle(TVColor.text)
                Text(PMString("ext.tv.sources.form.iphoneInputBody"))
                    .tvFont(.meta).foregroundStyle(TVColor.textFaint)
                    .multilineTextAlignment(.center).lineSpacing(4)
            }
            .padding(28).frame(maxWidth: .infinity)
            .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(TVColor.cardBorder, lineWidth: 1) }

            if let testResult {
                Text(testResult).tvFont(.meta).foregroundStyle(TVColor.textMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }

            HStack(spacing: 14) {
                TVFocusButton(radius: 14, scale: 1.04, lift: 0, action: runTest) { f in
                    Group {
                        if testing { ProgressView().tint(TVColor.brand) }
                        else { Text(PMString("ext.tv.sources.testConnection")) }
                    }
                        .tvFont(.meta, weight: .medium).foregroundStyle(TVColor.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(f ? TVColor.surfaceStrong : TVColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!canTestConnection || testing || addressProbe.isProbing)
                TVFocusButton(radius: 14, accent: TVColor.brand, scale: 1.05, lift: 0, action: save) { f in
                    // 探测期间按钮会变成不可用,焦点会被系统挪走 —— 所以进行中的
                    // 指示必须留在按钮自己身上,和「测试连接」一个样子。
                    Group {
                        if addressProbe.isProbing { ProgressView().tint(TVColor.brand) }
                        else { Text(saveButtonTitle) }
                    }
                        .tvFont(.meta, weight: .bold)
                        .foregroundStyle(canSubmitNow ? TVColor.onBrand : TVColor.textGhost)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(canSubmitNow ? TVColor.brand.opacity(f ? 1 : 0.88) : TVColor.surface,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!canSubmitNow)
            }
            TVFocusButton(radius: 14, scale: 1.04, lift: 0, action: { dismiss() }) { f in
                Text(PMString("ext.tv.sources.cancel"))
                    .tvFont(.caption, weight: .medium).foregroundStyle(TVColor.text)
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
        if type == .plex {
            authType = .apiKey
        } else if !type.requiresCredentials {
            authType = .none
        }

        if let e = editing {
            name = e.name
            username = e.username ?? ""
            authType = e.authType
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
                if type.usesSynologyConnectionMode {
                    synologyConnectionMode = configuration.remoteAccessMode == .vendor
                        ? .quickConnect
                        : .address
                } else if type == .fnMusic {
                    fnMusicConnectionMode = configuration.remoteAccessMode == .vendor
                        ? .fnConnect
                        : .address
                }
                // 已存的端点渲染回地址串,协议与端口都写在里面,再读一遍能原样回到
                // 同一个端点。留一份基线:这几行没被动过就不重新探测,免得离线改个
                // 名字也要等服务器应答 —— 扫码直传和 iCloud 同步下来的源也走这里。
                let drafts = SourceAddressFormPolicy.drafts(
                    for: configuration,
                    sourceType: type
                )
                addressRows = drafts.isEmpty
                    ? [TVSourceAddressRow()]
                    : drafts.map(TVSourceAddressRow.init(draft:))
                addressBaseline = drafts.isEmpty ? nil : drafts
            } else {
                host = e.host ?? ""
                portText = String(e.port ?? type.defaultPort)
                useSsl = e.useSsl
                if type.usesSynologyConnectionMode {
                    synologyConnectionMode = e.effectiveSynologyConnectionMode
                }
                if type == .fnMusic {
                    fnMusicConnectionMode = e.effectiveFnMusicConnectionMode
                }
            }
            useGuestAccess = type.supportsAnonymous && authType == .none
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
            // 内网发现来的端口是实测到的,所以连协议一起写死进地址串 —— 候选只剩
            // 一个,保存时不会再去试别的。
            if supportsAdaptiveConnections, let prefillHost, !prefillHost.isEmpty {
                addressRows = [TVSourceAddressRow(
                    address: SourceAddressFormPolicy.exactAddress(
                        host: prefillHost,
                        port: prefillPort ?? type.defaultPort(useSsl: useSsl),
                        useSsl: useSsl,
                        sourceType: type
                    )
                )]
            }
            // 这两个 mode 只是个起点:自适应连接的源最终走不走厂商中转,由
            // `applyAddressPlan` 按地址框里读出来的东西定。
            if type.usesSynologyConnectionMode {
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

    // MARK: - 地址行

    private struct ResolvedAddressSelection {
        var signature: String
        var selected: [UUID: SourceConnectionCandidatePlanner.Candidate]
    }

    /// 只盯真正影响「连到哪里」的那几项:展开高级选项、改个名字都不该作废已经
    /// 拿回来的探测结论。行的身份也算进来 —— `selected` 是按行 id 存的,删掉
    /// 再加一行虽然文字一样,却对不上任何一条已探到的候选。
    private var addressProbeSignature: String {
        addressRows
            .map { "\($0.id.uuidString)\u{1}\($0.draft.probeSignature)" }
            .joined(separator: "\n")
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
            if let note = TVSourceAddressReadingText.unconfirmedNote(
                addressProbe.verdicts[row.id],
                sourceType: type
            ) {
                return note
            }
        }
        return nil
    }

    private func addAddressRow() {
        guard addressRows.count < SourceAddressFormPolicy.maximumAddressCount else { return }
        addressRows.append(TVSourceAddressRow())
    }

    private func removeAddressRow(_ id: UUID) {
        guard addressRows.count > 1 else { return }
        addressRows.removeAll { $0.id == id }
    }

    private func cancelAddressProbe() {
        addressSubmitTask?.cancel()
        addressSubmitTask = nil
        addressProbe.invalidate()
        resolvedSelection = nil
    }

    // MARK: - 提交

    /// 按下「保存」或「测试连接」之后要做的那件事。写成枚举而不是回调闭包:
    /// 探测在 `Task` 里跑,而闭包不是 `Sendable`,枚举是。
    private enum AddressResolutionIntent {
        case save
        case test
    }

    private func save() { beginAddressResolution(for: .save) }

    private func runTest() { beginAddressResolution(for: .test) }

    /// 提交分三步:识别 →(需要时)探测 → 把结果写回旧表单那组 `@State`,再走
    /// 原来的 `draftSource()` / `commitSave()`。凭据、云盘授权、S3 映射都在那条
    /// 路径里,一个字没动。
    private func beginAddressResolution(for intent: AddressResolutionIntent) {
        guard supportsAdaptiveConnections, type.requiresHost else {
            perform(intent)
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
            "🔎 Source address submit type=\(type.rawValue) editing=\(editing != nil) "
                + "rows=\(addressRows.count) probing=\(probing.count)"
        )
        guard probing.isEmpty == false else {
            // 编辑已有源且地址没动过:已存的端口与协议本来就是明确的,原样留着。
            applyAddressPlan(reading, selected: [:])
            perform(intent)
            return
        }

        // 刚在「测试连接」里探过同一组地址,直接用那一轮的结论。
        if let resolved = resolvedSelection, resolved.signature == addressProbeSignature {
            applyAddressPlan(reading, selected: resolved.selected)
            perform(intent)
            return
        }

        addressSubmitTask?.cancel()
        addressSubmitTask = Task { @MainActor in
            let outcome = await addressProbe.probe(
                rows: addressRows,
                reading: reading,
                sourceType: type,
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
            // 接着改,或者按「仍然保存」坚持用第一个候选,不弹全屏面板打断。
            guard outcome.selected.isEmpty == false || outcome.unresolvedRowIDs.isEmpty else {
                plog("🔎 Source address submit halted: no address responded rows=\(outcome.unresolvedRowIDs.count)")
                return
            }
            plog(
                "🔎 Source address submit saving resolved=\(outcome.selected.count) "
                    + "unresolved=\(outcome.unresolvedRowIDs.count)"
            )
            resolvedSelection = ResolvedAddressSelection(
                signature: addressProbeSignature,
                selected: outcome.selected
            )
            applyAddressPlan(reading, selected: outcome.selected)
            perform(intent)
        }
    }

    private func perform(_ intent: AddressResolutionIntent) {
        switch intent {
        case .save: commitSave()
        case .test: startConnectionTest()
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
        commitSave()
    }

    /// 把识别 + 探测的结果写回 host / portText / useSsl / publicHost / … 这组
    /// `@State`。`draftSource()` 读的仍然是这些字段,所以它的语义一点没变。
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
        portText = localEndpoint.map { String($0.port) } ?? ""
        useSsl = localEndpoint?.useSsl ?? type.defaultSSL
        localPathPrefix = localEndpoint?.pathPrefix ?? ""

        publicHost = publicEndpoint?.host ?? ""
        publicPortText = publicEndpoint.map { String($0.port) } ?? ""
        publicUseSsl = publicEndpoint?.useSsl ?? (showsSSL ? true : type.defaultSSL)
        publicPathPrefix = publicEndpoint?.pathPrefix ?? ""

        vendorIdentifier = resolvedVendorIdentifier ?? ""
        let usesVendor = resolvedVendorIdentifier != nil
        if type.usesSynologyConnectionMode {
            synologyConnectionMode = usesVendor ? .quickConnect : .address
        }
        if type == .fnMusic {
            fnMusicConnectionMode = usesVendor ? .fnConnect : .address
        }

        applyAddressPath(localEndpoint?.pathPrefix ?? publicEndpoint?.pathPrefix)
    }

    /// `smb://nas/music` 里的那截路径不属于端点:SMB 的共享名、NFS 的导出路径、
    /// FTP/SFTP 的起始目录都是源级别的字段。用户没单独填时就用地址里写的那段。
    private func applyAddressPath(_ rawPath: String?) {
        guard type.supportsEndpointPathPrefix == false,
              pathText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.isEmpty == false,
              path != "/" else {
            return
        }
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard relative.isEmpty == false else { return }

        // 共享名只有一段,更深的目录留给目录选择页去挑;导出路径与起始目录是
        // 整条路径。
        pathText = type == .smb
            ? (relative.split(separator: "/").first.map(String.init) ?? relative)
            : path
    }

    private func startConnectionTest() {
        guard canTestConnection, let source = draftSource() else { return }
        let draftPassword = password.isEmpty ? nil : password
        let draftAccessCode = fnConnectAccessCode.isEmpty ? nil : fnConnectAccessCode
        testing = true; testResult = nil
        Task {
            testResult = await store.testConnection(
                source: source,
                password: draftPassword,
                fnConnectAccessCode: draftAccessCode
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
        if type.requiresHost && supportsAdaptiveConnections {
            src.connectionConfiguration = adaptiveConnectionConfiguration()
            src.synologyConnectionMode = type.usesSynologyConnectionMode ? synologyConnectionMode : nil
            src.fnMusicConnectionMode = type == .fnMusic ? fnMusicConnectionMode : nil
            src = src.projectingPreferredConnectionForLegacy()
        } else if type.requiresHost {
            if type.usesSynologyConnectionMode, synologyConnectionMode == .quickConnect {
                src.host = SynologyQuickConnectResolver.quickConnectID(from: trimmedHost)
            } else if type == .fnMusic, fnMusicConnectionMode == .fnConnect {
                src.host = FnConnectResolver.fnID(from: trimmedHost)
            } else {
                src.host = trimmedHost
            }
            let usesResolvedConnection = (type.usesSynologyConnectionMode && synologyConnectionMode == .quickConnect)
                || (type == .fnMusic && fnMusicConnectionMode == .fnConnect)
            src.port = usesResolvedConnection ? type.defaultPort(useSsl: true) : validatedPort
            src.useSsl = usesResolvedConnection ? true : (showsSSL ? useSsl : type.defaultSSL)
            src.synologyConnectionMode = type.usesSynologyConnectionMode ? synologyConnectionMode : nil
            src.fnMusicConnectionMode = type == .fnMusic ? fnMusicConnectionMode : nil
        } else {
            src.host = nil
            src.port = nil
            src.connectionConfiguration = nil
        }
        if type == .drime {
            src.username = nil
            src.authType = .apiKey
        } else if type.isCloudDrive {
            src.username = nil
            src.authType = .oauth
        } else if showsAuth {
            switch effectiveAuthType {
            case .password, .sshKey:
                src.username = trimmedUser.isEmpty ? nil : trimmedUser
            case .apiKey, .cookie, .oauth, .none:
                src.username = nil
            }
            src.authType = effectiveAuthType
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
        } else if type.usesSynologyConnectionMode {
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

    /// 原来的保存路径,一个字没动:构造 `MusicSource`、写凭据、云盘再走授权页。
    /// 地址已经在 `applyAddressPlan` 里写回了那组 `@State`,这里照旧读它们。
    private func commitSave() {
        guard let src = draftSource() else { return }
        if isCloudDrive {
            saveCloudDrive(src)
            return
        }

        let passwordToSave = effectiveAuthType == .none || password.isEmpty ? nil : password
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
        onSaved(store.source(id: src.id) ?? src, editing == nil)
        dismiss()
    }

    /// 云盘:先把 client 凭据 / API token 落进与 iPhone 同一份钥匙串,再决定
    /// 是弹扫码授权页,还是(123 云盘 / Drime 这种不需要授权页的)直接落库。
    private func saveCloudDrive(_ src: MusicSource) {
        Task { @MainActor in
            let client = await TVCloudConnectorFactory.stageCredentials(
                sourceID: src.id,
                type: type,
                apiToken: cloudAPIToken,
                clientID: cloudClientID,
                clientSecret: cloudClientSecret
            )
            guard usesCloudDeviceAuth else {
                commitCloudDrive(src)
                return
            }
            guard let client else {
                saveFailed = true
                return
            }
            cloudAuthRequest = CloudAuthRequest(
                source: src, clientID: client.id, clientSecret: client.secret
            )
        }
    }

    private func commitCloudDrive(_ src: MusicSource) {
        let didSave = editing == nil
            ? store.addSource(src, password: nil, fnConnectAccessCode: nil)
            : store.updateSource(src, password: nil, fnConnectAccessCode: nil)
        guard didSave else {
            saveFailed = true
            return
        }
        onSaved(store.source(id: src.id) ?? src, editing == nil)
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
            Text(label).tvFont(.caption)
                .foregroundStyle(focused ? TVColor.text : TVColor.textFaint)
            TVTextFieldBox(mono: mono) {
                Group {
                    if secure { SecureField("", text: $text) }
                    else { TextField("", text: $text) }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(label)
                .focused($focused)
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear { if autofocus { focused = true } }
    }
}

// MARK: - 地址行(界面状态 + 探测 + 文案)
//
// iOS / macOS 那一份在 `Primuse/Views/Sources/SourceAddressForm.swift`,不在
// PrimuseTV target 里,所以这里另有一份:判断与归位全部走 PrimuseKit 的
// `SourceAddressFormPolicy`,电视端只负责状态、探测编排和把结构化结果翻成人话。

/// 协议三态。「自动」不是一个取值,而是"不要写死" —— 交给候选规划去逐个试,
/// 这正是旧表单做不到的事:那里的 SSL 开关永远有一个确定答案。
enum TVSourceAddressTransportChoice: String, CaseIterable, Identifiable {
    case automatic
    case cleartext
    case secure

    var id: String { rawValue }

    var manualUseSsl: Bool? {
        switch self {
        case .automatic: return nil
        case .cleartext: return false
        case .secure: return true
        }
    }

    static func choice(forUseSsl useSsl: Bool?) -> TVSourceAddressTransportChoice {
        guard let useSsl else { return .automatic }
        return useSsl ? .secure : .cleartext
    }
}

/// 表单里的一行地址。地址串本身是主输入,端口与协议是它的高级选项。
struct TVSourceAddressRow: Identifiable, Equatable {
    let id = UUID()
    var address: String = ""
    /// 空字符串 = 自动。**绝不预填真实端口**:预填出来的值会在用户填了域名之后
    /// 继续生效,把 `https://emby.example.com` 连成 `:8096`。
    var portText: String = ""
    var transport: TVSourceAddressTransportChoice = .automatic
    var showsAdvancedOptions = false
    var treatDotlessTokenAsHostname = false

    var manualPort: Int? {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...65_535).contains(value) else { return nil }
        return value
    }

    /// 端口框里写了东西却不是个能用的端口。留空是合法的(自动),写错不是。
    var hasInvalidManualPort: Bool {
        portText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && manualPort == nil
    }

    var draft: SourceAddressFormPolicy.AddressDraft {
        SourceAddressFormPolicy.AddressDraft(
            address: address,
            manualPort: manualPort,
            manualUseSsl: transport.manualUseSsl,
            treatDotlessTokenAsHostname: treatDotlessTokenAsHostname
        )
    }

    mutating func selectTransport(_ choice: TVSourceAddressTransportChoice, sourceType: MusicSourceType) {
        var updated = draft
        updated.selectTransport(choice.manualUseSsl, sourceType: sourceType)
        address = updated.address
        transport = choice
    }

    mutating func editAddress(_ value: String, sourceType: MusicSourceType) {
        var updated = draft
        updated.editAddress(value, sourceType: sourceType)
        address = updated.address
        transport = .choice(forUseSsl: updated.manualUseSsl)
    }

    /// 从一个已存的端点/标识回显。高级选项留在「自动」—— 端口与协议已经写进
    /// 地址串里了,再在下面重复一遍会让用户以为有两个地方要改。
    init(draft: SourceAddressFormPolicy.AddressDraft) {
        address = draft.address
        portText = draft.manualPort.map(String.init) ?? ""
        transport = .choice(forUseSsl: draft.manualUseSsl)
        treatDotlessTokenAsHostname = draft.treatDotlessTokenAsHostname
    }

    init(address: String = "") {
        self.address = address
    }
}

/// 提交时把候选端口真的试一遍。界面只关心三件事:在不在跑、每条试了什么、
/// 选中的那条到底认没认出是这个服务。
@MainActor
@Observable
final class TVSourceAddressProbeController {

    enum Phase: Equatable {
        case idle
        case probing
        /// 有地址一个候选都没应答。清单留在界面上,用户可以继续改,也可以坚持保存。
        case unresolved
    }

    struct Outcome {
        var selected: [UUID: SourceConnectionCandidatePlanner.Candidate] = [:]
        var unresolvedRowIDs: [UUID] = []
        var isCancelled = false
    }

    private(set) var phase: Phase = .idle
    private(set) var attempts: [UUID: [SourceEndpointResolver.Attempt]] = [:]
    private(set) var verdicts: [UUID: SourceServiceFingerprint.Verdict] = [:]
    /// 这一轮里定下来的候选,按行 id 存。「仍然保存」要用它 —— 已经探到的行
    /// 没有理由退回去猜第一个候选。
    private(set) var selectedCandidates: [UUID: SourceConnectionCandidatePlanner.Candidate] = [:]

    /// 会话活到控制器被释放为止:一次提交可能要发四五个请求,每次都新建会话
    /// 等于每次都重建连接池。
    private let session = SourceEndpointProbeSession()

    var isProbing: Bool { phase == .probing }

    /// 地址一改就把上一轮的结论清掉 —— 留着会让用户以为新地址也试过了。
    func invalidate() {
        guard phase != .idle || attempts.isEmpty == false || selectedCandidates.isEmpty == false else {
            return
        }
        phase = .idle
        attempts = [:]
        verdicts = [:]
        selectedCandidates = [:]
    }

    func probe(
        rows: [TVSourceAddressRow],
        reading: SourceAddressFormPolicy.FormReading,
        sourceType: MusicSourceType,
        probing: Set<UUID>
    ) async -> Outcome {
        let plans = Self.plans(rows: rows, reading: reading, probing: probing)
        guard plans.isEmpty == false else { return Outcome() }

        phase = .probing
        attempts = [:]
        verdicts = [:]
        selectedCandidates = [:]
        plog(
            "🔎 Address probe start type=\(sourceType.rawValue) rows=\(plans.count) "
                + "candidates=\(plans.map(\.candidates.count))"
        )

        let resolver = SourceEndpointResolver(load: session.loader())
        var resolutions: [UUID: SourceEndpointResolver.Resolution] = [:]
        await withTaskGroup(of: (UUID, SourceEndpointResolver.Resolution?).self) { group in
            // 两行地址并发探,而不是一行等完再探下一行:每一轮最长要二十几秒,
            // 串起来用户要等一倍。捕获的都是单个 Sendable 值,不带整个计划
            // 结构进任务里。
            for plan in plans {
                let id = plan.id
                let input = plan.input
                let candidates = plan.candidates
                group.addTask {
                    let resolution = try? await resolver.resolve(
                        for: input,
                        sourceType: sourceType,
                        candidates: candidates
                    )
                    return (id, resolution)
                }
            }
            for await (id, resolution) in group {
                resolutions[id] = resolution
            }
        }

        guard Task.isCancelled == false else {
            phase = .idle
            return Outcome(isCancelled: true)
        }

        var outcome = Outcome()
        var collectedAttempts: [UUID: [SourceEndpointResolver.Attempt]] = [:]
        var collectedVerdicts: [UUID: SourceServiceFingerprint.Verdict] = [:]
        // 按表单里的顺序收集,任务组的完成顺序不该泄漏到界面上。
        for (index, plan) in plans.enumerated() {
            // 试过哪些地址、对面回了什么,逐行记一条:这是「一直在确认连接方式」
            // 之后唯一能回答「它到底试了什么」的东西。
            let tried = (resolutions[plan.id]?.attempts ?? [])
                .map { "\($0.url)→\($0.verdict.logTag)" }
                .joined(separator: " ")
            guard let resolution = resolutions[plan.id], let candidate = resolution.selected else {
                // 尝试清单只在这一行一个候选都没应答时才有意义 —— 定下来的那行
                // 再列一遍"试过什么"只会让人以为它也没成。
                collectedAttempts[plan.id] = resolutions[plan.id]?.attempts ?? []
                outcome.unresolvedRowIDs.append(plan.id)
                plog("🔎 Address probe row=\(index + 1) no response tried=[\(tried)]")
                continue
            }
            outcome.selected[plan.id] = candidate
            collectedVerdicts[plan.id] = resolution.verdict
            plog(
                "🔎 Address probe row=\(index + 1) selected=\(candidate.httpScheme):\(candidate.port) "
                    + "verdict=\(resolution.verdict?.logTag ?? "-") tried=[\(tried)]"
            )
        }

        attempts = collectedAttempts
        verdicts = collectedVerdicts
        selectedCandidates = outcome.selected
        phase = outcome.unresolvedRowIDs.isEmpty ? .idle : .unresolved
        return outcome
    }

    private struct Plan {
        var id: UUID
        var input: SourceAddressInputPolicy.ParsedEndpointInput
        var candidates: [SourceConnectionCandidatePlanner.Candidate]
    }

    /// 只探要真正存下来的端点行。厂商标识不用探(它不是一个地址),没抢到槽位的
    /// 那一行也不用探(存不进去),编辑时没动过的那一行也不用探(协议与端口
    /// 已经写死在里面,`SourceAddressFormPolicy.rowsRequiringProbe`)。
    private static func plans(
        rows: [TVSourceAddressRow],
        reading: SourceAddressFormPolicy.FormReading,
        probing: Set<UUID>
    ) -> [Plan] {
        var plans: [Plan] = []
        for (index, row) in rows.enumerated() where index < reading.rows.count {
            guard probing.contains(row.id),
                  case let .endpoint(endpoint) = reading.rows[index],
                  endpoint.slot != nil else {
                continue
            }
            plans.append(Plan(id: row.id, input: endpoint.input, candidates: endpoint.candidates))
        }
        return plans
    }
}

/// 结构化的解读结果翻成人话。电视端的文案键与 iPhone 端同名同义 —— 同一个概念
/// 在两端不该叫两个名字,只是这里要从 PrimuseKit 自己那 16 张表里取。
enum TVSourceAddressReadingText {

    /// 空地址时那一行提示。群晖 / 飞牛的地址框还认厂商远程接入标识,而「连接方式」
    /// 分段选择器已经不在了 —— 这里是唯一能把「也能填 ID」说出来又不多占一行的地方。
    static func addressPlaceholder(for sourceType: MusicSourceType) -> String {
        guard sourceType.supportsVendorRemoteAccess else {
            return PMString("source_address_placeholder")
        }
        return PMString(
            "source_address_placeholder_vendor %@",
            PMString(sourceType.usesSynologyConnectionMode
                ? "synology_quickconnect_id"
                : "fnmusic_fnid")
        )
    }

    /// 地址框下面那一行。nil 表示这一行还没什么可说的(空输入)。
    static func line(
        for reading: SourceAddressFormPolicy.Reading,
        sourceType: MusicSourceType
    ) -> String? {
        switch reading {
        case .empty:
            return nil
        case let .invalid(reason):
            return invalidText(reason)
        case let .vendor(vendor):
            if vendor.isRedundant {
                return PMString("source_address_reading_vendor_redundant")
            }
            return vendorText(vendor.kind)
        case let .endpoint(endpoint):
            return endpointText(endpoint, sourceType: sourceType)
        }
    }

    /// 解读行该不该按「出错了」来显示。
    static func isProblem(_ reading: SourceAddressFormPolicy.Reading) -> Bool {
        switch reading {
        case .invalid:
            return true
        case let .vendor(vendor):
            return vendor.isRedundant
        case let .endpoint(endpoint):
            return endpoint.slot == nil
        case .empty:
            return false
        }
    }

    static func hostClassText(_ hostClass: SourceAddressInputPolicy.HostClass) -> String {
        switch hostClass {
        case .loopback: return PMString("source_address_class_loopback")
        // 沿用音乐源卡片上已有的那一个词,同一个概念不该在两处叫两个名字。
        case .lan: return PMString("source_connection_local")
        case .overlay: return PMString("source_address_class_overlay")
        case .public: return PMString("source_address_class_public")
        }
    }

    /// 尝试清单里那一条为什么不通。清单只在"一个候选都没应答"时出现,所以里面
    /// 只会有不可达的结论;真选中了的那条不走这里。
    static func attemptReasonText(_ attempt: SourceEndpointResolver.Attempt) -> String? {
        guard case let .unreachable(reason) = attempt.verdict else { return nil }
        return unreachableText(reason)
    }

    /// 选中的候选只是「有人应答」而不是「确认是这个服务」时的那句实话。
    static func unconfirmedNote(
        _ verdict: SourceServiceFingerprint.Verdict?,
        sourceType: MusicSourceType
    ) -> String? {
        guard let verdict, verdict.isResponded else { return nil }
        return PMString("source_address_probe_unconfirmed %@", sourceType.displayName)
    }

    // MARK: - 私有

    private static func endpointText(
        _ endpoint: SourceAddressFormPolicy.EndpointReading,
        sourceType: MusicSourceType
    ) -> String {
        guard let candidate = endpoint.preferred else {
            return PMString("source_address_reading_unused")
        }
        let address = endpoint.displayAddress
        let port = String(candidate.port)
        // 键名写在 `PMString(` 同一行:文案检查脚本是按这个形状找 key 的。
        let body = endpoint.isAutomatic
            ? PMString("source_address_reading_auto %@ %@", address, port)
            : PMString("source_address_reading %@ %@", address, port)
        guard endpoint.slot != nil else {
            return "\(body)\n\(PMString("source_address_reading_unused"))"
        }
        return "\(hostClassText(endpoint.hostClass)) · \(body)"
    }

    private static func vendorText(
        _ kind: SourceAddressInputPolicy.VendorIdentifierKind
    ) -> String {
        switch kind {
        case .synologyQuickConnect:
            return PMString("source_address_reading_quickconnect")
        case .fnConnect:
            return PMString("source_address_reading_fnid")
        }
    }

    private static func invalidText(
        _ reason: SourceAddressInputPolicy.InvalidReason
    ) -> String {
        switch reason {
        case .missingHost: return PMString("source_address_invalid_missing_host")
        case .schemeMismatch: return PMString("source_address_invalid_scheme")
        case .invalidPort: return PMString("source_address_invalid_port")
        case .invalidHost: return PMString("source_address_invalid_host")
        case .credentialsInAddress: return PMString("source_address_invalid_credentials")
        }
    }

    private static func unreachableText(
        _ reason: SourceServiceFingerprint.UnreachableReason
    ) -> String {
        switch reason {
        case .timedOut: return PMString("source_address_probe_timed_out")
        case .hostNotFound: return PMString("source_address_probe_host_not_found")
        case .tlsFailure: return PMString("source_address_probe_tls_failure")
        case .cleartextOnTLSPort: return PMString("source_address_probe_cleartext")
        case .connectionFailed: return PMString("source_address_probe_refused")
        case .cancelled: return PMString("source_address_probe_cancelled")
        case .notAttempted: return PMString("source_address_probe_not_attempted")
        }
    }
}

/// 地址区里的次要动作(移除本行、添加备用地址、仍然保存、取消探测)。
/// tvOS 没有 iOS 那种无边框链接按钮 —— 所有可聚焦元素都得有自己的高亮面,
/// 所以统一成一枚小胶囊,样式与文件里其它 `TVFocusButton` 用法一致。
struct TVSourceAddressActionButton: View {
    let title: String
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        TVFocusButton(radius: 12, scale: 1.03, lift: 0, action: action) { focused in
            Text(title)
                .tvFont(.caption, weight: .medium)
                .foregroundStyle(tint(focused: focused))
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// 两个分支都写成 `Color`:三元里混用不同的 `ShapeStyle` 类型编不过。
    private func tint(focused: Bool) -> Color {
        if isDestructive { return TVColor.bad }
        return focused ? TVColor.text : TVColor.textMuted
    }
}

/// 一行地址在电视表单里的样子:地址框 + 解读行 + 收起来的手动端口 / 协议。
struct TVSourceAddressRowView: View {
    @Binding var row: TVSourceAddressRow
    let reading: SourceAddressFormPolicy.Reading
    let sourceType: MusicSourceType
    let attempts: [SourceEndpointResolver.Attempt]
    let label: String
    let canRemove: Bool
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVFormField(label: label, text: Binding(
                get: { row.address }, set: { row.editAddress($0, sourceType: sourceType) }
            ), mono: true)
            readingLine
            dotlessToggle
            advancedOptions
            attemptList
            if canRemove {
                TVSourceAddressActionButton(
                    title: PMString("source_address_remove"),
                    isDestructive: true,
                    action: onRemove
                )
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    /// 还没开始打字时先说清这个框能吃什么;打了字就换成这一行的解读。
    @ViewBuilder
    private var readingLine: some View {
        if let text = TVSourceAddressReadingText.line(for: reading, sourceType: sourceType) {
            Text(text)
                .tvFont(.meta)
                .foregroundStyle(
                    TVSourceAddressReadingText.isProblem(reading) ? TVColor.bad : TVColor.textFaint
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 720, alignment: .leading)
        } else {
            Text(TVSourceAddressReadingText.addressPlaceholder(for: sourceType))
                .tvFont(.meta)
                .foregroundStyle(TVColor.textGhost)
                .frame(maxWidth: 720, alignment: .leading)
        }
    }

    /// 不带点的单词既可能是厂商标识也可能是内网主机名,只有用户知道。
    /// 这里的三元两边都已经是取好的 `String`,不会掉进 `Text(条件 ? "a" : "b")`
    /// 那个不做本地化的初始化器。
    @ViewBuilder
    private var dotlessToggle: some View {
        if SourceAddressFormPolicy.isAmbiguousDotlessToken(row.address, sourceType: sourceType) {
            TVSourceAddressActionButton(
                title: row.treatDotlessTokenAsHostname
                    ? PMString("source_address_treat_as_vendor")
                    : PMString("source_address_treat_as_hostname")
            ) {
                row.treatDotlessTokenAsHostname.toggle()
            }
        }
    }

    @ViewBuilder
    private var advancedOptions: some View {
        if sourceType.requiresHost {
            TVSwitchRow(
                icon: "slider.horizontal.3",
                title: PMString("source_address_advanced"),
                isOn: $row.showsAdvancedOptions
            )
            if row.showsAdvancedOptions {
                TVFormField(
                    label: PMString("ext.tv.sources.form.port"),
                    text: $row.portText,
                    mono: true
                )
                portHint
                if sourceType.usesHTTPTransport {
                    transportPicker
                }
            }
        }
    }

    /// 端口框**留空即自动**,默认值只写在提示里 —— 写进框里就会在用户改填域名
    /// 之后继续生效,那正是这次要修掉的事。
    @ViewBuilder
    private var portHint: some View {
        if row.hasInvalidManualPort {
            Text(PMString("source_address_invalid_port"))
                .tvFont(.meta)
                .foregroundStyle(TVColor.bad)
                .frame(maxWidth: 720, alignment: .leading)
        } else {
            Text(PMString("source_address_port_auto %@", defaultPortText))
                .tvFont(.meta)
                .foregroundStyle(TVColor.textFaint)
                .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var defaultPortText: String {
        String(
            sourceType.defaultPort(
                useSsl: row.transport.manualUseSsl ?? sourceType.defaultSSL
            )
        )
    }

    private var transportPicker: some View {
        Picker(PMString("source_address_transport"), selection: Binding(
            get: { row.transport }, set: { row.selectTransport($0, sourceType: sourceType) }
        )) {
            Text(PMString("source_address_transport_automatic"))
                .tag(TVSourceAddressTransportChoice.automatic)
            Text(verbatim: "HTTP").tag(TVSourceAddressTransportChoice.cleartext)
            Text(verbatim: "HTTPS").tag(TVSourceAddressTransportChoice.secure)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 720)
    }

    /// 一个候选都没应答时,把试过的每个完整地址和它不通的原因就地列出来 ——
    /// 电视上最不该做的就是弹一个「连接失败」然后什么都不说。
    @ViewBuilder
    private var attemptList: some View {
        if attempts.isEmpty == false {
            VStack(alignment: .leading, spacing: 8) {
                Text(PMString("source_address_probe_unresolved"))
                    .tvFont(.eyebrow, weight: .bold)
                    .foregroundStyle(TVColor.bad)
                ForEach(attempts) { attempt in
                    attemptRow(attempt)
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private func attemptRow(_ attempt: SourceEndpointResolver.Attempt) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(attempt.url)
                .tvFont(.meta, design: .monospaced)
                .foregroundStyle(TVColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = TVSourceAddressReadingText.attemptReasonText(attempt) {
                Text(reason)
                    .tvFont(.meta)
                    .foregroundStyle(TVColor.textFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 两步验证(6 格 OTP + 数字键盘)

struct TVOTPEntryView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: TVSource
    /// 验证通过后回调,给调用方接着做下一步(继续浏览目录、重试扫描)。
    var onVerified: () -> Void = {}

    @State private var code = ""
    @State private var error: String?
    @State private var busy = false
    /// 验证失败后这个界面会自己把输入框清空,好让用户重新输一遍。那次清空不能
    /// 顺手把刚写上去的失败原因也清掉 —— 否则用户看到的就只是输入框莫名其妙
    /// 变空,既不知道码错了还是凭据缺了,也不知道为什么没往下走。
    @State private var keepsErrorOnNextChange = false
    @FocusState private var fieldFocused: Bool

    private let keys = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "⌫", "0", "✓"]

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.45)
            TVColor.bg.opacity(0.38).ignoresSafeArea()
            HStack(alignment: .center, spacing: 100) {
                leftPrompt
                numberPad
            }
            .padding(.horizontal, 120).padding(.vertical, 90)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { fieldFocused = true }
        .onExitCommand { dismiss() }
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
                .tvFont(size: 44, weight: .bold, relativeTo: .title)
                .foregroundStyle(TVColor.text)
                .padding(.bottom, 16)
            Text(PMString("ext.tv.otp.body"))
                .tvFont(.meta).foregroundStyle(TVColor.textMuted)
                .frame(maxWidth: 520, alignment: .leading).lineSpacing(5).padding(.bottom, 28)

            // 真正的输入框而不是六个只读方格:聚焦时 Apple TV 会推送输入提示到
            // 已配对的 iPhone,在手机上打字比用遥控器点数字盘快得多。右侧数字盘
            // 保留给只有遥控器的场景。
            codeField.padding(.bottom, 18)

            if let error {
                Text(error).tvFont(.caption).foregroundStyle(TVColor.bad)
                    .frame(maxWidth: 560, alignment: .leading).lineSpacing(4)
            } else if busy {
                HStack(spacing: 12) {
                    ProgressView().tint(TVColor.brand)
                    Text(PMString("ext.tv.otp.verifying")).foregroundStyle(TVColor.textFaint)
                }
            } else {
                Text(PMString("ext.tv.otp.iphoneHint"))
                    .tvFont(.meta).foregroundStyle(TVColor.textGhost)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: 10) {
            TVTextFieldBox(mono: true) {
                TextField("", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(Text(PMString("ext.tv.otp.enterCode")))
                    .focused($fieldFocused)
                    .onChange(of: code) { _, newValue in
                        let digits = TVOneTimeCodePolicy.sanitized(newValue)
                        if digits != newValue {
                            // 这次赋值会再触发一轮,错误留给那一轮处理。
                            code = digits
                            return
                        }
                        guard !keepsErrorOnNextChange else {
                            keepsErrorOnNextChange = false
                            return
                        }
                        error = nil
                    }
                    .onSubmit(submit)
            }
            .frame(maxWidth: 520, alignment: .leading)
        }
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
                .disabled(k == "✓" && !TVOneTimeCodePolicy.isSubmittable(code))
            }
        }
        .frame(width: 332)
    }

    private func tap(_ k: String) {
        error = nil
        switch k {
        case "⌫": if !code.isEmpty { code.removeLast() }
        case "✓": submit()
        default: code = TVOneTimeCodePolicy.appending(k, to: code)
        }
    }

    private func submit() {
        guard TVOneTimeCodePolicy.isSubmittable(code), !busy else { return }
        busy = true; error = nil
        Task {
            let err = await store.login2FA(sourceID: source.id, otp: code)
            busy = false
            if let err {
                keepsErrorOnNextChange = !code.isEmpty
                code = ""
                error = err
                fieldFocused = true
            } else {
                onVerified()
                dismiss()
            }
        }
    }
}

/// 一次性验证码的输入规则。抽出来是因为遥控器数字盘与 iPhone 键盘是两条输入
/// 路径,长度与字符集必须由同一份规则约束,否则手机上能粘进字母或超长串。
enum TVOneTimeCodePolicy {
    /// 常见的 NAS / 服务端 OTP 都是 6 位数字;留到 8 位以容纳个别 8 位实现。
    static let maximumLength = 8
    static let minimumLength = 4

    /// 只留 ASCII 数字。`Character.isNumber` 还会放过全角数字和其它文字体系的
    /// 数字,那些直接发给服务端一定不匹配,不如在输入这一步就挡掉。
    static func sanitized(_ raw: String) -> String {
        String(raw.filter { $0.isASCII && $0.isNumber }.prefix(maximumLength))
    }

    static func appending(_ key: String, to code: String) -> String {
        sanitized(code + key)
    }

    static func isSubmittable(_ code: String) -> Bool {
        let digits = sanitized(code)
        return digits.count >= minimumLength && digits == code
    }
}

// MARK: - 回收站

struct TVRecycleBinView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: TVColor.brandSecondary, strength: 0.35)
            TVColor.bg.opacity(0.38).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    TVEyebrow(text: PMString("ext.tv.sources.recycleBin"))
                    Text(PMString("ext.tv.sources.recycleTitle"))
                        .tvFont(.pageTitle)
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
                                        Text(s.name).tvFont(.rowTitle).foregroundStyle(TVColor.text)
                                        Text(s.type.uppercased()).tvFont(.meta, design: .monospaced).foregroundStyle(TVColor.textFaint)
                                    }
                                    Spacer(minLength: 0)
                                    Label(PMString("ext.tv.sources.restore"), systemImage: "arrow.uturn.backward")
                                        .tvFont(.caption, weight: .semibold)
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
