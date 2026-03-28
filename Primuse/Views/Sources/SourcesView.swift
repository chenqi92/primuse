import SwiftUI
import PrimuseKit

struct SourcesView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourceStore
    @Environment(MusicLibrary.self) private var library
    @State private var showAddSource = false
    @State private var editingSource: MusicSource?
    @State private var connectingSource: MusicSource?
    @State private var scanStates: [String: ScanState] = [:]
    // Keep Synology API sessions alive for scanning
    @State private var synologyAPIs: [String: SynologyAPI] = [:]

    struct ScanState: Equatable {
        var isScanning: Bool = false
        var progress: Double = 0
        var currentFile: String = ""
        var scannedCount: Int = 0
    }

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
                    synologyAPIs[updated.id] = nil
                    Task { await sourceManager.refreshConnector(for: updated.id) }
                }
            }
            .sheet(item: $connectingSource) { source in
                connectionSheet(for: source)
            }
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("no_sources", systemImage: "externaldrive.badge.plus")
        } description: { Text("no_sources_desc") } actions: {
            Button { showAddSource = true } label: { Text("add_source") }
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
        let scanning = scanStates[source.id]

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: source.type.iconName)
                    .font(.title3).foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.gradient)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name).font(.body).fontWeight(.medium)
                    HStack(spacing: 4) {
                        Text(source.type.displayName)
                        if let host = source.host, !host.isEmpty { Text("·"); Text(host) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if source.songCount > 0 {
                    Text("\(source.songCount)")
                        .font(.caption).fontWeight(.semibold).monospacedDigit()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary).clipShape(Capsule())
                }
            }

            if !dirs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(dirs, id: \.self) { dir in
                            Label((dir as NSString).lastPathComponent, systemImage: "folder.fill")
                                .font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                        }
                    }
                }
            }

            if let scan = scanning, scan.isScanning {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: min(scan.progress, 1.0)).tint(.accentColor)
                    HStack {
                        Text(scan.currentFile).lineLimit(1)
                        Spacer()
                        Text("\(scan.scannedCount) \(String(localized: "songs_found"))").monospacedDigit()
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
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
                    Button { scanSource(source) } label: {
                        Label("scan", systemImage: "waveform.badge.magnifyingglass")
                            .font(.caption).fontWeight(.medium)
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                    }
                    .buttonStyle(.bordered).tint(.green)
                    .disabled(scanning?.isScanning == true)
                }
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteSource(source) } label: { Label("delete", systemImage: "trash") }
            Button { editingSource = source } label: { Label("edit", systemImage: "pencil") }.tint(.orange)
        }
    }

    // MARK: - Real Scan

    private func scanSource(_ source: MusicSource) {
        let dirs = decodeDirs(source.extraConfig)
        guard !dirs.isEmpty else { return }

        scanStates[source.id] = ScanState(isScanning: true)

        Task {
            switch source.type {
            case .synology:
                await scanSynology(source: source, directories: dirs)
            case .smb, .webdav, .jellyfin, .emby:
                await scanConnectorSource(source: source, directories: dirs)
            default:
                scanStates[source.id] = ScanState(
                    isScanning: false,
                    currentFile: String(localized: "scan_needs_connect")
                )
            }
        }
    }

    private func scanSynology(source: MusicSource, directories: [String]) async {
        let api: SynologyAPI
        if let existing = synologyAPIs[source.id] {
            api = existing
        } else {
            let created = SynologyAPI(
                host: source.host ?? "",
                port: source.port ?? 5001,
                useSsl: source.useSsl
            )
            synologyAPIs[source.id] = created
            api = created
        }

        if await api.isLoggedIn == false {
            let password = KeychainService.getPassword(for: source.id) ?? ""
            let loginResult = await api.login(
                account: source.username ?? "",
                password: password,
                deviceName: source.rememberDevice ? "Primuse-iOS" : nil,
                deviceId: source.deviceId
            )

            if loginResult.needs2FA {
                scanStates[source.id] = ScanState(
                    isScanning: false,
                    currentFile: String(localized: "scan_needs_connect")
                )
                connectingSource = source
                return
            }

            guard loginResult.success else {
                scanStates[source.id] = ScanState(
                    isScanning: false,
                    currentFile: loginResult.errorMessage ?? "Login failed"
                )
                return
            }

            if let did = loginResult.deviceId {
                updateSource(source.id) { $0.deviceId = did }
            }
        }

        let scanner = SynologyScanner(api: api, sourceID: source.id)
        let stream = await scanner.scan(directories: directories)

        do {
            var lastSongs: [Song] = []
            for try await update in stream {
                scanStates[source.id]?.scannedCount = update.scannedCount
                scanStates[source.id]?.currentFile = update.currentFile
                lastSongs = update.songs
            }

            completeScan(sourceID: source.id, songs: lastSongs)
        } catch {
            scanStates[source.id] = ScanState(
                isScanning: false,
                currentFile: error.localizedDescription
            )
        }
    }

    private func scanConnectorSource(source: MusicSource, directories: [String]) async {
        let connector = sourceManager.connector(for: source)
        let scanner = ConnectorScanner(connector: connector, sourceID: source.id)
        let stream = await scanner.scan(directories: directories)

        do {
            var lastSongs: [Song] = []
            for try await update in stream {
                scanStates[source.id]?.scannedCount = update.scannedCount
                scanStates[source.id]?.currentFile = update.currentFile
                lastSongs = update.songs
            }

            completeScan(sourceID: source.id, songs: lastSongs)
        } catch {
            scanStates[source.id] = ScanState(
                isScanning: false,
                currentFile: error.localizedDescription
            )
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
                    synologyAPIs[source.id] = api
                }
            )
        case .smb:
            SMBBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .webdav:
            WebDAVBrowserView(source: source, selectedDirectories: selectedDirectories)
        case .jellyfin, .emby:
            MediaServerBrowserView(source: source, selectedDirectories: selectedDirectories)
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

    private func deleteSource(_ source: MusicSource) {
        library.removeSongsForSource(source.id)
        sourceStore.remove(id: source.id)
        synologyAPIs[source.id] = nil
        Task { await sourceManager.removeConnector(for: source.id) }
    }

    private func currentSource(for source: MusicSource) -> MusicSource {
        sourceStore.source(id: source.id) ?? source
    }

    private func updateSource(_ sourceID: String, mutate: (inout MusicSource) -> Void) {
        sourceStore.update(sourceID, mutate: mutate)
    }

    private func completeScan(sourceID: String, songs: [Song]) {
        library.addSongs(songs)
        updateSource(sourceID) {
            $0.songCount = songs.count
            $0.lastScannedAt = Date()
        }
        scanStates[sourceID]?.isScanning = false
        scanStates[sourceID]?.currentFile = "\(songs.count) \(String(localized: "songs_found"))"
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
