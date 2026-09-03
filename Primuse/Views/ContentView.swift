#if os(iOS)
import SwiftUI
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

enum AppNavigationLayoutPolicy {
    static func rootLayout(
        mode: AppNavigationMode,
        usesRegularWidth: Bool
    ) -> AppNavigationRootLayout {
        if mode == .minimal { return .minimal }
        return usesRegularWidth ? .standardSidebar : .standardTabs
    }
}

enum MinimalNavigationPage: Hashable, Identifiable, Sendable {
    case librarySection(LibrarySection)
    case search
    case settings

    var id: String {
        switch self {
        case .librarySection(let section): return "library:\(section.rawValue)"
        case .search: return "search"
        case .settings: return "settings"
        }
    }
}

enum MinimalNavigationPolicy {
    static let homePage = MinimalNavigationPage.librarySection(.recommendations)

    static func libraryPages(visibleSections: [LibrarySection]) -> [MinimalNavigationPage] {
        let remainingSections = visibleSections.filter { $0 != .recommendations }
        return ([.recommendations] + remainingSections).map(MinimalNavigationPage.librarySection)
    }

    static func selectedPage(
        selectedTab: Int,
        activeLibrarySection: LibrarySection?
    ) -> MinimalNavigationPage {
        switch selectedTab {
        case 0: return homePage
        case 1:
            return activeLibrarySection.map(MinimalNavigationPage.librarySection) ?? homePage
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

private struct MinimalNavigationDetailScopeEnvironmentKey: EnvironmentKey {
    static let defaultValue: MinimalNavigationDetailScope? = nil
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
    var appNavigationMode: AppNavigationMode {
        get { self[AppNavigationModeEnvironmentKey.self] }
        set { self[AppNavigationModeEnvironmentKey.self] = newValue }
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

extension View {
    func minimalNavigationDetail() -> some View {
        modifier(MinimalNavigationDetailModifier())
    }
}

private struct MinimalNavigationDetailModifier: ViewModifier {
    @Environment(\.appNavigationMode) private var appNavigationMode
    @Environment(\.minimalNavigationDetailScope) private var detailScope
    @Environment(\.minimalNavigationDetailTransitionHandler) private var transitionHandler
    @State private var transitionID = UUID()

    @ViewBuilder
    func body(content: Content) -> some View {
        if appNavigationMode == .minimal, let detailScope {
            content
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
    case librarySongs
    case libraryAlbums
    case libraryArtists
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
                .libraryArtists, .libraryPlaylists, .libraryRadio:
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
        case .songs: return .librarySongs
        case .albums: return .libraryAlbums
        case .artists: return .libraryArtists
        case .playlists: return .libraryPlaylists
        case .radio: return .libraryRadio
        }
    }

    var titleKey: String.LocalizationValue {
        switch self {
        case .home: return "home_title"
        case .library: return "library_title"
        case .libraryRecommendations: return "library_recommendations_title"
        case .librarySongs: return "tab_songs"
        case .libraryAlbums: return "tab_albums"
        case .libraryArtists: return "tab_artists"
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
        case .librarySongs: return "music.note"
        case .libraryAlbums: return "square.stack.fill"
        case .libraryArtists: return "music.mic"
        case .libraryPlaylists: return "music.note.list"
        case .libraryRadio: return "radio.fill"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(AppleMusicService.self) private var appleMusic
    @Environment(MetadataBackfillService.self) private var backfill

    /// Mini player 是否应该显示 — 猿音自家在播 或 Apple Music 在系统侧播。
    /// 这两路是独立 player, 任一非空都显示 accessory。
    private var miniPlayerActive: Bool {
        player.currentSong != nil || appleMusic.nowPlayingSong != nil
    }
    /// Batch selection temporarily owns the bottom safe area. Playback keeps
    /// running, but its accessory stays hidden until selection ends.
    private var miniPlayerVisible: Bool {
        miniPlayerActive && !batchSelectionActive
    }
    /// iPad (regular) 走 NavigationSplitView; iPhone / iPad 分屏小窗 (compact)
    /// 走 TabView。Apple 推荐用 horizontalSizeClass 而不是 idiom 来判断,以
    /// 适配 Stage Manager / 分屏 / 折叠态。
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
    @State private var searchText = ""
    @State private var showNowPlaying = false
    @State private var nowPlayingPresentationID = UUID()
    @State private var batchSelectionActive = false
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
    @State private var showInitialOnboarding = false
    private let legacyTabBarClearance: CGFloat = 49

    private var navigationMode: AppNavigationMode {
        AppNavigationMode.resolve(navigationModeRawValue)
    }

    private var rootLayout: AppNavigationRootLayout {
        AppNavigationLayoutPolicy.rootLayout(
            mode: navigationMode,
            usesRegularWidth: sizeClass == .regular
        )
    }

    private var visibleLibrarySections: [LibrarySection] {
        LibraryDisplayConfiguration.visibleSections(
            orderRawValue: librarySectionOrderRawValue,
            hiddenRawValue: hiddenLibrarySectionsRawValue
        )
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

    @ViewBuilder
    private var tabRoot: some View {
        TabView(selection: $selectedTab) {
            Tab(String(localized: "home_title"), systemImage: "house.fill", value: 0) {
                HomeView(
                    switchToSettingsTab: { selectedTab = 3 },
                    openLibrarySongs: { openLibraryDeepLink(.section(.songs)) }
                )
                    .id("primuse.tab.home")
                    .environment(\.minimalNavigationDetailScope, .home)
                    .toolbar(
                        navigationMode == .minimal ? .hidden : .automatic,
                        for: .tabBar
                    )
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
                .toolbar(
                    navigationMode == .minimal ? .hidden : .automatic,
                    for: .tabBar
                )
            }

            Tab(value: 2, role: .search) {
                SearchView(searchText: $searchText, onShowInLibrary: showSongInLibrary)
                    .id("primuse.tab.search")
                    .environment(\.minimalNavigationDetailScope, .search)
                    .toolbar(
                        navigationMode == .minimal ? .hidden : .automatic,
                        for: .tabBar
                    )
            }

            Tab(String(localized: "settings_title"), systemImage: "gearshape", value: 3) {
                SettingsView(scraperSettingsRoute: $scraperSettingsRoute)
                    .environment(\.minimalNavigationDetailScope, .settings)
                    .toolbar(
                        navigationMode == .minimal ? .hidden : .automatic,
                        for: .tabBar
                    )
            }
        }
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
        VStack(spacing: 0) {
            MinimalNavigationChromeLayout(
                visibility: minimalTopNavigationHidden ? 0 : 1
            ) {
                MinimalTopNavigationBar(
                    searchText: $searchText,
                    categoriesCollapsed: $minimalNavigationCategoriesCollapsed,
                    libraryPages: MinimalNavigationPolicy.libraryPages(
                        visibleSections: visibleLibrarySections
                    ),
                    selection: MinimalNavigationPolicy.selectedPage(
                        selectedTab: selectedTab,
                        activeLibrarySection: minimalLibrarySection
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
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.26, extraBounce: 0),
                value: minimalTopNavigationHidden
            )

            tabRoot
                .toolbar(.hidden, for: .tabBar)
                .background {
                    MinimalNavigationScrollObserver(
                        categoriesCollapsed: $minimalNavigationCategoriesCollapsed,
                        isEnabled: !minimalTopNavigationHidden,
                        refreshID: selectedTab
                    )
                }
        }
        .onPreferenceChange(MinimalNavigationDetailScopesPreferenceKey.self) { scopes in
            minimalDetailScopes = scopes
            minimalReturningDetailScopes.formIntersection(scopes)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if miniPlayerVisible {
                MinimalNowPlayingAccessory(onTap: presentNowPlaying)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
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

    /// iPad 用的 sidebar + detail 双栏布局。sidebar 顶层就是 Home / 资料库 /
    /// 搜索 / 设置,detail 直接挂对应的现有视图。播放器作为 sidebar 内独立
    /// 底栏与列表并排布局,既为列表让位,也避免列表手势干扰切歌。
    @ViewBuilder
    private var padRoot: some View {
        NavigationSplitView {
            let selection = Binding<SidebarItem?>(
                get: { sidebarSelection },
                set: { if let v = $0 {
                    sidebarSelection = v
                    selectedTab = v.rawValueTab
                } }
            )
            VStack(spacing: 0) {
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

                if miniPlayerVisible {
                    SidebarNowPlayingAccessory(onTap: presentNowPlaying)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("Primuse")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            padDetail(for: sidebarSelection)
        }
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
                openLibrarySongs: { openLibraryDeepLink(.section(.songs)) }
            )
        case .library:
            LibraryView(deepLink: $libraryDeepLink)
        case .libraryRecommendations:
            librarySubpane(title: "library_recommendations_title") {
                AIRecommendationLibraryView()
            }
        case .librarySongs:
            librarySubpane(title: "tab_songs") { SongListView() }
        case .libraryAlbums:
            librarySubpane(title: "tab_albums") { AlbumGridView() }
        case .libraryArtists:
            librarySubpane(title: "tab_artists") { ArtistListView(artists: library.visibleArtists) }
        case .libraryPlaylists:
            librarySubpane(title: "tab_playlists") { PlaylistListView() }
        case .libraryRadio:
            librarySubpane(title: "radio_title") { RadioStationsView() }
        case .search:
            SearchView(searchText: $searchText, onShowInLibrary: showSongInLibrary)
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
                .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
                .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
                .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
                // SmartPlaylist destination 由 PlaylistListView 自己挂,不在
                // 这层重复设置,免得 SwiftUI 报"重复 destination"警告。
        }
    }

    var body: some View {
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
                        .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .environment(\.appNavigationMode, navigationMode)
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
            if !(0...3).contains(selectedTab) {
                selectedTab = 0
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
        // 首启 onboarding —— 仅当未看过且库里没源 (避免 CloudKit 同步迟到时
        // 让老用户重看一次)
        .fullScreenCover(isPresented: $showInitialOnboarding) {
            OnboardingView()
        }
        // Spotlight 点击 ── identifier 形如 "song:<id>" / "album:<id>" 等。
        // song 直接播; album / artist / playlist 推进资料库对应详情页。
        .onContinueUserActivity("com.apple.corespotlight.searchableitem") { activity in
            guard let item = SpotlightIndexService.identifier(from: activity) else { return }
            handleSpotlightItem(item)
        }
        // Handoff ── 从另一台设备过来时拿到完整播放上下文 (当前歌 / 队列 /
        // 播放位置 / 播放或暂停 / shuffle / repeat),无缝接着播下去。
        .onContinueUserActivity("com.welape.yuanyin.nowplaying") { activity in
            handleHandoffActivity(activity)
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
        guard selectedTab == 0 || (selectedTab == 1 && minimalLibrarySection == nil) else {
            synchronizeSidebarForCurrentSelection()
            return
        }
        selectMinimalPage(MinimalNavigationPolicy.homePage)
    }

    private func submitMinimalSearch() {
        selectMinimalPage(.search)
        SearchHistoryStore.record(searchText)
    }

    private func selectMinimalPage(_ page: MinimalNavigationPage) {
        showNowPlaying = false
        switch page {
        case .librarySection(let section):
            selectedTab = 1
            sidebarSelection = SidebarItem.libraryChild(for: section)
            minimalLibrarySection = section
            libraryDeepLink = .section(section)
        case .search:
            selectedTab = 2
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
        player.setQueue(resolvedQueue, startAt: songIndex)
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
                await player.play(song: song, caller: "Handoff")
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
            player.setQueue([song] + rest, startAt: 0)
            Task { await player.play(song: song, caller: "Spotlight") }
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
        let observationStateChanged = uiView.observesScrolling != isEnabled
        uiView.observesScrolling = isEnabled
        guard isEnabled else {
            context.coordinator.detachAll()
            return
        }
        let pageChanged = uiView.refreshID != refreshID
        uiView.refreshID = refreshID
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
        private var observations: [ObjectIdentifier: Observation] = [:]

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

        private func updateCollapsedState() {
            guard let scopeView,
                  let window = scopeView.window else { return }
            let scopeRect = scopeView.convert(scopeView.bounds, to: window)
            let shouldCollapse = observations.values.contains { observation in
                guard let scrollView = observation.scrollView,
                      isVisible(scrollView, inside: scopeRect, window: window) else {
                    return false
                }
                let topOffset = -scrollView.adjustedContentInset.top
                return scrollView.contentOffset.y - topOffset > 24
            }

            DispatchQueue.main.async { [weak self] in
                self?.onCollapsedChange?(shouldCollapse)
            }
        }

        private func verticalScrollViews(in view: UIView) -> [UIScrollView] {
            var result: [UIScrollView] = []
            if let scrollView = view as? UIScrollView,
               scrollView.bounds.height > 80,
               scrollView.contentSize.height + scrollView.adjustedContentInset.top
                   + scrollView.adjustedContentInset.bottom > scrollView.bounds.height + 1 {
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
    @Binding var categoriesCollapsed: Bool
    let libraryPages: [MinimalNavigationPage]
    let selection: MinimalNavigationPage
    let onSelect: (MinimalNavigationPage) -> Void
    let onSubmitSearch: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFieldFocused: Bool
    @Namespace private var librarySelectionIndicator

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                homeButton

                searchField

                if categoriesCollapsed,
                   let selectedLibraryPage {
                    collapsedLibraryButton(selectedLibraryPage)
                        .transition(.scale(scale: 0.86).combined(with: .opacity))
                }

                actionButton(
                    page: .settings,
                    systemImage: "gearshape",
                    title: "settings_title"
                )
            }
            .padding(.horizontal, 12)

            if !categoriesCollapsed {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(libraryPages) { page in
                                libraryButton(page)
                                    .id(page.id)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .frame(height: 37)
                    .padding(.top, 9)
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
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay {
                    LinearGradient(
                        colors: [
                            Color(uiColor: .systemBackground).opacity(0.72),
                            Color(uiColor: .systemBackground).opacity(0.42),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86),
            value: categoriesCollapsed
        )
        .onChange(of: selection) { _, newSelection in
            if newSelection != .search {
                searchFieldFocused = false
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(searchFieldFocused ? Color.accentColor : Color.secondary)

            TextField("search_title", text: $searchText)
                .font(.system(size: 15.5))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFieldFocused)
                .onSubmit(onSubmitSearch)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFieldFocused = true
                    select(.search)
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
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(.thinMaterial, in: Capsule())
        .background(Color.secondary.opacity(0.08), in: Capsule())
        .overlay {
            Capsule()
                .stroke(
                    searchFieldFocused
                        ? Color.accentColor.opacity(0.55)
                        : Color.primary.opacity(0.08),
                    lineWidth: searchFieldFocused ? 1.5 : 1
                )
        }
        .shadow(color: Color.black.opacity(0.07), radius: 5, y: 2)
        .contentShape(Capsule())
        .simultaneousGesture(
            TapGesture().onEnded {
                select(.search)
                searchFieldFocused = true
            }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("search_title"))
    }

    private var homeButton: some View {
        Button {
            select(MinimalNavigationPolicy.homePage)
        } label: {
            Image(systemName: "house")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .background(.thinMaterial, in: Circle())
                .background(Color.secondary.opacity(0.08), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                }
                .shadow(color: Color.black.opacity(0.08), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("home_title"))
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
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .background {
                    Circle()
                        .fill(Color.accentColor.opacity(isSelected ? 0.2 : 0.14))
                }
                .background(.thinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 0.5)
                }
                .shadow(color: Color.black.opacity(0.07), radius: 5, y: 2)
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
                .font(.system(size: 14.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 15)
                .frame(height: 34)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.16))
                            .matchedGeometryEffect(
                                id: "minimal-library-selection",
                                in: librarySelectionIndicator
                            )
                    } else {
                        Capsule()
                            .fill(Color.secondary.opacity(0.1))
                    }
                }
                .overlay {
                    Capsule()
                        .strokeBorder(
                            isSelected
                                ? Color.accentColor.opacity(0.38)
                                : Color.primary.opacity(0.06),
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
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color.accentColor.opacity(0.16), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.38), lineWidth: 0.5)
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
        if reduceMotion {
            onSelect(page)
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                onSelect(page)
            }
        }
    }

    @ViewBuilder
    private func pageTitle(_ page: MinimalNavigationPage) -> some View {
        switch page {
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

struct SidebarNowPlayingAccessory: View {
    var onTap: () -> Void

    var body: some View {
        MiniPlayerView(
            onTap: onTap,
            showsNextButton: true,
            showsSubtitle: true
        )
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
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
