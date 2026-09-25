#if os(macOS)
import SwiftUI
import PrimuseKit

/// macOS 原生电台页。跟 `MacSourcesView` 同一套骨架：大标题 + 摘要行
/// 的 action bar，下面是 2 列卡片网格；卡片走 `pmCard`，按钮走 PM token，
/// 不用 iOS 那套 Form / ContentUnavailableView / .bordered。
struct MacRadioStationsView: View {
    @Environment(RadioStationsStore.self) private var store
    @Environment(AudioPlayerService.self) private var player

    @State private var editingStation: RadioStation?
    @State private var showAddStation = false
    @State private var showBatchAdd = false
    @State private var stationToDelete: RadioStation?
    @State private var pendingInsecureStation: RadioStation?
    @State private var folderScope: RadioStationFilter.FolderScope = .all
    @State private var activeTags: Set<String> = []
    @State private var searchText = ""
    @State private var namePrompt: RadioNamePrompt?
    @State private var namePromptText = ""
    @State private var folderToDelete: String?
    @State private var tagToDelete: String?
    @State private var showSubscriptions = false
    /// 从「+」菜单进来时直接停在「添加订阅」；从状态行进来时停在订阅列表。
    @State private var subscriptionsStartAdding = false
    /// 右键菜单「电台信息」打开的详情页。点卡片本身仍是直接起播。
    @State private var detailStation: RadioStation?
    @AppStorage(RadioStationLayoutMode.storageKey)
    private var layoutModeRaw = RadioStationLayoutMode.list.rawValue

    private var layoutMode: RadioStationLayoutMode {
        RadioStationLayoutMode(rawValue: layoutModeRaw) ?? .list
    }

    /// 列表版一行一个宽卡片；封面版是方格台标墙，一屏能放下三四倍的台。
    private var columns: [GridItem] {
        switch layoutMode {
        case .list:
            return [GridItem(.adaptive(minimum: 340, maximum: 520), spacing: PMSpace.m16)]
        case .cover:
            return [GridItem(.adaptive(minimum: 130, maximum: 190), spacing: PMSpace.m)]
        }
    }

    private var stations: [RadioStation] { store.stations }

    private var filter: RadioStationFilter {
        RadioStationFilter(folder: folderScope, tagNames: activeTags, searchText: searchText)
    }

    private var visibleStations: [RadioStation] {
        RadioStationOrganization.filtered(stations, with: filter)
    }

    private var folders: [RadioStationFolderSummary] { store.folders }
    private var tags: [RadioStationTagSummary] { store.tags }

