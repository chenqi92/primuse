import SwiftUI
import PrimuseKit

private enum SourceCacheAlert: Identifiable {
    case confirm(SourceCacheRequest)
    case completed(SourceCacheCompletion)

    var id: String {
        switch self {
        case .confirm(let request): "confirm-\(request.id.uuidString)"
        case .completed(let completion): "completed-\(completion.id.uuidString)"
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
    @State private var cacheAlert: SourceCacheAlert?
    @State private var activeCacheRun: SourceCacheRun?
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
    @State private var localImportProgress: LocalImportService.CopyProgress?
    @State private var localImportAlert: SourceLocalImportAlert?
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
            .onDisappear { flushPendingDeletes() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddSource = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAddSource) {
                SourceTypeSelectionView { source in
                    sourceStore.add(source)
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
            .alert(item: $cacheAlert) { alert in
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
                }
            }
            #if os(iOS)
            .alert(item: $localImportAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("ok"))
                )
            }
            #endif
            .navigationDestination(isPresented: $openAppleMusicSettings) {
                AppleMusicSettingsView()
            }
            .onReceive(NotificationCenter.default.publisher(for: CloudDirectoryNameStore.didChangeNotification)) { _ in
                cloudDirectoryNameRefreshID = UUID()
            }
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
        let isSourceCaching = activeCacheRun?.sourceID == source.id || hasSourceDownloads
        let isAnotherSourceCaching = (activeCacheRun != nil && activeCacheRun?.sourceID != source.id) || hasOtherSourceDownloads
        let cacheButtonTitle: LocalizedStringKey = isSourceCaching ? "source_cache_all_loading" : "source_cache_all_short"

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
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
                        Text(source.type.displayName)
                        if let host = source.host, !host.isEmpty { Text("·"); Text(host) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
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

            if let scan = scanning, scan.isScanning || scan.canResume {
                VStack(alignment: .leading, spacing: 4) {
                    if scan.totalCount > 0 {
                        ProgressView(value: min(scan.progress, 1.0)).tint(.accentColor)
                    } else {
                        ProgressView().tint(.accentColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Text(scan.isScanning ? scan.currentFile : String(localized: "scan_resume_hint")).lineLimit(1)
                        Spacer()
                        if scan.totalCount > 0 {
                            Text("\(scan.scannedCount)/\(scan.totalCount)").monospacedDigit()
                        } else {
                            // Show "newly added" instead of "files scanned" — the
                            // latter implied every file was being reprocessed even
                            // when ConnectorScanner was just walking known songs.
                            Text(String(format: String(localized: "new_songs_added"), scan.addedCount))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                    // 安抚: 让用户明确知道扫描在后台跑, 可以离开当前页面继续用 app。
                    Text("scan_runs_in_background_hint")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                // Phase A finished. If there are still bare songs from this source
                // (cloud sources fill metadata in the background), show a softer
                // "loading details" indicator so users don't think the scan is
                // stuck or "interrupted". Filter matches `MetadataBackfillService`
                // exactly (excludes already-failed songs) so this number agrees
                // with the global "remaining" in StorageManagementView.
                let bare = backfill.remainingCount(forSource: source.id)
                if bare > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.7).tint(.secondary)
                            Text("backfill_in_progress").font(.caption2)
                            Spacer()
                            Text(String(format: String(localized: "backfill_remaining"), bare))
                                .font(.caption2).monospacedDigit()
                        }
                        Text("backfill_runs_in_background_hint")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("backfill_keep_app_alive_hint")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
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
                        scanService.scanSource(
                            source,
                            sourceManager: sourceManager,
                            library: library,
                            sourceStore: sourceStore,
                            scraperService: scraperService
                        )
                    }
                } else if source.type.isServerLibrary {
                    // 服务端整库源(媒体服务器 / Subsonic)直接全库扫描 — 无需选目录
                    sourceActionButton(
                        cacheButtonTitle,
                        systemImage: "arrow.down.circle",
                        prominence: .accent,
                        isLoading: isSourceCaching,
                        isDisabled: isSourceCaching || source.songCount == 0 || isAnotherSourceCaching
                    ) {
                        presentCacheConfirmation(for: source, songs: playableSongs(for: source))
                    }

                    sourceActionButton(
                        scanning?.canResume == true ? "resume_scan" : "scan",
                        systemImage: scanning?.canResume == true ? "arrow.clockwise.circle" : "waveform.badge.magnifyingglass",
                        prominence: .success,
                        isDisabled: scanning?.isScanning == true
                    ) {
                        scanService.scanSource(
                            source,
                            sourceManager: sourceManager,
                            library: library,
                            sourceStore: sourceStore,
                            scraperService: scraperService
                        )
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
                        isLoading: isSourceCaching,
                        isDisabled: isSourceCaching || source.songCount == 0 || isAnotherSourceCaching
                    ) {
                        presentCacheConfirmation(for: source, songs: playableSongs(for: source))
                    }

                    if !dirs.isEmpty {
                        sourceActionButton(
                            scanning?.canResume == true ? "resume_scan" : "scan",
                            systemImage: scanning?.canResume == true ? "arrow.clockwise.circle" : "waveform.badge.magnifyingglass",
                            prominence: .success,
                            isDisabled: scanning?.isScanning == true
                        ) {
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
        localImportAlert = nil
        showExistingLocalFileImporter = true
    }

    private func handleExistingLocalImport(_ result: Result<[URL], Error>) {
        showExistingLocalFileImporter = false
        switch result {
        case .success(let urls):
            guard !urls.isEmpty, let source = localImportTargetSource else { return }
            startExistingLocalImport(urls, for: currentSource(for: source))
        case .failure(let error):
            localImportAlert = SourceLocalImportAlert(
                title: String(localized: "local_import_err_title"),
                message: error.localizedDescription
            )
        }
    }

    private func startExistingLocalImport(_ urls: [URL], for source: MusicSource) {
        localImportTask?.cancel()
        localImportAlert = nil
        localImportTargetSource = currentSource(for: source)
        localImportProgress = LocalImportService.CopyProgress(
            phase: .discovering,
            currentFileName: "",
            processed: 0,
            total: 0,
            copied: 0,
            skipped: 0
        )

        localImportTask = Task {
            var finalResult: LocalImportService.CopyResult?
            for await event in LocalImportService.copyEvents(urls, cleanupPickedCopies: true) {
                guard !Task.isCancelled else { return }
                switch event {
                case .progress(let progress):
                    localImportProgress = progress
                case .finished(let result):
                    finalResult = result
                }
            }

            guard !Task.isCancelled, let outcome = finalResult else { return }
            localImportTask = nil
            localImportProgress = nil
            if outcome.cancelled { return }

            guard outcome.copied > 0 else {
                localImportAlert = SourceLocalImportAlert(
                    title: localImportFailureTitle(outcome),
                    message: localImportFailureMessage(outcome)
                )
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
                localImportAlert = SourceLocalImportAlert(
                    title: String(localized: "local_import_partial_title"),
                    message: localImportCompletionMessage(outcome)
                )
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
        case .copying:
            if progress.total > 0 {
                return String(
                    format: String(localized: "local_import_progress_copying_format"),
                    progress.processed,
                    progress.total,
                    progress.copied,
                    progress.skipped
                )
            }
            return String(localized: "local_import_progress_preparing")
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
            result.skipped
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
        case .copyFailed:
            return String(localized: "local_import_reason_copy")
        }
    }

    private func localImportNeedsProviderHint(_ reason: LocalImportService.FailureReason) -> Bool {
        switch reason {
        case .coordinatedReadFailed, .invalidAudioFile, .providerReturnedError:
            return true
        case .unsupportedFormat, .notFound, .permissionDenied, .notEnoughSpace, .copyFailed:
            return false
        }
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
        cacheAlert = .confirm(SourceCacheRequest(
            source: source,
            songs: songs,
            estimate: sourceCacheEstimate(for: songs)
        ))
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
            cacheAlert = .completed(SourceCacheCompletion(
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
                },
                onSessionReady: { api in
                    scanService.synologyAPIs[source.id] = api
                },
                onPasswordSaved: {
                    await sourceManager.refreshConnector(for: source.id)
                }
            )
        case .smb:
            SMBBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .webdav:
            WebDAVBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .ftp:
            FTPBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .sftp:
            SFTPBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .nfs:
            NFSBrowserView(source: source, selectedDirectories: selectedDirectories)
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
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .pan115, .pan123:
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
        if source.type.isCloudDrive,
           let displayName = CloudDirectoryNameStore.displayName(for: path, sourceID: source.id),
           !displayName.isEmpty {
            return displayName
        }

        if path == "/" {
            if source.type == .local {
                return String(localized: "local_import_source_name")
            }
            return String(localized: "shared_folders")
        }

        let lastComponent = (path as NSString).lastPathComponent
        return lastComponent.isEmpty ? path : lastComponent
    }

}

private struct SourceDiagnosticsView: View {
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
