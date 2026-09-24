#if os(iOS)
import PrimuseKit
import SwiftUI

// MARK: - 根页动作

/// 顶部 tab 外壳里,根页不显示系统导航栏(tab 条就是标题),根页原来挂在导航栏上的按钮
/// 经这里交给 tab 条右侧的「页面动作」槽位。
///
/// 按页面分开登记:外壳会让几页同时常驻,它们的动作都会冒上来,tab 条只取当前那一页的。
/// 动作按值收进来,在 tab 条里渲染,所以里面的视图不能指望读到页面自己的环境
/// (`EditButton` 这类读 `\.editMode` 的要换成显式按钮),和导航栏条目是同一条约束。
struct MinimalRootActionsContent {
    let content: AnyView
}

struct MinimalRootActionsPreferenceKey: PreferenceKey {
    static var defaultValue: [MinimalNavigationPage: MinimalRootActionsContent] { [:] }

    static func reduce(
        value: inout [MinimalNavigationPage: MinimalRootActionsContent],
        nextValue: () -> [MinimalNavigationPage: MinimalRootActionsContent]
    ) {
        value.merge(nextValue()) { _, next in next }
    }
}

/// 根页正处在自己的编辑态(电台整理、歌单批量管理)。这时外壳收起 tab 条、把系统导航栏
/// 还给这一页 —— 编辑态的「完成」、选中计数与批量菜单都在那里。
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

extension EnvironmentValues {
    /// 当前视图是不是顶部 tab 外壳某一页的根页内容;详情页里恒为 nil。
    var minimalRootActionsPage: MinimalNavigationPage? {
        get { self[MinimalRootActionsPageEnvironmentKey.self] }
        set { self[MinimalRootActionsPageEnvironmentKey.self] = newValue }
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
}

private struct MinimalRootActionsModifier: ViewModifier {
    let actions: AnyView
    @Environment(\.minimalRootActionsPage) private var page

    func body(content: Content) -> some View {
        content.preference(
            key: MinimalRootActionsPreferenceKey.self,
            value: page.map { [$0: MinimalRootActionsContent(content: actions)] } ?? [:]
        )
    }
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

/// 顶部 tab 外壳(`SkinSlotVariant.NavigationHeader.topTabs`)的那一行:左边是横向可滚的 tab 条,
/// 右边固定是当前页的动作、搜索和设置。
///
/// 整个外壳只有这一份实例,挂在所有页面之上,所以切 tab 时选中指示器能从旧位置滑到新位置,
/// tab 条也记得自己滚到了哪里。它只负责画法:有哪些 tab、选中哪个、点了去哪都由外壳给。
struct TopTabsChrome: View {
    let pages: [MinimalNavigationPage]
    let selection: MinimalNavigationPage?
    let actions: AnyView?
    /// 这一行的高度。外壳用同一个值给根页留出顶部空间,两边必须一致。
    let rowHeight: CGFloat
    let onSelect: (MinimalNavigationPage) -> Void
    let onSearch: () -> Void
    let onSettings: () -> Void

    @Environment(\.skin) private var skin
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var indicatorNamespace

    var body: some View {
        HStack(spacing: 0) {
            tabStrip
            trailingCluster
        }
        .frame(height: rowHeight)
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

    private var trailingCluster: some View {
        HStack(spacing: 0) {
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
