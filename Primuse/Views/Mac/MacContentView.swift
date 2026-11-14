#if os(macOS)
import SwiftUI
import AppKit
import CoreSpotlight
import Observation
import PrimuseKit

/// Stage 2 的启动占位。资料库发布之前渲染它, 所以这里一行库内容都不能读:
/// 只有窗口底色 / 窗口装饰 + 进度指示 + 一句本地化文案。
private struct LibraryPreparingView: View {
    /// 资料库多数时候一两百毫秒就装好；先只铺底色，真慢的时候再亮出进度，
    /// 免得每次启动都闪一下「准备资料库」。
    @State private var showsProgress = false

    var body: some View {
        ZStack {
            PMColor.bg.ignoresSafeArea()
            if showsProgress {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("library_preparing")
                        .font(.subheadline)
                        .foregroundStyle(PMColor.textMuted)
                }
                .pmFadeTransition(motion: .contentAppear)
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            showsProgress = true
        }
        .background(PMWindowChromeConfigurator())
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct MacServerSyncErrorAlerts: ViewModifier {
    @Environment(MusicLibrary.self) private var library

    func body(content: Content) -> some View {
        content
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
    }
}

/// Mac 上 Spotlight 里点开的一项与「在 Primuse 中搜索」(#346)。AppKit 交给应用代理,SwiftUI 的
/// `onContinueUserActivity` 也可能收到同一次,都交到这里、几秒内同一项只认一次。冷启动时资料库还没装好、
/// 主界面还没挂上,先记在 `pending` 上,主界面出来后接手(原来的处理挂在主界面上,冷启动那一次就丢了)。
@MainActor
@Observable
final class MacSystemActivityRouter {
    static let shared = MacSystemActivityRouter()

    enum Request: Equatable {
        case item(SpotlightItem)
        case search(String)
    }

    private(set) var pending: Request?
    @ObservationIgnored private var handledAt: [String: ContinuousClock.Instant] = [:]
    /// 两条路送同一次点按的间隔:冷启动时 SwiftUI 那条要等窗口挂上才到。
    private static let duplicateWindow: Duration = .seconds(10)

    private init() {}

    nonisolated static func handles(_ activityType: String) -> Bool {
        activityType == CSSearchableItemActionType || activityType == CSQueryContinuationActionType
    }

    /// 认得的活动返回 true;`route` 只用来在诊断日志里分清是哪条路送来的。
    @discardableResult
    func handle(_ activity: NSUserActivity, route: String) -> Bool {
        switch activity.activityType {
        case CSSearchableItemActionType:
            guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                  let item = SpotlightIndexService.parse(uniqueIdentifier: identifier) else {
                plog("🔎 Spotlight activity without a known item via \(route)")
                return false
            }
            guard admit("item:\(identifier)", route: route) else { return true }
            plog("🔎 Spotlight open \(identifier.prefix(48)) via \(route)")
            pending = .item(item)
        case CSQueryContinuationActionType:
            let query = (activity.userInfo?[CSSearchQueryString] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else { return false }
            showSearch(query, route: route)
        default:
            return false
        }
        return true
    }

    /// 带着字进搜索页:Spotlight 的「在 App 中搜索」,以及 Siri / 快捷指令的搜索意图。
    func showSearch(_ query: String, route: String) {
        guard admit("query:\(query)", route: route) else { return }
        plog("🔎 Search in app via \(route)")
        pending = .search(query)
    }

    func consume() -> Request? {
        defer { pending = nil }
        return pending
    }

    private func admit(_ key: String, route: String) -> Bool {
        let now = ContinuousClock.now
        handledAt = handledAt.filter { now - $0.value < Self.duplicateWindow }
        guard handledAt[key] == nil else {
            plog("🔎 Same system activity again via \(route); already handled")
            return false
        }
        handledAt[key] = now
        return true
    }
}

/// 1.6 重设计后的 macOS 根布局: 自定义 TitleBar + Sidebar + Detail + BottomBar 四件套,
/// 不再依赖 NavigationSplitView。标题栏背景透明且内容延伸至顶部,导航和搜索由
/// `PMTitleBar` 绘制,窗口控制保留 AppKit 原生实现。
struct MacContentView: View {
    @State private var homeModel = MacHomeView.Model()
    @State private var listeningStatsModel = ListeningStatsScreen.Model()
    @State private var routeSwitch = MacRouteSwitch()
    @State private var sidebarCollapsed: Bool = false
    @State private var savedSidebarCollapsed: Bool = false
    @State private var pendingPlaybackRemovalIDs = Set<String>()
    @State private var isReconcilingPlaybackRemovals = false
    @State private var nowPlayingPresented = false
    @State private var queuePresented = false
    @State private var isWindowFullScreen = false
    @State private var hostWindow: NSWindow?
    @State private var searchText = ""
    @State private var songLocationRequest: SongLibraryLocationRequest?
    /// 等「有声」一栏的详情栈建好后要压进去的书; 详情容器取走后清空。
    @State private var spokenWordBookRequest: String?
    @State private var didRestorePersistedRoute = false
    @State private var preferences = MacUIPreferences.shared
    @State private var showNewPlaylist = false
    @State private var showSmartEditor = false
    @State private var showAIPlaylistEditor = false
    @State private var showInitialOnboarding = false
    @State private var newPlaylistName = ""
    @State private var newPlaylistDescription = ""
    /// Keep the one-tap lyrics scrape above `MacNowPlayingView`'s lifetime.
    /// The expanded player is removed from the view tree when it is collapsed;
    /// a task/state owned by that child can therefore lose its UI completion
    /// path halfway through a request. `MacContentView` stays mounted, so the
    /// scrape continues and publishes its result even while the player is
    /// collapsed.
    @State private var lyricsScrapeTask: Task<Void, Never>?
    @State private var isScrapingCurrentSongLyrics = false
    @State private var lyricsTranscriptionEditorTargetSong: Song?
    @State private var lyricsScrapeAlertMessage: String?
    @State private var showNoScraperSourceAlert = false
    /// 当前打开的工具弹框 (nil = 没开)。侧栏「工具」区点击设置它, sheet 关掉清空。
    @State private var activeTool: MacTool?
    @State private var showsRecommendationsPanel = false
    @State private var showsListeningStats = false
    /// 底栏「全屏播放」键开出来的效果面板,点哪一张就带着它进全屏播放。全屏播放页自己带一份。
    @State private var showsFullscreenEffectPicker = false
    /// 进全屏播放之前停在哪儿(播放页开没开、窗口本来是不是全屏、右侧面板)。退出时照着回去;
    /// 不是从「全屏播放」进的全屏(绿灯、系统菜单)没有这一份。只在事件里读写,body 不读。
    @State private var fullScreenPlayerReturnPoint: MacFullScreenPlayerPolicy.ReturnPoint?
    /// 刚请求窗口进系统全屏的时刻。窗口开始变全屏(willEnterFullScreen)时才把播放页装上,
    /// 过渡前不先露一下窗口版播放页。
    @State private var fullScreenPlayerEntryRequestedAt: Date?

    @Environment(\.openWindow) private var openWindow
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(ThemeService.self) private var theme
    @AppStorage("primuse.hasSeenOnboarding") private var hasSeenOnboarding = false
    /// 上次停在哪一页。直接读写偏好, 不挂 `@AppStorage`: 那样每换一页写一次, 整个主窗口就跟着重算一遍。
    private static let persistedRouteKey = "primuse.navigation.macRoute.v1"
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var fullscreenPlayerEffectRawValue = FullscreenPlayerEffect.defaultValue.rawValue

    @MainActor
    private func enqueuePlaybackReconciliation(removing songIDs: Set<String>) {
        let action = PlaybackLibraryMutationPolicy.action(
            queueSongIDs: player.queue.map(\.id),
            currentSongID: player.currentSong?.id,
            isLiveRadio: player.isLiveRadio,
            event: .songsRemoved(songIDs)
        )
        guard case let .removeSongs(relevantIDs) = action else { return }
        pendingPlaybackRemovalIDs.formUnion(relevantIDs)
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
                guard case let .removeSongs(stillRelevantIDs) = refreshedAction else { continue }
                await player.prepareQueueForRemovingSongs(withIDs: stillRelevantIDs)
            }
            if player.currentSong == nil { nowPlayingPresented = false }
        }
    }

    var body: some View {
        Group {
            // Stage 2: 资料库在主线程之外装载。就绪之前不渲染任何读库的界面 ——
            // 既不能闪 onboarding, 也不能闪"空资料库"状态。
            if library.isReady {
                mainContent
            } else {
                LibraryPreparingView()
            }
        }
        // Spotlight 送来的挂在最外层:冷启动时主界面还没挂上也接得住,先交给路由记着。
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            MacSystemActivityRouter.shared.handle(activity, route: "swiftui")
        }
        .onContinueUserActivity(CSQueryContinuationActionType) { activity in
            MacSystemActivityRouter.shared.handle(activity, route: "swiftui")
        }
        // 开着的窗口自己接,别为一次点按另开一个窗口。
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        // ⌃⌘F 与菜单栏的「全屏播放」:挂在最外层,资料库还在装载时也接得住。
        .onReceive(NotificationCenter.default.publisher(for: .primuseToggleFullScreenPlayer)) { note in
            toggleFullScreenPlayer(in: note.object as? NSWindow)
        }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if !isFullScreenNowPlaying {
                PMTitleBar(
                    searchText: $searchText,
                    sidebarCollapsed: $sidebarCollapsed,
                    routeSwitch: routeSwitch,
                    onSelectRoute: requestRoute,
                    isRecommendationsShown: showsRecommendationsPanel,
                    onToggleRecommendations: toggleRecommendationsPanel,
                    onOpenListeningStats: openListeningStats,
                    onOpenTool: { activeTool = $0 }
                )
            }

            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    MacSidebar(routeSwitch: routeSwitch, onSelectRoute: requestRoute)
                        .frame(width: preferences.sidebarWidth)
                        // 播放页开着时侧栏底色跟着染上封面颜色, 和播放页接得上。
                        .modifier(MacSidebarFollowsPlayerScope(isNowPlayingPresented: $nowPlayingPresented))
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ZStack {
                    MacDetailHost(
                        routeSwitch: routeSwitch,
                        homeModel: homeModel,
                        listeningStatsModel: listeningStatsModel,
                        searchText: $searchText,
                        songLocationRequest: $songLocationRequest,
                        spokenWordBookRequest: $spokenWordBookRequest,
                        onShowSongInLibrary: showSongInLibrary,
                        onOpenLibrarySongs: { selectRoute(.section(.songs)) }
                    )
                        .background(PMColor.bg.ignoresSafeArea())
                        // 挂在这里而不是 body 那条长修饰链上: 那条链再加一个
                        // onReceive 就超出类型检查的时间上限。
                        .onReceive(NotificationCenter.default.publisher(for: .primuseDetailOpenSpokenWordBook)) { note in
                            openSpokenWordBook(note.object as? String)
                        }
                        .onChange(of: SongLibraryNavigation.shared.pending, initial: true) { _, request in
                            guard let request else { return }
                            SongLibraryNavigation.shared.pending = nil
                            songLocationRequest = request
                            selectRoute(.section(.songs))
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .primuseRevealSearchResults)) { _ in
                            closeNowPlayingForSearch()
                        }
                        // 小组件上点播放键以外的地方: 打开电台、播客或有声书那一页。
                        .onChange(of: ListeningSpaceOpenRequest.shared.pending, initial: true) { _, pending in
                            guard pending != nil,
                                  let space = ListeningSpaceOpenRequest.shared.consume(),
                                  let section = LibrarySection(listeningSpace: space) else { return }
                            selectRoute(.section(section))
                        }
                        #if DEBUG
                        // 调试脚本的 `route:<页面>`: 锁屏的编译机上按不了侧栏, 由这里换页。
                        .onReceive(NotificationCenter.default.publisher(for: .primuseDebugSelectRoute)) { note in
                            // 和在侧栏点一下走同一条路, 量出来的就是点侧栏的耗时。
                            requestRoute((note.object as? String).flatMap(route(for:)) ?? .home)
                        }
                        #endif

                    MacStateSlot(value: $nowPlayingPresented) { isPresented in
                        if isPresented {
                            MacNowPlayingView(showsSidebar: !sidebarCollapsed, onClose: {
                                pmWithAnimation(.panel) {
                                    nowPlayingPresented = false
                                }
                            }, isScrapingCurrentSong: isScrapingCurrentSongLyrics,
                               canTranscribeAudio: canTranscribeCurrentSongAudio,
                               onScrapeCurrentSong: startCurrentSongLyricsScrape,
                               onTranscribeAudio: openCurrentSongAudioTranscriptionEditor,
                               onToggleQueue: {
                                   pmWithAnimation(.panel) {
                                       queuePresented.toggle()
                                       if queuePresented { showsRecommendationsPanel = false }
                                   }
                               },
                               hostIsFullScreen: isWindowFullScreen,
                               onExitFullScreen: { exitFullScreenPlayer(in: nil) })
                            // 播放页铺满全屏窗口(全屏效果、原生全屏双栏、全屏 MV)才算沉浸画面,播放时屏幕常亮
                            // 只在这时起作用;点绿灯进的资料库全屏没有播放页,不算。
                            .screenIdleImmersiveSurface(isWindowFullScreen)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .onAppear { homeModel.diagnostics.setCovered(true) }
                            .onDisappear { homeModel.diagnostics.setCovered(false) }
                        }
                    }
                    .zIndex(1)

                    if showsFullscreenEffectPicker {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { closeFullscreenEffectPicker() }
                            .accessibilityHidden(true)
                            .zIndex(2)

                        // 面板从底栏那个入口上方展开,跟着按钮走。
                        MacImmersiveEffectPicker(
                            selected: fullscreenPlayerEffect,
                            effects: FullscreenPlayerEffect.allCases,
                            palette: ImmersiveArtworkPalette(
                                primary: theme.accentColor,
                                secondary: theme.secondaryDarkAccent
                            ),
                            onSelect: { candidate in
                                // 选中哪一种就带着它直接进全屏播放,不用再按一次全屏。
                                enterFullScreenPlayer(in: nil, with: candidate)
                            },
                            onClose: { closeFullscreenEffectPicker() }
                        )
                        // 右边让出「更多」键和间距,面板右沿对齐全屏播放键。
                        .padding(.trailing, 58)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .transition(
                            .scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity)
                        )
                        .zIndex(3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(MacPanelCommandReceiver(
                    onOpenTool: { activeTool = $0 },
                    onToggleRecommendations: toggleRecommendationsPanel,
                    onOpenListeningStats: openListeningStats
                ))
                .modifier(MacSongListPrewarm())
                #if DEBUG
                .task {
                    // `PRIMUSE_DEBUG_MAC_PANEL`: 锁屏的编译机上点不了标题栏, 由这里打开。
                    let panel = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_MAC_PANEL"]
                    guard panel == "recommendations" || panel == "stats" else { return }
                    try? await Task.sleep(for: .seconds(6))
                    plog("🧪 DebugLaunchAutomation: open panel \(panel ?? "")")
                    if panel == "recommendations" {
                        toggleRecommendationsPanel()
                    } else {
                        openListeningStats()
                    }
                }
                #endif

                if queuePresented {
                    MacQueuePanel(onClose: {
                        pmWithAnimation(.panel) {
                            queuePresented = false
                        }
                    })
                    .frame(width: 380)
                    .transition(.move(edge: .trailing))
                } else if showsRecommendationsPanel {
                    // 和队列同一个位置, 一次只开一个: 左边照常能逛, 不盖住正在看的页。
                    MacRecommendationsPanel(onClose: toggleRecommendationsPanel)
                        .frame(width: 380)
                        .transition(.move(edge: .trailing))
                }
            }
            // 手柄放在整个 HStack 的顶层 overlay,保证跨进正文的右半边不会被
            // MacDetailContainer 里的 NSScrollView / NSClipView 抢走鼠标事件。
            .overlay(alignment: .leading) {
                if !sidebarCollapsed {
                    SidebarResizeHandle(preferences: preferences)
                        .frame(width: 10)
                        .frame(maxHeight: .infinity)
                        .offset(x: preferences.sidebarWidth - 5)
                }
            }
            // BottomBar 用 safeAreaInset 挂在内容 HStack 底部, 而不是当 VStack 的
            // 第三行 —— 后者会让底栏自带一条等高的窗口底色 (PMColor.bg) 横条, 浮动
            // 卡片的圆角和左右留白处透出的就是这条底色, 跟上方 sidebar 的玻璃色对不上,
            // 看着像卡片背后压了一个方块。改成 safeAreaInset 后 sidebar / detail 的
            // ignoresSafeArea 背景会一直延伸到窗口底部、铺到卡片背后, 圆角处透出的就是
            // 各自那一列的背景色, 卡片真正"浮"在内容上。
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isFullScreenNowPlaying {
                    MacStateSlot(value: $nowPlayingPresented) { isNowPlayingPresented in
                        MacBottomBar(
                            isExpanded: isNowPlayingPresented,
                            isQueueShown: queuePresented,
                            onToggleNowPlaying: {
                                pmWithAnimation(.panel) {
                                    nowPlayingPresented.toggle()
                                }
                            },
                            onToggleQueue: {
                                pmWithAnimation(.panel) {
                                    queuePresented.toggle()
                                    if queuePresented { showsRecommendationsPanel = false }
                                }
                            },
                            onMiniPlayer: {
                                PrimuseAppDelegate.shared?.toggleMiniPlayer()
                            },
                            onFullScreen: {
                                enterFullScreenPlayer(in: nil)
                            },
                            onPickFullscreenEffect: {
                                pmWithAnimation(.panel) {
                                    showsFullscreenEffectPicker.toggle()
                                }
                            },
                            isFullscreenEffectPickerShown: showsFullscreenEffectPicker
                        )
                    }
                }
            }
        }
        .songBatchRemovalFeedback()
        // 跟页面无关的提示条(批量删除、菜单里设为下一首):浮在底部播放栏上面。
        .pmToastHost(.shared, placement: .appRoot(fallbackClearance: PMSize.bottomBar + 12))
        .serverCatalogRefreshFeedback()
        .smartNudges()
        .macPlaybackErrorFeedback()
        .appleMusicSubscriptionOffer()
        .environment(\.pmAppearance, preferences.appearance)
        .background(PMColor.bg.ignoresSafeArea())
        .background(PMWindowChromeConfigurator())
        // 窗口态要把自绘的标题栏顶到窗口最上沿,所以忽略顶部安全区;全屏时不能再忽略。
        // 全屏窗口的内容区比屏幕矮一条菜单栏(诊断日志 🖼 enter-fullscreen:
        // content=1512×949 而屏幕 982),再往上扩展内容就比窗口高,顶部那排浮动按钮
        // 会被顶出上边界只剩半截 —— 被裁掉的正好是这 33 点。
        .ignoresSafeArea(.container, edges: isWindowFullScreen ? [] : .top)
        .pmLogFrame("root")
        .sheet(isPresented: $showInitialOnboarding) {
            OnboardingView()
                .frame(minWidth: 720, minHeight: 560)
        }
        .sheet(isPresented: $showsListeningStats) {
            MacListeningStatsSheet(model: listeningStatsModel)
        }
        .sheet(item: $activeTool) { tool in
            toolSheet(tool)
        }
        .sheet(item: $lyricsTranscriptionEditorTargetSong) { song in
            LyricsEditorSheet(song: song, autoStartsAudioTranscription: true) { updated in
                guard player.currentSong?.id == updated.id else { return }
                NotificationCenter.default.post(
                    name: .primuseLyricsDidChange,
                    object: updated.id
                )
            }
        }
        .sheet(isPresented: $showNewPlaylist) {
            MacNewPlaylistSheet(
                name: $newPlaylistName,
                description: $newPlaylistDescription,
                onCancel: {
                    newPlaylistName = ""
                    newPlaylistDescription = ""
                    showNewPlaylist = false
                },
                onCreate: { name in
                    _ = library.createPlaylist(name: name)
                    newPlaylistName = ""
                    newPlaylistDescription = ""
                    showNewPlaylist = false
                }
            )
        }
        .sheet(isPresented: $showSmartEditor) {
            SmartPlaylistEditorView(existing: nil)
        }
        .sheet(isPresented: $showAIPlaylistEditor) {
            AIPlaylistEditorView(existing: nil)
        }
        .modifier(MacServerSyncErrorAlerts())
        .alert(String(localized: "scrape_song"),
               isPresented: Binding(
                   get: { lyricsScrapeAlertMessage != nil },
                   set: { if !$0 { lyricsScrapeAlertMessage = nil } }
               )) {
            Button("done", role: .cancel) {}
        } message: {
            Text(lyricsScrapeAlertMessage ?? "")
        }
        .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
        .task {
            restorePersistedRouteIfNeeded()
            MainWindowOpener.register(openWindow)
            if !hasSeenOnboarding && sourcesStore.sources.isEmpty {
                hasSeenOnboarding = true
                showInitialOnboarding = true
            }
        }
        .background {
            MacAuthoritativeSongRemovalObserver(onSongsRemoved: enqueuePlaybackReconciliation)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseSidebarRequestNewPlaylist)) { _ in
            newPlaylistName = ""
            newPlaylistDescription = ""
            showNewPlaylist = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseSidebarRequestNewSmartPlaylist)) { _ in
            showSmartEditor = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseSidebarRequestNewAIPlaylist)) { _ in
            showAIPlaylistEditor = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseRequestExpandNowPlaying)) { note in
            let animated = note.userInfo?[PrimuseNowPlayingExpansion.animatedKey] as? Bool ?? true
            if animated {
                pmWithAnimation(.panel) {
                    nowPlayingPresented = true
                    queuePresented = false
                }
            } else {
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    nowPlayingPresented = true
                    queuePresented = false
                }
            }
        }
        // 播放页「更多」里的听歌记录:打开设置窗口的那一页(#358)。
        .onReceive(NotificationCenter.default.publisher(for: .primuseSelectScrobble)) { _ in
            SettingsWindowController.shared.show(tab: .scrobble)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseSelectPlaylists)) { _ in
            // 歌单总览页已移除 (侧栏已直接列出全部歌单 + 智能歌单)。删除当前歌单后
            // 回到首页, 而不是再跳那个不稳定的总览页。
            selectRoute(.home)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseSelectRadio)) { _ in
            selectRoute(.section(.radio))
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseSelectSpokenWord)) { note in
            // object 给了别的分类(首页「播客更新」的「全部」给 .podcasts)就跳那一项。
            selectRoute(.section(note.object as? LibrarySection ?? .spokenWord))
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseDetailOpenAlbum)) { note in
            guard note.object is Album else { return }
            nowPlayingPresented = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseDetailOpenArtist)) { note in
            guard note.object is Artist else { return }
            nowPlayingPresented = false
        }
        // 在 Spotlight 里点开的一项:歌直接放,专辑、艺人、歌单打开详情;「在 Primuse 中搜索」带着字进搜索页。
        // 收到的时候记在路由上(见 `MacSystemActivityRouter`),主界面这时一定已经挂上。
        .onChange(of: MacSystemActivityRouter.shared.pending, initial: true) { _, request in
            guard request != nil, let request = MacSystemActivityRouter.shared.consume() else { return }
            switch request {
            case .item(let item):
                openSpotlightItem(item)
            case .search(let query):
                searchText = query
                selectRoute(.search)
            }
        }
        .background {
            PMWindowResolver { window in
                hostWindow = window
            }
        }
        .modifier(MacWindowFullScreenObserver(
            isHostWindow: { $0 === hostWindow },
            onWillEnter: { windowWillEnterFullScreen() },
            onDidEnter: { windowDidEnterFullScreen() },
            onWillExit: { windowWillExitFullScreen() },
            onDidExit: { windowDidExitFullScreen() }
        ))
    }

    /// 工具弹框内容 —— 每个工具的 macBody 已经是自带 header/footer 的
    /// 整面板, 这里只负责按当前 `MacTool` 选一个塞进 sheet。
    @ViewBuilder
    private func toolSheet(_ tool: MacTool) -> some View {
        switch tool {
        case .lyricsConverter:
            LyricsFormatConverterView()
        case .duplicates:
            DuplicateSongsView()
        case .cacheSync:
            AudioCacheSyncView()
        case .deviceTransfer:
            WiFiTransferView()
        }
    }

    private var isFullScreenNowPlaying: Bool {
        isWindowFullScreen && nowPlayingPresented
    }

    private var fullscreenPlayerEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: fullscreenPlayerEffectRawValue) ?? .defaultValue
    }

    private func closeFullscreenEffectPicker() {
        pmWithAnimation(.panel) {
            showsFullscreenEffectPicker = false
        }
    }

    // MARK: - 全屏播放

    /// ⌃⌘F 与菜单栏:正在全屏播放就退出,否则进入。
    private func toggleFullScreenPlayer(in window: NSWindow?) {
        guard let window, hostWindow == nil || window === hostWindow else { return }
        guard library.isReady else {
            // 资料库还在装载,没有播放页可装:只切系统全屏。
            window.toggleFullScreen(nil)
            return
        }
        switch MacFullScreenPlayerPolicy.toggleAction(
            isWindowFullScreen: isWindowFullScreen,
            isPlayerExpanded: nowPlayingPresented
        ) {
        case .enter: enterFullScreenPlayer(in: window)
        case .exit: exitFullScreenPlayer(in: window)
        }
    }

    /// 进全屏播放:系统全屏加所选的全屏效果,一步到位。底栏全屏播放键、效果面板里点选、⌃⌘F、
    /// 菜单栏都走这里;带着 `effect` 进来时先换成它。窗口版不先展开播放页,等窗口开始变全屏
    /// (`windowWillEnterFullScreen`)才装上,过渡里看到的就是全屏播放页本身。
    private func enterFullScreenPlayer(in window: NSWindow?, with effect: FullscreenPlayerEffect? = nil) {
        if let effect {
            fullscreenPlayerEffectRawValue = effect.rawValue
            FullscreenPlayerEffectSync.shared.select(effect)
        }
        let current = MacFullScreenPlayerPolicy.ReturnPoint(
            windowWasFullScreen: isWindowFullScreen,
            playerWasExpanded: nowPlayingPresented,
            queueWasPresented: queuePresented,
            recommendationsWerePresented: showsRecommendationsPanel
        )
        if isWindowFullScreen {
            // 窗口本来就在全屏里(点绿灯进的资料库全屏):原地换上全屏播放页。
            fullScreenPlayerReturnPoint = MacFullScreenPlayerPolicy.returnPoint(
                existing: fullScreenPlayerReturnPoint,
                current: current,
                isWindowFullScreen: true
            )
            withoutAnimation { presentPlayerForFullScreen() }
            return
        }
        guard let window = window ?? hostWindow,
              // 正在进全屏的过渡里别再切一次,那会直接退回去。
              !window.styleMask.contains(.fullScreen) else { return }
        fullScreenPlayerReturnPoint = current
        fullScreenPlayerEntryRequestedAt = Date()
        // 面板这一轮先收起,下一轮再交给 AppKit 做全屏过渡:过渡开始时窗口里就没有面板了。
        withoutAnimation { showsFullscreenEffectPicker = false }
        // SwiftUI 的 WindowGroup 默认不带 .fullScreenPrimary,少了它 toggleFullScreen 静默无效。
        if !window.collectionBehavior.contains(.fullScreenPrimary) {
            window.collectionBehavior.insert(.fullScreenPrimary)
        }
        DispatchQueue.main.async { [weak window] in
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            window.toggleFullScreen(nil)
        }
    }

    /// 退出全屏播放:播放页左上角「退出全屏」、Esc、全屏 MV 的退出键、⌃⌘F、菜单栏都走这里;
    /// 窗口绿灯和系统菜单直接退出系统全屏,在 `windowWillExitFullScreen` 里收拾。
    private func exitFullScreenPlayer(in window: NSWindow?) {
        switch MacFullScreenPlayerPolicy.exitRoute(returnPoint: fullScreenPlayerReturnPoint) {
        case .stayInSystemFullScreen:
            // 进来之前就是资料库全屏:留在全屏,收起播放页回到资料库。
            guard let point = fullScreenPlayerReturnPoint else { return }
            fullScreenPlayerReturnPoint = nil
            withoutAnimation { restore(from: point) }
        case .leaveSystemFullScreen:
            // 宿主窗口正常情况下已经解析好了;万一还没有,找那个处于全屏的窗口兜底,
            // 退出这件事不能就这么点不动。
            guard let window = window ?? hostWindow ?? NSApp.windows.first(where: { $0.styleMask.contains(.fullScreen) }),
                  isWindowFullScreen || window.styleMask.contains(.fullScreen) else { return }
            // 进入时补过 `.fullScreenPrimary`,退出这一侧同样要补,否则窗口重新配置之后
            // 按钮和 Esc 走到这里都像是「没反应」。
            if !window.collectionBehavior.contains(.fullScreenPrimary) {
                window.collectionBehavior.insert(.fullScreenPrimary)
            }
            window.toggleFullScreen(nil)
        }
    }

    /// 全屏播放页铺满窗口:右侧的队列、推荐和底栏的效果面板都收起。
    private func presentPlayerForFullScreen() {
        nowPlayingPresented = true
        queuePresented = false
        showsRecommendationsPanel = false
        showsFullscreenEffectPicker = false
    }

    /// 回到进全屏播放之前那一页:从资料库进来的收起播放页,右侧面板照原样。
    private func restore(from point: MacFullScreenPlayerPolicy.ReturnPoint) {
        let restoration = MacFullScreenPlayerPolicy.restoration(for: point)
        if restoration.collapsesPlayer { nowPlayingPresented = false }
        queuePresented = restoration.showsQueue
        showsRecommendationsPanel = restoration.showsRecommendations
    }

    /// 换全屏播放的版式不带动画:它和窗口的全屏过渡是同一件事,再叠一层滑动只会两段动画抢在一起。
    private func withoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    /// 主窗口的全屏版式:标题栏、底栏让给播放页,侧栏收起(退出时还原)。
    private func adoptFullScreenLayout(animated: Bool) {
        guard !isWindowFullScreen else { return }
        isWindowFullScreen = true
        // 底栏连同它的效果入口在全屏里就消失了,面板不能留在屏幕上。
        showsFullscreenEffectPicker = false
        savedSidebarCollapsed = sidebarCollapsed
        if animated {
            pmWithAnimation(.panel) { sidebarCollapsed = true }
        } else {
            sidebarCollapsed = true
        }
    }

    private func adoptWindowedLayout(animated: Bool) {
        guard isWindowFullScreen else { return }
        isWindowFullScreen = false
        if animated {
            pmWithAnimation(.panel) { sidebarCollapsed = savedSidebarCollapsed }
        } else {
            sidebarCollapsed = savedSidebarCollapsed
        }
    }

    /// 窗口开始变全屏。是全屏播放请求的,这一刻把全屏播放页连同全屏版式一起装上(不带动画),
    /// 过渡里从资料库直接变成全屏播放页;绿灯、系统菜单进的全屏照旧等进完再换版式。
    private func windowWillEnterFullScreen() {
        let isPlayerEntry = MacFullScreenPlayerPolicy.isEntryRequestPending(
            requestedAt: fullScreenPlayerEntryRequestedAt,
            now: Date()
        )
        fullScreenPlayerEntryRequestedAt = nil
        guard isPlayerEntry else {
            // 不是从全屏播放进的:没有要回去的地方,上次没进成留下的那份也作废。
            fullScreenPlayerReturnPoint = nil
            return
        }
        withoutAnimation {
            adoptFullScreenLayout(animated: false)
            presentPlayerForFullScreen()
        }
    }

    private func windowDidEnterFullScreen() {
        // willEnterFullScreen 没收到时的兜底:请求还在就现在装上播放页。
        if MacFullScreenPlayerPolicy.isEntryRequestPending(
            requestedAt: fullScreenPlayerEntryRequestedAt,
            now: Date()
        ) {
            fullScreenPlayerEntryRequestedAt = nil
            withoutAnimation {
                adoptFullScreenLayout(animated: false)
                presentPlayerForFullScreen()
            }
        }
        adoptFullScreenLayout(animated: true)
    }

    /// 窗口开始退出全屏。全屏播放进来的,这一刻就换成退出后的样子(不带动画):从资料库进来的
    /// 收起播放页,不先退回窗口版播放页再让人自己关;侧栏和右侧面板也不等窗口回到原位再滑出来。
    private func windowWillExitFullScreen() {
        fullScreenPlayerEntryRequestedAt = nil
        guard let point = fullScreenPlayerReturnPoint else { return }
        fullScreenPlayerReturnPoint = nil
        withoutAnimation {
            restore(from: point)
            adoptWindowedLayout(animated: false)
        }
    }

    private func windowDidExitFullScreen() {
        fullScreenPlayerEntryRequestedAt = nil
        fullScreenPlayerReturnPoint = nil
        adoptWindowedLayout(animated: true)
    }

    private func startCurrentSongLyricsScrape() {
        guard lyricsScrapeTask == nil,
              let displayedSong = player.currentSong else { return }

        scraperSettings.performSingleSongScrapeAction(
            from: .macNowPlayingAutomaticLyrics,
            onProceed: { startCurrentSongLyricsScrapeWithEnabledSource(displayedSong) },
            onRequireSource: { showNoScraperSourceAlert = true }
        )
    }

    private func startCurrentSongLyricsScrapeWithEnabledSource(_ displayedSong: Song) {
        isScrapingCurrentSongLyrics = true
        lyricsScrapeTask = Task { @MainActor in
            defer {
                isScrapingCurrentSongLyrics = false
                lyricsScrapeTask = nil
            }

            do {
                let song: Song
                if displayedSong.sourceID == AppleMusicLibraryIdentity.sourceID {
                    song = AppServices.shared.appleMusicLibrary.canonicalLibrarySong(for: displayedSong)
                    if song.id != displayedSong.id {
                        _ = await MetadataAssetStore.shared.preserveLyricsAlias(
                            fromSongID: displayedSong.id,
                            toSongID: song.id
                        )
                        player.adoptCanonicalAppleMusicSong(song, replacing: displayedSong.id)
                    }
                } else {
                    song = displayedSong
                }

                let updatedSong: Song
                let scrapedLyrics: [LyricLine]?
                if song.sourceID == AppleMusicLibraryIdentity.sourceID {
                    let result = try await scraperService.scrapeOnlineLyricsOnly(song: song, in: library)
                    updatedSong = result.song
                    scrapedLyrics = result.lyrics
                } else {
                    let result = try await scraperService.scrapeSingle(song: song, in: library)
                    updatedSong = result.0
                    scrapedLyrics = result.2
                }

                CachedArtworkView.invalidateCache(for: updatedSong.id)
                if let oldRef = song.coverArtFileName {
                    CachedArtworkView.invalidateCache(for: oldRef)
                }
                player.syncSongMetadata(updatedSong)
                player.forceRefreshNowPlayingArtwork()

                // This notification is the view-independent completion path:
                // an expanded player reloads immediately; a collapsed player
                // reads the same song-ID cache on its next appearance.
                NotificationCenter.default.post(
                    name: .primuseLyricsDidChange,
                    object: updatedSong.id,
                    userInfo: lyricsChangeUserInfo(scrapedLyrics)
                )
                lyricsScrapeAlertMessage = String(localized: scrapedLyrics?.isEmpty == false
                    ? "scrape_song_success"
                    : "scrape_lyrics_not_found")
            } catch {
                lyricsScrapeAlertMessage = String(localized: "scrape_song_failed")
            }
        }
    }

    private func lyricsChangeUserInfo(
        _ lyrics: [LyricLine]?
    ) -> [AnyHashable: Any]? {
        guard let lyrics, !lyrics.isEmpty else { return nil }
        return ["lyrics": lyrics]
    }

    private var canTranscribeCurrentSongAudio: Bool {
        guard let song = player.currentSong else { return false }
        return intelligence.canTranscribeAudio(of: song)
    }

    private func openCurrentSongAudioTranscriptionEditor() {
        guard canTranscribeCurrentSongAudio,
              lyricsScrapeTask == nil,
              let song = player.currentSong else { return }
        lyricsTranscriptionEditorTargetSong = song
    }

    /// 播放页「转到这本书」。换栏会重建详情容器(`routeSwitch.navigationID`), 书不能
    /// 直接压栈, 交给新容器出现时取走。
    private func openSpokenWordBook(_ bookID: String?) {
        guard let bookID else { return }
        if case .section(.spokenWord) = routeSwitch.shown {
            // 已经在「有声」这一栏: 不重建容器, 由它自己把栈换成这本书。重建的话请求会被
            // 将要拆掉的旧容器先取走, 新容器里什么也没有, 停在书架上。
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                nowPlayingPresented = false
            }
            spokenWordBookRequest = bookID
            return
        }
        spokenWordBookRequest = bookID
        selectRoute(.section(.spokenWord))
    }

    /// 侧栏、标题栏上点了换页。分两步: 这一轮只换高亮、把旧页藏起来, 马上出一帧 ——
    /// 点下去立刻有反应; 新页要建几十到几百毫秒(曲库大时首页更久), 等这一帧交给屏幕
    /// 以后再建, 建好了淡入。一步做完的话, 建新页这段时间整个窗口定在旧页上, 侧栏高亮也
    /// 不动, 看着像先把新页加载完才切过去。
    private func requestRoute(_ route: MacRoute) {
        if route == .home { homeModel.diagnostics.navigationRequested() }
        #if DEBUG
        MacRouteTiming.begin(route)
        #endif
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if nowPlayingPresented { nowPlayingPresented = false }
            routeSwitch.requested = route
            routeSwitch.isSwitching = true
        }
        // 第二步还没轮到时又点了一项: 只建最后点的那页。
        let isScheduled = routeSwitch.pending != nil
        routeSwitch.pending = route
        guard !isScheduled else { return }
        MacFrameCommit.afterCurrentCommit {
            guard let route = routeSwitch.pending else { return }
            applyRoute(route)
        }
    }

    private func openSpotlightItem(_ item: SpotlightItem) {
        switch item {
        case .song(let id):
            guard library.visibleSong(id: id) != nil else { return }
            // 命中歌 + 整库剩下的拼起来当队列,跟 iOS 与 Siri 同款;只交 ID。
            var ids = [id]
            ids.reserveCapacity(library.visibleSongs.count)
            for song in library.visibleSongs where song.id != id { ids.append(song.id) }
            Task { await player.play(queueIDs: ids, startingAt: 0, caller: "Spotlight") }
        case .album(let id):
            guard let album = library.visibleAlbum(id: id) else { return }
            NotificationCenter.default.post(name: .primuseDetailOpenAlbum, object: album)
        case .artist(let id):
            guard let artist = library.visibleArtist(id: id) else { return }
            NotificationCenter.default.post(name: .primuseDetailOpenArtist, object: artist)
        case .playlist(let id):
            guard let playlist = library.playlists.first(where: { $0.id == id }) else { return }
            selectRoute(.playlist(playlist))
        }
    }

    /// 代码里换页(通知、「在资料库中显示」、恢复上次的页)。一步换完: 有的调用方在换页前
    /// 放了要交给新页的请求(定位到某首歌), 旧页多活一轮会先把它取走。
    private func selectRoute(_ route: MacRoute) {
        if route == .home { homeModel.diagnostics.navigationRequested() }
        #if DEBUG
        MacRouteTiming.begin(route)
        #endif
        applyRoute(route)
    }

    private func applyRoute(_ route: MacRoute) {
        #if DEBUG
        MacRouteTiming.markAfterCommit("page committed")
        #endif
        routeSwitch.pending = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            nowPlayingPresented = false
            routeSwitch.requested = route
            routeSwitch.isSwitching = false
            routeSwitch.shown = route
            // 直接目标 NavigationLink 的展示状态不在 path 内，侧栏导航需重建整栈。
            routeSwitch.navigationID = UUID()
        }
        UserDefaults.standard.set(persistenceID(for: route), forKey: Self.persistedRouteKey)
    }

    /// 在搜索栏里接着搜时, 盖在结果上的播放页先收起来, 和从别的栏开始搜一样。
    private func closeNowPlayingForSearch() {
        guard nowPlayingPresented else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            nowPlayingPresented = false
        }
    }

    private func openListeningStats() {
        #if DEBUG
        PMWindowChromeTrace.start("stats sheet")
        #endif
        showsListeningStats = true
    }

    private func toggleRecommendationsPanel() {
        pmWithAnimation(.panel) {
            showsRecommendationsPanel.toggle()
            if showsRecommendationsPanel { queuePresented = false }
        }
    }

    private func showSongInLibrary(_ song: Song) {
        songLocationRequest = SongLibraryLocationRequest(songID: song.id)
        selectRoute(.section(.songs))
    }

    private func restorePersistedRouteIfNeeded() {
        guard !didRestorePersistedRoute else { return }
        didRestorePersistedRoute = true
        // 听歌统计、智能推荐挪到了标题栏, 上次停在那两页的从首页开始。
        let restored = UserDefaults.standard.string(forKey: Self.persistedRouteKey).flatMap(route(for:)) ?? .home
        switch restored {
        case .stats, .section(.statistics), .section(.recommendations):
            selectRoute(.home)
        default:
            selectRoute(restored)
        }
    }

    private func persistenceID(for route: MacRoute) -> String {
        switch route {
        case .home: return "home"
        case .stats: return "stats"
        case .search: return "search"
        case .sources: return "sources"
        case .section(let section): return "section:\(section.rawValue)"
        case .liked: return "liked"
        case .playlist(let playlist): return "playlist:\(playlist.id)"
        case .smartPlaylist(let smartPlaylist): return "smart:\(smartPlaylist.id)"
        case .source(let sourceID): return "source:\(sourceID)"
        }
    }

    private func route(for persistedID: String) -> MacRoute? {
        switch persistedID {
        case "home": return .home
        case "stats": return .stats
        case "search": return .search
        case "sources": return .sources
        case "liked": return .liked
        default: break
        }

        if let rawValue = identifier(in: persistedID, after: "section:"),
           let section = LibrarySection(rawValue: rawValue) {
            return .section(section)
        }
        if let playlistID = identifier(in: persistedID, after: "playlist:") {
            guard let playlist = library.playlists.first(where: { $0.id == playlistID }) else {
                return .section(.playlists)
            }
            return .playlist(playlist)
        }
        if let smartPlaylistID = identifier(in: persistedID, after: "smart:") {
            guard let smartPlaylist = library.smartPlaylists.first(where: { $0.id == smartPlaylistID }) else {
                return .section(.playlists)
            }
            return .smartPlaylist(smartPlaylist)
        }
        if let sourceID = identifier(in: persistedID, after: "source:") {
            return sourcesStore.sources.contains(where: { $0.id == sourceID })
                ? .source(sourceID)
                : .sources
        }
        return nil
    }

    private func identifier(in value: String, after prefix: String) -> String? {
        guard value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }
}

