#if os(iOS)
import PrimuseKit
import SwiftUI

// MARK: - 顶栏的去处

/// 极简模式顶栏上的去处。音乐、电台、有声落在资料库的分类页上，首页就是首页标签。
enum MinimalTopTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case home
    case music
    case radio
    case spoken

    var id: String { rawValue }

    private var titleKeyName: String {
        switch self {
        case .home: "home_title"
        case .music: "listening_space_music"
        case .radio: "radio_title"
        case .spoken: "minimal_tab_spoken"
        }
    }

    var titleKey: LocalizedStringKey { LocalizedStringKey(titleKeyName) }

    var title: String { String(localized: String.LocalizationValue(titleKeyName)) }

    /// 资料库分类归哪一格：电台自成一格，有声书与播客同在「有声」，其余都在「音乐」下面。
    static func tab(for section: LibrarySection) -> MinimalTopTab {
        switch section {
        case .radio: .radio
        case .spokenWord, .podcasts: .spoken
        default: .music
        }
    }
}

/// 设置页左上角回到上一页的那颗键：极简模式的设置不在分段里，从哪一页进来就回哪一页。
struct MinimalReturnAction {
    let title: String
    let action: @MainActor () -> Void
}

private struct MinimalRootPageKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MinimalSettingsReturnKey: EnvironmentKey {
    static let defaultValue: MinimalReturnAction? = nil
}

private struct MinimalSpokenSectionsKey: EnvironmentKey {
    static let defaultValue: [LibrarySection] = []
}

private struct MinimalSelectSectionKey: EnvironmentKey {
    static let defaultValue: (@MainActor (LibrarySection) -> Void)? = nil
}

extension EnvironmentValues {
    /// 这一页是极简模式的根页：顶栏在它头上、系统导航栏藏着。页头只在这时出现。
    var minimalRootPage: Bool {
        get { self[MinimalRootPageKey.self] }
        set { self[MinimalRootPageKey.self] = newValue }
    }

    var minimalSettingsReturn: MinimalReturnAction? {
        get { self[MinimalSettingsReturnKey.self] }
        set { self[MinimalSettingsReturnKey.self] = newValue }
    }

    /// 「有声」那一格里有几页（有声书、播客），只有一页时不摆切换。
    var minimalSpokenSections: [LibrarySection] {
        get { self[MinimalSpokenSectionsKey.self] }
        set { self[MinimalSpokenSectionsKey.self] = newValue }
    }

    var minimalSelectSection: (@MainActor (LibrarySection) -> Void)? {
        get { self[MinimalSelectSectionKey.self] }
        set { self[MinimalSelectSectionKey.self] = newValue }
    }
}

extension View {
    /// 极简外壳的上下栏。iOS 26 起用 `safeAreaBar`，滚动内容在栏下面柔和地淡出；
    /// 更早的系统退回 `safeAreaInset`，栏自己铺一层底，免得列表从字底下透出来。
    @ViewBuilder
    func minimalSafeAreaBar<Bar: View>(
        edge: VerticalEdge,
        @ViewBuilder content: () -> Bar
    ) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: edge, spacing: 0, content: content)
                .scrollEdgeEffectStyle(.soft, for: edge == .top ? .top : .bottom)
        } else {
            safeAreaInset(edge: edge, spacing: 0) {
                content().background(.bar)
            }
        }
    }
}

// MARK: - 顶栏

/// 极简模式的顶栏：几个去处排成一组分段，右边是搜索与设置；停在音乐时第二排是分类。
/// 手机横屏只有一排，分类接在分段后面。
struct MinimalTopTabBar: View {
    let tabs: [MinimalTopTab]
    let selectedTab: MinimalTopTab?
    let musicSections: [LibrarySection]
    let selectedSection: LibrarySection?
    let onSelectTab: (MinimalTopTab) -> Void
    let onSelectSection: (LibrarySection) -> Void
    let onSearch: () -> Void
    let onSettings: () -> Void

    @Environment(\.pmHeightClass) private var heightClass

