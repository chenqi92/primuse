import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private enum SourceAlert: Identifiable {
    case confirm(SourceCacheRequest)
    case completed(SourceCacheCompletion)
    case appleMusicRemoval(MusicSource)
    #if os(iOS)
    case localImport(SourceLocalImportAlert)
    case managedCopyRemoval(MusicSource)
    #endif

    var id: String {
        switch self {
        case .confirm(let request): "confirm-\(request.id.uuidString)"
        case .completed(let completion): "completed-\(completion.id.uuidString)"
        case .appleMusicRemoval(let source): "apple-music-removal-\(source.id)"
        #if os(iOS)
        case .localImport(let alert): "local-import-\(alert.id.uuidString)"
        case .managedCopyRemoval(let source): "managed-copy-removal-\(source.id)"
        #endif
        }
    }
}

#if os(iOS)
private struct SourceLocalImportAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
#endif

private struct SourceCacheRequest: Identifiable {
    let id = UUID()
    let source: MusicSource
    let songs: [Song]
    let estimate: SourceCacheEstimate
}

private struct SourceCacheRun: Identifiable {
    let id = UUID()
    let sourceID: String
    let sourceName: String
    let songs: [Song]
    let estimate: SourceCacheEstimate
}

private struct SourceCacheCompletion: Identifiable {
    let id = UUID()
    let sourceName: String
    let result: OfflineDownloadBatchResult
}

private struct SourceCacheEstimate {
    let totalCount: Int
    let remainingCount: Int
    let alreadyCachedCount: Int
    let knownBytes: Int64
    let unknownCount: Int
    let remainingSongIDs: Set<String>
}

/// Shown on a source card while none of its addresses answers on the current
/// network. A source that only has a local address also gets the one piece of
/// advice that would have prevented the outage.
struct SourceUnreachableNotice: View {
    let source: MusicSource

    var body: some View {
        let guidance = PlaybackSourceOutageGuidance.resolve(
            routeHosts: source.connectionCandidates.map { $0.endpoint?.host }
        )
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.skin(.warning))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("source_card_unreachable")
                if guidance == .addRemoteRoute {
                    Text("source_card_unreachable_add_route_hint")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }
}

/// Presents adaptive routes as distinct, comparable endpoints instead of one
/// long subtitle. The highlighted segment is device-local runtime state and is
/// never persisted or synced with the source configuration.
struct SourceConnectionRouteStrip: View {
    let source: MusicSource
    let activeKind: SourceConnectionCandidateKind?
    let lastSuccessfulKind: SourceConnectionCandidateKind?

    private var candidates: [SourceConnectionCandidate] {
        source.connectionCandidates
    }

    var body: some View {
        HStack(spacing: 7) {
            ForEach(candidates) { candidate in
                routeSegment(candidate)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func routeSegment(_ candidate: SourceConnectionCandidate) -> some View {
        let presentation = SourceConnectionRoutePresentationState.resolve(
            candidate: candidate.kind,
            active: activeKind,
            lastSuccessful: lastSuccessfulKind
        )
        let isActive = presentation == .active
        let isRecent = presentation == .recent
        let isHighlighted = isActive || isRecent
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: iconName(for: candidate.kind))
                    .font(.system(size: 11, weight: .semibold))
                Text(title(for: candidate.kind))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 3)
                if isActive {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("current")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
                } else if isRecent {
                    HStack(spacing: 3) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("source_connection_last_used")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }
            }
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)

            Text(address(for: candidate))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .allowsTightening(true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isHighlighted ? Color.accentColor.opacity(isActive ? 0.11 : 0.065) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isHighlighted ? Color.accentColor.opacity(isActive ? 0.32 : 0.18) : Color.primary.opacity(0.075),
                    lineWidth: 0.8
                )
        }
        .pmAnimation(.hover, value: presentation)
        .accessibilityElement(children: .combine)
    }

    private func title(for kind: SourceConnectionCandidateKind) -> LocalizedStringKey {
        switch kind {
        case .localAddress:
            "source_connection_local"
        case .publicAddress:
            "source_connection_public_direct"
        case .vendorRemote:
            source.type.usesSynologyConnectionMode
                ? "synology_connection_quickconnect"
                : "fnmusic_connection_fnconnect"
        }
    }

    private func iconName(for kind: SourceConnectionCandidateKind) -> String {
        switch kind {
        case .localAddress: "wifi"
        case .publicAddress: "globe"
        case .vendorRemote: "point.3.connected.trianglepath.dotted"
        }
    }

    private func address(for candidate: SourceConnectionCandidate) -> String {
        if let endpoint = candidate.endpoint {
            return endpoint.displayDescription
        }
        return candidate.vendorIdentifier ?? source.type.displayName
    }
}

private struct SourceCacheProgressState {
    let handledCount: Int
    let completedCount: Int
    let failedCount: Int
    let totalCount: Int
    let downloadedKnownBytes: Int64
    let estimatedKnownBytes: Int64
    let unknownCount: Int

    var remainingKnownBytes: Int64 {
        max(0, estimatedKnownBytes - downloadedKnownBytes)
    }

    var fraction: Double? {
        if estimatedKnownBytes > 0 {
            return min(1, max(0, Double(downloadedKnownBytes) / Double(estimatedKnownBytes)))
        }
        guard totalCount > 0 else { return nil }
        return min(1, max(0, Double(handledCount) / Double(totalCount)))
    }
}

/// Snapshot of the scan scope when a directory picker is opened. Both source
/// screens use it to trigger one scan after the picker closes instead of
/// starting a scan for every checkbox tap.
struct SourceDirectorySelectionSession {
    let sourceID: String
    let previousDirectories: [String]
}

enum MetadataReadingText {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: "MetadataReading", bundle: .main, comment: "")
    }
}

/// 桌面端不提供这个选择 —— 见 `MetadataReadingMode.offersUserSelection`。
#if !os(macOS)
struct MetadataBackfillPerformanceButton<Label: View>: View {
    @AppStorage(MetadataBackfillExecutionPolicy.readingModeDefaultsKey)
    private var storedMode = ""
    @AppStorage(MetadataBackfillExecutionPolicy.highPerformanceAfterScanDefaultsKey)
    private var legacyFast = false
    @State private var showingFastConfirmation = false
    private let label: (MetadataReadingMode) -> Label

    init(@ViewBuilder label: @escaping (MetadataReadingMode) -> Label) { self.label = label }

    private var mode: MetadataReadingMode {
        .resolve(storedValue: storedMode, legacyFastEnabled: legacyFast)
    }

    var body: some View {
        Menu {
            Picker(MetadataReadingText.string("title"), selection: Binding(
                get: { mode }, set: { selected in
                    if selected == .fast, mode != .fast {
                        showingFastConfirmation = true
                    } else {
                        storedMode = selected.rawValue
                    }
                }
            )) {
                ForEach(MetadataReadingMode.allCases, id: \.self) { option in
                    SwiftUI.Label(MetadataReadingText.string(option.rawValue), systemImage: option.symbol)
                        .tag(option)
                }
            }
        } label: {
            label(mode)
        }
        .accessibilityLabel(MetadataReadingText.string("title"))
        .accessibilityValue(MetadataReadingText.string(mode.rawValue))
        .accessibilityIdentifier("sources.metadataBackfillPerformance")
        .sheet(isPresented: $showingFastConfirmation) {
            MetadataFastReadingConfirmation {
                storedMode = MetadataReadingMode.fast.rawValue
                AppServices.shared.metadataBackfill.continueInBackgroundForUserAction()
            }
        }
    }
}

