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

/// 首页的整库目录索引存哪儿。曲库里没有有声书、环境音时，首页、歌曲页、车机照的是同一份歌、
/// 同一套规则，存进 `LibraryFolderIndexReuseCache` 共用一份；有的话首页按全部可见歌建（有声书的
/// 文件夹照书架那样读），歌曲页只建音乐，同一个键下两份不一样，首页那份单独放一格。
private final class HomeDiscoveryFolderIndexCache: @unchecked Sendable {
    static let shared = HomeDiscoveryFolderIndexCache()

    private let lock = NSLock()
    private var privateKey: LibraryFolderIndexReuseKey?
    private var privateSpokenWordIDs: Set<String> = []
    private var privateIndex: LibraryFolderIndex?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .primuseMemoryPressure,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            let droppedShared = LibraryFolderIndexReuseCache.shared.removeAll()
            let droppedPrivate = self?.removeAllPrivate()
            if droppedShared != nil || droppedPrivate != nil {
                Task.detached(priority: .utility) {
                    withExtendedLifetime((droppedShared, droppedPrivate)) {}
                }
            }
        }
    }

    func index(
        for key: LibraryFolderIndexReuseKey,
        spokenWordSongIDs: Set<String>,
        sharesLibraryIndex: Bool
    ) -> LibraryFolderIndex? {
        if sharesLibraryIndex {
            return LibraryFolderIndexReuseCache.shared.index(for: key)
        }
        return lock.withLock {
            privateKey == key && privateSpokenWordIDs == spokenWordSongIDs ? privateIndex : nil
        }
    }

    func store(
        _ index: LibraryFolderIndex,
        for key: LibraryFolderIndexReuseKey,
        spokenWordSongIDs: Set<String>,
        sharesLibraryIndex: Bool
    ) {
        let displaced: LibraryFolderIndex?
        if sharesLibraryIndex {
            displaced = LibraryFolderIndexReuseCache.shared.store(index, for: key)
        } else {
            displaced = lock.withLock {
                let previous = privateIndex
                privateKey = key
                privateSpokenWordIDs = spokenWordSongIDs
                privateIndex = index
                return previous === index ? nil : previous
            }
        }
        if let displaced {
            Task.detached(priority: .utility) { withExtendedLifetime(displaced) {} }
        }
    }

    /// 只认存着的正是 `index` 的那一格，另一格里别人的索引不会被改记。
    func rekey(
        _ index: LibraryFolderIndex,
        from old: LibraryFolderIndexReuseKey,
        to new: LibraryFolderIndexReuseKey
    ) {
        LibraryFolderIndexReuseCache.shared.rekey(index, from: old, to: new)
        lock.withLock {
            guard privateIndex === index, privateKey == old else { return }
            privateKey = new
        }
    }

    private func removeAllPrivate() -> LibraryFolderIndex? {
        lock.withLock {
            let previous = privateIndex
            privateKey = nil
            privateSpokenWordIDs = []
            privateIndex = nil
            return previous
        }
    }
}

@MainActor
@Observable
final class HomeDiscoveryModel {

    private(set) var index: LibraryFolderIndex?
    /// The audiobook chapters the index was built with; their folders read as on the shelf.
    private(set) var spokenWordSongIDs: Set<String> = []
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
    /// 只存当封面的歌(每个文件夹至多 4 首)。整库的歌按需从资料库取, 不在这里再存
    /// 一份 —— 二十多万首的曲库光这张表就要常驻上百 MB。
    @ObservationIgnored private(set) var songsByID: [String: Song] = [:]
    @ObservationIgnored private(set) var folderCoverSongIDs: [LibraryFolderNodeID: [String]] = [:]
    @ObservationIgnored private(set) var lastPlayedByFolder: [LibraryFolderNodeID: Date] = [:]
    @ObservationIgnored private weak var boundLibrary: MusicLibrary?
    @ObservationIgnored private var pinnedCoverNodeIDs: Set<LibraryFolderNodeID> = []
    @ObservationIgnored private var preparedRequest: Request?
    @ObservationIgnored var handledMetadataToken: UUID?
    @ObservationIgnored private var preparedDirectoryNames: [String: [String: String]] = [:]
    @ObservationIgnored private var historySignature: HistorySignature?
    @ObservationIgnored nonisolated(unsafe) private var memoryPressureObserver: NSObjectProtocol?

