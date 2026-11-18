import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - 位置与模型

/// 文件页里的一层目录。
struct SourceFolderLocation: Hashable, Identifiable {
    /// 浏览路径:根是 "/",其余是连接器列目录给的条目路径(和扫描目录的存法一致)。
    let path: String
    let title: String
    /// 浏览到这一层经过的各级,外层在前,含根。按 ID 寻址的网盘只能靠它认上下级。
    let ancestors: [String]

    var id: String { path }
    var isRoot: Bool { ancestors.isEmpty }

    func child(path: String, title: String) -> SourceFolderLocation {
        SourceFolderLocation(path: path, title: title, ancestors: ancestors + [self.path])
    }

    static func root(for source: MusicSource) -> SourceFolderLocation {
        var path = "/"
        if source.type == .nfs,
           let exportPath = source.exportPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !exportPath.isEmpty {
            path = NFSSelectionPathCodec.makeSelectionPath(exportPath: exportPath, relativePath: "/")
        }
        return SourceFolderLocation(path: path, title: source.name, ancestors: [])
    }
}

/// 一个源的文件页共用:曲库里这个源的歌按路径建好的索引。进下一层不重建,
/// 改名、删除、扫完一次之后重建。
@MainActor
@Observable
final class SourceFilesModel {
    let sourceID: String
    private(set) var index = SourceFileBrowserPolicy.LibraryIndex()
    private(set) var songsByPath: [String: [Song]] = [:]
    /// 第一次建好之前不说哪首「还没入库」,免得一进来整页先闪一遍橙字。
    private(set) var isLoaded = false
    /// 每重建一次加一。
    private(set) var revision = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(sourceID: String) {
        self.sourceID = sourceID
    }

    func refresh(library: MusicLibrary, countsFolders: Bool) {
        refreshTask?.cancel()
        let songs = library.visibleSongs(forSourceID: sourceID)
        refreshTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) {
                (
                    index: SourceFileBrowserPolicy.LibraryIndex(
                        songPaths: songs.map(\.filePath),
                        countsFolders: countsFolders
                    ),
                    byPath: Dictionary(grouping: songs, by: \.filePath)
                )
            }.value
            guard !Task.isCancelled, let self else { return }
            self.index = built.index
            self.songsByPath = built.byPath
            self.isLoaded = true
            self.revision &+= 1
        }
    }

    func songs(atPath path: String) -> [Song] {
        songsByPath[path] ?? []
    }

    /// 这个目录里(含子目录)已入库的歌,按路径自然排序。
    func songs(underFolder path: String) -> [Song] {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let isRoot = path == "/" || path.isEmpty
        return songsByPath
            .filter { isRoot || $0.key.hasPrefix(prefix) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .flatMap(\.value)
    }
}

/// 一层目录在扫描范围里的位置。
enum SourceFolderScope: Equatable {
    /// 本机这类源整个都扫。
    case wholeSource
    case included
    /// 自己没被勾,下面有被勾的目录。
    case containsSelections
    case outside
    case noSelections

    var isScanned: Bool { self == .wholeSource || self == .included }

    static func resolve(path: String, ancestors: [String], source: MusicSource) -> SourceFolderScope {
        if source.type.scansEntireLibrary { return .wholeSource }
        let directories = source.scannedDirectories
        guard !directories.isEmpty else { return .noSelections }
        switch SourceDirectorySelectionPolicy.selectionState(
            of: path, in: directories, ancestors: ancestors, for: source.type
        ) {
        case .selected, .included:
            return .included
        case .unselected:
            let containsSelection = directories.contains {
                SourceDirectorySelectionPolicy.covers(path, $0, for: source.type)
            }
            return containsSelection ? .containsSelections : .outside
        }
    }
}

/// 文件页里点开的一个文件。
struct SourceFileSelection: Identifiable {
    let file: SourceFileBrowserPolicy.AudioFile
    let folder: SourceFolderLocation
    var id: String { file.entry.path }
}

// MARK: - 根页

struct SourceFilesRootPage: View {
    let source: MusicSource
    let actions: SourceDetailActions

    @State private var model: SourceFilesModel

    init(source: MusicSource, actions: SourceDetailActions) {
        self.source = source
        self.actions = actions
        _model = State(initialValue: SourceFilesModel(sourceID: source.id))
    }

    var body: some View {
        SourceFolderPage(
            source: source,
            location: .root(for: source),
            model: model,
            actions: actions
        )
    }
}

// MARK: - 一层目录

