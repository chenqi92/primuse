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
}

enum MinimalNavigationPolicy {
    /// 自绘顶栏里要不要带「首页」这一项。默认带:首页上的继续听、为你推荐、排行这些内容,
    /// 不该因为换了导航方式就再也进不去;只想留资料库分类的人可以关掉它。
    static let showsHomeKey = "primuse.navigation.minimal.showsHome.v1"
    static let showsHomeByDefault = true

    /// 资料库的落脚页:顶栏左上角那颗资料库按钮去的地方,也是没有首页时的起始页。
    static func homePage(visibleSections: [LibrarySection]) -> MinimalNavigationPage {
        visibleSections.first.map(MinimalNavigationPage.librarySection) ?? .search
    }

    static func libraryPages(visibleSections: [LibrarySection]) -> [MinimalNavigationPage] {
        visibleSections.map(MinimalNavigationPage.librarySection)
    }

    /// 顶栏分类行里的全部项:首页(如果显示)在最前,后面是资料库分类。
    static func chipPages(
        visibleSections: [LibrarySection],
        showsHome: Bool
    ) -> [MinimalNavigationPage] {
        (showsHome ? [MinimalNavigationPage.home] : []) + libraryPages(visibleSections: visibleSections)
    }

    /// 启动或切到自绘顶栏时,当前停着的标签页要不要改落到资料库的落脚页。
    ///
    /// 首页标签只有在顶栏带「首页」时才留得住;资料库标签还没定下分类时也要落过去。
    /// 已经在用自绘顶栏的人此前从不会停在首页标签上,所以他们的起始页不受影响。
    static func redirectsToLibraryHome(
        selectedTab: Int,
        activeLibrarySection: LibrarySection?,
        showsHome: Bool
    ) -> Bool {
        switch selectedTab {
        case 0: return !showsHome
        case 1: return activeLibrarySection == nil
        default: return false
        }
    }

    static func selectedPage(
        selectedTab: Int,
        activeLibrarySection: LibrarySection?,
        visibleSections: [LibrarySection],
        showsHome: Bool = false
    ) -> MinimalNavigationPage {
        let libraryHomePage = Self.homePage(visibleSections: visibleSections)
        let homePage = showsHome ? MinimalNavigationPage.home : libraryHomePage
        switch selectedTab {
        case 0: return homePage
        case 1:
            guard let activeLibrarySection, visibleSections.contains(activeLibrarySection) else {
                return libraryHomePage
            }
            return .librarySection(activeLibrarySection)
        case 2: return .search
        case 3: return .settings
        default: return homePage
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
        (@MainActor (UUID, MinimalNavigationDetailScope, Bool) -> Void)? = nil
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
        (@MainActor (UUID, MinimalNavigationDetailScope, Bool) -> Void)? {
        get { self[MinimalNavigationDetailTransitionHandlerEnvironmentKey.self] }
        set { self[MinimalNavigationDetailTransitionHandlerEnvironmentKey.self] = newValue }
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

    @ViewBuilder
    fileprivate func minimalSafeAreaBar<Bar: View>(
        edge: VerticalEdge,
        @ViewBuilder content: () -> Bar
    ) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: edge, spacing: 0, content: content)
                .scrollEdgeEffectStyle(.soft, for: edge == .top ? .top : .bottom)
        } else {
            safeAreaInset(edge: edge, spacing: 0, content: content)
        }
    }

    func minimalNavigationRoot() -> some View {
        modifier(MinimalNavigationRootModifier())
    }

    func minimalNavigationDetail(isDetail: Bool = true) -> some View {
        modifier(MinimalNavigationDetailModifier(isDetail: isDetail))
    }
}

private struct MinimalNavigationRootModifier: ViewModifier {
    @Environment(\.appNavigationMode) private var appNavigationMode
    @Environment(\.minimalNavigationBars) private var bars

