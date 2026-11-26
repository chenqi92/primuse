import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - 来源页交给详情页的几件事

/// 音乐源卡片点进去的那一页,要借来源页的几件事:扫描、连接与选目录、编辑连接。
/// 这几张表单由来源页搭好、详情页自己弹 —— 压在导航栈下面的来源页弹不出表单。
struct SourceDetailActions {
    var scan: (MusicSource, SourceSyncMode) -> Void
    /// 连接与选目录页。`onEditAddress` 由详情页给:关掉这一页,再打开编辑表单。
    var connectionSheet: (MusicSource, _ onEditAddress: @escaping () -> Void) -> AnyView
    /// 连接页关掉以后(目录可能改了),由来源页决定要不要重扫。
    var connectionSheetDidClose: () -> Void
    var editSheet: (MusicSource) -> AnyView
}

/// 卡片点进去:有文件的源进文件页,音乐服务器进概览,Apple Music 进资料库页。
struct SourceDetailPage: View {
    let source: MusicSource
    let actions: SourceDetailActions
    /// 卡片上的「选择目录」「管理目录」:文件页一进来就在勾选扫描目录。
    var startsScopeEditing = false

    @Environment(SourcesStore.self) private var sourcesStore

    var body: some View {
        let current = sourcesStore.source(id: source.id) ?? source
        if SourceFileBrowserPolicy.browsesFiles(current.type) {
            SourceFilesRootPage(source: current, actions: actions, startsScopeEditing: startsScopeEditing)
        } else if current.type == .appleMusic {
            AppleMusicSourcePage(source: current)
        } else {
            SourceOverviewPage(source: current, actions: actions)
        }
    }
}

// MARK: - 详情页共用的弹出页

/// 诊断、编辑连接、连接与选目录:几个详情页都要。
struct SourceDetailSheets: ViewModifier {
    let source: MusicSource
    let actions: SourceDetailActions
    @Binding var presented: SourceDetailSheet?
    /// 连接页或编辑表单关上以后(可能重新登录、改了地址),给详情页重新读一次的机会。
    var onConnectionChanged: (() -> Void)?

    @State private var connectionWasOpen = false
    @State private var editWasOpen = false
    @State private var editAfterConnection = false

    func body(content: Content) -> some View {
        content
            .sheet(item: $presented, onDismiss: didDismiss) { sheet in
                switch sheet {
                case .diagnostics:
                    SourceDiagnosticsView(source: source)
                case .edit:
                    actions.editSheet(source)
                        .onAppear { editWasOpen = true }
                case .connection:
                    actions.connectionSheet(source) {
                        editAfterConnection = true
                        presented = nil
                    }
                    .onAppear { connectionWasOpen = true }
                }
            }
    }

    private func didDismiss() {
        if editWasOpen {
            editWasOpen = false
            onConnectionChanged?()
        }
        guard connectionWasOpen else { return }
        connectionWasOpen = false
        actions.connectionSheetDidClose()
        // 连接页里点了「修改地址」:等它关完再开编辑表单,同一处不能一边关一边开。
        if editAfterConnection {
            editAfterConnection = false
            presented = .edit
            return
        }
        onConnectionChanged?()
    }
}

enum SourceDetailSheet: String, Identifiable {
    case diagnostics
    case edit
    case connection

    var id: String { rawValue }
}

extension View {
    func sourceDetailSheets(
        source: MusicSource,
        actions: SourceDetailActions,
        presented: Binding<SourceDetailSheet?>,
        onConnectionChanged: (() -> Void)? = nil
    ) -> some View {
        modifier(SourceDetailSheets(
            source: source,
            actions: actions,
            presented: presented,
            onConnectionChanged: onConnectionChanged
        ))
    }
}

// MARK: - 状态横幅

/// 详情页顶上那几条:连不上、扫描出错、要确认的移除、扫描进度、读取标签。
/// 只订阅这个源自己的扫描状态,不让整页跟着进度重画。
struct SourceStatusBanners: View {
    let source: MusicSource
    let onDiagnose: () -> Void
    let onScan: () -> Void
    let onOpenMetadata: () -> Void

    @Environment(SourceManager.self) private var sourceManager

