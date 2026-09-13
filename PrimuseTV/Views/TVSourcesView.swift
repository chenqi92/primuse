#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 音乐源 — 列出经 iCloud 同步过来的音乐源,并标出能否在 TV 播放;
/// 可在长按菜单里直接为某个源输入登录凭据、或测试连接。
struct TVSourcesView: View {
    private enum PrimaryAction: Hashable {
        case addSource
        case recycleBin
        case receive
        case metadata
    }

    @Environment(TVStore.self) private var store
    @State private var pendingDelete: TVSource?
    @State private var credentialEditor: TVSource?
    @State private var testingSourceIDs: Set<String> = []
    @State private var testResult: TVTestResult?
    @State private var queuedTestResults: [TVTestResult] = []
    @State private var typePicker = false           // 新增源:先选类型
    @State private var sourceForm: TVSourceForm?    // 新增 / 编辑源表单
    @State private var pendingSourceForm: TVSourceForm?
    @State private var pendingScanAfterSave: MusicSource?
    @State private var recycleBin = false           // 回收站
    @State private var showTransfer = false
    @State private var showsMetadata = false
    @State private var otpSource: TVSource?         // 两步验证(OTP)输入
    @State private var scanSource: MusicSource?     // 选目录 + 扫描流程
    @FocusState private var focusedPrimaryAction: PrimaryAction?

    var focusRequest = 0
    var onModalActivityChanged: (Bool) -> Void = { _ in }

