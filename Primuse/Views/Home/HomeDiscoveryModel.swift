import SwiftUI
import PrimuseKit

enum HomeDiscoveryText {
    static func string(_ key: String) -> String {
        NSLocalizedString(key, tableName: "HomeDiscovery", bundle: .main, comment: "")
    }

    static func folderTitle(_ node: LibraryFolderNode) -> String {
        if let name = node.displayName, !name.isEmpty { return name }
        let key: String
        switch node.kind {
        case .source: key = "source_label"
        case .scanRoot, .folder: key = "library_folder_scan_root"
        case .librarySongs: key = "library_folder_apple_music_library_songs"
        case .playlist: key = "library_folder_apple_music_unnamed_playlist"
        case .notInPlaylist: key = "library_folder_apple_music_not_in_playlist"
        case .uncategorized: key = "library_folder_uncategorized"
        case .other: key = "library_folder_other"
        }
        return NSLocalizedString(key, comment: "")
    }
}

/// 首页文件夹区上一次画出来的几张卡片。
///
/// 文件夹索引每次冷启动都要把整库过一遍才建得出来，这期间首页只能放占位，建好后
/// 卡片把下面的区块整体顶开，滚动中看到的就是一跳。存下来的只是已显示的那几张卡片
/// 的外观（标题、数量、封面用哪几首），冷启动先照它画，索引建好后换成真实节点，
/// 尺寸不变。显示条件（置顶了哪些、显示几张）变了就不用它。
struct HomeFolderPreview: Codable, Sendable, Equatable {
    static let currentVersion = 1

    struct Node: Codable, Sendable, Equatable {
        let sourceID: String
        let kind: String
        let path: String
        let parentKind: String?
        let parentPath: String?
        let displayName: String?
        let directSongCount: Int
        let descendantSongCount: Int
        let childNodeCount: Int
        let displayedChildCount: Int
        let sourceDisplayName: String?
        let coverSongIDs: [String]

        var id: LibraryFolderNodeID? {
            LibraryFolderNodeKind(rawValue: kind).map {
                LibraryFolderNodeID(sourceID: sourceID, kind: $0, normalizedRelativePath: path)
            }
        }

        var node: LibraryFolderNode? {
            guard let id else { return nil }
            let parentID = parentKind.flatMap(LibraryFolderNodeKind.init(rawValue:)).map {
                LibraryFolderNodeID(sourceID: sourceID, kind: $0, normalizedRelativePath: parentPath ?? "")
            }
            return LibraryFolderNode(
                id: id, parentID: parentID, sourceID: sourceID, kind: id.kind,
                displayName: displayName, directSongCount: directSongCount,
                descendantSongCount: descendantSongCount, childNodeCount: childNodeCount
            )
        }
    }

    let version: Int
    let pinsRawValue: String
    let displayCount: Int
    let nodes: [Node]

    func matches(pinsRawValue: String, displayCount: Int) -> Bool {
        version == Self.currentVersion
            && self.pinsRawValue == pinsRawValue
            && self.displayCount == displayCount
    }
}

private actor HomeFolderPreviewStore {
    static let shared = HomeFolderPreviewStore()

    private let url = FileManager.default
        .primuseDirectoryURL(for: .cachesDirectory)
        .appendingPathComponent("Primuse", isDirectory: true)
        .appendingPathComponent("home-folder-preview.plist")

    func load() -> HomeFolderPreview? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(HomeFolderPreview.self, from: data)
    }

    func save(_ preview: HomeFolderPreview) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(preview).write(to: url, options: .atomic)
        } catch {
            plog("⚠️ Home folder preview write failed: \(error.localizedDescription)")
        }
    }
}

@MainActor
@Observable
final class HomeDiscoveryModel {
    struct Request: Equatable {
        let collection: Int
        let playlists: Int
        let hierarchy: Int
        let names: Int
        let sources: [LibraryFolderSourceDescriptor]
    }

    private struct HistorySignature: Equatable {
        let revision: Int
        let day: Date
        let calendar: Calendar
        let localeIdentifier: String
    }

