#if os(tvOS)
import SwiftUI

/// tvOS 音乐源 — 列出经 iCloud 同步过来的音乐源,并标出能否在 TV 播放;
/// 可在长按菜单里直接为某个源输入登录凭据、或测试连接。
struct TVSourcesView: View {
    @Environment(TVStore.self) private var store
    @State private var pendingDelete: TVSource?
    @State private var credentialEditor: TVSource?
    @State private var testing: String?            // 正在测试的 sourceID
    @State private var testResult: TVTestResult?

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            HStack(alignment: .top, spacing: 60) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        TVEyebrow(text: TVL("音乐源", "Music Sources"))
                        Text(TVL("音乐源 · \(store.sources.count) 个", "Music Sources · \(store.sources.count)"))
                            .font(TVFont.pageTitle).foregroundStyle(.white)
                            .padding(.bottom, 22)
                        if store.sources.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "server.rack").font(.system(size: 54))
                                    .foregroundStyle(.white.opacity(0.35))
                                Text(TVL("还没有音乐源", "No Music Sources Yet")).font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
                                Text(TVL("扫右侧二维码在手机上添加,或在 iPhone / Mac 上添加后经 iCloud 同步过来。", "Scan the QR code on the right to add one from your phone, or add it on iPhone / Mac and it syncs over via iCloud."))
                                    .font(.system(size: 18)).foregroundStyle(.white.opacity(0.6))
                                    .frame(maxWidth: 560, alignment: .leading).lineSpacing(4)
                            }
                            .padding(.top, 24)
                        } else {
                            VStack(spacing: 12) {
                                ForEach(store.sources) { s in
                                    TVSourceRow(source: s,
                                                testing: testing == s.id,
                                                onSelect: { store.setSourceEnabled(s.id, s.status == .disabled) },
                                                onDelete: { pendingDelete = s },
                                                onEnterCredential: { credentialEditor = s },
                                                onTestConnection: { runTest(s) })
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: TVL("添加音乐源", "Add a Source")).padding(.bottom, 16)
                    TVSourcesInfoCard()
                }
                .frame(width: 520)
            }
            .tvPage()
        }
        .alert(TVL("删除音乐源?", "Remove Source?"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { source in
            Button(TVL("删除", "Remove"), role: .destructive) { store.deleteSource(source.id); pendingDelete = nil }
            Button(TVL("取消", "Cancel"), role: .cancel) { pendingDelete = nil }
        } message: { source in
            Text(TVL("「\(source.name)」将从 Apple TV 移除。它在 iPhone / Mac 上仍是权威方,彻底删除请在手机/电脑上操作。", "“\(source.name)” will be removed from Apple TV. It remains authoritative on iPhone / Mac — delete it there to remove it completely."))
        }
        .alert(TVL("测试连接", "Test Connection"), isPresented: Binding(
            get: { testResult != nil },
            set: { if !$0 { testResult = nil } }
        ), presenting: testResult) { _ in
            Button(TVL("好", "OK"), role: .cancel) { testResult = nil }
        } message: { r in
            Text("「\(r.sourceName)」\n\(r.message)")
        }
        .sheet(item: $credentialEditor) { src in
            TVCredentialEditorView(source: src).environment(store)
        }
    }

    private func runTest(_ s: TVSource) {
        testing = s.id
        Task {
            let msg = await store.testConnection(forSourceID: s.id)
            testing = nil
            testResult = TVTestResult(sourceName: s.name, message: msg)
        }
    }
}

private struct TVTestResult: Identifiable {
    let id = UUID()
    let sourceName: String
    let message: String
}