struct SourceFolderPage: View {
    let source: MusicSource
    let location: SourceFolderLocation
    let model: SourceFilesModel
    let actions: SourceDetailActions

    private enum Phase {
        case loading
        case loaded(SourceFileBrowserPolicy.Listing)
        case failed(String)
    }

    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ScanService.self) private var scanService
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(AudioPlayerService.self) private var player

    @State private var phase: Phase = .loading
    @State private var loadTask: Task<Void, Never>?
    @State private var hasAppeared = false
    @State private var openedFolder: SourceFolderLocation?
    @State private var openedFile: SourceFileSelection?
    @State private var sheet: SourceDetailSheet?
    @State private var showsMetadata = false
    @State private var showsLocalRemovals = false
    @State private var showsHiddenPlaylists = false
    @State private var toasts = PMToastPresenter()
    @State private var debugTargetsOpened = false
    /// 这个源能不能直接改名、删除目录(本机、WebDAV、SMB)。
    @State private var canMutateFolders = false
    @State private var folderAction: SourceFolderAction?

    private var current: MusicSource {
        sourcesStore.source(id: source.id) ?? source
    }

    /// 路径里带目录的源才按目录数入库数;按 ID 寻址的网盘与 UPnP 只能按文件对。
    private var countsFolders: Bool {
        current.type.itemPathsCarryFileNames
    }

    /// UPnP 列目录给的是容器里的条目,入库的歌存的是服务端资源地址,两边对不上,不标入库状态。
    private var tracksLibraryState: Bool {
        current.type != .upnp
    }

    var body: some View {
        let current = current
        let scope = SourceFolderScope.resolve(
            path: location.path, ancestors: location.ancestors, source: current
        )
        List {
            if location.isRoot {
                SourceFilesRootHeader(
                    source: current,
                    onDiagnose: { sheet = .diagnostics },
                    onScan: { actions.scan(current, .automatic) },
                    onOpenMetadata: { showsMetadata = true },
                    onLocalRemovals: { showsLocalRemovals = true },
                    onHiddenPlaylists: { showsHiddenPlaylists = true }
                )
            }
            Section {
                SourceFolderScopeBanner(
                    scope: scope,
                    songCount: countsFolders ? model.index.songCount(inFolder: location.path) : nil,
                    isRoot: location.isRoot,
                    canScanHere: ScanService.supportsFolderRescan(current) && current.isEnabled,
                    onScanHere: { scanHere(location) },
                    onManage: { sheet = .connection }
                )
            }
            listingSections(scope: scope)
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle(location.title)
        .toolbar { toolbarContent(scope: scope) }
        .refreshable { await reload() }
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            if location.isRoot { model.refresh(library: library, countsFolders: countsFolders) }
            load()
        }
        .onDisappear { loadTask?.cancel() }
        .onChange(of: scanService.scanningSourceIDs.contains(current.id)) { wasScanning, isScanning in
            // 扫完一次,入库状态变了:重建索引、重列这一层。
            guard wasScanning, !isScanning, location.isRoot else { return }
            model.refresh(library: library, countsFolders: countsFolders)
        }
        .navigationDestination(item: $openedFolder) { child in
            SourceFolderPage(source: current, location: child, model: model, actions: actions)
        }
        .navigationDestination(isPresented: $showsMetadata) { SourceMetadataStatusView(source: current) }
        .navigationDestination(isPresented: $showsLocalRemovals) { SourceLocalRemovalsView(source: current) }
        .sheet(isPresented: $showsHiddenPlaylists) { SourceHiddenPlaylistsView(source: current) }
        .sheet(item: $openedFile) { selection in
            SourceFileDetailSheet(
                source: current,
                file: selection.file,
                songs: model.songs(atPath: selection.file.entry.path),
                folderQueue: folderQueue(),
                isInScanScope: scope.isScanned,
                onChanged: { fileDidChange() },
                onDeleted: { name in
                    fileDidChange()
                    toasts.show(PMToastItem(
                        key: "source-files-deleted",
                        message: String(format: String(localized: "source_file_deleted_format"), name),
                        systemImage: "trash",
                        tint: .secondary
                    ))
                },
                onScanFolder: { scanHere(selection.folder) }
            )
        }
        .sourceDetailSheets(source: current, actions: actions, presented: $sheet)
        .sourceFolderActions(source: current, action: $folderAction) { message in
            fileDidChange()
            toasts.show(PMToastItem(
                key: "source-files-folder",
                message: message,
                systemImage: "checkmark.circle.fill",
                tint: .green
            ))
        }
        .task(id: current.id) {
            canMutateFolders = await sourceManager.connector(for: current).canMutateDirectories()
        }
        .pmToastHost(toasts)
    }

    // MARK: 列表

    @ViewBuilder
    private func listingSections(scope: SourceFolderScope) -> some View {
        switch phase {
        case .loading:
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 24)
            }
        case .failed(let message):
            Section {
                SourceFolderLoadFailure(
                    message: message,
                    onRetry: { load() },
                    onDiagnose: { sheet = .diagnostics }
                )
            }
        case .loaded(let listing):
            if listing.folders.isEmpty && listing.audioFiles.isEmpty {
                Section {
                    Text(listing.otherFileCount > 0
                         ? String(format: String(localized: "source_files_other_files_format"), listing.otherFileCount)
                         : String(localized: "source_files_empty"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                }
            } else {
                if !listing.folders.isEmpty {
                    Section {
                        ForEach(listing.folders, id: \.path) { folder in
                            folderRow(folder)
                        }
                    }
                }
                if !listing.audioFiles.isEmpty {
                    Section {
                        ForEach(listing.audioFiles, id: \.entry.path) { file in
                            fileRow(file, scope: scope)
                        }
                    } footer: {
                        if listing.otherFileCount > 0 {
                            Text(String(format: String(localized: "source_files_other_files_format"), listing.otherFileCount))
                        }
                    }
                } else if listing.otherFileCount > 0 {
                    Section {
                    } footer: {
                        Text(String(format: String(localized: "source_files_other_files_format"), listing.otherFileCount))
                    }
                }
            }
        }
    }

    private func folderRow(_ folder: SourceFileBrowserPolicy.Entry) -> some View {
        let child = location.child(path: folder.path, title: folder.name)
        let childScope = SourceFolderScope.resolve(path: child.path, ancestors: child.ancestors, source: current)
        let count = countsFolders ? model.index.songCount(inFolder: folder.path) : nil
        return Button {
            openedFolder = child
        } label: {
            SourceFolderRow(
                name: folder.name,
                songCount: count,
                scope: childScope,
                showsOutside: countsFolders
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if childScope.isScanned, ScanService.supportsFolderRescan(current) {
                Button { scanHere(child) } label: {
                    Label("source_files_scan_here", systemImage: "arrow.clockwise")
                }
            }
            if let count, count > 0 {
                Button { playFolder(child.path) } label: {
                    Label("source_files_play_folder", systemImage: "play")
                }
            }
            if current.type.itemPathsCarryFileNames {
                Button { copyPath(folder.path) } label: {
                    Label("source_files_copy_path", systemImage: "doc.on.doc")
                }
            }
            if canMutateFolders {
                Section {
                    Button { folderAction = .rename(child) } label: {
                        Label("playlist_rename", systemImage: "character.cursor.ibeam")
                    }
                }
                Section {
                    Button(role: .destructive) { folderAction = .delete(child) } label: {
                        Label("source_folder_delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func fileRow(_ file: SourceFileBrowserPolicy.AudioFile, scope: SourceFolderScope) -> some View {
        let songs = model.songs(atPath: file.entry.path)
        return Button {
            openedFile = SourceFileSelection(file: file, folder: location)
        } label: {
            SourceAudioFileRow(
                file: file,
                songs: songs,
                showsNotInLibrary: tracksLibraryState && scope.isScanned && songs.isEmpty && model.isLoaded
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let song = songs.first {
                Button { play(song) } label: { Label("play", systemImage: "play") }
            }
            if current.type.itemPathsCarryFileNames {
                Button { copyPath(file.entry.path) } label: {
                    Label("source_files_copy_path", systemImage: "doc.on.doc")
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbarContent(scope: SourceFolderScope) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            SourceStorageCapsule(sourceID: current.id, isSheetClosed: sheet == nil) { sheet = .storage }
            Menu {
                Section {
                    Button { actions.scan(current, .automatic) } label: {
                        Label("source_files_scan_source", systemImage: "waveform.badge.magnifyingglass")
                    }
                    if !location.isRoot, scope.isScanned, ScanService.supportsFolderRescan(current) {
                        Button { scanHere(location) } label: {
                            Label("source_files_scan_here", systemImage: "arrow.clockwise")
                        }
                    }
                    Button { actions.scan(current, .deep) } label: {
                        Label("source_deep_scan", systemImage: "arrow.triangle.2.circlepath.circle")
                    }
                }
                Section {
                    if !current.type.scansEntireLibrary {
                        Button { sheet = .connection } label: {
                            Label("manage_dirs", systemImage: "folder.badge.gear")
                        }
                    }
                    Button { sheet = .diagnostics } label: {
                        Label("source_diagnostics", systemImage: "stethoscope")
                    }
                    Button { sheet = .edit } label: {
                        Label("edit", systemImage: "pencil")
                    }
                }
            } label: {
                Label("more", systemImage: "ellipsis.circle")
            }
        }
    }

    // MARK: 动作

    private func load() {
        loadTask?.cancel()
        let source = current
        let path = SourceDirectorySelectionPolicy.connectorPath(for: source.type, browserPath: location.path)
        loadTask = Task { @MainActor in
            do {
                let items = try await DirectoryBrowserNetworkRetry.loadWithLocalNetworkAuthorizationGrace {
                    // 网盘刚重新授权时要等新的账号身份落定,和选目录页用同一个入口。
                    let connector = await sourceManager.connectorForDirectoryBrowsing(fallback: source).connector
                    try await connector.connect()
                    return try await connector.listFiles(at: path)
                }
                guard !Task.isCancelled else { return }
                if source.type.isCloudDrive {
                    CloudDirectoryNameStore.save(items, for: source.id)
                }
                let entries = items.map {
                    SourceFileBrowserPolicy.Entry(
                        name: $0.name, path: $0.path, isDirectory: $0.isDirectory,
                        size: $0.size, modifiedDate: $0.modifiedDate
                    )
                }
                let listing = SourceFileBrowserPolicy.listing(of: entries)
                phase = .loaded(listing)
                #if DEBUG
                openDebugTargetsIfRequested(listing)
                #endif
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    #if DEBUG
    /// 调试构建的无人值守截图:`PRIMUSE_DEBUG_SOURCE_FOLDER=<名字>` 在根页点进这个子目录,
    /// `PRIMUSE_DEBUG_SOURCE_FILE=<名字片段>` 打开第一个名字里带它的文件,
    /// `PRIMUSE_DEBUG_SOURCE_SHEET=storage` 在根页打开本机占用页。
    private func openDebugTargetsIfRequested(_ listing: SourceFileBrowserPolicy.Listing) {
        guard !debugTargetsOpened else { return }
        debugTargetsOpened = true
        let env = ProcessInfo.processInfo.environment
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if location.isRoot, env["PRIMUSE_DEBUG_SOURCE_SHEET"] == "storage" {
                sheet = .storage
                return
            }
            if location.isRoot, await runDebugFolderOperationIfRequested(listing, env: env) {
                return
            }
            if location.isRoot, let name = env["PRIMUSE_DEBUG_SOURCE_FOLDER"],
               let folder = listing.folders.first(where: { $0.name == name }) {
                openedFolder = location.child(path: folder.path, title: folder.name)
                return
            }
            if let fragment = env["PRIMUSE_DEBUG_SOURCE_FILE"], !fragment.isEmpty,
               let file = listing.audioFiles.first(where: { $0.entry.name.contains(fragment) }) {
                openedFile = SourceFileSelection(file: file, folder: location)
            }
        }
    }

    /// `PRIMUSE_DEBUG_FOLDER_RENAME=<旧名>:<新名>`、`PRIMUSE_DEBUG_FOLDER_DELETE=<名字>`:在根页直接改名或删除
    /// 这个子目录,把前后的歌曲 ID 与路径写进日志,核对改名不换 ID、删除确实移出曲库。
    private func runDebugFolderOperationIfRequested(
        _ listing: SourceFileBrowserPolicy.Listing,
        env: [String: String]
    ) async -> Bool {
        let operations = SourceFolderOperations(
            sourceManager: sourceManager, scanService: scanService, library: library,
            sourcesStore: sourcesStore, player: player
        )
        let source = current
        func songs(under path: String) -> [Song] {
            library.songs.filter {
                $0.sourceID == source.id
                    && SourceFolderRelocationPolicy.relocatedPath($0.filePath, from: path, to: path) != nil
            }
        }
        if let spec = env["PRIMUSE_DEBUG_FOLDER_RENAME"], let colon = spec.firstIndex(of: ":"),
           let folder = listing.folders.first(where: { $0.name == String(spec[..<colon]) }) {
            let before = songs(under: folder.path).map(\.id).sorted()
            do {
                let newPath = try await operations.rename(
                    folder: folder.path, in: source, to: String(spec[spec.index(after: colon)...])
                )
                let after = songs(under: newPath)
                plog("🧪 debug folder rename ok ids-kept=\(after.map(\.id).sorted() == before) count=\(after.count) paths=\(after.map(\.filePath).sorted())")
            } catch {
                plog("🧪 debug folder rename failed: \(error.localizedDescription)")
            }
            fileDidChange()
            return true
        }
        if let name = env["PRIMUSE_DEBUG_FOLDER_DELETE"],
           let folder = listing.folders.first(where: { $0.name == name }) {
            let impact = operations.deletionImpact(folder: folder.path, in: source)
            do {
                let removed = try await operations.delete(folder: folder.path, in: source)
                plog("🧪 debug folder delete ok removed=\(removed) impact=\(impact) left=\(songs(under: folder.path).count) total=\(library.songs.filter { $0.sourceID == source.id }.count)")
            } catch {
                plog("🧪 debug folder delete failed: \(error.localizedDescription)")
            }
            fileDidChange()
            return true
        }
        return false
    }
    #endif

    private func reload() async {
        model.refresh(library: library, countsFolders: countsFolders)
        load()
        await loadTask?.value
    }

    private func fileDidChange() {
        model.refresh(library: library, countsFolders: countsFolders)
        load()
    }

    private func scanHere(_ target: SourceFolderLocation) {
        let source = current
        guard !target.isRoot, ScanService.supportsFolderRescan(source) else {
            actions.scan(source, .automatic)
            return
        }
        guard !scanService.scanningSourceIDs.contains(source.id) else {
            toasts.show(PMToastItem(
                key: "source-files-scan",
                message: String(localized: "source_files_scan_busy"),
                systemImage: "hourglass",
                tint: .secondary
            ))
            return
        }
        let started = scanService.rescanFolder(
            of: source,
            request: SourceFolderRescanRequest(directoryCandidates: [target.path] + target.ancestors.reversed()),
            sourceManager: sourceManager,
            library: library,
            sourceStore: sourcesStore,
            scraperService: scraperService
        )
        toasts.show(PMToastItem(
            key: "source-files-scan",
            message: started
                ? String(format: String(localized: "source_files_scan_started_format"), target.title)
                : String(localized: "source_files_scan_busy"),
            systemImage: started ? "arrow.clockwise" : "hourglass",
            tint: .secondary
        ))
    }

    /// 这一层里已入库的歌,照列表的顺序。
    private func folderQueue() -> [Song] {
        guard case .loaded(let listing) = phase else { return [] }
        return listing.audioFiles.flatMap { model.songs(atPath: $0.entry.path) }
    }

    private func play(_ song: Song) {
        let queue = folderQueue()
        let start = queue.firstIndex { $0.id == song.id } ?? 0
        Task { await player.play(queue: queue.isEmpty ? [song] : queue, startingAt: start) }
    }

    private func playFolder(_ path: String) {
        let queue = model.songs(underFolder: path)
        guard !queue.isEmpty else { return }
        Task { await player.play(queue: queue, startingAt: 0) }
    }

    private func copyPath(_ path: String) {
        #if os(iOS)
        UIPasteboard.general.string = path
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        #endif
        toasts.show(PMToastItem(
            key: "source-files-copy",
            message: String(localized: "source_files_path_copied"),
            systemImage: "doc.on.doc",
            tint: .secondary
        ))
    }
}

// MARK: - 根页顶上

private struct SourceFilesRootHeader: View {
    let source: MusicSource
    let onDiagnose: () -> Void
    let onScan: () -> Void
    let onOpenMetadata: () -> Void
    let onLocalRemovals: () -> Void
    let onHiddenPlaylists: () -> Void

    var body: some View {
        Section {
            SourceDetailHeader(source: source)
            SourceStatusBanners(
                source: source,
                onDiagnose: onDiagnose,
                onScan: onScan,
                onOpenMetadata: onOpenMetadata
            )
            SourceDeviceRows(
                source: source,
                onLocalRemovals: onLocalRemovals,
                onHiddenPlaylists: onHiddenPlaylists
            )
        }
        .listRowSeparator(.hidden)
    }
}

// MARK: - 行

/// 这一层在不在扫描范围里,在的话可以只扫这一层。
private struct SourceFolderScopeBanner: View {
    let scope: SourceFolderScope
    let songCount: Int?
    let isRoot: Bool
    let canScanHere: Bool
    let onScanHere: () -> Void
    let onManage: () -> Void

    private var scanTitle: LocalizedStringKey {
        isRoot ? "scan" : "source_files_scan_here"
    }

    private var manageTitle: LocalizedStringKey {
        scope == .noSelections ? "source_files_choose_directories" : "manage_dirs"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if scope.isScanned, let songCount {
                    Text(String(format: String(localized: "source_files_folder_count_format"), songCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if scope.isScanned {
                if canScanHere || isRoot {
                    Button(scanTitle, action: onScanHere)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            } else {
                Button(manageTitle, action: onManage)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
    }

    private var title: String {
        switch scope {
        case .wholeSource, .included:
            return String(localized: "source_files_scope_included")
        case .containsSelections:
            return String(localized: "source_files_scope_partial")
        case .outside:
            return String(localized: "source_files_scope_outside")
        case .noSelections:
            return String(localized: "source_files_scope_none")
        }
    }

    private var iconName: String {
        switch scope {
        case .wholeSource, .included: "checkmark.circle.fill"
        case .containsSelections: "circle.lefthalf.filled"
        case .outside, .noSelections: "circle.dashed"
        }
    }

    private var tint: Color {
        scope.isScanned ? .green : .secondary
    }
}

private struct SourceFolderRow: View {
    let name: String
    let songCount: Int?
    let scope: SourceFolderScope
    /// 按 ID 寻址的源认不出子目录在不在范围里,不写「不扫描」。
    let showsOutside: Bool

    var body: some View {
        HStack(spacing: 12) {
            DirectoryFolderTile(
                icon: "folder.fill",
                tint: scope.isScanned || scope == .containsSelections ? .blue : .gray
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String? {
        if let songCount, songCount > 0 {
            return String(format: String(localized: "source_files_folder_count_format"), songCount)
        }
        if scope == .outside, showsOutside {
            return String(localized: "source_files_folder_outside")
        }
        return nil
    }
}

private struct SourceAudioFileRow: View {
    let file: SourceFileBrowserPolicy.AudioFile
    let songs: [Song]
    let showsNotInLibrary: Bool

    @Environment(SourceManager.self) private var sourceManager

    var body: some View {
        HStack(spacing: 12) {
            SourceFormatTile(file: file)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.entry.name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if showsNotInLibrary {
                        Text("source_files_not_in_library")
                            .foregroundStyle(.orange)
                    } else if let detail {
                        Text(detail)
                            .foregroundStyle(.secondary)
                    }
                    if let lyrics = file.lyrics.first {
                        Text((lyrics.name as NSString).pathExtension.uppercased())
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                .font(.caption)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let song = songs.first, song.sourceID != AppleMusicLibraryService.systemSourceID {
                OfflineAudioStatusBadge(snapshot: sourceManager.offlineAudioSnapshotEntry(for: song).snapshot)
            }
        }
        .contentShape(Rectangle())
    }

    private var detail: String? {
        var parts: [String] = []
        if songs.count > 1 {
            parts.append(String(format: String(localized: "source_files_cue_songs_format"), songs.count))
        } else if let song = songs.first {
            if let quality = SourceFileQualityText.make(for: song) { parts.append(quality) }
        }
        if file.entry.size > 0 {
            parts.append(SourceByteText.string(file.entry.size))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 文件行开头的格式小方块:无损偏青、有损偏灰。
struct SourceFormatTile: View {
    let file: SourceFileBrowserPolicy.AudioFile
    var size: CGFloat = 36

    var body: some View {
        let isLossless = file.format?.isLossless == true
        let tint: Color = isLossless ? .teal : .indigo
        Text((file.entry.name as NSString).pathExtension.uppercased())
            .font(.system(size: size * 0.26, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
            .accessibilityHidden(true)
    }
}

enum SourceFileQualityText {
    /// 「24bit/96kHz」;只知道一半时只写那一半。
    static func make(for song: Song) -> String? {
        let depth = song.effectiveBitDepth.map { "\($0)bit" }
        let rate = song.sampleRate.map { rate -> String in
            let khz = Double(rate) / 1000
            return khz.rounded() == khz ? "\(Int(khz))kHz" : String(format: "%.1fkHz", khz)
        }
        let parts = [depth, rate].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
}

private struct SourceFolderLoadFailure: View {
    let message: String
    let onRetry: () -> Void
    let onDiagnose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("source_files_load_failed", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button("retry", action: onRetry)
                Button("source_diagnostics", action: onDiagnose)
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