    private(set) var index: LibraryFolderIndex?
    /// 首页文件夹卡片要重画：索引换了、封面换了、最近播放时间变了。
    private(set) var revision = 0
    /// 只在播放记录真的变了时加一。排行只关心这个，不该跟着元数据回填一首首重算。
    private(set) var historyRevision = 0
    /// 冷启动时索引建好之前，首页文件夹区照它画。
    private(set) var homePreview: HomeFolderPreview?
    @ObservationIgnored private var homePreviewLoadStarted = false
    @ObservationIgnored private var savedHomePreview: HomeFolderPreview?
    @ObservationIgnored private var previewSourceNames: [String: String] = [:]
    @ObservationIgnored private var previewChildCounts: [LibraryFolderNodeID: Int] = [:]
    /// 当前被某个文件夹拿来当封面的歌。回填改到它们才需要重画卡片。
    @ObservationIgnored private var coverSongIDSet: Set<String> = []
    @ObservationIgnored private var publishedHistorySignature: HistorySignature?
    var nameRevision = 0
    @ObservationIgnored private(set) var songsByID: [String: Song] = [:]
    @ObservationIgnored private(set) var folderCoverSongIDs: [LibraryFolderNodeID: [String]] = [:]
    @ObservationIgnored private(set) var lastPlayedByFolder: [LibraryFolderNodeID: Date] = [:]
    @ObservationIgnored private var preparedRequest: Request?
    @ObservationIgnored var handledMetadataToken: UUID?
    @ObservationIgnored private var preparedDirectoryNames: [String: [String: String]] = [:]
    @ObservationIgnored private var historySignature: HistorySignature?

    func needsRebuild(
        for request: Request,
        metadataToken: UUID,
        directoryNames: [String: [String: String]]
    ) -> Bool {
        index == nil || preparedRequest != request
            || handledMetadataToken != metadataToken
            || preparedDirectoryNames != directoryNames
    }

    func publish(
        index: LibraryFolderIndex,
        songs: [String: Song],
        covers: [LibraryFolderNodeID: [String]],
        request: Request,
        metadataToken: UUID,
        directoryNames: [String: [String: String]]
    ) {
        self.songsByID = songs
        self.folderCoverSongIDs = covers
        self.coverSongIDSet = Set(covers.values.joined())
        self.index = index
        homePreview = nil
        previewSourceNames = [:]
        previewChildCounts = [:]
        preparedRequest = request
        handledMetadataToken = metadataToken
        preparedDirectoryNames = directoryNames
        historySignature = nil
        refreshHistory()
    }

    func refreshHistory() {
        let calendar = ListeningCalendar.current
        let signature = HistorySignature(
            revision: PlayHistoryStore.shared.revision,
            day: calendar.startOfDay(for: Date()),
            calendar: calendar,
            localeIdentifier: Locale.current.identifier
        )
        guard historySignature != signature else { return }
        var dates: [LibraryFolderNodeID: Date] = [:]
        for entry in PlayHistoryStore.shared.entries {
            var nodeID = index?.nodeID(containingSongID: entry.songID)
            while let id = nodeID {
                dates[id] = max(dates[id] ?? .distantPast, entry.playedAt)
                nodeID = index?.node(withID: id)?.parentID
            }
        }
        lastPlayedByFolder = dates
        historySignature = signature
        revision &+= 1
        // 重新发布索引会把 historySignature 清掉再算一遍，那一次播放记录没变。
        if publishedHistorySignature != signature {
            publishedHistorySignature = signature
            historyRevision &+= 1
        }
    }

