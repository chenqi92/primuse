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

    @Environment(SourcesStore.self) private var sourcesStore

    var body: some View {
        let current = sourcesStore.source(id: source.id) ?? source
        if SourceFileBrowserPolicy.browsesFiles(current.type) {
            SourceFilesRootPage(source: current, actions: actions)
        } else if current.type == .appleMusic {
            AppleMusicSourcePage(source: current)
        } else {
            SourceOverviewPage(source: current, actions: actions)
        }
    }
}

// MARK: - 详情页共用的弹出页

/// 诊断、编辑连接、连接与选目录:三个详情页都要。
struct SourceDetailSheets: ViewModifier {
    let source: MusicSource
    let actions: SourceDetailActions
    @Binding var presented: SourceDetailSheet?

    @State private var connectionWasOpen = false
    @State private var editAfterConnection = false

    func body(content: Content) -> some View {
        content
            .sheet(item: $presented, onDismiss: didDismiss) { sheet in
                switch sheet {
                case .diagnostics:
                    SourceDiagnosticsView(source: source)
                case .edit:
                    actions.editSheet(source)
                case .connection:
                    actions.connectionSheet(source) {
                        editAfterConnection = true
                        presented = nil
                    }
                    .onAppear { connectionWasOpen = true }
                case .storage:
                    SourceStorageSheet(source: source)
                }
            }
    }

    private func didDismiss() {
        guard connectionWasOpen else { return }
        connectionWasOpen = false
        actions.connectionSheetDidClose()
        // 连接页里点了「修改地址」:等它关完再开编辑表单,同一处不能一边关一边开。
        if editAfterConnection {
            editAfterConnection = false
            presented = .edit
        }
    }
}

enum SourceDetailSheet: String, Identifiable {
    case diagnostics
    case edit
    case connection
    case storage

    var id: String { rawValue }
}

extension View {
    func sourceDetailSheets(
        source: MusicSource,
        actions: SourceDetailActions,
        presented: Binding<SourceDetailSheet?>
    ) -> some View {
        modifier(SourceDetailSheets(source: source, actions: actions, presented: presented))
    }
}

// MARK: - 本机占用胶囊

/// 详情页右上角:这个源在本机占了多少,点开分类清理。
struct SourceStorageCapsule: View {
    let sourceID: String
    /// 本机占用页关上时由 true 变回去,重新量一次(刚清理过)。
    var isSheetClosed = true
    let action: () -> Void

