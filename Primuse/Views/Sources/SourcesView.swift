import SwiftUI
import PrimuseKit

struct SourcesView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourceStore
    @Environment(MusicLibrary.self) private var library
    @Environment(ScanService.self) private var scanService
    @Environment(MusicScraperService.self) private var scraperService
    @State private var showAddSource = false
    @State private var editingSource: MusicSource?
    @State private var connectingSource: MusicSource?
    @State private var cloudDirectoryNameRefreshID = UUID()

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
                            Text("\(scan.scannedCount) \(String(localized: "files_scanned"))").monospacedDigit()
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                if source.type.isMediaServer {
                    // Media servers scan all libraries directly — no directory selection needed
                    Button {
                        scanService.scanSource(
                            source,
                            sourceManager: sourceManager,
                            library: library,
                            sourceStore: sourceStore,
                            scraperService: scraperService
                        )
                    } label: {
                        Label(scanning?.canResume == true ? "resume_scan" : "scan",
                              systemImage: scanning?.canResume == true ? "arrow.clockwise.circle" : "waveform.badge.magnifyingglass")
                            .font(.caption).fontWeight(.medium)
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                    }
                    .buttonStyle(.bordered).tint(.green)
                    .disabled(scanning?.isScanning == true)
                } else {
                    Button { connectingSource = source } label: {
                        Label(
                            dirs.isEmpty ? String(localized: "connect_select_dirs") : String(localized: "manage_dirs"),
                            systemImage: dirs.isEmpty ? "link" : "folder.badge.gear"
                        )
                        .font(.caption).fontWeight(.medium)
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                    }
                    .buttonStyle(.bordered)
                    .tint(dirs.isEmpty ? .accentColor : .secondary)

                    if !dirs.isEmpty {
                        Button {
                            scanService.scanSource(
                                source,
                                sourceManager: sourceManager,
                                library: library,
                                sourceStore: sourceStore,
                                scraperService: scraperService
                            )
                        } label: {
                            Label(scanning?.canResume == true ? "resume_scan" : "scan",
                                  systemImage: scanning?.canResume == true ? "arrow.clockwise.circle" : "waveform.badge.magnifyingglass")
                                .font(.caption).fontWeight(.medium)
                                .frame(maxWidth: .infinity).padding(.vertical, 7)
                        }
                        .buttonStyle(.bordered).tint(.green)
                        .disabled(scanning?.isScanning == true)
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
            Button { editingSource = source } label: { Label("edit", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { deleteSource(source) } label: { Label("delete", systemImage: "trash") }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteSource(source) } label: { Label("delete", systemImage: "trash") }
            Button { editingSource = source } label: { Label("edit", systemImage: "pencil") }.tint(.orange)
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
        case .baiduPan, .aliyunDrive, .googleDrive, .oneDrive, .dropbox:
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