    func updateMetadata(song: Song) {
        let previousCover = songsByID[song.id]?.coverArtFileName
        songsByID[song.id] = song
        var coversChanged = false
        if song.coverArtFileName != nil {
            var nodeID = index?.nodeID(containingSongID: song.id)
            while let id = nodeID {
                if (folderCoverSongIDs[id]?.count ?? 0) < 4,
                   !(folderCoverSongIDs[id]?.contains(song.id) ?? false) {
                    folderCoverSongIDs[id, default: []].append(song.id)
                    coverSongIDSet.insert(song.id)
                    coversChanged = true
                }
                nodeID = index?.node(withID: id)?.parentID
            }
        }
        // 卡片上只有封面取自歌曲本身；启动时回填一首首改标签，别的字段变了不值得
        // 让首页所有文件夹卡片重画。文件夹页的歌曲列表直接读资料库，不靠这个计数。
        if coversChanged
            || (coverSongIDSet.contains(song.id) && previousCover != song.coverArtFileName) {
            revision &+= 1
        }
    }

    /// 首页文件夹区此刻该画的节点。索引还没建好时用上次存下的样子；两者都没有
    /// 时返回 nil，由调用方画同尺寸的占位。
    func homeNodes(pinsRawValue: String, displayCount: Int) -> [LibraryFolderNode]? {
        if let index {
            return Array(
                pins(from: pinsRawValue)
                    .compactMap { index.node(withID: $0) }
                    .prefix(HomeFolderPinStorage.displayCount(displayCount))
            )
        }
        guard let homePreview,
              homePreview.matches(pinsRawValue: pinsRawValue, displayCount: displayCount) else { return nil }
        return homePreview.nodes.compactMap(\.node)
    }

    /// 索引建好前占位要摆几张。用户自己置顶过就按置顶数，否则按设置的显示张数。
    func homePlaceholderCount(pinsRawValue: String, displayCount: Int) -> Int {
        let limit = HomeFolderPinStorage.displayCount(displayCount)
        guard !pinsRawValue.isEmpty else { return limit }
        return min(limit, HomeFolderPinStorage.decode(pinsRawValue).count)
    }

    func sourceDisplayName(for sourceID: String) -> String? {
        index?.sourceNode(for: sourceID)?.displayName ?? previewSourceNames[sourceID]
    }

    func previewDisplayedChildCount(for id: LibraryFolderNodeID) -> Int? {
        index == nil ? previewChildCounts[id] : nil
    }

    /// 冷启动时读回上次的首页文件夹卡片，封面用的歌从资料库里现取，已经不在库里
    /// 的就不画。只在索引还没建好时用。
    func loadHomePreviewIfNeeded(songForID: (String) -> Song?) async {
        guard index == nil, !homePreviewLoadStarted else { return }
        homePreviewLoadStarted = true
        guard let preview = await HomeFolderPreviewStore.shared.load(),
              preview.version == HomeFolderPreview.currentVersion,
              index == nil else { return }
        savedHomePreview = preview
        for entry in preview.nodes {
            guard let id = entry.id else { continue }
            let covers = entry.coverSongIDs.filter { songID in
                guard let song = songForID(songID) else { return false }
                songsByID[songID] = song
                return true
            }
            folderCoverSongIDs[id] = covers
            previewChildCounts[id] = entry.displayedChildCount
            if let name = entry.sourceDisplayName { previewSourceNames[entry.sourceID] = name }
        }
        homePreview = preview
    }

    /// 把首页此刻显示的文件夹卡片存下来，下次冷启动先照它画。
    func persistHomePreview(pinsRawValue: String, displayCount: Int) {
        guard let index, let nodes = homeNodes(pinsRawValue: pinsRawValue, displayCount: displayCount) else { return }
        let preview = HomeFolderPreview(
            version: HomeFolderPreview.currentVersion,
            pinsRawValue: pinsRawValue,
            displayCount: displayCount,
            nodes: nodes.map { node in
                HomeFolderPreview.Node(
                    sourceID: node.sourceID,
                    kind: node.id.kind.rawValue,
                    path: node.id.normalizedRelativePath,
                    parentKind: node.parentID?.kind.rawValue,
                    parentPath: node.parentID?.normalizedRelativePath,
                    displayName: node.displayName,
                    directSongCount: node.directSongCount,
                    descendantSongCount: node.descendantSongCount,
                    childNodeCount: node.childNodeCount,
                    displayedChildCount: node.kind == .source
                        ? LibraryFolderBrowsePolicy.displayedChildren(in: index, of: node.id).count
                        : node.childNodeCount,
                    sourceDisplayName: index.sourceNode(for: node.sourceID)?.displayName,
                    coverSongIDs: folderCoverSongIDs[node.id] ?? []
                )
            }
        )
        guard preview != savedHomePreview else { return }
        savedHomePreview = preview
        Task(priority: .utility) {
            await HomeFolderPreviewStore.shared.save(preview)
        }
    }