    private var activePresentationCount: Int {
        [
            pendingDelete != nil,
            credentialEditor != nil,
            testResult != nil,
            typePicker,
            sourceForm != nil,
            pendingSourceForm != nil,
            pendingScanAfterSave != nil,
            recycleBin,
            showTransfer,
            showsMetadata,
            otpSource != nil,
            scanSource != nil,
        ].filter { $0 }.count
    }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            HStack(alignment: .top, spacing: 60) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(PMString("ext.tv.sources.eyebrow"))
                            .tvFont(.caption, weight: .medium).foregroundStyle(TVColor.textMuted)
                        Text(PMString("ext.tv.sources.title", store.sources.count))
                            .tvFont(.pageTitle).foregroundStyle(TVColor.text)
                            .padding(.bottom, 22)
                        if store.sources.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: "server.rack").font(.system(size: 54))
                                    .foregroundStyle(TVColor.textGhost)
                                Text(PMString("ext.tv.sources.emptyTitle")).tvFont(.rowTitle, weight: .bold).foregroundStyle(TVColor.text)
                                Text(PMString("ext.tv.sources.emptyBody"))
                                    .tvFont(.caption).foregroundStyle(TVColor.textMuted)
                                    .frame(maxWidth: 560, alignment: .leading).lineSpacing(4)
                            }
                            .padding(.top, 24)
                        } else {
                            VStack(spacing: 12) {
                                ForEach(store.sources) { s in
                                    TVSourceRow(source: s,
                                                testing: testingSourceIDs.contains(s.id),
                                                canEdit: store.source(id: s.id).map(
                                                    TVSourceEditPolicy.canEdit
                                                ) ?? false,
                                                onSelect: {
                                                    if s.status == .disabled {
                                                        store.setSourceEnabled(s.id, true)
                                                    } else if s.status == .scanning || s.needsInitialScan,
                                                       let source = store.source(id: s.id) {
                                                        scanSource = source
                                                    } else {
                                                        store.setSourceEnabled(s.id, false)
                                                    }
                                                },
                                                onToggle: {
                                                    if s.status == .scanning {
                                                        store.cancelScan(sourceID: s.id)
                                                    }
                                                    store.setSourceEnabled(
                                                        s.id,
                                                        s.status == .disabled
                                                    )
                                                },
                                                onDelete: { pendingDelete = s },
                                                onEnterCredential: { credentialEditor = s },
                                                onTestConnection: { runTest(s) },
                                                onEdit: {
                                                    if let src = store.source(id: s.id) {
                                                        sourceForm = TVSourceForm(editing: src, type: src.type)
                                                    }
                                                },
                                                onLogin2FA: { otpSource = s },
                                                onScan: { if let src = store.source(id: s.id) { scanSource = src } })
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .focusSection()

                // 右侧操作栏撑满高度,从左列任意一行往右都能到达(焦点区 frame 满高)。
                VStack(alignment: .leading, spacing: 18) {
                    Text(PMString("ext.tv.sources.addSource"))
                        .tvFont(.caption, weight: .medium).foregroundStyle(TVColor.textMuted)
                    TVSourcesInfoCard()
                    TVFocusButton(radius: 16, scale: 1.02, lift: 0, action: { showsMetadata = true }) { focused in
                        Label(PMString("tv_metadata_reread"), systemImage: "arrow.clockwise")
                            .tvFont(.meta, weight: .semibold).foregroundStyle(TVColor.text)
                            .padding(.horizontal, 24).padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(focused ? TVColor.surfaceStrong : TVColor.surface,
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .focused($focusedPrimaryAction, equals: .metadata)
                    .accessibilityIdentifier("tv.sources.metadata")
                    Button { showTransfer = true } label: {
                        Label(TVTransferText.string("receive"), systemImage: "arrow.down.circle")
                            .tvFont(.meta, weight: .semibold)
                            .foregroundStyle(focusedPrimaryAction == .receive ? TVColor.onBrand : TVColor.text)
                            .padding(.horizontal, 24).padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(focusedPrimaryAction == .receive ? TVColor.brand : TVColor.surface,
                                        in: RoundedRectangle(cornerRadius: 16))
                            .tvFocusRing(focusedPrimaryAction == .receive, radius: 16, accent: TVColor.brand, scale: 1.02, lift: 0)
                    }
                    .buttonStyle(TVBareButtonStyle()).focused($focusedPrimaryAction, equals: .receive)
                    .focusEffectDisabled().accessibilityIdentifier("tv.sources.receive")
                    Button { typePicker = true } label: {
                        Label(PMString("ext.tv.sources.addOnTV"), systemImage: "plus.circle.fill")
                            .tvFont(.meta, weight: .semibold)
                            .foregroundStyle(focusedPrimaryAction == .addSource ? TVColor.onBrand : TVColor.text)
                            .padding(.horizontal, 24).padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(focusedPrimaryAction == .addSource ? TVColor.brand : TVColor.surface,
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .tvFocusRing(
                                focusedPrimaryAction == .addSource,
                                radius: 16,
                                accent: TVColor.brand,
                                scale: 1.02,
                                lift: 0
                            )
                    }
                    .buttonStyle(TVBareButtonStyle())
                    .focused($focusedPrimaryAction, equals: .addSource)
                    .focusEffectDisabled()
                    .accessibilityLabel(PMString("ext.tv.sources.addOnTV"))
                    .accessibilityHint(PMString("ext.tv.sources.chooseTypeBody"))
                    .accessibilityIdentifier("tv.sources.addOnTV")

                    Button { recycleBin = true } label: {
                        Label(PMString("ext.tv.sources.recycleBin"), systemImage: "trash.circle")
                            .tvFont(.meta, weight: .semibold).foregroundStyle(TVColor.text)
                            .padding(.horizontal, 24).padding(.vertical, 16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(focusedPrimaryAction == .recycleBin ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .tvFocusRing(
                                focusedPrimaryAction == .recycleBin,
                                radius: 16,
                                scale: 1.02,
                                lift: 0
                            )
                    }
                    .buttonStyle(TVBareButtonStyle())
                    .focused($focusedPrimaryAction, equals: .recycleBin)
                    .focusEffectDisabled()
                    .accessibilityIdentifier("tv.sources.recycleBin")
                }
                .frame(width: 520)
                .frame(maxHeight: .infinity, alignment: .top)
                .focusSection()
            }
            .tvPage()
        }
        .onChange(of: focusRequest) { _, request in
            guard request > 0 else { return }
            focusedPrimaryAction = .addSource
        }
        .onChange(of: activePresentationCount) { _, count in
            onModalActivityChanged(count > 0)
        }
        .alert(PMString("ext.tv.sources.removeTitle"), isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { source in
            Button(PMString("ext.tv.sources.remove"), role: .destructive) {
                store.deleteSource(source.id)
                pendingDelete = nil
                restorePrimaryFocus()
            }
            Button(PMString("ext.tv.sources.cancel"), role: .cancel) {
                pendingDelete = nil
                restorePrimaryFocus()
            }
        } message: { source in
            Text(PMString("ext.tv.sources.removeBody", source.name))
        }
        .alert(PMString("ext.tv.sources.testConnection"), isPresented: Binding(
            get: { testResult != nil },
            set: { if !$0 { advanceTestResultQueue() } }
        ), presenting: testResult) { _ in
            Button(PMString("ext.tv.sources.ok"), role: .cancel) {}
        } message: { r in
            Text(PMString("ext.tv.test.resultBody", r.sourceName, r.message))
        }
        .fullScreenCover(isPresented: $showTransfer, onDismiss: restorePrimaryFocus) {
            TVTransferReceiveView().environment(store)
        }
        .fullScreenCover(isPresented: $showsMetadata, onDismiss: restorePrimaryFocus) {
            TVMetadataMaintenanceView().environment(store)
        }
        .sheet(item: $credentialEditor, onDismiss: restorePrimaryFocus) { src in
            TVCredentialEditorView(source: src).environment(store)
        }
        .fullScreenCover(isPresented: $typePicker, onDismiss: finishTypePickerDismissal) {
            TVSourceTypePicker { type, prefill in
                pendingSourceForm = TVSourceForm(
                    editing: nil,
                    type: type,
                    prefillHost: prefill?.host,
                    prefillPort: prefill?.port,
                    prefillName: prefill?.name,
                    prefillUseSsl: prefill?.useSsl
                )
                typePicker = false
            }
            .environment(store)
        }
        .fullScreenCover(item: $sourceForm, onDismiss: finishSourceFormDismissal) { form in
            TVSourceFormView(editing: form.editing, type: form.type,
                             prefillHost: form.prefillHost, prefillPort: form.prefillPort,
                             prefillName: form.prefillName,
                             prefillUseSsl: form.prefillUseSsl) { savedSource, isNew in
                if TVSourceSaveContinuationPolicy.destination(
                    isNewSource: isNew,
                    type: savedSource.type
                ) == .scan {
                    pendingScanAfterSave = savedSource
                }
            }
            .environment(store)
        }
        .fullScreenCover(isPresented: $recycleBin, onDismiss: restorePrimaryFocus) {
            TVRecycleBinView().environment(store)
        }
        .fullScreenCover(item: $otpSource, onDismiss: restorePrimaryFocus) { src in
            TVOTPEntryView(source: src).environment(store)
        }
        .fullScreenCover(item: $scanSource, onDismiss: restorePrimaryFocus) { src in
            TVScanFlowView(source: src).environment(store)
        }
        #if DEBUG
        .task {
            await openDebugScreenIfNeeded()
        }
        #endif
    }

    private func runTest(_ s: TVSource) {
        guard testingSourceIDs.insert(s.id).inserted else { return }
        Task {
            let msg = await store.testConnection(forSourceID: s.id)
            testingSourceIDs.remove(s.id)
            let completed = TVTestResult(sourceName: s.name, message: msg)
            if testResult == nil {
                testResult = completed
            } else {
                queuedTestResults.append(completed)
            }
        }
    }

    private func advanceTestResultQueue() {
        testResult = nil
        guard !queuedTestResults.isEmpty else {
            restorePrimaryFocus()
            return
        }
        let next = queuedTestResults.removeFirst()
        Task { @MainActor in
            await Task.yield()
            testResult = next
        }
    }

    private func finishTypePickerDismissal() {
        guard let nextForm = pendingSourceForm else {
            restorePrimaryFocus()
            return
        }
        pendingSourceForm = nil
        sourceForm = nextForm
    }

    private func finishSourceFormDismissal() {
        guard let source = pendingScanAfterSave else {
            restorePrimaryFocus()
            return
        }
        pendingScanAfterSave = nil
        scanSource = source
    }

    private func restorePrimaryFocus() {
        Task { @MainActor in
            await Task.yield()
            focusedPrimaryAction = .addSource
        }
    }

    #if DEBUG
    private func openDebugScreenIfNeeded() async {
        switch TVDebugLaunch.screen {
        case "sourcePicker":
            typePicker = true
        case "sourceForm":
            sourceForm = TVSourceForm(editing: nil, type: .smb)
        case "recycleBin":
            recycleBin = true
        case "credentials", "otp", "scan":
            var tries = 0
            while store.sources.isEmpty && tries < 25 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                tries += 1
            }
            let sources = store.sources
            switch TVDebugLaunch.screen {
            case "credentials": credentialEditor = sources.first(where: \.canEnterCredential)
            case "otp": otpSource = sources.first(where: \.supports2FA)
            case "scan":
                if let source = sources.first(where: \.canScan) {
                    scanSource = store.source(id: source.id)
                }
            default: break
            }
        default:
            break
        }
    }
    #endif
}

enum TVSourcePostSaveDestination: Equatable, Sendable {
    case sources
    case scan
}

enum TVSourceSaveContinuationPolicy {
    static func destination(
        isNewSource: Bool,
        type: MusicSourceType
    ) -> TVSourcePostSaveDestination {
        isNewSource && TVStore.canBuildLibraryOnTV(type)
            ? .scan
            : .sources
    }
}

private struct TVTestResult: Identifiable {
    let id = UUID()
    let sourceName: String
    let message: String
}

/// 扫码添加:Apple TV 起一个局域网接收服务并展示二维码(内含 host:port + 一次性密钥),
/// iPhone 相机扫码后把已有曲库 / 源 / 凭据 AES-GCM 加密直传过来(同一 Wi-Fi 即可,绕开 iCloud)。
private struct TVSourcesInfoCard: View {
    @Environment(TVStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "qrcode").font(.system(size: 28)).foregroundStyle(TVColor.brand)
                Text(PMString("ext.tv.sources.scanTitle")).tvFont(.rowTitle, weight: .bold).foregroundStyle(TVColor.text)
            }
            HStack(alignment: .top, spacing: 22) {
                TVQRCode(content: store.pairingQRContent, size: 190)
                VStack(alignment: .leading, spacing: 12) {
                    Text(PMString("ext.tv.sources.scanBody1"))
                        .tvFont(.caption).foregroundStyle(TVColor.textMuted).lineSpacing(5)
                    Text(PMString("ext.tv.sources.scanBody2"))
                        .tvFont(.meta).foregroundStyle(TVColor.textGhost).lineSpacing(4)
                    if !store.pairingCode.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(PMString("ext.tv.sources.confirmCode"))
                                .tvFont(.meta, weight: .semibold)
                                .foregroundStyle(TVColor.textGhost)
                            Text(verbatim: store.pairingCode)
                                .tvFont(size: 34, weight: .bold, design: .monospaced, relativeTo: .title2)
                                .foregroundStyle(TVColor.text)
                            Text(PMString("ext.tv.sources.confirmCodeHint"))
                                .tvFont(.meta)
                                .foregroundStyle(TVColor.textMuted)
                        }
                        .padding(.top, 8)
                    }
                }
            }
        }
        .padding(28).frame(maxWidth: .infinity, alignment: .leading)
        .background(TVColor.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear { store.startPairingServer() }
        .onDisappear { store.stopPairingServer() }
    }
}