/// 详情区。单独一层读 `MacRouteSwitch`, 换页时重建的只有这一块。
private struct MacDetailHost: View {
    let routeSwitch: MacRouteSwitch
    let homeModel: MacHomeView.Model
    let listeningStatsModel: ListeningStatsScreen.Model
    @Binding var searchText: String
    @Binding var songLocationRequest: SongLibraryLocationRequest?
    @Binding var spokenWordBookRequest: String?
    let onShowSongInLibrary: (Song) -> Void
    let onOpenLibrarySongs: () -> Void

    var body: some View {
        MacDetailContainer(
            route: routeSwitch.shown,
            homeModel: homeModel,
            listeningStatsModel: listeningStatsModel,
            searchText: $searchText,
            songLocationRequest: $songLocationRequest,
            spokenWordBookRequest: $spokenWordBookRequest,
            onShowSongInLibrary: onShowSongInLibrary,
            onOpenLibrarySongs: onOpenLibrarySongs
        )
            // 入场要挂在 `.id` 之前: `.id` 只重置它下面那棵子树, 修饰符
            // 写在后面的话 @State 留在 id 之上, 换页时不会重新入场。
            .pmPageEnter()
            .id(routeSwitch.navigationID)
            .modifier(MacRouteSwitchVeil(routeSwitch: routeSwitch))
    }
}