    /// `#N` 是电台在全局优先级里的位次，筛选不改变它。
    private var priorityByID: [String: Int] {
        Dictionary(uniqueKeysWithValues: stations.enumerated().map { ($1.id, $0 + 1) })
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionBar
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 进列表时给还没有台标的电台排一次自动发现，重复进入由服务自己去重。
        .task {
            RadioLogoDiscoveryService.shared.discoverIfNeeded(for: stations)
        }
        .sheet(isPresented: $showAddStation) {
            MacRadioStationEditorView(station: nil)
        }
        .sheet(item: $editingStation) { station in
            // 「转为我自己的电台」之后直接接着编辑新建的那个电台。
            MacRadioStationEditorView(station: station) { own in
                editingStation = own
            }
        }
        .sheet(isPresented: $showBatchAdd) {
            MacRadioBatchAddView()
        }
        .sheet(isPresented: $showSubscriptions) {
            RadioSubscriptionsView(startsAdding: subscriptionsStartAdding)
        }
        .sheet(item: $detailStation) { station in
            RadioStationDetailView(stationID: station.id)
        }
        .confirmationDialog(
            Text("radio_manage_delete_confirm_title"),
            isPresented: Binding(
                get: { stationToDelete != nil },
                set: { if !$0 { stationToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: stationToDelete
        ) { station in
            Button(role: .destructive) {
                store.remove(id: station.id)
                stationToDelete = nil
            } label: {
                Text("delete")
            }
            Button(role: .cancel) { stationToDelete = nil } label: { Text("cancel") }
        } message: { station in
            if station.isSubscribed {
                Text(
                    String(localized: "radio_manage_delete_confirm_message")
                        + "\n" + String(localized: "radio_subscription_delete_note")
                )
            } else {
                Text("radio_manage_delete_confirm_message")
            }
        }
        .alert("insecure_http_warning_title", isPresented: Binding(
            get: { pendingInsecureStation != nil },
            set: { if !$0 { pendingInsecureStation = nil } }
        )) {
            Button("cancel", role: .cancel) { pendingInsecureStation = nil }
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
            Button("cancel", role: .cancel) { namePrompt = nil }
            Button("save") { commitNamePrompt() }
        }
        .confirmationDialog(
            Text("radio_folder_delete"),
            isPresented: Binding(
                get: { folderToDelete != nil },
                set: { if !$0 { folderToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                guard let name = folderToDelete else { return }
                if case .folder(let current) = folderScope,
                   RadioStationOrganization.isSameName(current, name) {
                    folderScope = .all
                }
                store.deleteFolder(name)
                folderToDelete = nil
            } label: {
                Text("delete")
            }
            Button(role: .cancel) { folderToDelete = nil } label: { Text("cancel") }
        } message: {
            Text("radio_folder_delete_message")
        }
        .confirmationDialog(
            Text("radio_tag_delete"),
            isPresented: Binding(
                get: { tagToDelete != nil },
                set: { if !$0 { tagToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                guard let name = tagToDelete else { return }
                activeTags.remove(name)
                store.deleteTag(name)
                tagToDelete = nil
            } label: {
                Text("delete")
            }
            Button(role: .cancel) { tagToDelete = nil } label: { Text("cancel") }
        } message: {
            Text("radio_tag_delete_message")
        }
    }

    // MARK: - Action bar

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: PMSpace.m16) {
                Text("radio_title")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(PMColor.text)

                Spacer()

                if !stations.isEmpty {
                    searchField
                    layoutToggle
                }

                if !stations.isEmpty {
                    Button {
                        pmWithAnimation(.list) { store.sortStationsByName() }
                    } label: {
                        Text("radio_priority_sort_by_name")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(PMColor.text)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.m))
                            .overlay {
                                RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                            }
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    Button("radio_add", systemImage: "plus") {
                        showAddStation = true
                    }
                    Button("radio_batch_add_title", systemImage: "square.and.arrow.down") {
                        showBatchAdd = true
                    }
                    Button("radio_subscriptions_add", systemImage: "arrow.triangle.2.circlepath") {
                        subscriptionsStartAdding = true
                        showSubscriptions = true
                    }
                    Divider()
                    Button("radio_folder_new", systemImage: "folder.badge.plus") {
                        beginPrompt(.createFolder(assigning: []))
                    }
                } label: {
                    Label("radio_add", systemImage: "plus")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(PMColor.brand, in: .rect(cornerRadius: PMRadius.m))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            HStack(spacing: PMSpace.m) {
                Text(summaryText)
                    .font(.system(size: 13))
                    .foregroundStyle(PMColor.textMuted)
                // 有订阅时露一行紧凑状态，点进订阅管理。
                RadioSubscriptionStatusRow {
                    subscriptionsStartAdding = false
                    showSubscriptions = true
                }
                    .fixedSize()
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    /// 两格分段开关。Mac 上版式是随时会切的，藏进菜单里太深。
    private var layoutToggle: some View {
        HStack(spacing: 2) {
            ForEach(RadioStationLayoutMode.allCases) { mode in
                Button {
                    layoutModeRaw = mode.rawValue
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(layoutMode == mode ? PMColor.text : PMColor.textMuted)
                        .frame(width: 30, height: 26)
                        .background(
                            layoutMode == mode ? PMColor.glassBtn : .clear,
                            in: .rect(cornerRadius: PMRadius.xs)
                        )
                        .contentShape(Rectangle())
                        .pmAnimation(.hover, value: layoutMode == mode)
                }
                .buttonStyle(.plain)
                .help(String(localized: mode.titleKey))
            }
        }
        .padding(2)
        .frame(height: 32)
        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.m))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)

            TextField("radio_search_placeholder", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.text)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 230, height: 32)
        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.m))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
        }
    }

    private var summaryText: String {
        guard !stations.isEmpty else {
            return String(localized: "radio_empty_description")
        }
        var parts = [String(format: String(localized: "radio_mac_count %lld"), stations.count)]
        if let current = player.currentRadioStation,
           player.isPlaying || player.isLoading {
            parts.append(String(format: String(localized: "radio_mac_now_playing %@"), current.name))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if stations.isEmpty {
            emptyState
        } else {
            HStack(alignment: .top, spacing: 0) {
                folderRail
                Rectangle().fill(PMColor.divider).frame(width: 0.5)
                stationArea
            }
        }
    }

    // MARK: - 文件夹侧栏

    /// 左侧固定一列文件夹。Mac 上横向空间够，把文件夹排成一列比挤成一行胶囊
    /// 更容易扫，也给「把某个文件夹重命名/删掉」一个固定的落点。
    private var folderRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            railRow(
                title: String(localized: "radio_folder_all"),
                icon: "square.grid.2x2",
                count: stations.count,
                isSelected: isScopeSelected(.all)
            ) { folderScope = .all }

            let ungrouped = store.ungroupedStationCount
            if ungrouped > 0 {
                railRow(
                    title: String(localized: "radio_folder_ungrouped"),
                    icon: "tray",
                    count: ungrouped,
                    isSelected: isScopeSelected(.ungrouped)
                ) { folderScope = .ungrouped }
            }

            if !folders.isEmpty {
                Rectangle()
                    .fill(PMColor.divider)
                    .frame(height: 0.5)
                    .padding(.vertical, 6)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(folders) { folder in
                            railRow(
                                title: folder.name,
                                icon: "folder",
                                count: folder.stationCount,
                                isSelected: isScopeSelected(.folder(folder.name))
                            ) { folderScope = .folder(folder.name) }
                                .contextMenu { folderActions(folder.name) }
                        }
                    }
                }
            }

