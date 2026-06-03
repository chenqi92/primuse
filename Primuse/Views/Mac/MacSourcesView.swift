#if os(macOS)
import SwiftUI
import PrimuseKit

/// macOS-native sources management aligned with design SRC-23..28: an eyebrow
/// + "Connected" title, a status-breakdown summary line, an attention banner
/// for sources that need re-auth, and a flat 2-column card grid. Each card
/// carries a status dot, a mono host line, a stats / scan-progress body, and a
/// row of text pills (rescan / browse / settings) plus an enable switch.
struct MacSourcesView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourceStore
    @Environment(MusicLibrary.self) private var library
    @Environment(ScanService.self) private var scanService
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(MetadataBackfillService.self) private var backfill

    @State private var showAddSource = false
    @State private var editingSource: MusicSource?
    @State private var connectingSource: MusicSource?
    @State private var sourceToDelete: MusicSource?
    @State private var cloudDirectoryNameRefreshID = UUID()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private let statusBlue = Color(red: 0.24, green: 0.48, blue: 0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionBar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showAddSource) {
            SourceTypeSelectionView { source in sourceStore.add(source) }
        }
        .sheet(item: $editingSource) { source in
            // 不要再套外层 .frame —— AddSourceView 自己已经定了 560/620/660 的尺寸,
            // 外面再压一个更小的 520×460 会把内容挤变形 (编辑态错位的根因)。新增
            // 走 SourceTypeSelectionView 也是不套 frame, 这样两条路径表现一致。
            AddSourceView(sourceType: source.type, editingSource: source) { updated in
                updateSource(updated.id) { $0 = updated }
                scanService.removeSynologyAPI(for: updated.id)
                Task { await sourceManager.refreshConnector(for: updated.id) }
            }
        }
        .sheet(item: $connectingSource) { source in
            // 这个 sheet 里既有 (云盘/Synology 的) 授权小步骤, 也有 940 宽的树形
            // 目录浏览器。macOS 的 sheet 会按"首屏内容"定窗宽, 之后切到更宽的浏览
            // 步骤时不会自己变大 → 浏览器被挤到溢出、左右两侧裁切。把固定 ideal
            // 尺寸放在最外层 (不随步骤变), 让窗口一开始就按浏览器的尺寸来。
            connectionSheet(for: source)
                .frame(minWidth: 880, idealWidth: 940, minHeight: 600, idealHeight: 680)
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudDirectoryNameStore.didChangeNotification)) { _ in
            cloudDirectoryNameRefreshID = UUID()
        }
        .confirmationDialog(
            Text(verbatim: "移除此音乐源？"),
            isPresented: Binding(
                get: { sourceToDelete != nil },
                set: { if !$0 { sourceToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: sourceToDelete
        ) { source in
            Button(role: .destructive) {
                deleteSource(source)
                sourceToDelete = nil
            } label: {
                Text(verbatim: "移除「\(source.name)」")
            }
            Button("cancel", role: .cancel) { sourceToDelete = nil }
        } message: { _ in
            Text(verbatim: "会从资料库移除该源及其歌曲记录，本地 / 远端文件不受影响。")
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Lz("Music Sources"))
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .foregroundStyle(PMColor.textMuted)
                    Text(Lz("Connected"))
                        .font(.system(size: 32, weight: .bold))
                        .tracking(-0.5)
                        .foregroundStyle(PMColor.text)
                }
                Spacer()
                Button {
                    showAddSource = true
                } label: {
                    Label("add_source", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(PMColor.brand, in: .rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Text(summaryText)
                .font(.system(size: 13))
                .foregroundStyle(PMColor.textMuted)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if sources.isEmpty {
            ContentUnavailableView {
                Label("no_sources", systemImage: "externaldrive.badge.plus")
            } description: {
                Text("no_sources_desc").font(.callout)
            } actions: {
                Button {
                    showAddSource = true
                } label: {
                    Label("add_source", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: PMSpace.m14) {
                    if !attentionSources.isEmpty {
                        attentionBanner
                    }

                    // 设计稿: 单一「已连接」分组 + 2 列自适应卡片网格。
                    LazyVGrid(
                        // 卡片放大一点 (min 440), 这样操作行的「重新扫描/浏览/设置/
                        // 删除」几个按钮不会被挤到截断成「重…」。
                        columns: [GridItem(.adaptive(minimum: 440, maximum: 600),
                                           spacing: PMSpace.m14, alignment: .top)],
                        alignment: .leading,
                        spacing: PMSpace.m14
                    ) {
                        ForEach(sources, id: \.id) { source in
                            sourceCard(source)
                                .pmCard(cornerRadius: PMRadius.l)
                        }
                    }
                }
                .padding(.horizontal, PMSpace.xxxl)
                .padding(.vertical, PMSpace.l)
                .padding(.bottom, 80)
            }
            .background(PMColor.bg.ignoresSafeArea())
        }
    }

    // MARK: - Attention banner (SRC-24)

    private var attentionBanner: some View {
        let first = attentionSources.first
        return HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PMColor.bad)
                .frame(width: 30, height: 30)
                .background(PMColor.bad.opacity(0.16), in: .rect(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: String(localized: "sources_attention_banner_title"), attentionSources.count))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text("source_auth_failed_message_generic")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if let first {
                Button("connect_select_dirs") { connectingSource = first }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(PMColor.matBtn, in: .rect(cornerRadius: 6))
            }
        }
        .padding(12)
        .pmCard(cornerRadius: PMRadius.l)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(PMColor.bad)
                .frame(width: 3)
                .padding(.vertical, 8)
        }
    }

    // MARK: - Card

    private func sourceCard(_ source: MusicSource) -> some View {
        let dirs = decodeDirs(source.extraConfig)
        let scanning = scanService.scanStates[source.id]
        let state = runtimeState(source)
        let displayedSongCount = if let scanning, scanning.isScanning || scanning.canResume {
            scanning.scannedCount
        } else {
            source.songCount
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: source.type.iconName)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(source.isEnabled ? Color.accentColor.gradient : Color.gray.gradient,
                                in: .rect(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(hostLine(source))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 8)
                statusBadge(state)
            }

            cardBody(source, scanning: scanning, displayedSongCount: displayedSongCount)
                // 给内容区一个统一最小高度: "扫描中"(三行进度) 和 "已同步"(一行)
                // 的卡片高度就一致了, 不会某张在扫描时突然变高、其它变矮。
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            actionsRow(source, scanning: scanning, dirs: dirs)
        }
        .padding(14)
        .id("\(source.id)-\(cloudDirectoryNameRefreshID.uuidString)")
        .opacity(source.isEnabled ? 1.0 : 0.6)
        .contextMenu {
            Button {
                toggleSourceEnabled(source)
            } label: {
                Label(source.isEnabled ? "disable" : "enable",
                      systemImage: source.isEnabled ? "eye.slash" : "eye")
            }
            Button { editingSource = source } label: {
                Label("edit", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                deleteSource(source)
            } label: {
                Label("delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Card body

    @ViewBuilder
    private func cardBody(_ source: MusicSource, scanning: ScanService.ScanState?, displayedSongCount: Int) -> some View {
        if let scan = scanning, scan.isScanning || scan.canResume {
            scanBox(scan)
        } else {
            let bare = backfill.remainingCount(forSource: source.id)
            if bare > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text("backfill_in_progress").font(.system(size: 11))
                    Text(verbatim: "·").font(.system(size: 11))
                    Text(String(format: String(localized: "backfill_remaining"), bare))
                        .font(.system(size: 11)).monospacedDigit()
                    Spacer()
                }
                .foregroundStyle(PMColor.textMuted)
                .padding(10)
                .background(PMColor.bgDeep.opacity(0.5), in: .rect(cornerRadius: 9))
            } else {
                HStack(spacing: 6) {
                    if displayedSongCount > 0 {
                        Text(verbatim: displayedSongCount.formatted())
                            .foregroundStyle(PMColor.text)
                            .monospacedDigit()
                        Text(Lz("songs_count_inline"))
                        Text(verbatim: "·")
                    }
                    Text(syncedText(source))
                    Spacer()
                }
                .font(.system(size: 12))
                .foregroundStyle(PMColor.textMuted)
            }
        }
    }

    private func scanBox(_ scan: ScanService.ScanState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if scan.isScanning, !scan.currentFile.isEmpty {
                Text(scan.currentFile)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if scan.totalCount > 0 {
                ProgressView(value: min(scan.progress, 1.0)).tint(PMColor.brand)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text(scan.isScanning ? "scanning" : "scan_resume_hint")
                Spacer()
                if scan.totalCount > 0 {
                    Text(verbatim: "\(scan.scannedCount)/\(scan.totalCount)").monospacedDigit()
                } else {
                    Text(String(format: String(localized: "new_songs_added"), scan.addedCount))
                        .monospacedDigit()
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(PMColor.textMuted)
        }
        .padding(10)
        .background(PMColor.bgDeep.opacity(0.5), in: .rect(cornerRadius: 9))
    }

    // MARK: - Status badge

    private func statusBadge(_ state: SourceRuntimeState) -> some View {
        HStack(spacing: 5) {
            Circle().fill(stateColor(state)).frame(width: 7, height: 7)
            Text(stateLabel(state))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(stateColor(state))
        }
        .fixedSize()
    }

    // MARK: - Actions row

    @ViewBuilder
    private func actionsRow(_ source: MusicSource, scanning: ScanService.ScanState?, dirs: [String]) -> some View {
        HStack(spacing: 6) {
            // 服务端整库源(媒体服务器 / Subsonic) / Apple Music 资料库:全库自动扫描,无需「连接 + 选目录」。
            if source.type.isServerLibrary || source.type == .appleMusicLibrary {
                scanPill(source, scanning: scanning)
                pill("settings_title", systemImage: "slider.horizontal.3") { editingSource = source }
            } else if dirs.isEmpty {
                pill("connect_select_dirs", systemImage: "link", tint: PMColor.brand) { connectingSource = source }
                pill("settings_title", systemImage: "slider.horizontal.3") { editingSource = source }
            } else {
                scanPill(source, scanning: scanning)
                pill("browse", systemImage: "folder") { connectingSource = source }
                pill("settings_title", systemImage: "slider.horizontal.3") { editingSource = source }
            }

            // 移除音乐源 —— 之前只藏在右键菜单里, 用户找不到; 这里给个显式入口。
            pill("delete", systemImage: "trash", tint: PMColor.bad) { sourceToDelete = source }

            Spacer(minLength: 4)

            macSwitch(isOn: source.isEnabled) { setEnabled(source, $0) }
        }
    }

    @ViewBuilder
    private func scanPill(_ source: MusicSource, scanning: ScanService.ScanState?) -> some View {
        if scanning?.isScanning == true {
            pill("pause", systemImage: "pause.fill") { scanService.cancelScan(for: source.id) }
        } else {
            let resuming = scanning?.canResume == true
            pill(resuming ? "resume_scan" : "rescan",
                 systemImage: resuming ? "arrow.clockwise" : "arrow.triangle.2.circlepath",
                 tint: PMColor.ok) {
                runScan(source)
            }
        }
    }

    private func pill(
        _ title: LocalizedStringKey,
        systemImage: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        MacPillButton(title: title, systemImage: systemImage, tint: tint, action: action)
    }

    private func macSwitch(isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.9)) { set(!isOn) }
        } label: {
            Capsule()
                .fill(isOn ? PMColor.ok : PMColor.dividerStrong)
                .frame(width: 32, height: 18)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
        .help(Text(isOn ? "disable" : "enable"))
    }

    // MARK: - Runtime state

    private enum SourceRuntimeState { case online, scanning, attention, disabled }

    private func runtimeState(_ source: MusicSource) -> SourceRuntimeState {
        if !source.isEnabled { return .disabled }
        if scanService.scanStates[source.id]?.isScanning == true { return .scanning }
        if isAttention(source) { return .attention }
        return .online
    }

    /// A source "needs attention" when its last scan attempt this session failed
    /// before making progress — a preflight / credential error leaves a
    /// non-resumable state with a message but zero scanned files.
    private func isAttention(_ source: MusicSource) -> Bool {
        guard source.isEnabled, let s = scanService.scanStates[source.id] else { return false }
        return !s.isScanning && !s.canResume && s.scannedCount == 0 && s.totalCount == 0 && !s.currentFile.isEmpty
    }

    private func stateColor(_ state: SourceRuntimeState) -> Color {
        switch state {
        case .online: PMColor.ok
        case .scanning: statusBlue
        case .attention: PMColor.bad
        case .disabled: PMColor.textFaint
        }
    }

    private func stateLabel(_ state: SourceRuntimeState) -> LocalizedStringKey {
        switch state {
        case .online: "source_state_online"
        case .scanning: "scanning"
        case .attention: "source_state_attention"
        case .disabled: "disabled"
        }
    }

    private var attentionSources: [MusicSource] {
        sources.filter { runtimeState($0) == .attention }
    }

    private var summaryText: String {
        let total = sources.count
        let online = sources.filter { runtimeState($0) == .online }.count
        let scanning = sources.filter { runtimeState($0) == .scanning }.count
        let attention = sources.filter { runtimeState($0) == .attention }.count
        let disabled = sources.filter { !$0.isEnabled }.count

        var parts = [String(format: String(localized: "sources_count_format"), total)]
        if online > 0 { parts.append("\(online) \(String(localized: "source_state_online"))") }
        if scanning > 0 { parts.append("\(scanning) \(String(localized: "scanning"))") }
        if attention > 0 { parts.append("\(attention) \(String(localized: "source_state_attention"))") }
        if disabled > 0 { parts.append("\(disabled) \(String(localized: "disabled"))") }
        return parts.joined(separator: " · ")
    }

    private func hostLine(_ source: MusicSource) -> String {
        if let host = source.host, !host.isEmpty {
            return "\(source.type.displayName) · \(host)"
        }
        return source.type.displayName
    }

    private func syncedText(_ source: MusicSource) -> String {
        guard let date = source.lastScannedAt else {
            return String(localized: "source_never_synced")
        }
        let relative = Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        return String(format: String(localized: "source_synced_ago_format"), relative)
    }

    // MARK: - Connection sheet (delegates to existing browsers)

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
                onDeviceIdSaved: { did in updateSource(source.id) { $0.deviceId = did } },
                onSessionReady: { api in scanService.synologyAPIs[source.id] = api }
            )
        case .smb: SMBBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .webdav: WebDAVBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .ftp: FTPBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .sftp: SFTPBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .nfs: NFSBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .upnp: UPnPBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .pan115, .pan123:
            CloudDriveConnectionView(source: source, selectedDirectories: selectedDirectories)
        default:
            ContentUnavailableView(
                "connection_failed",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text("save_then_connect_hint")
            )
        }
    }

    // MARK: - Helpers (reused logic)

    /// Apple Music (MusicKit 流播) 是 AppServices 兜底 upsert 的虚拟 source,
    /// 没有目录/扫描/编辑概念 — Mac 上走 Settings → Apple Music 授权 tab,
    /// 留在 Sources 列表里只会让用户误点 connect 按钮。直接隐藏。
    private var sources: [MusicSource] {
        sourceStore.sources.filter { $0.type != .appleMusic }
    }

    private func setEnabled(_ source: MusicSource, _ enabled: Bool) {
        updateSource(source.id) { $0.isEnabled = enabled }
        library.updateDisabledSourceIDs(disabledSourceIDs)
    }

    private func toggleSourceEnabled(_ source: MusicSource) {
        updateSource(source.id) { $0.isEnabled.toggle() }
        library.updateDisabledSourceIDs(disabledSourceIDs)
    }

    private var disabledSourceIDs: Set<String> {
        Set(sourceStore.sources.filter { !$0.isEnabled }.map(\.id))
    }

    private func deleteSource(_ source: MusicSource) {
        scanService.cancelScan(for: source.id)
        scanService.removeCheckpoint(for: source.id)
        library.removeSongsForSource(source.id)
        sourceStore.remove(id: source.id)
        scanService.removeSynologyAPI(for: source.id)
        sourceManager.deleteSourceCaches(sourceID: source.id)
        LocalBookmarkStore.remove(sourceID: source.id)
        KeychainService.deletePassword(for: source.id)
        if source.type.isCloudDrive {
            Task {
                let tm = CloudTokenManager(sourceID: source.id)
                await tm.deleteTokens()
                await tm.deleteAppCredentials()
            }
            CloudDirectoryNameStore.deleteAll(for: source.id)
        }
        Task { await sourceManager.removeConnector(for: source.id) }
    }

    private func runScan(_ source: MusicSource) {
        scanService.scanSource(
            source,
            sourceManager: sourceManager,
            library: library,
            sourceStore: sourceStore,
            scraperService: scraperService
        )
    }

    private func currentSource(for source: MusicSource) -> MusicSource {
        sourceStore.source(id: source.id) ?? source
    }

    private func updateSource(_ sourceID: String, mutate: (inout MusicSource) -> Void) {
        sourceStore.update(sourceID, mutate: mutate)
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

// MARK: - Pill button

/// Small hover-aware text pill matching the design's `pm-mat-btn`. A standalone
/// view so each pill owns its own hover state.
private struct MacPillButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var tint: Color?
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint ?? PMColor.textMuted)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background((tint ?? PMColor.text).opacity(hover ? 0.16 : 0.10), in: .rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}
#endif