/// 换页第一步拿详情区底色把旧页盖住, 第二步新页从透明淡入(`pmPageEnter`)。中间这一两帧
/// 看到的是底色, 点下去马上看得出已经换走了; 盖着的这层也挡住了对旧页的点击。
///
/// 盖一层而不是改旧页的透明度或 `allowsHitTesting`: 那两样改的是整棵旧页子树, 专辑墙这种
/// 大页面光这一帧就要几十毫秒。
private struct MacRouteSwitchVeil: ViewModifier {
    let routeSwitch: MacRouteSwitch

    func body(content: Content) -> some View {
        content
            .overlay {
                if routeSwitch.isSwitching {
                    PMColor.bg
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                }
            }
    }
}

/// 只在自己的 body 里读绑定的值。主界面的 body 只递绑定、不读值：播放页的展开状态在主界面里读，
/// 每次展开、收起整个主界面连同详情页都要重算，压在展开的第一帧和收起的最后一帧上（同 iOS 的 #322）。
private struct MacStateSlot<Value, Content: View>: View {
    @Binding var value: Value
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        content(value)
    }
}

/// 主窗口进出系统全屏的四个时刻。只认宿主窗口发来的,多开窗口或设置等其他窗口的全屏不算。
/// 挂成一个修饰器:`mainContent` 那条修饰链再多几个 onReceive 就超出类型检查的时间上限。
/// 宿主窗口用闭包在收到时才读:`PMWindowResolver` 每轮更新都写一次 `hostWindow`,
/// body 要是读它,就会写一次重算一次、一直转下去。
private struct MacWindowFullScreenObserver: ViewModifier {
    let isHostWindow: (NSWindow) -> Bool
    let onWillEnter: () -> Void
    let onDidEnter: () -> Void
    let onWillExit: () -> Void
    let onDidExit: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
                if comesFromHost(note) { onWillEnter() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
                if comesFromHost(note) { onDidEnter() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
                if comesFromHost(note) { onWillExit() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
                if comesFromHost(note) { onDidExit() }
            }
    }

    private func comesFromHost(_ note: Notification) -> Bool {
        guard let sender = note.object as? NSWindow else { return false }
        return isHostWindow(sender)
    }
}

/// 把「播放页开着」交给侧栏底色(`macSidebarFollowsPlayer`)。开合状态只在这个修饰器里读,
/// 道理同 `MacStateSlot`: 主容器的 body 不读它, 开合播放页时不把整个主窗口连同侧栏各行重算一遍。
private struct MacSidebarFollowsPlayerScope: ViewModifier {
    @Binding var isNowPlayingPresented: Bool

