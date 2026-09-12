import SwiftUI
import PrimuseKit

/// 分区标题要走 SwiftUI 的本地化键,而枚举本身存在 Kit 里(顺序与方案都按
/// rawValue 存盘),所以标题留在 app 侧作为扩展。
extension HomeSectionKind {
    var title: LocalizedStringKey {
        switch self {
        case .continueListening: return "home_section_continue_listening"
        case .radio: return "radio_title"
        case .quickAccess: return "home_section_quick_access"
        case .forYou: return "home_section_for_you"
        case .playlists: return "home_section_playlists"
        case .folders: return LocalizedStringKey(HomeDiscoveryText.string("folders"))
        case .listeningRanking: return LocalizedStringKey(HomeDiscoveryText.string("ranking"))
        case .topArtists: return "home_section_top_artists"
        case .recentlyAdded: return LocalizedStringKey(HomeDiscoveryText.string("recent_albums"))
        case .stats: return "stats_title"
        }
    }
}

enum HomeSectionConfiguration {
    static let orderKey = "primuse.home.sectionOrder.v1"
    static let defaultOrder: [HomeSectionKind] = [
        .continueListening,
        .radio,
        .quickAccess,
        .folders,
        .listeningRanking,
        .forYou,
        .playlists,
        .topArtists,
        .recentlyAdded,
        .stats,
    ]

    static func decode(_ rawValue: String) -> [HomeSectionKind] {
        let stored: [HomeSectionKind]
        if let data = rawValue.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([HomeSectionKind].self, from: data) {
            stored = decoded
        } else {
            stored = []
        }

        var seen = Set<HomeSectionKind>()
        var known = stored.filter { seen.insert($0).inserted }
        if !known.isEmpty {
            // Keep existing sections in the user's order while introducing
            // the two related modules together beside their library shortcuts.
            if seen.insert(.folders).inserted {
                let anchor = known.firstIndex(of: .playlists) ?? known.firstIndex(of: .quickAccess)
                known.insert(.folders, at: anchor.map { $0 + 1 } ?? 0)
            }
            if seen.insert(.listeningRanking).inserted {
                known.insert(.listeningRanking, at: (known.firstIndex(of: .folders) ?? 0) + 1)
            }
        }
        let missing = defaultOrder.filter { seen.insert($0).inserted }
        return known + missing
    }

    static func encode(_ sections: [HomeSectionKind]) -> String {
        guard let data = try? JSONEncoder().encode(sections) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Hero remains fixed at the top. Every other Home section can be hidden
/// independently and reordered with the native list drag handle.
struct HomeSectionsSettingsView: View {
    @AppStorage("primuse.home.showStatsGlimpse") private var showStatsGlimpse = true
    @AppStorage("primuse.home.showForYou") private var showForYou = true
    @AppStorage("primuse.home.showTopArtists") private var showTopArtists = true
    @AppStorage("primuse.home.showRecentlyAdded") private var showRecentlyAdded = true
    @AppStorage("primuse.home.showContinueListening") private var showContinueListening = true
    @AppStorage("primuse.home.showRadio") private var showRadio = true
    @AppStorage("primuse.home.showQuickAccess") private var showQuickAccess = true
    @AppStorage("primuse.home.showPlaylists") private var showPlaylists = true
    @AppStorage("primuse.home.showFolders") private var showFolders = true
    @AppStorage("primuse.home.showListeningRanking") private var showListeningRanking = true
    @AppStorage(HomeSectionConfiguration.orderKey) private var sectionOrderRawValue = ""
    @AppStorage(HomeFolderPinStorage.displayCountKey) private var folderDisplayCount = HomeFolderPinStorage.defaultDisplayCount
    @State private var showsFolderManager = false

    private var sectionOrder: [HomeSectionKind] {
        HomeSectionConfiguration.decode(sectionOrderRawValue)
    }

    /// 电台使用上方的独立开关控制整张首页背面，因此不参与音乐面板块排序。
    private var editableSections: [HomeSectionKind] {
        sectionOrder.filter(\.isUserConfigurable)
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: $showRadio) {
                    Label("radio_home_visibility", systemImage: "radio")
                }
                .accessibilityHint(Text("radio_home_visibility_description"))
            }
            .settingsAnchor("home.radio")

            Section {
                ForEach(editableSections) { section in
                    Toggle(isOn: visibilityBinding(for: section)) {
                        Label(section.title, systemImage: section.icon)
                    }
                    .accessibilityHint(Text("home_settings_sections_footer"))
                    .settingsAnchor("home." + section.rawValue)
                }
                .onMove(perform: moveSections)
            } header: {
                Text("home_settings_sections_label")
            }
            .settingsAnchor("home.order")

            Section(HomeDiscoveryText.string("folders")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(HomeDiscoveryText.string("folder_display_count"))
                        Spacer()
                        Text(HomeFolderPinStorage.displayCount(folderDisplayCount).formatted())
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(HomeFolderPinStorage.displayCount(folderDisplayCount)) },
                        set: { folderDisplayCount = HomeFolderPinStorage.displayCount(Int($0)) }
                    ), in: Double(HomeFolderPinStorage.displayCountRange.lowerBound)...Double(HomeFolderPinStorage.displayCountRange.upperBound), step: 1)
                    .accessibilityLabel(HomeDiscoveryText.string("folder_display_count"))
                    .accessibilityValue(HomeFolderPinStorage.displayCount(folderDisplayCount).formatted())
                    .accessibilityIdentifier("home.folderDisplayCount")
                }
                .settingsAnchor("home.folderDisplayCount")
                // This list stays in edit mode for reordering, which disables
                // ordinary NavigationLinks. Keep management available there.
                Button {
                    showsFolderManager = true
                } label: {
                    HStack {
                        Label(HomeDiscoveryText.string("manage_folders"), systemImage: "folder.badge.gearshape")
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home.manageFolders")
            }

            Section {
                Button("home_settings_restore_default_order") {
                    sectionOrderRawValue = HomeSectionConfiguration.encode(
                        HomeSectionConfiguration.defaultOrder
                    )
                }
                .settingsAnchor("home.restoreOrder")
            }
        }
        .navigationDestination(isPresented: $showsFolderManager) {
            HomeFolderManagementView()
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        #endif
        .navigationTitle("home_settings_title")
    }

    private func visibilityBinding(for section: HomeSectionKind) -> Binding<Bool> {
        switch section {
        case .continueListening: return $showContinueListening
        case .radio: return $showRadio
        case .quickAccess: return $showQuickAccess
        case .forYou: return $showForYou
        case .playlists: return $showPlaylists
        case .folders: return $showFolders
        case .listeningRanking: return $showListeningRanking
        case .topArtists: return $showTopArtists
        case .recentlyAdded: return $showRecentlyAdded
        case .stats: return $showStatsGlimpse
        }
    }

    /// `source` / `destination` 是**过滤后列表**的下标，不能直接套到完整顺序上 ──
    /// 那样会把不可配置的分区算进去，挪错位置。先在可见列表里完成移动，再把
    /// 结果按原顺序缝回去(不可配置项留在它原来的槽位)。
    private func moveSections(from source: IndexSet, to destination: Int) {
        var visible = editableSections
        visible.move(fromOffsets: source, toOffset: destination)

        var iterator = visible.makeIterator()
        let merged = sectionOrder.map { section in
            section.isUserConfigurable ? (iterator.next() ?? section) : section
        }
        sectionOrderRawValue = HomeSectionConfiguration.encode(merged)
    }
}
