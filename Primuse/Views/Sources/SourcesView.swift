import SwiftUI
import PrimuseKit

struct SourcesView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourceStore
    @Environment(MusicLibrary.self) private var library
    @Environment(ScanService.self) private var scanService
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(MetadataBackfillService.self) private var backfill
    @State private var showAddSource = false
    @State private var editingSource: MusicSource?
    @State private var connectingSource: MusicSource?
    @State private var diagnosingSource: MusicSource?
    @State private var cloudDirectoryNameRefreshID = UUID()
    /// Apple Music 这个虚拟 source 没有目录 / 体检的概念, 行内按钮换成
    /// "打开 Apple Music 设置" 的跳转 ── 走 NavigationStack 的 destination 而不是 sheet,
    /// 让推入栈跟其他 Settings 子页体验一致 (左上角"返回"而不是"完成")。
    @State private var openAppleMusicSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if sources.isEmpty { emptyView }
                else { sourceList }
            }
            .navigationTitle("sources_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddSource = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAddSource) {
                SourceTypeSelectionView { source in sourceStore.add(source) }
            }
            .sheet(item: $editingSource) { source in
                AddSourceView(sourceType: source.type, editingSource: source) { updated in
                    updateSource(updated.id) { $0 = updated }
                    scanService.removeSynologyAPI(for: updated.id)
                    Task { await sourceManager.refreshConnector(for: updated.id) }
                }
            }
            .sheet(item: $connectingSource) { source in
                connectionSheet(for: source)
            }
            .sheet(item: $diagnosingSource) { source in
                SourceDiagnosticsView(source: source)
            }
            .navigationDestination(isPresented: $openAppleMusicSettings) {
                AppleMusicSettingsView()
            }
            .onReceive(NotificationCenter.default.publisher(for: CloudDirectoryNameStore.didChangeNotification)) { _ in
                cloudDirectoryNameRefreshID = UUID()
            }
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
        List {
            ForEach(groupedSources, id: \.0) { category, items in
                Section(category.displayName) {
                    ForEach(items) { source in sourceCard(source) }
                }
            }
        }
    }

    private func sourceCard(_ source: MusicSource) -> some View {
        let dirs = decodeDirs(source.extraConfig)
        let scanning = scanService.scanStates[source.id]
        let displayedSongCount = if let scanning, scanning.isScanning || scanning.canResume {
            scanning.scannedCount
        } else {
            source.songCount
        }

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
                if displayedSongCount > 0 {
                    Text("\(displayedSongCount)")
                        .font(.caption).fontWeight(.semibold).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary).clipShape(Capsule())
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
                } else if source.type.isServerLibrary {
                    // 服务端整库源(媒体服务器 / Subsonic)直接全库扫描 — 无需选目录
                    sourceActionButton("source_diagnostics_short", systemImage: "stethoscope") {
                        diagnosingSource = source
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

                    sourceActionButton("source_diagnostics_short", systemImage: "stethoscope") {
                        diagnosingSource = source
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
                Button(role: .destructive) { deleteSource(source) } label: { Label("delete", systemImage: "trash") }
            }
        }
        .swipeActions(edge: .trailing) {
            if source.id != AppleMusicLibraryService.systemSourceID {
                Button(role: .destructive) { deleteSource(source) } label: { Label("delete", systemImage: "trash") }
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
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 18)
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
        .opacity(isDisabled ? 0.55 : 1)
    }

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
        sourceStore.sources
    }

    @ViewBuilder
    private func connectionSheet(for source: MusicSource) -> some View {
        let selectedDirectories = Binding(
            get: { decodeDirs(currentSource(for: source).extraConfig) },
            set: { newDirs in updateSource(source.id) { $0.extraConfig = encodeDirs(newDirs) } }
        )

        switch source.type {
        case .synology:
            ConnectionFlowView(
                source: source,
                selectedDirectories: selectedDirectories,
                onDeviceIdSaved: { did in
                    updateSource(source.id) { $0.deviceId = did }
                },
                onSessionReady: { api in
                    scanService.synologyAPIs[source.id] = api
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

    private func toggleSourceEnabled(_ source: MusicSource) {
        updateSource(source.id) { $0.isEnabled.toggle() }
        library.updateDisabledSourceIDs(disabledSourceIDs)
    }

    private var disabledSourceIDs: Set<String> {
        Set(sourceStore.sources.filter { !$0.isEnabled }.map(\.id))
    }

    private func deleteSource(_ source: MusicSource) {
        // Cancel any active scan first — otherwise it keeps adding songs back
        scanService.cancelScan(for: source.id)
        scanService.removeCheckpoint(for: source.id)
        library.removeSongsForSource(source.id)
        sourceStore.remove(id: source.id)
        scanService.removeSynologyAPI(for: source.id)
        KeychainService.deletePassword(for: source.id)
        if source.type.isCloudDrive {
            Task {
                let tokenManager = CloudTokenManager(sourceID: source.id)
                await tokenManager.deleteTokens()
                await tokenManager.deleteAppCredentials()
            }
            CloudDirectoryNameStore.deleteAll(for: source.id)
        }
        Task { await sourceManager.removeConnector(for: source.id) }
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
            return String(localized: "shared_folders")
        }

        let lastComponent = (path as NSString).lastPathComponent
        return lastComponent.isEmpty ? path : lastComponent
    }

    private func decodeDirs(_ config: String?) -> [String] {
        guard let config, let data = config.data(using: .utf8),
              let dirs = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return dirs
    }

    private func encodeDirs(_ dirs: [String]) -> String? {
        (try? JSONEncoder().encode(dirs)).flatMap { String(data: $0, encoding: .utf8) }
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