    func pins(from rawValue: String) -> [LibraryFolderNodeID] {
        let count = UserDefaults.standard.object(forKey: HomeFolderPinStorage.displayCountKey) as? Int
            ?? HomeFolderPinStorage.defaultDisplayCount
        return HomeFolderPinStorage.resolvedPins(rawValue, index: index, defaultCount: count)
    }

    func songs(in id: LibraryFolderNodeID, scope: LibraryFolderSongScope = .descendants) -> [Song] {
        LibraryFolderBrowsePolicy.sortedSongs(
            (index?.songIDs(in: id, scope: scope) ?? []).compactMap { songsByID[$0] }
        )
    }
}

/// Observe scan revisions outside HomeView so background metadata updates do
/// not invalidate the entire dashboard. A cancelled build never publishes.
struct HomeDiscoveryObserver: View {
    let model: HomeDiscoveryModel
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(ScanService.self) private var scanService
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingMetadataIDs: Set<String> = []
    @State private var isObserverVisible = false

    private struct RefreshRequest: Equatable {
        let content: HomeDiscoveryModel.Request
        let isActive: Bool
    }

    private struct ProviderInput: Sendable {
        let items: [String: SourceSyncIndexedItem]
        let rootNames: [String: String]
        let indexedRoots: Bool
    }

