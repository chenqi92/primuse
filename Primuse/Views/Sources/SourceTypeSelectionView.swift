import SwiftUI
import PrimuseKit
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct SourceTypeSelectionView<ConnectionContent: View>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ThemeService.self) private var theme
    @Environment(AppleMusicService.self) private var appleMusic
    @Environment(SourcesStore.self) private var sourceStore
    let submitIntent: AddSourceSubmitIntent
    let onAdd: (MusicSource) throws -> Void
    let onConnectionStart: (MusicSource) -> Void
    let onConnectionFinish: (MusicSource) -> Void
    let onConnectionCancel: (MusicSource) -> Void
    let connectionContent: (
        MusicSource,
        Binding<[String]>?,
        ((Bool) -> Void)?
    ) -> ConnectionContent

    init(
        submitIntent: AddSourceSubmitIntent = .save,
        onAdd: @escaping (MusicSource) throws -> Void,
        onConnectionStart: @escaping (MusicSource) -> Void,
        onConnectionFinish: @escaping (MusicSource) -> Void,
        onConnectionCancel: @escaping (MusicSource) -> Void,
        @ViewBuilder connectionContent: @escaping (
            MusicSource,
            Binding<[String]>?,
            ((Bool) -> Void)?
        ) -> ConnectionContent
    ) {
        self.submitIntent = submitIntent
        self.onAdd = onAdd
        self.onConnectionStart = onConnectionStart
        self.onConnectionFinish = onConnectionFinish
        self.onConnectionCancel = onConnectionCancel
        self.connectionContent = connectionContent
    }

    /// 选类型 / 选发现到的设备都只是弹同一个 AddSourceView。合并成单一 item 驱动
    /// 一个 .sheet —— 早先用两个 .sheet(item:) 叠在同一 view 上, 而该 view 因持续
    /// 读取 discoveryService(发现服务边扫边刷新)频繁重建, 触发 SwiftUI"同一视图多个
    /// sheet"缺陷, 把正在填的配置表单误 dismiss 回选择页。
    enum AddSourceTarget: Identifiable {
        case type(MusicSourceType)
        case device(DiscoveredDevice)
        var id: String {
            switch self {
            case .type(let type): return "type-\(type.rawValue)"
            case .device(let device): return "device-\(device.id)"
            }
        }

        var sourceType: MusicSourceType {
            switch self {
            case .type(let type): return type
            case .device(let device): return device.sourceType
            }
        }
    }
    @State private var addTarget: AddSourceTarget?
    /// Apple Music 没有表单可填 —— 点它就是请求授权, 通过之后直接建源并同步。
    @State private var isAuthorizingAppleMusic = false
    @State private var showAppleMusicAuthorizationAlert = false
    @State private var connectionSource: MusicSource?
    @State private var connectionCommitIsDeferred = false
    @State private var connectionWasCommitted = false
    @State private var discoveryService = NetworkDiscoveryService()
    #if os(macOS)
    @State private var pendingType: MusicSourceType?
    #endif
    #if os(iOS)
    @State private var showLocalImporter = false
    @State private var localImportPickerMode: LocalImportPickerMode = .referenceFolder
    @State private var localImportTask: Task<Void, Never>?
    @State private var localImportSession: LocalImportService.CopySession?
    @State private var localImportProgress: LocalImportService.CopyProgress?
    @State private var localImportAlert: LocalImportAlert?
    #endif

    var body: some View {
        content
        .sheet(item: $addTarget, onDismiss: finishConnectionFlowIfNeeded) { target in
            addFlowContent(for: target)
        }
        .alert(
            "apple_music_source_needs_authorization_title",
            isPresented: $showAppleMusicAuthorizationAlert
        ) {
            Button("open_system_settings") { openAppleMusicPrivacySettings() }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("apple_music_source_needs_authorization_message")
        }
        .onAppear { discoveryService.startDiscovery() }
        .onDisappear { discoveryService.stopDiscovery() }
    }

    /// Apple 分组:Apple Music 订阅资料库(两端都有), 外加 macOS 的本机
    /// Apple Music / iTunes 资料库。Apple Music 是系统单例, 已添加就不再列出。
    private var appleSectionTypes: [MusicSourceType] {
        var types: [MusicSourceType] = []
        if !appleMusicIsInstalled {
            types.append(.appleMusic)
        }
        #if os(macOS)
        types.append(.appleMusicLibrary)
        #endif
        return types
    }

    /// Apple Music 是系统单例音乐源:已经添加过就不再出现在"添加源"列表里。
    private var appleMusicIsInstalled: Bool {
        AppleMusicSourcePolicy.isInstalled(
            activeSourceIDs: Set(sourceStore.sources.map(\.id))
        )
    }

    /// 统一的类型入口。除 Apple Music 外都进配置表单; Apple Music 没有主机 /
    /// 凭据要填, 添加它就等于授权 + 开始同步。
    private func selectSourceType(_ type: MusicSourceType) {
        guard !type.isAwaitingPublicAPI else { return }
        guard type != .appleMusic else {
            addAppleMusicSource()
            return
        }
        addTarget = .type(type)
    }

    private func addAppleMusicSource() {
        guard !isAuthorizingAppleMusic, !appleMusicIsInstalled else { return }
        isAuthorizingAppleMusic = true
        Task { @MainActor in
            if appleMusic.authState != .authorized {
                await appleMusic.requestAuthorization()
            }
            isAuthorizingAppleMusic = false
            guard appleMusic.authState == .authorized else {
                showAppleMusicAuthorizationAlert = true
                return
            }
            // 走跟其它源同一条 onAdd:各个宿主(来源页 / 引导页)靠它收尾。
            do {
                try onAdd(AppServices.shared.appleMusicSourceRecord)
            } catch {
                plog("⛔ Apple Music source add failed: \(error.localizedDescription)")
                return
            }
            AppServices.shared.startAppleMusicSourceSync()
            dismiss()
        }
    }

    private func openAppleMusicPrivacySettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media"
        ) else { return }
        NSWorkspace.shared.open(url)
        #endif
    }

    @ViewBuilder
    private func addFlowContent(for target: AddSourceTarget) -> some View {
        #if os(macOS)
        if target.sourceType.continuesToDirectorySelectionAfterCreation,
           submitIntent == .continueToConnection {
            addFlowStep(for: target)
                // macOS fixes a sheet's size from its first step. Start the
                // combined form/browser flow at the directory browser width so
                // advancing in place cannot crop the tree view.
                .frame(minWidth: 880, idealWidth: 940, minHeight: 600, idealHeight: 680)
        } else {
            addFlowStep(for: target)
        }
        #else
        addFlowStep(for: target)
        #endif
    }

    @ViewBuilder
    private func addFlowStep(for target: AddSourceTarget) -> some View {
        if let connectionSource {
            if connectionCommitIsDeferred {
                connectionContent(
                    connectionSource,
                    deferredSelectedDirectories,
                    { connectionValidated in
                        commitDeferredConnection(connectionValidated: connectionValidated)
                    }
                )
            } else {
                connectionContent(connectionSource, nil, nil)
            }
        } else {
            switch target {
            case .type(let type):
                AddSourceView(
                    sourceType: type,
                    submitIntent: submitIntent,
                    onValidatedMediaServerSave: addValidatedMediaServerSource
                ) { source in
                    addSourceAndAdvance(source)
                }
            case .device(let device):
                AddSourceView(
                    sourceType: device.sourceType,
                    prefillDevice: device,
                    submitIntent: submitIntent,
                    onValidatedMediaServerSave: addValidatedMediaServerSource
                ) { source in
                    addSourceAndAdvance(source)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        macSheet
        #else
        NavigationStack {
            iosList
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("cancel") {
                    #if os(iOS)
                    cancelLocalImport()
                    #endif
                    dismiss()
                }
            }
        }
        #endif
    }

    // MARK: - macOS layout

    #if os(macOS)
    private var macSheet: some View {
        VStack(spacing: 0) {
            macSheetChrome

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    macDiscoverySection

                    macProtocolSection(
                        title: "Apple",
                        types: appleSectionTypes
                    )

                    ForEach(MusicSourceType.groupedByCategory, id: \.0) { category, types in
                        let filtered = types.filter { $0 != .appleMusicLibrary && $0 != .appleMusic }
                        if !filtered.isEmpty {
                            macProtocolSection(
                                title: category.displayNameFallback,
                                types: filtered
                            )
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .padding(.bottom, 80)
            }

            macSheetFooter
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 560, idealHeight: 680)
        .background(PMColor.bg.ignoresSafeArea())
        .foregroundStyle(PMColor.text)
        .tint(theme.uiAccentColor)
    }

    private var macSheetChrome: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("add_source")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text("select_source_type")
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

    private var macDiscoverySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                macSectionLabel("discovered_devices")
                if discoveryService.isDiscovering {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
                if !discoveryService.isDiscovering {
                    Button("rescan") { discoveryService.startDiscovery() }
                        .font(.system(size: 11.5))
                        .buttonStyle(.plain)
                        .foregroundStyle(PMColor.textMuted)
                }
            }

            if discoveryService.devices.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(discoveryService.isDiscovering ? "discovering_devices" : "no_files_found")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PMColor.textMuted)
                    Spacer()
                }
                .padding(12)
                .pmCard(cornerRadius: 8)
                .pmAppearFade(.contentAppear)
            } else {
                LazyVGrid(columns: macGridColumns, alignment: .leading, spacing: 8) {
                    ForEach(discoveryService.devices) { device in
                        macDeviceTile(device)
                            .pmFadeTransition(motion: .list)
                    }
                }
                .pmAppearFade(.contentAppear)
            }
        }
    }

    private func macProtocolSection(title: String, types: [MusicSourceType]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            macSectionLabelText(title)
            LazyVGrid(columns: macGridColumns, alignment: .leading, spacing: 8) {
                ForEach(types, id: \.self) { type in
                    macSourceTypeTile(type)
                }
            }
        }
    }

    private var macGridColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    private func macSourceTypeTile(_ type: MusicSourceType) -> some View {
        Button {
            guard !type.isAwaitingPublicAPI else { return }
            pendingType = type
        } label: {
            HStack(spacing: 10) {
                Text(String(type.rawValue.prefix(2)).uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.uiAccentColor)
                    .frame(width: 28, height: 28)
                    .background(theme.uiAccentColor.opacity(0.16), in: .rect(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.displayName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(type.subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                if type.isAwaitingPublicAPI {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PMColor.warn)
                } else if type.supports2FA {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PMColor.warn)
                }
                if !type.isAwaitingPublicAPI {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tileBackground(selected: pendingType == type), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(pendingType == type ? theme.uiAccentColor.opacity(0.55) : PMColor.cardBorder, lineWidth: 0.5)
            }
            .pmAnimation(.hover, value: pendingType == type)
        }
        .buttonStyle(.pmPressable)
        .disabled(type.isAwaitingPublicAPI)
        .opacity(type.isAwaitingPublicAPI ? 0.62 : 1)
        .onTapGesture(count: 2) {
            selectSourceType(type)
        }
    }

    private func macDeviceTile(_ device: DiscoveredDevice) -> some View {
        Button {
            guard !device.sourceType.isAwaitingPublicAPI else { return }
            addTarget = .device(device)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.sourceType.iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(PMColor.ok, in: .rect(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(device.sourceType.isAwaitingPublicAPI
                         ? "\(device.sourceType.displayName) · \(device.sourceType.subtitle)"
                         : "\(device.sourceType.displayName) · \(device.host)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                if device.sourceType.isAwaitingPublicAPI {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.warn)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(PMColor.ok)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pmCard(cornerRadius: 8)
        }
        .buttonStyle(.pmPressable)
        .disabled(device.sourceType.isAwaitingPublicAPI)
        .opacity(device.sourceType.isAwaitingPublicAPI ? 0.62 : 1)
    }

    private var macSheetFooter: some View {
        HStack(spacing: 10) {
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

            Button {
                if let pendingType {
                    selectSourceType(pendingType)
                }
            } label: {
                Text("next")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background((pendingType == nil || pendingType?.isAwaitingPublicAPI == true ? PMColor.textFaint : theme.uiAccentColor), in: .rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(pendingType == nil || pendingType?.isAwaitingPublicAPI == true)
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .background(PMColor.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private func macSectionLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
    }

    private func macSectionLabelText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
    }

    private func tileBackground(selected: Bool) -> Color {
        selected ? theme.uiAccentColor.opacity(0.14) : PMColor.card
    }

    /// Legacy grouped form kept as a reference for iOS parity; macOS now uses
    /// the custom SRC-01 sheet above.
    private var macForm: some View {
        Form {
            Section {
                if discoveryService.devices.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(discoveryService.isDiscovering
                             ? "discovering_devices"
                             : "no_files_found")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(discoveryService.devices) { device in
                        deviceRow(device)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text("discovered_devices")
                    if discoveryService.isDiscovering {
                        ProgressView().controlSize(.mini)
                    }
                    Spacer()
                    if !discoveryService.isDiscovering {
                        Button("rescan") { discoveryService.startDiscovery() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }
                }
            }

            // Apple Music 订阅资料库 + 本机 Apple Music / iTunes 资料库 —
            // 单独 section 置顶,避免被埋进 Local 分类底部找不到。
            Section("Apple") {
                ForEach(appleSectionTypes, id: \.self) { typeButton($0) }
            }

            // 其它来源按 category 分组,过滤掉已在上面单独展示的 appleMusicLibrary
            ForEach(MusicSourceType.groupedByCategory, id: \.0) { category, types in
                let filtered = types.filter { $0 != .appleMusicLibrary && $0 != .appleMusic }
                if !filtered.isEmpty {
                    Section(category.displayNameFallback) {
                        ForEach(filtered, id: \.self) { typeButton($0) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("select_source_type")
        .toolbarTitleDisplayMode(.inline)
    }

    /// macOS 行 — 横向布局,图标是品牌色小彩块,跟 macOS 系统设置和本应用的
    /// 音乐源卡片一致;文字两行紧贴,行高由文字决定,彩块不撑高它。
    private func typeButton(_ type: MusicSourceType) -> some View {
        Button {
            selectSourceType(type)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: type.iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(type.brandTint, in: .rect(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 1) {
                    Text(type.displayName)
                        .font(.body)
                    Text(type.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if type.isAwaitingPublicAPI {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if type.supports2FA {
                    Image(systemName: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !type.isAwaitingPublicAPI {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(type.isAwaitingPublicAPI)
    }

    private func deviceRow(_ device: DiscoveredDevice) -> some View {
        Button {
            guard !device.sourceType.isAwaitingPublicAPI else { return }
            addTarget = .device(device)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: device.sourceType.iconName)
                    .font(.system(size: 15))
                    .foregroundStyle(.green)
                    .frame(width: 22, alignment: .center)

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.body)
                    Text(device.sourceType.isAwaitingPublicAPI
                         ? "\(device.sourceType.displayName) · \(device.sourceType.subtitle)"
                         : "\(device.sourceType.displayName) · \(device.host)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: device.sourceType.isAwaitingPublicAPI
                      ? "clock.badge.exclamationmark"
                      : "plus.circle.fill")
                    .foregroundStyle(device.sourceType.isAwaitingPublicAPI ? Color.orange : Color.green)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(device.sourceType.isAwaitingPublicAPI)
    }
    #endif

    private func addSourceAndAdvance(_ source: MusicSource) {
        do {
            let continuesToConnection = submitIntent == .continueToConnection
                && source.type.continuesToConnectionAfterCreation
            let defersCommit = continuesToConnection
                && SourceCreationPersistencePolicy
                    .defersUntilValidatedDirectorySelection(for: source.type)

            if !defersCommit {
                try onAdd(source)
            }
            if continuesToConnection {
                connectionCommitIsDeferred = defersCommit
                connectionWasCommitted = !defersCommit
                onConnectionStart(source)
                connectionSource = source
            } else {
                dismiss()
            }
        } catch {
            #if os(iOS)
            localImportAlert = LocalImportAlert(
                title: String(localized: "local_import_err_title"),
                message: error.localizedDescription,
                dismissAfterOK: false
            )
            #else
            plog("⛔ Source persistence failed — \(error.localizedDescription)")
            #endif
        }
    }

    private func addValidatedMediaServerSource(_ source: MusicSource) throws {
        guard MediaServerSourceCreationPolicy.requiresPreflight(
            for: source.type,
            isEditing: false
        ) else {
            throw MediaServerSourceCreationError.missingPersistenceHandler
        }
        try onAdd(source)
        dismiss()
    }

    private var deferredSelectedDirectories: Binding<[String]> {
        Binding(
            get: { connectionSource?.scannedDirectories ?? [] },
            set: { newDirectories in
                guard var source = connectionSource else { return }
                source.extraConfig = MusicSource.encodeScannedDirectories(
                    newDirectories,
                    into: source.extraConfig,
                    type: source.type
                )
                connectionSource = source
            }
        )
    }

    private func commitDeferredConnection(connectionValidated: Bool) {
        guard connectionCommitIsDeferred,
              !connectionWasCommitted,
              let source = connectionSource,
              SourceCreationPersistencePolicy.canCommitDeferredCreation(
                  for: source.type,
                  connectionValidated: connectionValidated,
                  selectedDirectories: source.scannedDirectories
              ) else { return }

        do {
            try onAdd(source)
            connectionWasCommitted = true
            addTarget = nil
        } catch {
            #if os(iOS)
            localImportAlert = LocalImportAlert(
                title: String(localized: "credential_save_failed_title"),
                message: error.localizedDescription,
                dismissAfterOK: false
            )
            #else
            plog("⛔ Source persistence failed — \(error.localizedDescription)")
            #endif
        }
    }

    private func finishConnectionFlowIfNeeded() {
        guard let source = connectionSource else { return }
        connectionSource = nil
        if connectionCommitIsDeferred,
           SourceCreationPersistencePolicy.cancellationDisposition(
               wasPersistedBeforeFlow: false,
               wasCommittedDuringFlow: connectionWasCommitted
           ) == .discardUncommittedDraft {
            if !KeychainService.deletePassword(for: source.id) {
                plog("⛔ Draft source credential rollback failed id=\(source.id.prefix(8))…")
            }
            onConnectionCancel(source)
        } else {
            onConnectionFinish(source)
        }
        connectionCommitIsDeferred = false
        connectionWasCommitted = false
        dismiss()
    }

    // MARK: - iOS layout (unchanged from prior)

    #if os(iOS)
    private var iosList: some View {
        List {
            iosDiscoverySection
            if let localImportProgress {
                iosLocalImportProgressSection(localImportProgress)
            }

            // Apple Music 订阅资料库单独置顶。添加它等于授权并开始同步,
            // 已经添加过就不再列出来。
            if !appleSectionTypes.isEmpty {
                Section(header: Text(verbatim: "Apple")) {
                    ForEach(appleSectionTypes, id: \.self) { type in
                        Button {
                            selectSourceType(type)
                        } label: {
                            iosSourceTypeRow(type)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ForEach(MusicSourceType.groupedByCategory, id: \.0) { category, types in
                // Apple 分组已在上面单独展示, 这里不再重复列 Apple Music。
                let filtered = types.filter {
                    $0 != .local && $0 != .appleMusicLibrary && $0 != .appleMusic
                }
                if category == .local {
                    iosLocalImportSection
                } else if !filtered.isEmpty {
                    Section(header: Text(category.displayNameFallback)) {
                        ForEach(filtered, id: \.self) { type in
                            Button {
                                selectSourceType(type)
                            } label: {
                                iosSourceTypeRow(type)
                            }
                            .buttonStyle(.plain)
                            .disabled(type.isAwaitingPublicAPI)
                        }
                    }
                }
            }
        }
        .navigationTitle("select_source_type")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        // 引用与复制入口都先走 open-in-place 安全域授权。引用会持久化书签；
        // “复制到 Primuse”再由 LocalImportService 按需 materialize 并复制，
        // 避免 asCopy:true 在第三方 File Provider 上提前产出占位小文件。
        .sheet(isPresented: $showLocalImporter) {
            IOSLocalDocumentPicker(mode: localImportPickerMode) { result in
                handleLocalImport(result)
            }
        }
        .interactiveDismissDisabled(localImportProgress != nil)
        .onDisappear {
            cancelLocalImport()
        }
        .alert(item: $localImportAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("ok")) {
                    if alert.dismissAfterOK {
                        dismiss()
                    }
                }
            )
        }
    }

    /// 新选择默认保留在原位置并以安全域书签直接引用。复制仍作为显式菜单
    /// 提供；旧版本已经复制到 Documents/LocalMusic 的来源继续独立复用。
    private var iosLocalImportSection: some View {
        Section {
            NavigationLink {
                WiFiTransferView(initialMode: "receive")
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.title3).foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WiFiTransferText.string("nativeTitle"))
                        Text(WiFiTransferText.string("nativeSubtitle"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(localImportProgress != nil)
            .accessibilityIdentifier("localImport.wifi")

            Button {
                localImportPickerMode = .referenceFolder
                showLocalImporter = true
            } label: {
                iosImportRow(icon: "folder.badge.plus",
                             title: "local_import_folder_title",
                             subtitle: "local_import_folder_subtitle")
            }
            .buttonStyle(.plain)
            .disabled(localImportProgress != nil)
            .accessibilityIdentifier("localImport.folder")

            Button {
                localImportPickerMode = .referenceFiles
                showLocalImporter = true
            } label: {
                iosImportRow(icon: "doc.badge.plus",
                             title: "local_import_files_title",
                             subtitle: "local_import_files_subtitle")
            }
            .buttonStyle(.plain)
            .disabled(localImportProgress != nil)
            .accessibilityIdentifier("localImport.files")

            Menu {
                Button("local_import_copy_folder") {
                    localImportPickerMode = .copyFolder
                    showLocalImporter = true
                }
                Button("local_import_copy_files") {
                    localImportPickerMode = .copyFiles
                    showLocalImporter = true
                }
            } label: {
                iosImportRow(
                    icon: "square.and.arrow.down.on.square",
                    title: "local_import_copy_title",
                    subtitle: "local_import_copy_subtitle"
                )
            }
            .disabled(localImportProgress != nil)
            .accessibilityIdentifier("localImport.copy")
        } header: {
            Text(SourceCategory.local.displayNameFallback)
        } footer: {
            Text("local_import_section_footer")
        }
    }

    private func iosImportRow(icon: String, title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption).foregroundStyle(.secondary)
        }
        // 撑满整行 + 整块可点(否则 Spacer 空白区不响应, 只有图标/文字/箭头能点)。
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func iosLocalImportProgressSection(_ progress: LocalImportService.CopyProgress) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("local_import_progress_title")
                        .font(.body.weight(.medium))
                    Spacer()
                    Button("cancel") {
                        cancelLocalImport()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .disabled(progress.phase == .cancelling || progress.phase == .cancelled)
                    .accessibilityIdentifier("localImport.cancel")
                }

                if let fraction = progress.fraction {
                    ProgressView(value: fraction)
                        .tint(.accentColor)
                }

                Text(localImportProgressMessage(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("localImport.progress")

                if !progress.currentFileName.isEmpty {
                    Text(progress.currentFileName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func handleLocalImport(_ result: Result<[URL], Error>) {
        showLocalImporter = false
        switch result {
        case .success(let urls):
            if localImportPickerMode.copiesToPrimuse {
                startLocalImport(urls)
            } else {
                addLocalReferences(urls)
            }
        case .failure(let error):
            localImportAlert = LocalImportAlert(
                title: String(localized: "local_import_err_title"),
                message: error.localizedDescription,
                dismissAfterOK: false
            )
        }
    }

    private func addLocalReferences(_ urls: [URL]) {
        var seenPaths = Set<String>()
        let uniqueURLs = urls.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
        guard !uniqueURLs.isEmpty else { return }

        let sourceID = UUID().uuidString
        do {
            try LocalBookmarkStore.saveReferences(
                sourceID: sourceID,
                urls: uniqueURLs,
                treatingAsDirectories: localImportPickerMode.selectsFolders
            )
            let sourceName: String
            if uniqueURLs.count == 1 {
                let url = uniqueURLs[0]
                let suggestedName = localImportPickerMode.selectsFolders
                    ? url.lastPathComponent
                    : (url.lastPathComponent as NSString).deletingPathExtension
                sourceName = suggestedName.isEmpty
                    ? String(localized: "local_import_source_name")
                    : suggestedName
            } else {
                sourceName = String(
                    format: String(localized: "local_reference_source_name_format"),
                    uniqueURLs.count
                )
            }
            let source = MusicSource(
                id: sourceID,
                name: sourceName,
                type: .local,
                basePath: uniqueURLs[0].path,
                authType: .none,
                extraConfig: MusicSource.encodeScannedDirectories(["/"], into: nil, type: .local)
            )
            do {
                try onAdd(source)
            } catch {
                LocalBookmarkStore.remove(sourceID: sourceID)
                throw error
            }
            dismiss()
        } catch {
            LocalBookmarkStore.remove(sourceID: sourceID)
            localImportAlert = LocalImportAlert(
                title: String(localized: "local_import_err_title"),
                message: error.localizedDescription,
                dismissAfterOK: false
            )
        }
    }

    private func startLocalImport(_ urls: [URL]) {
        guard localImportSession == nil, localImportTask == nil else { return }
        localImportAlert = nil
        let cleanupPickedCopies = localImportPickerMode.pickerImportsCopy
        localImportProgress = LocalImportService.CopyProgress(
            phase: .discovering,
            currentFileName: "",
            processed: 0,
            total: 0,
            copied: 0,
            duplicateSkipped: 0,
            failed: 0
        )
        let session = LocalImportService.copySession(
            urls,
            cleanupPickedCopies: cleanupPickedCopies
        )
        localImportSession = session
        localImportTask = Task {
            var finalResult: LocalImportService.CopyResult?
            for await event in session.events {
                switch event {
                case .progress(let progress):
                    localImportProgress = progress
                case .finished(let result):
                    finalResult = result
                }
            }
            guard let outcome = finalResult else { return }
            localImportTask = nil
            localImportSession = nil
            localImportProgress = nil

            if outcome.cancelled { return }
            guard outcome.copied > 0 else {
                plog("📥 LocalImport: 没有可导入的音频 (选了 \(urls.count) 项)")
                localImportAlert = LocalImportAlert(
                    title: localImportFailureTitle(outcome),
                    message: localImportFailureMessage(outcome),
                    dismissAfterOK: false
                )
                return
            }

            do {
                try onAdd(LocalImportService.makeSource(
                    name: String(localized: "local_import_source_name")
                ))
            } catch {
                localImportAlert = LocalImportAlert(
                    title: String(localized: "local_import_err_title"),
                    message: error.localizedDescription,
                    dismissAfterOK: false
                )
                return
            }
            if outcome.skipped > 0 {
                localImportAlert = LocalImportAlert(
                    title: String(localized: "local_import_partial_title"),
                    message: localImportCompletionMessage(outcome),
                    dismissAfterOK: true
                )
            } else {
                dismiss()
            }
        }
    }

    private func cancelLocalImport() {
        guard let localImportSession else {
            localImportTask?.cancel()
            localImportTask = nil
            localImportProgress = nil
            return
        }
        if var current = localImportProgress {
            current.phase = .cancelling
            localImportProgress = current
        }
        localImportSession.cancel()
    }

    private func localImportProgressMessage(_ progress: LocalImportService.CopyProgress) -> String {
        switch progress.phase {
        case .discovering:
            return String(localized: "local_import_progress_discovering")
        case .indexing:
            return String(localized: "local_import_progress_indexing")
        case .copying:
            if progress.total > 0 {
                let base = String(
                    format: String(localized: "local_import_progress_copying_format"),
                    progress.processed,
                    progress.total,
                    progress.copied,
                    progress.duplicateSkipped
                )
                return base + " · " + String(
                    format: String(localized: "local_import_progress_failed_format"),
                    progress.failed
                )
            }
            return String(localized: "local_import_progress_preparing")
        case .validating:
            return String(localized: "local_import_progress_validating")
        case .committing:
            return String(localized: "local_import_progress_committing")
        case .cancelling:
            return String(localized: "local_import_progress_cancelling")
        case .finished:
            return String(localized: "local_import_progress_finishing")
        case .cancelled:
            return String(localized: "local_import_cancelled")
        }
    }

    private func localImportCompletionMessage(_ result: LocalImportService.CopyResult) -> String {
        var message = String(
            format: String(localized: "local_import_done_message_format"),
            result.copied,
            result.duplicateSkipped
        )
        message += "\n" + String(
            format: String(localized: "local_import_failed_count_format"),
            result.failed
        )
        if let firstFailure = result.failures.first {
            message += "\n" + String(
                format: String(localized: "local_import_failure_reason_format"),
                localImportFailureDescription(firstFailure)
            )
            if localImportNeedsProviderHint(firstFailure.reason) {
                message += "\n" + String(localized: "local_import_provider_hint")
            }
        }
        return message
    }

    private func localImportFailureMessage(_ result: LocalImportService.CopyResult) -> String {
        let attempted = max(result.discovered, result.skipped)
        // 网盘把后端错误响应当文件内容交出来(而非占位): 用更精准的文案直接引导内置云盘源。
        if result.copied == 0,
           let errFailure = result.failures.first(where: { $0.reason == .providerReturnedError }) {
            return String(
                format: String(localized: "local_import_provider_error_message_format"),
                attempted,
                result.skipped,
                localImportFailureDescription(errFailure)
            )
        }
        if let firstFailure = result.failures.first,
           localImportIsProviderOnlyFailure(result) {
            return String(
                format: String(localized: "local_import_provider_failure_message_format"),
                attempted,
                result.skipped,
                localImportFailureDescription(firstFailure)
            )
        }

        var message = String(
            format: String(localized: "local_import_none_added_message_format"),
            attempted,
            result.skipped
        )
        guard let firstFailure = result.failures.first else {
            return message
        }
        message += "\n" + String(
            format: String(localized: "local_import_failure_reason_format"),
            localImportFailureDescription(firstFailure)
        )
        if localImportNeedsProviderHint(firstFailure.reason) {
            message += "\n" + String(localized: "local_import_provider_hint")
        }
        return message
    }

    private func localImportFailureTitle(_ result: LocalImportService.CopyResult) -> String {
        if result.copied == 0,
           result.failures.contains(where: { $0.reason == .providerReturnedError }) {
            return String(localized: "local_import_provider_error_title")
        }
        if localImportIsProviderOnlyFailure(result) {
            return String(localized: "local_import_provider_title")
        }
        return String(localized: "local_import_err_title")
    }

    private func localImportIsProviderOnlyFailure(_ result: LocalImportService.CopyResult) -> Bool {
        result.copied == 0 && result.failures.contains { localImportNeedsProviderHint($0.reason) }
    }

    private func localImportFailureDescription(_ failure: LocalImportService.CopyFailure) -> String {
        var reason = localImportReasonText(failure.reason)
        if failure.reason == .invalidAudioFile || failure.reason == .providerReturnedError,
           let detail = failure.detail,
           !detail.isEmpty {
            reason += " (\(detail))"
        }
        return String(
            format: String(localized: "local_import_failure_item_format"),
            failure.fileName,
            reason
        )
    }

    private func localImportReasonText(_ reason: LocalImportService.FailureReason) -> String {
        switch reason {
        case .unsupportedFormat:
            return String(localized: "local_import_reason_unsupported")
        case .notFound:
            return String(localized: "local_import_reason_not_found")
        case .permissionDenied:
            return String(localized: "local_import_reason_permission")
        case .notEnoughSpace:
            return String(localized: "local_import_reason_space")
        case .coordinatedReadFailed:
            return String(localized: "local_import_reason_provider")
        case .invalidAudioFile:
            return String(localized: "local_import_reason_invalid_audio")
        case .providerReturnedError:
            return String(localized: "local_import_reason_provider_error")
        case .databaseFailed:
            return String(localized: "local_import_reason_database")
        case .copyFailed:
            return String(localized: "local_import_reason_copy")
        }
    }

    private func localImportNeedsProviderHint(_ reason: LocalImportService.FailureReason) -> Bool {
        switch reason {
        case .coordinatedReadFailed, .invalidAudioFile, .providerReturnedError:
            return true
        case .unsupportedFormat, .notFound, .permissionDenied, .notEnoughSpace, .databaseFailed, .copyFailed:
            return false
        }
    }

    private struct LocalImportAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let dismissAfterOK: Bool
    }

    /// 文件选择器允许的类型: `.audio` 父类型 + 常见具体类型, 再用扩展名兜底
    /// flac/ape/wv/dsf 等系统不一定声明为 audio 的格式, 让它们在选择器里可选。
    nonisolated fileprivate static var audioContentTypes: [UTType] {
        var set: Set<UTType> = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
        for ext in PrimuseConstants.supportedAudioExtensions {
            if let type = UTType(filenameExtension: ext) { set.insert(type) }
        }
        for ext in PrimuseConstants.supportedStreamDescriptorExtensions {
            set.insert(UTType(filenameExtension: ext) ?? UTType(exportedAs: "com.welape.primuse.\(ext)", conformingTo: .plainText))
        }
        return Array(set)
    }

    @ViewBuilder
    private var iosDiscoverySection: some View {
        Section {
            if discoveryService.isDiscovering && discoveryService.devices.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("discovering_devices").foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .pmFadeTransition(motion: .contentAppear)
            }

            ForEach(discoveryService.devices) { device in
                Button {
                    guard !device.sourceType.isAwaitingPublicAPI else { return }
                    addTarget = .device(device)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: device.sourceType.iconName)
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.green)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.body)
                            Text(device.sourceType.isAwaitingPublicAPI
                                 ? "\(device.sourceType.displayName) · \(device.sourceType.subtitle)"
                                 : "\(device.sourceType.displayName) · \(device.host)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: device.sourceType.isAwaitingPublicAPI
                              ? "clock.badge.exclamationmark"
                              : "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(device.sourceType.isAwaitingPublicAPI ? Color.orange : Color.green)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(device.sourceType.isAwaitingPublicAPI)
                .pmFadeTransition(motion: .list)
            }

            if !discoveryService.isDiscovering && !discoveryService.devices.isEmpty {
                Button {
                    discoveryService.startDiscovery()
                } label: {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("rescan")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                .pmFadeTransition(motion: .list)
            }
        } header: {
            HStack {
                Text("discovered_devices")
                if discoveryService.isDiscovering {
                    ProgressView().controlSize(.mini).padding(.leading, 4)
                }
            }
        }
    }

    private func iosSourceTypeRow(_ type: MusicSourceType) -> some View {
        HStack(spacing: 12) {
            Image(systemName: type.iconName)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(type.brandTint)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(type.displayName).font(.body)
                Text(type.subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if type.isAwaitingPublicAPI {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            } else if type.supports2FA {
                Image(systemName: "lock.shield.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !type.isAwaitingPublicAPI {
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        // 撑满整行 + 整块可点(否则 Spacer 空白区不响应, 只有图标/文字/箭头能点)。
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
    #endif
}

extension SourceTypeSelectionView where ConnectionContent == EmptyView {
    init(
        submitIntent: AddSourceSubmitIntent = .save,
        onAdd: @escaping (MusicSource) throws -> Void
    ) {
        self.init(
            submitIntent: submitIntent,
            onAdd: onAdd,
            onConnectionStart: { _ in },
            onConnectionFinish: { _ in },
            onConnectionCancel: { _ in },
            connectionContent: { _, _, _ in EmptyView() }
        )
    }
}

extension MusicSourceType: @retroactive Identifiable {
    public var id: String { rawValue }
}

private func sourceBrandColor(_ hex: UInt32) -> Color {
    Color(red: Double((hex >> 16) & 0xFF) / 255,
          green: Double((hex >> 8) & 0xFF) / 255,
          blue: Double(hex & 0xFF) / 255)
}

extension MusicSourceType {
    /// 来源图标彩块的底色。同一分组里的来源大量共用一个类别字形——9 个网盘都是
    /// `cloud.fill`,4 个 NAS 都是 `xserve`,4 个 Subsonic 实现都是 `server.rack`
    /// ——颜色是把它们分开的那条线索,所以同一分组内的取值按色相拉开。
    /// 取的是品牌近似色,不是厂商官方色值;亮度统一压到白色字形至少 3:1 对比。
    var brandTint: Color {
        switch self {
        // NAS
        case .synology: sourceBrandColor(0x2E5FA3)
        case .qnap: sourceBrandColor(0x0290B3)
        case .ugreen: sourceBrandColor(0x2F8F76)
        case .fnos: sourceBrandColor(0x7E57C2)

        // 协议
        case .webdav: sourceBrandColor(0x4B7BEC)
        case .smb: sourceBrandColor(0x6B8291)
        case .ftp: sourceBrandColor(0x8D6E63)
        case .sftp: sourceBrandColor(0x00796B)
        case .nfs: sourceBrandColor(0x6E5AA8)
        case .upnp: sourceBrandColor(0x5E35B1)
        case .s3: sourceBrandColor(0xC96F14)

        // 媒体服务器与服务端曲库
        case .jellyfin: sourceBrandColor(0x7B4FD6)
        case .emby: sourceBrandColor(0x3E9142)
        case .plex: sourceBrandColor(0xBD7E0A)
        case .subsonic: sourceBrandColor(0x2F6FED)
        case .navidrome: sourceBrandColor(0x0097A7)
        case .airsonic: sourceBrandColor(0xC2185B)
        case .gonic: sourceBrandColor(0x6D4C41)
        case .fnMusic: sourceBrandColor(0xF4511E)
        case .daoliyu: sourceBrandColor(0x8E24AA)
        case .songloft: sourceBrandColor(0x7E7E1C)
        // 与群晖直连同一色相、更深一档:两者会在「我的音乐源」里并排出现。
        case .synologyAudioStation: sourceBrandColor(0x1A4F7A)

        // 网盘
        case .baiduPan: sourceBrandColor(0x2932E1)
        case .aliyunDrive: sourceBrandColor(0xF25C00)
        case .googleDrive: sourceBrandColor(0x0E8C4E)
        case .oneDrive: sourceBrandColor(0x1789C9)
        case .dropbox: sourceBrandColor(0x0061FF)
        case .drime: sourceBrandColor(0xA13BB8)
        case .pan115: sourceBrandColor(0xD81B60)
        case .pan123: sourceBrandColor(0x00838F)
        case .guangya: sourceBrandColor(0x8A6D1F)

        // Apple 与本机
        case .appleMusic: sourceBrandColor(0xFA2D48)
        case .appleMusicLibrary: sourceBrandColor(0x5E5CE6)
        case .local: sourceBrandColor(0x5A6270)
        }
    }
}

#if os(iOS)
enum LocalImportPickerMode {
    case referenceFolder
    case referenceFiles
    case copyFolder
    case copyFiles

    var contentTypes: [UTType] {
        switch self {
        case .referenceFolder, .copyFolder:
            return [.folder]
        case .referenceFiles, .copyFiles:
            return SourceTypeSelectionView<EmptyView>.audioContentTypes
        }
    }

    var copiesToPrimuse: Bool {
        switch self {
        case .copyFolder, .copyFiles: return true
        case .referenceFolder, .referenceFiles: return false
        }
    }

    var selectsFolders: Bool {
        switch self {
        case .referenceFolder, .copyFolder: return true
        case .referenceFiles, .copyFiles: return false
        }
    }

    // 所有入口都走 open-in-place(asCopy:false): 拿到活的 security-scoped
    // provider URL, LocalImportService 才能用 startDownloadingUbiquitousItem +
    // NSFileCoordinator(.forUploading) 驱动按需 materialize。asCopy:true 时系统
    // 在导出阶段就先复制进沙箱, 第三方网盘扩展常交出占位小文件(几十字节), 而那时
    // 已是普通本地副本(非 ubiquitous), 兜底下载逻辑全部失效, 只能拒收。
    var pickerImportsCopy: Bool {
        false
    }
}

struct IOSLocalDocumentPicker: UIViewControllerRepresentable {
    let mode: LocalImportPickerMode
    let onCompletion: (Result<[URL], Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: mode.contentTypes,
            asCopy: mode.pickerImportsCopy
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        picker.view.accessibilityIdentifier = "localImport.documentPicker"
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onCompletion: (Result<[URL], Error>) -> Void

        init(onCompletion: @escaping (Result<[URL], Error>) -> Void) {
            self.onCompletion = onCompletion
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onCompletion(.success(urls))
        }
    }
}
#endif