private struct MetadataFastReadingConfirmation: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.pmHeightClass) private var heightClass
    let onConfirm: () -> Void

    /// 两颗按钮竖排要 160pt，手机横屏的 .medium 下正文只剩三十来点。
    /// 换排布方向用布局容器而不是换一棵子树，旋转时按钮的身份不变。
    private var actionLayout: AnyLayout {
        heightClass.isCompact
            ? AnyLayout(HStackLayout(spacing: 12))
            : AnyLayout(VStackLayout(spacing: 12))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title)
                    .foregroundStyle(.skin(.danger))
                    .accessibilityHidden(true)
                Text(MetadataReadingText.string("fastWarningTitle"))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(MetadataReadingText.string("fastWarningMessage"))
                    .font(.body.bold())
                    .foregroundStyle(.skin(.danger))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sources.metadataBackfillFastWarning")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionLayout {
                Button {
                    dismiss()
                    onConfirm()
                } label: {
                    Text(MetadataReadingText.string("fastWarningConfirm"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .accessibilityIdentifier("sources.metadataBackfillFastConfirm")

                Button(role: .cancel) { dismiss() } label: {
                    Text(MetadataReadingText.string("cancel"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("sources.metadataBackfillFastCancel")
            }
            .controlSize(.large)
            .padding(heightClass.value(24, compact: 16))
            .background(.background)
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        .frame(width: 440, height: 420)
        #endif
    }
}

extension MetadataReadingMode {
    var symbol: String {
        switch self {
        case .automatic: "bolt.badge.automatic"
        case .fast: "bolt.fill"
        case .energySaving: "leaf"
        case .paused: "pause.circle"
        }
    }
}
#endif

struct MetadataReadingStatusView: View {
    @Environment(MetadataBackfillService.self) private var backfill
    let sourceID: String

    var body: some View {
        if backfill.activeSourceIDs.contains(sourceID)
            || backfill.batchRereadingSourceIDs.contains(sourceID) {
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                let constraint = backfill.readingConstraint(forSource: sourceID)
                let status = MetadataReadingText.string(
                    constraint == .none ? backfill.readingMode.rawValue : constraint.rawValue
                )
                HStack(spacing: 5) {
                    Text(status)
                    if constraint != .cooling,
                       let rate = backfill.readingProgress[sourceID]?.songsPerMinute(at: .now) {
                        Text("·")
                        Text(String(
                            format: MetadataReadingText.string("rate"),
                            rate
                        ))
                        .monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Standalone sources root for callers that don't already own navigation.
struct SourcesView: View {
    var body: some View {
        NavigationStack {
            SourcesContentView()
        }
    }
}

/// Sources page content. Push this from an existing NavigationStack to avoid
/// nested stacks resetting the back button or immediately dismissing the page.
struct SourcesContentView: View {
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:工具栏按钮带上标题。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @Environment(SourceManager.self) private var sourceManager
    @Environment(\.skin) private var skin
    @Environment(SourcesStore.self) private var sourceStore
    @Environment(MusicLibrary.self) private var library
    @Environment(AppleMusicLibraryService.self) private var appleMusicLibrary
    @Environment(AppleMusicService.self) private var appleMusic
    @Environment(ScanService.self) private var scanService
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(MetadataBackfillService.self) private var backfill
    @State private var showAddSource = false
    @State private var showTransfer = false
    @State private var editingSource: MusicSource?
    @State private var connectingSource: MusicSource?
    /// 连接失败页点了「修改地址」之后要编辑的那个源。两个 sheet 不能同时在飞,
    /// 先记在这里, 等连接 sheet 的 onDismiss 里再呈现编辑表单。
    @State private var pendingAddressEditSource: MusicSource?
    @State private var directorySelectionSession: SourceDirectorySelectionSession?
    @State private var optimisticallyHiddenIDs: Set<String> = []
    @State private var undoToast: UndoDeleteToast?
    @State private var pendingDeleteTasks: [String: Task<Void, Never>] = [:]
    @State private var diagnosingSource: MusicSource?
    @State private var browsingFoldersSource: MusicSource?
    @State private var inspectingMetadataSource: MusicSource?
    @State private var inspectingLocalRemovalsSource: MusicSource?
    @State private var sourceAlert: SourceAlert?
    @State private var activeCacheRun: SourceCacheRun?
    @State private var preparingCacheSourceID: String?
    @State private var cachePreparationTask: Task<Void, Never>?
    @State private var cloudDirectoryNameRefreshID = UUID()
    /// Apple Music 授权请求在途。授权框是系统弹的, 期间按钮转圈防止重复点。
    @State private var isAuthorizingAppleMusic = false
    /// 各源磁盘占用(字节), 后台 .task 填充, 卡片读取。键为 source.id。
    @State private var sourceSizes: [String: Int64] = [:]
    #if os(iOS)
    @State private var showExistingLocalFileImporter = false
    @State private var localImportTargetSource: MusicSource?
    @State private var localImportTask: Task<Void, Never>?
    @State private var localImportSession: LocalImportService.CopySession?
    @State private var localImportProgress: LocalImportService.CopyProgress?
    #endif

    var body: some View {
        Group {
            if sources.isEmpty {
                emptyView.pmAppearFade(.contentAppear)
            } else {
                sourceList.pmAppearFade(.contentAppear)
            }
        }
            .navigationTitle("sources_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            .overlay(alignment: .bottom) {
                if let toast = undoToast {
                    undoToastView(toast)
                }
            }
            .onDisappear {
                flushPendingDeletes()
                cachePreparationTask?.cancel()
                cachePreparationTask = nil
                preparingCacheSourceID = nil
                #if os(iOS)
                cancelExistingLocalImport()
                #endif
                if let id = sourceAlert?.id {
                    AppAlertCoordinator.shared.cancel(.sourceOperation(id))
                    sourceAlert = nil
                }
            }
            .onChange(of: sourceAlert?.id, initial: true) { previousID, currentID in
                if let previousID, previousID != currentID {
                    AppAlertCoordinator.shared.cancel(.sourceOperation(previousID))
                }
                if let currentID, previousID != currentID {
                    AppAlertCoordinator.shared.enqueue(.sourceOperation(currentID))
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    #if !os(macOS)
                    MetadataBackfillPerformanceButton { mode in
                        Image(systemName: mode.symbol)
                            .foregroundStyle(mode == .fast ? Color.orange : Color.primary)
                    }
                    #endif

                    Button { showAddSource = true } label: { PMToolbarItemLabel("add_source", systemImage: "plus", titled: verticalBarEdge != nil) }
                        .accessibilityIdentifier("sources.add")
                    Button { showTransfer = true } label: {
                        Label(WiFiTransferText.string("nativeTitle"), systemImage: "laptopcomputer.and.iphone")
                    }.accessibilityIdentifier("sources.transfer")
                }
            }
            .sheet(isPresented: $showTransfer) { NavigationStack { WiFiTransferView() } }
            .sheet(isPresented: $showAddSource) {
                SourceTypeSelectionView(
                    submitIntent: .continueToConnection,
                    onAdd: { source in
                        if MediaServerSourceCreationPolicy.requiresPreflight(
                            for: source.type,
                            isEditing: false
                        ) {
                            try sourceStore.addDurably(source)
                        } else if source.type == .local {
                            try sourceStore.addDurably(source)
                        } else {
                            sourceStore.add(source)
                        }
                        // 本地导入: 文件已拷进沙箱, add 后立即扫描入库, 让导入的歌
                        // 即时出现。需要远端目录的源会在目录选择会话结束后自动扫描。
                        if source.type == .local {
                            scanService.scanSource(
                                source,
                                sourceManager: sourceManager,
                                library: library,
                                sourceStore: sourceStore,
                                scraperService: scraperService
                            )
                        } else if MediaServerSourceCreationPolicy.requiresPreflight(
                            for: source.type,
                            isEditing: false
                        ) {
                            scanService.scanSource(
                                source,
                                sourceManager: sourceManager,
                                library: library,
                                sourceStore: sourceStore,
                                scraperService: scraperService
                            )
                        }
                    },
                    onConnectionStart: { source in
                        beginDirectorySelectionSession(for: currentSource(for: source))
                    },
                    onConnectionFinish: { _ in
                        finishDirectorySelectionSession()
                    },
                    onConnectionCancel: { source in
                        cancelDirectorySelectionSession()
                        Task { await sourceManager.removeConnector(for: source.id) }
                    }
                ) { source, stagedDirectories, onConfirm in
                    connectionSheet(
                        for: currentSource(for: source),
                        stagedDirectories: stagedDirectories,
                        onConfirm: onConfirm
                    )
                }
            }
            .sheet(item: $editingSource) { source in
                AddSourceView(sourceType: source.type, editingSource: source) { updated in
                    updateSource(updated.id) { $0 = updated }
                    scanService.removeSynologyAPI(for: updated.id)
                    Task { await sourceManager.refreshConnector(for: updated.id) }
                }
            }
            .sheet(item: $connectingSource, onDismiss: finishConnectionSheet) { source in
                connectionSheet(
                    for: source,
                    onEditAddress: { requestAddressEdit(for: source) }
                )
                .onAppear { beginDirectorySelectionSession(for: source) }
            }
            .sheet(item: $diagnosingSource) { source in
                SourceDiagnosticsView(source: source)
            }
            .sheet(item: $browsingFoldersSource) { source in
                NavigationStack {
                    HomeFolderManagementView(nodeID: LibraryFolderNodeID(
                        sourceID: source.id,
                        kind: .source,
                        normalizedRelativePath: ""
                    ))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("done") { browsingFoldersSource = nil }
                        }
                    }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showExistingLocalFileImporter) {
                IOSLocalDocumentPicker(mode: .copyFiles) { result in
                    handleExistingLocalImport(result)
                }
            }
            #endif
            .alert(item: coordinatedSourceAlert) { alert in
                switch alert {
                case .confirm(let request):
                    return Alert(
                        title: Text("source_cache_all_title"),
                        message: Text(cacheConfirmationMessage(for: request)),
                        primaryButton: .default(Text("source_cache_all_confirm")) {
                            startCaching(request)
                        },
                        secondaryButton: .cancel(Text("cancel"))
                    )
                case .completed(let completion):
                    return Alert(
                        title: Text(cacheCompletionTitle(for: completion)),
                        message: Text(cacheCompletionMessage(for: completion)),
                        dismissButton: .default(Text("done"))
                    )
                case .appleMusicRemoval(let source):
                    return Alert(
                        title: Text("source_remove_apple_music_confirm_title"),
                        message: Text("source_remove_apple_music_confirm_message"),
                        primaryButton: .destructive(Text("source_remove_apple_music_confirm_action")) {
                            scheduleDelete(source)
                        },
                        secondaryButton: .cancel(Text("cancel"))
                    )
                #if os(iOS)
                case .localImport(let alert):
                    return Alert(
                        title: Text(alert.title),
                        message: Text(alert.message),
                        dismissButton: .default(Text("ok"))
                    )
                case .managedCopyRemoval(let source):
                    return Alert(
                        title: Text("source_remove_managed_confirm_title"),
                        message: Text("source_remove_managed_confirm_message"),
                        primaryButton: .destructive(Text("source_remove_managed_confirm_action")) {
                            scheduleDelete(source)
                        },
                        secondaryButton: .cancel(Text("cancel"))
                    )
                #endif
                }
            }
            .navigationDestination(item: $inspectingLocalRemovalsSource) { source in
                SourceLocalRemovalsView(source: source)
                    #if os(iOS)
                    .minimalNavigationDetail()
                    #endif
            }
            .navigationDestination(item: $inspectingMetadataSource) { source in
                SourceMetadataStatusView(source: source)
                    #if os(iOS)
                    .minimalNavigationDetail()
                    #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: CloudDirectoryNameStore.didChangeNotification)) { _ in
                cloudDirectoryNameRefreshID = UUID()
            }
    }

    private var coordinatedSourceAlert: Binding<SourceAlert?> {
        Binding(
            get: {
                guard let alert = sourceAlert,
                      AppAlertCoordinator.shared.activeRequest == .sourceOperation(alert.id) else {
                    return nil
                }
                return alert
            },
            set: { newValue, _ in
                guard newValue == nil,
                      case .sourceOperation(let id) = AppAlertCoordinator.shared.activeRequest else {
                    return
                }
                if sourceAlert?.id == id {
                    sourceAlert = nil
                }
                AppAlertCoordinator.shared.finish(.sourceOperation(id))
            }
        )
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("no_sources", systemImage: "externaldrive.badge.plus")
        } description: { Text("no_sources_desc") } actions: {
            Button { showAddSource = true } label: {
                Label("add_source", systemImage: "plus.circle.fill")
                    .font(.body).fontWeight(.semibold)
                    .frame(maxWidth: 240).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var sourceList: some View {
        // CloudDirectoryNameStore 不是可观察对象, 目录名变化只能靠这个令牌把 body 拉回来重算。
        // 卡片是本视图的私有方法, 父 body 一重算目录名就跟着重取, 所以令牌在这里读到即可,
        // 不必再拼进每张卡片的 .id ── 那样任意一个源改名都会销毁重建所有源卡片。
        _ = cloudDirectoryNameRefreshID
        let activeSourceCacheIDs = sourceManager.activeOfflineSourceCacheSourceIDs
        return SkinList {
            ForEach(groupedSources, id: \.0) { category, items in
                Section(category.displayName) {
                    ForEach(items) { source in
                        sourceCard(source, activeSourceCacheIDs: activeSourceCacheIDs)
                    }
                }
            }
        }
        .task(id: sources.map(\.id).joined(separator: ",")) {
            // 后台逐源算磁盘占用, 一次性重建字典(顺带清掉已删源的残留键)。
            // diskUsage 内部走后台枚举, 不卡主线程。只让源列表结构变化触发；
            // 扫描期间 songCount 会高频变化，把它放进 task id 会反复取消并
            // 重启整轮磁盘枚举，正是大库来源页滚动卡顿的一部分。
            var sizes: [String: Int64] = [:]
            for source in sources {
                let size = await sourceManager.diskUsage(for: source)
                if Task.isCancelled { return }
                sizes[source.id] = size
            }
            sourceSizes = sizes
        }
        .task(id: "metadata-status-\(sources.map(\.id).joined(separator: ","))") {
            // Source cards read cached, disjoint metadata counts. Refresh once
            // when the source topology changes; worker updates publish later
            // revisions without rescanning the library from every card body.
            backfill.refreshStatusSnapshot()
        }
    }

    private func sourceCard(
        _ source: MusicSource,
        activeSourceCacheIDs: Set<String>
    ) -> some View {
        let dirs = source.scannedDirectories
        // 卡片主体刻意不读 `scanStates`, 也不读整库引用 —— 这两样在扫描期间每秒
        // 都在变, 读一下就意味着整张卡片(连同长按菜单和滑动操作)跟着重建。真正
        // 跟着动的几小块各自向下订阅, 整源歌曲清单等到按下去那一刻再取。
        let hasPlayableSongs = library.sourceIDsWithPlayableSongs.contains(source.id)
        let cachePresentation = SourceCachePresentationPolicy.resolve(
            sourceID: source.id,
            preparingSourceID: preparingCacheSourceID,
            locallyTrackedBatchSourceID: activeCacheRun?.sourceID,
            activeBatchSourceIDs: activeSourceCacheIDs
        )
        let isSourceCaching = cachePresentation.isCachingCurrentSource
        let isSourceCacheBusy = cachePresentation.isCurrentSourceBusy
        let isAnotherSourceCaching = cachePresentation.isBlockedByAnotherSource
        let cacheButtonTitle: LocalizedStringKey = isSourceCacheBusy ? "source_cache_all_loading" : "source_cache_all_short"

        // 大一号卡片(组件级 `SkinComponentStyle.Card.tile`)下品牌色图标块稍放大、圆角跟着放大:卡片的第一眼是「这是哪家的源」。
        let tileCard = skin.usesTileCards
        let iconSide: CGFloat = tileCard ? 42 : 38
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: source.type.iconName)
                    .font(tileCard ? .title3.weight(.semibold) : .title3).foregroundStyle(.white)
                    .frame(width: iconSide, height: iconSide)
                    .background(source.isEnabled ? source.type.brandTint.gradient : Color.gray.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: tileCard ? 11 : 9))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(source.name).font(.body).fontWeight(tileCard ? .semibold : .medium)
                        if !source.isEnabled {
                            Text(String(localized: "disabled"))
                                .font(.caption2).fontWeight(.medium)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.skin(.danger).opacity(0.12))
                                .foregroundStyle(.skin(.danger))
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 4) {
                        Text(source.type.displayName).fixedSize()
                        if source.connectionConfiguration == nil,
                           let summary = source.connectionSummary {
                            Text("·").fixedSize()
                            Text(summary).truncationMode(.middle)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    // The endpoint can be long enough to wrap onto three lines,
                    // which pushed the trailing count badge out of alignment.
                    // Keep the whole line to one row and truncate the URL only.
                    .lineLimit(1)
                    if source.type.isAwaitingPublicAPI {
                        Label(source.type.subtitle, systemImage: "clock.badge.exclamationmark")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.skin(.warning))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    SourceSongCountBadge(sourceID: source.id, settledCount: source.songCount)
                    if let size = sourceSizes[source.id], size > 0 {
                        Text(cacheSizeDescription(knownBytes: size, unknownCount: 0))
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }

            if source.connectionConfiguration != nil,
               source.connectionCandidates.isEmpty == false {
                SourceConnectionRouteStrip(
                    source: source,
                    activeKind: sourceManager.activeConnectionRoutes[source.id],
                    lastSuccessfulKind: sourceManager.lastSuccessfulConnectionRoutes[source.id]
                )
            }

            if sourceManager.unreachablePlaybackSourceIDs.contains(source.id) {
                SourceUnreachableNotice(source: source)
            }

            if AppServices.shared.serverCatalogAutoRefresh.supportsAutomaticRefresh(source) {
                serverCatalogAutoRefreshControl(for: source)
            }

            if !dirs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(dirs, id: \.self) { dir in
                            let chip = Label(
                                directoryDisplayName(for: dir, source: source),
                                systemImage: "folder.fill"
                            )
                            .font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                            // 刚选完目录的用户就停在这张卡片上，按文件夹听歌的
                            // 入口原本只在资料库那一侧，这里把它接回来。来源
                            // 还没扫出歌时点进去只会是空列表，保持静态。
                            if !hasPlayableSongs {
                                chip
                            } else {
                                Button { browsingFoldersSource = source } label: { chip }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .pmStopsAtVerticalBar()
            }

            SourceScanStateReader(sourceID: source.id) { scanning in
                if let failureMessage = scanning?.failureMessage, !failureMessage.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Label("notify_scan_failed_title", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.skin(.danger))
                            Spacer(minLength: 8)
                            if source.type == .synologyAudioStation {
                                // 设备令牌失效后后台登录会卡在两步验证上,只有这里能再输一次验证码。
                                Button {
                                    connectingSource = source
                                } label: {
                                    Label("audio_station_sign_in", systemImage: "person.badge.key")
                                        .font(.caption2.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                            }
                            Button {
                                diagnosingSource = source
                            } label: {
                                Label("source_diagnostics_short", systemImage: "stethoscope")
                                    .font(.caption2.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                        }
                        Text(failureMessage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.skin(.danger).opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.skin(.danger).opacity(0.14), lineWidth: 0.8)
                    }
                    .pmFadeTransition(motion: .list)
                }
            }

            SourceScanStateReader(sourceID: source.id) { scanning in
                if let reconciliationMessage = scanning?.reconciliationMessage,
                   !reconciliationMessage.isEmpty {
                    Label {
                        Text(reconciliationMessage)
                            .font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.shield.fill")
                    }
                    .foregroundStyle(.skin(.warning))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.skin(.warning).opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .pmFadeTransition(motion: .list)
                }
            }

            SourceScanStateReader(sourceID: source.id) { scanning in
                if let scan = scanning, scan.isScanning || scan.canResume {
                    VStack(alignment: .leading, spacing: 4) {
                        if scan.totalCount > 0 {
                            ProgressView(value: min(scan.progress, 1.0)).tint(.accentColor)
                            HStack {
                                Text(scan.isScanning ? scan.currentFile : String(localized: "scan_resume_hint"))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text("\(scan.scannedCount)/\(scan.totalCount)").monospacedDigit()
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            // An indeterminate spinner on its own row left the
                            // trailing count stranded on the next line. Keep the
                            // spinner, the current file and the count on one row.
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.7).tint(.accentColor)
                                Text(scan.isScanning ? scan.currentFile : String(localized: "scan_resume_hint"))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text(String(format: String(localized: "new_songs_added"), scan.addedCount))
                                    .monospacedDigit()
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else if scanning?.failureMessage == nil,
                          scanning?.reconciliationMessage == nil {
                    // Phase A finished. Surface every unresolved background tag
                    // inspection for this source, including work parked behind a
                    // source circuit breaker, without implying every row issued a
                    // failed request.
                    let metadataSummary = backfill.sourceStatusSummary(forSource: source.id)
                    if metadataSummary.affectedCount > 0 {
                        metadataStatusButton(source, summary: metadataSummary)
                    }
                }
            }

            localRemovalsButton(source)

            if let progress = sourceCacheProgress(
                for: source,
                hasExplicitBatch: isSourceCaching
            ) {
                sourceCacheProgressView(progress)
            }

            #if os(iOS)
            if isManagedLocalImportSource(source),
               localImportTargetSource?.id == source.id,
               let localImportProgress {
                localImportProgressView(localImportProgress)
            }
            #endif

            if source.type == .appleMusic {
                // 设置搜索里搜 "Apple Music" 落到这儿 —— 授权与同步都在这一行上,
                // iOS 不再有单独的 Apple Music 设置页可跳。
                appleMusicSyncStatus.settingsAnchor("sources.appleMusic")
                #if os(iOS)
                if appleMusic.authState == .authorized, source.isEnabled {
                    // 系统选歌器能浏览整个 Apple Music 目录,比 Primuse 自己的搜索
                    // 覆盖面大。选中的歌先进用户的 Apple Music 资料库,再走正常同步。
                    // macOS 上没有这个入口:`musicPicker` 在 Mac 被标成 unavailable。
                    AppleMusicCatalogPickerButton {
                        appleMusicLibrary.sync()
                    }
                }
                #endif
            }

            HStack(spacing: 10) {
                if source.type == .appleMusic {
                    // Apple Music 走 ApplicationMusicPlayer, 没有目录/体检概念。
                    // 同步就是这个源的"扫描", 所以直接摆在行内, 跟别的源一致。
                    // 授权也在这一行里要回来 —— 它是这个源唯一的连接步骤, 不值得
                    // 为它单开一个只有"授权 + 同步"的设置页。
                    if appleMusic.authState == .authorized {
                        sourceActionButton(
                            appleMusicSyncTitle,
                            systemImage: "arrow.triangle.2.circlepath",
                            prominence: .success,
                            isLoading: isAppleMusicSyncing,
                            isDisabled: isAppleMusicSyncing || !source.isEnabled
                        ) {
                            appleMusicLibrary.sync()
                        }
                    } else {
                        appleMusicAuthorizationButton
                    }
                } else if source.type == .local {
                    #if os(iOS)
                    if isManagedLocalImportSource(source) {
                        let isImportingHere = localImportTargetSource?.id == source.id
                            && localImportProgress != nil
                        sourceActionButton(
                            "local_import_copy_title",
                            systemImage: "square.and.arrow.down.on.square",
                            prominence: .accent,
                            isLoading: isImportingHere,
                            isDisabled: localImportProgress != nil
                        ) {
                            presentExistingLocalImport(for: source)
                        }
                    }
                    #endif

                    SourceScanStateReader(sourceID: source.id) { scanning in
                        sourceActionButton(
                            scanning?.canResume == true ? "resume_scan" : "scan",
                            systemImage: scanning?.canResume == true ? "arrow.clockwise.circle" : "waveform.badge.magnifyingglass",
                            prominence: .success,
                            isDisabled: scanning?.isScanning == true
                        ) {
                            startSourceScan(source)
                        }
                    }
                } else if source.type.scansEntireLibrary {
                    // 整库来源直接扫描，无需再选目录。macOS Local 的范围已由
                    // 用户选定的 basePath 确定。
                    sourceActionButton(
                        cacheButtonTitle,
                        systemImage: "arrow.down.circle",
                        prominence: .accent,
                        isLoading: isSourceCacheBusy,
                        isDisabled: isSourceCacheBusy || !hasPlayableSongs || isAnotherSourceCaching
                    ) {
                        presentCacheConfirmation(for: source, songs: playableSongs(for: source))
                    }

                    SourceScanStateReader(sourceID: source.id) { scanning in
                        sourceActionButton(
                            scanning?.canResume == true ? "resume_scan" : "scan",
                            systemImage: scanning?.canResume == true ? "arrow.clockwise.circle" : "waveform.badge.magnifyingglass",
                            prominence: .success,
                            isDisabled: scanning?.isScanning == true
                        ) {
                            startSourceScan(source)
                        }
                    }
                } else {
                    sourceActionButton(
                        dirs.isEmpty ? "connect_select_dirs" : "manage_dirs",
                        systemImage: dirs.isEmpty ? "link" : "folder.badge.gear",
                        prominence: dirs.isEmpty ? .accent : .neutral
                    ) {
                        connectingSource = source
                    }

                    sourceActionButton(
                        cacheButtonTitle,
                        systemImage: "arrow.down.circle",
                        prominence: .accent,
                        isLoading: isSourceCacheBusy,
                        isDisabled: isSourceCacheBusy || !hasPlayableSongs || isAnotherSourceCaching
                    ) {
                        presentCacheConfirmation(for: source, songs: playableSongs(for: source))
                    }

                    if !dirs.isEmpty {
                        SourceScanStateReader(sourceID: source.id) { scanning in
                            sourceActionButton(
                                scanning?.canResume == true ? "resume_scan" : "scan",
                                systemImage: scanning?.canResume == true ? "arrow.clockwise.circle" : "waveform.badge.magnifyingglass",
                                prominence: .success,
                                isDisabled: scanning?.isScanning == true
                            ) {
                                startSourceScan(source)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .id(source.id)
        .opacity(source.isEnabled ? 1.0 : 0.55)
        .contextMenu {
            // Apple Music 没有 edit / diagnose 概念 ── 两者都依赖 connector。
            // 但它跟其它音乐源一样可以移除:移除即取消授权同步并清掉同步产物。
            let isSystemSource = source.id == AppleMusicLibraryService.systemSourceID
            let canBrowseFolders = hasPlayableSongs
            // 「禁用/启用」永远在, 另外两个各有条件; 只剩它一个时横排会变成
            // 一个键占满整行, 那还不如老老实实排一行。
            let usesQuickRow = canBrowseFolders || !isSystemSource

            if usesQuickRow {
                PMMenuQuickActions {
                    if canBrowseFolders {
                        Button { browsingFoldersSource = source } label: {
                            Label("library_browse_folder", systemImage: "folder")
                        }
                    }
                    if !isSystemSource {
                        Button { editingSource = source } label: { Label("edit", systemImage: "pencil") }
                    }
                    sourceEnableToggleButton(source)
                }
            } else {
                sourceEnableToggleButton(source)
            }

            if !isSystemSource {
                Section {
                    if source.type == .synologyAudioStation {
                        Button { connectingSource = source } label: {
                            Label("audio_station_sign_in", systemImage: "person.badge.key")
                        }
                    }
                    Button { diagnosingSource = source } label: { Label("source_diagnostics", systemImage: "stethoscope") }
                    if source.type.scansEntireLibrary || !dirs.isEmpty {
                        Button {
                            startSourceScan(source, mode: .deep)
                        } label: {
                            Label("source_deep_scan", systemImage: "arrow.triangle.2.circlepath.circle")
                        }
                        // 长按菜单是独立宿主, 不往里塞读 `@Environment` 的子视图;
                        // 这份集合只在"开始扫/扫完"时翻面, 读它不会把卡片拖进
                        // 每帧进度的重算里。
                        .disabled(scanService.scanningSourceIDs.contains(source.id))
                    }
                }
            }

            // 破坏性动作单独成段落在最后。
            Section {
                Button(role: .destructive) { requestDelete(source) } label: { Label("delete", systemImage: "trash") }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { requestDelete(source) } label: { Label("delete", systemImage: "trash") }
            if source.id != AppleMusicLibraryService.systemSourceID {
                Button { editingSource = source } label: { Label("edit", systemImage: "pencil") }.tint(.orange)
                Button { diagnosingSource = source } label: { Label("source_diagnostics_short", systemImage: "stethoscope") }.tint(.blue)
            }
            Button {
                toggleSourceEnabled(source)
            } label: {
                Label(
                    source.isEnabled ? String(localized: "disable") : String(localized: "enable"),
                    systemImage: source.isEnabled ? "eye.slash" : "eye"
                )
            }
            .tint(source.isEnabled ? .gray : .green)
        }
    }

    /// 长按菜单里的「禁用/启用」。横排和退回来的普通行都要它，所以抽出来一份。
    @ViewBuilder
    private func sourceEnableToggleButton(_ source: MusicSource) -> some View {
        Button {
            toggleSourceEnabled(source)
        } label: {
            Label(
                source.isEnabled ? String(localized: "disable") : String(localized: "enable"),
                systemImage: source.isEnabled ? "eye.slash" : "eye"
            )
        }
    }

    // MARK: - Apple Music 同步

    private var isAppleMusicSyncing: Bool {
        if case .syncing = appleMusicLibrary.state { return true }
        return false
    }

    private var appleMusicSyncTitle: LocalizedStringKey {
        if case .done = appleMusicLibrary.state { return "apple_music_library_resync" }
        return "apple_music_library_sync"
    }

    /// 未授权时顶替同步按钮。添加这个源时已经过过一次授权, 会走到这里的是事后
    /// 在系统设置里撤回了授权的人 —— 留一个点了只会失败的"同步"没有意义, 直接
    /// 把授权要回来。`.notDetermined` 还能就地弹系统授权框; 被拒或被屏幕使用
    /// 时间 / MDM 限制的, app 内再问系统也不会再弹, 只能送去系统设置。
    @ViewBuilder
    private var appleMusicAuthorizationButton: some View {
        switch appleMusic.authState {
        case .notDetermined:
            sourceActionButton(
                "settings_apple_music_connect",
                systemImage: "applelogo",
                prominence: .accent,
                isLoading: isAuthorizingAppleMusic,
                isDisabled: isAuthorizingAppleMusic
            ) {
                isAuthorizingAppleMusic = true
                Task { @MainActor in
                    await appleMusic.requestAuthorization()
                    isAuthorizingAppleMusic = false
                    guard appleMusic.authState == .authorized else { return }
                    appleMusicLibrary.sync()
                }
            }
        case .denied, .restricted:
            sourceActionButton(
                "open_system_settings",
                systemImage: "gear",
                prominence: .accent
            ) {
                openAppleMusicPrivacySettings()
            }
        case .authorized:
            EmptyView()
        }
    }

    private func openAppleMusicPrivacySettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #elseif os(macOS)
        // 系统设置 → 隐私与安全性 → 媒体与 Apple Music。
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media"
        ) else { return }
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Apple Music 源的"扫描进度"—— 同步状态直接显示在卡片里, 不必再跳设置页。
    @ViewBuilder
    private var appleMusicSyncStatus: some View {
        switch appleMusic.authState {
        case .denied, .restricted:
            // 授权被撤回后同步状态会停在上一次的结果上, 只显示它会让人以为是
            // 同步本身出了问题 —— 先把真正卡住这个源的那件事说清楚。
            Label(
                String(localized: "settings_apple_music_denied"),
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.skin(.warning))
        case .notDetermined, .authorized:
            // 还没授权时同步状态就是"尚未同步", 与旁边的"连接 Apple Music"
            // 按钮说的是同一件事, 不必再多一行警告。
            appleMusicSyncStateLabel
        }
    }

    @ViewBuilder
    private var appleMusicSyncStateLabel: some View {
        switch appleMusicLibrary.state {
        case .idle:
            Text("apple_music_library_idle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("apple_music_library_syncing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .done(let count, let at):
            Label(
                String(
                    format: String(localized: "apple_music_library_done_format"),
                    count,
                    Self.appleMusicSyncDateFormatter.string(from: at)
                ),
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.skin(.danger))
        }
    }

    private static let appleMusicSyncDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func serverCatalogAutoRefreshControl(for source: MusicSource) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: serverCatalogAutoRefreshBinding(for: source.id)) {
                Text("server_auto_refresh")
                    .font(.subheadline.weight(.semibold))
            }
            .toggleStyle(.switch)
            .accessibilityLabel(Text("server_auto_refresh"))
            .accessibilityHint(Text("server_auto_refresh_description"))

            if AppServices.shared.serverCatalogAutoRefresh.supportsServerScanRequest(source) {
                Divider()

                Toggle(isOn: serverCatalogScanOnLaunchBinding(for: source.id)) {
                    Text("server_scan_on_launch")
                        .font(.subheadline.weight(.semibold))
                }
                .toggleStyle(.switch)
                .disabled(!AppServices.shared.serverCatalogAutoRefresh.isEnabled(for: source.id))
                .accessibilityLabel(Text("server_scan_on_launch"))
                .accessibilityHint(Text("server_scan_on_launch_description"))
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func serverCatalogAutoRefreshBinding(for sourceID: String) -> Binding<Bool> {
        Binding(
            get: {
                AppServices.shared.serverCatalogAutoRefresh.isEnabled(for: sourceID)
            },
            set: { enabled in
                AppServices.shared.serverCatalogAutoRefresh.setEnabled(enabled, for: sourceID)
            }
        )
    }

    private func serverCatalogScanOnLaunchBinding(for sourceID: String) -> Binding<Bool> {
        Binding(
            get: {
                AppServices.shared.serverCatalogAutoRefresh
                    .isServerScanOnLaunchEnabled(for: sourceID)
            },
            set: { enabled in
                AppServices.shared.serverCatalogAutoRefresh
                    .setServerScanOnLaunchEnabled(enabled, for: sourceID)
            }
        )
    }

    /// 只有这个源确实有"本机已移除、远端还在"的行时才出现。按账本内容判断
    /// 而不是按源类型 —— WebDAV 类型上支持删除, 但具体挂载可能没权限, 按类型
    /// 判断会漏掉最典型的那一种。
    @ViewBuilder
    private func localRemovalsButton(_ source: MusicSource) -> some View {
        let count = library.locallyRemovedCount(forSourceID: source.id)
        if count > 0 {
            Button {
                inspectingLocalRemovalsSource = source
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.caption)
                    Text(verbatim: String(
                        format: String(localized: "local_removals_source_row_format"),
                        count
                    ))
                    .font(.caption.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("local_removals_title"))
        }
    }

    private func metadataStatusButton(
        _ source: MusicSource,
        summary: MetadataBackfillSourceSummary
    ) -> some View {
        let activityState = backfill.activityState(forSource: source.id)
        return Button {
            inspectingMetadataSource = source
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    metadataActivityIndicator(activityState)
                    Text(metadataActivityTitle(activityState))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 8)
                    Text("metadata_status_open")
                        .font(.caption2.weight(.semibold))
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                Text(metadataSummaryText(summary))
                    .font(.caption2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                MetadataReadingStatusView(sourceID: source.id)
            }
            .foregroundStyle(.secondary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("metadata_status_open"))
        .accessibilityValue(Text(metadataSummaryText(summary)))
        .accessibilityIdentifier("sources.metadataStatus.\(source.id)")
    }

    @ViewBuilder
    private func metadataActivityIndicator(_ state: MetadataBackfillActivityState) -> some View {
        switch state {
        case .running, .retrying:
            ProgressView().scaleEffect(0.7).tint(.secondary)
        case .waitingForWiFi:
            Image(systemName: "wifi.exclamationmark")
        case .retryPending:
            Image(systemName: "arrow.clockwise.circle")
        case .pending:
            Image(systemName: "clock")
        case .idle:
            Image(systemName: "exclamationmark.circle")
        }
    }

    private func metadataActivityTitle(
        _ state: MetadataBackfillActivityState
    ) -> LocalizedStringKey {
        switch state {
        case .running: "backfill_in_progress"
        case .retrying: "backfill_retry_in_progress"
        case .waitingForWiFi: "backfill_waiting_for_wifi"
        case .retryPending: "metadata_status_state_retry"
        case .pending, .idle: "metadata_status_title"
        }
    }

    private func metadataSummaryText(_ summary: MetadataBackfillSourceSummary) -> String {
        var parts: [String] = []
        if summary.activeQueueCount > 0 {
            parts.append(String(
                format: String(localized: "metadata_status_card_pending_format"),
                summary.activeQueueCount
            ))
        }
        if summary.retryPendingCount > 0 {
            parts.append(String(
                format: String(localized: "metadata_status_card_retry_format"),
                summary.retryPendingCount
            ))
        }
        let sourceProblems = summary.sourceUnavailableCount + summary.fileUnavailableCount
        if sourceProblems > 0 {
            parts.append(String(
                format: String(localized: "metadata_status_card_source_problem_format"),
                sourceProblems
            ))
        }
        if summary.unreadableTagsCount > 0 {
            parts.append(String(
                format: String(localized: "metadata_status_card_unreadable_format"),
                summary.unreadableTagsCount
            ))
        }
        if summary.playableIncompleteCount > 0 {
            parts.append(String(
                format: String(localized: "metadata_status_card_incomplete_format"),
                summary.playableIncompleteCount
            ))
        }
        if summary.stalledCount > 0 {
            parts.append(String(
                format: String(localized: "metadata_status_card_stalled_format"),
                summary.stalledCount
            ))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Helpers

    private enum SourceActionProminence {
        case neutral
        case accent
        case success
    }

    private func sourceActionButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        prominence: SourceActionProminence = .neutral,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(sourceActionForeground(for: prominence))
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 18, height: 18)
                }
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .padding(.horizontal, 8)
            .foregroundStyle(sourceActionForeground(for: prominence))
            .background {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(sourceActionBackground(for: prominence))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(sourceActionStroke(for: prominence), lineWidth: 0.8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled && !isLoading ? 0.55 : 1)
    }

    #if os(iOS)
    private func presentExistingLocalImport(for source: MusicSource) {
        guard localImportProgress == nil else { return }
        localImportTargetSource = currentSource(for: source)
        sourceAlert = nil
        showExistingLocalFileImporter = true
    }

    private func handleExistingLocalImport(_ result: Result<[URL], Error>) {
        showExistingLocalFileImporter = false
        switch result {
        case .success(let urls):
            guard !urls.isEmpty, let source = localImportTargetSource else { return }
            startExistingLocalImport(urls, for: currentSource(for: source))
        case .failure(let error):
            sourceAlert = .localImport(SourceLocalImportAlert(
                title: String(localized: "local_import_err_title"),
                message: error.localizedDescription
            ))
        }
    }

    private func startExistingLocalImport(_ urls: [URL], for source: MusicSource) {
        guard localImportSession == nil, localImportTask == nil else { return }
        sourceAlert = nil
        localImportTargetSource = currentSource(for: source)
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
            cleanupPickedCopies: true
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
                sourceAlert = .localImport(SourceLocalImportAlert(
                    title: localImportFailureTitle(outcome),
                    message: localImportFailureMessage(outcome)
                ))
                return
            }

            let scanSource = currentSource(for: source)
            scanService.scanSource(
                scanSource,
                sourceManager: sourceManager,
                library: library,
                sourceStore: sourceStore,
                scraperService: scraperService
            )

            if outcome.skipped > 0 {
                sourceAlert = .localImport(SourceLocalImportAlert(
                    title: String(localized: "local_import_partial_title"),
                    message: localImportCompletionMessage(outcome)
                ))
            }
        }
    }

    @ViewBuilder
    private func localImportProgressView(_ progress: LocalImportService.CopyProgress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .tint(.accentColor)
            } else {
                ProgressView()
                    .tint(.accentColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Text(localImportProgressMessage(progress))
                    .lineLimit(1)
                Spacer()
                if progress.total > 0 {
                    Text("\(progress.processed)/\(progress.total)")
                        .monospacedDigit()
                }
                Button("cancel") {
                    cancelExistingLocalImport()
                }
                .buttonStyle(.borderless)
                .disabled(progress.phase == .cancelling || progress.phase == .cancelled)
                .accessibilityIdentifier("existingLocalImport.cancel")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if !progress.currentFileName.isEmpty {
                Text(progress.currentFileName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
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

    private func cancelExistingLocalImport() {
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
    #endif

    private func sourceActionForeground(for prominence: SourceActionProminence) -> Color {
        switch prominence {
        case .neutral: .secondary
        case .accent: .accentColor
        case .success: .green
        }
    }

    private func sourceActionBackground(for prominence: SourceActionProminence) -> Color {
        switch prominence {
        case .neutral: Color(.tertiarySystemFill)
        case .accent: Color.accentColor.opacity(0.14)
        case .success: Color.green.opacity(0.16)
        }
    }

    private func sourceActionStroke(for prominence: SourceActionProminence) -> Color {
        switch prominence {
        case .neutral: Color.white.opacity(0.04)
        case .accent: Color.accentColor.opacity(0.20)
        case .success: Color.green.opacity(0.24)
        }
    }

    private var sources: [MusicSource] {
        // 排除正处于"撤销倒计时"被乐观隐藏的源(尚未真正删除)。
        sourceStore.sources.filter { !optimisticallyHiddenIDs.contains($0.id) }
    }

    private func playableSongs(for source: MusicSource) -> [Song] {
        library.playableSongs(forSourceID: source.id)
    }

    private func presentCacheConfirmation(for source: MusicSource, songs: [Song]) {
        if let trustTarget = explicitHTTPTrustTarget(for: source),
           !SSLTrustStore.shared.allowsInsecureHTTP(domain: trustTarget) {
            Task { @MainActor in
                guard await SSLTrustStore.shared.requestInsecureHTTPTrust(domain: trustTarget) else {
                    return
                }
                presentCacheConfirmation(for: source, songs: songs)
            }
            return
        }
        cachePreparationTask?.cancel()
        preparingCacheSourceID = source.id
        cachePreparationTask = Task { @MainActor in
            await sourceManager.prepareOfflineAudioSnapshots(for: songs)
            guard !Task.isCancelled, preparingCacheSourceID == source.id else { return }
            preparingCacheSourceID = nil
            cachePreparationTask = nil
            sourceAlert = .confirm(SourceCacheRequest(
                source: source,
                songs: songs,
                estimate: sourceCacheEstimate(for: songs)
            ))
        }
    }

    private func startSourceScan(
        _ source: MusicSource,
        mode: SourceSyncMode = .automatic
    ) {
        if let trustTarget = explicitHTTPTrustTarget(for: source),
           !SSLTrustStore.shared.allowsInsecureHTTP(domain: trustTarget) {
            Task { @MainActor in
                guard await SSLTrustStore.shared.requestInsecureHTTPTrust(domain: trustTarget) else {
                    return
                }
                startSourceScan(source, mode: mode)
            }
            return
        }
        scanService.scanSource(
            source,
            mode: mode,
            sourceManager: sourceManager,
            library: library,
            sourceStore: sourceStore,
            scraperService: scraperService
        )
    }

    private func explicitHTTPTrustTarget(for source: MusicSource) -> String? {
        let routedSources: [MusicSource]
        if source.connectionConfiguration != nil {
            routedSources = source.connectionCandidates.map {
                source.applyingConnectionCandidate($0)
            }
        } else {
            routedSources = [source]
        }

        for routedSource in routedSources {
            let usesHTTP: Bool
            switch routedSource.type {
            case .synology, .synologyAudioStation:
                usesHTTP = routedSource.effectiveSynologyConnectionMode == .address
            case .qnap, .ugreen, .fnos, .webdav, .s3,
                 .jellyfin, .emby, .plex,
                 .subsonic, .navidrome, .airsonic, .gonic,
                 .daoliyu:
                usesHTTP = true
            case .fnMusic:
                usesHTTP = routedSource.effectiveFnMusicConnectionMode == .address
            default:
                usesHTTP = false
            }
            guard usesHTTP,
                  let url = NetworkURLBuilder.baseURL(
                      host: routedSource.host ?? "",
                      scheme: routedSource.useSsl ? "https" : "http",
                      port: routedSource.port
                  ),
                  TrustedHTTPTransport.requiresPlainSocket(for: url),
                  let target = TrustedHTTPTransport.trustTarget(for: url),
                  !SSLTrustStore.shared.allowsInsecureHTTP(domain: target) else {
                continue
            }
            return target
        }
        return nil
    }

    private func sourceCacheEstimate(for songs: [Song]) -> SourceCacheEstimate {
        var remainingCount = 0
        var alreadyCachedCount = 0
        var knownBytes: Int64 = 0
        var unknownCount = 0
        var remainingSongIDs = Set<String>()

        for song in songs {
            switch sourceManager.offlineAudioSnapshot(for: song).state {
            case .cached, .pinned:
                alreadyCachedCount += 1
            case .notCached, .downloading, .failed:
                remainingCount += 1
                remainingSongIDs.insert(song.id)
                if song.fileSize > 0 {
                    knownBytes += song.fileSize
                } else {
                    unknownCount += 1
                }
            }
        }

        return SourceCacheEstimate(
            totalCount: songs.count,
            remainingCount: remainingCount,
            alreadyCachedCount: alreadyCachedCount,
            knownBytes: knownBytes,
            unknownCount: unknownCount,
            remainingSongIDs: remainingSongIDs
        )
    }

    private func startCaching(_ request: SourceCacheRequest) {
        let run = SourceCacheRun(
            sourceID: request.source.id,
            sourceName: request.source.name,
            songs: request.songs,
            estimate: request.estimate
        )
        activeCacheRun = run

        Task { @MainActor in
            let result = await sourceManager.downloadSourceForOffline(
                sourceID: request.source.id,
                songs: request.songs
            )
            guard activeCacheRun?.id == run.id else { return }
            activeCacheRun = nil
            sourceAlert = .completed(SourceCacheCompletion(
                sourceName: request.source.name,
                result: result
            ))
        }
    }

    private func sourceCacheProgress(
        for source: MusicSource,
        hasExplicitBatch: Bool
    ) -> SourceCacheProgressState? {
        if let run = activeCacheRun, run.sourceID == source.id {
            return sourceCacheProgress(songs: run.songs, estimate: run.estimate)
        }

        // A re-created source screen can recover a real user-confirmed batch
        // from SourceManager. Incidental one-song playback downloads never
        // enter that aggregate and therefore cannot fabricate whole-source
        // progress.
        guard hasExplicitBatch else { return nil }

        let songs = playableSongs(for: source)
        return sourceCacheProgress(songs: songs, estimate: sourceCacheEstimate(for: songs))
    }

    private func sourceCacheProgress(songs: [Song], estimate: SourceCacheEstimate) -> SourceCacheProgressState {
        var handledCount = 0
        var completedCount = 0
        var failedCount = 0
        var downloadedKnownBytes: Int64 = 0

        for song in songs {
            let snapshot = sourceManager.offlineAudioSnapshot(for: song)
            switch snapshot.state {
            case .cached, .pinned:
                handledCount += 1
                completedCount += 1
                if estimate.remainingSongIDs.contains(song.id) {
                    downloadedKnownBytes += snapshot.byteCount ?? max(song.fileSize, 0)
                }
            case .failed:
                handledCount += 1
                failedCount += 1
            case .downloading:
                if estimate.remainingSongIDs.contains(song.id),
                   song.fileSize > 0,
                   let progress = snapshot.progress {
                    downloadedKnownBytes += Int64(Double(song.fileSize) * min(1, max(0, progress)))
                }
            case .notCached:
                break
            }
        }

        return SourceCacheProgressState(
            handledCount: handledCount,
            completedCount: completedCount,
            failedCount: failedCount,
            totalCount: estimate.totalCount,
            downloadedKnownBytes: downloadedKnownBytes,
            estimatedKnownBytes: estimate.knownBytes,
            unknownCount: estimate.unknownCount
        )
    }

    private func sourceCacheProgressView(_ progress: SourceCacheProgressState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.fraction)
                .tint(.accentColor)
            HStack {
                Text(sourceCacheProgressMessage(for: progress))
                    .lineLimit(1)
                Spacer()
                Text("\(progress.completedCount)/\(progress.totalCount)")
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func sourceCacheProgressMessage(for progress: SourceCacheProgressState) -> String {
        let downloadedSize = cacheSizeDescription(knownBytes: progress.downloadedKnownBytes, unknownCount: 0)
        let remainingSize = cacheSizeDescription(knownBytes: progress.remainingKnownBytes, unknownCount: progress.unknownCount)
        if progress.failedCount > 0 {
            return String(
                format: String(localized: "source_cache_progress_with_failed_format"),
                downloadedSize,
                remainingSize,
                progress.failedCount
            )
        }
        return String(
            format: String(localized: "source_cache_progress_format"),
            downloadedSize,
            remainingSize
        )
    }

    private func cacheConfirmationMessage(for request: SourceCacheRequest) -> String {
        let size = cacheSizeDescription(
            knownBytes: request.estimate.knownBytes,
            unknownCount: request.estimate.unknownCount
        )

        if request.estimate.alreadyCachedCount > 0 {
            return String(
                format: String(localized: "source_cache_all_message_with_cached_format"),
                request.source.name,
                request.estimate.totalCount,
                size,
                request.estimate.alreadyCachedCount
            )
        }

        return String(
            format: String(localized: "source_cache_all_message_format"),
            request.source.name,
            request.estimate.totalCount,
            size
        )
    }

    private func cacheCompletionTitle(for completion: SourceCacheCompletion) -> String {
        if completion.result.succeeded {
            return String(localized: "source_cache_success_title")
        }
        if completion.result.completedCount == 0 {
            return String(localized: "source_cache_failed_title")
        }
        return String(localized: "source_cache_partial_title")
    }

    private func cacheCompletionMessage(for completion: SourceCacheCompletion) -> String {
        let size = cacheSizeDescription(knownBytes: completion.result.byteCount, unknownCount: 0)
        if completion.result.succeeded {
            return String(
                format: String(localized: "source_cache_success_message_format"),
                completion.sourceName,
                completion.result.completedCount,
                completion.result.requestedCount,
                size
            )
        }

        return String(
            format: String(localized: "source_cache_partial_message_format"),
            completion.sourceName,
            completion.result.completedCount,
            completion.result.requestedCount,
            completion.result.failedCount,
            size
        )
    }

    private func cacheSizeDescription(knownBytes: Int64, unknownCount: Int) -> String {
        let knownSize = ByteCountFormatter.string(fromByteCount: knownBytes, countStyle: .file)
        if knownBytes <= 0, unknownCount > 0 {
            return String(
                format: String(localized: "source_cache_size_unknown_only_format"),
                unknownCount
            )
        }
        if unknownCount > 0 {
            return String(
                format: String(localized: "source_cache_size_known_plus_unknown_format"),
                knownSize,
                unknownCount
            )
        }
        return knownSize
    }

    @ViewBuilder
    private func connectionSheet(
        for source: MusicSource,
        stagedDirectories: Binding<[String]>? = nil,
        onConfirm: ((Bool) -> Void)? = nil,
        onEditAddress: (() -> Void)? = nil
    ) -> some View {
        let persistedDirectories = Binding(
            get: { currentSource(for: source).scannedDirectories },
            set: { newDirs in
                updateSource(source.id) {
                    $0.extraConfig = MusicSource.encodeScannedDirectories(newDirs, into: $0.extraConfig, type: $0.type)
                }
            }
        )
        let selectedDirectories = stagedDirectories ?? persistedDirectories

        switch source.type {
        case .local:
            ContentUnavailableView(
                "local_import_title",
                systemImage: "folder.badge.plus",
                description: Text("local_import_section_footer")
            )
        case .synology, .synologyAudioStation:
            ConnectionFlowView(
                source: source,
                selectedDirectories: selectedDirectories,
                onDeviceTrustSaved: { remember, did in
                    guard let current = sourceStore.source(id: source.id),
                          current.rememberDevice != remember
                            || (!remember && current.deviceId != nil)
                            || (remember && did != nil && current.deviceId != did) else { return }
                    sourceStore.update(source.id) {
                        $0.rememberDevice = remember
                        if remember {
                            if let did { $0.deviceId = did }
                        } else {
                            $0.deviceId = nil
                        }
                    }
                    Task { await sourceManager.refreshConnector(for: source.id) }
                },
                onSessionReady: { api in
                    scanService.synologyAPIs[source.id] = api
                },
                onPasswordWillChange: {
                    do {
                        try sourceManager.credentialsWillChange(for: source.id)
                        return true
                    } catch {
                        plog("⚠️ Synology credential revision could not be persisted source=\(source.id.prefix(8))… error=\(error.localizedDescription)")
                        return false
                    }
                },
                onPasswordSaveUncertain: {
                    sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                },
                onPasswordSaved: {
                    do {
                        try sourceManager.credentialsDidChange(for: source.id)
                        await sourceManager.refreshConnector(for: source.id, force: true)
                        return true
                    } catch {
                        sourceManager.credentialsChangeOutcomeUncertain(for: source.id)
                        plog("⚠️ Synology credential transition could not commit source=\(source.id.prefix(8))… error=\(error.localizedDescription)")
                        return false
                    }
                },
                onEditAddress: onEditAddress,
                onAudioStationReady: {
                    // 先让连接器按刚存下的设备令牌重建,再扫描整库。
                    Task { @MainActor in
                        await sourceManager.refreshConnector(for: source.id)
                        startSourceScan(currentSource(for: source))
                    }
                }
            )
        case .smb:
            SMBBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories,
                onConfirm: onConfirm,
                onEditAddress: onEditAddress
            )
        case .webdav:
            WebDAVBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories,
                onConfirm: onConfirm,
                onEditAddress: onEditAddress
            )
        case .ftp:
            FTPBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories,
                onEditAddress: onEditAddress
            )
        case .sftp:
            SFTPBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories,
                onEditAddress: onEditAddress
            )
        case .nfs:
            NFSBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories,
                onEditAddress: onEditAddress
            )
        case .upnp:
            // UPnP 的源是发现出来的设备, 没有一条可以改的地址, 所以不给
            // 「修改地址」的出口。
            UPnPBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .qnap, .ugreen, .fnos, .s3:
            // Connector-driven sources: extraConfig holds the scanned-directory
            // list (S3 keeps its region alongside, transparently handled by the
            // S3-aware binding above), so the generic connector browser drives
            // selection/scan the same way SMB/WebDAV/FTP do.
            ConnectorDirectoryBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories,
                onEditAddress: onEditAddress
            )
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .drime, .pan115, .pan123,
             .guangya:
            CloudDriveConnectionView(
                source: source,
                selectedDirectories: selectedDirectories
            )
        default:
            ContentUnavailableView(
                "connection_failed",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text("save_then_connect_hint")
            )
        }
    }

    private var groupedSources: [(SourceCategory, [MusicSource])] {
        let grouped = Dictionary(grouping: sources) { $0.type.category }
        return SourceCategory.allCases.compactMap { cat in
            guard let items = grouped[cat], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

    private func beginDirectorySelectionSession(for source: MusicSource) {
        guard directorySelectionSession?.sourceID != source.id else { return }
        directorySelectionSession = SourceDirectorySelectionSession(
            sourceID: source.id,
            previousDirectories: currentSource(for: source).scannedDirectories
        )
    }

    private func finishDirectorySelectionSession() {
        guard let session = directorySelectionSession else { return }
        directorySelectionSession = nil
        scanService.scanAfterDirectorySelectionChange(
            sourceID: session.sourceID,
            previousDirectories: session.previousDirectories,
            sourceManager: sourceManager,
            library: library,
            sourceStore: sourceStore,
            scraperService: scraperService
        )
    }

    private func cancelDirectorySelectionSession() {
        directorySelectionSession = nil
    }

    /// 连接失败页的「修改地址」: 记下目标再关掉连接 sheet。这里不能直接呈现编辑
    /// 表单 —— 同一个视图上两个 sheet 不能一个还没关完另一个就开, 否则后者会被
    /// 系统丢掉。真正的呈现放在 finishConnectionSheet 里。
    private func requestAddressEdit(for source: MusicSource) {
        pendingAddressEditSource = currentSource(for: source)
        connectingSource = nil
    }

    private func finishConnectionSheet() {
        finishDirectorySelectionSession()
        guard let pending = pendingAddressEditSource else { return }
        pendingAddressEditSource = nil
        editingSource = currentSource(for: pending)
    }

    private func toggleSourceEnabled(_ source: MusicSource) {
        let current = currentSource(for: source)
        let enabled = !current.isEnabled
        if !enabled {
            pauseBackgroundWork(for: current.id)
        }
        updateSource(current.id) { $0.isEnabled = enabled }
        library.updateDisabledSourceIDs(disabledSourceIDs)
        if current.id == AppleMusicLibraryService.systemSourceID {
            if enabled {
                appleMusicLibrary.sync()
            } else {
                appleMusicLibrary.cancel()
            }
        }
        backfill.sourceAvailabilityChanged(forSourceID: current.id)
    }

    private var disabledSourceIDs: Set<String> {
        Set(sourceStore.sources.filter { !$0.isEnabled }.map(\.id))
    }

    /// 撤销提示条数据(被删源的 id + 名字)。
    struct UndoDeleteToast: Equatable {
        let id: String
        let name: String
    }

    /// 删除源(带撤销): 先把卡片乐观隐藏并弹底部撤销条, 延迟数秒后才真正落地
    /// 删除。窗口内点撤销 = 取消尚未执行的删除、卡片滑回, 数据完好(不靠软删
    /// 恢复, 因为 deleteSource 会移歌/移 connector 且 restore 不重扫)。
    private func requestDelete(_ source: MusicSource) {
        #if os(iOS)
        if isManagedLocalImportSource(source) {
            sourceAlert = .managedCopyRemoval(source)
            return
        }
        #endif
        // 移除 Apple Music 会一并删掉同步进来的歌和镜像歌单, 先说清楚再删。
        if source.id == AppleMusicLibraryService.systemSourceID {
            sourceAlert = .appleMusicRemoval(source)
            return
        }
        scheduleDelete(source)
    }

    private func scheduleDelete(_ source: MusicSource) {
        // 同源若已有未落地删除, 先落地旧的再开新窗口。
        if pendingDeleteTasks[source.id] != nil { commitPendingDelete(source.id) }
        pmWithAnimation(.list) {
            optimisticallyHiddenIDs.insert(source.id)
            undoToast = UndoDeleteToast(id: source.id, name: source.name)
        }
        let id = source.id
        let task = Task {
            try? await Task.sleep(for: .seconds(4))
            if Task.isCancelled { return }
            await MainActor.run { commitPendingDelete(id) }
        }
        pendingDeleteTasks[id] = task
    }

    /// 撤销倒计时到期 → 真正删除。
    private func commitPendingDelete(_ id: String) {
        pendingDeleteTasks[id]?.cancel()
        pendingDeleteTasks[id] = nil
        if let source = sourceStore.source(id: id) { deleteSource(source) }
        pmWithAnimation(.list) {
            optimisticallyHiddenIDs.remove(id)
            if undoToast?.id == id { undoToast = nil }
        }
    }

    /// 用户点撤销 → 取消尚未执行的删除, 卡片恢复显示。
    private func undoDelete(_ id: String) {
        pendingDeleteTasks[id]?.cancel()
        pendingDeleteTasks[id] = nil
        pmWithAnimation(.list) {
            optimisticallyHiddenIDs.remove(id)
            undoToast = nil
        }
    }

    /// 离开页面时把所有未落地的删除立即落地(不再有机会撤销)。
    private func flushPendingDeletes() {
        for id in Array(pendingDeleteTasks.keys) {
            pendingDeleteTasks[id]?.cancel()
            pendingDeleteTasks[id] = nil
            if let source = sourceStore.source(id: id) { deleteSource(source) }
        }
        optimisticallyHiddenIDs.removeAll()
        undoToast = nil
    }

    @ViewBuilder
    private func undoToastView(_ toast: UndoDeleteToast) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            Text(String(format: String(localized: "source_deleted_toast"), toast.name))
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(String(localized: "undo")) { undoDelete(toast.id) }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func deleteSource(_ source: MusicSource) {
        // Cancel any active scan first — otherwise it keeps adding songs back.
        // The global source-lifecycle coordinator batches library/cache removal
        // across rapid deletions; doing it here as well caused duplicate
        // full-library rebuilds and per-song cache invalidations.
        stopBackgroundWork(for: source.id)
        // Soft-delete: the row moves to "Recently Deleted" and stays
        // recoverable for the retention window. Credentials, OAuth tokens,
        // app credentials and cloud directory names are deliberately NOT
        // wiped here — destroying them on soft-delete would leave a restored
        // source unable to log in / re-authorize. Their physical removal
        // belongs to the permanent-purge stage.
        sourceStore.remove(id: source.id)
        scanService.removeSynologyAPI(for: source.id)
    }

    private func stopBackgroundWork(for sourceID: String) {
        scanService.cancelScan(for: sourceID)
        scanService.removeCheckpoint(for: sourceID)
    }

    /// 停用源时暂停它名下的后台工作: 扫描, 以及 SourceManager 里的整源
    /// 离线批量 / 单曲离线下载 / 后台缓存 / MV 下载。
    private func pauseBackgroundWork(for sourceID: String) {
        scanService.cancelScan(for: sourceID)
        sourceManager.sourceAvailabilityDidChange(sourceID: sourceID, isEnabled: false)
    }

    private func isManagedLocalImportSource(_ source: MusicSource) -> Bool {
        #if os(iOS)
        return LocalImportService.isManagedSource(source)
        #else
        return false
        #endif
    }

    private func currentSource(for source: MusicSource) -> MusicSource {
        sourceStore.source(id: source.id) ?? source
    }

    private func updateSource(_ sourceID: String, mutate: (inout MusicSource) -> Void) {
        sourceStore.update(sourceID, mutate: mutate)
    }

    private func directoryDisplayName(for path: String, source: MusicSource) -> String {
        if SourceDirectorySelectionPolicy.selectableRootPath(
            for: source.type,
            browserPath: path
        ) != nil {
            return source.basePath ?? String(localized: "shared_folders")
        }

        if source.type.isCloudDrive {
            if let displayName = source.scannedDirectoryDisplayNames[path],
               !displayName.isEmpty {
                return displayName
            }
            if let displayName = CloudDirectoryNameStore.displayName(for: path, sourceID: source.id),
               !displayName.isEmpty {
                return displayName
            }
            if let displayName = scanService.libraryFolderSyncIndex(for: source.id)
                .values.first(where: { $0.path == path })?.displayName,
               !displayName.isEmpty {
                return displayName
            }
        }

        if path == "/" {
            if source.type == .local {
                return source.name
            }
            return String(localized: "shared_folders")
        }

        if let readable = SourceDirectoryLabelPolicy.readableFallback(
            path: path,
            sourceType: source.type
        ) {
            return readable
        }
        return "\(source.type.displayName) · \(String(localized: "current_directory"))"
    }

}

struct SourceDiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SourceManager.self) private var sourceManager

    let source: MusicSource
    @State private var report: SourceDiagnosticReport?
    @State private var isRunning = false
    @State private var progress = SourceDiagnosticProgress()
    @State private var runID = UUID()

    @ViewBuilder
    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("source_diagnostics")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(source.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    runID = UUID()
                } label: {
                    Label("source_diag_run_again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRunning)
                .accessibilityIdentifier("sourceDiagnosticsRunAgain")

                Button("done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("sourceDiagnosticsDone")
            }
            .padding(.horizontal, 18)
            .frame(height: 56)

            Divider()
            diagnosticsList
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 460, idealHeight: 540)
        #else
        NavigationStack {
            diagnosticsList
            .navigationTitle("source_diagnostics")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        runID = UUID()
                    } label: {
                        Label("source_diag_run_again", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRunning)
                }
            }
        }
        #endif
    }

    private var diagnosticsList: some View {
        SkinList {
            if isRunning {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: String(localized: "source_diag_progress_format"),
                                    progress.completedChecks, progress.totalChecks))
                        ProgressView(value: Double(progress.completedChecks), total: Double(max(1, progress.totalChecks)))
                    }
                    .padding(.vertical, 4)
                }
            }

            if !progress.checks.isEmpty {
                Section("source_diag_checks") {
                    ForEach(progress.checks) { check in
                        diagnosticRow(check)
                    }
                }
            }
            if let report, !isRunning {
                Section {
                    summaryRow(report)
                }
            }
        }
        .task(id: runID) {
            await runDiagnostics()
        }
        .refreshable {
            guard !isRunning else { return }
            runID = UUID()
        }
    }

    private func summaryRow(_ report: SourceDiagnosticReport) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName(for: report.summaryStatus))
                .font(.title3)
                .foregroundStyle(tint(for: report.summaryStatus))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(report.wasCancelled ? String(localized: "source_diag_cancelled") : summaryTitle(for: report.summaryStatus))
                    .font(.headline)
                if !report.connections.isEmpty {
                    Text(String(format: String(localized: "source_diag_routes_format"),
                                report.connections.filter(\.isAvailable).count, report.connections.count))
                        .font(.subheadline)
                }
                Text(String(format: String(localized: "source_diag_check_counts_format"),
                            report.checks.filter { $0.status == .passed }.count,
                            report.checks.filter { $0.status == .warning }.count,
                            report.checks.filter { $0.status == .failed }.count,
                            report.checks.filter { $0.status == .skipped }.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: String(localized: "source_diag_summary_detail_format"), report.sourceName, elapsedText(report)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func diagnosticRow(_ check: SourceDiagnosticCheck) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if check.status == .running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: iconName(for: check.status))
                        .font(.body)
                        .foregroundStyle(tint(for: check.status))
                }
            }
            .frame(width: 24)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(check.title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(check.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !check.suggestion.isEmpty {
                    Text(check.suggestion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private func runDiagnostics() async {
        guard !isRunning else { return }
        isRunning = true
        report = nil
        progress = SourceDiagnosticProgress()
        defer { isRunning = false }
        let result = await sourceManager.diagnoseAllConnections(source: source) { progress = $0 }
        guard !Task.isCancelled else { return }
        report = result
    }

    private func elapsedText(_ report: SourceDiagnosticReport) -> String {
        let elapsed = max(0.1, report.finishedAt.timeIntervalSince(report.startedAt))
        return String(format: "%.1fs", elapsed)
    }

    private func summaryTitle(for status: SourceDiagnosticStatus) -> String {
        switch status {
        case .running: String(localized: "source_diag_running")
        case .skipped: String(localized: "source_diag_skipped")
        case .passed: String(localized: "source_diag_summary_ok")
        case .warning: String(localized: "source_diag_summary_warning")
        case .failed: String(localized: "source_diag_summary_failed")
        }
    }

    private func iconName(for status: SourceDiagnosticStatus) -> String {
        switch status {
        case .running: "circle.dotted"
        case .skipped: "minus.circle"
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func tint(for status: SourceDiagnosticStatus) -> Color {
        switch status {
        case .running: .accentColor
        case .skipped: .secondary
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}

/// 把"读扫描状态"这件事关在一小块视图里。
///
/// 扫描期间 `ScanService.scanStates` 一秒要发布好几次, 而 Observation 的粒度是
/// 整个字典 —— 来源卡片主体只要读它一下, 每一次进度更新就会把整张卡片连同长按
/// 菜单、滑动操作和整排按钮重新构造一遍, 正好跟列表滑动抢主线程, 于是"一边扫描
/// 一边滑音乐源页"必然掉帧。真正跟着进度动的只有几小块, 让它们各自订阅, 卡片
/// 主体就不必跟着重算了。
struct SourceScanStateReader<Content: View>: View {
    let sourceID: String
    @ViewBuilder let content: (ScanService.ScanState?) -> Content

    @Environment(ScanService.self) private var scanService

    var body: some View {
        content(scanService.scanStates[sourceID])
    }
}

/// 扫描中显示已扫到的首数, 扫完回到来源自己记的那个总数。
private struct SourceSongCountBadge: View {
    let sourceID: String
    let settledCount: Int

    @Environment(ScanService.self) private var scanService

    var body: some View {
        let scanning = scanService.scanStates[sourceID]
        let count = if let scanning, scanning.isScanning || scanning.canResume {
            scanning.scannedCount
        } else {
            settledCount
        }
        if count > 0 {
            Text("\(count)")
                .font(.caption).fontWeight(.semibold).monospacedDigit()
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(.quaternary).clipShape(Capsule())
        }
    }
}

/// 整页汇总(几个源在扫、哪些要处理)要看所有源的扫描状态, 但这份订阅不该留在
/// 页面主体上 —— 留在那里, 每一帧进度都会把整张来源列表重建一遍。把它关进这
/// 一小块里, 外面就只管布局。
struct ScanStateScope<Content: View>: View {
    @ViewBuilder let content: () -> Content

    @Environment(ScanService.self) private var scanService

    var body: some View {
        let _ = scanService.scanStates
        content()
    }
}
