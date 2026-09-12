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

/// 首页布局编辑。
///
/// 每个区块一张卡：左边是该区块当前排布的缩略图，右边是开关、排布与条目数。
/// 缩略图跟着选择实时变，拖动卡片就是在排首页的顺序 —— 不再需要边改边退回
/// 首页看效果。这张列表常驻编辑态（为了拖动），编辑态下 NavigationLink 点不动，
/// 所以所有操作都用 Button 完成。
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
    @AppStorage(HomeSectionLayoutConfiguration.storageKey) private var sectionLayoutRawValue = ""
    @AppStorage(HomeFolderPinStorage.displayCountKey) private var folderDisplayCount = HomeFolderPinStorage.defaultDisplayCount
    @State private var showsFolderManager = false

    private var sectionOrder: [HomeSectionKind] {
        HomeSectionConfiguration.decode(sectionOrderRawValue)
    }

    /// 电台有自己的整页模式（首页右上角切换），不参与音乐面的区块排序。
    private var editableSections: [HomeSectionKind] {
        sectionOrder.filter(\.isUserConfigurable)
    }

    private var sectionLayout: HomeSectionLayoutConfiguration {
        HomeSectionLayoutConfiguration.decode(sectionLayoutRawValue)
    }

    var body: some View {
        List {
            Section {
                Toggle(isOn: $showRadio) {
                    Label("radio_home_visibility", systemImage: "radio")
                }
                .accessibilityHint(Text("radio_home_visibility_description"))
                .settingsAnchor("home.radio")
            } header: {
                Text("radio_title")
            } footer: {
                Text("radio_home_visibility_description")
            }

            Section {
                ForEach(editableSections) { section in
                    sectionCard(section)
                        .settingsAnchor("home." + section.rawValue)
                }
                .onMove(perform: moveSections)
            } header: {
                Text("home_settings_sections_label")
            } footer: {
                Text("home_settings_sections_footer")
            }
            .settingsAnchor("home.order")

            Section {
                Button("home_settings_restore_all", role: .destructive) {
                    restoreDefaults()
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

    // MARK: - 区块卡片

    @ViewBuilder
    private func sectionCard(_ section: HomeSectionKind) -> some View {
        let visible = visibilityBinding(for: section)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                HomeSectionMiniature(style: sectionLayout.style(for: section))
                    .opacity(visible.wrappedValue ? 1 : 0.3)
                Toggle(isOn: visible) {
                    Label(section.title, systemImage: section.icon)
                        .lineLimit(1)
                }
                .accessibilityIdentifier("home.visible." + section.rawValue)
            }

            if visible.wrappedValue {
                layoutOptions(for: section)
                countControl(for: section)
                if section == .folders { manageFoldersButton }
            }
        }
        .padding(.vertical, 4)
    }

    /// 排布选择。给不出第二种像样排布的区域（统计概览、文件夹、听歌排行）不显示。
    @ViewBuilder
    private func layoutOptions(for section: HomeSectionKind) -> some View {
        let options = HomeSectionLayoutPolicy.supportedStyles(for: section)
        if options.count > 1 {
            let current = sectionLayout.style(for: section)
            HStack(spacing: 8) {
                Text("home_layout_label")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                ForEach(options) { style in
                    Button {
                        setLayout(style, for: section)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: style.icon).font(.caption2)
                            Text(LocalizedStringKey(style.titleKey))
                                .font(.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .foregroundStyle(style == current ? Color.accentColor : Color.secondary)
                        .background {
                            Capsule().fill(
                                style == current
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.secondary.opacity(0.10)
                            )
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.layout.\(section.rawValue).\(style.rawValue)")
                }
            }
        }
    }

    /// 条目数。Stepper 在常驻编辑态里不一定响应，用两个 Button 自己做。
    @ViewBuilder
    private func countControl(for section: HomeSectionKind) -> some View {
        if let (binding, range) = countBinding(for: section) {
            HStack(spacing: 8) {
                Text("home_count_label")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Text(binding.wrappedValue.formatted())
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 22)
                Spacer(minLength: 8)
                countButton("minus", enabled: binding.wrappedValue > range.lowerBound) {
                    binding.wrappedValue = max(range.lowerBound, binding.wrappedValue - 1)
                }
                .accessibilityIdentifier("home.count.decrement." + section.rawValue)
                countButton("plus", enabled: binding.wrappedValue < range.upperBound) {
                    binding.wrappedValue = min(range.upperBound, binding.wrappedValue + 1)
                }
                .accessibilityIdentifier("home.count.increment." + section.rawValue)
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(binding.wrappedValue.formatted())
        }
    }

    private func countButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: 26, height: 24)
                .background { Capsule().fill(Color.secondary.opacity(0.12)) }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(enabled ? Color.accentColor : Color.secondary.opacity(0.5))
    }

    private var manageFoldersButton: some View {
        Button {
            showsFolderManager = true
        } label: {
            HStack {
                Label(HomeDiscoveryText.string("manage_folders"), systemImage: "folder.badge.gearshape")
                    .font(.caption)
                Spacer()
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.manageFolders")
    }

    // MARK: - 读写

    /// 文件夹另有自己的条目数存储（管理页也在用），不在统一配置里再存一份。
    private func countBinding(for section: HomeSectionKind) -> (Binding<Int>, ClosedRange<Int>)? {
        if let range = HomeSectionLayoutPolicy.itemCountRange(for: section) {
            return (Binding(
                get: {
                    sectionLayout.itemCount(for: section)
                        ?? HomeSectionLayoutPolicy.defaultItemCount(for: section)
                },
                set: { newValue in
                    var configuration = sectionLayout
                    configuration.setItemCount(newValue, for: section)
                    sectionLayoutRawValue = configuration.encoded()
                }
            ), range)
        }
        if section == .folders {
            return (Binding(
                get: { HomeFolderPinStorage.displayCount(folderDisplayCount) },
                set: { folderDisplayCount = HomeFolderPinStorage.displayCount($0) }
            ), HomeFolderPinStorage.displayCountRange)
        }
        return nil
    }

    private func setLayout(_ style: HomeSectionLayoutStyle, for section: HomeSectionKind) {
        var configuration = sectionLayout
        configuration.setStyle(style, for: section)
        sectionLayoutRawValue = configuration.encoded()
    }

    private func restoreDefaults() {
        sectionOrderRawValue = HomeSectionConfiguration.encode(HomeSectionConfiguration.defaultOrder)
        sectionLayoutRawValue = ""
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

/// 区块排布的缩略图。用色块把「横排 / 双行 / 网格 / 列表」画出来 —— 光看名字
/// 分不清双行横排和网格差在哪，画出来一眼就知道各自占多高。
private struct HomeSectionMiniature: View {
    let style: HomeSectionLayoutStyle

    private var tint: Color { Color.accentColor.opacity(0.55) }
    private var faded: Color { Color.accentColor.opacity(0.22) }

    var body: some View {
        Group {
            switch style {
            case .list:
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(height: 5)
                    }
                }
            case .carousel:
                HStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2.5).fill(tint).frame(width: 17, height: 17)
                    }
                    RoundedRectangle(cornerRadius: 2.5).fill(faded).frame(width: 6, height: 17)
                }
            case .carouselDouble:
                VStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1.5).fill(tint).frame(width: 24, height: 7)
                            RoundedRectangle(cornerRadius: 1.5).fill(faded).frame(width: 6, height: 7)
                        }
                    }
                }
            case .grid:
                VStack(spacing: 4) {
                    ForEach(0..<2, id: \.self) { _ in
                        HStack(spacing: 4) {
                            ForEach(0..<2, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2).fill(tint).frame(width: 15, height: 12)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 40, height: 34, alignment: .leading)
        .accessibilityHidden(true)
    }
}
