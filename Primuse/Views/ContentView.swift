import SwiftUI
#if os(iOS)
import MusicKit
import PrimuseKit
import UIKit

enum AppNavigationMode: String, CaseIterable, Sendable {
    case standard
    case minimal

    static let storageKey = "primuse.navigation.mode.v1"

    static func resolve(_ rawValue: String) -> AppNavigationMode {
        AppNavigationMode(rawValue: rawValue) ?? .standard
    }
}

enum AppNavigationRootLayout: Equatable, Sendable {
    case standardTabs
    case standardSidebar
    case minimal
}

enum AppTabSelectionPolicy {
    static func resolve(_ storedValue: Int) -> Int {
        (0...3).contains(storedValue) ? storedValue : 0
    }
}

enum AppNavigationLayoutPolicy {
    /// `allowsSidebar` 只在 iPad 上为 true。iPhone 的宽度等级会随开合
    /// (iPhone Duo 内外屏)和大屏机型横竖屏来回翻转，整棵根视图在侧边栏和
    /// 标签栏之间互换会把各页已经推进去的详情页全部清掉；TabView 自己就能
    /// 适配这些形态，所以 iPhone 始终留在标签栏。
    static func rootLayout(
        mode: AppNavigationMode,
        usesRegularWidth: Bool,
        allowsSidebar: Bool
    ) -> AppNavigationRootLayout {
        if mode == .minimal { return .minimal }
        return usesRegularWidth && allowsSidebar ? .standardSidebar : .standardTabs
    }
}

enum AppBottomChromeOwner: Equatable, Sendable {
    case systemTabBar
    case minimalNavigation
    case batchSelection
}

enum AppNavigationChromePolicy {
    static func bottomChromeOwner(
        mode: AppNavigationMode,
        batchSelectionActive: Bool
    ) -> AppBottomChromeOwner {
        if batchSelectionActive { return .batchSelection }
        if mode == .minimal { return .minimalNavigation }
        return .systemTabBar
    }

    static func hidesSystemTabBar(
        mode: AppNavigationMode,
        batchSelectionActive: Bool
    ) -> Bool {
        bottomChromeOwner(
            mode: mode,
            batchSelectionActive: batchSelectionActive
        ) != .systemTabBar
    }
}

enum MinimalNavigationPage: Hashable, Identifiable, Sendable {
    case home
    case librarySection(LibrarySection)
    case search
    case settings

    var id: String {
        switch self {
        case .home: return "home"
        case .librarySection(let section): return "library:\(section.rawValue)"
        case .search: return "search"
        case .settings: return "settings"
        }
    }

    /// 顶栏上亮起的那一格。搜索与设置不在分段里。
    var topTab: MinimalTopTab? {
        switch self {
        case .home: return .home
        case .librarySection(let section): return MinimalTopTab.tab(for: section)
        case .search, .settings: return nil
        }
    }
}

enum MinimalNavigationPolicy {
    /// 极简模式要不要摆「首页」那一格。
    static let showsHomeKey = "primuse.minimal.showsHome.v1"

    /// 「音乐」下面的分类：资料库里排好的顺序与显隐，电台、有声书、播客各在自己的格里。
    static func musicSections(visibleSections: [LibrarySection]) -> [LibrarySection] {
        visibleSections.filter { MinimalTopTab.tab(for: $0) == .music }
    }

    /// 「有声」那一格里的页：有声书要资料库里开着且真有有声内容（`visibleSections` 已经按内容筛过）；
    /// 播客在资料库里打开了或者已经订了节目就有。
    static func spokenSections(
        visibleSections: [LibrarySection],
        hasPodcastShows: Bool
    ) -> [LibrarySection] {
        var sections: [LibrarySection] = []
        if visibleSections.contains(.spokenWord) { sections.append(.spokenWord) }
        if visibleSections.contains(.podcasts) || hasPodcastShows { sections.append(.podcasts) }
        return sections
    }

    static func topTabs(
        showsHome: Bool,
        visibleSections: [LibrarySection],
        spokenSections: [LibrarySection]
    ) -> [MinimalTopTab] {
        var tabs: [MinimalTopTab] = []
        if showsHome { tabs.append(.home) }
        tabs.append(.music)
        if visibleSections.contains(.radio) { tabs.append(.radio) }
        if !spokenSections.isEmpty { tabs.append(.spoken) }
        return tabs
    }

    /// 点某一格落在哪一页：上次在这一格停过的页还在就回那一页，否则排在最前的一页。
    /// 音乐的分类全藏起来时仍落在歌曲页。
    static func section(
        for tab: MinimalTopTab,
        remembered: LibrarySection?,
        musicSections: [LibrarySection],
        spokenSections: [LibrarySection]
    ) -> LibrarySection? {
        switch tab {
        case .home:
            return nil
        case .radio:
            return .radio
        case .music:
            if let remembered, musicSections.contains(remembered) { return remembered }
            return musicSections.first ?? .songs
        case .spoken:
            if let remembered, spokenSections.contains(remembered) { return remembered }
            return spokenSections.first
        }
    }

    /// 标签槽位 + 资料库停在哪一页 → 顶栏上的哪一页。资料库槽位还没有落定的分类时按 `fallbackSection`。
    static func selectedPage(
        selectedTab: Int,
        activeLibrarySection: LibrarySection?,
        fallbackSection: LibrarySection
    ) -> MinimalNavigationPage {
        switch selectedTab {
        case 0: return .home
        case 1: return .librarySection(activeLibrarySection ?? fallbackSection)
        case 2: return .search
        case 3: return .settings
        default: return .home
        }
    }

    static func section(for deepLink: LibraryDeepLink) -> LibrarySection? {
        switch deepLink {
        case .root: return nil
        case .section(let section): return section
        case .album: return .albums
        case .artist: return .artists
        case .playlist: return .playlists
        case .song: return .songs
        }
    }
}

enum MinimalNavigationDetailScope: Hashable, Sendable {
    case home
    case library
    case search
    case settings

    init?(selectedTab: Int) {
        switch selectedTab {
        case 0: self = .home
        case 1: self = .library
        case 2: self = .search
        case 3: self = .settings
        default: return nil
        }
    }
}

enum MinimalNavigationChromePolicy {
    static func hidesTopNavigation(
        mode: AppNavigationMode,
        selectedTab: Int,
        detailScopes: Set<MinimalNavigationDetailScope>,
        returningScopes: Set<MinimalNavigationDetailScope> = []
    ) -> Bool {
        guard mode == .minimal,
              let selectedScope = MinimalNavigationDetailScope(selectedTab: selectedTab) else {
            return false
        }
        return detailScopes.contains(selectedScope)
            && !returningScopes.contains(selectedScope)
    }
}

private struct AppNavigationModeEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppNavigationMode.standard
}

/// 叠加式 mini player 是否正在占住底部。只有这种情况下列表才需要自己让位；
/// 系统 accessory / safeAreaInset 面板 / safeAreaBar 都已经计入安全区。
private struct LegacyBottomChromeOverlayActiveEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MinimalNavigationDetailScopeEnvironmentKey: EnvironmentKey {
    static let defaultValue: MinimalNavigationDetailScope? = nil
}

private struct MinimalNavigationBars {
    let top: AnyView
    let bottom: AnyView
}

private struct MinimalNavigationBarsEnvironmentKey: EnvironmentKey {
    static var defaultValue: MinimalNavigationBars? { nil }
}

private struct MinimalNavigationDetailTransitionHandlerEnvironmentKey: EnvironmentKey {
    static let defaultValue:
        (@MainActor (
            UUID,
            MinimalNavigationDetailScope,
            MinimalNavigationDetailTransitionEvent
        ) -> Void)? = nil
}

private struct MinimalNavigationRootSettledHandlerEnvironmentKey: EnvironmentKey {
    static let defaultValue: (@MainActor (MinimalNavigationDetailScope) -> Void)? = nil
}

private struct MinimalNavigationDetailScopesPreferenceKey: PreferenceKey {
    static let defaultValue: Set<MinimalNavigationDetailScope> = []

    static func reduce(
        value: inout Set<MinimalNavigationDetailScope>,
        nextValue: () -> Set<MinimalNavigationDetailScope>
    ) {
        value.formUnion(nextValue())
    }
}

extension EnvironmentValues {
    fileprivate var minimalNavigationBars: MinimalNavigationBars? {
        get { self[MinimalNavigationBarsEnvironmentKey.self] }
        set { self[MinimalNavigationBarsEnvironmentKey.self] = newValue }
    }

    var appNavigationMode: AppNavigationMode {
        get { self[AppNavigationModeEnvironmentKey.self] }
        set { self[AppNavigationModeEnvironmentKey.self] = newValue }
    }

    var legacyBottomChromeOverlayActive: Bool {
        get { self[LegacyBottomChromeOverlayActiveEnvironmentKey.self] }
        set { self[LegacyBottomChromeOverlayActiveEnvironmentKey.self] = newValue }
    }

    var minimalNavigationDetailScope: MinimalNavigationDetailScope? {
        get { self[MinimalNavigationDetailScopeEnvironmentKey.self] }
        set { self[MinimalNavigationDetailScopeEnvironmentKey.self] = newValue }
    }

    var minimalNavigationDetailTransitionHandler:
        (@MainActor (
            UUID,
            MinimalNavigationDetailScope,
            MinimalNavigationDetailTransitionEvent
        ) -> Void)? {
        get { self[MinimalNavigationDetailTransitionHandlerEnvironmentKey.self] }
        set { self[MinimalNavigationDetailTransitionHandlerEnvironmentKey.self] = newValue }
    }

    fileprivate var minimalNavigationRootSettledHandler:
        (@MainActor (MinimalNavigationDetailScope) -> Void)? {
        get { self[MinimalNavigationRootSettledHandlerEnvironmentKey.self] }
        set { self[MinimalNavigationRootSettledHandlerEnvironmentKey.self] = newValue }
    }
}
#endif

// MARK: - 详情页 zoom 展开

/// 列表卡片与详情页之间的转场标识。专辑 / 艺术家 / 歌单共用一层导航栈的
/// 命名空间,靠 kind 区分,免得不同类型撞上同一个 ID 时互相匹配。
struct MediaZoomTransitionID: Hashable {
    enum Kind: String {
        case album
        case artist
        case playlist
    }

    let kind: Kind
    let id: String
}

/// 用可选值:绝大多数视图不在这套转场里,取不到命名空间时两个修饰符都原样
/// 返回内容,页面照常 push,只是没有放大动画。
private struct MediaZoomNamespaceEnvironmentKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var mediaZoomNamespace: Namespace.ID? {
        get { self[MediaZoomNamespaceEnvironmentKey.self] }
        set { self[MediaZoomNamespaceEnvironmentKey.self] = newValue }
    }
}

