import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import PrimuseKit

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct RadioStationsView: View {
    @Environment(RadioStationsStore.self) private var store
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.skin) private var skin
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:整理菜单并进系统溢出菜单。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @State private var editingStation: RadioStation?
    @State private var showingNewStation = false
    @State private var showingBatchAdd = false
    @State private var pendingInsecureStation: RadioStation?
    /// 管理态 —— 设计上用「先选后做」的多选替代每行一个 ⋯ 菜单。
    /// 进入即编辑态，没有中间的"看着像可选但没勾选圈"的过渡。
    @State private var isManaging = false
    @State private var selection: Set<String> = []
    @State private var showDeleteConfirm = false
    @State private var showExporter = false
    @State private var exportDocument = RadioPlaylistDocument()
    @State private var folderScope: RadioStationFilter.FolderScope = .all
    @State private var activeTags: Set<String> = []
    @State private var searchText = ""
    /// 顶部 tab 外壳里页内搜索框是否展开。文本仍是 `searchText`,与 `.searchable`(经典、整理态)同一份。
    @State private var showsRootFilter = false
    @State private var namePrompt: RadioNamePrompt?
    @State private var namePromptText = ""
    @State private var folderToDelete: String?
    @State private var tagToDelete: String?
    @State private var showingSubscriptions = false
    /// 从「+」菜单进来时直接停在「添加订阅」；从顶部状态行进来时停在订阅列表。
    @State private var subscriptionsStartAdding = false
    /// 删订阅电台前先确认一次 —— 删掉就等于告诉清单「这一条我不要了」。
    @State private var subscribedStationToDelete: RadioStation?
    @AppStorage(RadioStationLayoutMode.storageKey)
    private var layoutModeRaw = RadioStationLayoutMode.list.rawValue
    @Environment(\.pmHeightClass) private var heightClass

    private var layoutMode: RadioStationLayoutMode {
        RadioStationLayoutMode(rawValue: layoutModeRaw) ?? .list
    }

    /// 工具栏那个切版式的按钮要显示「点了会变成哪种」，这里就是那一种。
    private var alternateLayoutMode: RadioStationLayoutMode {
        layoutMode == .cover ? .list : .cover
    }

    /// 列表版一行一个宽卡片；封面版是方格台标墙，一屏能放下三四倍的台。
    /// 列表版在手机横屏下本来就会排成两列、不必再收；封面版的格子跟着高度收一档。
    private var columns: [GridItem] {
        switch layoutMode {
        case .list:
            return [GridItem(.adaptive(minimum: 320, maximum: 460), spacing: 16)]
        case .cover:
            return [GridItem(
                .adaptive(
                    minimum: heightClass.value(108, compact: 92),
                    maximum: heightClass.value(170, compact: 132)
                ),
                spacing: 14
            )]
        }
    }

    private var filter: RadioStationFilter {
        RadioStationFilter(folder: folderScope, tagNames: activeTags, searchText: searchText)
    }

    private var visibleStations: [RadioStation] {
        RadioStationOrganization.filtered(store.stations, with: filter)
    }

    private var folders: [RadioStationFolderSummary] { store.folders }
    private var tags: [RadioStationTagSummary] { store.tags }

    /// 未收窄时按文件夹分段展示 —— 这才是文件夹的用处。一旦在搜索或筛选，
    /// 用户要的是一份结果清单，分段只会让他多滚几屏。
    private var showsFolderSections: Bool {
        !filter.isNarrowed && folders.contains { !$0.isEmpty }
    }

    /// 选中项里能被编辑/导出/删除的那部分。服务器镜像不在其列。
    private var selectedStations: [RadioStation] {
        visibleStations.filter { selection.contains($0.id) && !$0.isServerMirror }
    }

    /// 选中项的全部 id。归类(文件夹/标签)对服务器镜像同样成立 —— 那是用户
    /// 自己的整理方式，跟电台是不是音乐源给的无关。
    private var selectedIDs: [String] {
        visibleStations.filter { selection.contains($0.id) }.map(\.id)
    }

    private var visibleStationIDs: Set<String> {
        Set(visibleStations.map(\.id))
    }

    /// 管理态且有选中时，标题让位给计数 —— 批量操作藏在菜单里，选了几条
    /// 得有个地方看得见。
    private var navigationTitleText: String {
        guard isManaging, !selectedIDs.isEmpty else {
            return String(localized: "radio_title")
        }
        return String(
            format: String(localized: "radio_manage_selected %lld"),
            selectedIDs.count
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            subscriptionBar
            organizeBar
            content
        }
        .navigationTitle(navigationTitleText)
        .searchable(text: $searchText, prompt: Text("radio_search_placeholder"))
        .toolbar { toolbarContent }
        #if os(iOS)
        .minimalRootFilter(
            text: $searchText,
            isPresented: $showsRootFilter,
            prompt: Text("radio_search_placeholder")
        )
        .minimalRootActions { minimalRootActionItems }
        .minimalRootEditing(isManaging)
        #endif
        // 进列表时给还没有台标的电台排一次自动发现。重复进入是安全的 ——
        // 已有台标的、正在找的、还在退避期的都会被服务自己挡掉。
        .task {
            RadioLogoDiscoveryService.shared.discoverIfNeeded(for: store.stations)
        }
        #if DEBUG
        // 编译机截图用:`PRIMUSE_DEBUG_EDIT=radio` 时进页两秒后进入整理,看导航栏是否回到根页。
        .task {
            guard ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_EDIT"] == "radio" else { return }
            try? await Task.sleep(for: .seconds(2))
            isManaging = true
        }
        // 编译机截图用:`PRIMUSE_DEBUG_SEED_RADIO=1` 时没有电台就先放几个(地址不通,只为看列表与筛选)。
        .task {
            guard ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_SEED_RADIO"] == "1",
                  store.stations.isEmpty else { return }
            let names = ["Nova FM", "Harbor Jazz", "City Night Radio", "Classic 88.1", "Folk Café", "Morning News", "Lo-fi Beats", "Tokyo Pop"]
            for (index, name) in names.enumerated() {
                store.add(RadioStation(name: name, streamURL: "https://radio.example.com/stream/\(index + 1)"))
            }
        }
        #endif
        .sheet(isPresented: $showingNewStation) {
            RadioStationEditorView(station: nil)
        }
        .sheet(isPresented: $showingBatchAdd) {
            RadioBatchAddView()
        }
        .sheet(item: $editingStation) { station in
            // 「转为我自己的电台」之后直接接着编辑新建的那个电台。
            RadioStationEditorView(station: station) { own in
                editingStation = own
            }
        }
        .sheet(isPresented: $showingSubscriptions) {
            RadioSubscriptionsView(startsAdding: subscriptionsStartAdding)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .m3uPlaylist,
            defaultFilename: "primuse-radio"
        ) { _ in }
        .confirmationDialog(
            String(localized: "radio_manage_delete_confirm_title"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(
                String(
                    format: String(localized: "radio_manage_delete_count %lld"),
                    selectedStations.count
                ),
                role: .destructive
            ) {
                deleteSelected()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            if selectedStations.contains(where: { $0.isSubscribed }) {
                Text(
                    String(localized: "radio_manage_delete_confirm_message")
                        + "\n" + String(localized: "radio_subscription_delete_note")
                )
            } else {
                Text("radio_manage_delete_confirm_message")
            }
        }
        .confirmationDialog(
            String(localized: "radio_manage_delete_confirm_title"),
            isPresented: Binding(
                get: { subscribedStationToDelete != nil },
                set: { if !$0 { subscribedStationToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: subscribedStationToDelete
        ) { station in
            Button("delete", role: .destructive) {
                store.remove(id: station.id)
                subscribedStationToDelete = nil
            }
            Button("cancel", role: .cancel) { subscribedStationToDelete = nil }
        } message: { _ in
            Text("radio_subscription_delete_note")
        }
        .alert("insecure_http_warning_title", isPresented: Binding(
            get: { pendingInsecureStation != nil },
            set: { if !$0 { pendingInsecureStation = nil } }
        )) {
            Button("cancel", role: .cancel) {
                pendingInsecureStation = nil
            }
            Button("insecure_http_continue", role: .destructive) {
                guard let station = pendingInsecureStation,
                      let url = station.url,
                      let trustTarget = TrustedHTTPTransport.trustTarget(for: url) else { return }
                SSLTrustStore.shared.allowInsecureHTTP(domain: trustTarget)
                pendingInsecureStation = nil
                performToggle(station)
            }
        } message: {
            Text(String(
                format: String(localized: "insecure_http_warning_message %@"),
                pendingInsecureStation?.url.flatMap(TrustedHTTPTransport.trustTarget(for:)) ?? ""
            ))
        }
        .alert(namePrompt?.title ?? "", isPresented: Binding(
            get: { namePrompt != nil },
            set: { if !$0 { namePrompt = nil } }
        )) {
            TextField(namePrompt?.fieldTitle ?? "", text: $namePromptText)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
            Button("cancel", role: .cancel) { namePrompt = nil }
            Button("save") { commitNamePrompt() }
        }
        .confirmationDialog(
            String(localized: "radio_folder_delete"),
            isPresented: Binding(
                get: { folderToDelete != nil },
                set: { if !$0 { folderToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("delete", role: .destructive) {
                guard let name = folderToDelete else { return }
                if case .folder(let current) = folderScope,
                   RadioStationOrganization.isSameName(current, name) {
                    folderScope = .all
                }
                store.deleteFolder(name)
                folderToDelete = nil
            }
            Button("cancel", role: .cancel) { folderToDelete = nil }
        } message: {
            Text("radio_folder_delete_message")
        }
        .confirmationDialog(
            String(localized: "radio_tag_delete"),
            isPresented: Binding(
                get: { tagToDelete != nil },
                set: { if !$0 { tagToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("delete", role: .destructive) {
                guard let name = tagToDelete else { return }
                activeTags.remove(name)
                store.deleteTag(name)
                tagToDelete = nil
            }
            Button("cancel", role: .cancel) { tagToDelete = nil }
        } message: {
            Text("radio_tag_delete_message")
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.stations.isEmpty {
            ContentUnavailableView {
                Label("radio_empty_title", systemImage: "radio")
            } description: {
                Text("radio_empty_description")
            }
        } else if visibleStations.isEmpty {
            ContentUnavailableView {
                Label("radio_filter_empty_title", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("radio_filter_empty_description")
            } actions: {
                Button("radio_filter_clear") { clearFilters() }
            }
        } else if isManaging {
            manageList
        } else {
            stationGrid
        }
    }

    // MARK: - 清单订阅状态

    /// 有订阅时在筛选条上方露一行紧凑状态，点进订阅管理。
    @ViewBuilder
    private var subscriptionBar: some View {
        if !RadioSubscriptionsStore.shared.subscriptions.isEmpty {
            HStack(spacing: 0) {
                RadioSubscriptionStatusRow {
                    subscriptionsStartAdding = false
                    showingSubscriptions = true
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    // MARK: - 文件夹与标签筛选条

    @ViewBuilder
    private var organizeBar: some View {
        let folderChips = folders
        let tagChips = tags
        if !folderChips.isEmpty || !tagChips.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !folderChips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            RadioFilterChip(
                                title: String(localized: "radio_folder_all"),
                                systemImage: "square.grid.2x2",
                                count: store.stations.count,
                                isSelected: isScopeSelected(.all)
                            ) { folderScope = .all }

                            let ungrouped = store.ungroupedStationCount
                            if ungrouped > 0 {
                                RadioFilterChip(
                                    title: String(localized: "radio_folder_ungrouped"),
                                    systemImage: "tray",
                                    count: ungrouped,
                                    isSelected: isScopeSelected(.ungrouped)
                                ) { folderScope = .ungrouped }
                            }

                            ForEach(folderChips) { folder in
                                RadioFilterChip(
                                    title: folder.name,
                                    systemImage: "folder",
                                    count: folder.stationCount,
                                    isSelected: isScopeSelected(.folder(folder.name))
                                ) {
                                    folderScope = isScopeSelected(.folder(folder.name))
                                        ? .all
                                        : .folder(folder.name)
                                }
                                .contextMenu { folderChipActions(folder.name) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .pmStopsAtVerticalBar()
                }

                if !tagChips.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(tagChips) { tag in
                                RadioFilterChip(
                                    title: tag.name,
                                    systemImage: "tag",
                                    count: tag.stationCount,
                                    isSelected: activeTags.contains(tag.name),
                                    tint: RadioTagPalette.color(for: tag.name)
                                ) {
                                    if activeTags.contains(tag.name) {
                                        activeTags.remove(tag.name)
                                    } else {
                                        activeTags.insert(tag.name)
                                    }
                                }
                                .contextMenu { tagChipActions(tag.name) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .pmStopsAtVerticalBar()
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func folderChipActions(_ name: String) -> some View {
        Button("radio_folder_rename", systemImage: "pencil") {
            beginPrompt(.renameFolder(name))
        }
        Button("radio_folder_delete", systemImage: "trash", role: .destructive) {
            folderToDelete = name
        }
    }

    @ViewBuilder
    private func tagChipActions(_ name: String) -> some View {
        Button("radio_tag_rename", systemImage: "pencil") {
            beginPrompt(.renameTag(name))
        }
        Button("radio_tag_delete", systemImage: "trash", role: .destructive) {
            tagToDelete = name
        }
    }

    private func isScopeSelected(_ scope: RadioStationFilter.FolderScope) -> Bool {
        switch (folderScope, scope) {
        case (.all, .all), (.ungrouped, .ungrouped):
            return true
        case (.folder(let lhs), .folder(let rhs)):
            return RadioStationOrganization.isSameName(lhs, rhs)
        default:
            return false
        }
    }

    private func clearFilters() {
        folderScope = .all
        activeTags = []
        searchText = ""
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isManaging {
            ToolbarItem(placement: .cancellationAction) {
                Button("done") {
                    pmWithAnimation(.list) {
                        isManaging = false
                        selection = []
                    }
                }
            }

            // 批量操作收进右上角菜单 —— 这个页面是 push 进 tab 里的，底部已经
            // 被系统 tab bar 和 mini player accessory 占满，任何自绘的底部条
            // 都会被盖住(mini player 是 zIndex overlay，不贡献安全区)。
            #if os(iOS)
            if verticalBarEdge != nil {
                // 系统竖栏(iPhone Duo):批量操作并进系统溢出菜单,不再自己套一层「⋯」。
                if #available(iOS 27.0, *) {
                    ToolbarOverflowMenu {
                        radioManageMenuItems
                    }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        radioManageMenuItems
                    } label: {
                        Label("radio_manage", systemImage: "ellipsis.circle")
                    }
                }
            }
            #else
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    radioManageMenuItems
                } label: {
                    Label("radio_manage", systemImage: "ellipsis.circle")
                }
            }
            #endif
        } else {
            ToolbarItemGroup(placement: .primaryAction) {
                if !store.stations.isEmpty {
                    Button {
                        pmWithAnimation(.list) { isManaging = true }
                    } label: {
                        Label("radio_manage", systemImage: "checklist")
                    }
                }

                // 版式一共就两种，展开一个菜单去点其中一个不如按一下直接换。
                // 图标画的是「点下去会变成的那种」，当前是哪种交给旁白报。
                Button {
                    layoutModeRaw = alternateLayoutMode.rawValue
                } label: {
                    PMToolbarItemLabel(
                        verbatim: String(localized: alternateLayoutMode.titleKey),
                        systemImage: alternateLayoutMode.icon,
                        titled: verticalBarEdge != nil
                    )
                }
                .accessibilityLabel(Text(String(localized: alternateLayoutMode.titleKey)))
                .accessibilityValue(Text(String(localized: layoutMode.titleKey)))
                .accessibilityIdentifier("radioLayoutMode.toggle")

                radioAddMenu
            }
        }
    }

    /// 整理状态下的批量操作(全选、置顶、导出、移到文件夹、标签、编辑、删除)。
    @ViewBuilder
    private var radioManageMenuItems: some View {
        // 批量操作里用得最多的三件事排成一行。这三个键在任何选中
        // 状态下都在，只是会变灰，所以这一行不会塌成一个键。
        PMMenuQuickActions {
            let allSelected = selection == visibleStationIDs
            PMMenuQuickActionButton(
                shortKey: allSelected ? "deselect_all_short" : "select_all_short",
                fullKey: allSelected ? "radio_manage_deselect_all" : "select_all",
                systemImage: allSelected ? "circle" : "checkmark.circle"
            ) {
                selection = allSelected ? [] : visibleStationIDs
            }
            .disabled(visibleStationIDs.isEmpty)

            PMMenuQuickActionButton(
                shortKey: "radio_manage_pin_top_short",
                fullKey: "radio_manage_pin_top",
                systemImage: "arrow.up.to.line"
            ) {
                moveToTop(selection)
            }
            .disabled(selectedStations.isEmpty)

            Button {
                exportSelected()
            } label: {
                Label("radio_manage_export", systemImage: "square.and.arrow.up")
            }
            .disabled(selectedStations.isEmpty)
        }

        Section {
            Menu {
                folderAssignmentActions(for: selectedIDs)
            } label: {
                Label("radio_folder_move", systemImage: "folder")
            }
            .disabled(selectedIDs.isEmpty)

            Menu {
                tagAssignmentActions(for: selectedIDs)
            } label: {
                Label("radio_tags", systemImage: "tag")
            }
            .disabled(selectedIDs.isEmpty)

            Button {
                guard let station = selectedStations.first else { return }
                editingStation = station
            } label: {
                Label("edit", systemImage: "pencil")
            }
            // 编辑是单条操作，多选时没有明确目标。
            .disabled(selectedStations.count != 1)
        }

        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("delete", systemImage: "trash")
            }
            .disabled(selectedStations.isEmpty)
        }
    }

    /// 添加电台、批量添加、订阅、新建文件夹、按名称排序。
    private var radioAddMenu: some View {
        Menu {
            Button("radio_batch_add_title", systemImage: "square.and.arrow.down") {
                showingBatchAdd = true
            }
            Button("radio_add", systemImage: "plus") {
                showingNewStation = true
            }
            Button("radio_subscriptions_add", systemImage: "arrow.triangle.2.circlepath") {
                subscriptionsStartAdding = true
                showingSubscriptions = true
            }
            Divider()
            Button("radio_folder_new", systemImage: "folder.badge.plus") {
                beginPrompt(.createFolder(assigning: []))
            }
            if !store.stations.isEmpty {
                Button("radio_priority_sort_by_name", systemImage: "arrow.up.arrow.down") {
                    store.sortStationsByName()
                }
            }
        } label: {
            Label("radio_add", systemImage: "plus")
        }
    }

    /// 顶部 tab 外壳里电台是根页:「+」菜单照旧,整理与版式切换并进一个「更多」菜单。
    /// 进入整理后导航栏回来,完成键、选中计数与批量菜单仍在那里。
    @ViewBuilder
    private var minimalRootActionItems: some View {
        radioAddMenu
        Menu {
            if !store.stations.isEmpty {
                Button {
                    pmWithAnimation(.list) { isManaging = true }
                } label: {
                    Label("radio_manage", systemImage: "checklist")
                }
            }
            Button {
                layoutModeRaw = alternateLayoutMode.rawValue
            } label: {
                Label(String(localized: alternateLayoutMode.titleKey), systemImage: alternateLayoutMode.icon)
            }
            .accessibilityValue(Text(String(localized: layoutMode.titleKey)))
        } label: {
            Label("a11y_more_actions", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("radio.moreActions")
    }

    // MARK: - 归类动作

    /// 「移动到文件夹」的菜单内容。`ids` 为空时调用方已经把整个菜单禁掉了。
    @ViewBuilder
    private func folderAssignmentActions(for ids: [String]) -> some View {
        Button("radio_folder_new", systemImage: "folder.badge.plus") {
            beginPrompt(.createFolder(assigning: ids))
        }
        if !folders.isEmpty {
            Divider()
            ForEach(folders) { folder in
                Button(folder.name, systemImage: "folder") {
                    store.setFolder(folder.name, forStationIDs: ids)
                }
            }
        }
        Divider()
        Button("radio_folder_remove_from", systemImage: "tray") {
            store.setFolder(nil, forStationIDs: ids)
        }
    }

    /// 「标签」的菜单内容。已经贴在**全部**选中电台上的标签打勾，再点一次是撕掉。
    @ViewBuilder
    private func tagAssignmentActions(for ids: [String]) -> some View {
        Button("radio_tag_new", systemImage: "tag.fill") {
            beginPrompt(.createTag(assigning: ids))
        }
        if !tags.isEmpty {
            Divider()
            let targets = store.stations.filter { ids.contains($0.id) }
            ForEach(tags) { tag in
                let applied = !targets.isEmpty && targets.allSatisfy { station in
                    station.assignedTagNames.contains {
                        RadioStationOrganization.isSameName($0, tag.name)
                    }
                }
                Button {
                    if applied {
                        store.removeTag(tag.name, fromStationIDs: ids)
                    } else {
                        store.addTag(tag.name, toStationIDs: ids)
                    }
                } label: {
                    Label(tag.name, systemImage: applied ? "checkmark.circle.fill" : "tag")
                }
            }
        }
    }

    private func beginPrompt(_ prompt: RadioNamePrompt) {
        namePromptText = prompt.initialText
        namePrompt = prompt
    }

    private func commitNamePrompt() {
        defer { namePrompt = nil }
        guard let prompt = namePrompt else { return }
        let text = namePromptText
        switch prompt {
        case .createFolder(let ids):
            guard let name = store.createFolder(text) else { return }
            if !ids.isEmpty { store.setFolder(name, forStationIDs: ids) }
        case .renameFolder(let old):
            guard let name = RadioStationOrganization.normalizedFolderName(text) else { return }
            store.renameFolder(old, to: name)
            if case .folder(let current) = folderScope,
               RadioStationOrganization.isSameName(current, old) {
                folderScope = .folder(name)
            }
        case .createTag(let ids):
            store.addTag(text, toStationIDs: ids)
        case .renameTag(let old):
            guard let name = RadioStationOrganization.normalizedTagName(text) else { return }
            store.renameTag(old, to: name)
            if activeTags.remove(old) != nil { activeTags.insert(name) }
        }
    }

    private var stationGrid: some View {
        // 卡片上的 `#N` 是电台在**全局**优先级里的位次，不随筛选变化 ——
        // 上一台/下一台、CarPlay、电视端用的都是这份全局顺序。
        let priorities = store.priorityByID
        let total = store.stations.count
        return ScrollView {
            if skin.usesOnAirRadio {
                VStack(alignment: .leading, spacing: 16) {
                    #if os(iOS)
                    // 正在播的电台放在最上面一张大卡:台名、节目、上下台与停止、睡眠定时都在这里。
                    // 卡片自己读播放状态,节目标题更新不会把整页网格拉着重画。
                    RadioOnAirHero()
                    #endif
                    stationLazyGrid(priorities: priorities, total: total)
                    // 末尾一格「添加电台」,和首页电台墙的添加卡一样打开批量添加。
                    RadioAddStationTile(layoutMode: layoutMode) { showingBatchAdd = true }
                }
                .padding(16)
            } else {
                stationLazyGrid(priorities: priorities, total: total)
                    .padding(16)
            }
        }
    }

    private func stationLazyGrid(priorities: [String: Int], total: Int) -> some View {
        LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: layoutMode == .cover ? 14 : 16,
            pinnedViews: [.sectionHeaders]
        ) {
            if showsFolderSections {
                // 分段只在没筛选时出现，这时可见的就是全部电台，直接用存储里分好的。
                ForEach(store.folderGroups) { group in
                    Section {
                        ForEach(group.stations) { station in
                            stationItem(
                                station,
                                priority: priorities[station.id] ?? 1,
                                total: total
                            )
                        }
                    } header: {
                        folderSectionHeader(group)
                    }
                }
            } else {
                ForEach(visibleStations) { station in
                    stationItem(station, priority: priorities[station.id] ?? 1, total: total)
                }
            }
        }
    }

    private func stationItem(
        _ station: RadioStation,
        priority: Int,
        total: Int
    ) -> some View {
        RadioStationGridItem(
            station: station,
            layoutMode: layoutMode,
            priority: priority,
            onPlay: { toggle(station) },
            actions: { stationActions(for: station, priority: priority, total: total) }
        )
    }

    /// 一条电台的全部单条操作。列表卡片的 ⋯ 菜单和封面格的长按菜单共用这一份 ——
    /// 两种版式给的是同一组能力，不该有哪个少一项。
    @ViewBuilder
    private func stationActions(
        for station: RadioStation,
        priority: Int,
        total: Int
    ) -> some View {
        // 最常用的三件事排成一行。服务器镜像改不了名字和地址，那一行就只剩
        // 调序两个键 —— 仍然是两个，不会出现一个键占满整行的样子。
        PMMenuQuickActions {
            if !station.isServerMirror {
                Button("edit", systemImage: "pencil") { editingStation = station }
            }

            PMMenuQuickActionButton(
                shortKey: "radio_priority_move_up_short",
                fullKey: "radio_priority_move_up",
                systemImage: "arrow.up"
            ) {
                store.moveStation(id: station.id, by: -1)
            }
            .disabled(priority <= 1)

            PMMenuQuickActionButton(
                shortKey: "radio_priority_move_down_short",
                fullKey: "radio_priority_move_down",
                systemImage: "arrow.down"
            ) {
                store.moveStation(id: station.id, by: 1)
            }
            .disabled(priority >= total)
        }

        Section {
            // 镜像电台没有可编辑的地址，把它摆在这里至少能认出这条是哪台服务器给的。
            if station.isServerMirror {
                Label(station.displayEndpoint, systemImage: "server.rack")
                    .foregroundStyle(.secondary)
            }

            organizeMenu(for: station)

            // 自动发现失败过的台在退避期里不会再自己去找，这里给用户一个
            // 「现在就再试一次」的出口。用户自己选过图或填过链接的不提供 ——
            // 那会覆盖他的选择。
            if !station.isServerMirror,
               station.logoData == nil,
               station.logoFileName == nil,
               station.remoteLogoSource?.isUserProvided != true {
                Button("radio_logo_fetch", systemImage: "photo.badge.arrow.down") {
                    RadioLogoDiscoveryService.shared.discoverNow(for: station)
                }
            }
        }

        if !station.isServerMirror {
            // 破坏性动作单独成段落在最后，跟上面隔开。
            Section {
                Button("delete", systemImage: "trash", role: .destructive) {
                    if station.isSubscribed {
                        subscribedStationToDelete = station
                    } else {
                        store.remove(id: station.id)
                    }
                }
            }
        }
    }

    /// 单条电台的归类菜单。批量版在工具栏里，这里是给「就改这一个」用的。
    @ViewBuilder
    private func organizeMenu(for station: RadioStation) -> some View {
        Menu {
            folderAssignmentActions(for: [station.id])
        } label: {
            Label("radio_folder_move", systemImage: "folder")
        }
        Menu {
            tagAssignmentActions(for: [station.id])
        } label: {
            Label("radio_tags", systemImage: "tag")
        }
    }

    private func folderSectionHeader(_ group: RadioStationFolderGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.isUngrouped ? "tray" : "folder.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(group.name ?? String(localized: "radio_folder_ungrouped"))
                .font(.subheadline.weight(.semibold))
            Text(verbatim: "\(group.stations.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 吸顶的分组标题要盖住从下面滚过去的行,所以必须不透明:经典皮肤下是系统底色,
        // 自己画页面底色的皮肤下用皮肤的页面底色。
        .background(skin.cardFill(classic: .background, token: .canvas))
        .contextMenu {
            if let name = group.name {
                folderChipActions(name)
            }
        }
    }

    // MARK: - 管理态

    /// 管理态的多选列表。`editMode` 常开 —— 用户点「管理」就是来批量操作的，
    /// 再要求他去菜单里点一次「选择」才出现勾选圈，中间那个状态看着像坏了。
    /// 勾选圈、拖动柄、批量选中手势全由系统提供。
    ///
    /// 单条操作不在这里：网格态的卡片自带 ⋯ 菜单(编辑/归类/上移/下移/删除)，
    /// 所以这一屏可以专心做多选，不必再兼顾左右滑 —— 编辑态下系统本来也会
    /// 吞掉滑动手势。
    ///
    /// 服务器镜像在这里是**可以选中**的：它不能改名不能删，但归入文件夹、
    /// 贴标签是用户自己的整理，对镜像同样成立。
    private var manageList: some View {
        List(selection: $selection) {
            Section {
                ForEach(visibleStations) { station in
                    manageRow(station: station)
                        .tag(station.id)
                        .deleteDisabled(station.isServerMirror)
                }
                .onMove(perform: moveVisible)
                .onDelete { offsets in
                    let ordered = visibleStations
                    for index in offsets where ordered.indices.contains(index) {
                        store.remove(id: ordered[index].id)
                    }
                }
                .skinListRowBackground()
            } footer: {
                Text("radio_manage_footer")
            }
        }
        // 多选列表用不了 SkinList,底色与行底两处手工挂上。
        .skinPageBackground()
        #if os(iOS)
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    /// 在当前可见的子集里拖动排序。筛选状态下不能直接把可见下标喂给全局顺序 ——
    /// 那会把没显示出来的电台一起搅乱。
    private func moveVisible(from offsets: IndexSet, to destination: Int) {
        store.moveStations(from: offsets, to: destination, within: visibleStations)
    }

    private func manageRow(station: RadioStation) -> some View {
        HStack(spacing: 12) {
            RadioStationArtworkView(station: station, size: 52, cornerRadius: 11)

            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(station.playbackSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                RadioStationOrganizeLabels(station: station)
                Text(station.displayEndpoint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 6)
    }

    /// 置顶保持选中项之间的相对顺序，其余的原样跟在后面（只改被置顶的台的序号）。
    private func moveToTop(_ ids: Set<String>) {
        let picked = store.stations.filter { ids.contains($0.id) && !$0.isServerMirror }
        guard !picked.isEmpty else { return }
        store.moveToTop(ids: picked.map(\.id))
    }

    private func exportSelected() {
        let stations = selectedStations
        guard !stations.isEmpty else { return }
        exportDocument = RadioPlaylistDocument(stations: stations)
        showExporter = true
    }

    private func deleteSelected() {
        for station in selectedStations { store.remove(id: station.id) }
        selection = []
    }

    private func toggle(_ station: RadioStation) {
        // `.pls` 包装先放行:它拆出来的真实流主机由播放器在起播时再问。
        if !RadioImportParser.isPlaylistWrapper(station.streamURL),
           let url = station.url,
           TrustedHTTPTransport.requiresPlainSocket(for: url),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) {
            pendingInsecureStation = station
            return
        }
        performToggle(station)
    }

    private func performToggle(_ station: RadioStation) {
        if player.currentRadioStation?.id == station.id,
           player.isPlaying || player.isLoading {
            player.pause()
        } else {
            SiriMediaInteractionDonor.donate(station: station)
            Task { await player.play(station: station, within: store.stations) }
        }
    }
}

/// 导出选中电台为 `.m3u`。带 `#EXTINF` 名字、`group-title` 和 `tvg-logo`，
/// 导回来时 `RadioImportParser` 能连文件夹和台标一起还原，别的播放器也认这两个属性。
struct RadioPlaylistDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.m3uPlaylist, .plainText] }

    var stations: [RadioStation]

    init(stations: [RadioStation] = []) {
        self.stations = stations
    }

    init(configuration: ReadConfiguration) throws {
        stations = []
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var lines = ["#EXTM3U"]
        for station in stations {
            var attributes = ""
            if let folder = station.assignedFolderName {
                attributes += " group-title=\"\(Self.attributeValue(folder))\""
            }
            if let logo = RadioLogoURLPolicy.normalized(station.remoteLogoURL) {
                attributes += " tvg-logo=\"\(Self.attributeValue(logo))\""
            }
            lines.append("#EXTINF:-1\(attributes),\(Self.attributeValue(station.name))")
            lines.append(station.streamURL)
        }
        let data = Data(lines.joined(separator: "\n").utf8)
        return FileWrapper(regularFileWithContents: data)
    }

    /// 属性值里出现引号或换行会让这一行的结构塌掉，直接去掉。
    private static func attributeValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

extension UTType {
    /// 系统没有内建 m3u 的常量；从扩展名解析，解不到就退回纯文本。
    static var m3uPlaylist: UTType {
        UTType(filenameExtension: "m3u") ?? .plainText
    }
}


#if os(iOS)
/// 电台页顶部的「正在直播」卡。只在当前正放着一个电台时出现。
///
/// 播放状态在这里读:节目标题一变只重画这张卡。点卡片空白处打开播放页。
private struct RadioOnAirHero: View {
    @Environment(AudioPlayerService.self) private var player
    @State private var showsSleepTimer = false

    var body: some View {
        if let station = player.currentRadioStation {
            let isActive = player.isPlaying || player.isLoading
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    if isActive {
                        HStack(spacing: 5) {
                            Circle().fill(.white).frame(width: 6, height: 6)
                            Text("live_badge").font(.caption.weight(.heavy))
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(Color(red: 1, green: 0.23, blue: 0.36), in: Capsule())
                        .accessibilityLabel(Text("radio_live"))
                    }
                    if isActive, player.currentTime > 0 {
                        Text(player.currentTime.formattedDuration)
                            .font(.caption.monospacedDigit())
                            .opacity(0.72)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 16) {
                    RadioStationArtworkView(station: station, size: 88, cornerRadius: 18)
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: station.name)
                            .font(.title2.weight(.heavy))
                            .lineLimit(2)
                        if let program = player.radioMetadataTitle, !program.isEmpty {
                            Text(verbatim: program)
                                .font(.subheadline)
                                .opacity(0.78)
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 30) {
                    Spacer(minLength: 0)
                    Button {
                        Task { await player.previous() }
                    } label: {
                        Image(systemName: "backward.fill").font(.title2)
                    }
                    .disabled(!player.canSwitchRadioStation)
                    .opacity(player.canSwitchRadioStation ? 1 : 0.4)
                    .accessibilityLabel(Text("radio_previous_station"))

                    Button { player.togglePlayPause() } label: {
                        Image(systemName: isActive ? "stop.fill" : "play.fill")
                            .font(.title2)
                            .foregroundStyle(.black)
                            .frame(width: 60, height: 60)
                            .background(.white, in: Circle())
                    }
                    .accessibilityLabel(Text(isActive ? "radio_stop" : "a11y_play"))

                    Button {
                        Task { await player.next() }
                    } label: {
                        Image(systemName: "forward.fill").font(.title2)
                    }
                    .disabled(!player.canSwitchRadioStation)
                    .opacity(player.canSwitchRadioStation ? 1 : 0.4)
                    .accessibilityLabel(Text("radio_next_station"))
                    Spacer(minLength: 0)
                }
                .buttonStyle(.plain)
                .overlay(alignment: .trailing) {
                    Button { showsSleepTimer = true } label: {
                        Image(systemName: player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                            .background(.white.opacity(0.16), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(player.isSleepTimerActive ? "sleep_timer_active" : "sleep_timer"))
                }
            }
            .foregroundStyle(.white)
            .padding(18)
            .background {
                ZStack {
                    RadioStationArtworkView(station: station, size: 320, cornerRadius: 0)
                        .blur(radius: 40)
                        .scaleEffect(1.5)
                    Color.black.opacity(0.46)
                }
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .accessibilityHidden(true)
            }
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .onTapGesture {
                NotificationCenter.default.post(name: .primuseRequestShowNowPlaying, object: nil)
            }
            .accessibilityAction(named: Text("now_playing")) {
                NotificationCenter.default.post(name: .primuseRequestShowNowPlaying, object: nil)
            }
            .confirmationDialog(String(localized: "sleep_timer"), isPresented: $showsSleepTimer) {
                ForEach([5, 15, 30, 45, 60, 90], id: \.self) { minutes in
                    Button("\(minutes) " + String(localized: "minutes")) { player.scheduleSleep(minutes: minutes) }
                }
                if player.isSleepTimerActive {
                    Button(String(localized: "cancel_timer"), role: .destructive) { player.cancelSleep() }
                }
                Button(String(localized: "cancel"), role: .cancel) {}
            }
        }
    }
}
#endif

/// 网格末尾的「添加电台」:虚线框一格,打开批量添加。两种版式各自配一个大小。
private struct RadioAddStationTile: View {
    let layoutMode: RadioStationLayoutMode
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                switch layoutMode {
                case .cover:
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 24, weight: .medium))
                        Text("radio_batch_add_title").font(.caption).multilineTextAlignment(.center)
                    }
                    .frame(width: 110, height: 110)
                case .list:
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.headline)
                        Text("radio_batch_add_title").font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 56)
                }
            }
            .foregroundStyle(.secondary)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// 电台页的一格。播放状态在这里读，而不是在整页的 body 里读：节目标题每更新一次、
/// 换一次台，只重画相关的一两张卡，整页的筛选、分组不跟着重算。
private struct RadioStationGridItem<Actions: View>: View {
    let station: RadioStation
    let layoutMode: RadioStationLayoutMode
    let priority: Int
    let onPlay: () -> Void
    @ViewBuilder let actions: () -> Actions

    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        let isCurrent = player.currentRadioStation?.id == station.id
        let isPlaying = isCurrent && (player.isPlaying || player.isLoading)
        switch layoutMode {
        case .list:
            RadioStationCard(
                station: station,
                priority: priority,
                isCurrent: isCurrent,
                isPlaying: isPlaying,
                metadataTitle: isCurrent ? player.radioMetadataTitle : nil,
                onPlay: onPlay,
                actions: actions
            )
        case .cover:
            RadioStationCoverTile(
                station: station,
                isCurrent: isCurrent,
                isPlaying: isPlaying,
                onPlay: onPlay,
                actions: actions
            )
        }
    }
}

private struct RadioStationCard<Actions: View>: View {
    let station: RadioStation
    let priority: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let metadataTitle: String?
    let onPlay: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                HStack(spacing: 14) {
                    RadioStationArtworkView(station: station, size: 72, cornerRadius: 16)

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(station.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if station.isServerMirror {
                                Image(systemName: "server.rack")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if station.isSubscribed {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(Text("radio_subscription_station_badge"))
                            }
                            Spacer(minLength: 4)
                            Text(verbatim: "#\(priority)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        if isCurrent {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 6, height: 6)
                                Text("live_badge")
                                    .font(.system(size: 9.5, weight: .bold))
                                    .tracking(0.8)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }

                        Text(metadataTitle ?? station.playbackSubtitle)
                            .font(.caption)
                            .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                            .lineLimit(2)

                        RadioStationOrganizeLabels(station: station)

                        // 订阅电台在本机认识那份订阅时，这一行换成订阅名。
                        Text(RadioSubscriptionText.stationSource(station) ?? station.displayEndpoint)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 4)

                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isPlaying ? Color.red : Color.accentColor)
                        .frame(width: 40, height: 40)
                        .background(.thinMaterial, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                        .pmAnimation(.control, value: isPlaying)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pmPressable)

            Menu {
                actions()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("radio_manage")
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
        .background(
            isCurrent ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(isCurrent ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.1), lineWidth: 0.7)
        }
        // 电台条数远小于曲库，底色/描边/LIVE 徽标可以在行内直接挂。
        .pmAnimation(.hover, value: isCurrent)
        .contextMenu {
            actions()
        }
    }
}

/// 封面版的一格。台标占满整格，名字和状态压在下面两行 ——
/// 台标齐全时这一屏能放下三四倍的电台。
private struct RadioStationCoverTile<Actions: View>: View {
    let station: RadioStation
    let isCurrent: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 7) {
                // 用空白容器定尺寸，台标以 .fit 填进去 —— 台标是 logo 不是照片，
                // 完整显示比填满后裁掉台名更重要，也不会让长图反过来撑大网格列。
                Color.clear
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        RadioStationArtworkContent(
                            station: station,
                            decodeSize: 200,
                            contentMode: .fit
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isPlaying ? Color.red : Color.accentColor)
                            .frame(width: 28, height: 28)
                            .background(.thinMaterial, in: Circle())
                            .contentTransition(.symbolEffect(.replace))
                            .pmAnimation(.control, value: isPlaying)
                            .padding(7)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                isCurrent ? Color.accentColor : Color.secondary.opacity(0.15),
                                lineWidth: isCurrent ? 1.6 : 0.6
                            )
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if isCurrent {
                            Circle().fill(.red).frame(width: 5, height: 5)
                        }
                        if station.isServerMirror {
                            Image(systemName: "server.rack")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        if station.isSubscribed {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        Text(station.playbackSubtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    RadioStationOrganizeLabels(station: station, maximumTags: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pmPressable)
        .pmAnimation(.hover, value: isCurrent)
        .contextMenu {
            actions()
        }
    }
}

struct SendableRadioArtworkCGImage: @unchecked Sendable {
    let value: CGImage?
}

/// 把台标缩成一张小位图读像素，交给 `RadioLogoBackdropPolicy` 定衬底颜色。
///
/// 电台列表、批量添加候选、两端编辑页都要垫同一块底，取样只写这一份。
enum RadioLogoBackdropSampler {
    static func backdrop(for image: CGImage?) -> RadioLogoBackdrop {
        guard let image else { return RadioLogoBackdropPolicy.light }
        let side = RadioLogoBackdropPolicy.sampleSide
        guard side > 0,
              let context = CGContext(
                  data: nil,
                  width: side,
                  height: side,
                  bitsPerComponent: 8,
                  bytesPerRow: side * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return RadioLogoBackdropPolicy.light
        }
        // 非正方形台标在这里会被拉成正方形，但最外一圈仍旧是原图的边缘，判色不受影响。
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let buffer = context.data else { return RadioLogoBackdropPolicy.light }
        let pixels = Array(UnsafeBufferPointer(
            start: buffer.assumingMemoryBound(to: UInt8.self),
            count: side * side * 4
        ))
        return RadioLogoBackdropPolicy.backdrop(pixels: pixels, width: side, height: side)
    }
}

extension RadioLogoBackdrop {
    /// 衬底故意不带平台颜色类型，画之前在这里转一次。
    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }
}

@MainActor
private enum RadioStationArtworkResourceResolver {
    nonisolated(unsafe) private static let failedLoadCache: NSCache<NSString, NSDate> = {
        let cache = NSCache<NSString, NSDate>()
        cache.countLimit = 500
        return cache
    }()

    private static let failedLoadCacheTTL: TimeInterval = 5 * 60

    static func resolve(
        plan: RadioStationArtworkResolutionPlan,
        maximumPixelSize: Int,
        networkPathGeneration: UInt64,
        cacheRevision: UInt64,
        sourceManager: SourceManager
    ) async -> RadioStationArtworkResolution<PlatformRadioImage>? {
        await RadioStationArtworkResolver.resolve(plan: plan) { candidate in
            switch candidate {
            case .inline(let data):
                return await decodeInlineLogo(data, maximumPixelSize: maximumPixelSize)

            case .cachedOrSource(let request):
                let failureKey = failureKey(
                    for: request,
                    networkPathGeneration: networkPathGeneration
                )
                guard !hasRecentFailure(for: failureKey) else { return nil }
                let image = await CachedArtworkView.resolveImage(
                    coverRef: request.coverReference,
                    songID: request.songID,
                    size: CGFloat(maximumPixelSize) / 3,
                    sourceID: request.sourceID,
                    filePath: request.filePath,
                    fileFormat: request.fileFormat,
                    sourceManager: sourceManager,
                    cacheDiscriminator: "\(request.cacheDiscriminator)#revision-\(cacheRevision)"
                )
                guard !Task.isCancelled else { return nil }
                if image == nil {
                    failedLoadCache.setObject(NSDate(), forKey: failureKey)
                } else {
                    failedLoadCache.removeObject(forKey: failureKey)
                }
                return image
            }
        }
    }

    static func clearFailure(
        for request: RadioStationArtworkRemoteRequest,
        networkPathGeneration: UInt64
    ) {
        failedLoadCache.removeObject(forKey: failureKey(
            for: request,
            networkPathGeneration: networkPathGeneration
        ))
    }

    private static func failureKey(
        for request: RadioStationArtworkRemoteRequest,
        networkPathGeneration: UInt64
    ) -> NSString {
        "\(request.cacheDiscriminator)#network-\(networkPathGeneration)" as NSString
    }

    private static func hasRecentFailure(for key: NSString) -> Bool {
        guard let failedAt = failedLoadCache.object(forKey: key) else { return false }
        if abs(failedAt.timeIntervalSinceNow) < failedLoadCacheTTL {
            return true
        }
        failedLoadCache.removeObject(forKey: key)
        return false
    }

    private static func decodeInlineLogo(
        _ data: Data,
        maximumPixelSize: Int
    ) async -> PlatformRadioImage? {
        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return SendableRadioArtworkCGImage(value: nil) }
            let image = makeThumbnail(from: data, maximumPixelSize: maximumPixelSize)
            guard !Task.isCancelled else { return SendableRadioArtworkCGImage(value: nil) }
            return SendableRadioArtworkCGImage(value: image)
        }
        let decoded = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, let image = decoded.value else { return nil }
        return PlatformRadioImage.fromCGImage(image)
    }

    private nonisolated static func makeThumbnail(
        from data: Data,
        maximumPixelSize: Int
    ) -> CGImage? {
        // 矢量台标 ImageIO 解不了，先交给栅格化器。
        if SVGImageSupport.looksLikeSVG(data) {
            return SVGArtworkRasterizer.makeCGImage(from: data, maximumPixelSize: maximumPixelSize)
        }
        guard ArtworkImageCompatibility.isCompleteImage(data),
              !ArtworkImageCompatibility.hasRedundantJPEGSampling(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private struct RadioStationArtworkLoadKey: Hashable {
    let identity: RadioStationArtworkResolutionIdentity
    let maximumPixelSize: Int
    let networkPathGeneration: UInt64
    let cacheRevision: UInt64
}

/// The layout-independent radio artwork surface. Callers own its frame, aspect
/// ratio, clipping, and corner radius; every surface shares the same source
/// priority, async decoding, cancellation, and stale-result protection.
struct RadioStationArtworkContent: View {
    let station: RadioStation
    var decodeSize: CGFloat = 320
    var contentMode: ContentMode = .fill

    @Environment(SourceManager.self) private var sourceManager
    @State private var image: PlatformRadioImage?
    @State private var backdrop: RadioLogoBackdrop?
    @State private var resolvedIdentity: RadioStationArtworkResolutionIdentity?
    @State private var cacheRevision: UInt64 = 0

    private var plan: RadioStationArtworkResolutionPlan {
        RadioStationArtworkResolutionPolicy.makePlan(for: station)
    }

    private var maximumPixelSize: Int {
        min(max(Int(decodeSize.rounded(.up) * 3), 96), 1_536)
    }

    private var loadKey: RadioStationArtworkLoadKey {
        RadioStationArtworkLoadKey(
            identity: plan.identity,
            maximumPixelSize: maximumPixelSize,
            networkPathGeneration: NetworkMonitor.shared.pathGeneration,
            cacheRevision: cacheRevision
        )
    }

    private var remoteRequest: RadioStationArtworkRemoteRequest? {
        for candidate in plan.candidates {
            if case .cachedOrSource(let request) = candidate { return request }
        }
        return nil
    }

    var body: some View {
        let currentPlan = plan
        let currentLoadKey = loadKey

        ZStack {
            // 占位图是渐变加同心环,台标一旦带透明通道、或者按 .fit 摆放留出两侧
            // 空白,那个图案就会透出来。有台标时改垫一块由台标自己定色的纯底。
            if resolvedIdentity == currentPlan.identity, let image, let backdrop {
                // 台标由 .task 裸赋值,调用点包不了事务,曲线附在过渡上。
                backdrop.color
                    .pmFadeTransition(motion: .contentAppear)
                Image(platformRadioImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .pmFadeTransition(motion: .contentAppear)
            } else {
                RadioStationPlaceholderArtwork()
                    .pmFadeTransition(motion: .contentAppear)
            }
        }
        .task(id: currentLoadKey) {
            let capturedIdentity = currentPlan.identity
            if resolvedIdentity != capturedIdentity {
                image = nil
                backdrop = nil
                resolvedIdentity = nil
            }
            let resolved = await RadioStationArtworkResourceResolver.resolve(
                plan: currentPlan,
                maximumPixelSize: currentLoadKey.maximumPixelSize,
                networkPathGeneration: currentLoadKey.networkPathGeneration,
                cacheRevision: currentLoadKey.cacheRevision,
                sourceManager: sourceManager
            )
            guard RadioStationArtworkResultPolicy.shouldApply(
                completedIdentity: capturedIdentity,
                displayedIdentity: plan.identity,
                isCancelled: Task.isCancelled
            ) else { return }
            guard let logo = resolved?.value else {
                image = nil
                backdrop = nil
                resolvedIdentity = capturedIdentity
                return
            }
            let sampled = SendableRadioArtworkCGImage(value: logo.platformCGImage)
            let sampling = Task.detached(priority: .utility) {
                RadioLogoBackdropSampler.backdrop(for: sampled.value)
            }
            let logoBackdrop = await sampling.value
            // 取样这段时间里电台可能已经换了,回到主线程要再判一次身份。
            guard RadioStationArtworkResultPolicy.shouldApply(
                completedIdentity: capturedIdentity,
                displayedIdentity: plan.identity,
                isCancelled: Task.isCancelled
            ) else { return }
            // 台标和衬底必须同一次赋值,否则会先露一帧没垫底的台标。
            image = logo
            backdrop = logoBackdrop
            resolvedIdentity = capturedIdentity
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidInvalidate)) { note in
            let tokens = artworkInvalidationTokens(from: note)
            guard RadioStationArtworkCacheRevisionPolicy.shouldReloadAfterInvalidation(
                invalidatesAll: note.userInfo?["all"] as? Bool == true,
                invalidatedTokens: tokens,
                request: remoteRequest
            ), let remoteRequest else { return }
            RadioStationArtworkResourceResolver.clearFailure(
                for: remoteRequest,
                networkPathGeneration: NetworkMonitor.shared.pathGeneration
            )
            cacheRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
            guard RadioStationArtworkCacheRevisionPolicy.shouldReloadAfterCaching(
                cachedSongID: note.object as? String,
                request: remoteRequest,
                hasResolvedImage: resolvedIdentity == plan.identity && image != nil
            ), let remoteRequest else { return }
            RadioStationArtworkResourceResolver.clearFailure(
                for: remoteRequest,
                networkPathGeneration: NetworkMonitor.shared.pathGeneration
            )
            cacheRevision &+= 1
        }
    }

    private func artworkInvalidationTokens(from note: Notification) -> [String] {
        var tokens: [String] = []
        if let token = note.object as? String, !token.isEmpty {
            tokens.append(token)
        }
        for key in ["songID", "oldRef", "newRef"] {
            if let token = note.userInfo?[key] as? String, !token.isEmpty {
                tokens.append(token)
            }
        }
        if let values = note.userInfo?["tokens"] as? [String] {
            tokens.append(contentsOf: values)
        }
        if let values = note.userInfo?["songIDs"] as? [String] {
            tokens.append(contentsOf: values)
        }
        return tokens
    }
}

struct RadioStationArtworkView: View {
    let station: RadioStation
    var size: CGFloat
    var cornerRadius: CGFloat

    var body: some View {
        RadioStationArtworkContent(station: station, decodeSize: size)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// 无台标时用当前主题色构成单色信号场，避免固定紫蓝色从整套外观里跳出来。
/// 同心环只承担“广播信号”的识别，不参与播放状态表达。
struct RadioStationPlaceholderArtwork: View {
    @Environment(ThemeService.self) private var theme

    var body: some View {
        GeometryReader { proxy in
            let side = max(min(proxy.size.width, proxy.size.height), 1)

            ZStack {
                theme.uiDarkAccent

                LinearGradient(
                    colors: [
                        theme.uiAccentColor.opacity(0.82),
                        theme.uiAccentColor.opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .stroke(.white.opacity(0.10), lineWidth: max(1, side * 0.008))
                    .frame(width: side * 0.82, height: side * 0.82)

                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: max(1, side * 0.009))
                    .frame(width: side * 0.58, height: side * 0.58)

                Image(systemName: "radio.fill")
                    .font(.system(size: side * 0.31, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct RadioStationEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(RadioStationsStore.self) private var store
    @Environment(AudioPlayerService.self) private var player

    let station: RadioStation?
    /// 「转为我自己的电台」之后交给调用方接着编辑新电台；不给就直接关掉编辑页。
    private let onDetach: ((RadioStation) -> Void)?
    @State private var name: String
    @State private var urlString: String
    @State private var logoData: Data?
    @State private var logoURLString: String
    @State private var pickerItem: PhotosPickerItem?
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var resultMessage: String?
    @State private var insecureHTTPHost: String?
    @State private var pendingTestAfterTrust = false

    init(station: RadioStation?, onDetach: ((RadioStation) -> Void)? = nil) {
        self.station = station
        self.onDetach = onDetach
        _name = State(initialValue: station?.name ?? "")
        _urlString = State(initialValue: station?.streamURL ?? "")
        _logoData = State(initialValue: station?.logoData)
        _logoURLString = State(initialValue: station?.remoteLogoURL ?? "")
    }

    /// 填了地址就必须是个能用的 http(s) 地址。留空表示不要远程台标。
    private var normalizedLogoURL: String? {
        RadioLogoURLPolicy.normalized(logoURLString)
    }

    private var isLogoURLAcceptable: Bool {
        logoURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || normalizedLogoURL != nil
    }

    private var canSave: Bool {
        RadioStationValidation.isValid(name: name, urlString: urlString)
            && isLogoURLAcceptable
            && !isSaving
    }

    /// 订阅电台的名称和地址归清单所有，编辑页里只读。
    private var isSubscribed: Bool { station?.isSubscribed == true }

    var body: some View {
        NavigationStack {
            SkinForm {
                Section {
                    TextField("radio_name", text: $name)
                        .disabled(isSubscribed)
                    TextField("radio_stream_url", text: $urlString)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                        .disabled(isSubscribed)
                } header: {
                    Text("radio_details")
                } footer: {
                    if let station, station.isSubscribed {
                        Text(RadioSubscriptionText.editorNote(for: station))
                    }
                }

                if isSubscribed {
                    Section {
                        Button("radio_subscription_detach", systemImage: "person.crop.circle.badge.checkmark") {
                            detach()
                        }
                    } footer: {
                        Text("radio_subscription_detach_footer")
                    }
                }

                Section {
                    HStack(spacing: 16) {
                        RadioEditorArtwork(data: logoData, remoteURLString: normalizedLogoURL)
                        VStack(alignment: .leading, spacing: 10) {
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                Label("radio_choose_logo", systemImage: "photo")
                            }
                            if logoData != nil {
                                Button("radio_remove_logo", role: .destructive) {
                                    pickerItem = nil
                                    logoData = nil
                                }
                            }
                        }
                    }

                    TextField("radio_logo_url", text: $logoURLString)
                        .font(.footnote)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif

                    if !isLogoURLAcceptable {
                        Text("radio_logo_url_invalid")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("radio_logo_optional")
                } footer: {
                    Text("radio_logo_url_hint")
                }

                Section {
                    Button {
                        beginTest()
                    } label: {
                        HStack {
                            Label("radio_test_playback", systemImage: "waveform")
                            Spacer()
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                                    // 试听状态由回调裸赋值,曲线附在过渡上;表单里只做淡入淡出。
                                    .pmFadeTransition(motion: .control)
                            }
                        }
                    }
                    .disabled(!canSave || isTesting)

                    if let resultMessage {
                        Text(resultMessage)
                            .font(.caption)
                            .foregroundStyle(resultMessage == String(localized: "radio_test_success") ? .green : .secondary)
                            .pmFadeTransition(motion: .control)
                    }
                } footer: {
                    Text("radio_test_description")
                }
            }
            .navigationTitle(station == nil ? "radio_add" : "radio_edit")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") { save() }
                        .disabled(!canSave)
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let processed = RadioLogoProcessor.process(data) else {
                        resultMessage = String(localized: "radio_logo_invalid")
                        return
                    }
                    logoData = processed
                }
            }
            .alert("insecure_http_warning_title", isPresented: Binding(
                get: { insecureHTTPHost != nil },
                set: { if !$0 { insecureHTTPHost = nil; pendingTestAfterTrust = false } }
            )) {
                Button("cancel", role: .cancel) {
                    insecureHTTPHost = nil
                    pendingTestAfterTrust = false
                }
                Button("insecure_http_continue", role: .destructive) {
                    guard let host = insecureHTTPHost else { return }
                    SSLTrustStore.shared.allowInsecureHTTP(domain: host)
                    insecureHTTPHost = nil
                    if pendingTestAfterTrust {
                        pendingTestAfterTrust = false
                        runTest()
                    }
                }
            } message: {
                Text(String(format: String(localized: "insecure_http_warning_message %@"), insecureHTTPHost ?? ""))
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 470)
        #endif
    }

    private func detach() {
        guard let station,
              let ownID = store.detachFromSubscription(id: station.id),
              let own = store.station(id: ownID) else { return }
        if let onDetach {
            onDetach(own)
        } else {
            dismiss()
        }
    }

    private func beginTest() {
        guard let normalized = RadioStationValidation.normalizedURLString(urlString),
              let url = URL(string: normalized) else { return }
        if TrustedHTTPTransport.requiresPlainSocket(for: url),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) {
            pendingTestAfterTrust = true
            insecureHTTPHost = trustTarget
            return
        }
        runTest()
    }

    private func runTest() {
        guard let normalized = RadioStationValidation.normalizedURLString(urlString),
              let url = URL(string: normalized) else { return }
        isTesting = true
        resultMessage = nil
        Task {
            let result = await player.testRadioStream(url: url)
            isTesting = false
            switch result {
            case .success:
                resultMessage = String(localized: "radio_test_success")
            case .failure(let error):
                resultMessage = String(format: String(localized: "radio_test_failed %@"), error.localizedDescription)
            }
        }
    }

    private func save() {
        guard let normalizedURL = RadioStationValidation.normalizedURLString(urlString),
              isLogoURLAcceptable else { return }
        isSaving = true
        Task {
            let id = station?.id ?? UUID().uuidString
            let logoFileName: String?
            if let logoData {
                logoFileName = await MetadataAssetStore.shared.storeCover(logoData, for: "radio:\(id)")
            } else {
                logoFileName = nil
                // 用户把台标清掉了，磁盘上那张旧图得一起清 —— 否则锁屏与车机
                // 仍会按电台的 songID 从缓存里把它读出来。
                await MetadataAssetStore.shared.invalidateCoverCache(forSongID: "radio:\(id)")
            }
            let logoURL = normalizedLogoURL
            // 地址没动过就保留它原来的来源 —— 打开编辑页按一下保存，不该把
            // 自动找来的台标"升格"成用户指定的，那会让自动发现从此再也不更新它。
            let logoSource: RadioLogoSource?
            if let logoURL {
                logoSource = logoURL == station?.remoteLogoURL
                    ? (station?.remoteLogoSource ?? .userProvidedURL)
                    : .userProvidedURL
            } else {
                logoSource = nil
            }
            if logoURL != station?.remoteLogoURL {
                await MetadataAssetStore.shared.invalidateCoverCache(
                    forSongID: RadioStationArtworkResolutionPolicy.remoteLogoCacheSongID(for: id)
                )
            }
            let value = RadioStation(
                id: id,
                name: RadioStationValidation.normalizedName(name),
                streamURL: normalizedURL,
                logoData: logoData,
                logoFileName: logoFileName,
                streamFormat: station?.streamFormat ?? RadioStreamFormat.inferred(from: URL(string: normalizedURL)!),
                bitRate: station?.bitRate,
                createdAt: station?.createdAt ?? Date(),
                modifiedAt: Date(),
                lastPlayedAt: station?.lastPlayedAt,
                sortOrder: station?.sortOrder,
                homepageURL: station?.homepageURL,
                remoteLogoURL: logoURL,
                remoteLogoSource: logoSource,
                folderName: station?.folderName,
                tagNames: station?.tagNames
            )
            store.upsert(value)
            isSaving = false
            dismiss()
        }
    }
}

private struct RadioEditorArtwork: View {
    let data: Data?
    var remoteURLString: String?

    var body: some View {
        Group {
            if let data, let image = PlatformRadioImage(data: data) {
                // 别的设备同步过来的 logoData 不保证是不透明的 JPEG,垫一块由台标
                // 自己定色的底,免得透明台标直接压在弹框背景上。
                let backdrop = RadioLogoBackdropSampler.backdrop(for: image.platformCGImage)
                ZStack {
                    backdrop.color
                    Image(platformRadioImage: image)
                        .resizable()
                        .scaledToFill()
                }
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if let remoteURLString {
                // 走和列表同一套加载器，矢量台标在这里也能预览；
                // 加载不出来时它自己会显示默认台标。
                RadioCandidateLogoView(urlString: remoteURLString, size: 84, cornerRadius: 14)
            } else {
                RadioStationPlaceholderArtwork()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

private enum RadioLogoProcessor {
    static func process(_ data: Data) -> Data? {
        // 矢量图先栅格化再往下走：`logoData` 会进 CloudKit 同步，被电视端、
        // 小组件和锁屏直接读，那些地方没有矢量解析器。
        if SVGImageSupport.looksLikeSVG(data) {
            guard let rasterized = SVGArtworkRasterizer.pngData(
                from: data,
                maximumPixelSize: 512
            ) else { return nil }
            return process(rasterized)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else {
            return nil
        }
        let maxDimension: CGFloat = 512
        let scale = min(1, maxDimension / max(width, height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(width, height) * scale),
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              output.length <= RadioStationValidation.maximumLogoBytes else { return nil }
        return output as Data
    }
}

#if os(iOS)
private typealias PlatformRadioImage = UIImage

private extension Image {
    init(platformRadioImage image: UIImage) { self.init(uiImage: image) }
}
#elseif os(macOS)
private typealias PlatformRadioImage = NSImage

private extension Image {
    init(platformRadioImage image: NSImage) { self.init(nsImage: image) }
}
#endif
