#if os(iOS)
import PrimuseKit
import SwiftUI
import UIKit

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

    /// 极简外壳的换页过渡，顶栏、页头、根页出现时从这里认领（见 `MinimalPageSwitchMotion`）。经典导航里为空。
    var minimalPageSwitchMotion: MinimalPageSwitchMotion? {
        get { self[MinimalPageSwitchMotionKey.self] }
        set { self[MinimalPageSwitchMotionKey.self] = newValue }
    }
}

private struct MinimalPageSwitchMotionKey: EnvironmentKey {
    static let defaultValue: MinimalPageSwitchMotion? = nil
}

// MARK: - 换页过渡

/// 极简导航点选换页的过渡：点顶上的去处、音乐的分类、「有声」里的切换。
///
/// 顶栏和页面都是每一页各挂一份：换分类时新页连同它头上那份顶栏是刚建出来的，首页与资料库之间
/// 是刚露出来的，都没有「上一帧」可以接着做动画。所以这里记下刚发生的这一次换页，新页、新顶栏
/// 出现时来认领：
/// - 旧页：换页前在窗口最上面盖一张截屏（系统合成器里的快照，App 里不重画），下一拍淡出。新页在底下
///   第一帧就是完整的样子，不用给整页挂透明度，也没有新旧两棵页面树同时活着；
/// - 新页：从它在顶栏上的那一侧轻推进来一小段（绘制位移，不动布局，见 `MinimalPageSwitchPolicy`）；
/// - 顶栏、页头：选中块、分类下划线先停在上一格，再滑到这一格。
///
/// 普通引用，不是 @Observable：记录、认领都不会让任何视图重算。换页本身不进动画事务。
@MainActor
final class MinimalPageSwitchMotion {
    struct Entry: Equatable {
        /// +1 从右侧进来，-1 从左侧（屏幕方向）。
        let side: CGFloat
        let distance: CGFloat
    }

    private struct Switch {
        let from: MinimalNavigationPage
        let to: MinimalNavigationPage
        /// 点选换的；横滑翻页只借顶栏指示，页面的过渡由横滑自己做。
        let isTap: Bool
        var entry: Entry?
        let time: TimeInterval

        var isFresh: Bool {
            MinimalPageSwitchPolicy.isFresh(elapsed: ProcessInfo.processInfo.systemUptime - time)
        }
    }

    private var latest: Switch?
    private weak var cover: UIView?
    /// 外壳里的一个空视图（`MinimalPageSwitchAnchor`）：从它找到所在的窗口，iPad 多窗口时不会找错。
    weak var anchorView: UIView?

    /// 点选换页：记下这一次，在窗口上盖住旧页。`entrySide` 为空时新页不推（减少动态效果、说不清方向）。
    func begin(from: MinimalNavigationPage, to: MinimalNavigationPage, entrySide: CGFloat?) {
        latest = Switch(
            from: from,
            to: to,
            isTap: true,
            entry: entrySide.map {
                Entry(side: $0, distance: CGFloat(MinimalPageSwitchPolicy.entryDistance))
            },
            time: ProcessInfo.processInfo.systemUptime
        )
        coverOutgoingPage()
    }

    /// 页面自己换了分类（横滑翻页）：只让新顶栏上的下划线从上一个分类滑过来。
    /// 刚点过的那一次还新鲜时不覆盖它：资料库换页途中旧分类页可能先露一下面，它报上来的不算数。
    func noteIndicatorChange(from: MinimalNavigationPage, to: MinimalNavigationPage) {
        if let latest, latest.isTap, latest.isFresh { return }
        latest = Switch(
            from: from,
            to: to,
            isTap: false,
            entry: nil,
            time: ProcessInfo.processInfo.systemUptime
        )
    }

    /// 刚换到的那一页满足 `arrivesAt` 时，换页前停在哪一页。过了新鲜期就不算（返回、切回来直接到位）。
    func origin(arrivingAt arrivesAt: (MinimalNavigationPage) -> Bool) -> MinimalNavigationPage? {
        guard let latest, latest.isFresh, arrivesAt(latest.to) else { return nil }
        return latest.from
    }