private struct TVSourceRow: View {
    let source: TVSource
    var testing: Bool = false
    var canEdit = false
    var onSelect: () -> Void = {}            // 点击:启用 / 停用切换
    var onToggle: () -> Void = {}            // 长按菜单:启用 / 停用切换
    var onDelete: () -> Void = {}            // 长按菜单:从 Apple TV 移除
    var onEnterCredential: () -> Void = {}   // 长按菜单:输入登录凭据
    var onTestConnection: () -> Void = {}    // 长按菜单:测试连接
    var onEdit: () -> Void = {}              // 长按菜单:编辑连接参数
    var onLogin2FA: () -> Void = {}          // 长按菜单:两步验证登录(NAS)
    var onScan: () -> Void = {}              // 长按菜单:选目录 + 扫描(SMB)

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
                    Text(source.name).tvFont(.rowTitle)
                        .foregroundStyle(TVColor.text).lineLimit(1)
                    Text(PMString(
                        "ext.tv.sources.typeSongs",
                        MusicSourceType(rawValue: source.type)?.displayName ?? source.type.uppercased(),
                        TVFmt.count(source.songs)
                    ))
                        .tvFont(.caption, design: .monospaced)
                        .foregroundStyle(TVColor.textFaint)
                    if let availabilityNote = source.availabilityNote {
                        Label(availabilityNote, systemImage: "clock.badge.exclamationmark")
                            .tvFont(.meta, weight: .semibold)
                            .foregroundStyle(TVColor.warn)
                    }
                    if source.needsInitialScan {
                        Label(
                            PMString("ext.tv.sources.continueInitialScan"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                        .tvFont(.meta, weight: .semibold)
                        .foregroundStyle(TVColor.warn)
                    }
                }
                Spacer(minLength: 0)
                if testing {
                    ProgressView().padding(.trailing, 6)
                }
                playabilityBadge
                HStack(spacing: 8) {
                    Image(systemName: statusIcon).font(.system(size: 20))
                    Text(statusLabel).tvFont(.meta, weight: .semibold)
                }
                .foregroundStyle(statusColor)
                // 焦点提示:点击会「启用 / 停用」这个源(不再是直接删除)。
                // 常驻占位、只切换透明度 —— 之前是聚焦才插入这个图标,导致右侧
                // 状态标签和徽标每次聚焦都被挤着左移。
                Image(systemName: source.status == .disabled ? "play.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(source.status == .disabled ? TVColor.ok : TVColor.textFaint)
                    .padding(.leading, 10)
                    .opacity(focused ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 22).padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : TVColor.card)
        }
        .accessibilityHint(
            source.needsInitialScan
                ? PMString("ext.tv.sources.continueInitialScan")
                : PMString("ext.tv.sources.toggleHint")
        )
        // 长按(Siri Remote)弹菜单:启用/停用 + 输入凭证 + 测试连接 + 从 Apple TV 移除。
        .contextMenu {
            Button { onToggle() } label: {
                Label(source.status == .disabled ? PMString("ext.tv.sources.enable") : PMString("ext.tv.sources.disable"),
                      systemImage: source.status == .disabled ? "power" : "pause.circle")
            }
            if source.canEnterCredential {
                Button { onEnterCredential() } label: {
                    Label(PMString("ext.tv.sources.enterCredentials"), systemImage: "key")
                }
            }
            if canEdit {
                Button { onEdit() } label: {
                    Label(PMString("ext.tv.sources.editConnection"), systemImage: "slider.horizontal.3")
                }
            }
            if source.canScan {
                Button { onScan() } label: {
                    Label(PMString("ext.tv.sources.scanFolders"), systemImage: "folder.badge.gearshape")
                }
            }
            if source.supports2FA {
                Button { onLogin2FA() } label: {
                    Label(PMString("ext.tv.sources.login2FA"), systemImage: "lock.shield")
                }
            }
            Button { onTestConnection() } label: {
                Label(PMString("ext.tv.sources.testConnection"), systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(testing)
            Button(role: .destructive) { onDelete() } label: {
                Label(PMString("ext.tv.sources.removeFromTV"), systemImage: "trash")
            }
        }
        .accessibilityValue(Text(statusLabel))
    }

    // MARK: 可播放性徽标

    @ViewBuilder private var playabilityBadge: some View {
        if let info = badgeInfo {
            HStack(spacing: 5) {
                Image(systemName: info.icon).font(.system(size: 20))
                Text(info.label).tvFont(.meta, weight: .semibold)
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
        case .missingCredential: return (PMString("ext.tv.sources.tag.noCredentials"), TVColor.warn, "key.slash")
        case .needsRelay: return (PMString("ext.tv.sources.tag.needsRelay"), TVColor.brand, "iphone.radiowaves.left.and.right")
        case .unsupported: return (PMString("ext.tv.sources.tag.notOnTV"), TVColor.textGhost, "xmark.circle")
        }
    }

    private var statusIcon: String {
        if source.needsInitialScan { return "arrow.triangle.2.circlepath" }
        switch source.status {
        case .connected: return "circle.fill"
        case .scanning: return "arrow.triangle.2.circlepath"
        case .authFailed: return "exclamationmark.triangle.fill"
        case .disabled: return "circle"
        }
    }
    private var statusLabel: String {
        if source.needsInitialScan { return PMString("ext.tv.sources.status.pendingScan") }
        switch source.status {
        case .connected: return PMString("ext.tv.sources.status.enabled")
        case .scanning: return PMString("ext.tv.sources.status.scanning")
        case .authFailed: return PMString("ext.tv.sources.status.authFailed")
        case .disabled: return PMString("ext.tv.sources.status.disabled")
        }
    }
    private var statusColor: Color {
        if source.needsInitialScan { return TVColor.warn }
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
    @State private var saveFailed = false
    @FocusState private var focus: Field?
    private enum Field { case username, password }

    private var isFnMusic: Bool { source.type == MusicSourceType.fnMusic.rawValue }

    private var hasLocal: Bool { TVCredentialStore.hasLocalCredential(sourceID: source.id) }
    private var canSave: Bool { !password.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 手输之前先说清楚密码本可以从手机同步过来 —— 遥控器打字很贵,别让人白打。
    private var syncHint: String? {
        switch store.syncedCredentialAvailability(sourceID: source.id) {
        case .available: nil
        case .bundleMissing: PMString("ext.tv.sources.cred.syncBundleMissing")
        case .entryMissing: PMString("ext.tv.sources.cred.syncEntryMissing")
        }
    }

    /// 弹框样式:氛围底 + 居中卡片。之前是一整屏纯色背景、内容全部贴左上角,
    /// 在 16:9 电视上下方留一大片空白,看起来不像弹框而像半页空白页。
    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: source.color, tint2: TVColor.brandSecondary, strength: 0.4)
            TVColor.bg.opacity(0.5).ignoresSafeArea()
            dialogCard
                .padding(.horizontal, 90)
                .padding(.vertical, 60)
        }
        .onAppear {
            username = store.manualCredentialUsername(sourceID: source.id)
            focus = .username
        }
        .alert(PMString("ext.tv.sources.cred.saveFailedTitle"), isPresented: $saveFailed) {
            Button(PMString("ext.tv.sources.ok"), role: .cancel) {}
        } message: {
            Text(PMString("ext.tv.sources.cred.saveFailedBody"))
        }
    }

    private var dialogCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(TVColor.divider)
                .frame(height: 1)
                .padding(.top, 26).padding(.bottom, 24)
            Text(PMString("ext.tv.sources.cred.intro"))
                .tvFont(.caption).foregroundStyle(TVColor.textMuted)
                .lineSpacing(5)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let hint = syncHint {
                Label(hint, systemImage: "iphone.and.arrow.forward")
                    .tvFont(.caption).foregroundStyle(TVColor.textFaint)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
            }
            VStack(alignment: .leading, spacing: 20) {
                credentialField(icon: "person", title: PMString("ext.tv.sources.cred.username"), field: .username) {
                    TextField("", text: $username)
                        .focused($focus, equals: .username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                credentialField(icon: "lock", title: PMString("ext.tv.sources.cred.password"), field: .password) {
                    SecureField("", text: $password)
                        .focused($focus, equals: .password)
                        .textContentType(.password)
                }
            }
            .padding(.top, 28)
            if isFnMusic {
                Text(PMString("fnmusic_account_hint"))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textFaint)
                    .padding(.top, 14)
            }
            actions.padding(.top, 32)
        }
        .padding(.horizontal, 64).padding(.vertical, 52)
        .frame(maxWidth: 1080, alignment: .leading)
        // 与外观选色、播放选项等覆层用同一块面板样式,弹框观感才一致。
        .tvPanel(radius: 26)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: source.iconName)
                .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(source.color, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(PMString("ext.tv.sources.enterCredentials")).tvFont(size: 40, weight: .bold, relativeTo: .title2).foregroundStyle(TVColor.text)
                Text("\(source.name) · \(MusicSourceType(rawValue: source.type)?.displayName ?? source.type.uppercased())")
                    .tvFont(.caption, design: .monospaced).foregroundStyle(TVColor.textFaint)
            }
            Spacer(minLength: 0)
        }
    }

    private var actions: some View {
        HStack(spacing: 16) {
            TVFocusButton(radius: 14, accent: TVColor.brand, scale: 1.02, lift: 0, action: save) { focused in
                Text(PMString("ext.tv.sources.cred.saveEnable"))
                    .tvFont(.caption, weight: .semibold)
                    .foregroundStyle(canSave ? TVColor.onBrand : TVColor.textGhost)
                    .padding(.horizontal, 30).padding(.vertical, 16)
                    .frame(minWidth: 220)
                    .background(canSave ? TVColor.brand.opacity(focused ? 1 : 0.85) : TVColor.surface,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(!canSave)

            if hasLocal {
                TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: clearLocal) { focused in
                    Text(PMString("ext.tv.sources.cred.clearLocal"))
                        .tvFont(.caption, weight: .semibold).foregroundStyle(TVColor.bad)
                        .padding(.horizontal, 26).padding(.vertical, 16)
                        .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            Spacer(minLength: 0)

            TVFocusButton(radius: 14, scale: 1.02, lift: 0, action: { dismiss() }) { focused in
                Text(PMString("ext.tv.sources.cancel"))
                    .tvFont(.caption, weight: .semibold).foregroundStyle(TVColor.text)
                    .padding(.horizontal, 26).padding(.vertical, 16)
                    .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    /// 账号和密码必须是同宽同高的两格。tvOS 的原生 `TextField` / `SecureField` 会按
    /// 占位串的宽度收缩,「用户名」和「密码」字数不同,就成了一个大一个小;把标题提到
    /// 框外、占位串留空,再让输入框撑满同一列宽,两格才对齐,框内文字也由系统垂直居中。
    private func credentialField<Content: View>(
        icon: String,
        title: String,
        field: Field,
        @ViewBuilder _ content: @escaping () -> Content
    ) -> some View {
        let isFocused = focus == field
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isFocused ? TVColor.brand : TVColor.textFaint)
                    .frame(width: 26)
                Text(title).tvFont(.caption)
                    .foregroundStyle(isFocused ? TVColor.text : TVColor.textFaint)
            }
            TVTextFieldBox(isFocused: isFocused) {
                content().accessibilityLabel(title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        guard canSave else { return }
        guard store.saveManualCredential(
            sourceID: source.id,
            username: username.trimmingCharacters(in: .whitespaces),
            password: password
        ) else {
            saveFailed = true
            return
        }
        dismiss()
    }

    private func clearLocal() {
        store.clearManualCredential(sourceID: source.id)
        password = ""
        dismiss()
    }
}

struct TVMetadataMaintenanceView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSource: MusicSource?
    @State private var artistArtworkTask: Task<Void, Never>?
    @State private var artistArtworkProgress = ""

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    Text(String(localized: "metadata")).tvFont(.pageTitle)
                    Spacer()
                    TVPillButton(title: String(localized: "done"), systemImage: "xmark") { dismiss() }
                }
                HStack(alignment: .top, spacing: 48) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(PMString("tv_metadata_reread")).tvFont(.sectionTitle)
                            Text(PMString("tv_metadata_reread_body"))
                                .tvFont(.body).foregroundStyle(TVColor.textMuted)
                            Text(PMString("tv_metadata_select_source"))
                                .tvFont(.caption).foregroundStyle(TVColor.textFaint)
                            ForEach(store.sources) { source in
                                sourceRow(source)
                            }
                            if store.sources.isEmpty {
                                Text(PMString("ext.tv.sources.emptyTitle")).tvFont(.body)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusSection()
                    VStack(alignment: .leading, spacing: 20) {
                        Text(PMString("tv_complete_artist_artwork")).tvFont(.sectionTitle)
                        Text(PMString("tv_artist_artwork_source_hint"))
                            .tvFont(.body).foregroundStyle(TVColor.textMuted)
                        TVPillButton(
                            title: PMString(artistArtworkTask == nil
                                ? "tv_complete_artist_artwork" : "ext.tv.sources.cancel"),
                            systemImage: artistArtworkTask == nil ? "person.crop.circle.badge.plus" : "xmark",
                            action: refreshArtistArtwork
                        )
                        .disabled(store.artists.isEmpty)
                        .accessibilityIdentifier("tv.metadata.completeArtistArtwork")
                        if !artistArtworkProgress.isEmpty {
                            Text(artistArtworkProgress).tvFont(.caption).foregroundStyle(TVColor.textMuted)
                        }
                    }
                    .padding(28).frame(width: 440, alignment: .leading).tvPanel(radius: 20)
                    .focusSection()
                }
            }
            .padding(.horizontal, 80).padding(.vertical, 48)
        }
        .foregroundStyle(TVColor.text)
        .fullScreenCover(item: $selectedSource) { source in
            TVScanFlowView(source: source, rereadMetadata: true).environment(store)
        }
        .onExitCommand {
            if selectedSource != nil { selectedSource = nil } else { dismiss() }
        }
        .onDisappear { artistArtworkTask?.cancel(); artistArtworkTask = nil }
        .accessibilityIdentifier("tv.metadata.maintenance")
    }

    private func sourceRow(_ source: TVSource) -> some View {
        let canRead = source.canScan && source.status != .disabled
        let isServer = source.type == MusicSourceType.fnMusic.rawValue
            || source.type == MusicSourceType.daoliyu.rawValue
            || source.type == MusicSourceType.songloft.rawValue
        return TVFocusButton(radius: 16, scale: 1.0, lift: 0, action: {
            selectedSource = store.source(id: source.id)
        }) { focused in
            HStack(spacing: 20) {
                Image(systemName: source.iconName).tvFont(.sectionTitle)
                VStack(alignment: .leading, spacing: 8) {
                    Text(source.name).tvFont(.body).lineLimit(2)
                    Text(PMString(canRead
                        ? (isServer ? "tv_metadata_server_hint" : "tv_metadata_source_hint")
                        : "tv_metadata_source_unavailable"))
                        .tvFont(.caption).foregroundStyle(TVColor.textMuted)
                }
                Spacer()
                Image(systemName: "chevron.right").tvFont(.caption)
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? TVColor.surfaceStrong : TVColor.surface)
        }
        .disabled(!canRead || (store.activeScanSourceID != nil && store.activeScanSourceID != source.id))
        .accessibilityIdentifier("tv.metadata.source.\(source.id)")
    }

    private func refreshArtistArtwork() {
        if let task = artistArtworkTask { task.cancel(); artistArtworkTask = nil; return }
        let candidates = store.artists.filter { artist in
            let presentation = store.library.artworkPresentation(for: .init(kind: .artist, id: artist.id))
            return presentation.resolution == .automatic
                && store.library.visibleArtist(id: artist.id)?.thumbnailPath?.isEmpty != false
        }
        artistArtworkTask = Task { @MainActor in
            var available = 0
            var missing = 0
            for (index, artist) in candidates.enumerated() {
                guard !Task.isCancelled else { return }
                artistArtworkProgress = PMString("batch_scrape_artwork_progress_format", index + 1, candidates.count)
                let data = await ArtworkFetchService.shared.fetchArtistImage(
                    artistName: artist.name, artistID: artist.id, allowBuiltInFallback: true
                )
                guard !Task.isCancelled else { return }
                if data != nil {
                    available += 1
                    NotificationCenter.default.post(name: .primuseArtworkDidCache, object: nil,
                                                    userInfo: ["artistID": artist.id])
                } else { missing += 1 }
            }
            artistArtworkProgress = PMString("batch_scrape_artwork_counts_format", available, missing)
            artistArtworkTask = nil
        }
    }
}
#endif