    private var showsSectionRow: Bool {
        selectedTab == .music && musicSections.count > 1
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if heightClass.isCompact {
                    MinimalTopTabPicker(tabs: tabs, selection: selectedTab, onSelect: onSelectTab)
                        .fixedSize()
                    if showsSectionRow {
                        MinimalSectionTabs(
                            sections: musicSections,
                            selection: selectedSection,
                            onSelect: onSelectSection
                        )
                    } else {
                        Spacer(minLength: 0)
                    }
                } else {
                    // 字大或者语言长时一排放不下四段，就让分段自己横着滑，不挤掉右边两颗键。
                    ScrollView(.horizontal, showsIndicators: false) {
                        MinimalTopTabPicker(tabs: tabs, selection: selectedTab, onSelect: onSelectTab)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                }

                MinimalChromeIconButton(systemImage: "magnifyingglass", titleKey: "search_title", action: onSearch)
                    .accessibilityIdentifier("minimal.search")
                MinimalChromeIconButton(systemImage: "gearshape", titleKey: "settings_title", action: onSettings)
                    .accessibilityIdentifier("minimal.settings")
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .frame(minHeight: 50)

            if !heightClass.isCompact, showsSectionRow {
                MinimalSectionTabs(
                    sections: musicSections,
                    selection: selectedSection,
                    onSelect: onSelectSection
                )
                // 固定在顶上的分类行：iPhone Duo 竖栏时停在竖栏前。
                .pmPinnedRowStopsAtVerticalBar()
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

/// 顶栏左边的分段：浅灰的槽里，选中的那一段是一块白底（深色下是浅一档的灰）。
private struct MinimalTopTabPicker: View {
    let tabs: [MinimalTopTab]
    let selection: MinimalTopTab?
    let onSelect: (MinimalTopTab) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                segment(tab)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
    }

    private func segment(_ tab: MinimalTopTab) -> some View {
        let isSelected = tab == selection
        return Button {
            onSelect(tab)
        } label: {
            Text(tab.titleKey)
                .font(.callout.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(selectedFill)
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.1), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "selection", in: indicator)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier("minimal.tab.\(tab.rawValue)")
    }

    private var selectedFill: Color {
        colorScheme == .dark
            ? Color(uiColor: .systemGray3)
            : Color(uiColor: .systemBackground)
    }
}

/// 音乐下面的分类：选中的字加粗变墨色，底下一道主题色短线。
private struct MinimalSectionTabs: View {
    let sections: [LibrarySection]
    let selection: LibrarySection?
    let onSelect: (LibrarySection) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var underline

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(sections) { section in
                        item(section)
                            .id(section)
                    }
                }
                .padding(.horizontal, 20)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onChange(of: selection, initial: true) { _, section in
                guard let section else { return }
                if reduceMotion {
                    proxy.scrollTo(section, anchor: .center)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(section, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 42)
    }

    private func item(_ section: LibrarySection) -> some View {
        let isSelected = section == selection
        return Button {
            onSelect(section)
        } label: {
            Text(section.title)
                .font(.body.weight(isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: 20, height: 3)
                            .matchedGeometryEffect(id: "underline", in: underline)
                            .padding(.bottom, 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("minimal.section.\(section.rawValue)")
    }
}

private struct MinimalChromeIconButton: View {
    let systemImage: String
    let titleKey: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(titleKey))
    }
}

// MARK: - 搜索态的顶栏

/// 点了放大镜之后顶栏换成输入框，右边是范围、调整结果与「取消」。
struct MinimalSearchBar: View {
    @Binding var text: String
    @Binding var scope: LibrarySearchScope?
    let context: LibrarySearchScope?
    /// 刚从放大镜进来：出现时直接弹键盘。启动时恢复到搜索页不弹。
    @Binding var activationRequested: Bool
    let onSubmit: () -> Void
    let onEditLayout: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    private var prompt: String {
        if let scope {
            return String(format: String(localized: "search_scope_prompt_format"), scope.title)
        }
        return String(localized: "search_title")
    }

    var body: some View {
        HStack(spacing: 6) {
            field

            if let context {
                SearchScopeSwitchButton(scope: $scope, context: context)
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 40, minHeight: 44)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Button(action: onEditLayout) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("search_layout_title"))
            .accessibilityIdentifier("search.layout.button")

            Button {
                isFocused = false
                onCancel()
            } label: {
                Text("cancel")
                    .font(.body)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("minimal.search.cancel")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(minHeight: 50)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .onChange(of: activationRequested, initial: true) { _, requested in
            guard requested else { return }
            activationRequested = false
            Task { @MainActor in isFocused = true }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
                .onSubmit {
                    isFocused = false
                    onSubmit()
                }
                .accessibilityIdentifier("minimal.search.field")

            if !text.isEmpty {
                Button {
                    text = ""
                    isFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("clear"))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, text.isEmpty ? 12 : 4)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(
            Color(uiColor: .secondarySystemFill),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { isFocused = true }
    }
}

// MARK: - 根页页头

/// 页内查找：极简根页上输入框平时收着，点页头的放大镜才拉出来；有字时一直留着。
@MainActor
@Observable
final class MinimalPageFindState {
    fileprivate(set) var isAvailable = false
    var isActive = false
    fileprivate(set) var prompt: LocalizedStringKey = "search_title"

    func register(prompt: LocalizedStringKey) {
        self.prompt = prompt
        isAvailable = true
    }
}

extension View {
    /// 极简模式根页的页头：系统导航栏藏起来以后，页面自己的标题与操作排在顶栏下面。
    /// 不在极简根页上时什么都不做，页面照旧用系统导航栏与工具栏。
    /// 要挂在 `libraryPageFind` 的外面，页头才排在查找框上面。
    func minimalPageHeader<Header: View>(@ViewBuilder _ header: @escaping () -> Header) -> some View {
        modifier(MinimalPageHeaderModifier(header: header))
    }
}

private struct MinimalPageHeaderModifier<Header: View>: ViewModifier {
    let header: () -> Header
    @Environment(\.minimalRootPage) private var isMinimalRoot
    @State private var findState = MinimalPageFindState()

    func body(content: Content) -> some View {
        if isMinimalRoot {
            content
                .environment(findState)
                .minimalSafeAreaBar(edge: .top) {
                    header()
                        .environment(findState)
                        .padding(.leading, 16)
                        .padding(.trailing, 8)
                        .padding(.vertical, 2)
                        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                }
        } else {
            content
        }
    }
}

/// 页头左边的页名（电台、书架、播客这类没有分类行的页）。
struct MinimalPageTitle: View {
    private let title: Text

    init(_ key: LocalizedStringKey) {
        title = Text(key)
    }

    init(verbatim: String) {
        title = Text(verbatim: verbatim)
    }

    var body: some View {
        title
            .font(.largeTitle.weight(.bold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 页头里的一组图标键：Label 只留图标、40pt 见方的命中区、墨色。菜单也是同一种样子。
struct MinimalHeaderActions<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) {
            content
        }
        .labelStyle(.iconOnly)
        .font(.title3.weight(.regular))
        .buttonStyle(MinimalHeaderIconButtonStyle())
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct MinimalHeaderIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MinimalHeaderIconButtonBody(configuration: configuration)
    }
}

private struct MinimalHeaderIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(.primary)
            .frame(minWidth: 40, minHeight: 40)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.45 : 1) : 0.35)
    }
}

/// 页头里的「在本页里找」：点开页内查找。图标是带文字行的放大镜，和顶栏上全局搜索的放大镜、
/// 专辑艺人页「显示」菜单的筛选图标都分开。页面没挂 `libraryPageFind` 时不出现。
struct MinimalPageFindButton: View {
    @Environment(MinimalPageFindState.self) private var findState: MinimalPageFindState?

    var body: some View {
        if let findState, findState.isAvailable {
            Button {
                pmWithAnimation(.control) { findState.isActive.toggle() }
            } label: {
                Label(findState.prompt, systemImage: "text.magnifyingglass")
                    .foregroundStyle(findState.isActive ? Color.accentColor : Color.primary)
            }
            .accessibilityIdentifier("minimal.pageFind")
        }
    }
}

/// 音乐分类页页头最左边的「▶ 全部播放」：主题色圆底的播放键，字底下一行小字写数量。
struct MinimalPlayAllButton: View {
    var titleKey: LocalizedStringKey = "play_all"
    var subtitle: String? = nil
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.accentColor)
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .prominentLabelOnAccent()
                }
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 0) {
                    Text(titleKey)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityIdentifier("minimal.playAll")
    }
}

/// 页头里的数量（「8,426 首」）。
struct MinimalHeaderCount: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// 页头里的细竖线，把操作和数量隔开。
struct MinimalHeaderDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: 1, height: 16)
            .accessibilityHidden(true)
    }
}

/// 「有声」那一格里在有声书与播客之间切换。只有一页时不出现。
struct MinimalSpokenSwitcher: View {
    let current: LibrarySection

    @Environment(\.minimalSpokenSections) private var sections
    @Environment(\.minimalSelectSection) private var select
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var indicator

    var body: some View {
        if sections.count > 1, let select {
            HStack(spacing: 2) {
                ForEach(sections) { section in
                    let isSelected = section == current
                    Button {
                        guard !isSelected else { return }
                        select(section)
                    } label: {
                        Text(section.title)
                            .font(.subheadline.weight(isSelected ? .semibold : .medium))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(colorScheme == .dark
                                            ? Color(uiColor: .systemGray3)
                                            : Color(uiColor: .systemBackground))
                                        .shadow(
                                            color: .black.opacity(colorScheme == .dark ? 0 : 0.1),
                                            radius: 3, y: 1
                                        )
                                        .matchedGeometryEffect(id: "selection", in: indicator)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("minimal.spoken.\(section.rawValue)")
                }
            }
            .padding(3)
            .background(
                Color(uiColor: .secondarySystemFill),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
    }
}
#endif