private struct MediaZoomSourceModifier: ViewModifier {
    let transitionID: MediaZoomTransitionID
    @Environment(\.mediaZoomNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace, !reduceMotion {
            // 不自定义裁剪形状:卡片是"封面 + 标题"的组合,拿一个矩形去裁本来
            // 就对不上,而圆形头像想要的超大圆角会让 continuous 圆角路径退化,
            // 整张卡片被裁成空白。交给系统按视图自身形状取转场源。
            content.matchedTransitionSource(id: transitionID, in: namespace)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct MediaZoomDestinationModifier: ViewModifier {
    let transitionID: MediaZoomTransitionID
    @Environment(\.mediaZoomNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace, !reduceMotion {
            content.navigationTransition(.zoom(sourceID: transitionID, in: namespace))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /// 挂在 NavigationStack 上,给这一层导航建立共享命名空间。
    func mediaZoomNamespace(_ namespace: Namespace.ID) -> some View {
        environment(\.mediaZoomNamespace, namespace)
    }

    /// 挂在列表卡片上:详情页从这张卡片放大出来,返回时缩回原位。
    func mediaZoomSource(_ kind: MediaZoomTransitionID.Kind, id: String) -> some View {
        modifier(
            MediaZoomSourceModifier(
                transitionID: MediaZoomTransitionID(kind: kind, id: id)
            )
        )
    }

    /// 挂在 navigationDestination 给出的详情页根视图上。
    func mediaZoomDestination(_ kind: MediaZoomTransitionID.Kind, id: String) -> some View {
        modifier(
            MediaZoomDestinationModifier(
                transitionID: MediaZoomTransitionID(kind: kind, id: id)
            )
        )
    }
}

#if os(iOS)
extension View {
    @ViewBuilder
    fileprivate func softNavigationScrollEdges() -> some View {
        if #available(iOS 27.0, *) {
            // iOS 27 changes the automatic edge appearance; retain the soft
            // transition without changing earlier systems' contextual styles.
            scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            self
        }
    }

    /// 极简模式的根页：头上是顶栏，底下是停靠条，系统导航栏藏起来。
    /// `showsTopChrome` 为 false 的根页（设置）保留系统导航栏，只在底下挂停靠条。
    func minimalNavigationRoot(showsTopChrome: Bool = true) -> some View {
        modifier(MinimalNavigationRootModifier(showsTopChrome: showsTopChrome))
    }

    func minimalNavigationDetail(isDetail: Bool = true) -> some View {
        modifier(MinimalNavigationDetailModifier(isDetail: isDetail))
    }
}

private struct MinimalNavigationRootModifier: ViewModifier {
    let showsTopChrome: Bool
    @Environment(\.appNavigationMode) private var appNavigationMode
    @Environment(\.minimalNavigationBars) private var bars
    @Environment(\.minimalNavigationDetailScope) private var detailScope
    @Environment(\.minimalNavigationRootSettledHandler) private var rootSettledHandler

    @ViewBuilder
    func body(content: Content) -> some View {
        if appNavigationMode == .minimal, showsTopChrome {
            content
                // 页头挂在页面里面，读这个值决定出不出来。
                .environment(\.minimalRootPage, true)
                // 根页上的歌曲列表用大封面（#69）；专辑、艺人这些详情页仍是小封面。
                .environment(\.songRowStyle, .minimal)
                // Empty states have an intrinsic height; bars need the full page bounds.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if let detailScope, let rootSettledHandler {
                        // 根页回到栈顶就说明这个页签上已经没有详情页，顶栏以此为准回来。
                        MinimalNavigationRootSettledReporter {
                            rootSettledHandler(detailScope)
                        }
                        .frame(width: 0, height: 0)
                    }
                }
                .toolbar(.hidden, for: .navigationBar)
                .minimalSafeAreaBar(edge: .top) { bars?.top }
                .minimalSafeAreaBar(edge: .bottom) { bars?.bottom }
        } else if appNavigationMode == .minimal {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .minimalSafeAreaBar(edge: .bottom) { bars?.bottom }
        } else {
            content
        }
    }
}

private struct MinimalNavigationDetailModifier: ViewModifier {
    let isDetail: Bool
    @Environment(\.appNavigationMode) private var appNavigationMode
    @Environment(\.minimalNavigationDetailScope) private var detailScope
    @Environment(\.minimalNavigationDetailTransitionHandler) private var transitionHandler
    @Environment(\.minimalNavigationBars) private var bars
    @State private var transitionID = UUID()

    @ViewBuilder
    func body(content: Content) -> some View {
        if isDetail, appNavigationMode == .minimal, let detailScope {
            content
                // 根页推出来的分类页（首页「全部」进来的播客、书架）当详情页用，不摆根页的页头。
                .environment(\.minimalRootPage, false)
                .environment(\.songRowStyle, .standard)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .preference(
                    key: MinimalNavigationDetailScopesPreferenceKey.self,
                    value: Set([detailScope])
                )
                .background {
                    MinimalNavigationDetailTransitionReporter { event in
                        transitionHandler?(transitionID, detailScope, event)
                    }
                    .frame(width: 0, height: 0)
                }
                .toolbar(.visible, for: .navigationBar)
                .navigationBarBackButtonHidden(false)
                .minimalSafeAreaBar(edge: .bottom) { bars?.bottom }
        } else {
            content
        }
    }
}

/// 根页显示完成、而且就在导航栈顶时汇报一次。返回转场被取消时根页只有 will、没有 did，
/// 不会误报；被详情页、页签切换盖住的根页也收不到 did。
private struct MinimalNavigationRootSettledReporter: UIViewControllerRepresentable {
    let onSettled: @MainActor () -> Void

    func makeUIViewController(context: Context) -> ReporterViewController {
        ReporterViewController(onSettled: onSettled)
    }

    func updateUIViewController(
        _ uiViewController: ReporterViewController,
        context: Context
    ) {
        uiViewController.onSettled = onSettled
    }

    @MainActor
    final class ReporterViewController: UIViewController {
        var onSettled: @MainActor () -> Void

        init(onSettled: @escaping @MainActor () -> Void) {
            self.onSettled = onSettled
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard isTopOfNavigationStack else { return }
            onSettled()
        }

        private var isTopOfNavigationStack: Bool {
            var ancestor = parent
            while let viewController = ancestor {
                if let navigationController = viewController.navigationController,
                   navigationController.viewControllers.contains(where: { $0 === viewController }) {
                    return navigationController.topViewController === viewController
                }
                ancestor = viewController.parent
            }
            return false
        }
    }
}

private struct MinimalNavigationDetailTransitionReporter: UIViewControllerRepresentable {
    let onTransition: @MainActor (MinimalNavigationDetailTransitionEvent) -> Void

    func makeUIViewController(context: Context) -> ReporterViewController {
        ReporterViewController(onTransition: onTransition)
    }

    func updateUIViewController(
        _ uiViewController: ReporterViewController,
        context: Context
    ) {
        uiViewController.onTransition = onTransition
    }

    static func dismantleUIViewController(
        _ uiViewController: ReporterViewController,
        coordinator: ()
    ) {
        uiViewController.retire()
    }

    @MainActor
    final class ReporterViewController: UIViewController {
        var onTransition: @MainActor (MinimalNavigationDetailTransitionEvent) -> Void
        private var reportsVisible = false
        private var popGeneration: UInt64 = 0
        private var isRetired = false

        init(
            onTransition: @escaping @MainActor (MinimalNavigationDetailTransitionEvent) -> Void
        ) {
            self.onTransition = onTransition
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            let view = UIView(frame: .zero)
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            self.view = view
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            reportVisible()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            guard !isRetired, let coordinator = navigationPopCoordinator() else { return }

            popGeneration &+= 1
            let generation = popGeneration
            reportsVisible = false
            onTransition(.popping)
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard context.isCancelled else { return }
                self?.restoreAfterCancelledPop(generation: generation)
            }
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            // 被上层详情页、页签切换或全屏封面盖住时这一页还在导航栈里,登记要留着。
            // 已经不在栈里才是真的走了 —— 包括系统没走一次认得出的返回转场的情况。
            guard !isRetired, !isInNavigationStack else { return }
            reportsVisible = false
            onTransition(.removed)
        }

        /// SwiftUI 拆掉这张详情页时的最后一次汇报,此后迟到的转场回调一律不再理会。
        func retire() {
            guard !isRetired else { return }
            isRetired = true
            reportsVisible = false
            let onTransition = onTransition
            // dismantle 发生在 SwiftUI 的视图更新当中,状态改动放到这次更新之后。
            Task { @MainActor in
                onTransition(.removed)
            }
        }

        /// 卡片放大转场的拖拽返回可以中途换一只手势接管(先向右、再向下):先开始的那次
        /// 返回以「已取消」收尾,而页面正被后一次返回带走。只有最近一次返回被取消,才算
        /// 回到了详情页。
        private func restoreAfterCancelledPop(generation: UInt64) {
            guard generation == popGeneration else { return }
            reportVisible()
        }

        private func reportVisible() {
            guard !isRetired, !reportsVisible else { return }
            reportsVisible = true
            onTransition(.appearing)
        }

        private var isInNavigationStack: Bool {
            var ancestor = parent
            while let viewController = ancestor {
                if let navigationController = viewController.navigationController,
                   navigationController.viewControllers.contains(where: { $0 === viewController }) {
                    return true
                }
                ancestor = viewController.parent
            }
            return false
        }

        private func navigationPopCoordinator() -> UIViewControllerTransitionCoordinator? {
            guard let navigationController = enclosingNavigationController,
                  let coordinator = transitionCoordinator
                    ?? navigationController.transitionCoordinator,
                  let fromViewController = coordinator.viewController(forKey: .from),
                  let toViewController = coordinator.viewController(forKey: .to),
                  isPop(
                    from: fromViewController,
                    to: toViewController,
                    in: navigationController
                  ) else {
                return nil
            }
            return coordinator
        }

        private var enclosingNavigationController: UINavigationController? {
            var ancestor = parent
            while let viewController = ancestor {
                if let navigationController = viewController as? UINavigationController {
                    return navigationController
                }
                if let navigationController = viewController.navigationController {
                    return navigationController
                }
                ancestor = viewController.parent
            }
            return nil
        }

        private func isPop(
            from fromViewController: UIViewController,
            to toViewController: UIViewController,
            in navigationController: UINavigationController
        ) -> Bool {
            let stack = navigationController.viewControllers
            let fromIndex = stack.firstIndex { $0 === fromViewController }
            let toIndex = stack.firstIndex { $0 === toViewController }

            if let fromIndex, let toIndex {
                return toIndex < fromIndex
            }
            return fromIndex == nil && toIndex != nil
        }
    }
}

/// iPad sidebar 选中项。Library 之外的顶级项跟 iPhone TabView 一对一
/// (rawValueTab 暴露 0/1/2/3 给 `selectedTab` mirror),Library 还细分到
/// 子列表 (.libraryAlbums / .librarySongs 等) 直接路由 detail,少一层
/// 点击。
private enum SidebarItem: String, Hashable, Identifiable, CaseIterable {
    case home
    case library
    case libraryRecommendations
    case libraryFavorites
    case libraryFolders
    case libraryStatistics
    case librarySongs
    case librarySpokenWord
    case libraryAlbums
    case libraryArtists
    case libraryGenres
    case libraryPlaylists
    case libraryRadio
    case libraryReleaseDate
    case libraryPodcasts
    case search
    case settings

    var id: Self { self }

    /// 映射到 iPhone tab 的索引,保证 phone 与 pad 共享 `selectedTab` state
    /// (sidebar 子项也属于 library 这一档,统一回 1)。
    var rawValueTab: Int {
        switch self {
        case .home: return 0
        case .library, .libraryRecommendations, .librarySongs, .librarySpokenWord, .libraryAlbums,
                .libraryArtists, .libraryGenres, .libraryPlaylists, .libraryRadio,
                .libraryFavorites, .libraryFolders, .libraryStatistics, .libraryReleaseDate, .libraryPodcasts:
            return 1
        case .search: return 2
        case .settings: return 3
        }
    }

    /// 顶级 4 项 + Library 下展开的 4 个子项,在 sidebar 里按分段渲染。
    static var topLevel: [SidebarItem] { [.home, .library, .search, .settings] }
    static func libraryChild(for section: LibrarySection) -> SidebarItem {
        switch section {
        case .recommendations: return .libraryRecommendations
        case .favorites: return .libraryFavorites
        case .folders: return .libraryFolders
        case .statistics: return .libraryStatistics
        case .songs: return .librarySongs
        case .spokenWord: return .librarySpokenWord
        case .albums: return .libraryAlbums
        case .artists: return .libraryArtists
        case .genres: return .libraryGenres
        case .playlists: return .libraryPlaylists
        case .radio: return .libraryRadio
        case .releaseDate: return .libraryReleaseDate
        case .podcasts: return .libraryPodcasts
        }
    }