    @Environment(SourceManager.self) private var sourceManager
    @Environment(MusicLibrary.self) private var library
    @State private var bytes: Int64?

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "internaldrive")
                if let bytes {
                    Text(SourceByteText.string(bytes))
                        .monospacedDigit()
                }
            }
        }
        .accessibilityLabel(Text(verbatim: String(
            format: String(localized: "source_storage_capsule_label_format"),
            bytes.map(SourceByteText.string) ?? "…"
        )))
        .task(id: "\(sourceID)-\(isSheetClosed)") {
            guard isSheetClosed else { return }
            let usage = await sourceManager.sourceStorageUsage(
                sourceID: sourceID,
                songs: library.visibleSongs(forSourceID: sourceID)
            )
            bytes = usage.totalBytes
        }
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
        if sourceManager.unreachablePlaybackSourceIDs.contains(source.id) {
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
                Button("scan", action: onScan)
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

/// 详情页最上面:图标、类型、地址、线路。名字已经在导航栏上,这里不再写一遍。
struct SourceDetailHeader: View {
    let source: MusicSource

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
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)

        if source.connectionConfiguration != nil, !source.connectionCandidates.isEmpty {
            SourceConnectionRouteStrip(
                source: source,
                activeKind: sourceManager.activeConnectionRoutes[source.id],
                lastSuccessfulKind: sourceManager.lastSuccessfulConnectionRoutes[source.id]
            )
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if source.connectionConfiguration == nil, let summary = source.connectionSummary {
            parts.append(summary)
        }
        if !source.isEnabled {
            parts.append(String(localized: "source_disabled_on_this_device"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 一行大数字 + 小标签。卡片和详情页共用。
struct SourceMetricTile: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
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
        .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        List {
            Section {
                SourceDetailHeader(source: source)
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
                SourceStorageCapsule(sourceID: source.id, isSheetClosed: sheet == nil) { sheet = .storage }
                Menu {
                    Button { sheet = .edit } label: { Label("edit", systemImage: "pencil") }
                    Button { actions.scan(source, .deep) } label: {
                        Label("source_deep_scan", systemImage: "arrow.triangle.2.circlepath.circle")
                    }
                } label: {
                    Label("more", systemImage: "ellipsis")
                }
            }
        }
        .sourceDetailSheets(source: source, actions: actions, presented: $sheet)
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
            let title: LocalizedStringKey = scanning?.canResume == true ? "resume_scan" : "scan"
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

/// 原来挂在音乐服务器卡片上的自动刷新设置,搬到概览页。
struct ServerCatalogAutoRefreshControl: View {
    let source: MusicSource

    var body: some View {
        let refresh = AppServices.shared.serverCatalogAutoRefresh
        Toggle(isOn: Binding(
            get: { refresh.isEnabled(for: source.id) },
            set: { refresh.setEnabled($0, for: source.id) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("server_auto_refresh")
                Text(LocalizedStringKey(source.type.isServerLibrary
                    ? "server_auto_refresh_description" : "source_auto_refresh_description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        if refresh.isEnabled(for: source.id) {
            Picker("source_auto_refresh_interval", selection: Binding(
                get: { refresh.refreshInterval(for: source.id) },
                set: { refresh.setRefreshInterval($0, for: source.id) }
            )) {
                ForEach(SourceAutomaticRefreshInterval.allCases, id: \.self) { interval in
                    Text(Duration.seconds(interval.timeInterval), format: .units(allowed: [.hours], width: .wide))
                        .tag(interval)
                }
            }
            .pickerStyle(.menu)
        }

        if refresh.supportsServerScanRequest(source) {
            Toggle(isOn: Binding(
                get: { refresh.isServerScanOnLaunchEnabled(for: source.id) },
                set: { refresh.setServerScanOnLaunchEnabled($0, for: source.id) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("server_scan_on_launch")
                    Text("server_scan_on_launch_description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!refresh.isEnabled(for: source.id))
        }

        if refresh.supportsCatalogRemovalModeChoice(source) {
            Picker(selection: Binding(
                get: { refresh.catalogRemovalMode(for: source.id) },
                set: { refresh.setCatalogRemovalMode($0, for: source.id) }
            )) {
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
    @State private var sheet: SourceDetailSheet?
    @State private var isAuthorizing = false

    var body: some View {
        List {
            Section {
                SourceDetailHeader(source: source)
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
            }

            Section {
                Toggle(isOn: Binding(
                    get: { catalogSearchEnabled },
                    set: { enabled in
                        catalogSearchEnabled = enabled
                        if !enabled { appleMusic.clearCatalogSearchResults() }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Catalog Search")
                        Text("source_apple_music_catalog_search_detail")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SourceStorageCapsule(sourceID: source.id, isSheetClosed: sheet == nil) { sheet = .storage }
            }
        }
        .sheet(item: $sheet) { _ in SourceStorageSheet(source: source) }
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

/// 同步状态一行:没授权时先说授权的事。
struct AppleMusicSyncStateRow: View {
    @Environment(AppleMusicService.self) private var appleMusic
    @Environment(AppleMusicLibraryService.self) private var appleMusicLibrary

    var body: some View {
        switch appleMusic.authState {
        case .denied, .restricted:
            Label("settings_apple_music_denied", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .notDetermined, .authorized:
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