    func body(content: Content) -> some View {
        content.environment(\.macSidebarFollowsPlayer, isNowPlayingPresented)
    }
}

// MARK: - Sidebar resize handle

/// 侧栏宽度拖拽手柄。设计稿里侧栏可在 180–300pt 之间拖动调整。
///
/// 用 AppKit NSView 而不是 SwiftUI DragGesture: 手柄需要自己持有鼠标追踪、
/// resize 光标和拖拽生命周期, 避免跟窗口拖动或 SwiftUI 命中测试互相抢事件。
/// 这里的 NSView 把 `mouseDownCanMoveWindow` 返回 false, 拖拽完全由它自己处理,
/// 实时改 `MacUIPreferences.sidebarWidth` (夹到 [min, max] 并持久化)。
private struct SidebarResizeHandle: NSViewRepresentable {
    let preferences: MacUIPreferences

    func makeNSView(context: Context) -> NSView {
        ResizeHandleNSView(preferences: preferences)
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    /// overlay 默认贴在侧栏 trailing 内侧, 右移半个宽度让 10pt 命中区跨在边界线上。
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: 10, height: proposal.height ?? 0)
    }
}

private final class ResizeHandleNSView: NSView {
    private let preferences: MacUIPreferences
    private var startWidth: CGFloat = 0
    private var startX: CGFloat = 0
    private var trackingAreaRef: NSTrackingArea?