    /// 新页出现时认领进场的轻推，一次换页只给一回。
    func takeEntry(for page: MinimalNavigationPage) -> Entry? {
        guard var latest, latest.to == page, latest.isFresh, let entry = latest.entry else { return nil }
        latest.entry = nil
        self.latest = latest
        return entry
    }

    private func coverOutgoingPage() {
        guard let window = anchorView?.window else { return }
        // 连点时上一张还在淡：先撤掉。新截的这张取的是合成器里此刻的画面（上一张还在上面），前后接得上。
        cover?.removeFromSuperview()
        guard let snapshot = window.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = window.bounds
        snapshot.isUserInteractionEnabled = false
        snapshot.accessibilityElementsHidden = true
        window.addSubview(snapshot)
        cover = snapshot
        // 下一拍再淡：这一拍里换页、建新页，淡出跟新页的第一帧一起提交，透出来的就是完整的新页。
        // 用 UIKit 的动画而不是 SwiftUI 的：它在合成器里跑，新页建得慢、主线程忙时也照样走完。
        // 时长、曲线同 `PMMotion.pageSwitch`（easeOut）。
        Task { @MainActor in
            UIView.animate(
                withDuration: PMMotion.pageSwitch.settleDuration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
        }
    }
}

/// 外壳里一个不占地方、不接触摸的空视图，换页过渡靠它找到窗口。
struct MinimalPageSwitchAnchor: UIViewRepresentable {
    let motion: MinimalPageSwitchMotion

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        motion.anchorView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        motion.anchorView = uiView
    }
}

/// 不带动画地改状态：选中指示出现时先停到起点用，挡住外面事务里带进来的动画。
@MainActor
private func minimalSetWithoutAnimation(_ body: () -> Void) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
}

/// 栏下面滚动内容的收边方式。
enum MinimalBarEdgeEffect {
    /// 柔和淡出：栏不高时用。
    case soft
    /// 整段压实、底边一条分隔：栏叠得高（顶栏加页头），柔和淡出到最下面一行已经淡没了，
    /// 内容会直接压在那一行的字和按钮下面。
    case hard
}

/// 调试构建专用：启动时带 `PRIMUSE_DEBUG_LEGACY_CHROME=1`，iOS 26 起的系统也走 26.1 以前那套底部
/// chrome —— 标签栏上方自绘的迷你条与它的让位、极简外壳的 `safeAreaInset` 与底板、迷你条的磨砂底。
/// 编译机没有 iOS 18 运行时，老系统这条路只能这样在新系统上看；标签栏、搜索框、键盘这些系统自己
/// 画的东西仍是新系统的样子。正式构建恒为 false。
enum LegacyBottomChromeDebug {
    #if DEBUG
    static let isForced = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_LEGACY_CHROME"] == "1"
    #else
    static let isForced = false
    #endif
}

