import SwiftUI
import PrimuseKit

extension SearchResultSection {
    /// 这一块对应的本机命中类别。专辑、艺术家、智能补充和 Apple Music 不按命中类别分。
    var libraryMatchKind: LibrarySearchMatchKind? {
        switch self {
        case .metadata: .metadata
        case .path: .path
        case .lyrics: .lyrics
        case .fuzzy: .fuzzy
        case .albums, .artists, .intelligent, .appleMusic: nil
        }
    }

    var title: LocalizedStringKey { LocalizedStringKey(titleKey) }
}

/// 搜索页当前生效的布局: 用户排的顺序, 以及哪些块关掉了。
struct SearchResultLayout: Equatable {
    let order: [SearchResultSection]
    let hidden: Set<SearchResultSection>

    init(orderRawValue: String, hiddenRawValue: String) {
        order = SearchResultSectionLayout.decodeOrder(orderRawValue)
        hidden = SearchResultSectionLayout.decodeHidden(hiddenRawValue)
    }

    /// Apple Music 的开关在别处(曲库搜索设置), 这里只管本机的几块。
    func shows(_ section: SearchResultSection) -> Bool {
        !hidden.contains(section)
    }

    /// 要去索引里查的命中类别。关掉的类别不查, 也不占歌。
    var matchKinds: Set<LibrarySearchMatchKind> {
        Set(order.filter(shows).compactMap(\.libraryMatchKind))
    }
}

/// 搜索页右上角「调整搜索结果」的入口。
///
/// 只是个按钮, 不读任何按类型注入的环境对象 —— 它挂在导航栏里, 那里另起一套视图图。
struct SearchResultLayoutButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("search_layout_title", systemImage: "slider.horizontal.3")
        }
        .labelStyle(.iconOnly)
        .help(Text("search_layout_title"))
        .accessibilityIdentifier("search.layout.button")
    }
}

/// 搜索结果各块的先后与显隐。iOS 从搜索页右上角以 sheet 打开,
/// Mac 从筛选按钮那一行的末尾以 popover 打开。
///
/// 需要的状态都按值传进来、自己只读 AppStorage: 它挂在工具栏按钮旁边,
/// 不能依赖按类型注入的环境对象。
struct SearchResultLayoutEditor: View {
    /// 没配 AI 语义搜索时不列这一行: 开着它搜索页也不会多出任何东西。
    let showsIntelligentRow: Bool
    /// 没添加或停用了 Apple Music 源时同理。
    let showsAppleMusicRow: Bool

    @AppStorage(SearchResultSectionLayout.orderKey) private var orderRawValue = ""
    @AppStorage(SearchResultSectionLayout.hiddenKey) private var hiddenRawValue = ""
    @AppStorage(AppleMusicFeatureSettings.catalogSearchEnabledKey)
    private var appleMusicCatalogSearchEnabled = true
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    private var order: [SearchResultSection] {
        SearchResultSectionLayout.decodeOrder(orderRawValue)
    }

    private var hidden: Set<SearchResultSection> {
        SearchResultSectionLayout.decodeHidden(hiddenRawValue)
    }

    private var displayed: [SearchResultSection] {
        order.filter { section in
            switch section {
            case .intelligent: showsIntelligentRow
            case .appleMusic: showsAppleMusicRow
            default: true
            }
        }
    }

    private var isDefault: Bool {
        order == SearchResultSectionLayout.defaultOrder && hidden.isEmpty
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    #if os(iOS)
    private var iosBody: some View {
        NavigationStack {
            SkinList {
                Section {
                    ForEach(displayed) { section in
                        Toggle(isOn: visibilityBinding(for: section)) {
                            Label(section.title, systemImage: section.icon)
                        }
                        .disabled(!canToggle(section))
                    }
                    .onMove(perform: move)
                } footer: {
                    Text("search_layout_footer")
                }

                Section {
                    Button("search_layout_restore_default", action: restoreDefaults)
                        .disabled(isDefault)
                }
            }
            // 常驻编辑态, 拖动把手一眼可见, 不必先长按才发现能排。
            .environment(\.editMode, .constant(.active))
            .navigationTitle(Text("search_layout_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
            // 矮屏（iPhone SE、iPhone Duo 外屏）上半屏只放得下五六行，页脚与「恢复默认」落在折下，
            // 这时改停在装得下整张表的高度；普通 iPhone 仍是半屏。
            .pmSheetSymmetricMargins()
            .pmFitsContentInSheet()
        }
    }
    #endif

    #if os(macOS)
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("search_layout_title")
                .font(.headline)

            VStack(spacing: 2) {
                ForEach(Array(displayed.enumerated()), id: \.element) { index, section in
                    HStack(spacing: 8) {
                        Toggle(isOn: visibilityBinding(for: section)) {
                            Label(section.title, systemImage: section.icon)
                                .labelStyle(.titleAndIcon)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!canToggle(section))

                        Spacer(minLength: 12)

                        Button {
                            move(from: IndexSet(integer: index), to: index - 1)
                        } label: {
                            Image(systemName: "chevron.up")
                                .frame(width: 18, height: 18)
                        }
                        .disabled(index == 0)
                        .accessibilityLabel(Text("search_layout_move_up"))

                        Button {
                            move(from: IndexSet(integer: index), to: index + 2)
                        } label: {
                            Image(systemName: "chevron.down")
                                .frame(width: 18, height: 18)
                        }
                        .disabled(index == displayed.count - 1)
                        .accessibilityLabel(Text("search_layout_move_down"))
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }

            Text("search_layout_footer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("search_layout_restore_default", action: restoreDefaults)
                .disabled(isDefault)
        }
        .padding(16)
        .frame(width: 320)
    }
    #endif

    private func isShown(_ section: SearchResultSection) -> Bool {
        section == .appleMusic ? appleMusicCatalogSearchEnabled : !hidden.contains(section)
    }

    private func canToggle(_ section: SearchResultSection) -> Bool {
        !isShown(section) || SearchResultSectionLayout.canHide(section, hidden: hidden)
    }

    private func visibilityBinding(for section: SearchResultSection) -> Binding<Bool> {
        Binding(
            get: { isShown(section) },
            set: { isShown in
                if section == .appleMusic {
                    appleMusicCatalogSearchEnabled = isShown
                    return
                }
                var updated = hidden
                if isShown {
                    updated.remove(section)
                } else {
                    guard SearchResultSectionLayout.canHide(section, hidden: updated) else { return }
                    updated.insert(section)
                }
                hiddenRawValue = SearchResultSectionLayout.encodeHidden(updated)
            }
        )
    }

    private func move(from source: IndexSet, to destination: Int) {
        orderRawValue = SearchResultSectionLayout.encodeOrder(
            SearchResultSectionLayout.reordering(
                order,
                displayed: displayed,
                fromOffsets: source,
                toOffset: destination
            )
        )
    }

    private func restoreDefaults() {
        orderRawValue = ""
        hiddenRawValue = ""
    }
}
