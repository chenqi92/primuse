#if os(iOS)
import PrimuseKit
import SwiftUI
import UIKit

// MARK: - 根页动作

/// 顶部 tab 外壳里,根页不显示系统导航栏(tab 条就是标题),根页原来挂在导航栏上的按钮
/// 经这里交给 tab 条右侧的「页面动作」槽位。
///
/// 按页面分开登记:外壳会让几页同时常驻,它们的动作都会冒上来,tab 条只取当前那一页的。
/// 动作按值收进来,在 tab 条里渲染,所以里面的视图不能指望读到页面自己的环境
/// (`EditButton` 这类读 `\.editMode` 的要换成显式按钮),和导航栏条目是同一条约束。
/// 页面动作与页内筛选(`minimalRootFilter`)各占一格,谁先登记都不会把另一格盖掉。
struct MinimalRootActionsContent {
    var content: AnyView?
    var filter: MinimalRootFilterContent?

    func merged(with next: MinimalRootActionsContent) -> MinimalRootActionsContent {
        MinimalRootActionsContent(content: next.content ?? content, filter: next.filter ?? filter)
    }
}

/// 根页的页内筛选:绑定的是页面给 `.searchable` 用的同一个文本,筛选逻辑还在页面里,只有一份。
struct MinimalRootFilterContent {
    let text: Binding<String>
    let isPresented: Binding<Bool>
    let prompt: Text
}

struct MinimalRootActionsPreferenceKey: PreferenceKey {
    static var defaultValue: [MinimalNavigationPage: MinimalRootActionsContent] { [:] }

    static func reduce(
        value: inout [MinimalNavigationPage: MinimalRootActionsContent],
        nextValue: () -> [MinimalNavigationPage: MinimalRootActionsContent]
    ) {
        value.merge(nextValue()) { current, next in current.merged(with: next) }
    }
}

/// 根页正处在自己的编辑态(电台整理、歌单批量管理;歌曲多选由根页修饰符按页转进来)。
/// 这时外壳收起 tab 条、把系统导航栏还给这一页 —— 编辑态的「完成」、选中计数与批量菜单都在那里。
struct MinimalRootEditingPreferenceKey: PreferenceKey {
    static let defaultValue: Set<MinimalNavigationPage> = []

    static func reduce(
        value: inout Set<MinimalNavigationPage>,
        nextValue: () -> Set<MinimalNavigationPage>
    ) {
        value.formUnion(nextValue())
    }
}

private struct MinimalRootActionsPageEnvironmentKey: EnvironmentKey {
    static let defaultValue: MinimalNavigationPage? = nil
}

private struct MinimalRootNavigationBarRevealedEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 当前视图是不是顶部 tab 外壳某一页的根页内容;详情页里恒为 nil。
    var minimalRootActionsPage: MinimalNavigationPage? {
        get { self[MinimalRootActionsPageEnvironmentKey.self] }
        set { self[MinimalRootActionsPageEnvironmentKey.self] = newValue }
    }

    /// 根页正处在编辑态、系统导航栏回到了这一页(连同页面自己的 `.searchable` 框)。
    var minimalRootNavigationBarRevealed: Bool {
        get { self[MinimalRootNavigationBarRevealedEnvironmentKey.self] }
        set { self[MinimalRootNavigationBarRevealedEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// 把根页的导航栏按钮交给顶部 tab 条。超过两个时由页面自己收进一个 `Menu`。
    /// 不在顶部 tab 外壳的根页里(经典外观、详情页、iPad)时什么都不做。
    func minimalRootActions<Actions: View>(@ViewBuilder _ actions: () -> Actions) -> some View {
        modifier(MinimalRootActionsModifier(actions: AnyView(actions())))
    }

    /// 根页进入 / 退出自己的编辑态。
    func minimalRootEditing(_ isEditing: Bool) -> some View {
        modifier(MinimalRootEditingModifier(isEditing: isEditing))
    }

    /// 顶部 tab 外壳根页的页内筛选:tab 条动作槽里多一颗筛选键,点开后 tab 条下方展开一条筛选框。
    ///
    /// `text` 必须是页面给经典外观 `.searchable` 用的同一个状态 —— 筛选逻辑只有一份,两种外观只是入口不同。
    /// 筛选框展开时页面顶部多让出一行,列表不会被盖住;收起(取消)时清空文本。
    /// 不在顶部 tab 外壳的根页里(经典外观、详情页、iPad)时什么都不做。
    func minimalRootFilter(text: Binding<String>, isPresented: Binding<Bool>, prompt: Text) -> some View {
        modifier(MinimalRootFilterModifier(text: text, isPresented: isPresented, prompt: prompt))
    }
}

private struct MinimalRootActionsModifier: ViewModifier {
    let actions: AnyView
    @Environment(\.minimalRootActionsPage) private var page

    func body(content: Content) -> some View {
        let page = page
        let actions = actions
        content.transformPreference(MinimalRootActionsPreferenceKey.self) { value in
            guard let page else { return }
            value[page] = (value[page] ?? MinimalRootActionsContent()).merged(
                with: MinimalRootActionsContent(content: actions)
            )
        }
    }
}

private struct MinimalRootFilterModifier: ViewModifier {
    let text: Binding<String>
    let isPresented: Binding<Bool>
    let prompt: Text

    @Environment(\.minimalRootActionsPage) private var page
    @Environment(\.minimalRootNavigationBarRevealed) private var navigationBarRevealed
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.pmHeightClass) private var heightClass

    @ViewBuilder
    func body(content: Content) -> some View {
        if let page {
            let filter = MinimalRootFilterContent(text: text, isPresented: isPresented, prompt: prompt)
            // 编辑态时系统导航栏连同页面自己的搜索框回来了,不再另外让出一行。
            let reserved = isPresented.wrappedValue && !navigationBarRevealed
                ? MinimalRootFilterField.rowHeight(dynamicTypeSize, isCompactHeight: heightClass.isCompact)
                : 0
            content
                .minimalSafeAreaBar(edge: .top) {
                    Color.clear.frame(height: reserved)
                }
                .transformPreference(MinimalRootActionsPreferenceKey.self) { value in
                    value[page] = (value[page] ?? MinimalRootActionsContent()).merged(
                        with: MinimalRootActionsContent(filter: filter)
                    )
                }
                #if DEBUG
                .task { await runDebugFilter() }
                #endif
        } else {
            content
        }
    }

    #if DEBUG
    /// 编译机截图用:`PRIMUSE_DEBUG_FILTER=<词>` 时进页两秒后展开筛选框、再输入这个词;
    /// `-` 只展开不输入;词后面带 `!` 时输入完收起键盘,看筛选结果与停靠条。
    @MainActor
    private func runDebugFilter() async {
        guard var word = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_FILTER"] else { return }
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        isPresented.wrappedValue = true
        let dismissesKeyboard = word.hasSuffix("!")
        if dismissesKeyboard { word.removeLast() }
        guard !word.isEmpty, word != "-" else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard !Task.isCancelled else { return }
        text.wrappedValue = word
        guard dismissesKeyboard else { return }
        try? await Task.sleep(for: .seconds(1))
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    #endif
}

private struct MinimalRootEditingModifier: ViewModifier {
    let isEditing: Bool
    @Environment(\.minimalRootActionsPage) private var page

    func body(content: Content) -> some View {
        content.preference(
            key: MinimalRootEditingPreferenceKey.self,
            value: isEditing ? Set([page].compactMap { $0 }) : []
        )
    }
}

// MARK: - tab 条

/// 顶部 tab 外壳(`SkinShell.Navigation.topTabs`)的那一行:左边是横向可滚的 tab 条,
/// 右边固定是当前页的动作、搜索和设置。
///
/// 整个外壳只有这一份实例,挂在所有页面之上,所以切 tab 时选中指示器能从旧位置滑到新位置,
/// tab 条也记得自己滚到了哪里。它只负责画法:有哪些 tab、选中哪个、点了去哪都由外壳给。
///
/// 系统把工具栏竖排到侧边时(iPhone Duo 等,`railEdge` 不为 nil),同一份内容改排成那一侧的竖栏:
/// 住进系统竖栏让出的那条安全区,tab 纵向滚动,动作、搜索、设置收在竖栏底部,顶部的高度还给页面。
/// 横排与竖排只是排法不同(同一棵视图树换布局参数),开合、转屏时 tab 条的状态都还在。
struct TopTabsChrome: View {
    let pages: [MinimalNavigationPage]
    let selection: MinimalNavigationPage?
    let actions: AnyView?
    /// 当前页的页内筛选(专辑、艺术家、流派、电台)。有它时动作槽里多一颗筛选键,展开时 tab 条下面多一行筛选框。
    var filter: MinimalRootFilterContent? = nil
    /// 这一行的高度。外壳用同一个值给根页留出顶部空间,两边必须一致。
    let rowHeight: CGFloat
    /// 系统竖栏在哪一侧。为 nil 时是顶部横排的一行(普通 iPhone、Xcode 27.0 构建)。
    var railEdge: HorizontalEdge? = nil
    /// 竖栏宽度:系统竖栏那一侧让出的安全区。
    var railWidth: CGFloat = 0
    /// 竖栏时根页顶部的留白。外壳给根页留的是同一个值,筛选框从它下面开始。
    var railContentTopInset: CGFloat = 0
    let onSelect: (MinimalNavigationPage) -> Void
    let onSearch: () -> Void
    let onSettings: () -> Void

    @Environment(\.skin) private var skin
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.pmHeightClass) private var heightClass
    @Namespace private var indicatorNamespace
    /// 竖栏顶端要让开的遮挡(竖排的状态栏与摄像头),按系统报的遮挡区量出来。
    @State private var railTopClearance = CGFloat(TopTabsRailLayoutPolicy.minimumTopClearance)

    private var isRail: Bool { railEdge != nil }

    var body: some View {
        let isRail = isRail
        let layout = isRail
            ? AnyLayout(TopTabsRailChromeLayout(edge: railEdge ?? .trailing, railWidth: railWidth))
            : AnyLayout(VStackLayout(spacing: 0))
        layout {
            bar

            if let filter, filter.isPresented.wrappedValue {
                MinimalRootFilterField(filter: filter) {
                    dismissFilter(filter)
                }
                .frame(height: MinimalRootFilterField.rowHeight(dynamicTypeSize, isCompactHeight: heightClass.isCompact))
                // 竖栏时筛选框自己是页面顶上的一行:底色与分隔线跟着它走。
                .padding(.top, isRail ? railContentTopInset : 0)
                .background {
                    if isRail {
                        chromeFill.ignoresSafeArea(.container, edges: .top)
                    }
                }
                .overlay(alignment: .bottom) {
                    if isRail {
                        hairline(vertical: false)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: isRail ? .infinity : nil)
        .background {
            if !isRail {
                chromeFill
                    .ignoresSafeArea(.container, edges: [.top, .horizontal])
            }
        }
        .overlay(alignment: .bottom) {
            if !isRail {
                hairline(vertical: false)
                    .ignoresSafeArea(.container, edges: .horizontal)
            }
        }
    }

    /// tab 与右侧(竖栏时是底部)那组按钮。
    private var bar: some View {
        let isRail = isRail
        let layout = isRail ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            tabStrip
            trailingCluster
        }
        .frame(height: isRail ? nil : rowHeight)
        .padding(.top, isRail ? railTopClearance : 0)
        .background {
            if isRail {
                chromeFill
                    .ignoresSafeArea(.container, edges: [.vertical, .horizontal])
            }
        }
        .overlay(alignment: railEdge == .leading ? .trailing : .leading) {
            if isRail {
                hairline(vertical: true)
                    .ignoresSafeArea(.container, edges: .vertical)
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            guard isRail else { return CGFloat(TopTabsRailLayoutPolicy.minimumTopClearance) }
            return CGFloat(TopTabsRailLayoutPolicy.topClearance(
                occlusions: PMReservedRegions.activeOcclusionSpans(in: proxy),
                railHeight: Double(proxy.size.height)
            ))
        } action: { clearance in
            railTopClearance = clearance
        }
    }

    private func hairline(vertical: Bool) -> some View {
        Rectangle()
            .fill(skin.color(.separator))
            .frame(width: vertical ? skin.rawMetric(.hairline) : nil, height: vertical ? nil : skin.rawMetric(.hairline))
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var chromeFill: some View {
        if reduceTransparency || skin.usesSolidChrome {
            Rectangle().fill(skin.color(.canvasElevated))
        } else {
            // 半透明底色叠在模糊之上:底下滚过的封面只透出一点颜色,tab 文字始终可读。
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(skin.color(.chromeBackground))
            }
        }
    }

    private var tabStrip: some View {
        let isRail = isRail
        let stack = isRail
            ? AnyLayout(VStackLayout(spacing: 2))
            : AnyLayout(HStackLayout(spacing: skin.rawMetric(.chromeItemSpacing) * 2))
        return ScrollViewReader { proxy in
            ScrollView(isRail ? .vertical : .horizontal, showsIndicators: false) {
                stack {
                    ForEach(pages) { page in
                        TopTabsChromeTab(
                            page: page,
                            isSelected: page == selection,
                            namespace: indicatorNamespace,
                            railEdge: railEdge
                        ) {
                            onSelect(page)
                        }
                        .id(page)
                    }
                }
                .padding(isRail ? .vertical : .horizontal, isRail ? 4 : skin.rawMetric(.chromeHorizontalInset) + 4)
                .frame(maxWidth: isRail ? .infinity : nil, maxHeight: isRail ? nil : .infinity)
                .animation(skin.animation(.selection), value: selection)
            }
            .mask { edgeFade }
            .onAppear {
                guard let selection else { return }
                proxy.scrollTo(selection, anchor: .center)
            }
            .onChange(of: selection) { _, selected in
                guard let selected else { return }
                withAnimation(skin.animation(.selection)) {
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
            .onChange(of: isRail) { _, _ in
                // 横竖互换后滚动方向变了,原来的偏移没有意义:让选中项回到可见处。
                guard let selection else { return }
                proxy.scrollTo(selection, anchor: .center)
            }
        }
    }

    /// 两端淡出,提示这一行(一列)还能往两边滚。
    private var edgeFade: some View {
        let isRail = isRail
        let layout = isRail ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            LinearGradient(colors: [.clear, .black],
                           startPoint: isRail ? .top : .leading,
                           endPoint: isRail ? .bottom : .trailing)
                .frame(width: isRail ? nil : 10, height: isRail ? 10 : nil)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear],
                           startPoint: isRail ? .top : .leading,
                           endPoint: isRail ? .bottom : .trailing)
                .frame(width: isRail ? nil : 18, height: isRail ? 18 : nil)
        }
    }

    /// 收起筛选框并清空:先不带动画清掉文本(逐键筛选的结果集不进动画事务),再带动画收起那一行。
    private func dismissFilter(_ filter: MinimalRootFilterContent) {
        filter.text.wrappedValue = ""
        withAnimation(skin.animation(.chromeReveal)) {
            filter.isPresented.wrappedValue = false
        }
    }

    private func toggleFilter(_ filter: MinimalRootFilterContent) {
        if filter.isPresented.wrappedValue {
            dismissFilter(filter)
        } else {
            withAnimation(skin.animation(.chromeReveal)) {
                filter.isPresented.wrappedValue = true
            }
        }
    }

    private var trailingCluster: some View {
        let isRail = isRail
        let layout = isRail
            ? AnyLayout(TopTabsRailClusterLayout(width: railWidth))
            : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            if let filter {
                let isOpen = filter.isPresented.wrappedValue
                Button {
                    toggleFilter(filter)
                } label: {
                    Image(systemName: isOpen
                          ? "line.3.horizontal.decrease.circle.fill"
                          : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(isOpen ? skin.color(.accent) : skin.color(.textPrimary))
                }
                .accessibilityLabel(Text("filter_by"))
                .accessibilityAddTraits(isOpen ? .isSelected : [])
                .accessibilityIdentifier("topTabs.filter")
            }

            if let actions {
                actions
                    .labelStyle(.iconOnly)
                    .menuStyle(.button)
            }

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel(Text("search_title"))
            .accessibilityIdentifier("topTabs.search")

            Button(action: onSettings) {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel(Text("settings_title"))
            .accessibilityIdentifier("topTabs.settings")
        }
        .buttonStyle(TopTabsChromeButtonStyle(height: isRail ? Self.railButtonHeight : rowHeight))
        .font(.system(size: skin.metric(.iconSizeMedium), weight: .semibold))
        .foregroundStyle(.skin(.textPrimary))
        .padding(isRail ? .bottom : .trailing, isRail ? 4 : max(0, skin.rawMetric(.chromeHorizontalInset) - 6))
        // 竖栏里这组按钮紧接在 tab 下面:上沿一道短分隔线,页面动作不会被看成又一个 tab。
        .padding(.top, isRail ? 9 : 0)
        .overlay(alignment: .top) {
            if isRail {
                Capsule()
                    .fill(skin.color(.separator))
                    .frame(width: 28, height: 1)
                    .allowsHitTesting(false)
            }
        }
        .fixedSize(horizontal: !isRail, vertical: isRail)
    }

    /// 竖栏底部按钮的高度(宽度仍是 40 起)。
    private static let railButtonHeight: CGFloat = 44
}

/// 竖栏时 tab 条的外层排法:第一个子视图(tab 与按钮那一列)放进系统竖栏让出的那条安全区 ——
/// 它在这个容器(安全区以内)的外侧,紧贴着容器那一边;筛选框(如果展开)是页面顶上的一行。
private struct TopTabsRailChromeLayout: Layout {
    let edge: HorizontalEdge
    let railWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let rail = subviews.first else { return }
        let railX = edge == .trailing ? bounds.maxX : bounds.minX - railWidth
        rail.place(
            at: CGPoint(x: railX, y: bounds.minY),
            proposal: ProposedViewSize(width: railWidth, height: bounds.height)
        )
        for row in subviews.dropFirst() {
            let height = row.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            row.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                proposal: ProposedViewSize(width: bounds.width, height: height)
            )
        }
    }
}

/// 竖栏底部那组按钮:从末尾往前每行放满(`TopTabsRailLayoutPolicy.clusterRows`),每行居中。
private struct TopTabsRailClusterLayout: Layout {
    let width: CGFloat

    private func rows(_ subviews: Subviews) -> (rows: [Range<Int>], sizes: [CGSize]) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = TopTabsRailLayoutPolicy.clusterRows(
            itemWidths: sizes.map { Double($0.width) },
            railWidth: Double(width)
        )
        return (rows, sizes)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = rows(subviews)
        let height = layout.rows.reduce(CGFloat(0)) { total, row in
            total + (layout.sizes[row].map(\.height).max() ?? 0)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(subviews)
        var y = bounds.minY
        for row in layout.rows {
            let sizes = layout.sizes[row]
            let rowWidth = sizes.reduce(CGFloat(0)) { $0 + $1.width }
            let rowHeight = sizes.map(\.height).max() ?? 0
            var x = bounds.midX - rowWidth / 2
            for index in row {
                let size = layout.sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width
            }
            y += rowHeight
        }
    }
}

private struct TopTabsChromeTab: View {
    let page: MinimalNavigationPage
    let isSelected: Bool
    let namespace: Namespace.ID
    /// 竖栏时在哪一侧;横排为 nil。
    var railEdge: HorizontalEdge? = nil
    let action: () -> Void

    @Environment(\.skin) private var skin

    var body: some View {
        let isRail = railEdge != nil
        Button(action: action) {
            // 竖栏只有七八十点宽,放不下整行文字:图标在上、两行小字在下,像系统竖排的标签栏那样。
            VStack(spacing: 3) {
                if isRail {
                    Image(systemName: page.railSymbol)
                        .symbolVariant(isSelected ? .fill : .none)
                        .font(.system(size: 19, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? skin.color(.accent) : skin.color(.chromeItem))
                        .frame(height: 24)
                }
                ZStack {
                    // 按选中时的粗体占好宽度,切换选中时文字不会把两边的 tab 挤得跳一下。
                    Text(verbatim: page.localizedTitle)
                        .font(labelFont(selected: true, isRail: isRail))
                        .hidden()
                    Text(verbatim: page.localizedTitle)
                        .font(labelFont(selected: isSelected, isRail: isRail))
                        .foregroundStyle(isSelected ? skin.color(.textPrimary) : skin.color(.chromeItem))
                }
                // 竖栏里多个词的标题折成两行;一个长词(德语、俄语常见)不在词中间断开,缩小到放得下。
                .lineLimit(isRail && page.localizedTitle.contains(" ") ? 2 : 1)
                .multilineTextAlignment(isRail ? .center : .leading)
                .minimumScaleFactor(isRail ? 0.6 : 1)
                .fixedSize(horizontal: !isRail, vertical: true)
            }
            .frame(maxWidth: isRail ? .infinity : nil, maxHeight: isRail ? nil : .infinity)
            .padding(.vertical, isRail ? 8 : 0)
            .padding(.horizontal, isRail ? 5 : 0)
            .overlay(alignment: indicatorAlignment) {
                if isSelected {
                    Capsule()
                        .fill(skin.color(.accent))
                        .frame(width: isRail ? 3 : 18, height: isRail ? 22 : 3)
                        .matchedGeometryEffect(id: "topTabs.indicator", in: namespace)
                        .padding(.bottom, isRail ? 0 : 4)
                }
            }
            // plain 样式的点击热区只有文字本身,整格(含上下留白)都要能点。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("topTabs.tab.\(page.id)")
    }

    /// 横排时指示器是标签下面的短横线;竖栏时是贴着页面那一侧的短竖线。
    private var indicatorAlignment: Alignment {
        switch railEdge {
        case .none: return .bottom
        case .trailing: return .leading
        case .leading: return .trailing
        }
    }

    private func labelFont(selected: Bool, isRail: Bool) -> Font {
        if isRail {
            return .caption.weight(selected ? .semibold : .medium)
        }
        return skin.font(selected ? .chromeCompact : .chrome)
    }
}

/// tab 条下面那一行筛选框:放大镜、输入框、清除键,右边一颗「取消」。展开时自动聚焦。
///
/// 住在外壳的 tab 条里(和 tab 条同一块材质),绑定的是页面的筛选文本;页面自己按同样的行高让出顶部空间。
struct MinimalRootFilterField: View {
    let filter: MinimalRootFilterContent
    let onCancel: () -> Void

    @Environment(\.skin) private var skin
    @FocusState private var focused: Bool

    /// 这一行的高度。外壳画这一行、页面让出顶部空间,都按它算。
    static func rowHeight(_ typeSize: DynamicTypeSize, isCompactHeight: Bool) -> CGFloat {
        let base: CGFloat = isCompactHeight ? 44 : 50
        switch typeSize {
        case .xSmall, .small, .medium, .large: return base
        case .xLarge, .xxLarge: return base + 4
        case .xxxLarge: return base + 8
        default: return base + 20
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.skin(.textSecondary))
                    .accessibilityHidden(true)
                TextField("", text: filter.text, prompt: filter.prompt)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit { focused = false }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("topTabs.filterField")

                if !filter.text.wrappedValue.isEmpty {
                    Button {
                        filter.text.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.skin(.textSecondary))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("clear"))
                }
            }
            .font(.body)
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .frame(maxHeight: .infinity)
            .background(skin.color(.surface), in: Capsule())
            .overlay {
                Capsule().strokeBorder(skin.color(.separator), lineWidth: skin.rawMetric(.hairline))
            }
            .contentShape(Capsule())
            .onTapGesture { focused = true }

            Button("cancel", action: onCancel)
                .font(.body)
                .foregroundStyle(skin.color(.accent))
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityIdentifier("topTabs.filterCancel")
        }
        .padding(.horizontal, skin.rawMetric(.chromeHorizontalInset) + 4)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .task {
            // 展开的这一帧输入框还没挂上,放到下一轮再聚焦。
            focused = true
        }
    }
}

/// tab 条右侧的图标按钮:统一的命中区与按下态。页面交进来的菜单也走这一套。
private struct TopTabsChromeButtonStyle: ButtonStyle {
    let height: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        TopTabsChromeButtonLabel(configuration: configuration, height: height)
    }
}

private struct TopTabsChromeButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .frame(minWidth: 40, minHeight: height)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.45 : 1) : 0.35)
    }
}
#endif