    /// 每条各占列表里的一行;没有要说的就一行都不占。
    var body: some View {
        if sourceManager.isSourceManuallyOffline(source) {
            SourceOfflineModeNotice(source: source)
        } else if sourceManager.unreachablePlaybackSourceIDs.contains(source.id) {
            SourceUnreachableNotice(source: source)
        }
        if source.type == .googleDrive {
            GoogleDriveAccessChangeNotice()
        }
        SourceScanStateReader(sourceID: source.id) { scanning in
            SourceScanBanner(
                scanning: scanning,
                sourceID: source.id,
                onDiagnose: onDiagnose,
                onScan: onScan,
                onOpenMetadata: onOpenMetadata
            )
        }
    }
}

private struct SourceScanBanner: View {
    let scanning: ScanService.ScanState?
    let sourceID: String
    let onDiagnose: () -> Void
    let onScan: () -> Void
    let onOpenMetadata: () -> Void

    var body: some View {
        if let failure = scanning?.failureMessage, !failure.isEmpty {
            SourceBannerBox(tint: .red) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("notify_scan_failed_title", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Spacer(minLength: 8)
                    Button("source_diagnostics", action: onDiagnose)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                }
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let message = scanning?.reconciliationMessage, !message.isEmpty {
            SourceBannerBox(tint: .orange) {
                Label(message, systemImage: "checkmark.shield.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("source_incremental_scan", action: onScan)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        } else if let scan = scanning, scan.isScanning {
            SourceBannerBox(tint: .accentColor) {
                if scan.totalCount > 0 {
                    ProgressView(value: min(scan.progress, 1.0))
                }
                HStack(spacing: 8) {
                    if scan.totalCount == 0 {
                        ProgressView().controlSize(.small)
                    }
                    Text(scan.currentFile)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Group {
                        if scan.totalCount > 0 {
                            Text(verbatim: "\(scan.scannedCount)/\(scan.totalCount)")
                        } else {
                            Text(String(format: String(localized: "new_songs_added"), scan.addedCount))
                        }
                    }
                    .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } else {
            SourceMetadataStatusCard(sourceID: sourceID, openDetails: onOpenMetadata) {
                EmptyView()
            }
        }
    }
}

struct SourceBannerBox<Content: View>: View {
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - 头部

/// 详情页最上面:图标、类型、地址,右边是这个源在本机占了多少,下面是线路。
/// 名字已经在导航栏上,这里不再写一遍。
struct SourceDetailHeader: View {
    let source: MusicSource
    var storage: SourceStorageUsageModel?

    @Environment(SourceManager.self) private var sourceManager

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: source.type.iconName)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(
                    source.isEnabled ? source.type.brandTint.gradient : Color.gray.gradient,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.type.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if let storage {
                SourceStorageHeaderValue(model: storage)
            }
        }
        .accessibilityElement(children: .combine)

        if source.connectionConfiguration != nil, !source.connectionCandidates.isEmpty {
            SourceConnectionRouteStrip(
                source: source,
                activeKind: sourceManager.activeConnectionRoutes[source.id],
                lastSuccessfulKind: sourceManager.lastSuccessfulConnectionRoutes[source.id]
            )
        }

        if OfflineModeState.supportsOfflineMode(for: source.type) {
            offlineModeRow
        }
    }

    @ViewBuilder
    private var offlineModeRow: some View {
        let isGlobal = sourceManager.isGlobalOfflineMode
        Toggle(
            isOn: Binding(
                get: { sourceManager.isSourceManuallyOffline(source) },
                set: { enabled in
                    if isGlobal {
                        if !enabled { sourceManager.setGlobalOfflineMode(false) }
                    } else {
                        sourceManager.setSourceManuallyOffline(enabled, sourceID: source.id)
                    }
                }
            )
        ) {
            Label("offline_mode_title", systemImage: "wifi.slash")
                .foregroundStyle(sourceManager.isSourceManuallyOffline(source) ? .orange : .primary)
        }
        .tint(.orange)
    }

    private var subtitle: String? {
        var parts: [String] = []
        let route = source.connectionConfiguration.flatMap { config in
            SourceCardPresentationPolicy.displayedRoute(
                candidates: source.connectionCandidates,
                active: sourceManager.activeConnectionRoutes[source.id],
                lastSuccessful: sourceManager.lastSuccessfulConnectionRoutes[source.id],
                selected: config.effectiveSelectedRoute
            )
        }
        if let address = SourceCardPresentationPolicy.compactAddress(for: source, displayedRoute: route) {
            parts.append(address)
        } else if source.connectionConfiguration == nil, let summary = source.connectionSummary {
            parts.append(summary)
        }
        if !source.isEnabled {
            parts.append(String(localized: "source_disabled_on_this_device"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 单源处于主动离线模式时的说明条（支持快速切回在线）。
struct SourceOfflineModeNotice: View {
    let source: MusicSource
    @Environment(SourceManager.self) private var sourceManager

    var body: some View {
        SourceBannerBox(tint: .orange) {
            HStack(alignment: .center, spacing: 8) {
                Label("source_card_status_offline_mode", systemImage: "wifi.slash")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer(minLength: 8)
                Button(
                    LocalizedStringKey(
                        sourceManager.isGlobalOfflineMode
                            ? "offline_mode_turn_off_global"
                            : "offline_mode_go_online_source"
                    )
                ) {
                    if sourceManager.isGlobalOfflineMode {
                        sourceManager.setGlobalOfflineMode(false)
                    } else {
                        sourceManager.setSourceManuallyOffline(false, sourceID: source.id)
                    }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
    }
}

/// 一行大数字 + 小标签。卡片和详情页共用。
struct SourceMetricTile: View {
    let value: String
    let label: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - 这台设备上(本机移除、隐藏歌单)

/// 只在这台设备上的几件事。没有内容的行不显示。
struct SourceDeviceRows: View {
    let source: MusicSource
    let onLocalRemovals: () -> Void
    let onHiddenPlaylists: () -> Void

    @Environment(MusicLibrary.self) private var library

    var body: some View {
        let removed = library.locallyRemovedCount(forSourceID: source.id)
        let hidden = library.hiddenMirrorPlaylists(forSourceID: source.id).count
        if removed > 0 {
            Button(action: onLocalRemovals) {
                SourceNavigationRow(
                    title: String(localized: "local_removals_title"),
                    systemImage: "arrow.uturn.backward.circle",
                    value: removed.formatted()
                )
            }
            .buttonStyle(.plain)
        }
        if hidden > 0 {
            Button(action: onHiddenPlaylists) {
                SourceNavigationRow(
                    title: String(localized: "hidden_source_playlists"),
                    systemImage: "eye.slash",
                    value: hidden.formatted()
                )
            }
            .buttonStyle(.plain)
        }
    }
}

struct SourceNavigationRow: View {
    let title: String
    let systemImage: String
    var value: String?
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint == .primary ? Color.secondary : tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(tint)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - 音乐服务器概览

/// 曲库在服务器上的源(Navidrome、Jellyfin…)没有文件可看:这一页放扫描与同步、
/// 自动刷新,以及只关于这台设备的几件事。
struct SourceOverviewPage: View {
    let source: MusicSource
    let actions: SourceDetailActions

    @Environment(SourceManager.self) private var sourceManager
    @State private var sheet: SourceDetailSheet?
    @State private var showsMetadata = false
    @State private var showsLocalRemovals = false
    @State private var showsHiddenPlaylists = false
    /// 管理员账号才有「服务器管理」(Navidrome、Jellyfin、Emby)。
    @State private var adminAccess: ServerAdmin.Access?
    @State private var adminUserCount: Int?
    @State private var showsUsers = false
    @State private var storage: SourceStorageUsageModel
    @State private var toasts = PMToastPresenter()

    init(source: MusicSource, actions: SourceDetailActions) {
        self.source = source
        self.actions = actions
        _storage = State(initialValue: SourceStorageUsageModel(sourceID: source.id))
    }

    var body: some View {
        List {
            Section {
                SourceDetailHeader(source: source, storage: storage)
                SourceOverviewMetrics(source: source)
            }
            .listRowSeparator(.hidden)

            Section {
                SourceStatusBanners(
                    source: source,
                    onDiagnose: { sheet = .diagnostics },
                    onScan: { actions.scan(source, .automatic) },
                    onOpenMetadata: { showsMetadata = true }
                )
                SourceScanButtonRow(source: source) { mode in actions.scan(source, mode) }
            } header: {
                Text("source_overview_scan_section")
            }

            if let adminAccess, adminAccess.isAdmin {
                ServerAdminSection(
                    source: source,
                    access: adminAccess,
                    userCount: adminUserCount,
                    onOpenUsers: { showsUsers = true }
                )
            }

            if AppServices.shared.serverCatalogAutoRefresh.supportsAutomaticRefresh(source) {
                Section {
                    ServerCatalogAutoRefreshControl(source: source)
                }
            }

            if source.type == .tingReader {
                Section {
                    TingReaderProgressSyncControls(source: source)
                }
            }

            SourceStorageSection(model: storage) { toasts.show($0) }

            Section {
                SourceDeviceRows(
                    source: source,
                    onLocalRemovals: { showsLocalRemovals = true },
                    onHiddenPlaylists: { showsHiddenPlaylists = true }
                )
                Button { sheet = .diagnostics } label: {
                    SourceNavigationRow(title: String(localized: "source_diagnostics"), systemImage: "stethoscope")
                }
                .buttonStyle(.plain)
                if source.type == .synologyAudioStation {
                    Button { sheet = .connection } label: {
                        SourceNavigationRow(title: String(localized: "audio_station_sign_in"), systemImage: "person.badge.key")
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("source_overview_device_section")
            }
        }
        .navigationTitle(source.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button { sheet = .edit } label: { Label("edit", systemImage: "pencil") }
                    Button { actions.scan(source, .deep) } label: {
                        Label("source_full_scan", systemImage: "arrow.triangle.2.circlepath.circle")
                    }
                } label: {
                    Label("more", systemImage: "ellipsis")
                }
            }
        }
        .sourceDetailSheets(source: source, actions: actions, presented: $sheet)
        .sourceStorageUsage(storage, songCount: source.songCount)
        .pmToastHost(toasts)
        .navigationDestination(isPresented: $showsMetadata) { SourceMetadataStatusView(source: source) }
        .navigationDestination(isPresented: $showsLocalRemovals) { SourceLocalRemovalsView(source: source) }
        .navigationDestination(isPresented: $showsUsers) {
            if let adminAccess { ServerUsersPage(source: source, access: adminAccess) }
        }
        .sheet(isPresented: $showsHiddenPlaylists) { SourceHiddenPlaylistsView(source: source) }
        .task(id: "\(source.id)-\(showsUsers)") {
            // 从用户页回来时再数一次人数。
            guard !showsUsers, source.isEnabled,
                  let admin = sourceManager.connector(for: source) as? any ServerAdminConnector,
                  let access = try? await admin.serverAdminAccess() else { return }
            adminAccess = access
            guard access.isAdmin else { return }
            adminUserCount = (try? await admin.serverAdminUsers())?.count
        }
    }
}

private struct SourceOverviewMetrics: View {
    let source: MusicSource

    @Environment(MusicLibrary.self) private var library
    /// 这个源在曲库里有几张专辑、几位艺人;后台数一次。
    @State private var counts: (albums: Int, artists: Int)?

    var body: some View {
        HStack(spacing: 12) {
            SourceScanStateReader(sourceID: source.id) { scanning in
                let count = if let scanning, scanning.isScanning || scanning.canResume {
                    scanning.scannedCount
                } else {
                    source.songCount
                }
                SourceMetricTile(value: count.formatted(), label: String(localized: "tab_songs"))
            }
            SourceMetricTile(
                value: counts.map { $0.albums.formatted() } ?? "—",
                label: String(localized: "tab_albums")
            )
            SourceMetricTile(
                value: counts.map { $0.artists.formatted() } ?? "—",
                label: String(localized: "tab_artists")
            )
            SourceMetricTile(
                value: source.lastScannedAt.map(SourceDateText.relative) ?? "—",
                label: String(localized: "source_overview_last_scan")
            )
        }
        .task(id: source.songCount) {
            let songs = library.visibleSongs(forSourceID: source.id)
            counts = await Task.detached(priority: .utility) {
                (
                    albums: Set(songs.compactMap(\.albumID)).count,
                    artists: Set(songs.compactMap(\.artistID)).count
                )
            }.value
        }
    }
}

/// 扫描 / 继续扫描。正在扫时转圈、不能再点。
struct SourceScanButtonRow: View {
    let source: MusicSource
    let scan: (SourceSyncMode) -> Void

    var body: some View {
        SourceScanStateReader(sourceID: source.id) { scanning in
            let isScanning = scanning?.isScanning == true
            let title: LocalizedStringKey = scanning?.canResume == true ? "resume_scan" : "source_incremental_scan"
            Button {
                scan(.automatic)
            } label: {
                HStack {
                    Spacer()
                    if isScanning {
                        ProgressView().controlSize(.small)
                        Text("scanning")
                    } else {
                        Label(
                            title,
                            systemImage: scanning?.canResume == true
                                ? "arrow.clockwise.circle" : "waveform.badge.magnifyingglass"
                        )
                    }
                    Spacer()
                }
                .font(.body.weight(.semibold))
            }
            .disabled(isScanning || !source.isEnabled)
        }
    }
}

/// 大小写成「0 KB」「3.2 GB」,不写「Zero KB」。
@MainActor
enum SourceByteText {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}

@MainActor
enum SourceDateText {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    static func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 {
            return String(localized: "source_date_just_now")
        }
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

// MARK: - 服务器自动刷新

/// 「自动刷新」一个选项列表:关,或者隔多久刷一次。卡片上的胶囊和文件页「更多」里共用。
struct SourceAutoRefreshPicker: View {
    let sourceID: String

    var body: some View {
        let refresh = AppServices.shared.serverCatalogAutoRefresh
        Picker(selection: Binding<SourceAutomaticRefreshInterval?>(
            get: { refresh.isEnabled(for: sourceID) ? refresh.refreshInterval(for: sourceID) : nil },
            set: { interval in
                guard let interval else {
                    refresh.setEnabled(false, for: sourceID)
                    return
                }
                if refresh.isEnabled(for: sourceID) {
                    refresh.setRefreshInterval(interval, for: sourceID)
                } else {
                    // 先换间隔再打开,只按新间隔检查一次。
                    refresh.setRefreshInterval(interval, for: sourceID)
                    refresh.setEnabled(true, for: sourceID)
                }
            }
        )) {
            Text("source_card_metric_off").tag(nil as SourceAutomaticRefreshInterval?)
            ForEach(SourceAutomaticRefreshInterval.allCases, id: \.self) { interval in
                Text(Duration.seconds(interval.timeInterval), format: .units(allowed: [.hours], width: .wide))
                    .tag(Optional(interval))
            }
        } label: {
            Label("server_auto_refresh", systemImage: "clock.arrow.circlepath")
        }
    }
}

/// 原来挂在音乐服务器卡片上的自动刷新设置,搬到概览页。
struct ServerCatalogAutoRefreshControl: View {
    let source: MusicSource

    var body: some View {
        let refresh = AppServices.shared.serverCatalogAutoRefresh
        Toggle(isOn: refresh.enabledBinding(for: source.id)) {
            SettingsInfoLabel("server_auto_refresh") {
                Text(LocalizedStringKey(source.type.isServerLibrary
                    ? "server_auto_refresh_description" : "source_auto_refresh_description"))
            }
        }

        if refresh.isEnabled(for: source.id) {
            Picker("source_auto_refresh_interval", selection: refresh.intervalBinding(for: source.id)) {
                ForEach(SourceAutomaticRefreshInterval.allCases, id: \.self) { interval in
                    Text(Duration.seconds(interval.timeInterval), format: .units(allowed: [.hours], width: .wide))
                        .tag(interval)
                }
            }
            .pickerStyle(.menu)
        }

        if refresh.supportsServerScanRequest(source) {
            Toggle(isOn: refresh.scanOnLaunchBinding(for: source.id)) {
                SettingsInfoLabel("server_scan_on_launch") {
                    Text("server_scan_on_launch_description")
                }
            }
            .disabled(!refresh.isEnabled(for: source.id))
        }

        if refresh.supportsCatalogRemovalModeChoice(source) {
            Picker(selection: refresh.removalModeBinding(for: source.id)) {
                Text("catalog_prune_mode_confirm").tag(ServerCatalogRemovalMode.confirmFirst)
                Text("catalog_prune_mode_immediate").tag(ServerCatalogRemovalMode.immediate)
            } label: {
                SettingsInfoLabel("catalog_prune_mode_title") {
                    Text("catalog_prune_mode_description")
                }
            }
            .pickerStyle(.menu)
        }
    }
}

// MARK: - Apple Music

/// Apple Music 没有文件:授权与同步、从目录选歌、两个和它有关的开关。
struct AppleMusicSourcePage: View {
    let source: MusicSource

    @Environment(AppleMusicService.self) private var appleMusic
    @Environment(AppleMusicLibraryService.self) private var appleMusicLibrary
    @AppStorage(AppleMusicFeatureSettings.catalogSearchEnabledKey) private var catalogSearchEnabled = true
    @AppStorage(AppleMusicFeatureSettings.autoAddToSmartPlaylistsKey) private var autoAddToSmartPlaylists = false
    @State private var isAuthorizing = false
    @State private var storage: SourceStorageUsageModel
    @State private var toasts = PMToastPresenter()

    init(source: MusicSource) {
        self.source = source
        _storage = State(initialValue: SourceStorageUsageModel(sourceID: source.id))
    }

    var body: some View {
        List {
            Section {
                SourceDetailHeader(source: source, storage: storage)
                AppleMusicSourceMetrics(source: source)
            }
            .listRowSeparator(.hidden)

            Section {
                AppleMusicSyncStateRow()
                syncButton
                #if os(iOS)
                if appleMusic.authState == .authorized, source.isEnabled {
                    AppleMusicCatalogPickerButton { appleMusicLibrary.sync() }
                }
                #endif
            } header: {
                Text("source_apple_music_sync_section")
            } footer: {
                AppleMusicRestrictedSongsNote()
            }

            Section {
                Toggle(isOn: $catalogSearchEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Catalog Search")
                        Text("source_apple_music_catalog_search_detail")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: catalogSearchEnabled) { _, enabled in
                    if !enabled { appleMusic.clearCatalogSearchResults() }
                }
                Toggle(isOn: $autoAddToSmartPlaylists) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto Add to Smart Playlists")
                        Text("source_apple_music_smart_playlists_detail")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("source_apple_music_in_primuse_section")
            }

            SourceStorageSection(model: storage) { toasts.show($0) }

            Section {
                Button(action: openSystemSettings) {
                    SourceNavigationRow(title: String(localized: "open_system_settings"), systemImage: "gear")
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(source.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sourceStorageUsage(storage, songCount: source.songCount)
        .pmToastHost(toasts)
    }

    @ViewBuilder
    private var syncButton: some View {
        switch appleMusic.authState {
        case .authorized:
            Button { appleMusicLibrary.sync() } label: {
                Label(syncTitle, systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isSyncing || !source.isEnabled)
        case .notDetermined:
            Button {
                isAuthorizing = true
                Task { @MainActor in
                    await appleMusic.requestAuthorization()
                    isAuthorizing = false
                    if appleMusic.authState == .authorized { appleMusicLibrary.sync() }
                }
            } label: {
                Label("settings_apple_music_connect", systemImage: "applelogo")
            }
            .disabled(isAuthorizing)
        case .denied, .restricted:
            Button(action: openSystemSettings) {
                Label("open_system_settings", systemImage: "gear")
            }
        }
    }

    private var isSyncing: Bool {
        if case .syncing = appleMusicLibrary.state { return true }
        return false
    }

    private var syncTitle: LocalizedStringKey {
        if case .done = appleMusicLibrary.state { return "apple_music_library_resync" }
        return "apple_music_library_sync"
    }

    private func openSystemSettings() {
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
}

private struct AppleMusicSourceMetrics: View {
    let source: MusicSource

    @Environment(AppleMusicLibraryService.self) private var appleMusicLibrary

    var body: some View {
        HStack(spacing: 12) {
            SourceMetricTile(value: source.songCount.formatted(), label: String(localized: "tab_songs"))
            SourceMetricTile(
                value: lastSyncedAt.map(SourceDateText.relative) ?? "—",
                label: String(localized: "source_card_metric_last_sync")
            )
        }
    }

    private var lastSyncedAt: Date? {
        if case .done(_, let at) = appleMusicLibrary.state { return at }
        return appleMusicLibrary.syncHistory.previousCompletedAt
    }
}

/// 「已同步 N 首」里有几首没订阅放不了(只在云端、带版权保护)。这些歌照样留在曲库里,
/// 跟“音乐”App 里本机能放的数目对不上时由这一句解释;一首都没有或者有订阅时不显示。
private struct AppleMusicRestrictedSongsNote: View {
    @Environment(AppleMusicLibraryService.self) private var appleMusicLibrary

    var body: some View {
        let count = appleMusicLibrary.activeRestrictedLibrarySongCount
        if count > 0 {
            Text(String(format: String(localized: "apple_music_restricted_songs_footer_format"), count))
        }
    }
}

/// 同步状态一行:没授权时先说授权的事。
struct AppleMusicSyncStateRow: View {
    @Environment(AppleMusicService.self) private var appleMusic
    @Environment(AppleMusicLibraryService.self) private var appleMusicLibrary

    var body: some View {
        switch appleMusic.authState {
        case .denied, .restricted:
            Label("settings_apple_music_denied", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .notDetermined:
            Label("apple_music_library_not_authorized", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .authorized:
            switch appleMusicLibrary.state {
            case .idle:
                Text("apple_music_library_idle").foregroundStyle(.secondary)
            case .syncing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("apple_music_library_syncing").foregroundStyle(.secondary)
                }
            case .done(let count, let at):
                Label(
                    String(
                        format: String(localized: "apple_music_library_done_format"),
                        count,
                        at.formatted(date: .abbreviated, time: .shortened)
                    ),
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }
}