extension View {
    /// 极简外壳的上下栏。iOS 26 起用 `safeAreaBar`，滚动内容在栏下面收边；
    /// 更早的系统退回 `safeAreaInset`：顶栏自己铺一层底，免得列表从字底下透出来；底下只有
    /// 停靠条，它的底由 `minimalDockLegacyBackdrop()` 自己铺。
    @ViewBuilder
    func minimalSafeAreaBar<Bar: View>(
        edge: VerticalEdge,
        edgeEffect: MinimalBarEdgeEffect = .soft,
        @ViewBuilder content: () -> Bar
    ) -> some View {
        if LegacyBottomChromeDebug.isForced {
            legacyMinimalSafeAreaBar(edge: edge, content: content)
        } else if #available(iOS 26.0, *) {
            safeAreaBar(edge: edge, spacing: 0, content: content)
                .scrollEdgeEffectStyle(
                    edgeEffect == .hard ? .hard : .soft,
                    for: edge == .top ? .top : .bottom
                )
        } else {
            legacyMinimalSafeAreaBar(edge: edge, content: content)
        }
    }

    private func legacyMinimalSafeAreaBar<Bar: View>(
        edge: VerticalEdge,
        @ViewBuilder content: () -> Bar
    ) -> some View {
        safeAreaInset(edge: edge, spacing: 0) {
            switch edge {
            case .top: content().background(.bar)
            case .bottom: content()
            }
        }
    }

    /// 26 以前极简停靠条底下那层底。不能像顶栏那样在外面套 `.background(.bar)`：停靠条自己的
    /// 磨砂圆角板夹在两层材质中间，板上用 `.secondary` 的第二行（迷你歌词、歌手、章节）整行
    /// 画不出来，只剩空着的一行（实测）；而且一块板摆在一整条工具栏里，上沿一道硬边横过整屏。
    /// 这里用一层普通视图从板子中间往下渐渐铺实，列表在板子上方柔和地淡出去，接近 26 起
    /// `safeAreaBar` 的收边。挂在停靠条本身上，条子不在（没在播、键盘弹着）时这层也不在。
    @ViewBuilder
    func minimalDockLegacyBackdrop() -> some View {
        if LegacyBottomChromeDebug.isForced {
            background { MinimalDockLegacyBackdrop() }
        } else if #available(iOS 26.0, *) {
            self
        } else {
            background { MinimalDockLegacyBackdrop() }
        }
    }
}

private struct MinimalDockLegacyBackdrop: View {
    var body: some View {
        Rectangle()
            .fill(.bar)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.7), location: 0.45),
                        .init(color: .black, location: 0.8),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            MinimalTopTabPicker(tabs: tabs, selection: selectedTab, onSelect: onSelectTab)
                        }
                        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                        // 放不下时选中的那一段要在看得见的地方；放得下时什么也不动。
                        .onChange(of: selectedTab, initial: true) { _, tab in
                            guard let tab else { return }
                            proxy.scrollTo(tab)
                        }
                    }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.minimalPageSwitchMotion) private var switchMotion
    @Namespace private var indicator
    /// 白块暂时停在这一格，为空就是跟着 `selection`。顶栏每一页各挂一份，换页时新页上这一份是
    /// 刚建出来（刚露出来）的：先停在换页前那一格，下一拍再滑过来。
    @State private var heldTab: MinimalTopTab?

    private var shownTab: MinimalTopTab? { heldTab ?? selection }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                segment(tab)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
        .onAppear {
            slide(from: switchMotion?.origin(arrivingAt: { $0.topTab == selection })?.topTab)
        }
        .onChange(of: selection) { previous, _ in
            slide(from: previous)
        }
    }

    /// 白块从 `origin` 那一格滑到选中的一格。减少动态效果时不滑，直接落在选中的一格。
    private func slide(from origin: MinimalTopTab?) {
        guard let origin, let selection, origin != selection, tabs.contains(origin),
              let animation = PMMotion.selection.resolved(reduceMotion: reduceMotion) else {
            if heldTab != nil { minimalSetWithoutAnimation { heldTab = nil } }
            return
        }
        minimalSetWithoutAnimation { heldTab = origin }
        // 先在起点画一帧，下一拍再滑（两次改动并进同一帧就成了原地跳过去）。
        Task { @MainActor in
            guard heldTab == origin else { return }
            withAnimation(animation) { heldTab = nil }
        }
    }

    private func segment(_ tab: MinimalTopTab) -> some View {
        let isShown = tab == shownTab
        return Button {
            onSelect(tab)
        } label: {
            Text(tab.titleKey)
                .font(.callout.weight(isShown ? .semibold : .medium))
                .foregroundStyle(isShown ? Color.primary : Color.secondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background {
                    if isShown {
                        Capsule()
                            .fill(selectedFill)
                            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.1), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "selection", in: indicator)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == selection ? .isSelected : [])
        .accessibilityShowsLargeContentViewer()
        .accessibilityIdentifier("minimal.tab.\(tab.rawValue)")
        // 顶栏放不下横着滑的时候，按这个值把选中的一段滚进来。
        .id(tab)
    }

    private var selectedFill: Color {
        colorScheme == .dark
            ? Color(uiColor: .systemGray3)
            : Color(uiColor: .systemBackground)
    }
}