    var titleKey: String.LocalizationValue {
        switch self {
        case .home: return "home_title"
        case .library: return "library_title"
        case .libraryRecommendations: return "library_recommendations_title"
        case .libraryFavorites: return "library_quick_access"
        case .libraryFolders: return "library_browse_folder"
        case .libraryStatistics: return "stats_title"
        case .librarySongs: return "tab_songs"
        case .librarySpokenWord: return "tab_spoken_word"
        case .libraryAlbums: return "tab_albums"
        case .libraryArtists: return "tab_artists"
        case .libraryGenres: return "tab_genres"
        case .libraryPlaylists: return "tab_playlists"
        case .libraryRadio: return "radio_title"
        case .libraryReleaseDate: return "library_release_date_title"
        case .libraryPodcasts: return "listening_space_podcast"
        case .search: return "search_title"
        case .settings: return "settings_title"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "books.vertical"
        case .libraryRecommendations: return "sparkles"
        case .libraryFavorites: return "heart.fill"
        case .libraryFolders: return "folder.fill"
        case .libraryStatistics: return "chart.bar.fill"
        case .librarySongs: return "music.note"
        case .librarySpokenWord: return "books.vertical.fill"
        case .libraryAlbums: return "square.stack.fill"
        case .libraryArtists: return "music.mic"
        case .libraryGenres: return "tag.fill"
        case .libraryPlaylists: return "music.note.list"
        case .libraryRadio: return "radio.fill"
        case .libraryReleaseDate: return "calendar"
        case .libraryPodcasts: return ListeningSpace.podcast.systemImage
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

/// Stage 2 的启动占位。资料库发布之前渲染它, 所以这里一行库内容都不能读:
/// 只有 App 背景 + 进度指示 + 一句本地化文案。
private struct LibraryPreparingView: View {
    /// 资料库多数时候一两百毫秒就装好。一出来就转圈的话，每次冷启动都会闪一下
    /// 「准备资料库」；先只铺底色，真慢的时候再把进度亮出来。
    @State private var showsProgress = false

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            if showsProgress {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("library_preparing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .pmFadeTransition(motion: .contentAppear)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            showsProgress = true
        }
    }
}

struct ContentView: View {
    @State private var homeModel = HomeView.Model()
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(AppleMusicService.self) private var appleMusic
    @Environment(MetadataBackfillService.self) private var backfill
    #if DEBUG
    @Environment(RadioStationsStore.self) private var debugRadioStore
    #endif

    /// Mini player 是否应该显示 — Primuse 自家在播 或 Apple Music 在系统侧播。
    /// 这两路是独立 player, 任一非空都显示 accessory。
    private var miniPlayerActive: Bool {
        player.currentSong != nil || appleMusic.nowPlayingSong != nil
    }
    /// Batch selection temporarily owns the bottom safe area. Playback keeps
    /// running, but its accessory stays hidden until selection ends.
    private var miniPlayerVisible: Bool {
        miniPlayerActive && !batchSelectionActive && !carPlayEditorActive
    }
    /// iPad (regular) 走 NavigationSplitView; iPhone 与 iPad 分屏小窗 (compact)
    /// 走 TabView。iPad 上按 horizontalSizeClass 适配 Stage Manager / 分屏;
    /// iPhone 为什么不切侧边栏见 `AppNavigationLayoutPolicy`。
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// 手机横屏是紧凑高度。用它把「regular 宽度 = iPad」的旧判断分开:大屏机型横屏
    /// 也是 regular 宽,但纵向只剩三百多点,不该套 iPad 那一套版面。
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppNavigationMode.storageKey)
    private var navigationModeRawValue = AppNavigationMode.standard.rawValue
    @AppStorage("primuse.navigation.selectedTab.v1") private var selectedTab = 0
    /// iPad sidebar 当前选中项。iPhone 不用,sidebar 隐藏。值跟 selectedTab
    /// 保持联动 (sidebar 改 → selectedTab 也改; selectedTab 改 → sidebar
    /// 跟到对应顶级项, 但子项不自动猜测)。
    @AppStorage("primuse.navigation.sidebarItem.v1")
    private var sidebarSelection: SidebarItem = .home
    /// iPad sidebar 的资料库子面板自成一层导航栈,zoom 转场的命名空间也要
    /// 跟着这一层走。
    @Namespace private var librarySubpaneZoomNamespace
    @State private var searchText = ""
    @State private var searchNavigation = LibrarySearchNavigation()
    @State private var searchScope: LibrarySearchScope?
    @State private var searchContext: LibrarySearchScope?
    /// 用户刚点了搜索入口, 搜索页据此直接弹出键盘。
    @State private var searchFieldActivationRequested = false
    /// 极简导航没有系统导航栏, 「调整搜索结果」的入口在自绘顶栏里, 由搜索页负责弹出。
    @State private var searchLayoutEditorRequested = false
    @State private var settingsSearch = SettingsSearchState()
    @State private var showNowPlaying = false
    @State private var nowPlayingPresentationID = UUID()
    @State private var batchSelectionActive = false
    @State private var carPlayEditorActive = false
    @State private var pendingPlaybackRemovalIDs: Set<String> = []
    @State private var isReconcilingPlaybackRemovals = false
    @State private var libraryDeepLink: LibraryDeepLink?
    @State private var minimalLibrarySection: LibrarySection?
    @State private var minimalDetailLedger =
        MinimalNavigationDetailLedger<MinimalNavigationDetailScope>()
    /// 资料库槽位停在哪个分类。下次启动回到这一页（#69：重开 App 停在上次的页面）。
    @AppStorage("primuse.minimal.librarySection.v1") private var minimalStoredSectionRaw = ""
    /// 「音乐」「有声」两格各自上次停的分类，点回这一格时落在那里。
    @AppStorage("primuse.minimal.musicSection.v1") private var minimalMusicSectionRaw = ""
    @AppStorage("primuse.minimal.spokenSection.v1") private var minimalSpokenSectionRaw = ""
    @AppStorage(MinimalNavigationPolicy.showsHomeKey) private var minimalShowsHome = true
    /// 进搜索、设置之前停的那一页；「取消」与设置的返回键回到这里。
    @State private var minimalReturnPage: MinimalNavigationPage?
    @State private var showsMinimalQueue = false
    @State private var scraperSettingsRoute = ScraperSettingsRouteState()
    /// 跨年自动弹年度报告的状态。1/1 之后用户首次进 app + 上一年听满 2 个月
    /// 时由 YearlyReportAutoTrigger 触发。
    @State private var autoYearlyReport: YearlyReportYear?
    /// 首启 onboarding —— @AppStorage 持久, 关掉后永久 true。
    @AppStorage("primuse.hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @AppStorage(LibraryDisplayConfiguration.sectionOrderKey)
    private var librarySectionOrderRawValue = ""
    @AppStorage(LibraryDisplayConfiguration.hiddenSectionsKey)
    private var hiddenLibrarySectionsRawValue = ""
    @State private var showInitialOnboarding = false
    private let legacyTabBarClearance: CGFloat = 49

    /// 与 mainContent 里 LegacyNowPlayingAccessory 的挂载条件同源。
    private var legacyBottomChromeOverlayActive: Bool {
        var systemAccessoryAvailable = false
        if #available(iOS 26.1, *) {
            systemAccessoryAvailable = true
        }
        return BottomChromeClearancePolicy.usesLegacyOverlayAccessory(
            rootLayoutIsStandardTabs: rootLayout == .standardTabs,
            miniPlayerVisible: miniPlayerVisible,
            systemAccessoryAvailable: systemAccessoryAvailable
        )
    }

    private var navigationMode: AppNavigationMode {
        AppNavigationMode.resolve(navigationModeRawValue)
    }

    private var rootLayout: AppNavigationRootLayout {
        AppNavigationLayoutPolicy.rootLayout(
            mode: navigationMode,
            usesRegularWidth: sizeClass == .regular,
            allowsSidebar: UIDevice.current.userInterfaceIdiom == .pad
        )
    }

    private var systemTabBarVisibility: Visibility {
        AppNavigationChromePolicy.hidesSystemTabBar(
            mode: navigationMode,
            batchSelectionActive: batchSelectionActive
        ) ? .hidden : .automatic
    }

    private var visibleLibrarySections: [LibrarySection] {
        LibraryDisplayConfiguration.visibleSections(
            orderRawValue: librarySectionOrderRawValue,
            hiddenRawValue: hiddenLibrarySectionsRawValue
        )
        // 没有有声内容时不摆这个入口。
        .filter { $0 != .spokenWord || !library.spokenWordSongs.isEmpty }
    }

    private var minimalMusicSections: [LibrarySection] {
        MinimalNavigationPolicy.musicSections(visibleSections: visibleLibrarySections)
    }

    private var minimalSpokenSections: [LibrarySection] {
        MinimalNavigationPolicy.spokenSections(
            visibleSections: visibleLibrarySections,
            hasPodcastShows: !PodcastStore.shared.shows.isEmpty
        )
    }

    private var minimalTopTabs: [MinimalTopTab] {
        MinimalNavigationPolicy.topTabs(
            showsHome: minimalShowsHome,
            visibleSections: visibleLibrarySections,
            spokenSections: minimalSpokenSections
        )
    }

    /// 资料库槽位还没落定分类时（刚启动、刚换到极简）去的那一页。
    private var minimalFallbackSection: LibrarySection {
        MinimalNavigationPolicy.section(
            for: .music,
            remembered: LibrarySection(rawValue: minimalMusicSectionRaw),
            musicSections: minimalMusicSections,
            spokenSections: minimalSpokenSections
        ) ?? .songs
    }

    private var currentMinimalPage: MinimalNavigationPage {
        MinimalNavigationPolicy.selectedPage(
            selectedTab: AppTabSelectionPolicy.resolve(selectedTab),
            activeLibrarySection: minimalLibrarySection,
            fallbackSection: minimalFallbackSection
        )
    }

    private var minimalTopNavigationHidden: Bool {
        MinimalNavigationChromePolicy.hidesTopNavigation(
            mode: navigationMode,
            selectedTab: selectedTab,
            detailScopes: minimalDetailLedger.detailScopes,
            returningScopes: minimalDetailLedger.returning
        )
    }

    private var librarySidebarItems: [SidebarItem] {
        visibleLibrarySections.map(SidebarItem.libraryChild(for:))
    }

    private var searchTabRole: TabRole {
        #if compiler(>=6.4)
        // iOS 27 no longer separates a search tab unless it activates search.
        // Keep the independent button without changing search activation.
        if #available(iOS 27.0, *) { return .prominent }
        #endif
        return .search
    }

    @ViewBuilder
    private var tabRoot: some View {
        TabView(selection: searchAwareTabSelection) {
            Tab(String(localized: "home_title"), systemImage: "house.fill", value: 0) {
                HomeView(
                    switchToSettingsTab: { selectedTab = 3 },
                    model: homeModel,
                    openLibrarySongs: { openLibraryDeepLink(.section(.songs)) }
                )
                    .id("primuse.tab.home")
                    .environment(\.minimalNavigationDetailScope, .home)
                    .environment(\.librarySearchTab, 0)
                    .toolbar(systemTabBarVisibility, for: .tabBar)
            }

            Tab(String(localized: "library_title"), systemImage: "books.vertical", value: 1) {
                LibraryView(
                    deepLink: $libraryDeepLink,
                    onActiveSectionChange: { section in
                        guard navigationMode == .minimal else { return }
                        minimalLibrarySection = section
                        if let section { rememberMinimalSection(section) }
                    }
                )
                .environment(\.minimalNavigationDetailScope, .library)
                .environment(\.librarySearchTab, 1)
                .toolbar(systemTabBarVisibility, for: .tabBar)
            }

            Tab(String(localized: "search_title"), systemImage: "magnifyingglass",
                value: 2, role: searchTabRole) {
                SearchView(searchText: $searchText, scope: $searchScope,
                           activatesSearchField: $searchFieldActivationRequested,
                           requestsResultLayoutEditor: $searchLayoutEditorRequested,
                           contextualScope: searchContext, onShowInLibrary: showSongInLibrary)
                    .id("primuse.tab.search")
                    .environment(\.minimalNavigationDetailScope, .search)
                    .toolbar(systemTabBarVisibility, for: .tabBar)
            }

            Tab(String(localized: "settings_title"), systemImage: "gearshape", value: 3) {
                SettingsView(scraperSettingsRoute: $scraperSettingsRoute, search: settingsSearch)
                    .environment(\.minimalNavigationDetailScope, .settings)
                    .environment(\.minimalSettingsReturn, minimalSettingsReturn)
                    .toolbar(systemTabBarVisibility, for: .tabBar)
            }
        }
        .softNavigationScrollEdges()
        .environment(\.minimalNavigationDetailTransitionHandler) {
            transitionID, detailScope, event in
            updateMinimalNavigationDetailTransition(
                id: transitionID,
                scope: detailScope,
                event: event
            )
        }
        .environment(\.minimalNavigationRootSettledHandler) { scope in
            settleMinimalNavigationRoot(scope: scope)
        }
    }

    @ViewBuilder
    private var minimalRoot: some View {
        tabRoot
            .environment(
                \.minimalNavigationBars,
                MinimalNavigationBars(
                    top: AnyView(minimalTopChrome),
                    bottom: AnyView(minimalBottomChrome)
                )
            )
            .environment(\.minimalSpokenSections, minimalSpokenSections)
            .environment(\.minimalSelectSection) { section in
                selectMinimalPage(.librarySection(section))
            }
            .onPreferenceChange(MinimalNavigationDetailScopesPreferenceKey.self) { scopes in
                minimalDetailLedger.updateMounted(scopes)
            }
            .sheet(isPresented: $showsMinimalQueue) {
                QueueView(player: player)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
    }

    @ViewBuilder
    private var minimalBottomChrome: some View {
        if miniPlayerVisible {
            Group {
                // regular 宽度单独判不出 iPad:大屏机型横屏也是 regular 宽,套上
                // iPad 那块圆角板会在 440pt 高的视口里显得又厚又空。
                if sizeClass == .regular && !heightClass.isCompact {
                    PadNowPlayingAccessory(onTap: presentNowPlaying)
                } else {
                    MinimalNowPlayingAccessory(
                        onTap: presentNowPlaying,
                        onShowQueue: { showsMinimalQueue = true }
                    )
                }
            }
            // miniPlayerVisible 是派生量, 翻转由播放状态决定, 调用点包不住动画
            // 事务, 曲线只能附在过渡本身上。
            .pmSlideTransition(edge: .bottom, motion: .panel)
        }
    }

    private var minimalTopChrome: some View {
        let page = currentMinimalPage
        return MinimalNavigationChromeLayout(
            visibility: minimalTopNavigationHidden ? 0 : 1
        ) {
            Group {
                if page == .search {
                    MinimalSearchBar(
                        text: $searchText,
                        scope: $searchScope,
                        context: searchContext,
                        activationRequested: $searchFieldActivationRequested,
                        onSubmit: { SearchHistoryStore.record(searchText) },
                        onEditLayout: { searchLayoutEditorRequested = true },
                        onCancel: cancelMinimalSearch
                    )
                } else {
                    MinimalTopTabBar(
                        tabs: minimalTopTabs,
                        selectedTab: page.topTab,
                        musicSections: minimalMusicSections,
                        selectedSection: {
                            if case .librarySection(let section) = page { return section }
                            return nil
                        }(),
                        onSelectTab: selectMinimalTopTab,
                        onSelectSection: { section in
                            animateMinimalSelection { selectMinimalPage(.librarySection(section)) }
                        },
                        onSearch: { selectMinimalPage(.search) },
                        onSettings: { selectMinimalPage(.settings) }
                    )
                }
            }
            .opacity(
                minimalTopNavigationHidden
                    ? 0
                    : (batchSelectionActive ? 0.42 : 1)
            )
            .scaleEffect(
                x: 1,
                y: minimalTopNavigationHidden ? 0.985 : 1,
                anchor: .top
            )
        }
        .clipped()
        .allowsHitTesting(!minimalTopNavigationHidden && !batchSelectionActive)
        .accessibilityHidden(minimalTopNavigationHidden || batchSelectionActive)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.26, extraBounce: 0),
            value: minimalTopNavigationHidden
        )
    }

    /// 设置页左上角回到进设置之前那一页。
    private var minimalSettingsReturn: MinimalReturnAction? {
        guard navigationMode == .minimal else { return nil }
        let target = minimalReturnPage ?? .librarySection(minimalFallbackSection)
        let title = target.topTab?.title ?? MinimalTopTab.music.title
        return MinimalReturnAction(title: title) {
            selectMinimalPage(target)
        }
    }

    @ViewBuilder
    private var playerAwareTabRoot: some View {
        // Keep the modifier identity stable while search is active. Toggling
        // between two different TabView structures at the instant a search
        // result starts playback makes UIKit tear down UISearchController and
        // install the accessory in the same update; on iOS 26 that can abort
        // in `_willDismissSearchController` with an unowned-reference crash.
        if #available(iOS 26.1, *) {
            tabRoot
                // A minimized tab bar keeps only the selected tab and Search.
                // Without a player accessory that leaves a large empty gap at
                // the bottom and looks like the other tabs disappeared. Only
                // minimize when Now Playing can occupy that compact space.
                .tabBarMinimizeBehavior(miniPlayerVisible ? .onScrollDown : .never)
                .tabViewBottomAccessory(isEnabled: miniPlayerVisible) {
                    NowPlayingAccessory(onTap: presentNowPlaying)
                }
        } else if #available(iOS 26.0, *) {
            // 26.0 has no `isEnabled:` overload and an empty system accessory
            // still reserves transparent space. Keep the TabView identity
            // stable for Search, disable minimization, and render the player
            // as the outer legacy overlay below instead.
            tabRoot
                .tabBarMinimizeBehavior(.never)
        } else {
            tabRoot
        }
    }