    init(preferences: MacUIPreferences) {
        self.preferences = preferences
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { return nil }

    /// 关键: 落在手柄上的 mouseDown 不触发窗口移动。
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateCursorRects()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        invalidateCursorRects()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        startWidth = preferences.sidebarWidth
        startX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        // 用窗口坐标系里的绝对位移算, 避免 deltaX 累加在夹紧后产生死区。
        let dx = event.locationInWindow.x - startX
        preferences.sidebarWidth = min(
            PMSize.sidebarMax,
            max(PMSize.sidebarMin, startWidth + dx)
        )
    }

    private func invalidateCursorRects() {
        window?.invalidateCursorRects(for: self)
        updateTrackingAreas()
    }
}
private struct MacAuthoritativeSongRemovalObserver: View {
    let onSongsRemoved: @MainActor (Set<String>) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .primuseSongsRemoved).receive(on: DispatchQueue.main)) { note in
                let songIDs: Set<String>
                if let identifiers = note.userInfo?["songIDs"] as? Set<String> {
                    songIDs = identifiers
                } else {
                    let songs = note.userInfo?["songs"] as? [Song] ?? []
                    songIDs = Set(songs.map(\.id))
                }
                guard !songIDs.isEmpty else { return }
                onSongsRemoved(songIDs)
            }
    }
}