enum StandardLibrarySectionTabsPolicy {
    static func sections(
        enabled: Bool,
        mode: AppNavigationMode,
        selection: LibrarySection?,
        visibleSections: [LibrarySection]
    ) -> [LibrarySection] {
        guard enabled, mode == .standard,
              selection.map({ MinimalTopTab.tab(for: $0) == .music }) ?? true else { return [] }
        return MinimalNavigationPolicy.musicSections(visibleSections: visibleSections)
    }
}

struct StandardLibrarySectionTabs: View {
    let selection: LibrarySection?
    let onSelect: (LibrarySection) -> Void
    @Environment(\.appNavigationMode) private var navigationMode
    @AppStorage(HomeFilterBarConfiguration.showsLibrarySectionsKey) private var enabled = false
    @AppStorage(LibraryDisplayConfiguration.sectionOrderKey) private var orderRawValue = ""
    @AppStorage(LibraryDisplayConfiguration.hiddenSectionsKey) private var hiddenRawValue = ""
    @Environment(MusicLibrary.self) private var library

    var body: some View {
        let sections = StandardLibrarySectionTabsPolicy.sections(
            enabled: enabled, mode: navigationMode, selection: selection,
            visibleSections: LibraryDisplayConfiguration.visibleSections(
                orderRawValue: orderRawValue, hiddenRawValue: hiddenRawValue
            )
            // 「环境音」只在真有环境音时出现,和资料库首页一样。
            .filter { $0 != .ambient || library.hasAmbientContent }
        )
        if !sections.isEmpty {
            MinimalSectionTabs(
                sections: sections, selection: selection, onSelect: onSelect,
                accessibilityPrefix: "library.sectionTab"
            )
            .pmPinnedRowStopsAtVerticalBar()
        }
    }
}

