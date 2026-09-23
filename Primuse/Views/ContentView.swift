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

/// 极简基座:页面按经典的方式带系统导航栏,底部换成极简底栏。只有外壳与根页/详情页
/// 两个修饰符读它;页面本身看到的 `appNavigationMode` 一律是 `.standard`。
private struct UsesMinimalDockEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

/// 极简基座没有「设置」标签,首页与资料库的根页在右上角放一颗齿轮,点它走这里。
private struct MinimalOpenSettingsEnvironmentKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
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

    var usesMinimalDock: Bool {
        get { self[UsesMinimalDockEnvironmentKey.self] }
        set { self[UsesMinimalDockEnvironmentKey.self] = newValue }
    }

    var minimalOpenSettings: (@MainActor () -> Void)? {
        get { self[MinimalOpenSettingsEnvironmentKey.self] }
        set { self[MinimalOpenSettingsEnvironmentKey.self] = newValue }
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

    /// 极简基座没有设置标签:首页与资料库的根页右上角放一颗齿轮。经典基座下什么都不加。
    func minimalSettingsToolbarButton() -> some View {
        modifier(MinimalSettingsToolbarButtonModifier())
    }

    func minimalNavigationDetail(isDetail: Bool = true) -> some View {
        modifier(MinimalNavigationDetailModifier(isDetail: isDetail))
    }
}

private struct MinimalNavigationRootModifier: ViewModifier {
    @Environment(\.usesMinimalDock) private var usesMinimalDock
    @Environment(\.minimalNavigationBars) private var bars

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesMinimalDock {
            // 极简基座的根页保留系统导航栏(大标题、工具栏按钮、搜索框都在),
            // 只把底部换成极简底栏。
            content
                // Empty states have an intrinsic height; bars need the full page bounds.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 每个根页面都经过这里,样式自己的页面底色在这一处挂上,不必逐页去改。
                .skinPageBackground()
                .minimalSafeAreaBar(edge: .bottom) { bars?.bottom }
        } else {
            content
        }
    }
}

private struct MinimalSettingsToolbarButtonModifier: ViewModifier {
    @Environment(\.minimalOpenSettings) private var openSettings

    func body(content: Content) -> some View {
        content.toolbar {
            if let openSettings {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: openSettings) {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(Text("settings_title"))
                    .accessibilityIdentifier("minimal.settings")
                }
            }
        }
    }
}

private struct MinimalNavigationDetailModifier: ViewModifier {
    let isDetail: Bool
    @Environment(\.usesMinimalDock) private var usesMinimalDock
    @Environment(\.minimalNavigationDetailScope) private var detailScope
    @Environment(\.minimalNavigationDetailTransitionHandler) private var transitionHandler
    @Environment(\.minimalNavigationBars) private var bars
    @State private var transitionID = UUID()

    @ViewBuilder
    func body(content: Content) -> some View {
        if isDetail, usesMinimalDock, let detailScope {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .skinPageBackground()
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
        case .spokenWord: return .librarySpokenWord
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
        case .librarySpokenWord: return "tab_spoken_word"
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
        case .librarySpokenWord: return "books.vertical.fill"
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
    /// 悬浮播放条上的队列入口。sheet 挂在这一层而不是播放条里:播放条住在 safeAreaBar 里,
    /// 从那里弹出面板要依赖它所在宿主的呈现上下文。
    @State private var showQueueFromBottomChrome = false
    @State private var batchSelectionActive = false
    @State private var carPlayEditorActive = false
    @State private var pendingPlaybackRemovalIDs: Set<String> = []
    @State private var isReconcilingPlaybackRemovals = false
    @State private var libraryDeepLink: LibraryDeepLink?
    @State private var minimalLibrarySection: LibrarySection?
    @State private var minimalDetailLedger =
        MinimalNavigationDetailLedger<MinimalNavigationDetailScope>()
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
    @State private var showInitialOnboarding = false
    private let legacyTabBarClearance: CGFloat = 49
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
        // 没有有声内容时不摆这个入口。
        .filter { $0 != .spokenWord || !library.spokenWordSongs.isEmpty }
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
    }

    @ViewBuilder
    private var minimalRoot: some View {
        tabRoot
            .environment(
                \.minimalNavigationBars,
                MinimalNavigationBars(
                    top: AnyView(EmptyView()),
                    bottom: AnyView(minimalBottomChrome)
                )
            )
            .environment(\.minimalOpenSettings) { selectMinimalPage(.settings) }
            .onPreferenceChange(MinimalNavigationDetailScopesPreferenceKey.self) { scopes in
                minimalDetailLedger.updateMounted(scopes)
            }
    }

    private var minimalDockPlace: MinimalBottomDock.Place {
        switch selectedTab {
        case 1: return .library
        case 2: return .search
        case 3: return .settings
        default: return .home
        }
    }

    /// 多选时系统的批量操作栏占着底部,极简底栏让开。
    @ViewBuilder
    private var minimalBottomChrome: some View {
        if !batchSelectionActive {
            MinimalBottomDock(
                place: minimalDockPlace,
                showsPlayer: miniPlayerVisible,
                librarySections: visibleLibrarySections,
                onHome: { selectMinimalPage(.home) },
                onLibrary: openMinimalLibraryRoot,
                onLibrarySection: { selectMinimalPage(.librarySection($0)) },
                onSearch: { selectMinimalPage(.search) },
                onSettings: { selectMinimalPage(.settings) },
                onTapPlayer: presentNowPlaying,
                onOpenQueue: { showQueueFromBottomChrome = true }
            )
            .pmAnimation(.panel, value: miniPlayerVisible)
        }
    }

    /// 资料库键:已经在资料库时回到资料库首页,否则切过去停在上次看的位置。
    private func openMinimalLibraryRoot() {
        showNowPlaying = false
        if selectedTab == 1 {
            libraryDeepLink = .root
        } else {
            selectedTab = 1
            sidebarSelection = .library
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
            librarySubpane(title: "stats_title") { ListeningStatsView() }
        case .librarySongs:
            librarySubpane(title: "tab_songs") { SongListView() }
        case .librarySpokenWord:
            librarySubpane(title: "tab_spoken_word") { SpokenWordLibraryView() }
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
        // 极简基座下页面也走经典的导航方式(系统导航栏、工具栏、搜索框),差别只在外壳。
        .environment(\.appNavigationMode, .standard)
        .environment(\.usesMinimalDock, navigationMode == .minimal)
        .environment(\.legacyBottomChromeOverlayActive, legacyBottomChromeOverlayActive)
        .onPreferenceChange(CarPlayEditorActivePreferenceKey.self) { carPlayEditorActive = $0 }
        .songBatchRemovalFeedback()
        .appleMusicSubscriptionOffer()
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

    /// 极简基座有首页,资料库也有自己的首页,不再需要把用户改落到某个分类。
    private func activateMinimalLandingPageIfNeeded() {
        synchronizeSidebarForCurrentSelection()
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
        sidebarSelection = .library
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
}

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