    private var padRoot: some View {
        NavigationSplitView {
            let selection = Binding<SidebarItem?>(
                get: { sidebarSelection },
                set: { if let v = $0 {
                    // 从侧栏点「搜索」进来就直接弹出键盘。
                    if v == .search, sidebarSelection != .search {
                        searchFieldActivationRequested = true
                    }
                    selectTab(v.rawValueTab)
                    sidebarSelection = v
                } }
            )
            List(selection: selection) {
                // 顶层 4 项 ── Home / 资料库 / 搜索 / 设置。资料库下面再开 section
                // 列子项,让 iPad 用户少一层点击直达。
                Section {
                    ForEach(SidebarItem.topLevel) { item in
                        Label(String(localized: item.titleKey), systemImage: item.icon)
                            .tag(item as SidebarItem?)
                    }
                }
                Section(String(localized: "library_title")) {
                    ForEach(librarySidebarItems) { item in
                        Label(String(localized: item.titleKey), systemImage: item.icon)
                            .tag(item as SidebarItem?)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Primuse")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            padDetail(for: sidebarSelection)
                .environment(\.librarySearchTab, sidebarSelection.rawValueTab)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if miniPlayerVisible {
                        PadNowPlayingAccessory(onTap: presentNowPlaying)
                            .pmSlideTransition(edge: .bottom, motion: .panel)
                    }
                }
        }
        .softNavigationScrollEdges()
    }

    /// 把 sidebar 选项映射到具体 detail 视图。Library 的子项 (Songs / Albums
    /// / Artists / Playlists) 直接呈现对应的子 list, 并自带一个 NavigationStack
    /// + 必要的 navigationDestination,让 NavigationLink 还能正常 push 详情页。
    @ViewBuilder
    private func padDetail(for item: SidebarItem) -> some View {
        switch item {
        case .home:
            HomeView(
                switchToSettingsTab: {
                    sidebarSelection = .settings
                    selectedTab = 3
                },
                model: homeModel,
                openLibrarySongs: { openLibraryDeepLink(.section(.songs)) }
            )
        case .library:
            LibraryView(deepLink: $libraryDeepLink)
        case .libraryRecommendations:
            librarySubpane(title: "library_recommendations_title") {
                AIRecommendationLibraryView()
            }
        case .libraryFavorites:
            LibraryView(rootSection: .favorites)
        case .libraryFolders:
            librarySubpane(title: "library_browse_folder") { HomeFolderManagementView() }
        case .libraryStatistics:
            librarySubpane(title: "stats_title") { ListeningStatsScreen() }
        case .librarySongs:
            librarySubpane(title: "tab_songs") { SongListView() }
        case .librarySpokenWord:
            librarySubpane(title: "tab_spoken_word") { SpokenWordLibraryView() }
        case .libraryAlbums:
            librarySubpane(title: "tab_albums") { AlbumGridView() }
        case .libraryArtists:
            librarySubpane(title: "tab_artists") { ArtistListView() }
        case .libraryGenres:
            librarySubpane(title: "tab_genres") { GenreLibraryView() }
        case .libraryPlaylists:
            librarySubpane(title: "tab_playlists") { PlaylistListView() }
        case .libraryRadio:
            librarySubpane(title: "radio_title") { RadioStationsView() }
        case .libraryReleaseDate:
            librarySubpane(title: "library_release_date_title") { ReleaseDateLibraryView() }
        case .libraryPodcasts:
            librarySubpane(title: "listening_space_podcast") { PodcastLibraryView() }
        case .search:
            SearchView(searchText: $searchText, scope: $searchScope,
                           activatesSearchField: $searchFieldActivationRequested,
                           contextualScope: searchContext, onShowInLibrary: showSongInLibrary)
        case .settings:
            SettingsView(scraperSettingsRoute: $scraperSettingsRoute)
        }
    }

    @ViewBuilder
    private func librarySubpane<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .navigationDestination(for: Album.self) {
                    AlbumDetailView(album: $0)
                        .mediaZoomDestination(.album, id: $0.id)
                }
                .navigationDestination(for: Artist.self) {
                    ArtistDetailView(artist: $0)
                        .mediaZoomDestination(.artist, id: $0.id)
                }
                .navigationDestination(for: Playlist.self) {
                    PlaylistDetailView(playlist: $0)
                        .mediaZoomDestination(.playlist, id: $0.id)
                }
                // SmartPlaylist destination 由 PlaylistListView 自己挂,不在
                // 这层重复设置,免得 SwiftUI 报"重复 destination"警告。
        }
        .mediaZoomNamespace(librarySubpaneZoomNamespace)
    }

    var body: some View {
        // Stage 2: 资料库在主线程之外装载。就绪之前不渲染任何读库的界面 ——
        // 既不能闪 onboarding (它由 SourcesStore 驱动, 但入口在下面这棵树的
        // `.task` 里), 也不能闪"空资料库"状态。
        Group {
            if LaunchDiagnostics.isSafeModeActive {
                // 连续两次启动没跑完。这一支完全不碰首页、迷你播放条与入场
                // 动画，落地页只有回执和发送入口，先保证他打得开。
                LaunchSafeModeView()
            } else if library.isReady {
                mainContent
                    .environment(\.openLibraryDestination, { link in openLibraryDeepLink(link) })
                    .onAppear { LaunchDiagnostics.mark(.homeFirstFrame) }
            } else {
                LibraryPreparingView()
                    .onAppear { LaunchDiagnostics.mark(.preparingLibrary) }
            }
        }
        // 上次启动没跑完时的回执。挂在这一层而不是 `mainContent` 里：占位页要
        // 显示十秒, 弹在那上面比等首页出来再弹稳妥得多 —— 首页正是出事的地方。
        .launchAbortReport()
        // 首页模型放进环境：设置里的界面编辑器要就地渲染真实首页，编辑的必须是
        // 同一份状态，另起一个实例会看到不一样的快照。
        .environment(homeModel)
        // Spotlight 点击 ── identifier 形如 "song:<id>" / "album:<id>" 等。
        // song 直接播; album / artist / playlist 推进资料库对应详情页。
        //
        // Stage 2b: 系统会把启动时的 Spotlight / Handoff 活动随场景连接选项
        // 一起投递, 那一刻挂在树上的只有占位界面。处理器因此必须挂在外层 ——
        // 挂在 `mainContent` 上这次点击会被整个丢掉。库还没发布时先交给
        // `onReady` 存着, 发布之后重放(已就绪时立即执行, 与历史版本一致)。
        .onContinueUserActivity("com.apple.corespotlight.searchableitem") { activity in
            guard let item = SpotlightIndexService.identifier(from: activity) else { return }
            library.onReady { handleSpotlightItem(item) }
        }
        // Handoff ── 从另一台设备过来时拿到完整播放上下文 (当前歌 / 队列 /
        // 播放位置 / 播放或暂停 / shuffle / repeat),无缝接着播下去。
        .onContinueUserActivity("com.welape.yuanyin.nowplaying") { activity in
            library.onReady { handleHandoffActivity(activity) }
        }
        // 主屏幕快捷菜单的「搜索」。请求先记在快捷菜单那边,这里接手:冷启动时同样
        // 只有外层挂着,切页和弹键盘的状态留到搜索页出来再用。
        .onChange(of: HomeScreenQuickActionCenter.shared.pendingSearch, initial: true) { _, pending in
            guard pending else { return }
            HomeScreenQuickActionCenter.shared.consumeSearchRequest()
            searchFieldActivationRequested = true
            selectMinimalPage(.search)
        }
    }

