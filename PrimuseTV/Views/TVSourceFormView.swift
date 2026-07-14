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
}

// MARK: - 第 1 步:选择服务类型(全屏玻璃态网格)

struct TVSourceTypePicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TVStore.self) private var store
    /// (类型, 可选预填 host/port/name) —— 内网发现的设备会带预填。
    let onPick: (MusicSourceType, (host: String, port: Int, name: String)?) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 24), count: 5)

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: Color(hex: "#1f3a5b"), strength: 0.4)
            Color.black.opacity(0.45).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: "添加新源 · 第 1 步").padding(.bottom, 8)
                    Text("选择服务类型").font(.system(size: 52, weight: .bold)).foregroundStyle(.white)
                        .padding(.bottom, 8)
                    Text("文件型源(SMB/WebDAV/NAS)直接填地址连接 · 云盘类需在 iPhone 上 OAuth 授权后扫码同步过来")
                        .font(.system(size: 20)).foregroundStyle(TVColor.textFaint)
                        .frame(maxWidth: 1100, alignment: .leading).padding(.bottom, 36)

                    // 内网自动发现的设备(Bonjour)优先展示。
                    if !store.discoveredDevices.isEmpty {
                        TVEyebrow(text: "在本地网络发现").padding(.bottom, 14)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                            ForEach(store.discoveredDevices) { d in
                                typeCard(icon: d.sourceType.iconName, label: d.name, hint: "\(d.host):\(d.port)",
                                         badge: Self.shortProtocol(d.sourceType), accentIcon: true) {
                                    onPick(d.sourceType, (d.host, d.port, d.name))
                                }
                            }
                        }
                        .padding(.bottom, 34)
                    }

                    TVEyebrow(text: "全部类型").padding(.bottom, 14)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(Array(TVStore.addableTypes.enumerated()), id: \.element) { idx, t in
                            typeCard(icon: t.iconName, label: t.displayName, hint: Self.hint(for: t),
                                     accentIcon: idx == 0) { onPick(t, nil) }
                        }
                    }
                    Text("◯ Menu 返回 · 选择后填写连接信息或在 iPhone 上完成")
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
                          accentIcon: Bool, action: @escaping () -> Void) -> some View {
        TVFocusButton(radius: 16, scale: 1.08, lift: 10, action: action) { focused in
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: icon).font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 52, height: 52)
                        .background((focused || accentIcon) ? TVColor.brand : Color.white.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Spacer(minLength: 0)
                    if let badge {
                        // 内网发现的设备靠这个文字徽标区分协议(SMB/WebDAV 图标相近)。
                        Text(badge).font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(TVColor.brand, in: Capsule())
                    }
                }
                Spacer(minLength: 16)
                Text(label).font(.system(size: 22, weight: .bold))
                    .foregroundStyle(focused ? Color(hex: "#1f1c19") : .white).lineLimit(1)
                Text(hint).font(.system(size: 15, design: .monospaced))
                    .foregroundStyle((focused ? Color(hex: "#1f1c19") : .white).opacity(0.6)).lineLimit(1)
            }
            .padding(22).frame(height: 178, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? Color.white : Color.white.opacity(0.10))
        }
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
        case .ugreen: return "绿联"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        case .subsonic, .navidrome, .airsonic, .gonic: return "Subsonic"
        default: return t.rawValue.uppercased()
        }
    }

    static func hint(for t: MusicSourceType) -> String {
        switch t {
        case .smb: return "NAS · TrueNAS · 共享文件夹"
        case .webdav: return "群晖 · Nextcloud"
        case .ftp: return "FTP / FTPS"
        case .sftp: return "SSH 文件传输"
        case .nfs: return "NFS 共享"
        case .jellyfin, .emby, .plex: return "媒体服务器"
        case .subsonic, .navidrome, .airsonic, .gonic: return "Subsonic 协议"
        case .synology, .qnap, .fnos, .ugreen: return "NAS 音乐套件"
        default: return t.category.rawValue
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

    @State private var name = ""
    @State private var host = ""
    @State private var portText = ""
    @State private var useSsl = false
    @State private var username = ""
    @State private var password = ""
    @State private var useGuestAccess = false
    @State private var pathText = ""
    @State private var testResult: String?
    @State private var testing = false

    private var showsSSL: Bool { type.category == .mediaServer || type.category == .nas || type == .webdav }
    private var showsAuth: Bool { type != .nfs }
    private var validatedPort: Int? {
        let trimmed = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...65_535).contains(value) else { return nil }
        return value
    }
    private var canSave: Bool {
        let connectionIsValid = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validatedPort != nil
        guard connectionIsValid else { return false }
        if type.supportsAnonymous && !useGuestAccess {
            guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if editing == nil && password.isEmpty { return false }
        }
        return true
    }
    private var pathLabel: String {
        switch type {
        case .smb: return "共享名 (Share)"
        case .nfs: return "导出路径 (Export)"
        default: return "基础路径(可选)"
        }
    }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: TVColor.brand, tint2: Color(hex: "#1f3a5b"), strength: 0.4)
            Color.black.opacity(0.45).ignoresSafeArea()
            // 只让左列字段在自己列里滚动;右列作为撑满高度的固定侧栏,从任意字段往右都能到达
            //(右侧焦点区 frame 必须满高,否则下方字段往右无候选)。
            HStack(alignment: .top, spacing: 90) {
                ScrollView(.vertical, showsIndicators: false) {
                    leftFields.frame(maxWidth: .infinity, alignment: .topLeading)
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
                    TVEyebrow(text: editing == nil ? "添加新源 · 第 2 步" : "编辑连接信息")
                    Text("\(type.displayName) · 填写连接信息").font(.system(size: 36, weight: .bold)).foregroundStyle(.white)
                }
            }
            .padding(.bottom, 8)

            TVFormField(label: "名称", text: $name, autofocus: true)
            TVFormField(label: type == .nfs ? "服务器地址" : "主机 / IP", text: $host, mono: true)
            TVFormField(label: "端口", text: $portText, mono: true)
            if showsSSL {
                Toggle(isOn: $useSsl) {
                    Label("使用 HTTPS / SSL", systemImage: "lock.shield")
                        .font(.system(size: 21, weight: .medium)).foregroundStyle(.white)
                }
                .padding(.horizontal, 22).padding(.vertical, 14).frame(maxWidth: 720, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if showsAuth {
                if type.supportsAnonymous {
                    Toggle(isOn: $useGuestAccess) {
                        Label("访客模式（无需账号密码）", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 21, weight: .medium)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 14).frame(maxWidth: 720, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if !useGuestAccess {
                    TVFormField(label: "用户名", text: $username, mono: true)
                    TVFormField(label: editing == nil ? "密码" : "密码(留空则不修改)", text: $password, secure: true)
                }
            }
            TVFormField(label: pathLabel, text: $pathText, mono: true)

            HStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.system(size: 15)).foregroundStyle(TVColor.brand)
                Text("密码保存在此 Apple TV(不上传 iCloud · 手机端如需请单独输入)")
                    .font(.system(size: 16)).foregroundStyle(TVColor.textFaint)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    private var rightPanel: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Image(systemName: "keyboard").font(.system(size: 44)).foregroundStyle(.white)
                Text("用 iPhone 输入").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                Text("聚焦输入框时,已配对的 iPhone 会弹出输入提示,在手机上打字比遥控器快得多。")
                    .font(.system(size: 16)).foregroundStyle(TVColor.textFaint)
                    .multilineTextAlignment(.center).lineSpacing(4)
            }
            .padding(28).frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }

            if let testResult {
                Text(testResult).font(.system(size: 16)).foregroundStyle(TVColor.textMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }

            HStack(spacing: 14) {
                if editing != nil {
                    TVFocusButton(radius: 14, scale: 1.04, lift: 0, action: runTest) { f in
                        Group { if testing { ProgressView().tint(.white) } else { Text("测试连接") } }
                            .font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 18)
                            .background(Color.white.opacity(f ? 0.2 : 0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                TVFocusButton(radius: 14, accent: TVColor.brand, scale: 1.05, lift: 0, action: save) { f in
                    Text(editing == nil ? "添加" : "保存")
                        .font(.system(size: 20, weight: .bold)).foregroundStyle(canSave ? Color(hex: "#1f1c19") : TVColor.textGhost)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(canSave ? Color.white.opacity(f ? 1 : 0.9) : Color.white.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(!canSave)
            }
            TVFocusButton(radius: 14, scale: 1.04, lift: 0, action: { dismiss() }) { f in
                Text("取消").font(.system(size: 19, weight: .medium)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color.white.opacity(f ? 0.14 : 0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func prefill() {
        if let e = editing {
            name = e.name; host = e.host ?? ""; portText = String(e.port ?? type.defaultPort)
            useSsl = e.useSsl; username = e.username ?? ""
            useGuestAccess = type.supportsAnonymous && e.authType == .none
            switch type {
            case .smb: pathText = e.shareName ?? ""
            case .nfs: pathText = e.exportPath ?? ""
            default: pathText = e.basePath ?? ""
            }
        } else {
            host = prefillHost ?? ""
            portText = String(prefillPort ?? type.defaultPort)
            useSsl = type.defaultSSL
            name = prefillName ?? type.displayName
        }
    }

    private func runTest() {
        guard let id = editing?.id else { return }
        testing = true; testResult = nil
        Task { testResult = await store.testConnection(forSourceID: id); testing = false }
    }

    private func save() {
        guard canSave else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        let trimmedPath = pathText.trimmingCharacters(in: .whitespaces)

        var src = editing ?? MusicSource(name: trimmedName, type: type)
        src.name = trimmedName
        src.host = trimmedHost
        src.port = validatedPort
        src.useSsl = showsSSL ? useSsl : type.defaultSSL
        if showsAuth {
            src.username = useGuestAccess ? nil : (trimmedUser.isEmpty ? nil : trimmedUser)
            src.authType = useGuestAccess ? .none : .password
        } else {
            src.username = nil; src.authType = .none
        }
        switch type {
        case .smb: src.shareName = trimmedPath.isEmpty ? nil : trimmedPath
        case .nfs: src.exportPath = trimmedPath.isEmpty ? nil : trimmedPath
        default: src.basePath = trimmedPath.isEmpty ? nil : trimmedPath
        }
        src.modifiedAt = Date()

        let passwordToSave = useGuestAccess || password.isEmpty ? nil : password
        if editing == nil { store.addSource(src, password: passwordToSave) }
        else { store.updateSource(src, password: passwordToSave) }
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
            Color.black.opacity(0.4).ignoresSafeArea()
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
            TVEyebrow(text: "两步验证 · \(source.name)").padding(.bottom, 8)
            Text("输入验证码").font(.system(size: 44, weight: .bold)).foregroundStyle(.white).padding(.bottom, 16)
            Text("打开该 NAS 上的身份验证器 App,输入一次性验证码。登录成功后将记住此 Apple TV。")
                .font(.system(size: 20)).foregroundStyle(TVColor.textMuted)
                .frame(maxWidth: 520, alignment: .leading).lineSpacing(5).padding(.bottom, 36)

            HStack(spacing: 14) {
                ForEach(0..<6, id: \.self) { i in
                    let ch = i < code.count ? String(Array(code)[i]) : ""
                    Text(ch.isEmpty ? "·" : ch)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundStyle(ch.isEmpty ? TVColor.textGhost : .white)
                        .frame(width: 72, height: 92)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(i == code.count ? TVColor.brand : .white.opacity(0.16),
                                              lineWidth: i == code.count ? 3 : 0.5)
                        }
                }
            }
            if let error {
                Text(error).font(.system(size: 17)).foregroundStyle(TVColor.bad).padding(.top, 24)
            } else if busy {
                HStack(spacing: 12) { ProgressView().tint(.white); Text("验证中…").foregroundStyle(TVColor.textFaint) }
                    .padding(.top, 24)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var numberPad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(100), spacing: 16), count: 3), spacing: 16) {
            ForEach(keys, id: \.self) { k in
                TVFocusButton(radius: 50, accent: k == "✓" ? TVColor.brand : .white, scale: 1.12, lift: 6,
                              action: { tap(k) }) { focused in
                    Text(k)
                        .font(.system(size: k.count > 1 ? 30 : 40, weight: .semibold))
                        .foregroundStyle(focused ? Color(hex: "#1f1c19") : .white)
                        .frame(width: 100, height: 100)
                        .background(focused ? Color.white : (k == "✓" ? TVColor.brand : Color.white.opacity(0.10)),
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
            Color.black.opacity(0.4).ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    TVEyebrow(text: "回收站")
                    Text("最近删除").font(.system(size: 48, weight: .bold)).foregroundStyle(.white).padding(.bottom, 8)
                    let deleted = store.deletedSources
                    if deleted.isEmpty {
                        Text("没有最近删除的音乐源。").font(.system(size: 20)).foregroundStyle(TVColor.textGhost)
                    } else {
                        ForEach(deleted) { s in
                            TVFocusButton(radius: TVRadius.card, scale: 1.0, lift: 0,
                                          action: { store.restoreSource(s.id) }) { focused in
                                HStack(spacing: 18) {
                                    Image(systemName: s.iconName).font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(.white).frame(width: 46, height: 46)
                                        .background(s.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(s.name).font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                                        Text(s.type.uppercased()).font(.system(size: 15, design: .monospaced)).foregroundStyle(TVColor.textFaint)
                                    }
                                    Spacer(minLength: 0)
                                    Label("恢复", systemImage: "arrow.uturn.backward")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundStyle(focused ? TVColor.ok : TVColor.textFaint)
                                }
                                .padding(.horizontal, 22).padding(.vertical, 16).frame(maxWidth: .infinity)
                                .background(focused ? Color.white.opacity(0.12) : TVColor.card)
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
