import SwiftUI
import PrimuseKit

private extension LibraryFolderNode {
    func displayedChildCount(in index: LibraryFolderIndex?) -> Int {
        guard kind == .source, let index else { return childNodeCount }
        return LibraryFolderBrowsePolicy.displayedChildren(in: index, of: id).count
    }
}

#if os(macOS)
private struct MacFolderLibraryLocationActionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (Song) -> Void)? = nil
}

extension EnvironmentValues {
    var macFolderShowInLibrary: (@MainActor (Song) -> Void)? {
        get { self[MacFolderLibraryLocationActionKey.self] }
        set { self[MacFolderLibraryLocationActionKey.self] = newValue }
    }
}
#endif

struct HomeFoldersSection: View {
    @Environment(HomeDiscoveryModel.self) private var model
    @AppStorage(HomeFolderPinStorage.key) private var pinsRawValue = ""
    @AppStorage(HomeFolderPinStorage.displayCountKey) private var displayCount = HomeFolderPinStorage.defaultDisplayCount

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(HomeDiscoveryText.string("folders"))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                NavigationLink {
                    HomeFolderBrowser(showsInlineBack: true)
                        #if os(iOS)
                        .minimalNavigationDetail()
                        #endif
                } label: {
                    HStack(spacing: 5) {
                        Text("see_all")
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("home.allFolders")
            }

            if model.index == nil {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else {
                let nodes = model.pins(from: pinsRawValue).compactMap { model.index?.node(withID: $0) }
                ForEach(Array(nodes.prefix(HomeFolderPinStorage.displayCount(displayCount)))) { node in
                    HomeFolderRow(node: node)
                    Divider().padding(.leading, 68)
                }
                if nodes.isEmpty {
                    Text(HomeDiscoveryText.string("no_pinned_folders"))
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 20)
    }
}

struct HomeFolderManagementView: View {
    var usesInlineControls = false
    @State private var model = HomeDiscoveryModel()
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    var body: some View {
        HomeFolderBrowser(usesInlineControls: usesInlineControls)
            .environment(model)
            .background { HomeDiscoveryObserver(model: model) }
            #if os(iOS)
            .environment(\.editMode, $editMode)
            #endif
    }
}

struct HomeFolderArtwork: View {
    let node: LibraryFolderNode
    var size: CGFloat = 54
    @Environment(HomeDiscoveryModel.self) private var model

    var body: some View {
        let _ = model.revision
        let songs = (model.folderCoverSongIDs[node.id] ?? []).compactMap { model.songsByID[$0] }
        Group {
            if songs.count >= 4 {
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow { artwork(songs[0], size: size / 2); artwork(songs[1], size: size / 2) }
                    GridRow { artwork(songs[2], size: size / 2); artwork(songs[3], size: size / 2) }
                }
            } else if let song = songs.first {
                artwork(song, size: size)
            } else {
                Image(systemName: "folder.fill")
                    .font(.system(size: size * 0.38))
                    .foregroundStyle(.tint)
                    .frame(width: size, height: size)
                    .background(.quaternary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
    }

    private func artwork(_ song: Song, size: CGFloat) -> some View {
        CachedArtworkView(
            coverRef: song.coverArtFileName, songID: song.id, size: size, cornerRadius: 0,
            sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat
        )
    }
}

private struct HomeFolderRow: View {
    let node: LibraryFolderNode
    var onOpen: (() -> Void)? = nil
    @Environment(HomeDiscoveryModel.self) private var model
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @AppStorage(HomeFolderPinStorage.key) private var pinsRawValue = ""

    private var playButtonWidth: CGFloat {
        #if os(macOS)
        32
        #else
        44
        #endif
    }

    private var artworkSize: CGFloat {
        #if os(macOS)
        36
        #else
        54
        #endif
    }

    var body: some View {
        let _ = model.revision
        HStack(spacing: 8) {
            Group {
                if let onOpen {
                    Button(action: onOpen) { folderLabel }
                } else {
                    NavigationLink {
                        HomeFolderBrowser(nodeID: node.id)
                            .environment(model)
                    } label: { folderLabel }
                }
            }
            .buttonStyle(.plain)

            Button { play(shuffle: false) } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 25))
                    .frame(width: playButtonWidth, height: artworkSize)
            }
            .buttonStyle(.plain).foregroundStyle(.tint)
            .disabled(node.descendantSongCount == 0)
            .accessibilityLabel(String(localized: "play") + " · " + HomeDiscoveryText.folderTitle(node))
        }
        .contextMenu {
            Button("play", systemImage: "play.fill") { play(shuffle: false) }
            Button("shuffle", systemImage: "shuffle") { play(shuffle: true) }
            Button(HomeDiscoveryText.string("unpin_folder"), systemImage: "pin.slash") {
                pinsRawValue = HomeFolderPinStorage.replacingVisiblePins(
                    in: pinsRawValue,
                    with: model.pins(from: pinsRawValue).filter { $0 != node.id },
                    index: model.index,
                    defaultCount: UserDefaults.standard.object(forKey: HomeFolderPinStorage.displayCountKey) as? Int
                        ?? HomeFolderPinStorage.defaultDisplayCount
                )
            }
        }
    }

    private var folderLabel: some View {
        HStack(spacing: 14) {
            HomeFolderArtwork(node: node, size: artworkSize)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").font(.caption).foregroundStyle(.tint)
                    Text(HomeDiscoveryText.folderTitle(node))
                        .font(.headline).lineLimit(1).foregroundStyle(.primary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { sourceBadge; songCount }
                    VStack(alignment: .leading, spacing: 3) { sourceBadge; songCount }
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var sourceBadge: some View {
        Text(model.index?.sourceNode(for: node.sourceID)?.displayName ?? String(localized: "source_label"))
            .font(.caption2.weight(.medium)).lineLimit(1)
            .foregroundStyle(.tint)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
    }

    private var songCount: some View {
        let childCount = node.displayedChildCount(in: model.index)
        let counts = childCount > 0
            ? String(format: HomeDiscoveryText.string("folder_counts"), childCount, node.descendantSongCount)
            : "\(node.descendantSongCount.formatted()) \(String(localized: "songs_count"))"
        let lastPlayed = childCount == 0 ? model.lastPlayedByFolder[node.id] : nil
        let suffix = lastPlayed.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? ""
        return Text(counts + suffix)
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    private func play(shuffle: Bool) {
        HomeDiscoveryPlayback.play(
            ids: model.songs(in: node.id).map(\.id), shuffle: shuffle,
            library: library, player: player
        )
    }
}

struct HomeFolderBrowser: View {
    var nodeID: LibraryFolderNodeID?
    var usesInlineControls = false
    var showsInlineBack = false
    #if os(iOS)
    @Environment(\.appNavigationMode) private var appNavigationMode
    @Environment(\.editMode) private var editMode
    @Environment(\.legacyBottomChromeOverlayActive)
    private var legacyBottomChromeOverlayActive
    #endif
    #if os(macOS)
    @Environment(\.dismiss) private var dismiss
    @Environment(\.macFolderShowInLibrary) private var macShowInLibrary
    @State private var macListChromeHeight: CGFloat = 0
    @State private var macListViewportHeight: CGFloat = 0
    @State private var macSongAction: SongRowActionRequest?
    @State private var macFolderPath: [LibraryFolderNodeID?] = []
    @State private var macSearchText = ""
    @State private var macSearchScope: LibrarySearchScope?
    @State private var macSearchContext: LibrarySearchScope?
    @FocusState private var macSearchFocused: Bool
    #endif
    @Environment(HomeDiscoveryModel.self) private var model
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @AppStorage(HomeFolderPinStorage.key) private var pinsRawValue = ""

    private var currentNodeID: LibraryFolderNodeID? {
        #if os(macOS)
        if let location = macFolderPath.last { return location }
        return nodeID
        #else
        nodeID
        #endif
    }

    private var node: LibraryFolderNode? { currentNodeID.flatMap { model.index?.node(withID: $0) } }
    private var pins: [LibraryFolderNodeID] { model.pins(from: pinsRawValue) }
    private var children: [LibraryFolderNode] {
        if let currentNodeID, let index = model.index {
            return LibraryFolderBrowsePolicy.displayedChildren(in: index, of: currentNodeID)
        }
        return model.index?.sourceNodes ?? []
    }

    private func directSongs(in nodeID: LibraryFolderNodeID) -> [Song] {
        guard let index = model.index else { return [] }
        return LibraryFolderBrowsePolicy.sortedSongs(
            LibraryFolderBrowsePolicy.displayedSongIDs(in: index, of: nodeID)
                .compactMap { library.unobservedVisibleSong(id: $0) }
        )
    }

    private func savePins(_ updated: [LibraryFolderNodeID]) {
        pinsRawValue = HomeFolderPinStorage.replacingVisiblePins(
            in: pinsRawValue, with: updated, index: model.index,
            defaultCount: UserDefaults.standard.object(forKey: HomeFolderPinStorage.displayCountKey) as? Int
                ?? HomeFolderPinStorage.defaultDisplayCount
        )
    }

    private var legacyBottomClearance: CGFloat {
        #if os(iOS)
        appNavigationMode == .minimal
            ? 0
            : BottomChromeClearancePolicy.clearance(
                legacyOverlayActive: legacyBottomChromeOverlayActive,
                legacy: 90,
                baseline: 0
            )
        #else
        0
        #endif
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            macHeader
            if let context = macSearchContext {
                SearchView(
                    searchText: $macSearchText,
                    scope: $macSearchScope,
                    contextualScope: context,
                    showsMacQuerySummary: false,
                    onShowInLibrary: { song in macShowInLibrary?(song) }
                )
            } else if let currentNodeID {
                macFolderList(nodeID: currentNodeID)
            } else {
                macOverview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(PMColor.bg)
        .background {
            if let request = macSongAction {
                // Present actions once per page, outside the recycled scroll rows.
                SongRowView(song: request.song, actionRequest: request)
                    .id(request.id)
            }
        }
        .navigationBarBackButtonHidden(nodeID != nil || showsInlineBack)
        .onChange(of: model.revision) { _, _ in
            refreshMacSearchContext()
        }
        #else
        folderList
        #endif
    }

    private var folderList: some View {
        List {
            if nodeID == nil, !pins.isEmpty {
                Section {
                    ForEach(pins, id: \.self) { id in
                        if let node = model.index?.node(withID: id) {
                            #if os(macOS)
                            HomeFolderRow(node: node, onOpen: { openMacFolder(node.id) })
                            #else
                            HomeFolderRow(node: node)
                            #endif
                        } else {
                            Label(HomeDiscoveryText.string("folder_unavailable"), systemImage: "folder.badge.questionmark")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onMove { from, to in
                        var updated = pins
                        updated.move(fromOffsets: from, toOffset: to)
                        savePins(updated)
                    }
                    .onDelete { offsets in
                        var updated = pins
                        updated.remove(atOffsets: offsets)
                        savePins(updated)
                        #if os(iOS)
                        if usesInlineControls, updated.isEmpty {
                            editMode?.wrappedValue = .inactive
                        }
                        #endif
                    }
                } header: {
                    HStack {
                        Text(HomeDiscoveryText.string("pinned_folders"))
                        #if os(iOS)
                        if usesInlineControls {
                            Spacer()
                            EditButton()
                                .font(.subheadline)
                                .textCase(nil)
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("minimal.folders.edit")
                        }
                        #endif
                    }
                }
            }

            if !children.isEmpty {
                Section(nodeID == nil ? String(localized: "sources_title") : HomeDiscoveryText.string("folders")) {
                    ForEach(children) { child in
                        childRow(child)
                    }
                }
            }

            if let nodeID {
                let songs = directSongs(in: nodeID)
                let ids = songs.map(\.id)
                if !songs.isEmpty {
                    Section("tab_songs") {
                        ForEach(songs) { song in
                            // A fixed row container prevents List from expanding
                            // SongRowView's conditional menu tree for every song.
                            HStack(spacing: 0) {
                                SongRowView(song: song, isPlaying: player.currentSong?.id == song.id)
                            }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    HomeDiscoveryPlayback.play(ids: ids, startingAt: song.id, library: library, player: player)
                                }
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: legacyBottomClearance == 0 ? 0 : nil) {
            Color.clear.frame(height: legacyBottomClearance)
        }
        .overlay {
            if model.index == nil {
                ProgressView()
            } else if children.isEmpty && (node?.descendantSongCount ?? 0) == 0 {
                ContentUnavailableView(
                    HomeDiscoveryText.string(nodeID == nil ? "no_folders" : "folder_unavailable"),
                    systemImage: "folder",
                    description: Text(HomeDiscoveryText.string("folders_hint"))
                )
            }
        }
        .navigationTitle(node.map(HomeDiscoveryText.folderTitle) ?? HomeDiscoveryText.string("folders"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .minimalNavigationDetail(isDetail: nodeID != nil)
        .librarySearchContext {
            guard let node, let index = model.index else { return nil }
            return LibrarySearchScope.folder(node: node, index: index, title: HomeDiscoveryText.folderTitle)
        }
        .toolbar {
            if let node {
                ToolbarItemGroup(placement: .primaryAction) {
                    pinButton(node.id)
                    Menu {
                        Button("play", systemImage: "play.fill") { playFolder(node.id, shuffle: false) }
                        Button("shuffle", systemImage: "shuffle") { playFolder(node.id, shuffle: true) }
                    } label: { Image(systemName: "play.circle") }
                    .disabled(node.descendantSongCount == 0)
                    .accessibilityLabel("play")
                    if FolderPlaylistMenuButton.supports(node) {
                        Menu {
                            FolderPlaylistMenuButton(node: node, index: model.index)
                        } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("a11y_more_actions")
                    }
                }
            }
            if node == nil, !usesInlineControls {
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
        }
        #endif
    }

    #if os(macOS)
    private var macOverview: some View {
        MacFolderOverviewLayout(hasPins: !pins.isEmpty) {
            ForEach(pins, id: \.self) { id in
                if let folder = model.index?.node(withID: id) {
                    MacFolderPinnedCard(
                        title: HomeDiscoveryText.folderTitle(folder),
                        source: model.index?.sourceNode(for: folder.sourceID).map(HomeDiscoveryText.folderTitle) ?? "",
                        detail: String(format: HomeDiscoveryText.string("folder_counts"), folder.displayedChildCount(in: model.index), folder.descendantSongCount),
                        canPlay: folder.descendantSongCount > 0,
                        onOpen: { openMacFolder(id) },
                        onPlay: { playFolder(id, shuffle: false) }
                    ) {
                        HomeFolderArtwork(node: folder, size: 48)
                    }
                    .contextMenu { macPinnedFolderMenu(folder) }
                } else {
                    Label(HomeDiscoveryText.string("folder_unavailable"), systemImage: "folder.badge.questionmark")
                        .foregroundStyle(PMColor.textMuted)
                        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                        .contextMenu {
                            Button(HomeDiscoveryText.string("unpin_folder"), systemImage: "pin.slash") { togglePin(id) }
                        }
                }
            }
        } sources: {
            ForEach(children) { child in
                childRow(child)
            }
        }
        .overlay {
            if model.index == nil {
                ProgressView()
            } else if children.isEmpty && pins.isEmpty {
                ContentUnavailableView(
                    HomeDiscoveryText.string("no_folders"),
                    systemImage: "folder",
                    description: Text(HomeDiscoveryText.string("folders_hint"))
                )
            }
        }
    }

    @ViewBuilder
    private func macPinnedFolderMenu(_ folder: LibraryFolderNode) -> some View {
        Button("play", systemImage: "play.fill") { playFolder(folder.id, shuffle: false) }
            .disabled(folder.descendantSongCount == 0)
        Button("shuffle", systemImage: "shuffle") { playFolder(folder.id, shuffle: true) }
            .disabled(folder.descendantSongCount == 0)
        FolderPlaylistMenuButton(node: folder, index: model.index)
        Divider()
        Button("ai_move_up", systemImage: "arrow.up") { moveMacPin(folder.id, by: -1) }
            .disabled(pins.first == folder.id)
        Button("ai_move_down", systemImage: "arrow.down") { moveMacPin(folder.id, by: 1) }
            .disabled(pins.last == folder.id)
        Button(HomeDiscoveryText.string("unpin_folder"), systemImage: "pin.slash") { togglePin(folder.id) }
    }

    private func moveMacPin(_ id: LibraryFolderNodeID, by offset: Int) {
        var updated = pins
        guard let index = updated.firstIndex(of: id), updated.indices.contains(index + offset) else { return }
        updated.swapAt(index, index + offset)
        savePins(updated)
    }

    private var macBreadcrumbs: [LibraryFolderNode] {
        var result: [LibraryFolderNode] = []
        var visited = Set<LibraryFolderNodeID>()
        var cursor = currentNodeID
        while let id = cursor, visited.insert(id).inserted,
              let folder = model.index?.node(withID: id) {
            let isCollapsedAncestor = id != currentNodeID
                && folder.kind == .scanRoot
                && folder.parentID.flatMap { parentID in
                    model.index.flatMap { LibraryFolderBrowsePolicy.collapsedScanRoot(in: $0, for: parentID) }
                }?.id == id
            if !isCollapsedAncestor { result.append(folder) }
            cursor = folder.parentID
        }
        return result.reversed()
    }

    private func openMacFolder(_ id: LibraryFolderNodeID?) {
        guard id != currentNodeID else { return }
        // Native navigation pushes recreate window history/chrome; keep folder changes inside this pane.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            macSongAction = nil
            closeMacSearch()
            macFolderPath.append(id)
        }
    }

    private func navigateMacBreadcrumb(to id: LibraryFolderNodeID?) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            macSongAction = nil
            closeMacSearch()
            if id == nodeID {
                macFolderPath.removeAll()
            } else if let index = macFolderPath.firstIndex(of: id) {
                macFolderPath = Array(macFolderPath.prefix(through: index))
            } else {
                macFolderPath.append(id)
            }
        }
    }

    private func macFolderList(nodeID: LibraryFolderNodeID) -> some View {
        GeometryReader { geometry in
            macFolderContents(nodeID: nodeID, width: max(0, geometry.size.width - PMSpace.xxxl * 2))
        }
    }

    private func macFolderContents(nodeID: LibraryFolderNodeID, width: CGFloat) -> some View {
        let folders = children
        let songIDs = directSongs(in: nodeID).map(\.id)
        let folderColumns = max(1, Int((width + 12) / 272))
        let folderRows = (folders.count + folderColumns - 1) / folderColumns
        let folderWidth = min(360, max(0, (width - CGFloat(folderColumns - 1) * 12) / CGFloat(folderColumns)))
        let hasSongSection = !folders.isEmpty && !songIDs.isEmpty
        let songStart = folderRows + (hasSongSection ? 1 : 0)
        let columns = MacFolderSongColumns(width: width)

        return MacWindowedSongScrollView(
            axes: .vertical,
            rowCount: songStart + songIDs.count,
            rowHeight: songIDs.isEmpty ? 80 : 52,
            chromeHeight: $macListChromeHeight,
            viewportHeight: $macListViewportHeight
        ) {
            if !folders.isEmpty || !songIDs.isEmpty {
                Group {
                    if folders.isEmpty {
                        MacFolderSongColumnsHeader(columns: columns)
                    } else {
                        macSectionHeader(HomeDiscoveryText.string("folders"))
                    }
                }
                    .frame(width: width, alignment: .leading)
                    .padding(.horizontal, PMSpace.xxxl)
                    .padding(.vertical, 8)
            }
        } rowContent: { position in
            if position < folderRows {
                HStack(spacing: 12) {
                    ForEach((position * folderColumns)..<min((position + 1) * folderColumns, folders.count), id: \.self) { index in
                        let folder = folders[index]
                        MacFolderChildCard(
                            title: HomeDiscoveryText.folderTitle(folder),
                            detail: folder.displayedChildCount(in: model.index) > 0
                                ? String(format: HomeDiscoveryText.string("folder_counts"), folder.displayedChildCount(in: model.index), folder.descendantSongCount)
                                : "\(folder.descendantSongCount.formatted()) \(String(localized: "songs_count"))",
                            compact: !songIDs.isEmpty,
                            onOpen: { openMacFolder(folder.id) }
                        )
                        .frame(width: folderWidth)
                        .contextMenu { macChildFolderMenu(folder) }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: width, alignment: .leading)
            } else if hasSongSection && position == folderRows {
                MacFolderSongColumnsHeader(columns: columns)
                    .frame(width: width, alignment: .leading)
            } else {
                let songID = songIDs[position - songStart]
                MacHomeFolderSongRow(songID: songID, orderedSongIDs: songIDs, position: position - songStart + 1, columns: columns) { song, action in
                    macSongAction = SongRowActionRequest(song: song, action: action)
                }
                    .frame(width: width, alignment: .leading)
                    .id(songID)
            }
        }
        .modifier(MacFolderScrollReset(nodeID: nodeID))
        .overlay {
            if model.index == nil {
                ProgressView()
            } else if folders.isEmpty && songIDs.isEmpty {
                ContentUnavailableView(
                    HomeDiscoveryText.string("folder_unavailable"),
                    systemImage: "folder",
                    description: Text(HomeDiscoveryText.string("folders_hint"))
                )
            }
        }
    }

    private func macSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(PMColor.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var macHeader: some View {
        if let node {
            MacFolderDetailHeader(
                title: HomeDiscoveryText.folderTitle(node),
                detail: node.displayedChildCount(in: model.index) > 0
                    ? String(format: HomeDiscoveryText.string("folder_counts"), node.displayedChildCount(in: model.index), node.descendantSongCount)
                    : "\(node.descendantSongCount.formatted()) \(String(localized: "songs_count"))",
                isSource: node.kind == .source
            ) {
                macBackButton
                ViewThatFits(in: .horizontal) {
                    macBreadcrumbTrail(compact: false)
                    macBreadcrumbTrail(compact: true)
                }
            } tools: {
                if let context = macSearchContext {
                    macSearchControls(context: context)
                } else {
                    Button {
                        guard let index = model.index else { return }
                        let context = LibrarySearchScope.folder(
                            node: node,
                            index: index,
                            title: HomeDiscoveryText.folderTitle
                        )
                        macSearchScope = context
                        macSearchContext = context
                    } label: {
                        Image(systemName: "magnifyingglass").frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("search_title")
                    pinButton(node.id)
                    if FolderPlaylistMenuButton.supports(node) {
                        Menu {
                            FolderPlaylistMenuButton(node: node, index: model.index)
                        } label: { Image(systemName: "ellipsis").frame(width: 30, height: 30) }
                        .menuStyle(.borderlessButton)
                        .accessibilityLabel("a11y_more_actions")
                    }
                }
            } playback: {
                Button("shuffle", systemImage: "shuffle") {
                    playFolder(node.id, shuffle: true)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .frame(width: 30, height: 30)
                .disabled(node.descendantSongCount == 0)
                Button("play_all", systemImage: "play.fill") {
                    playFolder(node.id, shuffle: false)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(node.descendantSongCount == 0)
            }
        } else {
            HStack(spacing: 12) {
                if showsInlineBack || !macFolderPath.isEmpty { macBackButton }
                Text(HomeDiscoveryText.string("folders"))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(PMColor.text)
                Spacer()
            }
            .padding(.horizontal, PMSpace.xxxl)
            .padding(.vertical, 24)
        }
    }

    private var macBackButton: some View {
        Button {
            if macFolderPath.isEmpty {
                dismiss()
            } else {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    macSongAction = nil
                    closeMacSearch()
                    macFolderPath.removeLast()
                }
            }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PMColor.textMuted)
        .accessibilityLabel("back")
        .accessibilityIdentifier("folderInlineBack")
    }

    @ViewBuilder
    private func macChildFolderMenu(_ child: LibraryFolderNode) -> some View {
        Button("play", systemImage: "play.fill") { playFolder(child.id, shuffle: false) }
            .disabled(child.descendantSongCount == 0)
        Button("shuffle", systemImage: "shuffle") { playFolder(child.id, shuffle: true) }
            .disabled(child.descendantSongCount == 0)
        FolderPlaylistMenuButton(node: child, index: model.index)
        if child.kind != .source {
            let pinned = pins.contains(child.id)
            Button(HomeDiscoveryText.string(pinned ? "unpin_folder" : "pin_folder"),
                   systemImage: pinned ? "pin.slash" : "pin") {
                togglePin(child.id)
            }
        }
    }

    private func macSearchControls(context: LibrarySearchScope) -> some View {
        HStack(spacing: 6) {
            TextField(
                macSearchScope.map { String(format: String(localized: "search_scope_prompt_format"), $0.title) }
                    ?? String(localized: "search_prompt"),
                text: $macSearchText
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(minWidth: 120, idealWidth: 220, maxWidth: 260, minHeight: 32)
            .background(PMColor.bgElev, in: RoundedRectangle(cornerRadius: 8))
            .focused($macSearchFocused)
            .onExitCommand { closeMacSearch() }
            .task { macSearchFocused = true }

            SearchScopeSwitchButton(scope: $macSearchScope, context: context)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
            Button { closeMacSearch() } label: {
                Image(systemName: "xmark").frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("close")
        }
    }

    private func refreshMacSearchContext() {
        guard macSearchContext != nil,
              let node,
              let index = model.index else { return }
        let context = LibrarySearchScope.folder(
            node: node,
            index: index,
            title: HomeDiscoveryText.folderTitle
        )
        if macSearchScope != nil {
            macSearchScope = context
        }
        macSearchContext = context
    }

    private func closeMacSearch() {
        macSearchFocused = false
        macSearchText = ""
        macSearchContext = nil
        macSearchScope = nil
    }

    private func macBreadcrumbTrail(compact: Bool) -> some View {
        let ancestors = Array(macBreadcrumbs.dropLast())
        return HStack(spacing: 7) {
            Button(HomeDiscoveryText.string("folders")) { navigateMacBreadcrumb(to: nil) }
            if compact, ancestors.count > 1 {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                Menu {
                    ForEach(ancestors.dropLast()) { folder in
                        Button(HomeDiscoveryText.folderTitle(folder)) { navigateMacBreadcrumb(to: folder.id) }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuIndicator(.hidden)
            }
            ForEach(compact ? Array(ancestors.suffix(1)) : ancestors) { folder in
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                Button(HomeDiscoveryText.folderTitle(folder)) { navigateMacBreadcrumb(to: folder.id) }
                    .lineLimit(1)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(PMColor.textMuted)
        .buttonStyle(.plain)
        .fixedSize(horizontal: !compact, vertical: true)
    }
    #endif

    private func childRow(_ child: LibraryFolderNode) -> some View {
        HStack {
            #if os(macOS)
            MacFolderDirectoryRow(
                title: HomeDiscoveryText.folderTitle(child),
                folderCount: child.displayedChildCount(in: model.index),
                songCount: child.descendantSongCount,
                isSource: child.kind == .source,
                onOpen: { openMacFolder(child.id) },
                onPlay: { playFolder(child.id, shuffle: false) }
            )
            #else
            NavigationLink {
                HomeFolderBrowser(nodeID: child.id)
                    .environment(model)
            } label: {
                HomeFolderChildLabel(node: child)
            }
            pinButton(child.id)
            #endif
        }
        #if os(macOS)
        .contextMenu { macChildFolderMenu(child) }
        #endif
    }

    private func pinButton(_ id: LibraryFolderNodeID) -> some View {
        let pinned = pins.contains(id)
        return Button {
            togglePin(id)
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                #if os(macOS)
                .frame(width: 30, height: 30)
                #else
                .frame(width: 44, height: 44)
                #endif
                .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(HomeDiscoveryText.string(pinned ? "unpin_folder" : "pin_folder"))
    }

    private func togglePin(_ id: LibraryFolderNodeID) {
        var updated = pins
        if updated.contains(id) { updated.removeAll { $0 == id } } else { updated.insert(id, at: 0) }
        savePins(updated)
    }

    private func playFolder(_ id: LibraryFolderNodeID, shuffle: Bool) {
        HomeDiscoveryPlayback.play(ids: model.songs(in: id).map(\.id), shuffle: shuffle, library: library, player: player)
    }
}

struct FolderPlaylistMenuButton: View {
    let node: LibraryFolderNode
    let index: LibraryFolderIndex?
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore

    static func supports(_ node: LibraryFolderNode) -> Bool {
        (node.kind == .folder || node.kind == .scanRoot || node.kind == .source)
            && node.sourceID != AppleMusicLibraryIdentity.sourceID
    }

    var body: some View {
        if Self.supports(node),
           let source = sourcesStore.source(id: node.sourceID) {
            let binding = PlaylistFolderBinding(nodeID: node.id, cloudAccountID: source.cloudAccountID)
            let exists = library.playlists.contains { $0.folderBinding == binding }
            Button(
                HomeDiscoveryText.string("folder_as_playlist"),
                systemImage: exists ? "checkmark" : "music.note.list"
            ) {
                guard let index, index.node(withID: node.id) != nil else { return }
                library.createFolderPlaylist(
                    name: HomeDiscoveryText.folderTitle(node), nodeID: node.id,
                    cloudAccountID: source.cloudAccountID,
                    songIDs: index.songIDs(in: node.id, scope: .descendants)
                )
            }
            .disabled(exists || index?.node(withID: node.id) == nil)
            .accessibilityIdentifier("folder.createPlaylist")
        }
    }
}

#if os(macOS)
private struct MacFolderDetailHeader<Navigation: View, Tools: View, Playback: View>: View {
    let title: String
    let detail: String
    let isSource: Bool
    @ViewBuilder let navigation: Navigation
    @ViewBuilder let tools: Tools
    @ViewBuilder let playback: Playback

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                navigation
                Spacer(minLength: 12)
                tools
            }
            .frame(height: 32)
            HStack(spacing: 14) {
                Image(systemName: isSource ? "externaldrive.fill" : "folder.fill")
                    .font(.system(size: 23))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: 48, height: 48)
                    .background(PMColor.brand.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(PMColor.textMuted)
                }
                .lineLimit(1)
                Spacer(minLength: 16)
                playback
            }
        }
        .padding(.horizontal, PMSpace.xxxl)
        .padding(.top, 10)
        .padding(.bottom, 20)
    }
}

private struct MacFolderChildCard: View {
    let title: String
    let detail: String
    let compact: Bool
    let onOpen: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: compact ? 20 : 26))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: compact ? 28 : 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PMColor.text)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .frame(height: compact ? 48 : 68)
            .background(hovered ? PMColor.rowHover : PMColor.card, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(focused ? PMColor.brand : PMColor.cardBorder.opacity(0.5), lineWidth: focused ? 1 : 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
        .help(title)
    }
}

private struct MacFolderSongColumns {
    let width: CGFloat

    var artistWidth: CGFloat? { width >= 560 ? max(110, width * 0.19) : nil }
    var albumWidth: CGFloat? { width >= 780 ? max(140, width * 0.23) : nil }
}

private struct MacFolderSongLine<Artwork: View, Status: View>: View {
    let columns: MacFolderSongColumns
    let number: String
    let title: String
    let artist: String
    let album: String
    let duration: String
    var isHeader = false
    var isCurrent = false
    @ViewBuilder let artwork: Artwork
    @ViewBuilder let status: Status

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isCurrent {
                    Image(systemName: "play.fill").foregroundStyle(PMColor.brand)
                } else {
                    Text(number).monospacedDigit()
                }
            }
            .font(.system(size: 11))
            .frame(width: 32, alignment: .trailing)
            artwork.frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: isHeader ? 11 : 12.5, weight: isHeader ? .regular : .medium))
                    .foregroundStyle(isHeader ? PMColor.textMuted : (isCurrent ? PMColor.brand : PMColor.text))
                if !isHeader, columns.artistWidth == nil, !artist.isEmpty {
                    Text(artist).font(.system(size: 11))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let width = columns.artistWidth {
                Text(artist).frame(width: width, alignment: .leading)
            }
            if let width = columns.albumWidth {
                Text(album).frame(width: width, alignment: .leading)
            }
            Text(duration)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
            status.frame(width: 18)
        }
        .font(.system(size: isHeader ? 11 : 12))
        .foregroundStyle(PMColor.textMuted)
        .lineLimit(1)
        .padding(.horizontal, 10)
    }
}

private struct MacFolderSongColumnsHeader: View {
    let columns: MacFolderSongColumns

    var body: some View {
        MacFolderSongLine(
            columns: columns, number: "#", title: String(localized: "sort_title"),
            artist: String(localized: "sort_artist"), album: String(localized: "sort_album"),
            duration: String(localized: "track_duration_short"), isHeader: true
        ) {
            Color.clear
        } status: {
            Color.clear
        }
        .frame(height: 32)
        .background(PMColor.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityAddTraits(.isHeader)
    }
}

private struct MacFolderOverviewLayout<Pinned: View, Sources: View>: View {
    let hasPins: Bool
    @ViewBuilder let pinned: Pinned
    @ViewBuilder let sources: Sources

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if hasPins {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(HomeDiscoveryText.string("pinned_folders"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PMColor.textMuted)
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 400), spacing: 14)], spacing: 14) {
                            pinned
                        }
                    }
                }
                LazyVStack(spacing: 2) {
                    MacFolderColumnsHeader(title: String(localized: "sources_title"))
                        .padding(.bottom, 6)
                    sources
                }
            }
            .padding(.horizontal, PMSpace.xxxl)
            .padding(.bottom, 112)
        }
    }
}

private struct MacFolderColumnsHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(HomeDiscoveryText.string("folders"))
                .frame(width: 90, alignment: .trailing)
            Text("tab_songs")
                .frame(width: 100, alignment: .trailing)
        }
        .font(.system(size: 11))
        .foregroundStyle(PMColor.textMuted)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

private struct MacFolderPinnedCard<Artwork: View>: View {
    let title: String
    let source: String
    let detail: String
    let canPlay: Bool
    let onOpen: () -> Void
    let onPlay: () -> Void
    @ViewBuilder let artwork: Artwork
    @State private var hovered = false
    @FocusState private var playFocused: Bool

    private var fullTitle: String {
        source.isEmpty || source == title ? title : source + " / " + title
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    artwork.frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(fullTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(PMColor.text)
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(PMColor.textMuted)
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
                .background(hovered ? PMColor.rowHover : PMColor.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(PMColor.cardBorder.opacity(hovered ? 1 : 0.5), lineWidth: 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .help(fullTitle)

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .padding(.leading, 16)
            .focused($playFocused)
            .opacity((hovered || playFocused) && canPlay ? 1 : 0)
            .allowsHitTesting(hovered || playFocused)
            .disabled(!canPlay)
            .accessibilityLabel(String(localized: "play") + " · " + fullTitle)
        }
        .onHover { hovered = $0 }
    }
}

private struct MacFolderDirectoryRow: View {
    let title: String
    let folderCount: Int
    let songCount: Int
    let isSource: Bool
    let onOpen: () -> Void
    let onPlay: () -> Void
    @State private var hovered = false
    @FocusState private var playFocused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: isSource ? "externaldrive.fill" : "folder.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(PMColor.brand)
                        .frame(width: 32, height: 32)
                        .background(PMColor.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(folderCount.formatted())
                        .frame(width: 90, alignment: .trailing)
                    Text(songCount.formatted())
                        .frame(width: 100, alignment: .trailing)
                }
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(PMColor.textMuted)
                .padding(.horizontal, 12)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title + ", " + String(format: HomeDiscoveryText.string("folder_counts"), folderCount, songCount))

            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                    .frame(width: 32, height: 32)
                    .background(PMColor.bgElev, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .padding(.leading, 12)
            .focused($playFocused)
            .opacity((hovered || playFocused) && songCount > 0 ? 1 : 0)
            .allowsHitTesting(hovered || playFocused)
            .disabled(songCount == 0)
            .accessibilityLabel(String(localized: "play") + " · " + title)
        }
        .pmRowBackground()
        .onHover { hovered = $0 }
    }
}

private struct MacFolderScrollReset: ViewModifier {
    let nodeID: LibraryFolderNodeID
    @State private var position = ScrollPosition()

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .task(id: nodeID) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                position.scrollTo(y: 0)
            }
    }
}

private struct MacHomeFolderSongRow: View {
    let songID: String
    let orderedSongIDs: [String]
    let position: Int
    let columns: MacFolderSongColumns
    let performAction: (Song, SongRowActionRequest.Action) -> Void
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourceManager.self) private var sourceManager

    var body: some View {
        // Observe replacements only for rows inside the scroll window.
        if let song = library.visibleSong(id: songID) {
            let isCurrent = player.currentSong?.id == songID
            Button {
                if song.isPlayable {
                    HomeDiscoveryPlayback.play(ids: orderedSongIDs, startingAt: songID, library: library, player: player)
                } else {
                    performAction(song, .unavailable)
                }
            } label: {
                MacFolderSongLine(
                    columns: columns, number: String(position), title: song.title,
                    artist: library.artistDisplayName(for: song) ?? "", album: song.albumTitle ?? "",
                    duration: song.duration > 0 ? song.duration.formattedDuration : "—",
                    isCurrent: isCurrent
                ) {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName, songID: songID,
                        size: 32, cornerRadius: 5,
                        sourceID: song.sourceID, filePath: song.filePath,
                        fileFormat: song.fileFormat
                    )
                } status: {
                    if song.sourceID != AppleMusicLibraryService.systemSourceID {
                        OfflineAudioStatusBadge(snapshot: sourceManager.offlineAudioSnapshotEntry(for: song).snapshot)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .pmRowBackground(selected: isCurrent)
            }
            .buttonStyle(.plain)
            .contextMenu {
                MacHomeFolderSongMenu(song: song) { performAction(song, $0) }
            }
            .task(id: songID) {
                guard song.sourceID != AppleMusicLibraryService.systemSourceID else { return }
                // Skip disk probes for rows that pass through the window during fast scrolling.
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                await sourceManager.ensureOfflineAudioSnapshot(for: song)
            }
        } else {
            Color.clear
        }
    }
}

private struct MacHomeFolderSongMenu: View {
    let song: Song
    let performAction: (SongRowActionRequest.Action) -> Void
    @Environment(SourceManager.self) private var sourceManager
    @Environment(MetadataBackfillService.self) private var backfill

    var body: some View {
        Section {
            Button("scrape_song", systemImage: "wand.and.stars") { performAction(.scrape) }
            Button("tag_editor_menu", systemImage: "tag") { performAction(.editTags) }
            Button("lyrics_editor_menu", systemImage: "quote.bubble") { performAction(.editLyrics) }
            Button("add_to_playlist", systemImage: "text.badge.plus") { performAction(.addToPlaylist) }
            Button("similar_songs", systemImage: "sparkles") { performAction(.similar) }
            if song.sourceID != AppleMusicLibraryService.systemSourceID {
                offlineActions
            }
            if backfill.canRereadTags(for: song) {
                Button(String(localized: backfill.isRereadingTags(songID: song.id) ? "reread_song_tags_in_progress" : "reread_song_tags"),
                       systemImage: "arrow.clockwise") { performAction(.rereadTags) }
                    .disabled(backfill.isRereadingTags(songID: song.id))
            }
            Button("song_info", systemImage: "info.circle") { performAction(.info) }
        }
        Section {
            Button("share", systemImage: "square.and.arrow.up") { performAction(.share) }
        }
    }

    @ViewBuilder
    private var offlineActions: some View {
        let snapshot = sourceManager.offlineAudioSnapshotEntry(for: song).snapshot
        switch snapshot.state {
        case .downloading:
            Button("offline_downloading", systemImage: "arrow.down.circle") {}
                .disabled(true)
        case .pinned:
            Button("offline_remove_song_cache", systemImage: "trash", role: .destructive) {
                sourceManager.removeOfflineDownload(song: song)
            }
        case .cached:
            Button("offline_keep_cached", systemImage: "pin") { sourceManager.downloadForOffline(song: song) }
            Button("offline_remove_cached_file", systemImage: "trash", role: .destructive) {
                sourceManager.removeOfflineDownload(song: song)
            }
        case .failed:
            Button("offline_retry_download", systemImage: "arrow.clockwise") { sourceManager.downloadForOffline(song: song) }
            Button("offline_clear_failed_download", systemImage: "trash", role: .destructive) {
                sourceManager.removeOfflineDownload(song: song)
            }
        case .notCached:
            Button("offline_cache_song", systemImage: "arrow.down.circle") { sourceManager.downloadForOffline(song: song) }
        }
    }
}
#endif

private struct HomeFolderChildLabel: View {
    let node: LibraryFolderNode

    var body: some View {
        HStack(spacing: 12) {
            #if os(macOS)
            HomeFolderArtwork(node: node, size: 32)
            #else
            HomeFolderArtwork(node: node, size: 44)
            #endif
            VStack(alignment: .leading, spacing: 4) {
                Text(HomeDiscoveryText.folderTitle(node)).lineLimit(2)
                Text("\(node.descendantSongCount.formatted()) \(String(localized: "songs_count"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        #if os(macOS)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        #endif
    }
}

@MainActor
enum HomeDiscoveryPlayback {
    static func play(
        ids: [String], startingAt selectedID: String? = nil, shuffle: Bool = false,
        library: MusicLibrary, player: AudioPlayerService
    ) {
        var queue = ids.compactMap { library.unobservedVisibleSong(id: $0) }.filteredPlayable()
        if shuffle { queue.shuffle() }
        guard !queue.isEmpty else { return }
        if let selectedID, !queue.contains(where: { $0.id == selectedID }) { return }
        let position = selectedID.flatMap { id in queue.firstIndex { $0.id == id } } ?? 0
        Task { await player.play(queue: queue, startingAt: position) }
    }
}