    init() {
        memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: .primuseMemoryPressure,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.trimCoverCacheToPinnedNodes()
            }
        }
    }

    deinit {
        if let memoryPressureObserver {
            NotificationCenter.default.removeObserver(memoryPressureObserver)
        }
    }
}

extension HomeDiscoveryModel {
    struct Request: Equatable {
        let collection: Int
        let playlists: Int
        let hierarchy: Int
        let names: Int
        let sources: [LibraryFolderSourceDescriptor]
        /// 目录的成员修订号:索引按目录建时,目录跟上内存(新加的歌入了目录)要再建一次。
        var catalogMembership: UInt64 = 0
    }

    private struct HistorySignature: Equatable {
        let revision: Int
        let day: Date
        let calendar: Calendar
        let localeIdentifier: String
    }

    private static let maximumCachedCoverFolders = 256

    func bindLibrary(_ library: MusicLibrary) {
        boundLibrary = library
    }

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
        pinnedNodeIDs: Set<LibraryFolderNodeID> = [],
        request: Request,
        metadataToken: UUID,
        directoryNames: [String: [String: String]],
        spokenWordSongIDs: Set<String> = []
    ) {
        self.songsByID = songs
        self.folderCoverSongIDs = covers
        self.pinnedCoverNodeIDs = pinnedNodeIDs
        self.coverSongIDSet = Set(covers.values.joined())
        self.index = index
        self.spokenWordSongIDs = spokenWordSongIDs
        homePreview = nil
        previewSourceNames = [:]
        previewChildCounts = [:]
        preparedRequest = request
        handledMetadataToken = metadataToken
        preparedDirectoryNames = directoryNames
        historySignature = nil
        refreshHistory()
    }

    func coverSongs(for nodeID: LibraryFolderNodeID) -> [Song] {
        if let cachedIDs = folderCoverSongIDs[nodeID] {
            return cachedIDs.compactMap { songsByID[$0] ?? boundLibrary?.unobservedVisibleSong(id: $0) }
        }
        guard let index, let library = boundLibrary else { return [] }
        // 没预挑过的文件夹（不在根目录前几个、也没钉住）在这里补：挑满四张就停。
        let resolvedSongs = index.firstSongIDs(in: nodeID, limit: 4) { songID in
            library.unobservedVisibleSong(id: songID)?.coverArtFileName != nil
        }.compactMap { library.unobservedVisibleSong(id: $0) }
        if folderCoverSongIDs.count >= Self.maximumCachedCoverFolders {
            trimCoverCacheToPinnedNodes()
        }
        let ids = resolvedSongs.map(\.id)
        folderCoverSongIDs[nodeID] = ids
        for song in resolvedSongs {
            songsByID[song.id] = song
            coverSongIDSet.insert(song.id)
        }
        return resolvedSongs
    }

    private func trimCoverCacheToPinnedNodes() {
        guard index != nil else { return }
        folderCoverSongIDs = folderCoverSongIDs.filter { pinnedCoverNodeIDs.contains($0.key) }
        coverSongIDSet = Set(folderCoverSongIDs.values.joined())
        songsByID = songsByID.filter { coverSongIDSet.contains($0.key) }
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
        let entries = PlayHistoryStore.shared.entries
        // 目录版索引按 id 找节点要查目录:几千条记录一次查完,不逐条查。
        let nodesBySongID = index?.nodeIDs(containingSongIDs: entries.map(\.songID)) ?? [:]
        for entry in entries {
            var nodeID = nodesBySongID[entry.songID]
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

    /// `containingNodeID`:调用方已经批量查好的节点(`.some(nil)` 表示不在索引里);nil 时这里自己查。
    func updateMetadata(song: Song, containingNodeID: LibraryFolderNodeID?? = nil) {
        let previousCover = songsByID[song.id]?.coverArtFileName
        if songsByID[song.id] != nil { songsByID[song.id] = song }
        var coversChanged = false
        if song.coverArtFileName != nil {
            var nodeID = containingNodeID ?? index?.nodeID(containingSongID: song.id)
            while let id = nodeID {
                if let existing = folderCoverSongIDs[id],
                   existing.count < 4,
                   !existing.contains(song.id) {
                    folderCoverSongIDs[id, default: []].append(song.id)
                    coverSongIDSet.insert(song.id)
                    songsByID[song.id] = song
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
                        ? LibraryFolderBrowsePolicy.displayedChildCount(in: index, of: node.id)
                        : node.childNodeCount,
                    sourceDisplayName: index.sourceNode(for: node.sourceID)?.displayName,
                    coverSongIDs: coverSongs(for: node.id).map(\.id)
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

    func songs(
        in id: LibraryFolderNodeID,
        scope: LibraryFolderSongScope = .descendants,
        songForID: (String) -> Song?
    ) -> [Song] {
        LibraryFolderBrowsePolicy.sortedSongs(
            (index?.songIDs(in: id, scope: scope) ?? []).compactMap(songForID),
            spokenWordSongIDs: spokenWordSongIDs
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
        let items: SourceSyncIndex
        let rootNames: [String: String]
        let indexedRoots: Bool
    }

    private var request: HomeDiscoveryModel.Request {
        HomeDiscoveryModel.Request(
            collection: library.visibleSongCollectionRevision,
            playlists: library.playlistCollectionRevision,
            hierarchy: scanService.folderHierarchyRevision,
            names: model.nameRevision,
            sources: sourcesStore.allSources.map(LibraryFolderSourceDescriptor.init(source:)),
            catalogMembership: library.readableCatalogReader == nil ? 0 : (library.catalogHost?.revisions.membership ?? 0)
        )
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: RefreshRequest(content: request, isActive: scenePhase == .active)) {
                isObserverVisible = true
                guard scenePhase == .active else { return }
                await rebuild()
            }
            .onChange(of: library.songReplacementToken) { previousToken, token in
                guard isObserverVisible, scenePhase == .active else { return }
                model.bindLibrary(library)
                let sources = Dictionary(sourcesStore.allSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                var structureChanged = false
                let replacedIDs = Array(library.lastReplacedSongIDs)
                // 目录版索引按 id 找节点要查目录:这一批一次查完。
                let currentNodes = model.index?.nodeIDs(containingSongIDs: replacedIDs) ?? [:]
                for id in replacedIDs {
                    pendingMetadataIDs.insert(id)
                    guard let song = library.unobservedVisibleSong(id: id) else { continue }
                    if let source = sources[song.sourceID],
                       !source.type.isCloudDrive, !source.type.isServerLibrary,
                       source.type != .upnp, song.sourceID != AppleMusicLibraryIdentity.sourceID,
                       LibraryFolderSourceDescriptor(source: source).placementNodeID(for: song)
                        != currentNodes[id] {
                        structureChanged = true
                    }
                    model.updateMetadata(song: song, containingNodeID: .some(currentNodes[id]))
                }
                model.handledMetadataToken = token
                if structureChanged {
                    model.nameRevision &+= 1
                } else if let currentIndex = model.index {
                    let currentKey = LibraryFolderIndexReuseKey(
                        songsRevision: library.musicSongsRevision,
                        collectionRevision: library.visibleSongCollectionRevision,
                        replacementToken: token,
                        virtualCollectionRevision: library.playlistCollectionRevision,
                        hierarchyRevision: scanService.folderHierarchyRevision,
                        sources: request.sources,
                        catalogRevision: library.folderIndexCatalogRevision
                    )
                    HomeDiscoveryFolderIndexCache.shared.rekey(
                        currentIndex,
                        from: currentKey.replacingToken(previousToken),
                        to: currentKey
                    )
                }
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
        model.bindLibrary(library)
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
        let canUseCachedIndex = directoryNames.values.allSatisfy(\.isEmpty)
        if canUseCachedIndex, await publishCachedIndexIfAvailable(request: request, directoryNames: directoryNames) {
            return
        }
        if model.index != nil {
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        if canUseCachedIndex, await publishCachedIndexIfAvailable(request: request, directoryNames: directoryNames) {
            return
        }
        pendingMetadataIDs.removeAll()
        let metadataToken = library.songReplacementToken
        let spokenWordSongIDs = library.spokenWordSongIDs
        let sharesLibraryIndex = library.nonMusicSongIDs.isEmpty
        let reuseKey = folderIndexReuseKey(replacementToken: metadataToken, request: request)
        let songs = library.visibleSongs
        let lookup = library.visibleSongLookup()
        let pins = Self.coverPins()
        let collectionSnapshot = library.appleMusicFolderSnapshot()
        let descriptors = request.sources
        let appleMusicName = String(localized: "apple_music_library_section")
        let sourceName = String(localized: "source_label")
        var providers: [String: ProviderInput] = [:]
        for source in sourcesStore.allSources {
            guard source.type.isCloudDrive || source.type.isServerLibrary || source.type == .upnp else { continue }
            providers[source.id] = ProviderInput(
                items: scanService.libraryFolderSyncIndex(for: source.id),
                rootNames: directoryNames[source.id] ?? [:],
                indexedRoots: source.type.isServerLibrary || source.type == .upnp
            )
        }
        let catalogReader = library.readableCatalogReader
        let task = Task.detached(priority: .utility) {
            [descriptors, providers, spokenWordSongIDs, catalogReader] () async -> (LibraryFolderIndex, PrewarmedCovers)? in
            guard !Task.isCancelled else { return nil }
            let collections = collectionSnapshot.collections(availableSongs: songs)
            if let catalogReader {
                // 目录可读:按目录建,索引里每首歌只留行号。配置里没有的源由目录里出现的先后补描述。
                var configured: [LibraryFolderSourceDescriptor] = []
                for descriptor in descriptors {
                    guard let provider = providers[descriptor.sourceID] else {
                        configured.append(descriptor)
                        continue
                    }
                    guard let attached = descriptor.attachingProviderHierarchy(
                        syncIndex: provider.items,
                        rootDisplayNames: provider.rootNames,
                        usesIndexedRoots: provider.indexedRoots,
                        isCancelled: { Task.isCancelled }
                    ) else { return nil }
                    configured.append(attached)
                }
                let virtualSourceIDs = Set(collections.filter { $0.kind == .librarySongs }.map(\.sourceID))
                let memorySongs = virtualSourceIDs.isEmpty ? [] : songs.filter { virtualSourceIDs.contains($0.sourceID) }
                do {
                    let index = try await catalogReader.folderIndex { [configured] catalog, isCancelled in
                        try LibraryFolderIndexBuilder.build(
                            sources: configured,
                            catalog: LibraryFolderCatalogInput(
                                catalog: catalog, kinds: nil, ordersSpokenWordLikeShelf: !spokenWordSongIDs.isEmpty
                            ),
                            unlistedSource: { sourceID in
                                LibraryFolderUnlistedSource.descriptor(
                                    sourceID: sourceID, appleMusicName: appleMusicName, genericName: sourceName
                                )
                            },
                            memorySongs: memorySongs,
                            virtualCollections: collections,
                            spokenWordSongIDs: spokenWordSongIDs,
                            isCancelled: isCancelled
                        )
                    }
                    guard !Task.isCancelled else { return nil }
                    let prewarmed = Self.prewarmedCovers(for: index, lookup: lookup, pins: pins) { Task.isCancelled }
                    return (index, prewarmed)
                } catch is CancellationError {
                    return nil
                } catch {
                    plog("⚠️ Home folder index from catalog failed, using memory: \(error)")
                }
            }
            var descriptors = descriptors
            var known = Set(descriptors.map(\.sourceID))
            for index in songs.indices {
                if index.isMultiple(of: 256), Task.isCancelled { return nil }
                let sourceID = songs[index].sourceID
                if known.insert(sourceID).inserted {
                    descriptors.append(LibraryFolderSourceDescriptor(
                        sourceID: sourceID,
                        displayName: sourceID == AppleMusicLibraryIdentity.sourceID ? appleMusicName : sourceName,
                        scanRoots: [], pathSemantics: .opaque
                    ))
                }
            }
            // 和歌曲页同一套挂法：共用一份索引时两边建出来的必须一样。被取消就中途放弃，不再走完整个曲库。
            var resolved: [LibraryFolderSourceDescriptor] = []
            for descriptor in descriptors {
                guard let provider = providers[descriptor.sourceID] else {
                    resolved.append(descriptor)
                    continue
                }
                guard let attached = descriptor.attachingProviderHierarchy(
                    syncIndex: provider.items,
                    rootDisplayNames: provider.rootNames,
                    usesIndexedRoots: provider.indexedRoots,
                    isCancelled: { Task.isCancelled }
                ) else { return nil }
                resolved.append(attached)
            }
            guard !Task.isCancelled else { return nil }
            let index = LibraryFolderIndexBuilder.build(
                sources: resolved,
                songs: songs,
                virtualCollections: collections,
                spokenWordSongIDs: spokenWordSongIDs
            )
            guard !Task.isCancelled else { return nil }
            let prewarmed = Self.prewarmedCovers(for: index, lookup: lookup, pins: pins) { Task.isCancelled }
            return (index, prewarmed)
        }
        let built = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, self.request == request,
              case let (builtIndex, prewarmed)? = built else { return }
        if canUseCachedIndex {
            HomeDiscoveryFolderIndexCache.shared.store(
                builtIndex,
                for: reuseKey,
                spokenWordSongIDs: spokenWordSongIDs,
                sharesLibraryIndex: sharesLibraryIndex
            )
        }
        publish(
            builtIndex,
            prewarmed: prewarmed,
            request: request,
            metadataToken: metadataToken,
            directoryNames: directoryNames,
            spokenWordSongIDs: spokenWordSongIDs
        )
    }

    /// 存着照眼下这份输入建好的索引时直接用它，只在后台挑一遍卡片封面。
    private func publishCachedIndexIfAvailable(
        request: HomeDiscoveryModel.Request,
        directoryNames: [String: [String: String]]
    ) async -> Bool {
        let metadataToken = library.songReplacementToken
        let spokenWordSongIDs = library.spokenWordSongIDs
        guard let cachedIndex = HomeDiscoveryFolderIndexCache.shared.index(
            for: folderIndexReuseKey(replacementToken: metadataToken, request: request),
            spokenWordSongIDs: spokenWordSongIDs,
            sharesLibraryIndex: library.nonMusicSongIDs.isEmpty
        ) else { return false }
        pendingMetadataIDs.removeAll()
        let lookup = library.visibleSongLookup()
        let pins = Self.coverPins()
        let task = Task.detached(priority: .utility) {
            Self.prewarmedCovers(for: cachedIndex, lookup: lookup, pins: pins) { Task.isCancelled }
        }
        let prewarmed = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        // 取消或请求换了也算处理过：调用方别再拿过期的输入去建一份。
        guard !Task.isCancelled, self.request == request else { return true }
        publish(
            cachedIndex,
            prewarmed: prewarmed,
            request: request,
            metadataToken: metadataToken,
            directoryNames: directoryNames,
            spokenWordSongIDs: spokenWordSongIDs
        )
        return true
    }

    private func folderIndexReuseKey(
        replacementToken: UUID,
        request: HomeDiscoveryModel.Request
    ) -> LibraryFolderIndexReuseKey {
        LibraryFolderIndexReuseKey(
            songsRevision: library.musicSongsRevision,
            collectionRevision: library.visibleSongCollectionRevision,
            replacementToken: replacementToken,
            virtualCollectionRevision: library.playlistCollectionRevision,
            hierarchyRevision: scanService.folderHierarchyRevision,
            sources: request.sources,
            catalogRevision: library.folderIndexCatalogRevision
        )
    }

    /// 发布之后把等待期间到的标签替换补上。
    private func publish(
        _ index: LibraryFolderIndex,
        prewarmed: PrewarmedCovers,
        request: HomeDiscoveryModel.Request,
        metadataToken: UUID,
        directoryNames: [String: [String: String]],
        spokenWordSongIDs: Set<String>
    ) {
        let patchedMetadataToken = pendingMetadataIDs.isEmpty ? metadataToken : model.handledMetadataToken
        model.publish(
            index: index,
            songs: prewarmed.songsByID,
            covers: prewarmed.covers,
            pinnedNodeIDs: prewarmed.pinnedNodeIDs,
            request: request,
            metadataToken: metadataToken,
            directoryNames: directoryNames,
            spokenWordSongIDs: spokenWordSongIDs
        )
        for id in pendingMetadataIDs {
            if let song = library.unobservedVisibleSong(id: id) { model.updateMetadata(song: song) }
        }
        model.handledMetadataToken = patchedMetadataToken
        pendingMetadataIDs.removeAll()
    }

    private struct CoverPins: Sendable {
        let raw: String
        let displayCount: Int
    }

    private struct PrewarmedCovers: Sendable {
        let songsByID: [String: Song]
        let covers: [LibraryFolderNodeID: [String]]
        let pinnedNodeIDs: Set<LibraryFolderNodeID>
    }

    private static func coverPins() -> CoverPins {
        CoverPins(
            raw: UserDefaults.standard.string(forKey: HomeFolderPinStorage.key) ?? "",
            displayCount: UserDefaults.standard.object(forKey: HomeFolderPinStorage.displayCountKey) as? Int
                ?? HomeFolderPinStorage.defaultDisplayCount
        )
    }

    /// 首页会摆出来的那几个文件夹（钉住的、各源根目录和它们前几个子目录）先挑好封面。
    /// 在主线程外做：源的根目录就是整个源，挑满四张就停，不先展开整棵子树。
    private nonisolated static func prewarmedCovers(
        for index: LibraryFolderIndex,
        lookup: VisibleSongLookup,
        pins: CoverPins,
        isCancelled: () -> Bool
    ) -> PrewarmedCovers {
        var candidateNodeIDs = Set(
            HomeFolderPinStorage.resolvedPins(pins.raw, index: index, defaultCount: pins.displayCount)
        )
        for rootNode in LibraryFolderBrowsePolicy.rootNodes(in: index, sourceID: nil) {
            candidateNodeIDs.insert(rootNode.id)
            for child in LibraryFolderBrowsePolicy.displayedChildren(in: index, of: rootNode.id).prefix(16) {
                candidateNodeIDs.insert(child.id)
            }
        }
        var songsByID: [String: Song] = [:]
        var covers: [LibraryFolderNodeID: [String]] = [:]
        for nodeID in candidateNodeIDs {
            if isCancelled() { break }
            let ids = index.firstSongIDs(
                in: nodeID,
                limit: 4,
                where: { lookup.song(id: $0)?.coverArtFileName != nil },
                isCancelled: isCancelled
            )
            for songID in ids where songsByID[songID] == nil {
                songsByID[songID] = lookup.song(id: songID)
            }
            covers[nodeID] = ids
        }
        return PrewarmedCovers(songsByID: songsByID, covers: covers, pinnedNodeIDs: candidateNodeIDs)
    }
}