    private var request: HomeDiscoveryModel.Request {
        HomeDiscoveryModel.Request(
            collection: library.visibleSongCollectionRevision,
            playlists: library.playlistCollectionRevision,
            hierarchy: scanService.folderHierarchyRevision,
            names: model.nameRevision,
            sources: sourcesStore.allSources.map(LibraryFolderSourceDescriptor.init(source:))
        )
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: RefreshRequest(content: request, isActive: scenePhase == .active)) {
                isObserverVisible = true
                guard scenePhase == .active else { return }
                await rebuild()
            }
            .onChange(of: library.songReplacementToken) { _, _ in
                guard isObserverVisible, scenePhase == .active else { return }
                let sources = Dictionary(sourcesStore.allSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                var structureChanged = false
                for id in library.lastReplacedSongIDs {
                    pendingMetadataIDs.insert(id)
                    guard let song = library.unobservedVisibleSong(id: id) else { continue }
                    if let source = sources[song.sourceID],
                       !source.type.isCloudDrive, !source.type.isServerLibrary,
                       source.type != .upnp, song.sourceID != AppleMusicLibraryIdentity.sourceID,
                       LibraryFolderSourceDescriptor(source: source).placementNodeID(for: song)
                        != model.index?.nodeID(containingSongID: id) {
                        structureChanged = true
                    }
                    model.updateMetadata(song: song)
                }
                model.handledMetadataToken = library.songReplacementToken
                if structureChanged { model.nameRevision &+= 1 }
            }
            .onReceive(NotificationCenter.default.publisher(for: .primuseListeningStatsDidChange)) { _ in
                model.refreshHistory()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                model.refreshHistory()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                model.refreshHistory()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                model.refreshHistory()
            }
            .onReceive(NotificationCenter.default.publisher(for: CloudDirectoryNameStore.didChangeNotification)) { _ in
                model.nameRevision &+= 1
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refreshHistory() }
            }
            .onDisappear { isObserverVisible = false }
    }

    private func rebuild() async {
        await model.loadHomePreviewIfNeeded(songForID: { library.unobservedVisibleSong(id: $0) })
        guard !Task.isCancelled else { return }
        let request = request
        let directoryNames = Dictionary(
            sourcesStore.allSources.filter { $0.type.isCloudDrive }.map {
                ($0.id, CloudDirectoryNameStore.displayNames(for: $0.id))
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard model.needsRebuild(
            for: request,
            metadataToken: library.songReplacementToken,
            directoryNames: directoryNames
        ) else {
            model.refreshHistory()
            return
        }
        if model.index != nil {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        let metadataToken = library.songReplacementToken
        pendingMetadataIDs.removeAll()
        let songs = library.visibleSongs
        let collections = library.appleMusicFolderCollections(availableSongs: songs)
        var descriptors = request.sources
        var known = Set(descriptors.map(\.sourceID))
        for song in songs where known.insert(song.sourceID).inserted {
            descriptors.append(LibraryFolderSourceDescriptor(
                sourceID: song.sourceID,
                displayName: song.sourceID == AppleMusicLibraryIdentity.sourceID
                    ? String(localized: "apple_music_library_section") : String(localized: "source_label"),
                scanRoots: [], pathSemantics: .opaque
            ))
        }
        var providers: [String: ProviderInput] = [:]
        for source in sourcesStore.allSources {
            guard source.type.isCloudDrive || source.type.isServerLibrary || source.type == .upnp else { continue }
            providers[source.id] = ProviderInput(
                items: scanService.libraryFolderSyncIndex(for: source.id),
                rootNames: directoryNames[source.id] ?? [:],
                indexedRoots: source.type.isServerLibrary || source.type == .upnp
            )
        }
        let task = Task.detached(priority: .utility) { [descriptors, providers] in
            let resolved = descriptors.map { descriptor in
                guard let provider = providers[descriptor.sourceID], !provider.items.isEmpty else { return descriptor }
                let indexedRoots = provider.items.values.filter { $0.isDirectory && $0.parentPath == nil }
                    .sorted { $0.path < $1.path }
                let rootPaths = provider.indexedRoots && !indexedRoots.isEmpty
                    ? indexedRoots.map(\.path) : descriptor.scanRoots
                let roots = rootPaths.map { path in
                    let indexedName = indexedRoots.first { $0.path == path }?.displayName
                    let pathName = descriptor.pathSemantics == .hierarchical && path != "/"
                        ? (path as NSString).lastPathComponent : nil
                    return LibraryFolderProviderRootDescriptor(
                        path: path, displayName: indexedName ?? provider.rootNames[path] ?? pathName
                    )
                }
                return descriptor.withProviderHierarchy(LibraryFolderProviderHierarchy(
                    roots: roots,
                    items: provider.items.values.map {
                        LibraryFolderProviderItemDescriptor(
                            path: $0.path, displayName: $0.displayName,
                            parentPath: $0.parentPath, isDirectory: $0.isDirectory
                        )
                    }
                ))
            }
            let index = LibraryFolderIndexBuilder.build(sources: resolved, songs: songs, virtualCollections: collections)
            let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var covers: [LibraryFolderNodeID: [String]] = [:]
            for song in songs where song.coverArtFileName != nil {
                if Task.isCancelled { break }
                var id = index.nodeID(containingSongID: song.id)
                while let current = id {
                    if (covers[current]?.count ?? 0) < 4 { covers[current, default: []].append(song.id) }
                    id = index.node(withID: current)?.parentID
                }
            }
            return (index, songsByID, covers)
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, self.request == request else { return }
        let patchedMetadataToken = pendingMetadataIDs.isEmpty ? metadataToken : model.handledMetadataToken
        model.publish(
            index: result.0, songs: result.1, covers: result.2,
            request: request, metadataToken: metadataToken, directoryNames: directoryNames
        )
        for id in pendingMetadataIDs {
            if let song = library.unobservedVisibleSong(id: id) { model.updateMetadata(song: song) }
        }
        model.handledMetadataToken = patchedMetadataToken
        pendingMetadataIDs.removeAll()
    }
}
