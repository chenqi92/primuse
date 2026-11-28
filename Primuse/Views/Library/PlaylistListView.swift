import SwiftUI
import PrimuseKit

struct PlaylistListView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.libraryStackRegistersCollectionDetails) private var stackRegistersDetails
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    #if os(iOS)
    @Environment(AppleMusicService.self) private var appleMusic
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.appNavigationMode) private var appNavigationMode
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(\.pmIsPhoneIdiom) private var isPhoneIdiomEnvironment
    #endif
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:工具栏按钮带上标题,收进系统溢出菜单时看得懂。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @Environment(\.librarySectionRailActive) private var sectionRailActive
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""
    @State private var newPlaylistDescription = ""
    @State private var showSmartEditor = false
    @State private var showAIEditor = false
    @State private var showPlaylistImport = false
    @State private var showNoScraperSourceAlert = false
    /// 歌单批量管理态。普通态和管理态用两个独立的列表 —— 在同一个 List 上
    /// 混 NavigationLink 与 selection，点一下到底是进歌单还是勾选会变得不确定。
    @State private var isManagingPlaylists = false
    @State private var isOrderingPlaylists = false
    @State private var playlistOrderDraft: [String] = []
    @State private var initialPlaylistOrder: [String] = []
    @AppStorage(PlaylistGrouping.storageKey) private var groupingRawValue = ""
    @State private var expandedGroupID: String?
    @State private var expandedSearchGroupID: String?
    @State private var showsGroupEditor = false
    @State private var editingGroupID: String?
    @State private var groupName = ""
    @State private var groupEditorReferences: [String] = []
    @State private var dissolvingGroup: PlaylistGrouping.Group?
    @State private var playlistSelection: Set<String> = []
    @State private var showCopyToServer = false
    /// 长按「同步歌单」时直接带上的那一个歌单。
    @State private var copyToServerPlaylist: Playlist?
    /// 长按「重命名」的那一个歌单。
    @State private var renamingPlaylist: Playlist?
    @State private var pendingRemoval: PlaylistRemovalRequest?
    @State private var serverMediaShareTarget: ServerMediaShareTarget?
    @State private var shareTargets = PlaylistShareTargets()
    @AppStorage(LibraryPinStorage.defaultsKey) private var favoritesRawValue = ""
    @AppStorage(PlaylistListOrder.storageKey) private var listOrderRawValue = PlaylistListOrder.custom.rawValue
    /// 顶栏排序菜单绑定到稳定 `@State` 存储，避免闭包 `Binding` 在 iOS 18 导航栏反复失效触发主线程卡死。
    @State private var listOrder: PlaylistListOrder = .resolved(
        UserDefaults.standard.string(forKey: PlaylistListOrder.storageKey) ?? PlaylistListOrder.custom.rawValue
    )
    /// 「在本页里找」。只按名字筛三类歌单、顺序不变；管理、排序仍对整份列表。
    @State private var findText = ""
    /// 只看包含本地离线可用曲目的歌单。
    @State private var showsOfflineOnly = false
    /// 含有离线可用曲目的歌单与智能歌单 id(以歌单数为界);还没算好时为 nil(先都列出来)。
    @State private var offlinePlaylistIDs: Set<String>? = nil

    private var effectiveOfflineOnly: Bool {
        showsOfflineOnly || sourceManager.isGlobalOfflineMode
    }

    private var offlineFilterTaskKey: String {
        guard effectiveOfflineOnly else { return "off" }
        return "on-\(library.visibleSongCollectionRevision)-\(library.playlistContentVersion)-\(sourceManager.offlineAudioSnapshotRevision)-\(library.smartPlaylists.count)"
    }

    /// 逐张看歌单里有没有离线能放的歌:普通歌单看成员,智能歌单看在曲库目录上匹配出的那些;
    /// 只探测远程源里的歌,以歌单里的歌为界,不取整库。
    private func refreshOfflinePlaylistIDs() async {
        guard effectiveOfflineOnly else {
            offlinePlaylistIDs = nil
            return
        }
        let localSourceIDs = SourceManager.localDeviceSourceIDs(in: sourcesStore.sources)
        var matched = Set<String>()
        // 模型不在内存里时歌在主线程外从曲库目录分段取;答不了的照样列出来,不当成没有离线的歌(6c 单元 4 U9b)。
        for playlist in playlists {
            let songs = await PlaylistListCatalog.offlineProbeSongs(playlist: playlist, library: library)
            if await PlaylistListCatalog.mayPlayOffline(songs, sourceManager: sourceManager, localSourceIDs: localSourceIDs) {
                matched.insert(playlist.id)
            }
            guard !Task.isCancelled else { return }
        }
        for smart in smartPlaylists {
            let songs = await PlaylistListCatalog.offlineProbeSongs(smart: smart, library: library)
            if await PlaylistListCatalog.mayPlayOffline(songs, sourceManager: sourceManager, localSourceIDs: localSourceIDs) {
                matched.insert(smart.id)
            }
            guard !Task.isCancelled else { return }
        }
        offlinePlaylistIDs = matched
    }

    private func playlistHasOfflineSongs(_ playlist: Playlist) -> Bool {
        guard effectiveOfflineOnly, let ids = offlinePlaylistIDs else { return true }
        return ids.contains(playlist.id)
    }

    private func smartPlaylistHasOfflineSongs(_ smart: SmartPlaylist) -> Bool {
        guard effectiveOfflineOnly, let ids = offlinePlaylistIDs else { return true }
        return ids.contains(smart.id)
    }

    // liked 系统歌单已作为「资料库 · 我喜欢的」固定入口展示, 歌单总览里不再重复列出。
    private var playlists: [Playlist] {
        library.playlists.filter { $0.id != MusicLibrary.likedSongsPlaylistID }
    }
    private var smartPlaylists: [SmartPlaylist] { library.smartPlaylists }
    private var selectedPlaylistIDs: Set<String> {
        playlistSelection.intersection(playlists.map(\.id))
    }
    private var selectedSmartPlaylistIDs: Set<String> {
        Set(smartPlaylists.filter {
            playlistSelection.contains(PlaylistGrouping.reference(id: $0.id, smart: true))
        }.map(\.id))
    }
    private var aiSmartPlaylists: [SmartPlaylist] {
        smartPlaylists.filter { $0.effectiveKind == .ai }
    }
    private var ruleSmartPlaylists: [SmartPlaylist] {
        smartPlaylists.filter { $0.effectiveKind == .rules }
    }
    private var findQuery: LibraryFindPolicy.Query? { LibraryFindPolicy.query(findText) }

    private func shown<Item>(_ items: [Item], name: (Item) -> String) -> [Item] {
        guard let query = findQuery else { return items }
        return items.filter { LibraryFindPolicy.matches(query, fields: [name($0)]) }
    }

    /// 按页面选的排序方式摆好的歌单;「自定义顺序」就是 `playlists` 本身。
    private func ordered(_ items: [Playlist]) -> [Playlist] {
        listOrder.sorted(items) { library.songCount(forPlaylist: $0) }
    }

    private var shownPlaylists: [Playlist] {
        ordered(shown(playlists.filter(playlistHasOfflineSongs), name: \.name))
    }

    private var operationAvailability: PlaylistOperationAvailability {
        #if os(tvOS)
        .television
        #else
        .standard
        #endif
    }

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            iosBody
            #endif
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isManagingPlaylists {
                playlistManageBar
                    .padding(.bottom, playlistManageBottomClearance)
                    // 曲线附在过渡上: 进出管理态是裸赋值, 不能为了驱动它
                    // 去包 withAnimation —— 那会把整块歌单列表拉进事务。
                    .pmSlideTransition(edge: .bottom, motion: .list)
            }
        }
        .playlistRemovalAlert($pendingRemoval) { _ in
            playlistSelection = []
            isManagingPlaylists = false
        }
        .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
        .sheet(isPresented: $showPlaylistImport) {
            #if os(iOS)
            NavigationStack {
                PlaylistImportView()
            }
            #else
            PlaylistImportView()
            #endif
        }
        .sheet(item: $serverMediaShareTarget) { target in
            ServerMediaShareSheet(target: target)
        }
        .sheet(isPresented: $showCopyToServer) {
            // 不预选: 面板里先勾要同步的歌单, Apple Music 和别的服务器上的歌单也能选。
            PlaylistCopyToServerSheet(playlistIDs: [])
        }
        .sheet(item: $copyToServerPlaylist) { playlist in
            PlaylistCopyToServerSheet(playlistIDs: [playlist.id])
        }
        .alert(LocalizedStringKey(editingGroupID == nil ? "playlist_group_new" : "playlist_group_rename"), isPresented: $showsGroupEditor) {
            TextField("playlist_group_name", text: $groupName)
            Button("cancel", role: .cancel) {}
            Button("save") { saveGroup() }
                .disabled(!grouping.acceptsName(groupName, replacing: editingGroupID))
        }
        .confirmationDialog("playlist_group_dissolve", isPresented: Binding(
            get: { dissolvingGroup != nil },
            set: { if !$0 { dissolvingGroup = nil } }
        ), titleVisibility: .visible) {
            if let group = dissolvingGroup {
                Button("playlist_group_dissolve", role: .destructive) {
                    var updated = grouping
                    updated.dissolve(id: group.id)
                    groupingRawValue = updated.encoded()
                    if expandedGroupID == group.id { expandedGroupID = nil }
                    if expandedSearchGroupID == group.id { expandedSearchGroupID = nil }
                    dissolvingGroup = nil
                }
            }
        } message: {
            Text("playlist_group_dissolve_message")
        }
        .onChange(of: findText) { _, _ in
            if isOrderingPlaylists { finishPlaylistOrder(save: false) }
            if findQuery != nil {
                let matches = pageSections.groups
                let preferred = expandedSearchGroupID ?? expandedGroupID
                expandedSearchGroupID = matches.contains { $0.id == preferred } ? preferred : matches.first?.id
            } else {
                expandedSearchGroupID = nil
            }
        }
        .onChange(of: listOrderRawValue, initial: true) { _, rawValue in
            let resolved = PlaylistListOrder.resolved(rawValue)
            if listOrder != resolved { listOrder = resolved }
        }
        .onChange(of: listOrder) { _, order in
            if listOrderRawValue != order.rawValue { listOrderRawValue = order.rawValue }
        }
        .task(id: offlineFilterTaskKey) {
            await refreshOfflinePlaylistIDs()
        }
        .onDisappear {
            if isOrderingPlaylists { finishPlaylistOrder(save: false) }
        }
    }

    /// 有能写歌单的音乐服务器时才给「同步歌单」的入口。
    private var canCopyToServer: Bool {
        !ServerPlaylistCopyService.targetSources(sourcesStore: sourcesStore).isEmpty
    }

    /// 顺序只在有得排的时候才给入口。
    private var canReorderPlaylists: Bool { playlists.count >= 2 }

    private var grouping: PlaylistGrouping { PlaylistGrouping.decode(groupingRawValue) }

    private var pagePlaylists: [Playlist] {
        guard isOrderingPlaylists else { return shownPlaylists }
        let byID = Dictionary(playlists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return playlistOrderDraft.compactMap { byID[$0] }
    }

    private struct GroupSection: Identifiable {
        let group: PlaylistGrouping.Group
        let playlists: [Playlist]
        let smartPlaylists: [SmartPlaylist]
        var id: String { group.id }
        var count: Int { playlists.count + smartPlaylists.count }
    }

    private struct PageSections {
        let groups: [GroupSection]
        let ungroupedPlaylists: [Playlist]
        let ungroupedAISmartPlaylists: [SmartPlaylist]
        let ungroupedRuleSmartPlaylists: [SmartPlaylist]

        var isEmpty: Bool {
            groups.isEmpty && ungroupedPlaylists.isEmpty
                && ungroupedAISmartPlaylists.isEmpty && ungroupedRuleSmartPlaylists.isEmpty
        }
    }

    private var pageSections: PageSections {
        let state = grouping
        let groupIDs = Set(state.groups.map(\.id))
        func groupID(for reference: String) -> String? {
            guard let id = state.memberships[reference], groupIDs.contains(id) else { return nil }
            return id
        }
        let ordinary = Dictionary(grouping: pagePlaylists) { groupID(for: PlaylistGrouping.reference(id: $0.id)) }
        let smart = Dictionary(grouping: shown(smartPlaylists.filter(smartPlaylistHasOfflineSongs), name: \.name)) {
            groupID(for: PlaylistGrouping.reference(id: $0.id, smart: true))
        }
        let isFiltering = findQuery != nil || effectiveOfflineOnly
        let groups = state.groups.compactMap { group -> GroupSection? in
            let section = GroupSection(
                group: group, playlists: ordinary[group.id] ?? [], smartPlaylists: smart[group.id] ?? []
            )
            return isFiltering && section.count == 0 ? nil : section
        }
        let ungroupedSmart = smart[nil] ?? []
        return PageSections(
            groups: groups,
            ungroupedPlaylists: ordinary[nil] ?? [],
            ungroupedAISmartPlaylists: ungroupedSmart.filter { $0.effectiveKind == .ai },
            ungroupedRuleSmartPlaylists: ungroupedSmart.filter { $0.effectiveKind == .rules }
        )
    }

    private var visibleExpandedGroupID: String? {
        findQuery == nil ? expandedGroupID : expandedSearchGroupID
    }

    private func setExpandedGroup(_ id: String?) {
        if findQuery == nil { expandedGroupID = id }
        else { expandedSearchGroupID = id }
    }

    private func beginPlaylistOrder() {
        initialPlaylistOrder = shownPlaylists.map(\.id)
        playlistOrderDraft = initialPlaylistOrder
        isManagingPlaylists = false
        playlistSelection = []
        isOrderingPlaylists = true
    }

    private func finishPlaylistOrder(save: Bool) {
        let available = Set(playlists.map(\.id))
        if save, playlistOrderDraft.filter(available.contains) != initialPlaylistOrder.filter(available.contains) {
            let merged = PlaylistMemberOrderPolicy.reordered(
                ordered(playlists).map(\.id), listedOrder: playlistOrderDraft
            )
            library.reorderPlaylists(merged)
            listOrder = .custom
            listOrderRawValue = PlaylistListOrder.custom.rawValue
        }
        isOrderingPlaylists = false
        playlistOrderDraft = []
        initialPlaylistOrder = []
    }

    private func movePlaylists(_ items: [Playlist], from: IndexSet, to: Int) {
        guard isOrderingPlaylists, from.allSatisfy(items.indices.contains), (0...items.count).contains(to) else { return }
        var ids = items.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        playlistOrderDraft = PlaylistMemberOrderPolicy.reordered(playlistOrderDraft, listedOrder: ids)
    }

    @ViewBuilder
    private func playlistSections(_ sections: PageSections) -> some View {
        ForEach(sections.groups) { section in
            Section {
                if visibleExpandedGroupID == section.id {
                    playlistRows(section.playlists)
                    ForEach(section.smartPlaylists) { smart in
                        smartPlaylistLink(smart)
                    }
                    if section.count == 0 {
                        Text("no_playlists").foregroundStyle(.secondary)
                    }
                }
            } header: {
                groupHeader(section)
            }
        }
        if !sections.ungroupedAISmartPlaylists.isEmpty {
            Section("ai_smart_playlists_section") {
                ForEach(sections.ungroupedAISmartPlaylists) { smart in smartPlaylistLink(smart) }
            }
        }
        if !sections.ungroupedRuleSmartPlaylists.isEmpty {
            Section("rule_smart_playlists_section") {
                ForEach(sections.ungroupedRuleSmartPlaylists) { smart in smartPlaylistLink(smart) }
            }
        }
        if !sections.ungroupedPlaylists.isEmpty {
            Section {
                playlistRows(sections.ungroupedPlaylists)
            } header: {
                if !grouping.groups.isEmpty {
                    Text("playlist_group_ungrouped")
                } else if !smartPlaylists.isEmpty {
                    Text("playlists_section")
                }
            }
        }
    }

    private func playlistRows(_ items: [Playlist]) -> some View {
        ForEach(items) { playlist in
            if isOrderingPlaylists {
                playlistRow(playlist)
                    #if os(macOS)
                    .overlay(alignment: .trailing) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                    }
                    #endif
            } else {
                NavigationLink(value: playlist) { playlistRow(playlist) }
                    .mediaZoomSource(.playlist, id: playlist.id)
                    // 左滑仅弹出确认框而非立即删行，不能走 onDelete 或 destructive role，否则 UIKit 会按已删行提交动画导致集合视图断言崩溃。
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if playlist.id != MusicLibrary.likedSongsPlaylistID {
                            Button {
                                pendingRemoval = PlaylistRemovalRequest(playlists: [playlist])
                            } label: {
                                Label("delete", systemImage: "trash")
                            }
                            .tint(.red)
                        }
                    }
                    .contextMenu {
                        favoriteToggleButton(for: playlist)
                        PlaylistRenameButton(playlist: playlist) { renamingPlaylist = playlist }
                        groupMoveMenu(references: [PlaylistGrouping.reference(id: playlist.id)])
                        serverMediaShareButton(for: playlist)
                        copyToServerButton(for: playlist)
                        playlistRemovalButtons(for: playlist)
                    }
            }
        }
        .onMove { movePlaylists(items, from: $0, to: $1) }
        .moveDisabled(!isOrderingPlaylists)
    }

    private func smartPlaylistLink(_ smart: SmartPlaylist) -> some View {
        NavigationLink(value: smart) { smartPlaylistRow(smart) }
            .disabled(isOrderingPlaylists)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !isOrderingPlaylists {
                    Button {
                        pendingRemoval = PlaylistRemovalRequest(smartPlaylistIDs: [smart.id])
                    } label: {
                        Label("delete", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
            .contextMenu { if !isOrderingPlaylists { smartPlaylistContextMenu(smart) } }
    }

    @ViewBuilder
    private func smartPlaylistContextMenu(_ smart: SmartPlaylist) -> some View {
        SmartPlaylistIntentPinButton(playlistID: smart.id)
        groupMoveMenu(references: [PlaylistGrouping.reference(id: smart.id, smart: true)])
        Divider()
        Button(role: .destructive) {
            pendingRemoval = PlaylistRemovalRequest(smartPlaylistIDs: [smart.id])
        } label: {
            Label("delete_playlist", systemImage: "trash")
        }
    }

    private func groupHeader(_ section: GroupSection) -> some View {
        let group = section.group
        let isExpanded = visibleExpandedGroupID == group.id
        return HStack(spacing: 8) {
            Button {
                setExpandedGroup(isExpanded ? nil : group.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text(verbatim: group.name)
                    Spacer()
                    Text(verbatim: section.count.formatted())
                        .monospacedDigit()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(LocalizedStringKey(
                isExpanded ? "library_release_date_expanded" : "library_release_date_collapsed"
            )))
            .accessibilityIdentifier("playlistGroup.toggle.\(group.id)")
            Menu {
                Button { playGroup(group.id) } label: {
                    Label("play_all", systemImage: "play.fill")
                }
                .disabled(section.count == 0)
                Divider()
                Button("playlist_group_rename") { editGroup(group) }
                Button("playlist_group_dissolve", role: .destructive) { dissolvingGroup = group }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(verbatim: group.name + ", ") + Text("a11y_more_actions"))
            .accessibilityIdentifier("playlistGroup.more.\(group.id)")
            .disabled(isOrderingPlaylists)
        }
        .textCase(nil)
    }

    private func playGroup(_ id: String) {
        let groups = grouping
        let orderedPlaylists = ordered(playlists)
        let smarts = smartPlaylists
        Task {
            // 分组里的智能歌单先在曲库目录上匹配好(主线程外),再按分组里的先后接起来。
            var smartSongIDs: [String: [String]] = [:]
            for smart in smarts
            where groups.groupID(for: PlaylistGrouping.reference(id: smart.id, smart: true)) == id {
                // AI 歌单在模型不在内存里时先装回来再对;答不了就不播,不当成空歌单(U9b)。
                guard let ids = await PlaylistListCatalog.matchedSongIDs(smart, library: library) else { return }
                smartSongIDs[smart.id] = ids
            }
            let songIDs = groups.playbackSongIDs(
                for: id, playlists: orderedPlaylists, smartPlaylists: smarts,
                songIDsForPlaylist: { library.songIDs(forPlaylist: $0.id) },
                songIDsForSmartPlaylist: { smartSongIDs[$0.id] ?? [] }
            )
            guard !songIDs.isEmpty else { return }
            await player.play(queueIDs: songIDs)
        }
    }

    private func groupMoveMenu(references: [String]) -> some View {
        Menu {
            Button("playlist_group_ungrouped") { moveToGroup(references, groupID: nil) }
            ForEach(grouping.groups) { group in
                Button { moveToGroup(references, groupID: group.id) } label: {
                    if references.allSatisfy({ grouping.groupID(for: $0) == group.id }) {
                        Label(group.name, systemImage: "checkmark")
                    } else {
                        Text(verbatim: group.name)
                    }
                }
            }
            Divider()
            Button("playlist_group_new") { editGroup(references: references) }
        } label: {
            Label("playlist_group_move", systemImage: "folder")
        }
    }

    private func moveToGroup(_ references: [String], groupID: String?) {
        var updated = grouping
        updated.move(references, to: groupID)
        groupingRawValue = updated.encoded()
        if let groupID { setExpandedGroup(groupID) }
    }

    private func editGroup(_ group: PlaylistGrouping.Group? = nil, references: [String] = []) {
        editingGroupID = group?.id
        groupName = group?.name ?? ""
        groupEditorReferences = references
        showsGroupEditor = true
    }

    private func saveGroup() {
        var updated = grouping
        if let id = editingGroupID {
            updated.rename(id: id, name: groupName)
        } else if let id = updated.create(name: groupName) {
            updated.move(groupEditorReferences, to: id)
            setExpandedGroup(id)
        }
        groupingRawValue = updated.encoded()
    }

    @ViewBuilder
    private var iosBody: some View {
        Group {
            if playlists.isEmpty && smartPlaylists.isEmpty && grouping.groups.isEmpty {
                EmptyStateView(
                    titleKey: "no_playlists",
                    descriptionKey: "no_playlists_desc",
                    systemImage: "music.note.list",
                    actionLabel: "new_playlist",
                    action: { showNewPlaylist = true }
                )
            } else if isManagingPlaylists {
                playlistManageList
            } else {
                let sections = pageSections
                List { playlistSections(sections) }
                #if os(iOS)
                .environment(\.editMode, .constant(isOrderingPlaylists ? .active : .inactive))
                #endif
                .overlay {
                    if findQuery != nil && sections.isEmpty {
                        ContentUnavailableView.search(text: findText)
                    }
                }
                #if os(iOS)
                .libraryPageFind(text: $findText, prompt: "filter_playlists_placeholder")
                #endif
            }
        }
        .toolbar {
            if isOrderingPlaylists {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { finishPlaylistOrder(save: false) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { finishPlaylistOrder(save: true) }
                        .fontWeight(.semibold)
                }
            } else if isManagingPlaylists {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done") {
                        isManagingPlaylists = false
                        playlistSelection = []
                    }
                }
            } else if sectionRailActive {
                // 资料库分类在 Duo 竖栏里时「+」与「⋯」并成一个「⋯」,竖栏中间留给分类。
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        playlistAddItems
                        if !playlists.isEmpty || !smartPlaylists.isEmpty {
                            Divider()
                            playlistMoreItems
                        }
                    } label: {
                        PMToolbarItemLabel("a11y_more_actions", systemImage: "ellipsis", titled: true)
                    }
                    .accessibilityIdentifier("playlists.more")
                }
            } else {
                // 「+」只管新建与导入；整理已有歌单（调整顺序、多选）放进旁边的「⋯」。
                ToolbarItem(placement: .topBarTrailing) {
                    playlistAddMenu(titled: verticalBarEdge != nil)
                }
                if !playlists.isEmpty || !smartPlaylists.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        playlistMoreMenu(titled: verticalBarEdge != nil)
                    }
                }
            }
        }
        #if os(iOS)
        .navigationBarBackButtonHidden(isOrderingPlaylists)
        // 极简模式根页没有导航栏：歌单数与上面两颗键排成页头。
        .minimalPageHeader {
            HStack(spacing: 4) {
                MinimalHeaderCount(text: playlistCountText)
                Spacer(minLength: 8)
                if isOrderingPlaylists {
                    Button("cancel") { finishPlaylistOrder(save: false) }
                    Button("done") { finishPlaylistOrder(save: true) }
                        .fontWeight(.semibold)
                } else if isManagingPlaylists {
                    Button {
                        isManagingPlaylists = false
                        playlistSelection = []
                    } label: {
                        Text("done")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    MinimalHeaderActions {
                        MinimalPageFindButton()
                        playlistAddMenu(titled: false)
                        if !playlists.isEmpty || !smartPlaylists.isEmpty {
                            playlistMoreMenu(titled: false)
                        }
                    }
                }
            }
        }
        #endif
        .alert("new_playlist", isPresented: $showNewPlaylist) {
            TextField("playlist_name", text: $newPlaylistName)
            Button("cancel", role: .cancel) { newPlaylistName = "" }
            Button("create") { createPlaylist() }
        }
        .playlistRenameAlert($renamingPlaylist)
        .sheet(isPresented: $showSmartEditor) {
            SmartPlaylistEditorView(existing: nil)
        }
        .sheet(isPresented: $showAIEditor) {
            AIPlaylistEditorView(existing: nil)
        }
        .modifier(SmartPlaylistDestinationModifier(isRegistered: stackRegistersDetails))
    }

    /// 管理态的多选列表。`editMode` 常开 —— 用户点「选择」就是来批量处理的，
    /// 再要求他在里面点一次才出现勾选圈，中间那个状态看着像坏了。
    private var playlistManageList: some View {
        List(selection: $playlistSelection) {
            if !smartPlaylists.isEmpty {
                Section("smart_playlists_section") {
                    ForEach(smartPlaylists) { smart in
                        smartPlaylistRow(smart)
                            .tag(PlaylistGrouping.reference(id: smart.id, smart: true))
                    }
                }
            }
            Section {
                ForEach(ordered(playlists)) { playlist in
                    playlistRow(playlist)
                        .tag(playlist.id)

                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    private var playlistManageBar: some View {
        HStack(spacing: 12) {
            Text(verbatim: String(
                format: String(localized: "batch_playlists_selected_count_format"),
                playlistSelection.count
            ))
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()

            Spacer(minLength: 8)

            Button("batch_select_all") {
                playlistSelection = Set(playlists.map(\.id) + smartPlaylists.map {
                    PlaylistGrouping.reference(id: $0.id, smart: true)
                })
            }
            .font(.subheadline)

            groupMoveMenu(references: selectedPlaylistIDs.map { PlaylistGrouping.reference(id: $0) }
                          + selectedSmartPlaylistIDs.map { PlaylistGrouping.reference(id: $0, smart: true) })
                .disabled(playlistSelection.isEmpty)

            Button(role: .destructive) {
                pendingRemoval = PlaylistRemovalRequest(
                    playlists: playlists.filter { selectedPlaylistIDs.contains($0.id) },
                    smartPlaylistIDs: selectedSmartPlaylistIDs
                )
            } label: {
                Label("delete", systemImage: "trash")
            }
            .disabled(playlistSelection.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var playlistAddItems: some View {
        Button {
            showNewPlaylist = true
        } label: {
            Label("new_playlist", systemImage: "music.note.list")
        }
        Button {
            showAIEditor = true
        } label: {
            Label("new_ai_smart_playlist", systemImage: "sparkles")
        }
        Button {
            showSmartEditor = true
        } label: {
            Label("new_rule_smart_playlist", systemImage: "slider.horizontal.3")
        }
        Button {
            editGroup()
        } label: {
            Label("playlist_group_new", systemImage: "folder.badge.plus")
        }
        if operationAvailability.supportsImport {
            Divider()
            Button {
                showPlaylistImport = true
            } label: {
                Label("playlist_import_title", systemImage: "tray.and.arrow.down")
            }
        }
    }

    /// 新建歌单、AI 歌单、规则歌单与导入。
    private func playlistAddMenu(titled: Bool) -> some View {
        Menu {
            playlistAddItems
        } label: {
            PMToolbarItemLabel("new_playlist", systemImage: "plus", titled: titled)
        }
        .accessibilityIdentifier("playlists.new")
    }

    @ViewBuilder
    private var playlistMoreItems: some View {
        Toggle(
            isOn: Binding(
                get: { effectiveOfflineOnly },
                set: { if !sourceManager.isGlobalOfflineMode { showsOfflineOnly = $0 } }
            )
        ) {
            Label("filter_offline_available", systemImage: "wifi.slash")
        }
        .disabled(sourceManager.isGlobalOfflineMode)
        if canReorderPlaylists {
            Menu {
                PlaylistListSortMenuItems(order: $listOrder)
            } label: {
                Label("sort_by", systemImage: "arrow.up.arrow.down")
            }
            Button {
                beginPlaylistOrder()
            } label: {
                Label("playlist_order_action", systemImage: "line.3.horizontal")
            }
        }
        Button {
            isManagingPlaylists = true
        } label: {
            Label("batch_select", systemImage: "checkmark.circle")
        }
        if canCopyToServer {
            Button {
                showCopyToServer = true
            } label: {
                Label("server_playlist_copy_action", systemImage: "server.rack")
            }
        }
    }

    /// 排序方式、调整顺序与多选。
    private func playlistMoreMenu(titled: Bool) -> some View {
        Menu {
            playlistMoreItems
        } label: {
            PMToolbarItemLabel("a11y_more_actions", systemImage: "ellipsis", titled: titled)
        }
        .accessibilityIdentifier("playlists.more")
    }

    private var playlistCountText: String {
        LibraryCountText.playlists(playlists.count + smartPlaylists.count)
    }

    #if os(iOS)
    /// iPhone 上常规宽度、常规高度的画布（iPhone Duo 内屏）。
    private var isPhoneRegularCanvas: Bool {
        (isPhoneIdiomEnvironment || UIDevice.current.userInterfaceIdiom == .phone)
            && horizontalSizeClass == .regular
            && !heightClass.isCompact
    }
    #endif

    private var playlistManageBottomClearance: CGFloat {
        #if os(iOS)
        guard player.currentSong != nil || appleMusic.nowPlayingSong != nil else {
            return 0
        }
        if appNavigationMode == .minimal { return 0 }
        // 68 是 iPad 分栏外壳里那条自绘迷你条的高度。iPhone Duo 展开的内屏也是常规宽高，
        // 但它用的是 iPhone 的标签栏与系统附件，照 iPhone 那一支让位。
        if horizontalSizeClass == .regular && !isPhoneRegularCanvas { return 68 }
        if #available(iOS 26.1, *) { return 0 }
        return 52
        #else
        return 0
        #endif
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        let summary = library.songSummary(forPlaylist: playlist.id)
        return HStack(spacing: 12) {
            PlaylistArtworkView(playlist: playlist, size: 48, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name).font(.body)
                HStack(spacing: 4) {
                    Text(String(
                        format: String(localized: "carplay_playlist_song_count_format"),
                        summary.count
                    ))
                    Text("·")
                    Text(playlist.updatedAt, style: .date)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func smartPlaylistRow(_ smart: SmartPlaylist) -> some View {
        let isAI = smart.effectiveKind == .ai
        return HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: isAI
                            ? [.pink.opacity(0.78), .orange.opacity(0.72)]
                            : [.purple.opacity(0.7), .blue.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Image(systemName: isAI ? "sparkles" : "slider.horizontal.3")
                    .font(.title3)
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(smart.name).font(.body)
                Text(smartPlaylistSubtitle(smart))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func smartPlaylistSubtitle(_ smart: SmartPlaylist) -> String {
        if smart.effectiveKind == .ai {
            return "\(LibraryCountText.songs(smart.aiConfiguration?.selections.count ?? 0)) · AI"
        }
        return LibraryCountText.rules(smart.ruleCount)
    }

    #if os(macOS)
    @ViewBuilder
    private func macSmartPlaylistCard(_ smart: SmartPlaylist) -> some View {
        let reference = PlaylistGrouping.reference(id: smart.id, smart: true)
        if isManagingPlaylists {
            smartPlaylistCard(smart)
                .overlay(alignment: .topTrailing) {
                    SongSelectionCheckmark(isSelected: playlistSelection.contains(reference))
                        .padding(10)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if playlistSelection.contains(reference) { playlistSelection.remove(reference) }
                    else { playlistSelection.insert(reference) }
                }
        } else {
            NavigationLink(value: smart) { smartPlaylistCard(smart) }
                .buttonStyle(.plain)
                .pmHoverLift()
                .contextMenu { smartPlaylistContextMenu(smart) }
        }
    }

    private func macGroupedPlaylists(_ groups: [GroupSection]) -> some View {
        ForEach(groups) { section in
            VStack(alignment: .leading, spacing: 10) {
                groupHeader(section)
                    .font(.subheadline.weight(.semibold))
                if visibleExpandedGroupID == section.id {
                    LazyVGrid(columns: macPlaylistGridColumns, alignment: .leading, spacing: 12) {
                        ForEach(section.playlists) { playlist in
                            if isManagingPlaylists {
                                playlistCard(playlist)
                                    .overlay(alignment: .topTrailing) {
                                        SongSelectionCheckmark(isSelected: playlistSelection.contains(playlist.id))
                                            .padding(10)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if playlistSelection.contains(playlist.id) { playlistSelection.remove(playlist.id) }
                                        else { playlistSelection.insert(playlist.id) }
                                    }
                            } else {
                                NavigationLink(value: playlist) { playlistCard(playlist) }
                                    .buttonStyle(.plain)
                                    .contextMenu { playlistContextMenu(for: playlist) }
                                    .pmHoverLift()
                            }
                        }
                        ForEach(section.smartPlaylists) { smart in
                            macSmartPlaylistCard(smart)
                        }
                    }
                    if section.count == 0 {
                        Text("no_playlists").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var macBody: some View {
        if isOrderingPlaylists {
            VStack(spacing: 16) {
                HStack {
                    Text("tab_playlists").font(.largeTitle.bold())
                    Spacer()
                    Button("cancel") { finishPlaylistOrder(save: false) }
                    Button("done") { finishPlaylistOrder(save: true) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 36)
                .padding(.top, 32)
                List { playlistSections(pageSections) }
                    .listStyle(.plain)
            }
            .background(PMColor.bg.ignoresSafeArea())
        } else {
            macBrowseBody
        }
    }

    private var macBrowseBody: some View {
        let sections = pageSections
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                macPlaylistsHeader

                if playlists.isEmpty && smartPlaylists.isEmpty && grouping.groups.isEmpty {
                    ContentUnavailableView(
                        "no_playlists",
                        systemImage: "music.note.list",
                        description: Text("no_playlists_desc")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else if findQuery != nil && sections.isEmpty {
                    ContentUnavailableView.search(text: findText)
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    playlistOverview
                    macGroupedPlaylists(sections.groups)

                    if !sections.ungroupedAISmartPlaylists.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            macSubsectionTitle("ai_smart_playlists_section")
                            LazyVGrid(
                                columns: macPlaylistGridColumns,
                                alignment: .leading,
                                spacing: 12
                            ) {
                                ForEach(sections.ungroupedAISmartPlaylists) { smart in
                                    macSmartPlaylistCard(smart)
                                }
                            }
                        }
                        .pmFadeTransition(motion: .contentAppear)
                    }

                    if !sections.ungroupedRuleSmartPlaylists.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            macSubsectionTitle("rule_smart_playlists_section")
                            LazyVGrid(
                                columns: macPlaylistGridColumns,
                                alignment: .leading,
                                spacing: 12
                            ) {
                                ForEach(sections.ungroupedRuleSmartPlaylists) { smart in
                                    macSmartPlaylistCard(smart)
                                }
                            }
                        }
                        .pmFadeTransition(motion: .contentAppear)
                    }

                    if !sections.ungroupedPlaylists.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            if !grouping.groups.isEmpty {
                                macSubsectionTitle("playlist_group_ungrouped")
                            } else if !smartPlaylists.isEmpty {
                                macSubsectionTitle("playlists_section")
                            }

                            LazyVGrid(
                                columns: macPlaylistGridColumns,
                                alignment: .leading,
                                spacing: 12
                            ) {
                                ForEach(sections.ungroupedPlaylists) { playlist in
                                    if isManagingPlaylists {
                                        playlistCard(playlist)
                                            .overlay(alignment: .topTrailing) {
                                                SongSelectionCheckmark(
                                                        isSelected: playlistSelection.contains(playlist.id)
                                                    )
                                                    .padding(10)
                                            }
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                if playlistSelection.contains(playlist.id) {
                                                    playlistSelection.remove(playlist.id)
                                                } else {
                                                    playlistSelection.insert(playlist.id)
                                                }
                                            }
                                    } else {
                                        NavigationLink(value: playlist) {
                                            playlistCard(playlist)
                                        }
                                        .buttonStyle(.plain)
                                        .contextMenu {
                                            playlistContextMenu(for: playlist)
                                        }
                                        .pmHoverLift()
                                    }
                                }
                            }
                        }
                        .pmFadeTransition(motion: .contentAppear)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 32)
            .padding(.bottom, 112)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .sheet(isPresented: $showNewPlaylist) {
            MacNewPlaylistSheet(
                name: $newPlaylistName,
                description: $newPlaylistDescription,
                onCancel: {
                    newPlaylistName = ""
                    newPlaylistDescription = ""
                    showNewPlaylist = false
                },
                onCreate: { name in
                    _ = library.createPlaylist(name: name, descriptionText: newPlaylistDescription)
                    newPlaylistName = ""
                    newPlaylistDescription = ""
                    showNewPlaylist = false
                }
            )
        }
        .sheet(isPresented: $showSmartEditor) {
            SmartPlaylistEditorView(existing: nil)
        }
        .sheet(isPresented: $showAIEditor) {
            AIPlaylistEditorView(existing: nil)
        }
    }

    /// 窄窗口保持单列；正文变宽后自动增加列数，避免列表固定在左侧而让右侧闲置。
    /// 380pt 仍足以容纳封面、两行信息和尾部操作，同时在常见宽屏下形成 2–3 列。
    private var macPlaylistGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 380), spacing: 12, alignment: .top)]
    }

    /// 页头右侧: 查找、排序、选择、同步歌单, 最右是「新建歌单」。新建的几种(普通、AI、规则、分组、导入)
    /// 收在这一颗品牌色键里, 和 iPhone 的「+」菜单、电台页的「添加电台」同一个排法;
    /// 以前五颗大小不一的键(其中「新建分组」还是系统按钮)摆成一排, 窄窗口里放不下。
    private var macPlaylistsHeader: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("library")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(PMColor.textMuted)
                Text("tab_playlists")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if !playlists.isEmpty || !smartPlaylists.isEmpty {
                    MacLibraryFindField(text: $findText, prompt: "filter_playlists_placeholder", width: 180)
                    MacControlIconButton(
                        systemImage: "wifi.slash",
                        help: "filter_offline_available",
                        style: effectiveOfflineOnly ? .selected : .glass
                    ) {
                        if !sourceManager.isGlobalOfflineMode {
                            showsOfflineOnly.toggle()
                        }
                    }
                    .disabled(sourceManager.isGlobalOfflineMode)
                }

                if canReorderPlaylists {
                    macSortMenu
                }

                if !playlists.isEmpty || !smartPlaylists.isEmpty {
                    MacControlIconButton(
                        systemImage: isManagingPlaylists ? "xmark" : "checkmark.circle",
                        help: isManagingPlaylists ? LocalizedStringKey("done") : "batch_select",
                        style: isManagingPlaylists ? .selected : .glass
                    ) {
                        isManagingPlaylists.toggle()
                        if !isManagingPlaylists { playlistSelection = [] }
                    }
                    // 事务只罩住这枚按钮 —— 进出管理态会重排整块歌单网格,
                    // 在调用点包 withAnimation 会把它们一起拖进来。
                    .pmAnimation(.control, value: isManagingPlaylists)
                }

                if canCopyToServer {
                    MacControlIconButton(systemImage: "server.rack", help: "server_playlist_copy_action") {
                        showCopyToServer = true
                    }
                }

                macNewMenu
            }
        }
    }

    private var macNewMenu: some View {
        Menu {
            Button {
                showNewPlaylist = true
            } label: {
                Label("new_playlist", systemImage: "music.note.list")
            }
            Button {
                showAIEditor = true
            } label: {
                Label("new_ai_smart_playlist", systemImage: "sparkles")
            }
            Button {
                showSmartEditor = true
            } label: {
                Label("new_rule_smart_playlist", systemImage: "slider.horizontal.3")
            }
            Button {
                editGroup()
            } label: {
                Label("playlist_group_new", systemImage: "folder.badge.plus")
            }
            if operationAvailability.supportsImport {
                Divider()
                Button {
                    showPlaylistImport = true
                } label: {
                    Label("playlist_import_title", systemImage: "tray.and.arrow.down")
                }
            }
        } label: {
            MacControlMenuLabel("new_playlist", systemImage: "plus", style: .prominent)
        }
        .macControlMenuStyle()
        .accessibilityIdentifier("playlists.new")
    }

    /// 排序方式和「调整歌单顺序」收在一颗键里, 键上写着当前怎么排。
    private var macSortMenu: some View {
        Menu {
            PlaylistListSortMenuItems(order: $listOrder)
            Section {
                Button {
                    beginPlaylistOrder()
                } label: {
                    Label("playlist_order_action", systemImage: "line.3.horizontal")
                }
            }
        } label: {
            MacControlMenuLabel(verbatim: listOrder.label, systemImage: "arrow.up.arrow.down")
        }
        .macControlMenuStyle()
        .help(Text("sort_by"))
    }

    private var playlistOverview: some View {
        HStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(PMColor.brand)
                .frame(width: 52, height: 52)
                .background(PMColor.brand.opacity(0.14), in: .rect(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text("tab_playlists")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text("\(playlists.count) \(String(localized: "playlists_section")) · \(aiSmartPlaylists.count) \(String(localized: "ai_smart_playlists_section")) · \(ruleSmartPlaylists.count) \(String(localized: "rule_smart_playlists_section")) · \(LibraryCountText.songs(totalPlaylistSongs))")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PMColor.card.opacity(0.78), in: .rect(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var totalPlaylistSongs: Int {
        playlists.reduce(0) { partialResult, playlist in
            partialResult + library.songCount(forPlaylist: playlist.id)
        }
    }

    private func macSubsectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
            .padding(.horizontal, 2)
    }

    private func smartPlaylistCard(_ smart: SmartPlaylist) -> some View {
        // 曲库目录可读时数的是后台在目录上算好的那份(第一次算好之前只显示规则数)。
        let count = SmartPlaylistEngine.summary(smart, in: library, history: PlayHistoryStore.shared)?.count
        let isAI = smart.effectiveKind == .ai
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isAI
                                ? [Color.pink.opacity(0.82), Color.orange.opacity(0.72)]
                                : [PMColor.brand.opacity(0.92), Color(red: 0.36, green: 0.45, blue: 0.68)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: isAI ? "sparkles" : "slider.horizontal.3")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 4) {
                Text(smart.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)

                Text(smartPlaylistCardSubtitle(smart, resolvedSongCount: count))
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(PMColor.card.opacity(0.72), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func smartPlaylistCardSubtitle(
        _ smart: SmartPlaylist,
        resolvedSongCount: Int?
    ) -> String {
        let songs = resolvedSongCount.map { "\(LibraryCountText.songs($0)) · " } ?? ""
        if smart.effectiveKind == .ai {
            return songs + "AI"
        }
        return songs + LibraryCountText.rules(smart.ruleCount)
    }

    private func playlistCard(_ playlist: Playlist) -> some View {
        let count = library.songCount(forPlaylist: playlist.id)
        return HStack(spacing: 14) {
            PlaylistArtworkView(playlist: playlist, size: 58, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(LibraryCountText.songs(count))
                    Text("·")
                    Text(playlist.updatedAt, style: .date)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textMuted)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(PMColor.card.opacity(0.72), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func playlistContextMenu(for playlist: Playlist) -> some View {
        // 菜单跟着每张卡片一起求值, 这里只数个数; 歌在点下去时才取。
        let isEmpty = library.songCount(forPlaylist: playlist.id) == 0

        Button {
            playPlaylist(playlist)
        } label: {
            Label("play_all", systemImage: "play.fill")
        }
        .disabled(isEmpty)

        Button {
            playPlaylist(playlist, shuffled: true)
        } label: {
            Label("shuffle", systemImage: "shuffle")
        }
        .disabled(isEmpty)

        Button {
            player.appendToQueue(library.songs(forPlaylist: playlist.id).filteredPlayable())
        } label: {
            Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        .disabled(isEmpty)

        Button {
            player.insertNextInQueue(library.songs(forPlaylist: playlist.id).filteredPlayable())
        } label: {
            Label("up_next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .disabled(isEmpty)

        Button {
            guard scraperSettings.hasEnabledSource else {
                showNoScraperSourceAlert = true
                return
            }
            scraperService.scrapeMissingMetadata(songs: library.songs(forPlaylist: playlist.id), in: library)
        } label: {
            Label("scrape_missing_metadata", systemImage: "wand.and.stars")
        }
        .disabled(isEmpty || scraperService.isScraping)

        favoriteToggleButton(for: playlist)
        PlaylistRenameButton(playlist: playlist) { renamingPlaylist = playlist }
        groupMoveMenu(references: [PlaylistGrouping.reference(id: playlist.id)])
        serverMediaShareButton(for: playlist)
        copyToServerButton(for: playlist)
        playlistRemovalButtons(for: playlist)
    }
    #endif

    /// 长按 / 右键里的「同步歌单」: 直接带上这一个歌单, 面板里只剩选服务器和去向。
    @ViewBuilder
    private func copyToServerButton(for playlist: Playlist) -> some View {
        if ServerPlaylistCopyService.hasTarget(for: playlist.id, sourcesStore: sourcesStore) {
            Button {
                copyToServerPlaylist = playlist
            } label: {
                Label("server_playlist_copy_action", systemImage: "server.rack")
            }
            .disabled(library.songCount(forPlaylist: playlist.id) == 0)
        }
    }

    @ViewBuilder
    private func playlistRemovalButtons(for playlist: Playlist) -> some View {
        if playlist.id != MusicLibrary.likedSongsPlaylistID {
            Divider()
            Button(role: .destructive) {
                pendingRemoval = PlaylistRemovalRequest(playlists: [playlist])
            } label: {
                Label("delete_playlist", systemImage: "trash")
            }
        }
    }

    /// 目标的建法见 `PlaylistShareTargets.make`;模型不在内存里时不在每次求值时从目录读整张歌单(U9b)。
    @ViewBuilder
    private func serverMediaShareButton(for playlist: Playlist) -> some View {
        if let target = shareTargets.target(for: playlist, library: library, sourcesStore: sourcesStore) {
            Button {
                serverMediaShareTarget = target
            } label: {
                Label("server_share_action", systemImage: "link.badge.plus")
            }
        }
    }

    /// 长按菜单里的「收藏 / 取消收藏」，和歌单页头部那颗心是同一件事。
    private func favoriteToggleButton(for playlist: Playlist) -> some View {
        let pin = QuickAccessPinReference(kind: .playlist, itemID: playlist.id)
        let isCollected = LibraryPinStorage.decode(favoritesRawValue).contains(pin)
        return Button {
            PMHaptics.likeToggled(isLiked: !isCollected)
            FavoriteCollectionStore.shared.setCollected(!isCollected, pin, library: library)
        } label: {
            Label(
                isCollected ? "library_favorite_unlike" : "library_favorite_like",
                systemImage: isCollected ? "heart.slash" : "heart"
            )
        }
    }

    private func createPlaylist() {
        let trimmedName = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        _ = library.createPlaylist(name: trimmedName)
        newPlaylistName = ""
    }

    private func playPlaylist(_ playlist: Playlist, shuffled: Bool = false) {
        let playable = library.songs(forPlaylist: playlist.id).filteredPlayable()
        let queue = shuffled ? player.shufflePlayOrder(playable) : playable
        guard !queue.isEmpty else { return }
        if shuffled { player.shuffleEnabled = true }
        SiriMediaInteractionDonor.donate(.playlist(id: playlist.id), shuffled: shuffled)
        Task { await player.play(queue: queue, startingAt: 0, recentItem: .init(kind: .playlist, entityID: playlist.id)) }
    }
}

#if os(macOS)
struct MacNewPlaylistSheet: View {
    @Binding var name: String
    @Binding var description: String
    var onCancel: () -> Void
    var onCreate: (String) -> Void

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("new_playlist")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 26, height: 26)
                        .background(PMColor.glassBtn, in: .circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            VStack(alignment: .center, spacing: 16) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(PMColor.rowHover)
                    .frame(width: 120, height: 120)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(PMColor.dividerStrong, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    }
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .medium))
                            Text("playlist_drop_cover")
                                .font(.system(size: 10.5))
                            Text("playlist_use_first_song_cover")
                                .font(.system(size: 9))
                                .opacity(0.70)
                        }
                        .foregroundStyle(PMColor.textFaint)
                    }

                VStack(alignment: .leading, spacing: 5) {
                    Text("smart_playlist_name")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                    TextField("", text: $name, prompt: Text("playlist_name_example"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PMColor.text)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(PMColor.bgElev, in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(PMColor.brand, lineWidth: 1.5)
                        }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("playlist_description_optional")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                    TextEditor(text: $description)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .frame(height: 64)
                        .background(PMColor.bgElev, in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
                        }
                }
            }
            .padding(20)

            Spacer(minLength: 0)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)
            HStack {
                Spacer()
                Button("cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
                Button("create") {
                    onCreate(name.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 28)
                .background(canCreate ? PMColor.brand : PMColor.textFaint, in: .rect(cornerRadius: 6))
                .disabled(!canCreate)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 420, height: 460)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PMColor.bg.opacity(0.86))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }
}
#endif

// MARK: - Playlist List Sort

extension PlaylistListOrder {
    var label: String {
        switch criterion {
        case nil: return String(localized: "playlist_sort_custom")
        case .some(let criterion): return criterion.label
        }
    }
}

extension PlaylistListOrder.Criterion {
    var label: String {
        switch self {
        case .name: return String(localized: "playlist_sort_name")
        case .dateAdded: return String(localized: "playlist_sort_date_added")
        case .dateUpdated: return String(localized: "playlist_sort_date_updated")
        case .songCount: return String(localized: "playlist_sort_song_count")
        }
    }
}

/// 歌单页的排序菜单, 和全部歌曲一样分两段: 先选按什么排(最前面是自定义顺序),
/// 再选升序还是降序; 自定义顺序没有方向。
struct PlaylistListSortMenuItems: View {
    @Binding var order: PlaylistListOrder

    var body: some View {
        Section {
            Picker("sort_by", selection: criterionBinding) {
                Text("playlist_sort_custom").tag(PlaylistListOrder.Criterion?.none)
                ForEach(PlaylistListOrder.Criterion.allCases, id: \.self) { criterion in
                    Text(verbatim: criterion.label).tag(Optional(criterion))
                }
            }
            .pickerStyle(.inline)
        }
        if order != .custom {
            Section {
                Picker("smart_sort_direction", selection: ascendingBinding) {
                    Label("smart_sort_ascending", systemImage: "arrow.up").tag(true)
                    Label("smart_sort_descending", systemImage: "arrow.down").tag(false)
                }
                .pickerStyle(.inline)
            }
        }
    }

    private var criterionBinding: Binding<PlaylistListOrder.Criterion?> {
        Binding(get: { order.criterion }, set: { order = order.selecting($0) })
    }

    private var ascendingBinding: Binding<Bool> {
        Binding(get: { order.isAscending }, set: { order = order.withAscending($0) })
    }
}

/// 智能歌单详情：资料库导航栈已经在根上登记过就不再登记（极简模式下登记在这一页里面
/// 点卡片接不住）；iPad 侧栏、Mac 单独挂出来时照旧在这里登记。
private struct SmartPlaylistDestinationModifier: ViewModifier {
    let isRegistered: Bool

    func body(content: Content) -> some View {
        if isRegistered {
            content
        } else {
            content.navigationDestination(for: SmartPlaylist.self) { smart in
                SmartPlaylistDetailView(smartPlaylistID: smart.id)
            }
        }
    }
}

// MARK: - 重命名

/// 长按、右键菜单和歌单页「⋯」里的「重命名」。只有自己建的歌单才有:镜像歌单、文件夹歌单和
/// 「我喜欢」的名字归它们的来源管(`MusicLibrary.allowsRename`)。电视上另有面板(看板 PRIM-35)。
struct PlaylistRenameButton: View {
    let playlist: Playlist
    let action: () -> Void

    var body: some View {
        if MusicLibrary.allowsRename(playlist) {
            Button(action: action) {
                Label("playlist_rename", systemImage: "pencil")
            }
        }
    }
}

/// 歌单改名的输入框:给绑定的歌单赋值就弹出,预先填好原来的名字。改名不动曲目和顺序,
/// 经 iCloud 同步到其他设备;名字去掉首尾空白后为空时不改。
private struct PlaylistRenameAlert: ViewModifier {
    @Binding var playlist: Playlist?
    @Environment(MusicLibrary.self) private var library
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("playlist_rename_title", isPresented: Binding(
                get: { playlist != nil },
                set: { if !$0 { playlist = nil } }
            )) {
                TextField("playlist_name", text: $name)
                Button("cancel", role: .cancel) { playlist = nil }
                Button("save") {
                    if let playlist { library.renamePlaylist(id: playlist.id, to: name) }
                    playlist = nil
                }
            }
            .onChange(of: playlist?.id) { _, _ in
                name = playlist?.name ?? ""
            }
    }
}

extension View {
    func playlistRenameAlert(_ playlist: Binding<Playlist?>) -> some View {
        modifier(PlaylistRenameAlert(playlist: playlist))
    }
}

struct PlaylistRemovalRequest {
    let playlistIDs: Set<String>
    let smartPlaylistIDs: Set<String>
    let localCount: Int
    let mirrorCount: Int

    init(playlists: [Playlist] = [], smartPlaylistIDs: Set<String> = []) {
        let ids = Set(playlists.map(\.id)).subtracting([MusicLibrary.likedSongsPlaylistID])
        self.playlistIDs = ids
        self.smartPlaylistIDs = smartPlaylistIDs
        self.mirrorCount = ids.filter(MirrorPlaylistIdentity.isMirrorPlaylist).count
        self.localCount = ids.count - mirrorCount + smartPlaylistIDs.count
    }

    var message: String {
        var parts: [String] = []
        if localCount > 0 {
            parts.append(String(format: String(localized: "playlist_delete_local_confirm_format"), localCount))
        }
        if mirrorCount > 0 {
            parts.append(String(format: String(localized: "playlist_delete_mirror_confirm_format"), mirrorCount))
        }
        return parts.joined(separator: "\n\n")
    }
}

private struct PlaylistRemovalAlert: ViewModifier {
    @Binding var request: PlaylistRemovalRequest?
    @Environment(MusicLibrary.self) private var library
    let onRemoved: (PlaylistRemovalRequest) -> Void

    func body(content: Content) -> some View {
        content.alert("delete_playlist", isPresented: Binding(
            get: { request != nil },
            set: { if !$0 { request = nil } }
        ), presenting: request) { removal in
            Button("cancel", role: .cancel) {}
            Button("delete", role: .destructive) {
                library.removePlaylistsFromLibrary(ids: removal.playlistIDs)
                for id in removal.smartPlaylistIDs { library.deleteSmartPlaylist(id: id) }
                onRemoved(removal)
            }
        } message: { removal in
            Text(verbatim: removal.message)
        }
    }
}

extension View {
    func playlistRemovalAlert(
        _ request: Binding<PlaylistRemovalRequest?>,
        onRemoved: @escaping (PlaylistRemovalRequest) -> Void = { _ in }
    ) -> some View {
        modifier(PlaylistRemovalAlert(request: request, onRemoved: onRemoved))
    }
}
