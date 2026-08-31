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
    case home
    case library
    case librarySection(LibrarySection)
    case search
    case settings

    var id: String {
        switch self {
        case .home: return "home"
        case .library: return "library"
        case .librarySection(let section): return "library:\(section.rawValue)"
        case .search: return "search"
        case .settings: return "settings"
        }
    }
}

enum MinimalNavigationPolicy {
    static func libraryPages(visibleSections: [LibrarySection]) -> [MinimalNavigationPage] {
        [.library] + visibleSections.map(MinimalNavigationPage.librarySection)
    }

    static func selectedPage(
        selectedTab: Int,
        activeLibrarySection: LibrarySection?
    ) -> MinimalNavigationPage {
        switch selectedTab {
        case 0: return .home
        case 1:
            return activeLibrarySection.map(MinimalNavigationPage.librarySection) ?? .library
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

private struct AppNavigationModeEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppNavigationMode.standard
}

extension EnvironmentValues {
    var appNavigationMode: AppNavigationMode {
        get { self[AppNavigationModeEnvironmentKey.self] }
        set { self[AppNavigationModeEnvironmentKey.self] = newValue }
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
    @State private var libraryDeepLink: LibraryDeepLink?
    @State private var minimalLibrarySection: LibrarySection?
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
                .toolbar(
                    navigationMode == .minimal ? .hidden : .automatic,
                    for: .tabBar
                )
            }

            Tab(value: 2, role: .search) {
                SearchView(searchText: $searchText, onShowInLibrary: showSongInLibrary)
                    .id("primuse.tab.search")
                    .toolbar(
                        navigationMode == .minimal ? .hidden : .automatic,
                        for: .tabBar
                    )
            }

            Tab(String(localized: "settings_title"), systemImage: "gearshape", value: 3) {
                SettingsView(scraperSettingsRoute: $scraperSettingsRoute)
                    .toolbar(
                        navigationMode == .minimal ? .hidden : .automatic,
                        for: .tabBar
                    )
            }
        }
    }

    @ViewBuilder
    private var minimalRoot: some View {
        VStack(spacing: 0) {
            MinimalTopNavigationBar(
                libraryPages: MinimalNavigationPolicy.libraryPages(
                    visibleSections: visibleLibrarySections
                ),
                selection: MinimalNavigationPolicy.selectedPage(
                    selectedTab: selectedTab,
                    activeLibrarySection: minimalLibrarySection
                ),
                onSelect: selectMinimalPage
            )
            .allowsHitTesting(!batchSelectionActive)
            .accessibilityHidden(batchSelectionActive)
            .opacity(batchSelectionActive ? 0.42 : 1)

            tabRoot
                .toolbar(.hidden, for: .tabBar)
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
        // 隔离资料库批次更新观察。直接把 searchRevision 的 onChange 挂在
        // ContentView 上会让整个 TabView 在后台扫描/回填时反复重算。
        .background {
            CurrentSongLibraryObserver {
                stopIfCurrentSongRemoved()
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
            synchronizeSidebarForCurrentSelection()
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

    private func selectMinimalPage(_ page: MinimalNavigationPage) {
        showNowPlaying = false
        switch page {
        case .home:
            selectedTab = 0
            sidebarSelection = .home
        case .library:
            selectedTab = 1
            sidebarSelection = .library
            minimalLibrarySection = nil
            libraryDeepLink = .root
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
        switch MinimalNavigationPolicy.selectedPage(
            selectedTab: selectedTab,
            activeLibrarySection: minimalLibrarySection
        ) {
        case .home:
            sidebarSelection = .home
        case .library:
            sidebarSelection = .library
        case .librarySection(let section):
            sidebarSelection = SidebarItem.libraryChild(for: section)
        case .search:
            sidebarSelection = .search
        case .settings:
            sidebarSelection = .settings
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

    /// 当前播放的歌已不在可见库里 (被删 / 源停用 / 重扫描时换了 ID) 时,
    /// 停止播放并清队列。player 继续持有失效的 Song 会让后续 seek / 下一首
    /// 指向已不存在的源文件。
    private func stopIfCurrentSongRemoved() {
        guard let cs = player.currentSong else { return }
        guard !player.isLiveRadio else { return }
        if !library.containsVisibleSong(id: cs.id) {
            player.stop(); player.clearQueue(); showNowPlaying = false
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
}

private struct MinimalTopNavigationBar: View {
    let libraryPages: [MinimalNavigationPage]
    let selection: MinimalNavigationPage
    let onSelect: (MinimalNavigationPage) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var librarySelectionIndicator

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                actionButton(
                    page: .home,
                    systemImage: selection == .home ? "house.fill" : "house",
                    title: "home_title"
                )

                Spacer(minLength: 12)

                HStack(spacing: 2) {
                    actionButton(
                        page: .search,
                        systemImage: "magnifyingglass",
                        title: "search_title"
                    )
                    actionButton(
                        page: .settings,
                        systemImage: selection == .settings ? "gearshape.fill" : "gearshape",
                        title: "settings_title"
                    )
                }
                .padding(2)
                .background(Color.primary.opacity(0.055), in: Capsule())
            }
            .padding(.horizontal, 16)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(libraryPages) { page in
                            libraryButton(page)
                                .id(page.id)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 44)
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
        }
        .padding(.top, 2)
        .padding(.bottom, 6)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.45)
        }
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
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .background {
                    Circle()
                        .fill(
                            isSelected
                                ? Color.accentColor.opacity(0.16)
                                : Color.clear
                        )
                }
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
                .font(.footnote.weight(isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Color.accentColor.opacity(0.16))
                            .matchedGeometryEffect(
                                id: "minimal-library-selection",
                                in: librarySelectionIndicator
                            )
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
        case .library:
            Text("library_title")
        case .librarySection(let section):
            Text(section.title)
        case .home:
            Text("home_title")
        case .search:
            Text("search_title")
        case .settings:
            Text("settings_title")
        }
    }
}

/// Keeps high-frequency library revision tracking out of `ContentView`'s
/// observation scope. The callback only mutates the root when the playing song
/// really disappeared; ordinary scan batches leave the tab hierarchy intact.
private struct CurrentSongLibraryObserver: View {
    @Environment(MusicLibrary.self) private var library
    let onLibraryChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            // Source enable/disable rebuilds the visible cache without always
            // bumping searchRevision, so retain both signals.
            .onChange(of: library.visibleSongs.count) { _, _ in
                onLibraryChange()
            }
            .onChange(of: library.searchRevision) { _, _ in
                onLibraryChange()
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
                }
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
            // `CachedArtworkView` can resolve synchronously from memory. Give
            // the complete player one display interval to commit off-screen
            // before starting the container animation, so no child layer can
            // appear ahead of the background and controls.
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if reduceMotion {
                presentationPhase = .visible
            } else {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.92)) {
                    presentationPhase = .visible
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
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