    private var mainContent: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch rootLayout {
                case .standardSidebar:
                    padRoot
                case .standardTabs:
                    playerAwareTabRoot
                case .minimal:
                    minimalRoot
                }
            }
            // 这两个开关只由页面里的批量选择与 CarPlay 编辑器上报。挂在整个 ZStack
            // 上时，按需挂载的播放页也落在请求范围里：第一次展开播放页，SwiftUI 要
            // 顺着整棵播放页视图树建这两个 Preference 的汇总，采样里这就是展开那一卡。
            .onPreferenceChange(CarPlayEditorActivePreferenceKey.self) { carPlayEditorActive = $0 }
            .onPreferenceChange(SongBatchSelectionActivePreferenceKey.self) { isActive in
                batchSelectionActive = isActive
            }

            if miniPlayerVisible && rootLayout == .standardTabs {
                if #available(iOS 26.1, *) {
                    EmptyView()
                } else {
                    LegacyNowPlayingAccessory(onTap: presentNowPlaying)
                        .padding(.bottom, legacyTabBarClearance)
                        .pmSlideTransition(edge: .bottom, motion: .panel)
                        .zIndex(1)
                }
            }

            // Player overlay — mounted on demand. NowPlayingView holds heavy
            // observers (player, library, lyrics) and a 0.3s timer; keeping it
            // mounted while the user is on the song list means scrolling pays
            // for those observations every time anything in the player state
            // changes. The slide-in animation is driven by PlayerOverlay's
            // own internal `entered` state on first appear.
            if showNowPlaying {
                PlayerOverlay(
                    isPresented: $showNowPlaying,
                    onOpenAlbum: { album in
                        showNowPlaying = false
                        openLibraryDeepLink(.album(album))
                    },
                    onOpenArtist: { artist in
                        showNowPlaying = false
                        openLibraryDeepLink(.artist(artist))
                    }
                )
                    .id(nowPlayingPresentationID)
                    .zIndex(2)
            }
        }
        // iPhone Duo 合上、展开时整屏做一次归位（模糊、沿开合方向拉伸后回到原样），播放页也在里面。
        .pmScreenChangeTransition()
        .environment(\.librarySearchNavigation, searchNavigation)
        .environment(\.appNavigationMode, navigationMode)
        .environment(\.legacyBottomChromeOverlayActive, legacyBottomChromeOverlayActive)
        .songBatchRemovalFeedback()
        .serverCatalogRefreshFeedback()
        .smartNudges()
        .appleMusicSubscriptionOffer()
        // Visibility and search revisions are presentation signals, not proof
        // that a song was durably removed. Only the library's authoritative
        // removal event is allowed to mutate active playback.
        .background {
            AuthoritativeSongRemovalObserver { songIDs in
                enqueuePlaybackReconciliation(removing: songIDs)
            }
        }
        // 跨年自动弹年度报告 ── 每次 ContentView 进入 (app 启动 / 切前台后
        // 重新出现) 都跑一次, trigger 内部用 UserDefaults 记录已弹避免重复。
        // 触发条件: 当前月份 == 1 + 上一年没弹过 + 上一年听满 ≥ 2 个不同月份。
        .task {
            if AppNavigationMode(rawValue: navigationModeRawValue) == nil {
                navigationModeRawValue = AppNavigationMode.standard.rawValue
            }
            let restoredTab = AppTabSelectionPolicy.resolve(selectedTab)
            if restoredTab != selectedTab {
                selectedTab = restoredTab
                sidebarSelection = .home
            }
            activateMinimalLandingPageIfNeeded()
            // 展示前就写入“一次性”标记。这样即使用户在导览期间直接杀掉
            // App，下次启动也不会再次自动弹出；设置页仍可手动重看。
            if !hasSeenOnboarding && sourcesStore.sources.isEmpty {
                hasSeenOnboarding = true
                showInitialOnboarding = true
            } else if let year = YearlyReportAutoTrigger.yearToShow() {
                autoYearlyReport = YearlyReportYear(year: year)
            } else {
                // 上次切出去时进程被系统结束、没填完的音乐源表单: 回到
                // 「设置 › 音乐源」接着填。和引导页、年度报告不同时弹。
                AddSourceDraftRestoration.shared.restoreIfNeeded()
            }
        }
        .onChange(of: navigationModeRawValue) { _, _ in
            if navigationMode == .minimal {
                activateMinimalLandingPageIfNeeded()
            } else {
                synchronizeSidebarForCurrentSelection()
            }
        }
        .onChange(of: visibleLibrarySections) { _, _ in
            // 资料库设置里把正停着的分类藏了，或者有声内容都移走了：回到音乐。
            guard navigationMode == .minimal, selectedTab == 1 else { return }
            if let section = minimalLibrarySection, minimalSectionIsAvailable(section) { return }
            selectMinimalPage(.librarySection(minimalFallbackSection))
        }
        .onChange(of: minimalShowsHome) { _, showsHome in
            guard navigationMode == .minimal, !showsHome, selectedTab == 0 else { return }
            selectMinimalPage(.librarySection(minimalFallbackSection))
        }
        .fullScreenCover(item: $autoYearlyReport) { item in
            YearlyReportScreen(year: item.year)
        }
        // 首启 onboarding —— 仅当未看过且库里没源 (避免 CloudKit 同步迟到时
        // 让老用户重看一次)
        .fullScreenCover(isPresented: $showInitialOnboarding) {
            OnboardingView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseRequestShowNowPlaying)) { _ in
            presentNowPlaying()
        }
        #if DEBUG
        .task { await runDebugOpenPage() }
        .task { await runDebugRotation() }
        .task { await runDebugMinimalSteps() }
        #endif
        .alert(
            String(localized: "server_favorite_update_failed_title"),
            isPresented: Binding(
                get: { library.serverFavoriteErrorMessage != nil },
                set: { if !$0 { library.dismissServerFavoriteError() } }
            )
        ) {
            Button("done", role: .cancel) {}
        } message: {
            Text(library.serverFavoriteErrorMessage ?? "")
        }
        .alert(
            String(localized: "server_rating_sync_failed_title"),
            isPresented: Binding(
                get: { library.serverRatingErrorMessage != nil },
                set: { if !$0 { library.dismissServerRatingError() } }
            )
        ) {
            Button("done", role: .cancel) {}
        } message: {
            Text(library.serverRatingErrorMessage ?? "")
        }
        // 蜂窝网络下「仅 WiFi」拦住了回填/缓存且确有待办 → 提示用户是否在 5G/4G 继续
        .alert(
            String(localized: "cellular_backfill_title"),
            isPresented: Binding(
                get: {
                    backfill.pausedForCellular
                        && AppAlertCoordinator.shared.activeRequest == .cellularBackfill
                },
                set: { if !$0 { backfill.dismissCellularPrompt() } }
            )
        ) {
            Button(String(localized: "cellular_backfill_allow_once")) {
                backfill.allowCellular(persist: false)
            }
            Button(String(localized: "cellular_backfill_allow_always")) {
                backfill.allowCellular(persist: true)
            }
            Button(String(localized: "cellular_backfill_wifi_only"), role: .cancel) {
                backfill.dismissCellularPrompt()
            }
        } message: {
            Text("cellular_backfill_message")
        }
        .onChange(of: SettingsNavigation.shared.request, initial: true) { _, request in
            guard let request, SettingsNavigation.shared.activatedToken != request.token else { return }
            SettingsNavigation.shared.activatedToken = request.token
            selectMinimalPage(.settings)
        }
        .environment(\.openScraperSettings, OpenScraperSettingsAction {
            openScraperSettings()
        })
    }

    private func openScraperSettings() {
        showNowPlaying = false
        selectMinimalPage(.settings)
        scraperSettingsRoute.requestMetadataScraping()
    }

    /// 进极简模式、启动时落在哪一页：资料库槽位回到上次停的分类；首页那一格关掉了就去音乐。
    private func activateMinimalLandingPageIfNeeded() {
        guard navigationMode == .minimal else { return }
        let tab = AppTabSelectionPolicy.resolve(selectedTab)
        if tab == 0, minimalShowsHome {
            synchronizeSidebarForCurrentSelection()
            return
        }
        if tab == 1, let section = minimalLibrarySection, minimalSectionIsAvailable(section) {
            synchronizeSidebarForCurrentSelection()
            return
        }
        if tab == 2 || tab == 3 {
            synchronizeSidebarForCurrentSelection()
            return
        }
        let stored = LibrarySection(rawValue: minimalStoredSectionRaw)
        if tab == 1, let stored, minimalSectionIsAvailable(stored) {
            selectMinimalPage(.librarySection(stored))
        } else {
            selectMinimalPage(.librarySection(minimalFallbackSection))
        }
    }

    /// 这个分类在顶栏上还够得着：音乐的分类要在资料库里开着，电台、有声要它们那一格还在。
    private func minimalSectionIsAvailable(_ section: LibrarySection) -> Bool {
        switch MinimalTopTab.tab(for: section) {
        case .music: minimalMusicSections.contains(section) || section == minimalFallbackSection
        case .radio: minimalTopTabs.contains(.radio)
        case .spoken: minimalSpokenSections.contains(section)
        case .home: false
        }
    }

    private func rememberMinimalSection(_ section: LibrarySection) {
        if minimalStoredSectionRaw != section.rawValue {
            minimalStoredSectionRaw = section.rawValue
        }
        switch MinimalTopTab.tab(for: section) {
        case .music where minimalMusicSectionRaw != section.rawValue:
            minimalMusicSectionRaw = section.rawValue
        case .spoken where minimalSpokenSectionRaw != section.rawValue:
            minimalSpokenSectionRaw = section.rawValue
        default:
            break
        }
    }

    private func selectMinimalTopTab(_ tab: MinimalTopTab) {
        let page: MinimalNavigationPage
        if tab == .home {
            page = .home
        } else {
            let remembered: LibrarySection? = switch tab {
            case .music: LibrarySection(rawValue: minimalMusicSectionRaw)
            case .spoken: LibrarySection(rawValue: minimalSpokenSectionRaw)
            default: nil
            }
            guard let section = MinimalNavigationPolicy.section(
                for: tab,
                remembered: remembered,
                musicSections: minimalMusicSections,
                spokenSections: minimalSpokenSections
            ) else { return }
            page = .librarySection(section)
        }
        animateMinimalSelection { selectMinimalPage(page) }
    }

    private func animateMinimalSelection(_ change: () -> Void) {
        if reduceMotion {
            change()
        } else {
            withAnimation(.easeOut(duration: 0.18), change)
        }
    }

    /// 搜索页的「取消」：清掉搜索词，回到进来之前那一页。
    private func cancelMinimalSearch() {
        searchText = ""
        searchScope = nil
        selectMinimalPage(minimalReturnPage ?? .librarySection(minimalFallbackSection))
    }

    private var searchAwareTabSelection: Binding<Int> {
        // TabView validates its first selection before the restoration task runs.
        Binding(
            get: { AppTabSelectionPolicy.resolve(selectedTab) },
            set: { tab in
                // 点底部「搜索」进来就直接弹出键盘, 不必再点一次搜索框。
                // 只认真的切换: 启动时恢复到搜索页不该自己弹键盘。
                if AppTabSelectionPolicy.resolve(tab) == 2, selectedTab != 2 {
                    searchFieldActivationRequested = true
                }
                selectTab(tab)
            }
        )
    }

    private func selectTab(_ tab: Int) {
        let tab = AppTabSelectionPolicy.resolve(tab)
        if tab == 2, selectedTab != 2 {
            // Capture before switching tabs triggers the detail's onDisappear.
            let context = searchNavigation.scope(for: selectedTab)
            searchContext = context
            searchScope = context
        }
        selectedTab = tab
    }

    private func selectMinimalPage(_ page: MinimalNavigationPage) {
        showNowPlaying = false
        if navigationMode == .minimal {
            let current = currentMinimalPage
            switch page {
            case .search, .settings:
                // 从搜索进设置时，返回仍回到搜索之前那一页。
                if current != .search, current != .settings {
                    minimalReturnPage = current
                }
                if page == .search, current != .search {
                    searchFieldActivationRequested = true
                }
            case .home, .librarySection:
                minimalReturnPage = nil
            }
        }
        switch page {
        case .home:
            selectedTab = 0
            sidebarSelection = .home
        case .librarySection(let section):
            selectedTab = 1
            sidebarSelection = SidebarItem.libraryChild(for: section)
            // 已经停在这一页时不再发深链：深链会把这一页的导航栈重排一遍。
            if minimalLibrarySection != section || libraryDeepLink != nil {
                minimalLibrarySection = section
                libraryDeepLink = .section(section)
            }
            if navigationMode == .minimal { rememberMinimalSection(section) }
        case .search:
            selectTab(2)
            sidebarSelection = .search
        case .settings:
            selectedTab = 3
            sidebarSelection = .settings
        }
    }

    private func synchronizeSidebarForCurrentSelection() {
        switch selectedTab {
        case 0:
            sidebarSelection = .home
        case 1:
            if navigationMode == .minimal, let minimalLibrarySection {
                sidebarSelection = SidebarItem.libraryChild(for: minimalLibrarySection)
            } else {
                sidebarSelection = .library
            }
        case 2:
            sidebarSelection = .search
        case 3:
            sidebarSelection = .settings
        default:
            sidebarSelection = .home
        }
    }

    /// Always advance the presentation identity before opening. A system UI
    /// interruption can suspend SwiftUI while the previous overlay is fading
    /// out, leaving its binding true even though the view is transparent. A
    /// fresh identity remounts the overlay instead of turning `true` into a
    /// no-op, so the mini player remains a reliable recovery entry point.
    private func presentNowPlaying() {
        nowPlayingPresentationID = UUID()
        showNowPlaying = true
    }

    /// Serialize authoritative removal bursts so an awaited replacement start
    /// cannot race a second library deletion. Partial scans and visibility
    /// rebuilds never enter this path.
    @MainActor
    private func enqueuePlaybackReconciliation(removing songIDs: Set<String>) {
        let action = PlaybackLibraryMutationPolicy.action(
            queueSongIDs: player.queue.map(\.id),
            currentSongID: player.currentSong?.id,
            isLiveRadio: player.isLiveRadio,
            event: .songsRemoved(songIDs)
        )
        guard case let .removeSongs(relevantSongIDs) = action else { return }

        pendingPlaybackRemovalIDs.formUnion(relevantSongIDs)
        guard !isReconcilingPlaybackRemovals else { return }
        isReconcilingPlaybackRemovals = true

        Task { @MainActor in
            defer { isReconcilingPlaybackRemovals = false }
            while !pendingPlaybackRemovalIDs.isEmpty {
                let pendingIDs = pendingPlaybackRemovalIDs
                pendingPlaybackRemovalIDs.removeAll(keepingCapacity: true)

                let refreshedAction = PlaybackLibraryMutationPolicy.action(
                    queueSongIDs: player.queue.map(\.id),
                    currentSongID: player.currentSong?.id,
                    isLiveRadio: player.isLiveRadio,
                    event: .songsRemoved(pendingIDs)
                )
                guard case let .removeSongs(stillRelevantIDs) = refreshedAction else {
                    continue
                }
                await player.prepareQueueForRemovingSongs(withIDs: stillRelevantIDs)
            }

            if player.currentSong == nil {
                showNowPlaying = false
            }
        }
    }

    /// Handoff 受方 ── 把 publisher 那边记录的 (当前歌, 队列, 播放位置, 状态)
    /// 还原到本机播放器上。受方库里找不到的歌跳过, 当前歌也找不到时静默忽略
    /// (跨设备库未同步的常见情况, 不弹 error 干扰用户)。
    private func handleHandoffActivity(_ activity: NSUserActivity) {
        guard let info = activity.userInfo,
              let songID = info["songID"] as? String else { return }

        // 还原队列。queueIDs 没传时退化成"只播当前歌";有时按顺序解析 ──
        // 受方 library 现在可能比 publisher 少 (CloudKit 同步未到位 / 不同 source
        // 启用状态),compactMap 后丢失的歌不影响其它歌正常播。
        let queueIDs = (info["queueIDs"] as? [String]) ?? [songID]
        let resolvedQueue = queueIDs.compactMap { library.visibleSong(id: $0) }
        guard !resolvedQueue.isEmpty,
              let songIndex = resolvedQueue.firstIndex(where: { $0.id == songID }) else {
            // 当前歌在受方库里不存在 → 退回纯 song-id 路径,让 spotlight 同
            // 一套逻辑兜底 (会把整库当队列起播); 至少不会"啥都没发生"。
            handleSpotlightItem(.song(id: songID))
            return
        }

        let song = resolvedQueue[songIndex]
        if let shuffle = info["shuffleEnabled"] as? Bool { player.shuffleEnabled = shuffle }
        if let rmRaw = info["repeatMode"] as? String,
           let rm = RepeatMode(rawValue: rmRaw) {
            player.repeatMode = rm
        }

        let snapshotTime = (info["snapshotTime"] as? Double)
            ?? Date().timeIntervalSinceReferenceDate
        let baseTime = (info["currentTime"] as? Double) ?? 0
        let wasPlaying = (info["isPlaying"] as? Bool) ?? true
        // 仅当 publisher 当时是播放状态才把"经过时间"加上;暂停态就保留
        // 原 currentTime,用户继续听不会跳过任何内容。
        let elapsed = wasPlaying
            ? max(0, Date().timeIntervalSinceReferenceDate - snapshotTime)
            : 0
        let resumeTime = baseTime + elapsed

        Task {
            if wasPlaying {
                await player.play(
                    queue: resolvedQueue,
                    startingAt: songIndex,
                    caller: "Handoff"
                )
                // play(song:) starts at zero; seek to the publisher's live
                // position only for an explicitly playing Handoff.
                player.seek(to: resumeTime, startPlaying: true)
            } else {
                player.stop()
                player.setQueue(resolvedQueue, startAt: songIndex)
                if let shuffle = info["shuffleEnabled"] as? Bool {
                    player.shuffleEnabled = shuffle
                }
                if let rmRaw = info["repeatMode"] as? String,
                   let rm = RepeatMode(rawValue: rmRaw) {
                    player.repeatMode = rm
                }
                player.stagePausedHandoff(song: song, at: resumeTime)
            }
        }
    }

    /// Spotlight 命中 -> 路由。`song` 直接进 queue 开播; album / artist /
    /// playlist 进入资料库并推到对应详情页。
    private func handleSpotlightItem(_ item: SpotlightItem) {
        switch item {
        case .song(let id):
            guard library.visibleSong(id: id) != nil else { return }
            // 命中歌 + 整库剩下的拼起来当队列,跟 Siri / Shortcuts 同款行为;
            // 只交 ID, 整库在主线程之外按窗口取。
            var ids = [id]
            ids.reserveCapacity(library.visibleSongs.count)
            for song in library.visibleSongs where song.id != id { ids.append(song.id) }
            Task {
                await player.play(queueIDs: ids, startingAt: 0, caller: "Spotlight")
            }
        case .album(let id):
            guard let album = library.visibleAlbums.first(where: { $0.id == id }) else { return }
            openLibraryDeepLink(.album(album))
        case .artist(let id):
            guard let artist = library.visibleArtists.first(where: { $0.id == id }) else { return }
            openLibraryDeepLink(.artist(artist))
        case .playlist(let id):
            guard let playlist = library.playlists.first(where: { $0.id == id }) else { return }
            openLibraryDeepLink(.playlist(playlist))
        }
    }

    private func openLibraryDeepLink(_ link: LibraryDeepLink) {
        selectedTab = 1
        if navigationMode == .minimal,
           let section = MinimalNavigationPolicy.section(for: link) {
            minimalLibrarySection = section
            sidebarSelection = SidebarItem.libraryChild(for: section)
        } else {
            sidebarSelection = .library
        }
        libraryDeepLink = link
    }

    private func showSongInLibrary(_ song: PrimuseKit.Song) {
        openLibraryDeepLink(.song(song.id))
    }

    private func updateMinimalNavigationDetailTransition(
        id: UUID,
        scope: MinimalNavigationDetailScope,
        event: MinimalNavigationDetailTransitionEvent
    ) {
        var ledger = minimalDetailLedger
        ledger.record(event, id: id, scope: scope)
        // 一张详情页离开时 removed 会到两次(离开导航栈、被拆掉),没变化就不写回,
        // 免得根视图白白重算一遍。
        guard ledger != minimalDetailLedger else { return }
        minimalDetailLedger = ledger
    }

    private func settleMinimalNavigationRoot(scope: MinimalNavigationDetailScope) {
        var ledger = minimalDetailLedger
        let wasHidden = ledger.hidesTopNavigation(for: scope)
        ledger.recordRootSettled(scope)
        guard ledger != minimalDetailLedger else { return }
        if wasHidden {
            // 正常的返回在这之前就已经把顶栏放出来了；走到这里说明有一路销账没到。
            plog("Minimal chrome: root settled with stale detail registration, scope=\(scope)")
        }
        minimalDetailLedger = ledger
    }
}

