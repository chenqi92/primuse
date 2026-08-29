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
    @Environment(ThemeService.self) private var theme

    @State private var showAddSource = false
    @State private var editingSource: MusicSource?
    @State private var connectingSource: MusicSource?
    @State private var diagnosingSource: MusicSource?
    @State private var inspectingMetadataSource: MusicSource?
    @State private var directorySelectionSession: SourceDirectorySelectionSession?
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
            SourceTypeSelectionView(
                submitIntent: .continueToConnection,
                onAdd: { source in
                    if MediaServerSourceCreationPolicy.requiresPreflight(
                        for: source.type,
                        isEditing: false
                    ) {
                        try sourceStore.addDurably(source)
                    } else {
                        sourceStore.add(source)
                    }
                    // Local 已通过 basePath 限定扫描范围，不需要再次选择目录；
                    // 保存后立即扫描，和 iOS 的新增来源流程保持一致。
                    if MediaServerSourceCreationPolicy.requiresPreflight(
                        for: source.type,
                        isEditing: false
                    ) {
                        runScan(source)
                    } else if source.type == .local {
                        runScan(source)
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
            // 不要再套外层 .frame —— AddSourceView 自己已经定了 560/620/660 的尺寸,
            // 外面再压一个更小的 520×460 会把内容挤变形 (编辑态错位的根因)。新增
            // 走 SourceTypeSelectionView 也是不套 frame, 这样两条路径表现一致。
            AddSourceView(sourceType: source.type, editingSource: source) { updated in
                updateSource(updated.id) { $0 = updated }
                scanService.removeSynologyAPI(for: updated.id)
                Task { await sourceManager.refreshConnector(for: updated.id) }
            }
        }
        .sheet(item: $connectingSource, onDismiss: finishDirectorySelectionSession) { source in
            // 这个 sheet 里既有 (云盘/Synology 的) 授权小步骤, 也有 940 宽的树形
            // 目录浏览器。macOS 的 sheet 会按"首屏内容"定窗宽, 之后切到更宽的浏览
            // 步骤时不会自己变大 → 浏览器被挤到溢出、左右两侧裁切。把固定 ideal
            // 尺寸放在最外层 (不随步骤变), 让窗口一开始就按浏览器的尺寸来。
            connectionSheet(for: source)
                .frame(minWidth: 880, idealWidth: 940, minHeight: 600, idealHeight: 680)
                .onAppear { beginDirectorySelectionSession(for: source) }
        }
        .sheet(item: $diagnosingSource) { source in
            SourceDiagnosticsView(source: source)
        }
        .sheet(item: $inspectingMetadataSource) { source in
            NavigationStack {
                SourceMetadataStatusView(source: source)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("done") { inspectingMetadataSource = nil }
                        }
                    }
            }
            .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 680)
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudDirectoryNameStore.didChangeNotification)) { _ in
            cloudDirectoryNameRefreshID = UUID()
        }
        .task(id: "metadata-status-\(sources.map(\.id).joined(separator: ","))") {
            backfill.refreshStatusSnapshot()
        }
        .confirmationDialog(
            Text("source_remove_confirm_title"),
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
                Text(verbatim: String(
                    format: String(localized: "source_remove_named_format"),
                    source.name
                ))
            }
            Button("cancel", role: .cancel) { sourceToDelete = nil }
        } message: { _ in
            Text("source_remove_confirm_message")
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
                        .background(theme.uiAccentColor, in: .rect(cornerRadius: 8))
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
            ContentUnavailableView(
                "no_sources",
                systemImage: "externaldrive.badge.plus",
                description: Text("no_sources_desc").font(.callout)
            )
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
        let dirs = source.scannedDirectories
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
                    .background(source.isEnabled ? theme.uiAccentColor.gradient : Color.gray.gradient,
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
                    if source.type.isAwaitingPublicAPI {
                        Label(source.type.subtitle, systemImage: "clock.badge.exclamationmark")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 8)
                statusBadge(state)
            }

            if source.connectionConfiguration != nil,
               source.connectionCandidates.isEmpty == false {
                SourceConnectionRouteStrip(
                    source: source,
                    activeKind: sourceManager.activeConnectionRoutes[source.id],
                    lastSuccessfulKind: sourceManager.lastSuccessfulConnectionRoutes[source.id]
                )
            }

            cardBody(source, scanning: scanning, displayedSongCount: displayedSongCount)
                // 给内容区一个统一最小高度: "扫描中"(三行进度) 和 "已同步"(一行)
                // 的卡片高度就一致了, 不会某张在扫描时突然变高、其它变矮。
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)

            if source.type == .navidrome {
                navidromeAutoRefreshControl(for: source)
            }

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
            Button { diagnosingSource = source } label: {
                Label("source_diagnostics", systemImage: "stethoscope")
            }
            if source.type.scansEntireLibrary || !dirs.isEmpty {
                Button { runDeepScan(source) } label: {
                    Label("source_deep_scan", systemImage: "arrow.triangle.2.circlepath.circle")
                }
                .disabled(scanning?.isScanning == true)
            }
            Divider()
            Button(role: .destructive) {
                // 与卡片操作行的删除 pill 统一走二次确认对话框,
                // 右键误点不会直接触发软删除。
                sourceToDelete = source
            } label: {
                Label("delete", systemImage: "trash")
            }
        }
    }

    private func navidromeAutoRefreshControl(for source: MusicSource) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("navidrome_auto_refresh")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text("navidrome_auto_refresh_description")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Toggle("", isOn: navidromeAutoRefreshBinding(for: source.id))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("navidrome_auto_refresh"))
                .accessibilityHint(Text("navidrome_auto_refresh_description"))
        }
        .padding(10)
        .background(PMColor.bgDeep.opacity(0.5), in: .rect(cornerRadius: 9))
    }

    private func navidromeAutoRefreshBinding(for sourceID: String) -> Binding<Bool> {
        Binding(
            get: {
                AppServices.shared.navidromeAutoRefresh.isEnabled(for: sourceID)
            },
            set: { enabled in
                AppServices.shared.navidromeAutoRefresh.setEnabled(enabled, for: sourceID)
            }
        )
    }

    // MARK: - Card body

    @ViewBuilder
    private func cardBody(_ source: MusicSource, scanning: ScanService.ScanState?, displayedSongCount: Int) -> some View {
        if let failureMessage = scanning?.failureMessage, !failureMessage.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Label("notify_scan_failed_title", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.bad)
                    Spacer(minLength: 8)
                    Button {
                        diagnosingSource = source
                    } label: {
                        Label("source_diagnostics_short", systemImage: "stethoscope")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.uiAccentColor)
                }
                Text(failureMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textMuted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PMColor.bad.opacity(0.05), in: .rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(PMColor.bad.opacity(0.16), lineWidth: 0.8)
            }
        } else if let reconciliationMessage = scanning?.reconciliationMessage,
                  !reconciliationMessage.isEmpty {
            Label {
                Text(reconciliationMessage)
                    .font(.system(size: 10.5))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "checkmark.shield.fill")
            }
            .foregroundStyle(.orange)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.06), in: .rect(cornerRadius: 9))
        } else if let scan = scanning, scan.isScanning || scan.canResume {
            scanBox(scan)
        } else {
            let metadataSummary = backfill.sourceStatusSummary(forSource: source.id)
            if metadataSummary.affectedCount > 0 {
                macMetadataStatusButton(source, summary: metadataSummary)
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

    private func macMetadataStatusButton(
        _ source: MusicSource,
        summary: MetadataBackfillSourceSummary
    ) -> some View {
        let activityState = backfill.activityState(forSource: source.id)
        return Button {
            inspectingMetadataSource = source
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    macMetadataActivityIndicator(activityState)
                    Text(macMetadataActivityTitle(activityState))
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 8)
                    Text("metadata_status_open")
                        .font(.system(size: 10.5, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(macMetadataSummaryText(summary))
                    .font(.system(size: 10.5))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(PMColor.textMuted)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PMColor.bgDeep.opacity(0.5), in: .rect(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("metadata_status_open"))
        .accessibilityValue(Text(macMetadataSummaryText(summary)))
        .accessibilityIdentifier("sources.metadataStatus.\(source.id)")
    }

    @ViewBuilder
    private func macMetadataActivityIndicator(_ state: MetadataBackfillActivityState) -> some View {
        switch state {
        case .running, .retrying:
            ProgressView().controlSize(.small).scaleEffect(0.8)
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

    private func macMetadataActivityTitle(
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

    private func macMetadataSummaryText(_ summary: MetadataBackfillSourceSummary) -> String {
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
                ProgressView(value: min(scan.progress, 1.0)).tint(theme.uiAccentColor)
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
            // 整库来源（含已由 basePath 限定范围的 Local）直接扫描，
            // 不再进入没有意义的「连接 + 选目录」流程。
            if source.type.scansEntireLibrary {
                scanPill(source, scanning: scanning)
                pill("settings_title", systemImage: "slider.horizontal.3") { editingSource = source }
            } else if dirs.isEmpty {
                pill("connect_select_dirs", systemImage: "link", tint: theme.uiAccentColor) { connectingSource = source }
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
        return !s.isScanning && s.failureMessage?.isEmpty == false
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
        if source.connectionConfiguration != nil {
            return source.type.displayName
        }
        if let summary = source.connectionSummary {
            return "\(source.type.displayName) · \(summary)"
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
    private func connectionSheet(
        for source: MusicSource,
        stagedDirectories: Binding<[String]>? = nil,
        onConfirm: ((Bool) -> Void)? = nil
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
                onSessionReady: { api in scanService.synologyAPIs[source.id] = api },
                onPasswordSaved: { await sourceManager.refreshConnector(for: source.id) }
            )
        case .smb:
            SMBBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories,
                onConfirm: onConfirm
            )
        case .webdav:
            WebDAVBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories,
                onConfirm: onConfirm
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
        case .upnp: UPnPBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .qnap, .ugreen, .fnos, .s3:
            // S3 stores region + dir list together in extraConfig; the S3-aware
            // binding above keeps the region intact while the connector browser
            // drives directory selection. Other connector-backed NAS sources
            // use the same browser as the iOS sources screen.
            ConnectorDirectoryBrowserView(
                source: source,
                connector: sourceManager.connector(for: source),
                selectedDirectories: selectedDirectories
            )
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox, .drime, .pan115, .pan123:
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

    private func setEnabled(_ source: MusicSource, _ enabled: Bool) {
        if !enabled {
            pauseBackgroundWork(for: source.id)
        }
        // Disable only removes the source from active views/scans. Deleting
        // source library rows and caches belongs to deleteSource(_:).
        updateSource(source.id) { $0.isEnabled = enabled }
        library.updateDisabledSourceIDs(disabledSourceIDs)
        backfill.sourceAvailabilityChanged(forSourceID: source.id)
    }

    private func toggleSourceEnabled(_ source: MusicSource) {
        let current = currentSource(for: source)
        setEnabled(current, !current.isEnabled)
    }

    private var disabledSourceIDs: Set<String> {
        Set(sourceStore.sources.filter { !$0.isEnabled }.map(\.id))
    }

    /// 软删除:把源移入「最近删除」,同时立即从资料库移除该源歌曲。
    /// 凭据、云盘 token、书签仍保留到彻底删除,便于从回收站还原后重新扫描。
    private func deleteSource(_ source: MusicSource) {
        stopBackgroundWork(for: source.id)
        scanService.removeSynologyAPI(for: source.id)
        sourceStore.remove(id: source.id)
    }

    private func stopBackgroundWork(for sourceID: String) {
        scanService.cancelScan(for: sourceID)
        scanService.removeCheckpoint(for: sourceID)
    }

    private func pauseBackgroundWork(for sourceID: String) {
        scanService.cancelScan(for: sourceID)
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

    private func runDeepScan(_ source: MusicSource) {
        scanService.scanSource(
            source,
            mode: .deep,
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