/// 菜单栏「工具」与「显示」里的几条命令发来的通知。单独成一个修饰器, 主容器那条长修饰链
/// 再加 onReceive 会超出类型检查的时间上限。
private struct MacPanelCommandReceiver: ViewModifier {
    let onOpenTool: (MacTool) -> Void
    let onToggleRecommendations: () -> Void
    let onOpenListeningStats: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .primuseOpenMacTool)) { note in
                guard let tool = (note.object as? String).flatMap(MacTool.init(rawValue:)) else { return }
                onOpenTool(tool)
            }
            .onReceive(NotificationCenter.default.publisher(for: .primuseToggleRecommendationsPanel)) { _ in
                onToggleRecommendations()
            }
            .onReceive(NotificationCenter.default.publisher(for: .primuseOpenListeningStats)) { _ in
                onOpenListeningStats()
            }
    }
}

/// 智能推荐面板: 从窗口右边滑进来, 和队列面板同一个位置、同一种底。
private struct MacRecommendationsPanel: View {
    let onClose: () -> Void

    var body: some View {
        AIRecommendationLibraryView(panelOnClose: onClose)
            .background {
                ZStack {
                    NSVisualEffectBackdrop(material: .sidebar, blending: .behindWindow)
                    Rectangle().fill(PMColor.sidebarGlass.opacity(0.6))
                }
                .ignoresSafeArea()
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(PMColor.divider).frame(width: 0.5).ignoresSafeArea(edges: .vertical)
            }
    }
}

