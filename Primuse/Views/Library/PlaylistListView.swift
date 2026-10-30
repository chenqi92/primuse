import SwiftUI
import PrimuseKit

struct PlaylistListView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.libraryStackRegistersCollectionDetails) private var stackRegistersDetails
    @Environment(AudioPlayerService.self) private var player
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
    @State private var collapsedGroupIDs: Set<String> = []
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
    @AppStorage(LibraryPinStorage.defaultsKey) private var favoritesRawValue = ""
    @AppStorage(PlaylistListOrder.storageKey) private var listOrderRawValue = PlaylistListOrder.custom.rawValue
    /// 「在本页里找」。只按名字筛三类歌单、顺序不变；管理、排序仍对整份列表。
    @State private var findText = ""

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

    private var listOrder: PlaylistListOrder { .resolved(listOrderRawValue) }

    private var listOrderBinding: Binding<PlaylistListOrder> {
        Binding(get: { listOrder }, set: { listOrderRawValue = $0.rawValue })
    }

    /// 按页面选的排序方式摆好的歌单;「自定义顺序」就是 `playlists` 本身。
    private func ordered(_ items: [Playlist]) -> [Playlist] {
        listOrder.sorted(items) { library.songCount(forPlaylist: $0) }
    }

    private var shownPlaylists: [Playlist] { ordered(shown(playlists, name: \.name)) }
    private var shownAISmartPlaylists: [SmartPlaylist] { shown(aiSmartPlaylists, name: \.name) }
    private var shownRuleSmartPlaylists: [SmartPlaylist] { shown(ruleSmartPlaylists, name: \.name) }

    private var findHasNoResults: Bool {
        findQuery != nil
            && shown(playlists, name: \.name).isEmpty
            && shownAISmartPlaylists.isEmpty
            && shownRuleSmartPlaylists.isEmpty
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
                    collapsedGroupIDs.remove(group.id)
                    dissolvingGroup = nil
                }
            }
        } message: {
            Text("playlist_group_dissolve_message")
        }
        .onChange(of: findText) { _, _ in
            if isOrderingPlaylists { finishPlaylistOrder(save: false) }
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

    private func playlists(in groupID: String?) -> [Playlist] {
        let state = grouping
        return pagePlaylists.filter { state.groupID(for: PlaylistGrouping.reference(id: $0.id)) == groupID }
    }

    private func smartPlaylists(in groupID: String?) -> [SmartPlaylist] {
        let state = grouping
        return shown(smartPlaylists, name: \.name).filter {
            state.groupID(for: PlaylistGrouping.reference(id: $0.id, smart: true)) == groupID
        }
    }

    private var ungroupedPlaylists: [Playlist] { playlists(in: nil) }
    private var ungroupedAISmartPlaylists: [SmartPlaylist] { smartPlaylists(in: nil).filter { $0.effectiveKind == .ai } }
    private var ungroupedRuleSmartPlaylists: [SmartPlaylist] { smartPlaylists(in: nil).filter { $0.effectiveKind == .rules } }
    private var visibleGroups: [PlaylistGrouping.Group] {
        grouping.groups.filter {
            findQuery == nil || !playlists(in: $0.id).isEmpty || !smartPlaylists(in: $0.id).isEmpty
        }
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
    private var playlistSections: some View {
        ForEach(visibleGroups) { group in
            Section {
                if isOrderingPlaylists || findQuery != nil || !collapsedGroupIDs.contains(group.id) {
                    playlistRows(playlists(in: group.id))
                    ForEach(smartPlaylists(in: group.id)) { smart in
                        smartPlaylistLink(smart)
                    }
                    if playlists(in: group.id).isEmpty && smartPlaylists(in: group.id).isEmpty {
                        Text("no_playlists").foregroundStyle(.secondary)
                    }
                }
            } header: {
                groupHeader(group)
            }
        }
        if !ungroupedAISmartPlaylists.isEmpty {
            Section("ai_smart_playlists_section") {
                ForEach(ungroupedAISmartPlaylists) { smart in smartPlaylistLink(smart) }
                    .onDelete { deleteSmartPlaylists(at: $0, in: ungroupedAISmartPlaylists) }
                    .deleteDisabled(isOrderingPlaylists)
            }
        }
        if !ungroupedRuleSmartPlaylists.isEmpty {
            Section("rule_smart_playlists_section") {
                ForEach(ungroupedRuleSmartPlaylists) { smart in smartPlaylistLink(smart) }
                    .onDelete { deleteSmartPlaylists(at: $0, in: ungroupedRuleSmartPlaylists) }
                    .deleteDisabled(isOrderingPlaylists)
            }
        }
        if !ungroupedPlaylists.isEmpty {
            Section {
                playlistRows(ungroupedPlaylists)
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if playlist.id != MusicLibrary.likedSongsPlaylistID {
                            Button(role: .destructive) { pendingRemoval = PlaylistRemovalRequest(playlists: [playlist]) } label: {
                                Label("delete", systemImage: "trash")
                            }
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

    private func groupHeader(_ group: PlaylistGrouping.Group) -> some View {
        HStack(spacing: 8) {
            Button {
                if collapsedGroupIDs.contains(group.id) { collapsedGroupIDs.remove(group.id) }
                else { collapsedGroupIDs.insert(group.id) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text(verbatim: group.name)
                    Spacer()
                    Text(verbatim: (playlists(in: group.id).count + smartPlaylists(in: group.id).count).formatted())
                        .monospacedDigit()
                    Image(systemName: collapsedGroupIDs.contains(group.id) && findQuery == nil && !isOrderingPlaylists
                          ? "chevron.right" : "chevron.down")
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu {
                Button("playlist_group_rename") { editGroup(group) }
                Button("playlist_group_dissolve", role: .destructive) { dissolvingGroup = group }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(verbatim: group.name + ", ") + Text("a11y_more_actions"))
            .accessibilityIdentifier("playlistGroup.more.\(group.id)")
        }
        .textCase(nil)
        .disabled(isOrderingPlaylists)
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
        if let groupID { collapsedGroupIDs.remove(groupID) }
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
                List { playlistSections }
                #if os(iOS)
                .environment(\.editMode, .constant(isOrderingPlaylists ? .active : .inactive))
                #endif
                .overlay {
                    if findHasNoResults {
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

    /// 新建歌单、AI 歌单、规则歌单与导入。
    private func playlistAddMenu(titled: Bool) -> some View {
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
            PMToolbarItemLabel("new_playlist", systemImage: "plus", titled: titled)
        }
        .accessibilityIdentifier("playlists.new")
    }

    /// 排序方式、调整顺序与多选。
    private func playlistMoreMenu(titled: Bool) -> some View {
        Menu {
            if canReorderPlaylists {
                Menu {
                    PlaylistListSortMenuItems(order: listOrderBinding)
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
        } label: {
            PMToolbarItemLabel("a11y_more_actions", systemImage: "ellipsis", titled: titled)
        }
        .accessibilityIdentifier("playlists.more")
    }

    private var playlistCountText: String {
        "\((playlists.count + smartPlaylists.count).formatted()) \(String(localized: "playlists_count"))"
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
            return "\(smart.aiConfiguration?.selections.count ?? 0) \(String(localized: "songs_count")) · AI"
        }
        return "\(smart.ruleCount) \(String(localized: "rules_count"))"
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

    private var macGroupedPlaylists: some View {
        ForEach(visibleGroups) { group in
            VStack(alignment: .leading, spacing: 10) {
                groupHeader(group)
                    .font(.subheadline.weight(.semibold))
                if findQuery != nil || !collapsedGroupIDs.contains(group.id) {
                    LazyVGrid(columns: macPlaylistGridColumns, alignment: .leading, spacing: 12) {
                        ForEach(playlists(in: group.id)) { playlist in
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
                        ForEach(smartPlaylists(in: group.id)) { smart in
                            macSmartPlaylistCard(smart)
                        }
                    }
                    if playlists(in: group.id).isEmpty && smartPlaylists(in: group.id).isEmpty {
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
                List { playlistSections }
                    .listStyle(.plain)
            }
            .background(PMColor.bg.ignoresSafeArea())
        } else {
            macBrowseBody
        }
    }

    private var macBrowseBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                macPlaylistsHeader

                if playlists.isEmpty && smartPlaylists.isEmpty && grouping.groups.isEmpty {
                    ContentUnavailableView(
                        "no_playlists",
                        systemImage: "music.note.list",
                        description: Text("no_playlists_desc")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else if findHasNoResults {
                    ContentUnavailableView.search(text: findText)
                        .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    playlistOverview
                    macGroupedPlaylists

                    if !ungroupedAISmartPlaylists.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            macSubsectionTitle("ai_smart_playlists_section")
                            LazyVGrid(
                                columns: macPlaylistGridColumns,
                                alignment: .leading,
                                spacing: 12
                            ) {
                                ForEach(ungroupedAISmartPlaylists) { smart in
                                    macSmartPlaylistCard(smart)
                                }
                            }
                        }
                        .pmFadeTransition(motion: .contentAppear)
                    }

                    if !ungroupedRuleSmartPlaylists.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            macSubsectionTitle("rule_smart_playlists_section")
                            LazyVGrid(
                                columns: macPlaylistGridColumns,
                                alignment: .leading,
                                spacing: 12
                            ) {
                                ForEach(ungroupedRuleSmartPlaylists) { smart in
                                    macSmartPlaylistCard(smart)
                                }
                            }
                        }
                        .pmFadeTransition(motion: .contentAppear)
                    }

                    if !ungroupedPlaylists.isEmpty {
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
                                ForEach(ungroupedPlaylists) { playlist in
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
                    .foregroundStyle(PMColor.text)
            }
            Spacer()
            if !playlists.isEmpty || !smartPlaylists.isEmpty {
                MacLibraryFindField(text: $findText, prompt: "filter_playlists_placeholder")
            }
            Button {
                showNewPlaylist = true
            } label: {
                Label("new_playlist", systemImage: "plus")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(PMColor.brand, in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            Button {
                showAIEditor = true
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .frame(width: 32, height: 32)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .help(Text("new_ai_smart_playlist"))

            Button {
                showSmartEditor = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .frame(width: 32, height: 32)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .help(Text("new_rule_smart_playlist"))

            if operationAvailability.supportsImport {
                Button {
                    showPlaylistImport = true
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .frame(width: 32, height: 32)
                        .background(PMColor.glassBtn, in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
                .help(Text("playlist_import_title"))
            }

            if canCopyToServer {
                Button {
                    showCopyToServer = true
                } label: {
                    Image(systemName: "server.rack")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                        .frame(width: 32, height: 32)
                        .background(PMColor.glassBtn, in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                        }
                }
                .buttonStyle(.plain)
                .help(Text("server_playlist_copy_action"))
            }

            Button {
                editGroup()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help(Text("playlist_group_new"))

            if canReorderPlaylists {
                macSortMenu
            }

            if !playlists.isEmpty || !smartPlaylists.isEmpty {
                Button {
                    isManagingPlaylists.toggle()
                    if !isManagingPlaylists { playlistSelection = [] }
                } label: {
                    Image(systemName: isManagingPlaylists ? "xmark" : "checkmark.circle")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(isManagingPlaylists ? .white : PMColor.text)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                        .background(isManagingPlaylists ? PMColor.brand : PMColor.glassBtn,
                                    in: .rect(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(isManagingPlaylists ? .clear : PMColor.cardBorder,
                                              lineWidth: 0.5)
                        }
                        // 事务只罩住这枚按钮 —— 进出管理态会重排整块歌单网格,
                        // 在调用点包 withAnimation 会把它们一起拖进来。
                        .pmAnimation(.control, value: isManagingPlaylists)
                }
                .buttonStyle(.plain)
                .help(Text(isManagingPlaylists ? LocalizedStringKey("done") : "batch_select"))
            }
        }
    }

    /// 排序方式和「调整歌单顺序」收在一颗键里, 键上写着当前怎么排。
    private var macSortMenu: some View {
        Menu {
            PlaylistListSortMenuItems(order: listOrderBinding)
            Section {
                Button {
                    beginPlaylistOrder()
                } label: {
                    Label("playlist_order_action", systemImage: "line.3.horizontal")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text(verbatim: listOrder.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted)
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(PMColor.text)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .background(PMColor.glassBtn, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
                Text("\(playlists.count) \(String(localized: "playlists_section")) · \(aiSmartPlaylists.count) \(String(localized: "ai_smart_playlists_section")) · \(ruleSmartPlaylists.count) \(String(localized: "rule_smart_playlists_section")) · \(totalPlaylistSongs) \(String(localized: "songs_count"))")
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
        let count = SmartPlaylistEngine.match(smart, in: library, history: PlayHistoryStore.shared).count
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
        resolvedSongCount: Int
    ) -> String {
        if smart.effectiveKind == .ai {
            return "\(resolvedSongCount) \(String(localized: "songs_count")) · AI"
        }
        return "\(resolvedSongCount) \(String(localized: "songs_count")) · \(smart.ruleCount) \(String(localized: "rules_count"))"
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
                    Text("\(count) \(String(localized: "songs_count"))")
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

    private func makeServerMediaShareTarget(
        for playlist: Playlist
    ) -> ServerMediaShareTarget? {
        // 长按菜单跟着每一行一起求值: 先只看第一首歌的源能不能这样分享, 能的才取出
        // 整张歌单逐首核对。没有 Subsonic 一类源的歌单不再每行都拷一遍整张歌单。
        guard let firstSong = library.songSummary(forPlaylist: playlist.id).first,
              let source = sourcesStore.source(id: firstSong.sourceID),
              ServerMediaShareTargetPolicy.supports(source.type) else { return nil }
        let songs = library.songs(forPlaylist: playlist.id)
        return try? ServerMediaShareTargetPolicy.makeTarget(
            kind: .playlist,
            title: playlist.name,
            songs: songs,
            source: source
        )
    }

    @ViewBuilder
    private func serverMediaShareButton(for playlist: Playlist) -> some View {
        if let target = makeServerMediaShareTarget(for: playlist) {
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

    private func deleteSmartPlaylists(
        at offsets: IndexSet,
        in playlists: [SmartPlaylist]
    ) {
        pendingRemoval = PlaylistRemovalRequest(smartPlaylistIDs: Set(offsets.map { playlists[$0].id }))
    }

    private func playPlaylist(_ playlist: Playlist, shuffled: Bool = false) {
        let playable = library.songs(forPlaylist: playlist.id).filteredPlayable()
        let queue = shuffled ? player.shufflePlayOrder(playable) : playable
        guard !queue.isEmpty else { return }
        if shuffled { player.shuffleEnabled = true }
        SiriMediaInteractionDonor.donate(.playlist(id: playlist.id), shuffled: shuffled)
        Task { await player.play(queue: queue, startingAt: 0) }
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