/// 音乐下面的分类：选中的字加粗变墨色，底下一道主题色短线。
private struct MinimalSectionTabs: View {
    let sections: [LibrarySection]
    let selection: LibrarySection?
    let onSelect: (LibrarySection) -> Void
    var accessibilityPrefix = "minimal.section"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.minimalPageSwitchMotion) private var switchMotion
    @Namespace private var underline
    /// 下划线暂时停在这个分类，为空就是跟着 `selection`。换分类时新页上这份顶栏是刚建的：
    /// 先停在上一个分类（这一排也滚到那里），下一拍再滑过来。
    @State private var heldSection: LibrarySection?

    private var shownSection: LibrarySection? { heldSection ?? selection }

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
            .onAppear {
                let origin = switchMotion?.origin(arrivingAt: { page in
                    guard let selection else { return false }
                    return page == .librarySection(selection)
                })
                if case .librarySection(let section)? = origin {
                    slide(from: section, proxy: proxy)
                } else {
                    slide(from: nil, proxy: proxy)
                }
            }
            .onChange(of: selection) { previous, _ in
                slide(from: previous, proxy: proxy)
            }
        }
        .frame(height: 42)
    }

    /// 下划线从 `origin` 滑到选中的分类，这一排跟着把它滚到中间。没有起点或者减少动态效果时
    /// 直接落在选中的分类上，不从行首滚过去。
    private func slide(from origin: LibrarySection?, proxy: ScrollViewProxy) {
        guard let selection else { return }
        guard let origin, origin != selection, sections.contains(origin),
              let animation = PMMotion.selection.resolved(reduceMotion: reduceMotion) else {
            minimalSetWithoutAnimation {
                if heldSection != nil { heldSection = nil }
                proxy.scrollTo(selection, anchor: .center)
            }
            return
        }
        minimalSetWithoutAnimation {
            heldSection = origin
            proxy.scrollTo(origin, anchor: .center)
        }
        // 先在起点画一帧，下一拍再滑（两次改动并进同一帧就成了原地跳过去）。
        Task { @MainActor in
            guard heldSection == origin else { return }
            withAnimation(animation) {
                heldSection = nil
                proxy.scrollTo(selection, anchor: .center)
            }
        }
    }

    private func item(_ section: LibrarySection) -> some View {
        let isShown = section == shownSection
        return Button {
            onSelect(section)
        } label: {
            Text(section.title)
                .font(.body.weight(isShown ? .bold : .medium))
                .foregroundStyle(isShown ? Color.primary : Color.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if isShown {
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
        .accessibilityAddTraits(section == selection ? .isSelected : [])
        .accessibilityIdentifier("\(accessibilityPrefix).\(section.rawValue)")
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
    /// 顶栏这一份视图挂在每个标签页的根页上，切到搜索时几份同时换成输入框。
    /// 只有搜索页上那一份去接「弹键盘」，别让还挂在后台的首页、资料库那一份先把请求拿走。
    @Environment(\.minimalNavigationDetailScope) private var hostScope

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
            guard requested, hostScope == .search || hostScope == nil else { return }
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
        modifier(MinimalPageHeaderModifier(isPresented: nil, header: header))
    }

    /// 只在 `isPresented` 成立时才有的页头（搜索页多选时的全选与退出）。不成立时栏里没有内容、
    /// 高度为零，收边和顶栏一样；修饰符一直挂着，页面内容不换身份，滚动位置与输入框都留着。
    /// `isPresented` 在修饰符里求值：它读到的可观察状态只让这一层重画，不牵动整页。
    func minimalPageHeader<Header: View>(
        isPresented: @escaping () -> Bool,
        @ViewBuilder _ header: @escaping () -> Header
    ) -> some View {
        modifier(MinimalPageHeaderModifier(isPresented: isPresented, header: header))
    }
}

private struct MinimalPageHeaderModifier<Header: View>: ViewModifier {
    /// nil 表示页头一直在。
    let isPresented: (() -> Bool)?
    let header: () -> Header
    @Environment(\.minimalRootPage) private var isMinimalRoot
    @State private var findState = MinimalPageFindState()

    func body(content: Content) -> some View {
        if isMinimalRoot {
            let presented = isPresented?() ?? true
            content
                .environment(findState)
                // 页头叠在顶栏下面，整段栏很高：用实边，列表滚上来不会压在页头的字底下。
                // 没有页头时退回顶栏自己的柔和收边。
                .minimalSafeAreaBar(edge: .top, edgeEffect: presented ? .hard : .soft) {
                    if presented {
                        header()
                            .environment(findState)
                            .padding(.leading, 16)
                            .padding(.trailing, 8)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.minimalPageSwitchMotion) private var switchMotion
    @Namespace private var indicator
    /// 白块暂时停在这一页，为空就是停在 `current`。切过来时这是新页上刚建的一份：
    /// 先停在切换前那一页，下一拍再滑过来（见 `MinimalPageSwitchMotion`）。
    @State private var heldSection: LibrarySection?

    var body: some View {
        if sections.count > 1, let select {
            HStack(spacing: 2) {
                ForEach(sections) { section in
                    let isSelected = section == current
                    let isShown = section == (heldSection ?? current)
                    Button {
                        guard !isSelected else { return }
                        select(section)
                    } label: {
                        Text(section.title)
                            .font(.subheadline.weight(isShown ? .semibold : .medium))
                            .foregroundStyle(isShown ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background {
                                if isShown {
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
            .onAppear(perform: slideInFromPreviousPage)
        }
    }

    private func slideInFromPreviousPage() {
        let previousPage = switchMotion?.origin(arrivingAt: { $0 == .librarySection(current) })
        guard case .librarySection(let origin)? = previousPage,
              origin != current, sections.contains(origin),
              let animation = PMMotion.selection.resolved(reduceMotion: reduceMotion) else { return }
        minimalSetWithoutAnimation { heldSection = origin }
        Task { @MainActor in
            guard heldSection == origin else { return }
            withAnimation(animation) { heldSection = nil }
        }
    }
}
#endif