            Spacer(minLength: PMSpace.m)

            Button {
                beginPrompt(.createFolder(assigning: []))
            } label: {
                Label("radio_folder_new", systemImage: "folder.badge.plus")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, PMSpace.m)
        .padding(.top, 2)
        .padding(.bottom, PMSpace.m16)
        .frame(width: 196, alignment: .leading)
    }

    private func railRow(
        title: String,
        icon: String,
        count: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(verbatim: "\(count)")
                    .font(PMFont.monoXS)
                    .foregroundStyle(isSelected ? PMColor.text : PMColor.textFaint)
            }
            .foregroundStyle(isSelected ? PMColor.text : PMColor.textMuted)
            .padding(.horizontal, 9)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? PMColor.glassBtn : .clear,
                in: .rect(cornerRadius: PMRadius.s)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 标签条与网格

    private var stationArea: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tags) { tag in
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
                            .contextMenu { tagActions(tag.name) }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, PMSpace.m)
                }
            }

            if visibleStations.isEmpty {
                filteredEmptyState
            } else {
                stationGrid
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stationGrid: some View {
        let priorities = priorityByID
        let total = stations.count
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: PMSpace.m16) {
                // 搜索或筛选时用户要的是结果清单，「最近收听」让位。
                if !filter.isNarrowed {
                    RadioRecentStationsSection(
                        horizontalInset: 28,
                        onPlay: { toggle($0) },
                        onDetails: { detailStation = $0 }
                    )
                }

                LazyVGrid(
                    columns: columns,
                    alignment: .leading,
                    spacing: layoutMode == .cover ? PMSpace.m : PMSpace.m16
                ) {
                    ForEach(visibleStations) { station in
                        stationItem(station, priority: priorities[station.id] ?? 1, total: total)
                    }
                }
                .padding(.horizontal, 28)
            }
            .padding(.bottom, 36)
        }
    }

    @ViewBuilder
    private func stationItem(
        _ station: RadioStation,
        priority: Int,
        total: Int
    ) -> some View {
        let isCurrent = player.currentRadioStation?.id == station.id
        let isPlaying = isCurrent && (player.isPlaying || player.isLoading)
        switch layoutMode {
        case .list:
            MacRadioStationCard(
                station: station,
                priority: priority,
                isCurrent: isCurrent,
                isPlaying: isPlaying,
                metadataTitle: isCurrent ? player.radioMetadataTitle : nil,
                canMoveUp: priority > 1,
                canMoveDown: priority < total,
                onPlay: { toggle(station) },
                onEdit: { editingStation = station },
                onMoveUp: { pmWithAnimation(.list) { store.moveStation(id: station.id, by: -1) } },
                onMoveDown: { pmWithAnimation(.list) { store.moveStation(id: station.id, by: 1) } },
                actions: { stationActions(for: station, priority: priority, total: total) }
            )
        case .cover:
            MacRadioStationCoverTile(
                station: station,
                isCurrent: isCurrent,
                isPlaying: isPlaying,
                onPlay: { toggle(station) },
                actions: { stationActions(for: station, priority: priority, total: total) }
            )
        }
    }

    /// 一条电台的全部单条操作。两种版式的右键菜单共用这一份。
    @ViewBuilder
    private func stationActions(
        for station: RadioStation,
        priority: Int,
        total: Int
    ) -> some View {
        Button { detailStation = station } label: {
            Label("radio_details", systemImage: "info.circle")
        }
        Divider()

        if station.isServerMirror {
            Label(station.displayEndpoint, systemImage: "server.rack")
        } else {
            Button { editingStation = station } label: { Label("edit", systemImage: "pencil") }
        }

        organizeMenu(for: station)

        Button {
            pmWithAnimation(.list) { store.moveStation(id: station.id, by: -1) }
        } label: {
            Label("radio_priority_move_up", systemImage: "arrow.up")
        }
        .disabled(priority <= 1)

        Button {
            pmWithAnimation(.list) { store.moveStation(id: station.id, by: 1) }
        } label: {
            Label("radio_priority_move_down", systemImage: "arrow.down")
        }
        .disabled(priority >= total)

        // 退避期里的台在这里可以被手动催一次；用户自己选过图或填过链接的不提供。
        if !station.isServerMirror,
           station.logoData == nil,
           station.logoFileName == nil,
           station.remoteLogoSource?.isUserProvided != true {
            Button {
                RadioLogoDiscoveryService.shared.discoverNow(for: station)
            } label: {
                Label("radio_logo_fetch", systemImage: "photo.badge.arrow.down")
            }
        }

        if !station.isServerMirror {
            Divider()
            Button(role: .destructive) { stationToDelete = station } label: {
                Label("delete", systemImage: "trash")
            }
        }
    }

    private var filteredEmptyState: some View {
        VStack(spacing: PMSpace.s10) {
            Spacer(minLength: 40)

            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 28))
                .foregroundStyle(PMColor.textFaint)

            Text("radio_filter_empty_title")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PMColor.text)

            Text("radio_filter_empty_description")
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.textMuted)

            Button {
                folderScope = .all
                activeTags = []
                searchText = ""
            } label: {
                Text("radio_filter_clear")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 14)
                    .frame(height: 28)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 归类动作

    /// 单条电台的「移动到文件夹 / 标签」两级菜单，挂在卡片的右键菜单里。
    @ViewBuilder
    private func organizeMenu(for station: RadioStation) -> some View {
        Menu {
            Button("radio_folder_new", systemImage: "folder.badge.plus") {
                beginPrompt(.createFolder(assigning: [station.id]))
            }
            if !folders.isEmpty {
                Divider()
                ForEach(folders) { folder in
                    Button(folder.name, systemImage: "folder") {
                        store.setFolder(folder.name, forStationIDs: [station.id])
                    }
                }
            }
            Divider()
            Button("radio_folder_remove_from", systemImage: "tray") {
                store.setFolder(nil, forStationIDs: [station.id])
            }
        } label: {
            Label("radio_folder_move", systemImage: "folder")
        }

        Menu {
            Button("radio_tag_new", systemImage: "tag.fill") {
                beginPrompt(.createTag(assigning: [station.id]))
            }
            if !tags.isEmpty {
                Divider()
                ForEach(tags) { tag in
                    let applied = station.assignedTagNames.contains {
                        RadioStationOrganization.isSameName($0, tag.name)
                    }
                    Button {
                        if applied {
                            store.removeTag(tag.name, fromStationIDs: [station.id])
                        } else {
                            store.addTag(tag.name, toStationIDs: [station.id])
                        }
                    } label: {
                        // 是否已打上标签只靠图标区分；macOS 27 起菜单默认隐藏图标，这里要求保留。
                        Label(tag.name, systemImage: applied ? "checkmark.circle.fill" : "tag")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
        } label: {
            Label("radio_tags", systemImage: "tag")
        }
    }

    @ViewBuilder
    private func folderActions(_ name: String) -> some View {
        Button("radio_folder_rename", systemImage: "pencil") {
            beginPrompt(.renameFolder(name))
        }
        Button("radio_folder_delete", systemImage: "trash", role: .destructive) {
            folderToDelete = name
        }
    }

    @ViewBuilder
    private func tagActions(_ name: String) -> some View {
        Button("radio_tag_rename", systemImage: "pencil") {
            beginPrompt(.renameTag(name))
        }
        Button("radio_tag_delete", systemImage: "trash", role: .destructive) {
            tagToDelete = name
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

    private var emptyState: some View {
        VStack(spacing: PMSpace.m14) {
            Spacer(minLength: 60)

            Image(systemName: "radio")
                .font(.system(size: 40))
                .foregroundStyle(PMColor.textFaint)
                .frame(width: 92, height: 92)
                .background(PMColor.card, in: .rect(cornerRadius: PMRadius.xxl))
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.xxl, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }

            Text("radio_empty_title")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PMColor.text)

            Text("radio_empty_description")
                .font(.system(size: 13))
                .foregroundStyle(PMColor.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

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

// MARK: - Station card

private struct MacRadioStationCard<Actions: View>: View {
    let station: RadioStation
    let priority: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let metadataTitle: String?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    @ViewBuilder let actions: () -> Actions

    @State private var hover = false

    var body: some View {
        HStack(spacing: PMSpace.m14) {
            RadioStationArtworkView(station: station, size: 64, cornerRadius: PMRadius.l)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(station.name)
                        .font(PMFont.cardTitle)
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)

                    if station.isServerMirror {
                        Image(systemName: "server.rack")
                            .font(.system(size: 10))
                            .foregroundStyle(PMColor.textMuted)
                    }

                    if station.isSubscribed {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                            .foregroundStyle(PMColor.textMuted)
                            .help(RadioSubscriptionText.stationSource(station)
                                ?? String(localized: "radio_subscription_station_badge"))
                    }

                    if isPlaying {
                        HStack(spacing: 4) {
                            Circle().fill(PMColor.bad).frame(width: 5, height: 5)
                            Text("live_badge")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(0.7)
                                .foregroundStyle(PMColor.brand)
                        }
                    }

                    Spacer(minLength: 4)

                    Text(verbatim: "#\(priority)")
                        .font(PMFont.monoXS)
                        .foregroundStyle(PMColor.textFaint)
                }

                Text(metadataTitle ?? station.playbackSubtitle)
                    .font(PMFont.bodyS)
                    .foregroundStyle(isCurrent ? PMColor.brand : PMColor.textMuted)
                    .lineLimit(1)

                RadioStationOrganizeLabels(station: station)

                // 订阅电台在本机认识那份订阅时，这一行换成订阅名。
                Text(RadioSubscriptionText.stationSource(station) ?? station.displayEndpoint)
                    .font(PMFont.monoXS)
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            HStack(spacing: PMSpace.s) {
                // 悬停才露出管理按钮 —— 常驻会让卡片显得吵，这也是 Mac 上
                // 列表类界面的通行做法。
                if hover {
                    PMRoundBtn(icon: "arrow.up", size: PMSize.smallBtn, iconSize: 11, style: .glass) {
                        onMoveUp()
                    }
                    .disabled(!canMoveUp)
                    .opacity(canMoveUp ? 1 : 0.35)

                    PMRoundBtn(icon: "arrow.down", size: PMSize.smallBtn, iconSize: 11, style: .glass) {
                        onMoveDown()
                    }
                    .disabled(!canMoveDown)
                    .opacity(canMoveDown ? 1 : 0.35)

                    if !station.isServerMirror {
                        PMRoundBtn(icon: "pencil", size: PMSize.smallBtn, iconSize: 11, style: .glass) {
                            onEdit()
                        }
                    }
                }

                PMRoundBtn(
                    icon: isPlaying ? "stop.fill" : "play.fill",
                    size: PMSize.playBtn,
                    iconSize: 13,
                    style: isCurrent ? .accent : .glass
                ) {
                    onPlay()
                }
            }
        }
        .padding(PMSpace.m14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .pmCard(cornerRadius: PMRadius.l14)
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.l14, style: .continuous)
                .strokeBorder(isCurrent ? PMColor.brand.opacity(0.55) : .clear, lineWidth: 1)
        }
        .onHover { hover = $0 }
        .pmAnimation(.hover, value: hover)
        .pmAnimation(.hover, value: isCurrent)
        .contextMenu {
            actions()
        }
    }
}

// MARK: - Cover tile

/// 封面版的一格。台标占满整格，名字和状态压在下面 ——
/// 台标齐全时一屏能放下三四倍的电台。
private struct MacRadioStationCoverTile<Actions: View>: View {
    let station: RadioStation
    let isCurrent: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    @ViewBuilder let actions: () -> Actions

    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 用空白容器定尺寸，台标以 .fit 填进去 —— 台标是 logo 不是照片，
            // 完整显示比填满后裁掉台名更重要，也不会让长图反过来撑大网格列。
            Color.clear
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    RadioStationArtworkContent(
                        station: station,
                        decodeSize: 220,
                        contentMode: .fit
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .clipShape(RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if hover || isCurrent {
                        PMRoundBtn(
                            icon: isPlaying ? "stop.fill" : "play.fill",
                            size: PMSize.smallBtn,
                            iconSize: 11,
                            style: isCurrent ? .accent : .glass
                        ) {
                            onPlay()
                        }
                        .padding(6)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.l, style: .continuous)
                        .strokeBorder(
                            isCurrent ? PMColor.brand.opacity(0.75) : PMColor.cardBorder,
                            lineWidth: isCurrent ? 1.5 : 0.5
                        )
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if isPlaying {
                        Circle().fill(PMColor.bad).frame(width: 5, height: 5)
                    }
                    if station.isServerMirror {
                        Image(systemName: "server.rack")
                            .font(.system(size: 8))
                            .foregroundStyle(PMColor.textFaint)
                    }
                    if station.isSubscribed {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 8))
                            .foregroundStyle(PMColor.textFaint)
                    }
                    Text(station.playbackSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }

                RadioStationOrganizeLabels(station: station, maximumTags: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .pmAnimation(.hover, value: hover)
        .pmAnimation(.hover, value: isCurrent)
        .onTapGesture { onPlay() }
        .contextMenu {
            actions()
        }
    }
}
#endif