/// Keeps the top chrome mounted while its occupied height animates. Removing
/// the view outright makes a completed navigation pop push the root page down
/// in a separate layout pass.
private struct MinimalNavigationChromeLayout: Layout {
    var visibility: CGFloat

    var animatableData: CGFloat {
        get { visibility }
        set { visibility = newValue }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let fullSize = subview.sizeThatFits(proposal)
        return CGSize(
            width: proposal.width ?? fullSize.width,
            height: fullSize.height * clampedVisibility
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let contentProposal = ProposedViewSize(width: bounds.width, height: nil)
        let fullSize = subview.sizeThatFits(contentProposal)
        let travel = min(14, fullSize.height * 0.16)
        subview.place(
            at: CGPoint(
                x: bounds.minX,
                y: bounds.minY - travel * (1 - clampedVisibility)
            ),
            anchor: .topLeading,
            proposal: contentProposal
        )
    }

    private var clampedVisibility: CGFloat {
        min(max(visibility, 0), 1)
    }
}

/// Bridges the library's durable removal contract into playback without
/// observing transient visible-library snapshots.
private struct AuthoritativeSongRemovalObserver: View {
    let onSongsRemoved: @MainActor (Set<String>) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .primuseSongsRemoved)) { note in
                let removedSongIDs = (note.userInfo?["songIDs"] as? Set<String>) ?? {
                    let removedSongs = (note.userInfo?["songs"] as? [PrimuseKit.Song]) ?? []
                    return Set(removedSongs.map(\.id))
                }()
                guard !removedSongIDs.isEmpty else { return }
                onSongsRemoved(removedSongIDs)
            }
    }
}

// MARK: - Player Overlay

struct PlayerOverlay: View {
    private enum PresentationPhase: Equatable {
        case staging
        case visible
        case dismissingDown
        case dismissingLeading
    }

    private enum InteractiveAxis {
        case horizontal
        case vertical
    }

    @Binding var isPresented: Bool
    let onOpenAlbum: (PrimuseKit.Album) -> Void
    let onOpenArtist: (PrimuseKit.Artist) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase
    @State private var presentationPhase = PresentationPhase.staging
    @State private var presentationHasSettled = false
    /// 拖动隐藏时每帧都在变。放在引用模型里、只由偏移修饰符读取, 拖动就只刷新
    /// 偏移, 不会每帧重建整个 NowPlayingView (它的 body 很重)。
    @State private var interactiveDrag = PlayerOverlayInteractiveDrag()
    @State private var dismissalState = PlayerOverlayDismissalState()
    @State private var dismissalTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.height, geometry.size.width) + 1
            NowPlayingView(
                onOpenAlbum: onOpenAlbum,
                onOpenArtist: onOpenArtist,
                onMinimize: { beginDismissal(.dismissingDown) },
                onTopMinimizeDragChanged: { translation in
                    updateInteractiveOffset(
                        axis: .vertical,
                        value: max(0, translation)
                    )
                },
                onTopMinimizeDragEnded: { shouldDismiss in
                    finishInteractiveDrag(
                        shouldDismiss: shouldDismiss,
                        phase: .dismissingDown
                    )
                },
                onLeadingMinimizeDragChanged: { translationTowardCenter in
                    let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
                    updateInteractiveOffset(
                        axis: .horizontal,
                        value: max(0, translationTowardCenter) * direction
                    )
                },
                onLeadingMinimizeDragEnded: { shouldDismiss in
                    finishInteractiveDrag(
                        shouldDismiss: shouldDismiss,
                        phase: .dismissingLeading
                    )
                },
                isPresentationSettled: presentationHasSettled,
                isPresentationActive: presentationPhase == .visible
                    && !dismissalState.isDismissing
            )
                .frame(width: geometry.size.width, height: geometry.size.height)
                // Keep eagerly decoded artwork and its shadow inside the same
                // off-screen presentation surface as the rest of the player.
                .clipped()
                // Move the live player as one presentation layer. Without this,
                // image-backed descendants can commit at their final position
                // while the background is still entering from the bottom.
                .compositingGroup()
                // 合成组只管绘制，入场位移仍会逐个传到子视图：进度时间、播放键这类挂着
                // 自己动画的零件，在第一首歌刚起播、秒数正变的那次展开里会换用自己的弹簧抢先到位。
                // 几何组让位移只作用在整页上，子视图的动画只管它们自己的变化。
                .geometryGroup()
                .modifier(PlayerOverlayOffsetModifier(
                    drag: interactiveDrag,
                    phaseOffset: phaseOffset(travel: travel)
                ))
        }
        .ignoresSafeArea()
        .allowsHitTesting(presentationPhase == .visible && !dismissalState.isDismissing)
        .task {
            guard presentationPhase == .staging else { return }
            // Commit the lightweight player tree off-screen first. Artwork
            // may reuse a decoded thumbnail here, while large decode, dynamic
            // artwork, and lyrics work remain suspended until completion.
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if reduceMotion {
                presentationPhase = .visible
                completeEntranceIfPossible()
            } else {
                withAnimation(
                    .spring(response: 0.45, dampingFraction: 0.92),
                    completionCriteria: .removed
                ) {
                    presentationPhase = .visible
                } completion: {
                    completeEntranceIfPossible()
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                completeEntranceIfPossible()
                return
            }
            guard newPhase != .active,
                  dismissalState.isDismissing || interactiveDrag.offset != .zero else { return }
            // Control Center / screen recording can interrupt an in-flight
            // transition. Invalidate its delayed completion and restore the
            // mounted player so an old callback cannot leave an invisible
            // hit-test surface over the mini player when the scene returns.
            dismissalTask?.cancel()
            dismissalTask = nil
            if dismissalState.isDismissing {
                dismissalState.cancelForSystemInterruption()
            }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                interactiveDrag.offset = .zero
                presentationPhase = .visible
            }
        }
        .onDisappear {
            dismissalTask?.cancel()
            dismissalTask = nil
        }
        #if DEBUG
        // `PRIMUSE_DEBUG_PLAYER_CYCLE`:和点左上角收起键走同一条路。
        .onReceive(NotificationCenter.default.publisher(for: .primuseDebugMinimizeNowPlaying)) { _ in
            beginDismissal(.dismissingDown)
        }
        #endif
    }

    /// nil = 停在可见位置, 由拖动偏移决定。
    private func phaseOffset(travel: CGFloat) -> CGSize? {
        switch presentationPhase {
        case .staging:
            return CGSize(width: 0, height: travel)
        case .visible:
            return nil
        case .dismissingDown:
            return CGSize(width: 0, height: travel)
        case .dismissingLeading:
            let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
            return CGSize(width: travel * direction, height: 0)
        }
    }

    private func completeEntranceIfPossible() {
        guard PlayerOverlayDeferredContentPolicy.allowsLoading(
            isPresented: isPresented,
            isSceneActive: scenePhase == .active,
            isVisible: presentationPhase == .visible,
            isDismissing: dismissalState.isDismissing
        ) else { return }
        presentationHasSettled = true
    }

    private func updateInteractiveOffset(axis: InteractiveAxis, value: CGFloat) {
        guard presentationPhase == .visible, !dismissalState.isDismissing else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch axis {
            case .horizontal:
                interactiveDrag.offset = CGSize(width: value, height: 0)
            case .vertical:
                interactiveDrag.offset = CGSize(width: 0, height: value)
            }
        }
    }

    private func finishInteractiveDrag(
        shouldDismiss: Bool,
        phase: PresentationPhase
    ) {
        if shouldDismiss {
            beginDismissal(phase)
        } else {
            guard presentationPhase == .visible, !dismissalState.isDismissing else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                interactiveDrag.offset = .zero
            }
        }
    }

    private func beginDismissal(_ phase: PresentationPhase) {
        guard isPresented,
              presentationPhase == .visible,
              !dismissalState.isDismissing else { return }

        let generation = dismissalState.begin()
        dismissalTask?.cancel()
        if reduceMotion {
            completeDismissal(generation: generation)
            return
        }

        withAnimation(.spring(response: 0.38, dampingFraction: 0.94)) {
            presentationPhase = phase
        }
        dismissalTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(460))
            } catch {
                return
            }
            completeDismissal(generation: generation)
        }
    }

    private func completeDismissal(generation: UInt64) {
        guard dismissalState.complete(generation: generation) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isPresented = false
        }
    }
}

