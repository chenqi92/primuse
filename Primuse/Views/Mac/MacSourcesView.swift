#if os(macOS)
import SwiftUI
import PrimuseKit

/// macOS-native sources management. Replaces the iOS list-with-toolbar +
/// stacked full-width buttons with a top action bar (Add) plus dense rows
/// showing icon / name / host / song count, and inline action buttons that
/// blend with the sheet chrome rather than an iOS-style blue full-width bar.
///
/// Avoids the `.toolbar { ToolbarItem(.primaryAction) }` from
/// `SourcesView` that ends up merged into the Settings TabView's tab bar
/// — using a plain inline button keeps the + where users expect it.
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
    @State private var cloudDirectoryNameRefreshID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionBar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showAddSource) {
            SourceTypeSelectionView { source in sourceStore.add(source) }
                .frame(minWidth: 520, minHeight: 480)
        }
        .sheet(item: $editingSource) { source in
            AddSourceView(sourceType: source.type, editingSource: source) { updated in
                updateSource(updated.id) { $0 = updated }
                scanService.removeSynologyAPI(for: updated.id)
                Task { await sourceManager.refreshConnector(for: updated.id) }
            }
            .frame(minWidth: 520, minHeight: 460)
        }
        .sheet(item: $connectingSource) { source in
            connectionSheet(for: source)
                .frame(minWidth: 640, minHeight: 480)
        }
        .onReceive(NotificationCenter.default.publisher(for: CloudDirectoryNameStore.didChangeNotification)) { _ in
            cloudDirectoryNameRefreshID = UUID()
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                showAddSource = true
            } label: {
                Label("add_source", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            Spacer()
            Text(String(format: String(localized: "sources_count_format"), sources.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(groupedSources, id: \.0) { category, items in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(category.displayName)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .padding(.horizontal, 4)

                            VStack(spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, source in
                                    sourceRow(source)
                                    if index < items.count - 1 {
                                        Divider().padding(.leading, 56)
                                    }
                                }
                            }
                            .background(.background.secondary, in: .rect(cornerRadius: 10))
                        }
                    }
                }
                .padding(18)
            }
        }
    }

    // MARK: - Row

    private func sourceRow(_ source: MusicSource) -> some View {
        let dirs = decodeDirs(source.extraConfig)
        let scanning = scanService.scanStates[source.id]
        let displayedSongCount = if let scanning, scanning.isScanning || scanning.canResume {
            scanning.scannedCount
        } else {
            source.songCount
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: source.type.iconName)
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(source.isEnabled ? Color.accentColor.gradient : Color.gray.gradient,
                                in: .rect(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(source.name).font(.body).fontWeight(.medium)
                        if !source.isEnabled {
                            Text("disabled")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.quaternary, in: .capsule)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(source.type.displayName)
                        if let host = source.host, !host.isEmpty { Text("·"); Text(host) }
                        if displayedSongCount > 0 {
                            Text("·")
                            Text(String(format: String(localized: "songs_count_inline"), displayedSongCount))
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                rowActions(source: source, dirs: dirs, scanning: scanning)
            }

            if !dirs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(dirs, id: \.self) { dir in
                            Label(directoryDisplayName(for: dir, source: source),
                                  systemImage: "folder.fill")
                                .font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.quaternary, in: .capsule)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.leading, 44)
            }

            if let scan = scanning, scan.isScanning || scan.canResume {
                scanProgress(scan)
                    .padding(.leading, 44)
            } else {
                let bare = backfill.remainingCount(forSource: source.id)
                if bare > 0 {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.55).tint(.secondary)
                        Text("backfill_in_progress").font(.caption2)
                        Text("·").font(.caption2)
                        Text(String(format: String(localized: "backfill_remaining"), bare))
                            .font(.caption2).monospacedDigit()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.leading, 44)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .id("\(source.id)-\(cloudDirectoryNameRefreshID.uuidString)")
        .opacity(source.isEnabled ? 1.0 : 0.55)
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

    @ViewBuilder
    private func rowActions(source: MusicSource, dirs: [String], scanning: ScanService.ScanState?) -> some View {
        HStack(spacing: 6) {
            // Apple Music Library 跟 media server 一样:全库自动扫描,不需要
            // "连接 + 选目录"那一步,直接给一个扫描按钮即可。
            if source.type.isMediaServer || source.type == .appleMusicLibrary {
                Button {
                    runScan(source)
                } label: {
                    Image(systemName: scanning?.canResume == true ? "arrow.clockwise.circle" : "waveform.badge.magnifyingglass")
                }
                .disabled(scanning?.isScanning == true)
                .help(Text(scanning?.canResume == true ? "resume_scan" : "scan"))
            } else {
                Button {
                    connectingSource = source
                } label: {
                    Image(systemName: dirs.isEmpty ? "link" : "folder.badge.gear")
                }
                .help(Text(dirs.isEmpty ? "connect_select_dirs" : "manage_dirs"))

                if !dirs.isEmpty {
                    Button {
                        runScan(source)
                    } label: {
                        Image(systemName: scanning?.canResume == true ? "arrow.clockwise.circle" : "waveform.badge.magnifyingglass")
                    }
                    .disabled(scanning?.isScanning == true)
                    .help(Text(scanning?.canResume == true ? "resume_scan" : "scan"))
                }
            }

            Menu {
                Button {
                    editingSource = source
                } label: {
                    Label("edit", systemImage: "pencil")
                }
                Button {
                    toggleSourceEnabled(source)
                } label: {
                    Label(source.isEnabled ? "disable" : "enable",
                          systemImage: source.isEnabled ? "eye.slash" : "eye")
                }
                Divider()
                Button(role: .destructive) {
                    deleteSource(source)
                } label: {
                    Label("delete", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
            .menuIndicator(.hidden)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        // 不同源类型的按钮数 1~3 个,不固定宽度时每行最右的「...」menu
        // 落在不同竖线上,看着不齐。把整组按钮固定到 trailing 对齐 +
        // 最小宽度,让所有源卡片的菜单按钮垂直对齐。
        .frame(minWidth: 130, alignment: .trailing)
    }

    private func scanProgress(_ scan: ScanService.ScanState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if scan.totalCount > 0 {
                ProgressView(value: min(scan.progress, 1.0))
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Text(scan.isScanning ? scan.currentFile : String(localized: "scan_resume_hint"))
                    .lineLimit(1)
                Spacer()
                if scan.totalCount > 0 {
                    Text("\(scan.scannedCount)/\(scan.totalCount)").monospacedDigit()
                } else {
                    Text(String(format: String(localized: "new_songs_added"), scan.addedCount))
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
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
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox:
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

    private var sources: [MusicSource] { sourceStore.sources }

    private var groupedSources: [(SourceCategory, [MusicSource])] {
        let grouped = Dictionary(grouping: sources) { $0.type.category }
        return SourceCategory.allCases.compactMap { cat in
            guard let items = grouped[cat], !items.isEmpty else { return nil }
            return (cat, items)
        }
    }

    private func toggleSourceEnabled(_ source: MusicSource) {
        updateSource(source.id) { $0.isEnabled.toggle() }
        library.updateSourceVisibility(
            activeSourceIDs: Set(sourceStore.sources.map(\.id)),
            disabledSourceIDs: disabledSourceIDs
        )
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

    private func directoryDisplayName(for path: String, source: MusicSource) -> String {
        if source.type.isCloudDrive,
           let displayName = CloudDirectoryNameStore.displayName(for: path, sourceID: source.id),
           !displayName.isEmpty {
            return displayName
        }
        if path == "/" { return String(localized: "shared_folders") }
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
#endif