    @ViewBuilder
    func body(content: Content) -> some View {
        if appNavigationMode == .minimal {
            content
                // Empty states have an intrinsic height; bars need the full page bounds.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 每个根页面都经过这里,样式自己的页面底色在这一处挂上,不必逐页去改。
                .skinPageBackground()
                .toolbar(.hidden, for: .navigationBar)
                .minimalSafeAreaBar(edge: .top) { bars?.top }
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .skinPageBackground()
                .preference(
                    key: MinimalNavigationDetailScopesPreferenceKey.self,
                    value: Set([detailScope])
                )
                .background {
                    MinimalNavigationDetailTransitionReporter { isVisible in
                        transitionHandler?(transitionID, detailScope, isVisible)
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

private struct MinimalNavigationDetailTransitionReporter: UIViewControllerRepresentable {
    let onVisibilityChange: @MainActor (Bool) -> Void

    func makeUIViewController(context: Context) -> ReporterViewController {
        ReporterViewController(onVisibilityChange: onVisibilityChange)
    }

    func updateUIViewController(
        _ uiViewController: ReporterViewController,
        context: Context
    ) {
        uiViewController.onVisibilityChange = onVisibilityChange
    }

    @MainActor
    final class ReporterViewController: UIViewController {
        var onVisibilityChange: @MainActor (Bool) -> Void
        private var reportsVisible = false

        init(onVisibilityChange: @escaping @MainActor (Bool) -> Void) {
            self.onVisibilityChange = onVisibilityChange
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
            guard let coordinator = navigationPopCoordinator() else { return }

            reportsVisible = false
            onVisibilityChange(false)
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                guard context.isCancelled else { return }
                self?.reportVisible()
            }
        }

        private func reportVisible() {
            guard !reportsVisible else { return }
            reportsVisible = true
            onVisibilityChange(true)
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
    case libraryAlbums
    case libraryArtists
    case libraryGenres
    case libraryPlaylists
    case libraryRadio
    case search
    case settings

    var id: Self { self }

    /// 映射到 iPhone tab 的索引,保证 phone 与 pad 共享 `selectedTab` state
    /// (sidebar 子项也属于 library 这一档,统一回 1)。
    var rawValueTab: Int {
        switch self {
        case .home: return 0
        case .library, .libraryRecommendations, .librarySongs, .libraryAlbums,
                .libraryArtists, .libraryGenres, .libraryPlaylists, .libraryRadio,
                .libraryFavorites, .libraryFolders, .libraryStatistics:
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
        case .albums: return .libraryAlbums
        case .artists: return .libraryArtists
        case .genres: return .libraryGenres
        case .playlists: return .libraryPlaylists
        case .radio: return .libraryRadio
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
        case .libraryAlbums: return "tab_albums"
        case .libraryArtists: return "tab_artists"
        case .libraryGenres: return "tab_genres"
        case .libraryPlaylists: return "tab_playlists"
        case .libraryRadio: return "radio_title"
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
        case .libraryAlbums: return "square.stack.fill"
        case .libraryArtists: return "music.mic"
        case .libraryGenres: return "tag.fill"
        case .libraryPlaylists: return "music.note.list"
        case .libraryRadio: return "radio.fill"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

/// Stage 2 的启动占位。资料库发布之前渲染它, 所以这里一行库内容都不能读:
/// 只有 App 背景 + 进度指示 + 一句本地化文案。
private struct LibraryPreparingView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("library_preparing")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
    @State private var settingsSearch = SettingsSearchState()
    @State private var showNowPlaying = false
    @State private var nowPlayingPresentationID = UUID()
    /// 悬浮播放条上的队列入口。sheet 挂在这一层而不是播放条里:播放条住在 safeAreaBar 里,
    /// 从那里弹出面板要依赖它所在宿主的呈现上下文。
    @State private var showQueueFromBottomChrome = false
    @State private var batchSelectionActive = false
    @State private var carPlayEditorActive = false
    @State private var pendingPlaybackRemovalIDs: Set<String> = []
    @State private var isReconcilingPlaybackRemovals = false
    @State private var libraryDeepLink: LibraryDeepLink?
    @State private var minimalLibrarySection: LibrarySection?
    @State private var minimalDetailScopes: Set<MinimalNavigationDetailScope> = []
    @State private var minimalPresentedDetailScopes:
        [UUID: MinimalNavigationDetailScope] = [:]
    @State private var minimalReturningDetailScopes:
        Set<MinimalNavigationDetailScope> = []
    @State private var minimalNavigationCategoriesCollapsed = false
    @State private var scraperSettingsRoute = ScraperSettingsRouteState()
    /// 跨年自动弹年度报告的状态。1/1 之后用户首次进 app + 上一年听满 2 个月
    /// 时由 YearlyReportAutoTrigger 触发。
    @State private var autoYearlyReport: YearlyReportData?
    /// 首启 onboarding —— @AppStorage 持久, 关掉后永久 true。
    @AppStorage("primuse.hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    @AppStorage(LibraryDisplayConfiguration.sectionOrderKey)
    private var librarySectionOrderRawValue = ""
    @AppStorage(LibraryDisplayConfiguration.hiddenSectionsKey)
    private var hiddenLibrarySectionsRawValue = ""
    @AppStorage(MinimalNavigationPolicy.showsHomeKey)
    private var minimalShowsHome = MinimalNavigationPolicy.showsHomeByDefault
    @State private var showInitialOnboarding = false
    private let legacyTabBarClearance: CGFloat = 49
    /// 顶栏几何来自当前界面样式。折叠判定要用同一组数值算滞回带宽,
    /// 否则样式把分类行做高之后,带宽会小于顶栏让出的高度,列表又会自己抽搐。
    @Environment(\.skin) private var skin

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
    }

    private var minimalCollapsibleChromeHeight: CGFloat {
        skin.metric(.chromeChipRowHeight) + skin.metric(.chromeChipRowSpacing)
    }

    private var minimalTopNavigationHidden: Bool {
        var effectiveDetailScopes = minimalDetailScopes
        effectiveDetailScopes.formUnion(minimalPresentedDetailScopes.values)
        return MinimalNavigationChromePolicy.hidesTopNavigation(
            mode: navigationMode,
            selectedTab: selectedTab,
            detailScopes: effectiveDetailScopes,
            returningScopes: minimalReturningDetailScopes
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
                    }
                )
                .environment(\.minimalNavigationDetailScope, .library)
                .environment(\.librarySearchTab, 1)
                .toolbar(systemTabBarVisibility, for: .tabBar)
            }

            Tab(String(localized: "search_title"), systemImage: "magnifyingglass",
                value: 2, role: searchTabRole) {
                SearchView(searchText: $searchText, scope: $searchScope,
                           contextualScope: searchContext, onShowInLibrary: showSongInLibrary)
                    .id("primuse.tab.search")
                    .environment(\.minimalNavigationDetailScope, .search)
                    .toolbar(systemTabBarVisibility, for: .tabBar)
            }

            Tab(String(localized: "settings_title"), systemImage: "gearshape", value: 3) {
                SettingsView(scraperSettingsRoute: $scraperSettingsRoute, search: settingsSearch)
                    .environment(\.minimalNavigationDetailScope, .settings)
                    .toolbar(systemTabBarVisibility, for: .tabBar)
            }
        }
        .softNavigationScrollEdges()
        .environment(\.minimalNavigationDetailTransitionHandler) {
            transitionID, detailScope, isVisible in
            updateMinimalNavigationDetailTransition(
                id: transitionID,
                scope: detailScope,
                isVisible: isVisible
            )
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
            .background {
                MinimalNavigationScrollObserver(
                    categoriesCollapsed: $minimalNavigationCategoriesCollapsed,
                    isEnabled: !minimalTopNavigationHidden,
                    refreshID: selectedTab,
                    collapsibleChromeHeight: minimalCollapsibleChromeHeight
                )
            }
            .onPreferenceChange(MinimalNavigationDetailScopesPreferenceKey.self) { scopes in
                minimalDetailScopes = scopes
                minimalReturningDetailScopes.formIntersection(scopes)
            }
    }

    @ViewBuilder
    private var minimalBottomChrome: some View {
        if miniPlayerVisible {
            Group {
                switch skin.skin.bottomChrome {
                case .floatingCapsule:
                    FloatingCapsulePlayerBar(
                        onTap: presentNowPlaying,
                        onOpenQueue: { showQueueFromBottomChrome = true }
                    )
                case .classic:
                    if sizeClass == .regular {
                        PadNowPlayingAccessory(onTap: presentNowPlaying)
                    } else {
                        MinimalNowPlayingAccessory(onTap: presentNowPlaying)
                    }
                }
            }
            // miniPlayerVisible 是派生量, 翻转由播放状态决定, 调用点包不住动画
            // 事务, 曲线只能附在过渡本身上。
            .pmSlideTransition(edge: .bottom, motion: .panel)
        }
    }

    private var minimalTopChrome: some View {
        MinimalNavigationChromeLayout(
            visibility: minimalTopNavigationHidden ? 0 : 1
        ) {
            MinimalTopNavigationBar(
                searchText: selectedTab == 3 ? $settingsSearch.query : $searchText,
                settingsSearchPresented: $settingsSearch.isPresented,
                searchScope: $searchScope,
                searchContext: searchContext,
                categoriesCollapsed: $minimalNavigationCategoriesCollapsed,
                libraryPages: MinimalNavigationPolicy.chipPages(
                    visibleSections: visibleLibrarySections,
                    showsHome: minimalShowsHome
                ),
                libraryHomePage: MinimalNavigationPolicy.homePage(
                    visibleSections: visibleLibrarySections
                ),
                selection: MinimalNavigationPolicy.selectedPage(
                    selectedTab: selectedTab,
                    activeLibrarySection: minimalLibrarySection,
                    visibleSections: visibleLibrarySections,
                    showsHome: minimalShowsHome
                ),
                onSelect: selectMinimalPage,
                onSubmitSearch: submitMinimalSearch
            )
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
        .animation(skin.animation(.chromeReveal), value: minimalTopNavigationHidden)
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
            librarySubpane(title: "stats_title") { ListeningStatsView() }
        case .librarySongs:
            librarySubpane(title: "tab_songs") { SongListView() }
        case .libraryAlbums:
            librarySubpane(title: "tab_albums") { AlbumGridView() }
        case .libraryArtists:
            librarySubpane(title: "tab_artists") { ArtistListView(artists: library.visibleArtists) }
        case .libraryGenres:
            librarySubpane(title: "tab_genres") { GenreLibraryView() }
        case .libraryPlaylists:
            librarySubpane(title: "tab_playlists") { PlaylistListView() }
        case .libraryRadio:
            librarySubpane(title: "radio_title") { RadioStationsView() }
        case .search:
            SearchView(searchText: $searchText, scope: $searchScope,
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
            if library.isReady {
                mainContent
            } else {
                LibraryPreparingView()
            }
        }
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
    }

    private var mainContent: some View {
        ZStack(alignment: .bottom) {
            switch rootLayout {
            case .standardSidebar:
                padRoot
            case .standardTabs:
                playerAwareTabRoot
            case .minimal:
                minimalRoot
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
        .environment(\.librarySearchNavigation, searchNavigation)
        .environment(\.appNavigationMode, navigationMode)
        .environment(\.legacyBottomChromeOverlayActive, legacyBottomChromeOverlayActive)
        .onPreferenceChange(CarPlayEditorActivePreferenceKey.self) { carPlayEditorActive = $0 }
        .songBatchRemovalFeedback()
        .onPreferenceChange(SongBatchSelectionActivePreferenceKey.self) { isActive in
            batchSelectionActive = isActive
        }
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
            } else if let report = YearlyReportAutoTrigger.shouldShowReport(
                library: library,
                sourcesStore: sourcesStore
            ) {
                autoYearlyReport = report
            }
        }
        .onChange(of: navigationModeRawValue) { _, _ in
            if navigationMode == .minimal {
                activateMinimalLandingPageIfNeeded()
            } else {
                synchronizeSidebarForCurrentSelection()
            }
        }
        .onChange(of: minimalShowsHome) { _, _ in
            activateMinimalLandingPageIfNeeded()
        }
        .onChange(of: visibleLibrarySections) { _, sections in
            guard navigationMode == .minimal, selectedTab == 1,
                  minimalLibrarySection.map({ !sections.contains($0) }) ?? true else { return }
            selectMinimalPage(MinimalNavigationPolicy.homePage(visibleSections: sections))
        }
        .fullScreenCover(item: $autoYearlyReport) { data in
            YearlyReportView(data: data)
        }
        .sheet(isPresented: $showQueueFromBottomChrome) {
            QueueView(player: player)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        // 首启 onboarding —— 仅当未看过且库里没源 (避免 CloudKit 同步迟到时
        // 让老用户重看一次)
        .fullScreenCover(isPresented: $showInitialOnboarding) {
            OnboardingView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseRequestShowNowPlaying)) { _ in
            presentNowPlaying()
        }
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

    private func activateMinimalLandingPageIfNeeded() {
        guard navigationMode == .minimal else { return }
        guard MinimalNavigationPolicy.redirectsToLibraryHome(
            selectedTab: selectedTab,
            activeLibrarySection: minimalLibrarySection,
            showsHome: minimalShowsHome
        ) else {
            synchronizeSidebarForCurrentSelection()
            return
        }
        selectMinimalPage(MinimalNavigationPolicy.homePage(visibleSections: visibleLibrarySections))
    }

    private var searchAwareTabSelection: Binding<Int> {
        // TabView validates its first selection before the restoration task runs.
        Binding(get: { AppTabSelectionPolicy.resolve(selectedTab) }, set: { selectTab($0) })
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

    private func submitMinimalSearch() {
        guard selectedTab != 3 else { return }
        selectMinimalPage(.search)
        SearchHistoryStore.record(searchText)
    }

    private func selectMinimalPage(_ page: MinimalNavigationPage) {
        showNowPlaying = false
        switch page {
        case .home:
            selectedTab = 0
            sidebarSelection = .home
        case .librarySection(let section):
            selectedTab = 1
            sidebarSelection = SidebarItem.libraryChild(for: section)
            minimalLibrarySection = section
            libraryDeepLink = .section(section)
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
        let songsByID = Dictionary(
            library.visibleSongs.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, _ in lhs }
        )
        let resolvedQueue = queueIDs.compactMap { songsByID[$0] }
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
            guard let song = library.visibleSong(id: id) else { return }
            // 命中歌 + 整库剩下的拼起来当队列,跟 Siri / Shortcuts 同款行为
            let rest = library.visibleSongs.filter { $0.id != id }
            let queue = [song] + rest
            Task {
                await player.play(queue: queue, startingAt: 0, caller: "Spotlight")
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
        isVisible: Bool
    ) {
        if isVisible {
            minimalPresentedDetailScopes[id] = scope
            minimalReturningDetailScopes.remove(scope)
            return
        }

        minimalPresentedDetailScopes[id] = nil
        if !minimalPresentedDetailScopes.values.contains(scope) {
            minimalReturningDetailScopes.insert(scope)
        }
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

/// Watches the active vertical scroller without coupling every existing page
/// to minimal-mode chrome. This keeps List, ScrollView, and UIKit-backed search
/// results on their current implementations while the header follows real
/// content offset changes.
private struct MinimalNavigationScrollObserver: UIViewRepresentable {
    @Binding var categoriesCollapsed: Bool
    let isEnabled: Bool
    let refreshID: Int
    /// 折叠时顶栏让出的高度,决定折叠判定的滞回带宽。
    let collapsibleChromeHeight: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ScopeView {
        let view = ScopeView()
        view.coordinator = context.coordinator
        context.coordinator.scopeView = view
        return view
    }

    func updateUIView(_ uiView: ScopeView, context: Context) {
        let collapsedBinding = $categoriesCollapsed
        context.coordinator.onCollapsedChange = { collapsed in
            collapsedBinding.wrappedValue = collapsed
        }
        context.coordinator.collapsibleChromeHeight = collapsibleChromeHeight
        // 顶栏上的分类按钮自己也会改这个值,判定要认用户的手动展开。
        context.coordinator.syncExternalCollapsed(categoriesCollapsed)
        let observationStateChanged = uiView.observesScrolling != isEnabled
        uiView.observesScrolling = isEnabled
        guard isEnabled else {
            context.coordinator.detachAll()
            return
        }
        let pageChanged = uiView.refreshID != refreshID
        uiView.refreshID = refreshID
        if pageChanged { context.coordinator.resetForPageChange() }
        uiView.scheduleRefresh()
        if observationStateChanged || pageChanged {
            uiView.scheduleRefresh(after: 0.25)
        }
    }

    static func dismantleUIView(_ uiView: ScopeView, coordinator: Coordinator) {
        coordinator.detachAll()
    }

    final class ScopeView: UIView {
        weak var coordinator: Coordinator?
        var refreshID = Int.min
        var observesScrolling = true
        private var refreshScheduled = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleRefresh()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleRefresh()
        }

        func scheduleRefresh() {
            guard observesScrolling, !refreshScheduled else { return }
            refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                refreshScheduled = false
                coordinator?.refresh()
            }
        }

        func scheduleRefresh(after delay: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, observesScrolling else { return }
                coordinator?.refresh()
            }
        }
    }

    @MainActor
    final class Coordinator {
        private final class Observation {
            weak var scrollView: UIScrollView?
            let token: NSKeyValueObservation

            init(scrollView: UIScrollView, token: NSKeyValueObservation) {
                self.scrollView = scrollView
                self.token = token
            }
        }

        weak var scopeView: ScopeView?
        var onCollapsedChange: ((Bool) -> Void)?
        var collapsibleChromeHeight = MinimalNavigationChromeMetrics.collapsibleHeight
        private var observations: [ObjectIdentifier: Observation] = [:]
        private var resolver = MinimalNavigationCollapseResolver()
        private var reportedCollapsed = false

        func refresh() {
            guard let scopeView,
                  scopeView.observesScrolling,
                  let window = scopeView.window,
                  !scopeView.bounds.isEmpty else {
                detachAll()
                return
            }

            let scopeRect = scopeView.convert(scopeView.bounds, to: window)
            let candidates = verticalScrollViews(in: window).filter {
                isVisible($0, inside: scopeRect, window: window)
            }
            let candidateIDs = Set(candidates.map(ObjectIdentifier.init))

            for id in Array(observations.keys) where !candidateIDs.contains(id) {
                observations[id] = nil
            }

            for scrollView in candidates {
                let id = ObjectIdentifier(scrollView)
                guard observations[id] == nil else { continue }
                let token = scrollView.observe(\.contentOffset, options: [.initial, .new]) {
                    [weak self] _, _ in
                    Task { @MainActor [weak self] in
                        self?.updateCollapsedState()
                    }
                }
                observations[id] = Observation(scrollView: scrollView, token: token)
            }

            updateCollapsedState()
        }

        func detachAll() {
            observations.removeAll()
        }

        /// 换页后滚动位置完全换了一套,判定从展开重新起算;写回交给随后的刷新,
        /// 免得在 SwiftUI 的更新过程里改状态。
        func resetForPageChange() {
            resolver.reset()
        }

        /// 顶栏自己把状态改回展开时同步判定,免得下一次采样立刻又折回去。
        func syncExternalCollapsed(_ collapsed: Bool) {
            guard collapsed != reportedCollapsed else { return }
            reportedCollapsed = collapsed
            if collapsed {
                resolver.reset(isCollapsed: true)
            } else {
                let distance = primaryScrollView().map { self.scrolledDistance($0) } ?? 0
                resolver.markManuallyExpanded(
                    at: distance,
                    now: ProcessInfo.processInfo.systemUptime
                )
            }
        }

        private func updateCollapsedState() {
            guard let scopeView,
                  scopeView.observesScrolling,
                  scopeView.window != nil else { return }
            guard let scrollView = primaryScrollView() else {
                resolver.reset()
                report(false)
                return
            }
            let collapsed = resolver.update(
                scrolledDistance: scrolledDistance(scrollView),
                collapsibleChromeHeight: collapsibleChromeHeight,
                now: ProcessInfo.processInfo.systemUptime
            )
            report(collapsed)
        }

        /// 只在状态真的翻转时写回。滚动时每一帧都写 Binding 会让整页跟着重绘。
        private func report(_ collapsed: Bool) {
            guard collapsed != reportedCollapsed else { return }
            reportedCollapsed = collapsed
            onCollapsedChange?(collapsed)
        }

        /// 已经滚过的内容距离。顶栏收放会改写 adjustedContentInset,这个值跟着跳,
        /// 判定的滞回带宽就是用来吃下这一跳的。
        private func scrolledDistance(_ scrollView: UIScrollView) -> CGFloat {
            scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        }

        /// 一页里可能同时挂着几个纵向列表(相邻分页、还没拆掉的兄弟页)。取与本页
        /// 重叠面积最大的那个,免得几个列表各报各的位置互相打架。
        private func primaryScrollView() -> UIScrollView? {
            guard let scopeView, let window = scopeView.window else { return nil }
            let scopeRect = scopeView.convert(scopeView.bounds, to: window)
            var best: UIScrollView?
            var bestArea: CGFloat = 0
            for observation in observations.values {
                guard let scrollView = observation.scrollView,
                      isVisible(scrollView, inside: scopeRect, window: window) else { continue }
                let intersection = scrollView.convert(scrollView.bounds, to: window)
                    .intersection(scopeRect)
                guard !intersection.isNull else { continue }
                let area = intersection.width * intersection.height
                if area > bestArea {
                    bestArea = area
                    best = scrollView
                }
            }
            return best
        }

        private func verticalScrollViews(in view: UIView) -> [UIScrollView] {
            var result: [UIScrollView] = []
            if let scrollView = view as? UIScrollView,
               scrollView.bounds.height > 80,
               // 只看内容本身够不够长。把安全区算进来的话,顶栏一折叠这条判断就会
               // 翻面,整个列表会先退出观察再被重新纳入,状态跟着来回跳。
               scrollView.contentSize.height > scrollView.bounds.height + 1 {
                result.append(scrollView)
            }
            for subview in view.subviews {
                result.append(contentsOf: verticalScrollViews(in: subview))
            }
            return result
        }

        private func isVisible(
            _ scrollView: UIScrollView,
            inside scopeRect: CGRect,
            window: UIWindow
        ) -> Bool {
            guard scrollView.window === window,
                  !scrollView.isHidden,
                  scrollView.alpha > 0.01 else { return false }
            let visibleRect = scrollView.convert(scrollView.bounds, to: window)
            let intersection = visibleRect.intersection(scopeRect)
            return !intersection.isNull
                && intersection.width > min(80, visibleRect.width * 0.5)
                && intersection.height > min(80, visibleRect.height * 0.25)
        }
    }
}

private struct MinimalTopNavigationBar: View {
    @Binding var searchText: String
    @Binding var settingsSearchPresented: Bool
    @Binding var searchScope: LibrarySearchScope?
    let searchContext: LibrarySearchScope?
    @Binding var categoriesCollapsed: Bool
    /// 分类行里的全部项:带首页时首页在最前,后面是资料库分类。
    let libraryPages: [MinimalNavigationPage]
    /// 左上角资料库按钮去的页面。
    let libraryHomePage: MinimalNavigationPage
    let selection: MinimalNavigationPage
    let onSelect: (MinimalNavigationPage) -> Void
    let onSubmitSearch: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.skin) private var skin
    @FocusState private var searchFieldFocused: Bool
    @Namespace private var librarySelectionIndicator

    // 尺寸、间距与字号来自当前皮肤,并已按 Dynamic Type 缩放(见 `SkinStyle`)。
    // 经典皮肤给出的正是这里原来的字面量,所以默认观感不变。
    //
    // 进 token 的只有「多处共用的词汇」:高度、间距、字号、主色。组件私有的
    // 微调 —— 玻璃材质、0.5 描边、阴影参数、聚焦态描边的透明度 —— 留在本文件里,
    // 它们属于这个 chrome 实现本身。往全局 token 表塞只有一个消费者的条目,
    // 表会迅速膨胀到没人能通读,那时换皮肤又会退回「逐视图分叉」。
    // 另一套皮肤要改这些细节,应当换一个 `SkinSlot.navigationHeader` 实现。
    private var chipRowHeight: CGFloat { skin.metric(.chromeChipRowHeight) }
    private var chipHeight: CGFloat { skin.metric(.chromeChipHeight) }
    private var collapsedChipHeight: CGFloat { skin.metric(.chromeCollapsedChipHeight) }
    private var searchFieldMinHeight: CGFloat { skin.metric(.chromeSearchFieldHeight) }
    private var chipFontSize: CGFloat { skin.fontSize(.chrome) }
    private var collapsedChipFontSize: CGFloat { skin.fontSize(.chromeCompact) }
    private var searchFontSize: CGFloat { skin.fontSize(.chromeField) }
    /// 圆形按钮的触达尺寸。用未缩放值:今天这里就是固定 44,改成随字号放大
    /// 会连带改变顶栏布局,那是外观改动,不该混在这次结构调整里。
    private var actionButtonSize: CGFloat { skin.rawMetric(.controlHeightLarge) }

    /// 自己画页面底色的样式,顶栏控件用样式给的半透明面与描边;经典样式保持原来的
    /// 毛玻璃叠灰、细描边和一点投影。两种材质是这条栏自己的事,所以留在这里而不进 token 表。
    private var usesCanvasChrome: Bool { skin.paintsPageBackground }

    private var controlStroke: Color {
        usesCanvasChrome ? skin.color(.surfaceBorder) : skin.color(.textPrimary).opacity(0.1)
    }

    private var controlShadow: Color {
        usesCanvasChrome ? Color.clear : Color.black.opacity(0.07)
    }

    @ViewBuilder
    private func controlFill<S: Shape>(_ shape: S) -> some View {
        if usesCanvasChrome {
            shape.fill(skin.color(.surface))
        } else {
            ZStack {
                shape.fill(skin.color(.textSecondary).opacity(0.08))
                shape.fill(.thinMaterial)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: skin.metric(.chromeItemSpacing)) {
                libraryHomeButton

                searchField

                if categoriesCollapsed,
                   let selectedLibraryPage {
                    collapsedLibraryButton(selectedLibraryPage)
                        .transition(.scale(scale: 0.86).combined(with: .opacity))
                }

                if selection == .search, let searchContext {
                    SearchScopeSwitchButton(scope: $searchScope, context: searchContext)
                        .labelStyle(.iconOnly)
                        .font(.system(size: skin.rawMetric(.iconSizeMedium), weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(skin.color(.accent))
                        .fixedSize(horizontal: true, vertical: false)
                        .background(skin.color(.accentSoft), in: Circle())
                }

                actionButton(
                    page: .settings,
                    systemImage: "gearshape",
                    title: "settings_title"
                )
            }
            .padding(.horizontal, skin.metric(.chromeHorizontalInset))

            if !categoriesCollapsed {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: skin.metric(.chromeChipSpacing)) {
                            ForEach(libraryPages) { page in
                                libraryButton(page)
                                    .id(page.id)
                            }
                        }
                        .padding(.horizontal, skin.metric(.chromeHorizontalInset))
                    }
                    .frame(height: chipRowHeight)
                    .padding(.top, skin.metric(.chromeChipRowSpacing))
                    .onChange(of: selection.id, initial: true) { _, pageID in
                        guard libraryPages.contains(where: { $0.id == pageID }) else { return }
                        if reduceMotion {
                            proxy.scrollTo(pageID, anchor: .center)
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(pageID, anchor: .center)
                            }
                        }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, skin.metric(.chromeTopPadding))
        .padding(.bottom, skin.metric(.chromeBottomPadding))
        .animation(skin.animation(.chromeCollapse), value: categoriesCollapsed)
        .onChange(of: selection) { _, newSelection in
            settingsSearchPresented = false
            if newSelection != .search {
                searchFieldFocused = false
            }
        }
        .onChange(of: searchFieldFocused) { _, isFocused in
            // Dismissing the keyboard leaves submitted search results visible.
            if selection == .settings, isFocused {
                settingsSearchPresented = true
            }
        }
        .onChange(of: settingsSearchPresented) { _, isPresented in
            if selection == .settings, !isPresented {
                searchFieldFocused = false
            }
        }
    }

    private var searchPrompt: String {
        if selection == .settings {
            return SettingsStrings.text("Search settings")
        }
        if selection == .search, let searchScope {
            return String(format: String(localized: "search_scope_prompt_format"), searchScope.title)
        }
        return String(localized: "search_title")
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: skin.rawMetric(.iconSizeMedium), weight: .semibold))
                .foregroundStyle(searchFieldFocused ? skin.color(.accent) : skin.color(.textSecondary))

            TextField(searchPrompt, text: $searchText)
                .font(.system(size: searchFontSize))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFieldFocused)
                .onSubmit {
                    if selection == .settings { searchFieldFocused = false }
                    onSubmitSearch()
                }
                .accessibilityIdentifier("minimal.search")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFieldFocused = true
                    if selection != .settings { select(.search) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("clear"))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, searchText.isEmpty ? 14 : 6)
        .frame(maxWidth: .infinity, minHeight: searchFieldMinHeight)
        .background { controlFill(Capsule()) }
        .overlay {
            Capsule()
                .stroke(
                    searchFieldFocused
                        ? skin.color(.accent).opacity(0.55)
                        : (usesCanvasChrome
                            ? skin.color(.surfaceBorder)
                            : skin.color(.textPrimary).opacity(0.08)),
                    lineWidth: searchFieldFocused ? 1.5 : 1
                )
        }
        .shadow(color: controlShadow, radius: 5, y: 2)
        .contentShape(Capsule())
        .simultaneousGesture(
            TapGesture().onEnded {
                if selection != .settings { select(.search) }
                searchFieldFocused = true
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(searchPrompt))
    }

    private var libraryHomeButton: some View {
        Button {
            select(libraryHomePage)
        } label: {
            Image(systemName: "books.vertical")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(skin.color(.textSecondary))
                .frame(width: actionButtonSize, height: actionButtonSize)
                .contentShape(Rectangle())
                .background { controlFill(Circle()) }
                .overlay {
                    Circle()
                        .strokeBorder(controlStroke, lineWidth: usesCanvasChrome ? 1 : 0.5)
                }
                .shadow(
                    color: usesCanvasChrome ? Color.clear : Color.black.opacity(0.08),
                    radius: 5,
                    y: 2
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("library_title"))
    }

    private func actionButton(
        page: MinimalNavigationPage,
        systemImage: String,
        title: LocalizedStringKey
    ) -> some View {
        let isSelected = selection == page
        return Button {
            select(page)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                // 经典样式里这个键一直是强调色;自己画底色的样式里,只有选中时才点亮。
                .foregroundStyle(
                    usesCanvasChrome && !isSelected ? skin.color(.chromeItem) : skin.color(.accent)
                )
                .frame(width: actionButtonSize, height: actionButtonSize)
                .contentShape(Rectangle())
                .background {
                    if usesCanvasChrome {
                        Circle().fill(isSelected ? skin.color(.chipSelected) : skin.color(.surface))
                    } else {
                        ZStack {
                            Circle().fill(.thinMaterial)
                            Circle().fill(skin.color(.accent).opacity(isSelected ? 0.2 : 0.14))
                        }
                    }
                }
                .overlay {
                    Circle()
                        .strokeBorder(
                            usesCanvasChrome && !isSelected
                                ? skin.color(.surfaceBorder)
                                : skin.color(.accent).opacity(usesCanvasChrome ? 0.42 : 0.32),
                            lineWidth: usesCanvasChrome ? 1 : 0.5
                        )
                }
                .shadow(color: controlShadow, radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func libraryButton(_ page: MinimalNavigationPage) -> some View {
        let isSelected = selection == page
        return Button {
            select(page)
        } label: {
            pageTitle(page)
                .font(
                    .system(
                        size: chipFontSize,
                        weight: isSelected ? .semibold : skin.fontWeight(.chrome)
                    )
                )
                .foregroundStyle(isSelected ? skin.color(.accent) : skin.color(.textSecondary))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 15)
                .frame(height: chipHeight)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(skin.color(.chipSelected))
                            .matchedGeometryEffect(
                                id: "minimal-library-selection",
                                in: librarySelectionIndicator
                            )
                    } else {
                        Capsule()
                            .fill(skin.color(.chip))
                    }
                }
                .overlay {
                    Capsule()
                        .strokeBorder(
                            isSelected
                                ? skin.color(.accent).opacity(0.38)
                                : skin.color(.textPrimary).opacity(0.06),
                            lineWidth: 0.5
                        )
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func collapsedLibraryButton(_ page: MinimalNavigationPage) -> some View {
        Button {
            categoriesCollapsed = false
        } label: {
            HStack(spacing: 5) {
                pageTitle(page)
                    .font(
                        .system(
                            size: collapsedChipFontSize,
                            weight: skin.fontWeight(.chromeCompact)
                        )
                    )
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(skin.color(.accent))
            .padding(.horizontal, skin.metric(.chromeHorizontalInset))
            .frame(height: collapsedChipHeight)
            .background(skin.color(.chipSelected), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(skin.color(.accent).opacity(0.38), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var selectedLibraryPage: MinimalNavigationPage? {
        libraryPages.first(where: { $0 == selection })
    }

    private func select(_ page: MinimalNavigationPage) {
        if selection == .settings {
            settingsSearchPresented = false
            searchFieldFocused = false
        }
        if let animation = skin.animation(.pageSwitch) {
            withAnimation(animation) {
                onSelect(page)
            }
        } else {
            onSelect(page)
        }
    }

    @ViewBuilder
    private func pageTitle(_ page: MinimalNavigationPage) -> some View {
        switch page {
        case .home:
            Text("home_title")
        case .librarySection(let section):
            Text(section.title)
        case .search:
            Text("search_title")
        case .settings:
            Text("settings_title")
        }
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
    @State private var interactiveOffset = CGSize.zero
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
                .offset(transitionOffset(travel: travel))
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
                  dismissalState.isDismissing || interactiveOffset != .zero else { return }
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
                interactiveOffset = .zero
                presentationPhase = .visible
            }
        }
        .onDisappear {
            dismissalTask?.cancel()
            dismissalTask = nil
        }
    }

    private func transitionOffset(travel: CGFloat) -> CGSize {
        switch presentationPhase {
        case .staging:
            return CGSize(width: 0, height: travel)
        case .visible:
            return interactiveOffset
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
                interactiveOffset = CGSize(width: value, height: 0)
            case .vertical:
                interactiveOffset = CGSize(width: 0, height: value)
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
                interactiveOffset = .zero
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

// MARK: - Now Playing Accessory (adapts to inline/expanded)

struct LegacyNowPlayingAccessory: View {
    var onTap: () -> Void

    var body: some View {
        MiniPlayerView(onTap: onTap)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
    }
}

struct MinimalNowPlayingAccessory: View {
    var onTap: () -> Void

    var body: some View {
        MiniPlayerView(onTap: onTap)
            .frame(maxWidth: 620)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .contentShape(Capsule())
            .shadow(color: Color.black.opacity(0.16), radius: 12, y: 6)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)
    }
}

struct PadNowPlayingAccessory: View {
    var onTap: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
        .background {
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            if reduceTransparency {
                shape.fill(Color(uiColor: .secondarySystemBackground))
            } else {
                shape.fill(.regularMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
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