@MainActor
@Observable
private final class PlayerOverlayInteractiveDrag {
    var offset = CGSize.zero
}

/// 只有这里读拖动偏移, 所以拖动时失效的是这个修饰符而不是整个播放页。
private struct PlayerOverlayOffsetModifier: ViewModifier {
    let drag: PlayerOverlayInteractiveDrag
    let phaseOffset: CGSize?

    func body(content: Content) -> some View {
        content.offset(phaseOffset ?? drag.offset)
    }
}

// MARK: - Now Playing Accessory (adapts to inline/expanded)

struct LegacyNowPlayingAccessory: View {
    var onTap: () -> Void

    var body: some View {
        MiniPlayerView(onTap: onTap)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
    }
}

/// 自绘迷你播放条的底板。iPad 侧栏与极简导航挂不了系统的 tabViewBottomAccessory,
/// iOS 26 起用 Liquid Glass 与系统附件保持一致(降低透明度由系统自己处理);
/// 更早的系统退回磨砂 + 细描边 + 投影,降低透明度时换实色底。
private struct NowPlayingAccessorySurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let legacyMaterial: Material
    let legacyStrokeOpacity: Double
    let legacyShadow: (opacity: Double, radius: CGFloat, y: CGFloat)
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content
                .background {
                    if reduceTransparency {
                        shape.fill(Color(uiColor: .secondarySystemBackground))
                    } else {
                        shape.fill(legacyMaterial)
                    }
                }
                .overlay {
                    shape
                        .strokeBorder(.primary.opacity(legacyStrokeOpacity), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
                .shadow(
                    color: .black.opacity(legacyShadow.opacity),
                    radius: legacyShadow.radius,
                    y: legacyShadow.y
                )
        }
    }
}

private extension View {
    func nowPlayingAccessorySurface<S: InsettableShape>(
        _ shape: S,
        legacyMaterial: Material,
        legacyStrokeOpacity: Double,
        legacyShadow: (opacity: Double, radius: CGFloat, y: CGFloat)
    ) -> some View {
        modifier(NowPlayingAccessorySurface(
            shape: shape,
            legacyMaterial: legacyMaterial,
            legacyStrokeOpacity: legacyStrokeOpacity,
            legacyShadow: legacyShadow
        ))
    }
}

/// 极简模式底部的停靠播放条：封面、标题与进度、一颗辅助键、实心圆的大播放键。
/// 圆角板浮在屏幕底边上方，两侧留出一点边。
struct MinimalNowPlayingAccessory: View {
    var onTap: () -> Void
    var onShowQueue: () -> Void
    @Environment(\.pmHeightClass) private var heightClass
    /// 固定条高跟随 Dynamic Type。
    @ScaledMetric(relativeTo: .body) private var contentHeight: CGFloat = 50

    var body: some View {
        // 手机横屏下条子收窄并靠向尾侧:横贯七百多点的一条厚板会把本来就只剩三百多点
        // 的版面压得更死,让开之后左侧内容在播放条旁边仍然看得见。
        let barWidth = heightClass.value(620, compact: 420)
        let barAlignment = heightClass.pick(Alignment.center, compact: .trailing)
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        return HStack(spacing: 4) {
            MiniPlayerSwipeContent(
                onTap: onTap,
                artworkSize: heightClass.value(48, compact: 40),
                artworkCornerRadius: 10,
                artworkTrailingSpacing: 12,
                titleFont: .callout,
                showsSubtitle: true,
                contentHeight: heightClass.value(contentHeight, compact: 42),
                showsProgress: true
            )
            MinimalDockTransportControls(onShowQueue: onShowQueue)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, heightClass.value(8, compact: 5))
        .frame(maxWidth: barWidth)
        .nowPlayingAccessorySurface(
            shape,
            legacyMaterial: .regularMaterial,
            legacyStrokeOpacity: 0.08,
            legacyShadow: (opacity: 0.16, radius: 14, y: 6)
        )
        .contentShape(shape)
        .frame(maxWidth: .infinity, alignment: barAlignment)
        .padding(.horizontal, 12)
        .padding(.top, heightClass.value(6, compact: 4))
        .padding(.bottom, heightClass.value(8, compact: 4))
    }
}

struct PadNowPlayingAccessory: View {
    var onTap: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var contentHeight: CGFloat = 44

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    trackInformation
                    transportControls.frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 0) {
                    trackInformation
                    transportControls
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: 560)
        .fixedSize(horizontal: false, vertical: true)
        .nowPlayingAccessorySurface(
            RoundedRectangle(cornerRadius: 24, style: .continuous),
            legacyMaterial: .regularMaterial,
            legacyStrokeOpacity: 0.06,
            legacyShadow: (opacity: 0.08, radius: 10, y: 3)
        )
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var trackInformation: some View {
        MiniPlayerSwipeContent(
            onTap: onTap,
            artworkSize: 30,
            artworkCornerRadius: 6,
            artworkTrailingSpacing: 8,
            titleFont: .subheadline,
            contentHeight: contentHeight
        )
    }

    private var transportControls: some View {
        MiniPlayerTransportControls(
            showsNextButton: true,
            regularIconSize: 18
        )
    }
}

@available(iOS 26.0, *)
struct NowPlayingAccessory: View {
    var onTap: () -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }

    var body: some View {
        HStack(spacing: 0) {
            MiniPlayerSwipeContent(
                onTap: onTap,
                artworkSize: isInline ? 32 : 30,
                artworkCornerRadius: 6,
                artworkTrailingSpacing: isInline ? 10 : 8,
                titleFont: isInline ? .caption : .subheadline
            )

            MiniPlayerTransportControls(
                isInline: isInline,
                showsNextButton: !isInline,
                regularIconSize: 18
            )
        }
        .padding(.horizontal, isInline ? 12 : 16)
        .padding(.vertical, isInline ? 2 : 4)
    }
}

#Preview {
    ContentView()
        .environment(AudioPlayerService())
        .environment(MusicLibrary())
}
#endif