/// 扫码添加:Apple TV 展示二维码,iPhone 相机扫码打开 app 的「添加音乐源」,经 iCloud 同步回来。
private struct TVSourcesInfoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "qrcode").font(.system(size: 28)).foregroundStyle(TVColor.brand)
                Text(TVL("扫码在手机上添加", "Scan to Add on Phone")).font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
            }
            HStack(alignment: .top, spacing: 22) {
                TVQRCode(content: "primuse://add-source", size: 190)
                VStack(alignment: .leading, spacing: 12) {
                    Text(TVL("用 iPhone 相机扫这个码,会打开 Primuse 到「添加音乐源」,可挨个添加 NAS / 云盘 / Subsonic 等。", "Scan this code with your iPhone camera to open Primuse at “Add a Source,” where you can add NAS, cloud drives, Subsonic, and more."))
                        .font(.system(size: 18)).foregroundStyle(.white.opacity(0.72)).lineSpacing(5)
                    Text(TVL("添加后经 iCloud 自动同步到 Apple TV;也可直接在 iPhone / Mac 上添加。", "Once added, it syncs to Apple TV automatically via iCloud. You can also add it directly on iPhone / Mac."))
                        .font(.system(size: 15)).foregroundStyle(TVColor.textGhost).lineSpacing(4)
                }
            }
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct TVSourceRow: View {
    let source: TVSource
    var testing: Bool = false
    var onSelect: () -> Void = {}            // 点击:启用 / 停用切换
    var onDelete: () -> Void = {}            // 长按菜单:从 Apple TV 移除
    var onEnterCredential: () -> Void = {}   // 长按菜单:输入登录凭据
    var onTestConnection: () -> Void = {}    // 长按菜单:测试连接

    var body: some View {
        // 不缩放:全宽行缩放会溢出 ScrollView 横向裁切,导致描边左右被裁(只剩上下)。
        TVFocusButton(radius: TVRadius.card, scale: 1.0, lift: 0, action: onSelect) { focused in
            HStack(spacing: 18) {
                // 与手机端一致:用音乐源类型对应的 SF Symbol(非渐变 + 首字母)。
                Image(systemName: source.iconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(source.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.name).font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(1)
                    Text(TVL("\(source.type.uppercased()) · \(TVFmt.count(source.songs)) 首", "\(source.type.uppercased()) · \(TVFmt.count(source.songs)) songs"))
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(TVColor.textFaint)
                }
                Spacer(minLength: 0)
                if testing {
                    ProgressView().padding(.trailing, 6)
                }
                playabilityBadge
                HStack(spacing: 8) {
                    Image(systemName: statusIcon).font(.system(size: 15))
                    Text(statusLabel).font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(statusColor)
                if focused {
                    // 焦点提示:点击会「启用 / 停用」这个源(不再是直接删除)。
                    Image(systemName: source.status == .disabled ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(source.status == .disabled ? TVColor.ok : TVColor.textFaint)
                        .padding(.leading, 10)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(focused ? Color.white.opacity(0.12) : TVColor.card)
        }
        // 长按(Siri Remote)弹菜单:启用/停用 + 输入凭证 + 测试连接 + 从 Apple TV 移除。
        .contextMenu {
            Button { onSelect() } label: {
                Label(source.status == .disabled ? TVL("启用", "Enable") : TVL("停用", "Disable"),
                      systemImage: source.status == .disabled ? "power" : "pause.circle")
            }
            if source.canEnterCredential {
                Button { onEnterCredential() } label: {
                    Label(TVL("输入登录凭据", "Enter Credentials"), systemImage: "key")
                }
            }
            Button { onTestConnection() } label: {
                Label(TVL("测试连接", "Test Connection"), systemImage: "antenna.radiowaves.left.and.right")
            }
            Button(role: .destructive) { onDelete() } label: {
                Label(TVL("从 Apple TV 移除", "Remove from Apple TV"), systemImage: "trash")
            }
        }
    }

    // MARK: 可播放性徽标

    @ViewBuilder private var playabilityBadge: some View {
        if let info = badgeInfo {
            HStack(spacing: 5) {
                Image(systemName: info.icon).font(.system(size: 13))
                Text(info.label).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(info.color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(info.color.opacity(0.16), in: Capsule())
            .padding(.trailing, 4)
        }
    }

    private var badgeInfo: (label: String, color: Color, icon: String)? {
        switch source.playability {
        case .ok: return nil
        case .missingCredential: return (TVL("缺凭据", "No Credentials"), TVColor.warn, "key.slash")
        case .needsRelay: return (TVL("需 iPhone 中继", "Needs iPhone Relay"), TVColor.brand, "iphone.radiowaves.left.and.right")
        case .unsupported: return (TVL("TV 不支持", "Not on TV"), TVColor.textGhost, "xmark.circle")
        }
    }

    private var statusIcon: String {
        switch source.status {
        case .connected: return "circle.fill"
        case .scanning: return "arrow.triangle.2.circlepath"
        case .authFailed: return "exclamationmark.triangle.fill"
        case .disabled: return "circle"
        }
    }
    private var statusLabel: String {
        switch source.status {
        case .connected: return TVL("已启用", "Enabled")
        case .scanning: return TVL("扫描中", "Scanning")
        case .authFailed: return TVL("凭据失败", "Auth Failed")
        case .disabled: return TVL("已停用", "Disabled")
        }
    }
    private var statusColor: Color {
        switch source.status {
        case .connected: return TVColor.ok
        case .scanning: return source.color
        case .authFailed: return TVColor.bad
        case .disabled: return TVColor.textGhost
        }
    }
}

// MARK: - 在 TV 上手动输入登录凭据

private struct TVCredentialEditorView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let source: TVSource

    @State private var username: String = ""
    @State private var password: String = ""
    @FocusState private var focus: Field?
    private enum Field { case username, password }

    private var hasLocal: Bool { TVCredentialStore.hasLocalCredential(sourceID: source.id) }
    private var canSave: Bool { !password.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                header
                Text(TVL("在 Apple TV 上直接为该源登录。凭据只存本机(不上传 / 不同步),并优先于从手机同步过来的凭据 —— 适合跨设备 session 不通用时。", "Sign in to this source directly on Apple TV. Credentials are stored only on this device (never uploaded or synced) and take priority over those synced from your phone — handy when sessions don’t carry across devices."))
                    .font(.system(size: 18)).foregroundStyle(TVColor.textMuted)
                    .frame(maxWidth: 760, alignment: .leading).lineSpacing(5)

                field(icon: "person", placeholder: TVL("用户名", "Username"), isFocused: focus == .username) {
                    TextField(TVL("用户名", "Username"), text: $username)
                        .focused($focus, equals: .username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.plain)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                        .focusEffectDisabled()
                }
                field(icon: "lock", placeholder: TVL("密码", "Password"), isFocused: focus == .password) {
                    SecureField(TVL("密码", "Password"), text: $password)
                        .focused($focus, equals: .password)
                        .textContentType(.password)
                        .textFieldStyle(.plain)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                        .focusEffectDisabled()
                }

                HStack(spacing: 16) {
                    TVFocusButton(radius: 14, accent: TVColor.brand, scale: 1.02, lift: 0, action: save) { focused in
                        Text(TVL("保存并启用", "Save & Enable"))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(canSave ? .white : TVColor.textGhost)
                            .padding(.horizontal, 30).padding(.vertical, 16)
                            .frame(minWidth: 220)
                            .background(canSave ? TVColor.brand.opacity(focused ? 1 : 0.85) : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .disabled(!canSave)

                    if hasLocal {
                        TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: clearLocal) { focused in
                            Text(TVL("清除本地凭据", "Clear Local Credentials"))
                                .font(.system(size: 22, weight: .semibold)).foregroundStyle(TVColor.bad)
                                .padding(.horizontal, 26).padding(.vertical, 16)
                                .background(Color.white.opacity(focused ? 0.14 : 0.06),
                                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                    }

                    TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: { dismiss() }) { focused in
                        Text(TVL("取消", "Cancel"))
                            .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 26).padding(.vertical, 16)
                            .background(Color.white.opacity(focused ? 0.14 : 0.06),
                                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 80).padding(.vertical, 70)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            username = store.manualCredentialUsername(sourceID: source.id)
            focus = .username
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: source.iconName)
                .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(source.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(TVL("输入登录凭据", "Enter Credentials")).font(.system(size: 40, weight: .bold)).foregroundStyle(.white)
                Text("\(source.name) · \(source.type.uppercased())")
                    .font(.system(size: 18, design: .monospaced)).foregroundStyle(TVColor.textFaint)
            }
        }
    }

    /// 与 TVSearchView 一致的低调焦点样式(去系统亮白高亮,聚焦时品牌色描边)。
    private func field<Content: View>(icon: String, placeholder: String, isFocused: Bool,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isFocused ? TVColor.brand : .white.opacity(0.55))
                .frame(width: 30)
            content()
        }
        .padding(.horizontal, 26).padding(.vertical, 18)
        .frame(maxWidth: 760, alignment: .leading)
        .background(Color.white.opacity(isFocused ? 0.10 : 0.06),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isFocused ? TVColor.brand : .white.opacity(0.10),
                              lineWidth: isFocused ? 2.5 : 1)
        }
    }

    private func save() {
        guard canSave else { return }
        store.saveManualCredential(sourceID: source.id,
                                   username: username.trimmingCharacters(in: .whitespaces),
                                   password: password)
        dismiss()
    }

    private func clearLocal() {
        store.clearManualCredential(sourceID: source.id)
        password = ""
        dismiss()
    }
}

#endif
