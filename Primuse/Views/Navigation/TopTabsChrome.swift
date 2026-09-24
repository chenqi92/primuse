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
struct TopTabsChrome: View {
    let pages: [MinimalNavigationPage]
    let selection: MinimalNavigationPage?
    let actions: AnyView?
    /// 当前页的页内筛选(专辑、艺术家、流派、电台)。有它时动作槽里多一颗筛选键,展开时 tab 条下面多一行筛选框。
    var filter: MinimalRootFilterContent? = nil
    /// 这一行的高度。外壳用同一个值给根页留出顶部空间,两边必须一致。
    let rowHeight: CGFloat
    let onSelect: (MinimalNavigationPage) -> Void
    let onSearch: () -> Void
    let onSettings: () -> Void

    @Environment(\.skin) private var skin
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.pmHeightClass) private var heightClass
    @Namespace private var indicatorNamespace

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabStrip
                trailingCluster
            }
            .frame(height: rowHeight)

            if let filter, filter.isPresented.wrappedValue {
                MinimalRootFilterField(filter: filter) {
                    dismissFilter(filter)
                }
                .frame(height: MinimalRootFilterField.rowHeight(dynamicTypeSize, isCompactHeight: heightClass.isCompact))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            chromeFill
                .ignoresSafeArea(.container, edges: [.top, .horizontal])
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(skin.color(.separator))
                .frame(height: skin.rawMetric(.hairline))
                .ignoresSafeArea(.container, edges: .horizontal)
                .allowsHitTesting(false)
        }
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
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: skin.rawMetric(.chromeItemSpacing) * 2) {
                    ForEach(pages) { page in
                        TopTabsChromeTab(
                            page: page,
                            isSelected: page == selection,
                            namespace: indicatorNamespace
                        ) {
                            onSelect(page)
                        }
                        .id(page)
                    }
                }
                .padding(.horizontal, skin.rawMetric(.chromeHorizontalInset) + 4)
                .frame(maxHeight: .infinity)
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
        }
    }

    /// 两端淡出,提示这一行还能往两边滚。
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 10)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 18)
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
        HStack(spacing: 0) {
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
        .buttonStyle(TopTabsChromeButtonStyle(height: rowHeight))
        .font(.system(size: skin.metric(.iconSizeMedium), weight: .semibold))
        .foregroundStyle(.skin(.textPrimary))
        .padding(.trailing, max(0, skin.rawMetric(.chromeHorizontalInset) - 6))
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct TopTabsChromeTab: View {
    let page: MinimalNavigationPage
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @Environment(\.skin) private var skin

    var body: some View {
        Button(action: action) {
            ZStack {
                // 按选中时的粗体占好宽度,切换选中时文字不会把两边的 tab 挤得跳一下。
                Text(verbatim: page.localizedTitle)
                    .font(skin.font(.chromeCompact))
                    .hidden()
                Text(verbatim: page.localizedTitle)
                    .font(skin.font(isSelected ? .chromeCompact : .chrome))
                    .foregroundStyle(isSelected ? skin.color(.textPrimary) : skin.color(.chromeItem))
            }
            .lineLimit(1)
            .fixedSize()
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Capsule()
                        .fill(skin.color(.accent))
                        .frame(width: 18, height: 3)
                        .matchedGeometryEffect(id: "topTabs.indicator", in: namespace)
                        .padding(.bottom, 4)
                }
            }
            // plain 样式的点击热区只有文字本身,整格(含上下留白)都要能点。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("topTabs.tab.\(page.id)")
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