#if DEBUG && os(iOS)
/// 调试构建的启动自动化：`PRIMUSE_OPEN_PAGE=<页面>` 在曲库装载后直接打开指定页面，给编译机上无人值守截图用。
/// 取值：`home` / `library` / `songs` / `albums` / `artists` / `playlists` / `album:<标题片段>` / `artist:<名字片段>` /
/// `playlist:<名字片段>`（`liked` 是「喜欢」）/ `player`（配合 `PRIMUSE_AUTOPLAY_SONG`）/ `search`（`search:<词>` 直接搜）/
/// `settings` / `onboarding`。
/// 另有 `PRIMUSE_ORIENTATION=landscape|portrait|landscapeLeft|landscapeRight`：打开页面前先请求转屏
/// （`landscape` 即 `landscapeRight`）。
/// `section:<分类 rawValue>`（如 `section:folders`）。
/// 详情页取证用：`genre:<名字片段>` / `smart:<名字片段>`（智能歌单）。
/// `PRIMUSE_DEBUG_SEED_RADIO=1` 建几个取证用的电台（看电台页版式）；`=organized` 另把它们分进几个文件夹、
/// 打上几个标签（看电台页顶上两排筛选胶囊）。
/// `PRIMUSE_DEBUG_SEED_PLAYS=<专辑名片段>[,…]` 给这些专辑的歌各记四次最近几天的播放(看「开始听」的「为你」与按收听排序),
/// 同一份曲库只记一次。
/// `PRIMUSE_DEBUG_SEED_PLAYLISTS=1` 先建两张取证歌单：整库一张（封面墙）、Evidence 专辑一张（单封面）；
/// 另建两张同样形态的取证智能歌单（Evidence Smart Wall / Evidence Smart Single），用 `smart:<名字片段>` 打开。
/// `PRIMUSE_DEBUG_SEED_INSIGHT=<专辑名片段>` 给这张专辑和它的专辑艺人各写一段简介和风格标签（看头图里的简介摘录），
/// 正文可用 `PRIMUSE_DEBUG_SEED_INSIGHT_TEXT` 换掉。
extension ContentView {
    @MainActor
    private func runDebugOpenPage() async {
        guard let raw = ProcessInfo.processInfo.environment["PRIMUSE_OPEN_PAGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        let page = parts[0].lowercased()
        let needle = parts.count > 1 ? parts[1].lowercased() : ""

        // 等曲库里有歌（最多一分钟），再给界面一点时间把标签页搭好。
        for _ in 0..<30 where library.visibleSongs.isEmpty {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
        }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        debugSeedPlaylistsIfRequested()
        debugSeedRadioIfRequested()
        debugSeedPlaysIfRequested()
        Task { await debugSeedInsightIfRequested() }
        if let orientation = ProcessInfo.processInfo.environment["PRIMUSE_ORIENTATION"]?.lowercased(),
           ["landscape", "portrait", "landscapeleft", "landscaperight"].contains(orientation) {
            InterfaceOrientationLock.debugRequest(named: orientation)
            try? await Task.sleep(for: .seconds(1))
        }
        plog("🧪 DebugLaunchAutomation: open page \(raw)")

        let namedSections: [String: LibrarySection] = [
            "songs": .songs, "albums": .albums, "artists": .artists, "playlists": .playlists,
        ]
        switch page {
        case "home":
            selectMinimalPage(.home)
        case "library":
            openLibraryDeepLink(.root)
        case _ where namedSections[page] != nil:
            openLibraryDeepLink(.section(namedSections[page]!))
        case "section":
            guard let section = LibrarySection(rawValue: parts.count > 1 ? parts[1] : "") else {
                plog("🧪 DebugLaunchAutomation: unknown section '\(needle)'")
                return
            }
            debugOpenSection(section)
        case "album":
            for _ in 0..<30 {
                if let album = library.visibleAlbums.first(where: {
                    needle.isEmpty || $0.title.lowercased().contains(needle)
                }) {
                    openLibraryDeepLink(.album(album))
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
            }
            plog("🧪 DebugLaunchAutomation: no album matching '\(needle)'")
        case "artist":
            for _ in 0..<30 {
                if let artist = library.visibleArtists.first(where: {
                    needle.isEmpty || $0.name.lowercased().contains(needle)
                }) {
                    openLibraryDeepLink(.artist(artist))
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
            }
            plog("🧪 DebugLaunchAutomation: no artist matching '\(needle)'")
        case "playlist":
            let match = needle == "liked"
                ? library.playlists.first(where: { $0.id == MusicLibrary.likedSongsPlaylistID })
                : library.playlists.first(where: { needle.isEmpty || $0.name.lowercased().contains(needle) })
            if let match {
                openLibraryDeepLink(.playlist(match))
            } else {
                plog("🧪 DebugLaunchAutomation: no playlist matching '\(needle)'")
            }
        case "genre":
            for _ in 0..<30 {
                if let genre = library.visibleGenres.first(where: {
                    needle.isEmpty || $0.name.lowercased().contains(needle)
                }) {
                    debugOpenSection(.genres)
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    LibraryDebugNavigation.push(genre, in: .genres)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
            }
            plog("🧪 DebugLaunchAutomation: no genre matching '\(needle)'")
        case "smart":
            for _ in 0..<30 {
                if let smart = library.smartPlaylists.first(where: {
                    needle.isEmpty || $0.name.lowercased().contains(needle)
                }) {
                    debugOpenSection(.playlists)
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    LibraryDebugNavigation.push(smart, in: .playlists)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
            }
            plog("🧪 DebugLaunchAutomation: no smart playlist matching '\(needle)'")
        case "player":
            // 等 `PRIMUSE_AUTOPLAY_SONG` 把歌放起来，没有也照样打开。
            for _ in 0..<20 where player.currentSong == nil {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            presentNowPlaying()
        case "search":
            selectMinimalPage(.search)
            // `search:<搜索词>` 直接搜这个词(看 AI 补充里的专辑组)。
            if parts.count > 1 { searchText = parts[1] }
        case "settings":
            selectMinimalPage(.settings)
        case "onboarding":
            showInitialOnboarding = true
        default:
            plog("🧪 DebugLaunchAutomation: unknown page '\(page)'")
        }
    }

    /// `PRIMUSE_DEBUG_MINIMAL_STEPS=music,section:albums,radio,spoken,music,search,cancel,settings,back,home`：
    /// 极简模式下按顺序走一遍点分段、点分类、搜索与取消、设置与返回用的同一套函数，每步隔
    /// `PRIMUSE_DEBUG_MINIMAL_STEP_SECONDS`（默认 4）秒，日志记下每步落在哪一页，给编译机逐步截图对照。
    @MainActor
    private func runDebugMinimalSteps() async {
        let environment = ProcessInfo.processInfo.environment
        guard navigationMode == .minimal,
              let raw = environment["PRIMUSE_DEBUG_MINIMAL_STEPS"], !raw.isEmpty else { return }
        let interval = environment["PRIMUSE_DEBUG_MINIMAL_STEP_SECONDS"].flatMap(Double.init) ?? 4
        for _ in 0..<30 where library.visibleSongs.isEmpty {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
        }
        for step in raw.split(separator: ",").map(String.init) {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            if let tab = MinimalTopTab(rawValue: step) {
                selectMinimalTopTab(tab)
            } else if step.hasPrefix("section:"),
                      let section = LibrarySection(rawValue: String(step.dropFirst("section:".count))) {
                animateMinimalSelection { selectMinimalPage(.librarySection(section)) }
            } else if step == "search" {
                selectMinimalPage(.search)
            } else if step == "cancel" {
                cancelMinimalSearch()
            } else if step == "settings" {
                selectMinimalPage(.settings)
            } else if step == "back" {
                minimalSettingsReturn?.action()
            } else if step.hasPrefix("album:") {
                let needle = String(step.dropFirst("album:".count))
                if let album = library.albums.first(where: { $0.title.contains(needle) }) {
                    LibraryDebugNavigation.push(album, in: minimalLibrarySection ?? .albums)
                }
            } else if step.hasPrefix("genrelink:") {
                let needle = String(step.dropFirst("genrelink:".count))
                if let genre = library.visibleGenres.first(where: { $0.name.contains(needle) }) {
                    LibraryDebugNavigation.push(genre, in: .genres)
                }
            } else if step == "pop" {
                LibraryDebugNavigation.pop(in: minimalLibrarySection ?? .albums)
            } else if step == "uikitpop" {
                // 跟点左上角返回一样走 UIKit 的返回转场。
                debugVisibleNavigationController()?.popViewController(animated: true)
            } else if step == "probe" {
                debugProbeMinimalChrome()
            }
            try? await Task.sleep(for: .milliseconds(600))
            plog("🧪 DebugLaunchAutomation: minimal step \(step) → \(currentMinimalPage.id)")
        }
    }

    /// 当前窗口里看得见的那一层导航栈。
    @MainActor
    private func debugVisibleNavigationController() -> UINavigationController? {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return nil }
        var found: [UINavigationController] = []
        func collect(_ controller: UIViewController) {
            if let navigation = controller as? UINavigationController,
               navigation.view.window != nil, !navigation.view.isHidden {
                found.append(navigation)
            }
            controller.children.forEach(collect)
        }
        if let root = window.rootViewController { collect(root) }
        return found.last
    }

    /// 顶栏位置上 UIKit 实际把点按交给了谁，连同各层导航栏的状态一起记下来。
    @MainActor
    private func debugProbeMinimalChrome() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return }
        let point = CGPoint(x: window.bounds.width * 0.27, y: window.safeAreaInsets.top + 22)
        var chain: [String] = []
        var view = window.hitTest(point, with: nil)
        while let current = view, chain.count < 10 {
            chain.append(String(describing: type(of: current)))
            view = current.superview
        }
        var navigations: [String] = []
        func collect(_ controller: UIViewController) {
            if let navigation = controller as? UINavigationController, navigation.view.window != nil {
                let bar = navigation.navigationBar
                navigations.append(
                    "stack=\(navigation.viewControllers.count) navHidden=\(navigation.isNavigationBarHidden) "
                        + "barHidden=\(bar.isHidden) alpha=\(bar.alpha) frame=\(bar.frame) "
                        + "interaction=\(bar.isUserInteractionEnabled)"
                )
            }
            controller.children.forEach(collect)
        }
        if let root = window.rootViewController { collect(root) }
        plog(
            "🧪 minimal probe: page=\(currentMinimalPage.id) chromeHidden=\(minimalTopNavigationHidden) "
                + "ledger=\(minimalDetailLedger) point=\(point) hit=\(chain.joined(separator: " < ")) "
                + "navs=\(navigations)"
        )
    }

    /// `PRIMUSE_DEBUG_ROTATE_EVERY=<秒>`：每隔这么久请求一次转屏（竖 ⇄ 横），走系统真实的转屏过渡，
    /// 录屏看换构图的元素过渡在系统过渡里是不是还在。起始方向跟 `PRIMUSE_ORIENTATION`。
    @MainActor
    private func runDebugRotation() async {
        let environment = ProcessInfo.processInfo.environment
        guard let every = environment["PRIMUSE_DEBUG_ROTATE_EVERY"].flatMap(Double.init), every > 0 else { return }
        var landscape = environment["PRIMUSE_ORIENTATION"]?.lowercased() == "landscape"
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(every))
            guard !Task.isCancelled else { return }
            landscape.toggle()
            plog("🧪 DebugLaunchAutomation: rotate to \(landscape ? "landscape" : "portrait")")
            InterfaceOrientationLock.debugRequest(landscape: landscape)
        }
    }

    @MainActor
    private func debugOpenSection(_ section: LibrarySection) {
        openLibraryDeepLink(.section(section))
    }

    /// `PRIMUSE_DEBUG_SEED_PLAYS=<专辑名片段>[,…]`：这些专辑里的歌各记四次最近几天的播放，只记一次。
    @MainActor
    private func debugSeedPlaysIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_SEED_PLAYS"], !raw.isEmpty else { return }
        let marker = "primuse.debug.seededPlays." + raw
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        let needles = raw.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let songs = library.visibleSongs.filter { song in
            let album = (song.albumTitle ?? "").lowercased()
            return needles.contains { !$0.isEmpty && album.contains($0) }
        }
        guard !songs.isEmpty else { return }
        let now = Date()
        for (index, song) in songs.enumerated() {
            for day in 0..<4 {
                PlayHistoryStore.shared.record(
                    song: song,
                    startedAt: now.addingTimeInterval(-Double(day) * 86_400 - Double(index) * 300),
                    listenedSec: 120
                )
            }
        }
        UserDefaults.standard.set(true, forKey: marker)
        plog("🧪 DebugLaunchAutomation: seeded \(songs.count * 4) plays")
    }

    /// `PRIMUSE_DEBUG_SEED_INSIGHT=<专辑名片段>`：已经有简介的不覆盖。刚扫进来的歌要等标签读完
    /// 才有专辑名，所以最多等一分钟。
    @MainActor
    private func debugSeedInsightIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard let needle = environment["PRIMUSE_DEBUG_SEED_INSIGHT"]?.lowercased(), !needle.isEmpty else { return }
        var match: PrimuseKit.Album?
        for _ in 0..<30 {
            match = library.visibleAlbums.first(where: { $0.title.lowercased().contains(needle) })
            if match != nil { break }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
        }
        guard let album = match else {
            plog("🧪 DebugLaunchAutomation: no album matching '\(needle)' to seed an insight")
            return
        }
        let summary = environment["PRIMUSE_DEBUG_SEED_INSIGHT_TEXT"] ?? """
            Recorded over one long winter, this album trades the band's early guitar sound for analog synths and \
            drum machines. The songs move from late-night city drives to quiet bedroom confessions, and the closing \
            track stretches past nine minutes.

            Critics at the time were divided, but it has since become the record most fans start with.
            """
        let artistName = album.artistName ?? ""
        let store = LibraryInsightStore.shared
        let subjects: [LibraryInsightSubject] = [
            .album(title: album.title, artist: artistName, year: album.year, genres: [], tracks: []),
            .artist(name: artistName, genres: [], albums: [], tracks: []),
        ]
        for subject in subjects where store.record(for: subject, in: library) == nil {
            store.saveEdit(subject, summary: summary, tags: ["Synth-pop", "New wave", "1980s"], aiDraft: nil, library: library)
        }
        plog("🧪 DebugLaunchAutomation: seeded insight for '\(album.title)'")
    }

    /// `PRIMUSE_DEBUG_SEED_PLAYLISTS=1`：没有就建两张取证歌单，名字固定，重复启动不会重复建。
    @MainActor
    private func debugSeedPlaylistsIfRequested() {
        guard ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_SEED_PLAYLISTS"] == "1" else { return }
        let names = library.playlists.map(\.name)
        if !names.contains("Evidence Wall") {
            _ = library.createPlaylist(name: "Evidence Wall", songIDs: library.visibleSongs.map(\.id))
        }
        if !names.contains("Evidence Single"),
           let album = library.visibleAlbums.first(where: { $0.title.lowercased().contains("evidence") }) {
            _ = library.createPlaylist(
                name: "Evidence Single",
                songIDs: library.songs(forAlbum: album.id).map(\.id)
            )
        }
        // 智能歌单的两种头图:命中整库(封面墙)与只命中 Evidence 专辑(单封面)。
        let smartNames = library.smartPlaylists.map(\.name)
        if !smartNames.contains("Evidence Smart Wall") {
            library.saveSmartPlaylist(SmartPlaylist(
                name: "Evidence Smart Wall",
                rules: [SmartPlaylistRule(field: .durationSec, op: .greaterThan, value: "0")]
            ))
        }
        if !smartNames.contains("Evidence Smart Single") {
            library.saveSmartPlaylist(SmartPlaylist(
                name: "Evidence Smart Single",
                rules: [SmartPlaylistRule(field: .albumTitle, op: .contains, value: "Evidence")]
            ))
        }
    }

    /// `PRIMUSE_DEBUG_SEED_RADIO=1`：没有电台时建几个取证用的（地址不通，只看版式），名字固定，重复启动不会重复建。
    /// `=organized`：再分进四个文件夹、打上六个标签，电台页顶上的两排筛选胶囊都比屏幕宽。
    private func debugSeedRadioIfRequested() {
        let request = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_SEED_RADIO"]
        guard request == "1" || request == "organized" else { return }
        let existing = Set(debugRadioStore.stations.map(\.name))
        for index in 1...8 where !existing.contains("Evidence FM \(index)") {
            debugRadioStore.add(RadioStation(
                name: "Evidence FM \(index)",
                streamURL: "https://radio.example.com/evidence\(index).mp3"
            ))
        }
        guard request == "organized" else { return }
        let seeded = debugRadioStore.stations
            .filter { $0.name.hasPrefix("Evidence FM ") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let folders = ["Evidence News", "Evidence Music", "Evidence Talk", "Evidence Night"]
        let tags = ["Jazz", "Classical", "Lo-fi Beats", "Morning Drive", "Late Night", "Talk Radio"]
        for (offset, station) in seeded.enumerated() {
            debugRadioStore.setFolder(folders[offset % folders.count], forStationIDs: [station.id])
            debugRadioStore.addTag(tags[offset % tags.count], toStationIDs: [station.id])
        }
    }
}
#endif

#if DEBUG
extension Notification.Name {
    /// 调试构建:收起播放页,同左上角的收起键(`PRIMUSE_DEBUG_PLAYER_CYCLE` 用)。
    static let primuseDebugMinimizeNowPlaying = Notification.Name("primuse.debug.minimizeNowPlaying")
}
#endif
