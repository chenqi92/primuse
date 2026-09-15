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

    private let columns = [
        GridItem(.adaptive(minimum: 340, maximum: 520), spacing: PMSpace.m16)
    ]

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
            MacRadioStationEditorView(station: station)
        }
        .sheet(isPresented: $showBatchAdd) {
            MacRadioBatchAddView()
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
        } message: { _ in
            Text("radio_manage_delete_confirm_message")
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
                }

                if !stations.isEmpty {
                    Button {
                        store.sortStationsByName()
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

            Text(summaryText)
                .font(.system(size: 13))
                .foregroundStyle(PMColor.textMuted)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 20)
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
            LazyVGrid(columns: columns, alignment: .leading, spacing: PMSpace.m16) {
                ForEach(visibleStations) { station in
                    let priority = priorities[station.id] ?? 1
                    MacRadioStationCard(
                        station: station,
                        priority: priority,
                        isCurrent: player.currentRadioStation?.id == station.id,
                        isPlaying: player.currentRadioStation?.id == station.id
                            && (player.isPlaying || player.isLoading),
                        metadataTitle: player.currentRadioStation?.id == station.id
                            ? player.radioMetadataTitle
                            : nil,
                        canMoveUp: priority > 1,
                        canMoveDown: priority < total,
                        onPlay: { toggle(station) },
                        onEdit: { editingStation = station },
                        onDelete: { stationToDelete = station },
                        onMoveUp: { store.moveStation(id: station.id, by: -1) },
                        onMoveDown: { store.moveStation(id: station.id, by: 1) },
                        organizeActions: { organizeMenu(for: station) }
                    )
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 36)
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
                        Label(tag.name, systemImage: applied ? "checkmark.circle.fill" : "tag")
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
        if let url = station.url,
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

private struct MacRadioStationCard<OrganizeActions: View>: View {
    let station: RadioStation
    let priority: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let metadataTitle: String?
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    @ViewBuilder let organizeActions: () -> OrganizeActions

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

                Text(station.displayEndpoint)
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
        .animation(.easeOut(duration: 0.12), value: hover)
        .contextMenu {
            if station.isServerMirror {
                Label(station.displayEndpoint, systemImage: "server.rack")
            } else {
                Button { onEdit() } label: { Label("edit", systemImage: "pencil") }
            }
            organizeActions()
            Button { onMoveUp() } label: { Label("radio_priority_move_up", systemImage: "arrow.up") }
                .disabled(!canMoveUp)
            Button { onMoveDown() } label: { Label("radio_priority_move_down", systemImage: "arrow.down") }
                .disabled(!canMoveDown)
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
                Button(role: .destructive) { onDelete() } label: {
                    Label("delete", systemImage: "trash")
                }
            }
        }
    }
}
#endif
