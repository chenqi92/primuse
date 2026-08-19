import SwiftUI
import PrimuseKit

private enum SourceAlert: Identifiable {
    case confirm(SourceCacheRequest)
    case completed(SourceCacheCompletion)
    #if os(iOS)
    case localImport(SourceLocalImportAlert)
    #endif

    var id: String {
        switch self {
        case .confirm(let request): "confirm-\(request.id.uuidString)"
        case .completed(let completion): "completed-\(completion.id.uuidString)"
        #if os(iOS)
        case .localImport(let alert): "local-import-\(alert.id.uuidString)"
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
        .accessibilityElement(children: .combine)
    }

    private func title(for kind: SourceConnectionCandidateKind) -> LocalizedStringKey {
        switch kind {
        case .localAddress:
            "source_connection_local"
        case .publicAddress:
            "source_connection_public_direct"
        case .vendorRemote:
            source.type == .synology
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
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourceStore
    @Environment(MusicLibrary.self) private var library
    @Environment(AppleMusicLibraryService.self) private var appleMusicLibrary
    @Environment(ScanService.self) private var scanService
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(MetadataBackfillService.self) private var backfill
    @State private var showAddSource = false
    @State private var editingSource: MusicSource?
    @State private var connectingSource: MusicSource?
    @State private var directorySelectionSession: SourceDirectorySelectionSession?
    @State private var optimisticallyHiddenIDs: Set<String> = []
    @State private var undoToast: UndoDeleteToast?
    @State private var pendingDeleteTasks: [String: Task<Void, Never>] = [:]
    @State private var diagnosingSource: MusicSource?
    @State private var sourceAlert: SourceAlert?
    @State private var activeCacheRun: SourceCacheRun?
    @State private var preparingCacheSourceID: String?
    @State private var cachePreparationTask: Task<Void, Never>?
    @State private var cloudDirectoryNameRefreshID = UUID()
    /// Apple Music 这个虚拟 source 没有目录 / 体检的概念, 行内按钮换成
    /// "打开 Apple Music 设置" 的跳转 ── 走 NavigationStack 的 destination 而不是 sheet,
    /// 让推入栈跟其他 Settings 子页体验一致 (左上角"返回"而不是"完成")。
    @State private var openAppleMusicSettings = false
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
            if sources.isEmpty { emptyView }
            else { sourceList }
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
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddSource = true } label: { Image(systemName: "plus") }
                        .accessibilityIdentifier("sources.add")
                }
            }
            .sheet(isPresented: $showAddSource) {
                SourceTypeSelectionView { source in
                    if source.type == .local,
                       source.id == LocalImportService.existingSourceID {
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
                    }
                }
            }
            .sheet(item: $editingSource) { source in
                AddSourceView(sourceType: source.type, editingSource: source) { updated in
                    updateSource(updated.id) { $0 = updated }
                    scanService.removeSynologyAPI(for: updated.id)
                    Task { await sourceManager.refreshConnector(for: updated.id) }
                }
            }
            .sheet(item: $connectingSource, onDismiss: finishDirectorySelectionSession) { source in
                connectionSheet(for: source)
                    .onAppear { beginDirectorySelectionSession(for: source) }
            }
            .sheet(item: $diagnosingSource) { source in
                SourceDiagnosticsView(source: source)
            }
            #if os(iOS)
            .sheet(isPresented: $showExistingLocalFileImporter) {
                IOSLocalDocumentPicker(mode: .files) { result in
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
                #if os(iOS)
                case .localImport(let alert):
                    return Alert(
                        title: Text(alert.title),
                        message: Text(alert.message),
                        dismissButton: .default(Text("ok"))
                    )
                #endif
                }
            }
            .navigationDestination(isPresented: $openAppleMusicSettings) {
                AppleMusicSettingsView()
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
        let downloadingIDs = downloadingSourceIDs
        return List {
            ForEach(groupedSources, id: \.0) { category, items in
                Section(category.displayName) {
                    ForEach(items) { source in
                        sourceCard(source, downloadingIDs: downloadingIDs)
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
    }

    private func sourceCard(
        _ source: MusicSource,
        downloadingIDs: Set<String>
    ) -> some View {
        let dirs = source.scannedDirectories
        let scanning = scanService.scanStates[source.id]
        let displayedSongCount = if let scanning, scanning.isScanning || scanning.canResume {
            scanning.scannedCount
        } else {
            source.songCount
        }
        // A song can only ever be `.downloading` while it has an in-memory
        // snapshot entry (written by SourceManager.performOfflineDownload); the
        // disk-stat fallback in `offlineAudioSnapshot(for:)` never returns
        // `.downloading`. So compute the set of currently-downloading source IDs
        // straight from the observed snapshot dictionary instead of calling
        // `offlineAudioSnapshot` per song — that fallback does a synchronous
        // FileManager stat for every uncached song and, scanning the full
        // library per card per frame, makes the Sources page stutter during
        // scans / batch caching on large libraries.
        let hasSourceDownloads = downloadingIDs.contains(source.id)
        let hasOtherSourceDownloads = downloadingIDs.contains { $0 != source.id }
        let sourceSongs = playableSongs(for: source)
        let isPreparingSourceCache = preparingCacheSourceID == source.id
        let isSourceCaching = activeCacheRun?.sourceID == source.id || hasSourceDownloads
        let isSourceCacheBusy = isPreparingSourceCache || isSourceCaching
        let isAnotherSourceCaching = (activeCacheRun != nil && activeCacheRun?.sourceID != source.id)
            || (preparingCacheSourceID != nil && preparingCacheSourceID != source.id)
            || hasOtherSourceDownloads
        let cacheButtonTitle: LocalizedStringKey = isSourceCacheBusy ? "source_cache_all_loading" : "source_cache_all_short"

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: source.type.iconName)
                    .font(.title3).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(source.isEnabled ? Color.accentColor.gradient : Color.gray.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(source.name).font(.body).fontWeight(.medium)
                        if !source.isEnabled {
                            Text(String(localized: "disabled"))
                                .font(.caption2).fontWeight(.medium)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.red.opacity(0.12))
                                .foregroundStyle(.red)
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
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if displayedSongCount > 0 {
                        Text("\(displayedSongCount)")
                            .font(.caption).fontWeight(.semibold).monospacedDigit()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary).clipShape(Capsule())
                    }
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

            if !dirs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(dirs, id: \.self) { dir in
                            Label(directoryDisplayName(for: dir, source: source), systemImage: "folder.fill")
                                .font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            if let failureMessage = scanning?.failureMessage, !failureMessage.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Label("notify_scan_failed_title", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                        Spacer(minLength: 8)
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
                .background(Color.red.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.red.opacity(0.14), lineWidth: 0.8)
                }
            }

            if let reconciliationMessage = scanning?.reconciliationMessage,
               !reconciliationMessage.isEmpty {
                Label {
                    Text(reconciliationMessage)
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.shield.fill")
                }
                .foregroundStyle(.orange)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

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
                    // 安抚: 让用户明确知道扫描在后台跑, 可以离开当前页面继续用 app。
                    Text("scan_runs_in_background_hint")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if scanning?.failureMessage == nil,
                      scanning?.reconciliationMessage == nil {
                // Phase A finished. If there are still bare songs from this source
                // (cloud sources fill metadata in the background), show a softer
                // "loading details" indicator so users don't think the scan is
                // stuck or "interrupted". Filter matches `MetadataBackfillService`
                // exactly (excludes already-failed songs) so this number agrees
                // with the global "remaining" in StorageManagementView.
                let outstanding = backfill.statusCount(forSource: source.id)
                if outstanding > 0 {
                    let activityState = backfill.activityState(forSource: source.id)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            switch activityState {
                            case .running:
                                ProgressView().scaleEffect(0.7).tint(.secondary)
                                Text("backfill_in_progress").font(.caption2)
                            case .retrying:
                                ProgressView().scaleEffect(0.7).tint(.secondary)
                                Text("backfill_retry_in_progress").font(.caption2)
                            case .waitingForWiFi:
                                Image(systemName: "wifi.exclamationmark")
                                Text("backfill_waiting_for_wifi").font(.caption2)
                            case .retryPending:
                                Image(systemName: "arrow.clockwise.circle")
                                Text("backfill_retry_pending").font(.caption2)
                            case .pending, .idle:
                                Image(systemName: "clock")
                                Text("home_pending_details").font(.caption2)
                            }
                            Spacer()
                            Text(String(format: String(localized: "backfill_remaining"), outstanding))
                                .font(.caption2).monospacedDigit()
                        }
                        if activityState == .running || activityState == .retrying {
                            Text("backfill_runs_in_background_hint")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text("backfill_keep_app_alive_hint")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        } else if activityState == .retryPending {
                            Text("backfill_retry_pending_hint")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }

            if let progress = sourceCacheProgress(
                for: source,
                hasDownloads: hasSourceDownloads
            ) {
                sourceCacheProgressView(progress)
            }

            #if os(iOS)
            if isLocalImportSource(source),
               localImportTargetSource?.id == source.id,
               let localImportProgress {
                localImportProgressView(localImportProgress)
            }
            #endif

            HStack(spacing: 10) {
                if source.type == .appleMusic {
                    // Apple Music 走 ApplicationMusicPlayer, 没有目录/扫描/体检概念,
                    // 行内只给一个跳转设置的入口。
                    sourceActionButton(
                        "source_apple_music_open_settings",
                        systemImage: "applelogo",
                        prominence: .accent
                    ) {
                        openAppleMusicSettings = true
                    }
                } else if isLocalImportSource(source) {
                    #if os(iOS)
                    let isImportingHere = localImportTargetSource?.id == source.id && localImportProgress != nil
                    sourceActionButton(
                        "local_import_title",
                        systemImage: "doc.badge.plus",
                        prominence: .accent,
                        isLoading: isImportingHere,
                        isDisabled: localImportProgress != nil
                    ) {
                        presentExistingLocalImport(for: source)
                    }
                    #else
                    sourceActionButton(
                        "local_import_title",
                        systemImage: "doc.badge.plus",
                        prominence: .accent
                    ) {
                        showAddSource = true
                    }
                    #endif

                    sourceActionButton(
                        scanning?.canResume == true ? "resume_scan" : "scan",
                        systemImage: scanning?.canResume == true ? "arrow.clockwise.circle" : "waveform.badge.magnifyingglass",
                        prominence: .success,
                        isDisabled: scanning?.isScanning == true
                    ) {
                        startSourceScan(source)
                    }
                } else if source.type.scansEntireLibrary {
                    // 整库来源直接扫描，无需再选目录。macOS Local 的范围已由
                    // 用户选定的 basePath 确定。
                    sourceActionButton(
                        cacheButtonTitle,
                        systemImage: "arrow.down.circle",
                        prominence: .accent,
                        isLoading: isSourceCacheBusy,
                        isDisabled: isSourceCacheBusy || sourceSongs.isEmpty || isAnotherSourceCaching
                    ) {
                        presentCacheConfirmation(for: source, songs: sourceSongs)
                    }

                    sourceActionButton(
                        scanning?.canResume == true ? "resume_scan" : "scan",
                        systemImage: scanning?.canResume == true ? "arrow.clockwise.circle" : "waveform.badge.magnifyingglass",
                        prominence: .success,
                        isDisabled: scanning?.isScanning == true
                    ) {
                        startSourceScan(source)
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
                        isDisabled: isSourceCacheBusy || sourceSongs.isEmpty || isAnotherSourceCaching
                    ) {
                        presentCacheConfirmation(for: source, songs: sourceSongs)
                    }

                    if !dirs.isEmpty {
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
        .padding(.vertical, 4)
        .id("\(source.id)-\(cloudDirectoryNameRefreshID.uuidString)")
        .opacity(source.isEnabled ? 1.0 : 0.55)
        .contextMenu {
            Button {
                toggleSourceEnabled(source)
            } label: {
                Label(
                    source.isEnabled ? String(localized: "disable") : String(localized: "enable"),
                    systemImage: source.isEnabled ? "eye.slash" : "eye"
                )
            }
            // Apple Music 没有 edit / diagnose / delete 概念 ── 删了 AppServices
            // 下次启动会自动重建, 反而带来困惑; 编辑/体检都依赖 connector。
            if source.id != AppleMusicLibraryService.systemSourceID {
                Button { editingSource = source } label: { Label("edit", systemImage: "pencil") }
                Button { diagnosingSource = source } label: { Label("source_diagnostics", systemImage: "stethoscope") }
                if source.type.scansEntireLibrary || !dirs.isEmpty {
                    Button {
                        startSourceScan(source, mode: .deep)
                    } label: {
                        Label("source_deep_scan", systemImage: "arrow.triangle.2.circlepath.circle")
                    }
                    .disabled(scanning?.isScanning == true)
                }
                Divider()
                Button(role: .destructive) { requestDelete(source) } label: { Label("delete", systemImage: "trash") }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if source.id != AppleMusicLibraryService.systemSourceID {
                Button(role: .destructive) { requestDelete(source) } label: { Label("delete", systemImage: "trash") }
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

    /// Source IDs that currently have at least one song being downloaded for
    /// offline use. SourceManager publishes only membership transitions here;
    /// per-chunk progress remains scoped to the affected song row.
    private var downloadingSourceIDs: Set<String> {
        var ids = Set<String>()
        for songID in sourceManager.offlineDownloadingSongIDs {
            if let sourceID = library.song(id: songID)?.sourceID {
                ids.insert(sourceID)
            }
        }
        return ids
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
            case .synology:
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
            let result = await sourceManager.downloadForOfflineBatch(songs: request.songs)
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
        hasDownloads: Bool
    ) -> SourceCacheProgressState? {
        if let run = activeCacheRun, run.sourceID == source.id {
            return sourceCacheProgress(songs: run.songs, estimate: run.estimate)
        }

        // The caller already derived this from the small observed in-memory
        // download dictionary. Avoid scanning every song in the source again.
        guard hasDownloads else { return nil }

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
    private func connectionSheet(for source: MusicSource) -> some View {
        let selectedDirectories = Binding(
            get: { currentSource(for: source).scannedDirectories },
            set: { newDirs in
                updateSource(source.id) {
                    $0.extraConfig = MusicSource.encodeScannedDirectories(newDirs, into: $0.extraConfig, type: $0.type)
                }
            }
        )

        switch source.type {
        case .local:
            ContentUnavailableView(
                "local_import_title",
                systemImage: "folder.badge.plus",
                description: Text("local_import_section_footer")
            )
        case .synology:
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
                onPasswordSaved: {
                    await sourceManager.refreshConnector(for: source.id)
                }
            )
        case .smb:
            SMBBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories
            )
        case .webdav:
            WebDAVBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories
            )
        case .ftp:
            FTPBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories
            )
        case .sftp:
            SFTPBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories
            )
        case .nfs:
            NFSBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories
            )
        case .upnp:
            UPnPBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .qnap, .ugreen, .fnos, .s3:
            // Connector-driven sources: extraConfig holds the scanned-directory
            // list (S3 keeps its region alongside, transparently handled by the
            // S3-aware binding above), so the generic connector browser drives
            // selection/scan the same way SMB/WebDAV/FTP do.
            ConnectorDirectoryBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories
            )
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .drime, .pan115, .pan123:
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
        if enabled {
            backfill.start()
        } else {
            backfill.sourceAvailabilityChanged()
        }
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
        // 同源若已有未落地删除, 先落地旧的再开新窗口。
        if pendingDeleteTasks[source.id] != nil { commitPendingDelete(source.id) }
        withAnimation {
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
        withAnimation {
            optimisticallyHiddenIDs.remove(id)
            if undoToast?.id == id { undoToast = nil }
        }
    }

    /// 用户点撤销 → 取消尚未执行的删除, 卡片恢复显示。
    private func undoDelete(_ id: String) {
        pendingDeleteTasks[id]?.cancel()
        pendingDeleteTasks[id] = nil
        withAnimation {
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

    private func pauseBackgroundWork(for sourceID: String) {
        scanService.cancelScan(for: sourceID)
    }

    private func isLocalImportSource(_ source: MusicSource) -> Bool {
        #if os(iOS)
        return source.type == .local
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
                return String(localized: "local_import_source_name")
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

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isRunning {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("source_diag_running")
                                .font(.body)
                        }
                        .padding(.vertical, 4)
                    } else if let report {
                        summaryRow(report)
                    }
                }

                if let report {
                    Section("source_diag_checks") {
                        ForEach(report.checks) { check in
                            diagnosticRow(check)
                        }
                    }
                }
            }
            .navigationTitle("source_diagnostics")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await runDiagnostics() }
                    } label: {
                        Label("source_diag_run_again", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRunning)
                }
            }
            .task {
                if report == nil {
                    await runDiagnostics()
                }
            }
            .refreshable {
                await runDiagnostics()
            }
        }
    }

    private func summaryRow(_ report: SourceDiagnosticReport) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName(for: report.summaryStatus))
                .font(.title3)
                .foregroundStyle(tint(for: report.summaryStatus))
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(summaryTitle(for: report.summaryStatus))
                    .font(.headline)
                Text(String(format: String(localized: "source_diag_summary_detail_format"), report.sourceName, elapsedText(report)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func diagnosticRow(_ check: SourceDiagnosticCheck) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName(for: check.status))
                .font(.body)
                .foregroundStyle(tint(for: check.status))
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
        isRunning = true
        defer { isRunning = false }
        report = await sourceManager.diagnose(source: source)
    }

    private func elapsedText(_ report: SourceDiagnosticReport) -> String {
        let elapsed = max(0.1, report.finishedAt.timeIntervalSince(report.startedAt))
        return String(format: "%.1fs", elapsed)
    }

    private func summaryTitle(for status: SourceDiagnosticStatus) -> String {
        switch status {
        case .passed: String(localized: "source_diag_summary_ok")
        case .warning: String(localized: "source_diag_summary_warning")
        case .failed: String(localized: "source_diag_summary_failed")
        }
    }

    private func iconName(for status: SourceDiagnosticStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }

    private func tint(for status: SourceDiagnosticStatus) -> Color {
        switch status {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }
}