/// 听歌统计弹框和整页共用内容，算好的结果跟着主窗口留着。
private struct MacListeningStatsSheet: View {
    let model: ListeningStatsScreen.Model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("stats_title")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Spacer()
                ListeningStatsStyleMenu()
                    .fixedSize()
                PMRoundBtn(icon: "xmark", size: 26, iconSize: 10, style: .glass, help: "close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 18)
            .frame(height: 50)
            Rectangle()
                .fill(PMColor.divider)
                .frame(height: 0.5)
            ListeningStatsScreen(model: model, showsStylePicker: false)
        }
        .frame(minWidth: 760, idealWidth: 860, maxWidth: 1000, minHeight: 560, idealHeight: 860)
        .background(PMColor.bg)
    }
}

/// 曲库变了之后, 在后台把「全部歌曲」按当前排序先排好放进缓存, 第一次点进去就不用现排。
/// iPhone 在资料库首页做同样的事 (`LibraryView`), Mac 没有那一页。
private struct MacSongListPrewarm: ViewModifier {
    @Environment(MusicLibrary.self) private var library

    func body(content: Content) -> some View {
        content.task(id: "\(library.visibleSongCollectionRevision)-\(library.songReplacementToken)") {
            let order = LibrarySongSortOrderPreference.load()
            // 播放次数、来源、是否已下载这几种排序用的是页面上现算的值, 预热对不上缓存。
            switch order.criterion {
            case .playCount, .source, .downloaded:
                return
            default:
                break
            }
            do {
                // 扫描时曲库一阵一阵地变, 等它停一下再排。
                try await Task.sleep(for: .milliseconds(1500))
            } catch {
                return
            }
            let version = SongListSnapshotVersion(
                collectionRevision: library.visibleSongCollectionRevision,
                replacementToken: library.songReplacementToken
            )
            // 和歌曲页同一份歌: 有声内容不在里面, 两边共用一个缓存键。
            let songs = library.musicSongs
            guard !songs.isEmpty, !Task.isCancelled else { return }
            _ = await SongListSnapshotStore.shared.snapshot(
                scopeKey: SongListSnapshotStore.libraryScopeKey,
                version: version,
                order: order,
                songs: songs
            )
        }
    }
}

#endif
