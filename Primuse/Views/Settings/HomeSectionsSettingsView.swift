import SwiftUI

enum HomeSectionKind: String, CaseIterable, Codable, Identifiable {
    case continueListening
    case radio
    case quickAccess
    case forYou
    case playlists
    case topArtists
    case recentlyAdded
    case stats

    var id: String { rawValue }

    /// 电台不再是首页的一个分区 —— 它有了自己的模式(右上角切换)，音乐态里
    /// 再放一块电台就是重复内容。case 本身保留，否则老用户存下来的排序 JSON
    /// 解不出来会被整个丢弃、自定义顺序全丢。
    var isUserConfigurable: Bool { self != .radio }

    var title: LocalizedStringKey {
        switch self {
        case .continueListening: return "home_section_continue_listening"
        case .radio: return "radio_title"
        case .quickAccess: return "home_section_quick_access"
        case .forYou: return "home_section_for_you"
        case .playlists: return "home_section_playlists"
        case .topArtists: return "home_section_top_artists"
        case .recentlyAdded: return "home_section_recently_added"
        case .stats: return "stats_title"
        }
    }

    var icon: String {
        switch self {
        case .continueListening: return "play.circle"
        case .radio: return "radio.fill"
        case .quickAccess: return "pin"
        case .forYou: return "sparkles"
        case .playlists: return "music.note.list"
        case .topArtists: return "music.mic"
        case .recentlyAdded: return "clock.badge.checkmark"
        case .stats: return "chart.bar.xaxis"
        }
    }
}

enum HomeSectionConfiguration {
    static let orderKey = "primuse.home.sectionOrder.v1"
    static let defaultOrder: [HomeSectionKind] = [
        .continueListening,
        .radio,
        .quickAccess,
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
        let known = stored.filter { seen.insert($0).inserted }
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
    @AppStorage(HomeSectionConfiguration.orderKey) private var sectionOrderRawValue = ""

    private var sectionOrder: [HomeSectionKind] {
        HomeSectionConfiguration.decode(sectionOrderRawValue)
    }

    /// 设置页只列可配置的分区。电台被排除 —— 它归模式切换管，不该在这里
    /// 出现一个开不开都不影响首页的死开关。
    private var editableSections: [HomeSectionKind] {
        sectionOrder.filter(\.isUserConfigurable)
    }

    var body: some View {
        List {
            Section {
                ForEach(editableSections) { section in
                    Toggle(isOn: visibilityBinding(for: section)) {
                        Label(section.title, systemImage: section.icon)
                    }
                }
                .onMove(perform: moveSections)
            } header: {
                Text("home_settings_sections_label")
            } footer: {
                Text("home_settings_sections_footer")
            }

            Section {
                Button("home_settings_restore_default_order") {
                    sectionOrderRawValue = HomeSectionConfiguration.encode(
                        HomeSectionConfiguration.defaultOrder
                    )
                }
            }
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
