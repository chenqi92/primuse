#if os(tvOS) || TV_FOCUS_ROUTING_HARNESS
#if os(tvOS)
import SwiftUI
import PrimuseKit
#endif

// MARK: - Content focus routing

enum TVContentFocusTab: Equatable, Sendable {
    case library
    case nowPlaying
    case sources
    case search
    case other
}

enum TVNowPlayingFocusMode: Equatable, Sendable {
    case empty
    case liveRadio
    case song
}

enum TVNowPlayingFocusTarget: Hashable, Sendable {
    case previous
    case liveRadioPrimary
    case songPrimary
    case playPause
    case scrubber
    case next
}

enum TVContentFocusTarget: Equatable, Sendable {
    case libraryDefault
    case nowPlaying(TVNowPlayingFocusTarget)
    case sourcesPrimary
    case searchField
}

struct TVContentFocusRequest: Equatable, Sendable {
    let id: Int
    let target: TVContentFocusTarget
}

enum TVContentFocusRoutingPolicy {
    static func target(
        for tab: TVContentFocusTab,
        nowPlayingMode: TVNowPlayingFocusMode
    ) -> TVContentFocusTarget? {
        switch tab {
        case .library:
            return .libraryDefault
        case .nowPlaying:
            switch nowPlayingMode {
            case .empty:
                return nil
            case .liveRadio:
                return .nowPlaying(.liveRadioPrimary)
            case .song:
                return .nowPlaying(.songPrimary)
            }
        case .sources:
            return .sourcesPrimary
        case .search:
            return .searchField
        case .other:
            return nil
        }
    }
}

struct TVContentFocusRoutingState: Equatable, Sendable {
    private(set) var latestRequest: TVContentFocusRequest?

    private var nextRequestID = 0
    private var keepsContentFocusActive = false

    mutating func moveDown(
        from tab: TVContentFocusTab,
        nowPlayingMode: TVNowPlayingFocusMode
    ) -> TVContentFocusRequest? {
        guard let target = TVContentFocusRoutingPolicy.target(
            for: tab,
            nowPlayingMode: nowPlayingMode
        ) else {
            return nil
        }
        keepsContentFocusActive = true
        return issue(target)
    }

    mutating func seekInNowPlaying(mode: TVNowPlayingFocusMode) -> TVContentFocusRequest? {
        guard mode == .song else { return nil }
        keepsContentFocusActive = true
        return issue(.nowPlaying(.scrubber))
    }

    mutating func contentDidAppear(
        in tab: TVContentFocusTab,
        nowPlayingMode: TVNowPlayingFocusMode
    ) -> TVContentFocusRequest? {
        reissueIfActive(in: tab, nowPlayingMode: nowPlayingMode)
    }

    mutating func contentModeDidChange(
        in tab: TVContentFocusTab,
        nowPlayingMode: TVNowPlayingFocusMode
    ) -> TVContentFocusRequest? {
        reissueIfActive(in: tab, nowPlayingMode: nowPlayingMode)
    }

    mutating func returnToTabs() {
        keepsContentFocusActive = false
        latestRequest = nil
    }

    private mutating func reissueIfActive(
        in tab: TVContentFocusTab,
        nowPlayingMode: TVNowPlayingFocusMode
    ) -> TVContentFocusRequest? {
        guard keepsContentFocusActive else { return nil }
        if tab == .nowPlaying, nowPlayingMode == .song,
           latestRequest?.target == .nowPlaying(.scrubber) {
            return issue(.nowPlaying(.scrubber))
        }
        guard let target = TVContentFocusRoutingPolicy.target(
            for: tab,
            nowPlayingMode: nowPlayingMode
        ) else {
            latestRequest = nil
            return nil
        }
        return issue(target)
    }

    private mutating func issue(_ target: TVContentFocusTarget) -> TVContentFocusRequest {
        nextRequestID &+= 1
        let request = TVContentFocusRequest(id: nextRequestID, target: target)
        latestRequest = request
        return request
    }
}

#if os(tvOS)
#if DEBUG
/// 模拟器截图路由。环境变量适合首次启动，`-TVScreen <name>`/UserDefaults
/// 可跨 tvOS 场景恢复稳定生效，避免连续重启时系统复用上一页。
enum TVDebugLaunch {
    static var screen: String? {
        ProcessInfo.processInfo.environment["TV_SCREEN"]
            ?? UserDefaults.standard.string(forKey: "TVScreen")
    }

    /// 选目录页(TV_SCREEN=scan)截图用的预置勾选,多条用 | 分隔;空串表示
    /// 什么都没勾。不设时照常回填源里已存的目录。
    static var scanPreset: [String]? {
        ProcessInfo.processInfo.environment["TV_SCAN_PRESET"].map {
            $0.split(separator: "|").map(String.init)
        }
    }

    /// 选目录页截图用:打开后直接进入这个子目录(看「整个文件夹」行)。
    static var scanOpenPath: String? {
        guard let path = ProcessInfo.processInfo.environment["TV_SCAN_OPEN"],
              !path.isEmpty, path != "/" else { return nil }
        return path
    }
}
#endif

/// tvOS 根布局 — 顶部自定义 tab bar(Apple TV / Apple Music for tvOS 风) + 全屏内容。
/// 正在播放仍挂在顶栏上,但它是全屏页:只有按下才进,进去后顶栏收起,Menu 回到进来前
/// 的那一页。队列 / 选项 / 设置仍以全屏覆盖呈现。
struct TVRoot: View {
    /// 默认顺序与 iPhone / iPad / Mac 一致:首页、音乐、电台、有声,再是电视端自己的几页。
    /// 电台没有台、有声没有内容时这两页不出现(`ListeningSpaceVisibilityPolicy`);
    /// 用户还能在设置里调顺序、关掉某几页(`TVTabBarConfiguration`)。
    typealias Tab = TVTabBarItem

    @Environment(TVStore.self) private var store
    @State private var tab: Tab
    @AppStorage(TVTabBarConfiguration.storageKey) private var tabBarConfigurationRawValue = ""
    /// 被用户关掉的页也可能被带过去:设置里的「资料库 / 歌单 / 音乐源」、开始播放后切到
    /// 正在播放。停在那一页期间顶栏临时把它放回原位,离开就收起。
    @State private var transientTab: Tab?
    /// 用户把电台 / 有声排在最前面:冷启动时它们要等内容载入才出现,先停在第一个
    /// 不看内容的页,内容一到、用户还没动过就切过去。
    @State private var pendingLaunchTab: Tab?
    /// 进播放页之前停在哪一页:Menu 离开播放页时回到这里。
    @State private var tabBeforePlayer: Tab?
    @State private var libraryFilter: TVLibraryView.Filter = .albums
    /// 资料库网格上次停在哪张卡片;播放后回到资料库时由它恢复位置和焦点。
    @State private var libraryBrowseMemory = TVLibraryBrowseMemory()
    /// 首页从哪张卡片开始播放;播放页按 Menu 回到首页时焦点回到它。
    @State private var homeBrowseMemory = TVHomeBrowseMemory()
    /// 搜索页的查询词、结果与焦点;播放后回来不丢。
    @State private var searchMemory = TVSearchMemory()
    #if DEBUG
    /// 截图路由指定的是电台 / 有声页,但曲库和电台还在载入:等内容出现后再切过去,
    /// 否则会因为「这一页暂时不该显示」被送回首页。
    @State private var debugPendingSpaceTab: Tab?
    #endif
    @State private var showSettings = false
    @State private var showQueue = false
    @State private var showOptions = false
    @State private var verifiedPlaybackAuthentication: TVStore.PlaybackAuthentication?
    @State private var libraryFocusRequest = 0
    @State private var nowPlayingFocusRequest: TVContentFocusRequest?
    @State private var sourcesFocusRequest = 0
    @State private var searchFocusRequest: TVContentFocusRequest?
    @State private var playbackInteractionRequest = 0
    @State private var isRoutingToScrubber = false
    @State private var contentFocusRouting = TVContentFocusRoutingState()
    @State private var tabFocusRequest = 0
    @State private var isTabBarFocused = true
    @State private var suppressesFocusDrivenTabSelection = false
    @State private var modalFocusRecoveryGeneration = 0
    @State private var hasChildModalPresentation = false
    @State private var certificateTrustStore = TVServerCertificateTrustStore.shared

    init() {
        let configuration = TVTabBarConfiguration.decode(
            UserDefaults.standard.string(forKey: TVTabBarConfiguration.storageKey) ?? ""
        )
        // 播放页是全屏页,冷启动不停在它上面。
        let landingTab = configuration.order.first {
            configuration.isShown($0) && !$0.dependsOnContent && $0 != .nowPlaying
        } ?? .home
        if let first = configuration.order.first(where: configuration.isShown), first.dependsOnContent {
            _pendingLaunchTab = State(initialValue: first)
        }
        let initialTab: Tab
        #if DEBUG
        // 截图预览用:SIMCTL_CHILD_TV_SCREEN=<tab> 直接进入指定页。
        // 电台三页(radioHome / radioAdd / radioLibrary)配合 TV_DEMO_RADIO=1 注入演示电台。
        switch TVDebugLaunch.screen {
        case "library", "albumDetail", "libraryIndex", "albumReturn": initialTab = .library
        case "homeReturn", "homeAlbumReturn": initialTab = .home
        case "folderRescan":
            initialTab = .library
            _libraryFilter = State(initialValue: .folders)
        case "radio", "radioLibrary":
            initialTab = .home
            _debugPendingSpaceTab = State(initialValue: .radio)
        case "spokenWord":
            initialTab = .home
            _debugPendingSpaceTab = State(initialValue: .spokenWord)
        case "radioHome", "radioAdd": initialTab = .home
        case "playlists": initialTab = .playlists
        case "sources", "sourcePicker", "sourceForm", "credentials", "otp", "scan", "recycleBin":
            initialTab = .sources
        case "search": initialTab = .search
        default: initialTab = landingTab
        }
        #else
        initialTab = landingTab
        #endif
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        rootContent
            .modifier(TVReturnToTabsModifier(enabled: !isTabBarFocused) {
                returnFocusToTabs()
            })
            .modifier(TVRemoteTransportModifier(
                shortcutsEnabled: store.hasNowPlaying && rootModalPresentationCount == 0
                    && !hasChildModalPresentation && tab != .search
                    && certificateTrustStore.pendingRequest == nil
                    && certificateTrustStore.pendingInsecureHTTPRequest == nil
            ) { command in
                guard store.hasNowPlaying else { return }
                switch command {
                case .togglePlayback: store.togglePlayPause()
                case .nextTrack: store.transportForward()
                case .seek:
                    guard store.duration > 0,
                          let request = contentFocusRouting.seekInNowPlaying(mode: nowPlayingFocusMode) else { return }
                    isRoutingToScrubber = true
                    tab = .nowPlaying
                    applyContentFocusRequest(request)
                }
                playbackInteractionRequest &+= 1
            })
            .alert(
                PMString("ext.tv.certificate.title"),
                isPresented: Binding(
                    get: { certificateTrustStore.pendingRequest != nil },
                    set: { _ in }
                )
            ) {
                Button(PMString("ext.tv.certificate.trust"), role: .destructive) {
                    certificateTrustStore.resolvePendingRequest(approved: true)
                }
                Button(PMString("ext.tv.sources.cancel"), role: .cancel) {
                    certificateTrustStore.resolvePendingRequest(approved: false)
                }
            } message: {
                if let request = certificateTrustStore.pendingRequest {
                    Text(verbatim: PMString(
                        "ext.tv.certificate.message",
                        request.endpoint
                    ))
                }
            }
            .alert(
                PMString("ext.tv.http.title"),
                isPresented: Binding(
                    get: { certificateTrustStore.pendingInsecureHTTPRequest != nil },
                    set: { _ in }
                )
            ) {
                Button(PMString("ext.tv.http.allow"), role: .destructive) {
                    certificateTrustStore.resolvePendingInsecureHTTPRequest(approved: true)
                }
                Button(PMString("ext.tv.sources.cancel"), role: .cancel) {
                    certificateTrustStore.resolvePendingInsecureHTTPRequest(approved: false)
                }
            } message: {
                if let request = certificateTrustStore.pendingInsecureHTTPRequest {
                    switch request.purpose {
                    case .server:
                        Text(verbatim: PMString("ext.tv.http.message", request.endpoint))
                    case .radioPlaylist:
                        Text(verbatim: PMString("ext.tv.http.radioMessage", request.endpoint))
                    }
                }
            }
    }

    private var rootContent: some View {
        GeometryReader { _ in
            ZStack {
                TVColor.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    TVTabBar(
                        active: tab,
                        tabs: visibleTabs,
                        onSelect: selectTab,
                        // 焦点停在「正在播放」上往下走时,下面仍是当前那一页。
                        onContentDown: { _ in requestContentFocus(from: tab) },
                        focusRequest: tabFocusRequest,
                        allowsFocusDrivenSelection: !suppressesFocusDrivenTabSelection && !isRoutingToScrubber,
                        onFocusChanged: tabBarFocusChanged,
                        onSettings: { showSettings = true }
                    )
                    // 播放页全屏:顶栏让出高度并退出焦点,上键不会再误切到别的页。
                    // 不从层级里拿掉,离开播放页时它的焦点回调还要接得住。
                    .frame(height: hidesTabBar ? 0 : nil, alignment: .top)
                    .opacity(hidesTabBar ? 0 : 1)
                    .disabled(hidesTabBar)
                    .accessibilityHidden(hidesTabBar)
                    .zIndex(1)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.25), value: hidesTabBar)
            }
        }
        .onChange(of: rootModalPresentationCount) { _, count in
            modalActivityChanged(count > 0 || hasChildModalPresentation)
        }
        // 电台删空 / 有声内容没了 / 在设置里关掉了:那一页从顶栏消失,停在上面就回到
        // 顶栏的第一页。
        .onChange(of: visibleTabs) { _, tabs in
            #if DEBUG
            if let pending = debugPendingSpaceTab, tabs.contains(pending) {
                debugPendingSpaceTab = nil
                tab = pending
                return
            }
            #endif
            if let pending = pendingLaunchTab, tabs.contains(pending) {
                pendingLaunchTab = nil
                tab = pending
                // 焦点还停在顶栏原来那一项上:跟着挪过去,免得横移时又把页切回去。
                if isTabBarFocused { tabFocusRequest &+= 1 }
                return
            }
            if !tabs.contains(tab) { tab = tabs.first ?? .library }
        }
        .onChange(of: tab) { oldTab, newTab in
            if newTab == .nowPlaying, oldTab != .nowPlaying { tabBeforePlayer = oldTab }
            pendingLaunchTab = nil
            transientTab = tabBarConfiguration.isShown(newTab) ? nil : newTab
        }
        .onAppear {
            if !tabBarConfiguration.isShown(tab) { transientTab = tab }
        }
        .fullScreenCover(isPresented: $showSettings) {
            TVSettingsView(onNavigate: { tab = $0 }).environment(store)
        }
        .fullScreenCover(isPresented: $showQueue) {
            TVQueueView().environment(store)
        }
        .fullScreenCover(isPresented: $showOptions) {
            TVOptionsView().environment(store)
        }
        .fullScreenCover(item: Binding(
            get: {
                guard !showSettings, !showQueue, !showOptions, !hasChildModalPresentation,
                      certificateTrustStore.pendingRequest == nil,
                      certificateTrustStore.pendingInsecureHTTPRequest == nil else { return nil }
                return store.playbackAuthentication
            },
            set: { store.playbackAuthentication = $0 }
        ), onDismiss: {
            if let request = verifiedPlaybackAuthentication {
                verifiedPlaybackAuthentication = nil
                store.resumeAfterAuthentication(request)
            }
        }) { request in
            TVOTPEntryView(source: request.source, onVerified: {
                verifiedPlaybackAuthentication = request
            }).environment(store)
        }
        .task {
            #if DEBUG
            switch TVDebugLaunch.screen {
            case "nowPlaying", "playerShelf", "nowPlayingArtist":
                await waitForDemoContent(requireAlbum: true)
                if let album = store.albums.first { store.play(album: album) }
                tab = .nowPlaying
            case "nowPlayingDemo":   // 截图用:注入演示播放态+歌词,不走真实播放
                await waitForDemoContent()
                await store.loadDemoNowPlaying()
                tab = .nowPlaying
            case "lyricsTranslationDemo":
                await waitForDemoContent()
                if await store.loadLyricsTranslationDemo() {
                    tab = .nowPlaying
                }
            case "nowPlayingSongArtwork":
                await waitForDemoContent()
                if await store.loadDemoNowPlaying(preferSongArtwork: true) {
                    tab = .nowPlaying
                }
            case "queue":
                await waitForDemoContent()
                await store.loadDemoNowPlaying()
                showQueue = true
            case "options":
                await waitForDemoContent()
                await store.loadDemoNowPlaying()
                showOptions = true
            case "immersivePlayer", "immersivePicker":
                await waitForDemoContent()
                await store.loadDemoNowPlaying()
                tab = .nowPlaying
            case "settings", "effectPicker", "themePicker": showSettings = true
            case "albumReturn":
                // 模拟「专辑页里点一首播放 → 播放页按 Menu」:应回到专辑页、焦点在那一首,
                // 再按 Menu 才回海报墙。
                await waitForDemoContent(requireAlbum: true)
                guard let album = store.albums.first else { break }
                let songs = store.songs(forAlbum: album.id)
                guard let song = songs.last else { break }
                libraryBrowseMemory.albumID = album.id
                libraryBrowseMemory.albumDetailID = album.id
                libraryBrowseMemory.albumDetailSongID = song.id
                guard store.play(song, in: songs.map(\.id)) else { break }
                tab = .nowPlaying
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                leavePlayer()
            case "homeReturn", "homeAlbumReturn":
                // 模拟「首页『最近添加』第 4 张专辑起播 → 播放页按 Menu」:焦点应回到那张卡片
                // (日志 `TV home return focus=card`);homeAlbumReturn 走「专辑页里点一首」,
                // 回来应先重开专辑页、焦点在那一首(`TV album detail reopened focus=track`)。
                await waitForDemoContent(requireAlbum: true)
                let added = store.recentlyAddedAlbums
                guard let album = added.dropFirst(3).first ?? added.first else { break }
                let songIDs = store.songIDs(forAlbum: album.id)
                homeBrowseMemory.cardID = "added:" + album.id
                if TVDebugLaunch.screen == "homeAlbumReturn" {
                    guard let songID = songIDs.last, let song = store.song(songID),
                          store.play(song, in: songIDs) else { break }
                    homeBrowseMemory.albumDetailID = album.id
                    homeBrowseMemory.albumDetailSongID = songID
                } else {
                    store.play(album: album)
                }
                tab = .nowPlaying
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                leavePlayer()
            case "searchReturn":
                // 模拟「搜索 → 点第 3 条歌曲结果起播 → 播放页按 Menu」:查询词和结果应原样还在、
                // 焦点回到那一条(日志 `TV search return focus=result`)。查询词可用 TV_SEARCH_QUERY 指定。
                await waitForDemoContent()
                let query = ProcessInfo.processInfo.environment["TV_SEARCH_QUERY"]
                    ?? store.songs.first.map { String($0.title.prefix(3)) } ?? "a"
                let hits = await store.searchResults(query).songs
                guard let hit = hits.dropFirst(2).first ?? hits.first else { break }
                // 搜索页带着查询词建出来、自己搜完(结果记进 searchMemory),再从那条结果起播。
                searchMemory.query = query
                tab = .search
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                searchMemory.lastFocusedResultID = "song:" + hit.id
                store.play(hit.song)
                tab = .nowPlaying
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                leavePlayer()
            case "libraryAnchor":
                // 模拟「播放专辑 → 回到资料库 → 按下键」:资料库在记住第 42 张专辑之后才建出来。
                await waitForDemoContent(requireAlbum: true)
                guard !store.albums.isEmpty else { break }
                libraryBrowseMemory.albumID = store.albums[min(41, store.albums.count - 1)].id
                tab = .library
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                requestContentFocus(from: .library)
            case "radio", "radioLibrary", "spokenWord":
                if let pending = debugPendingSpaceTab, visibleTabs.contains(pending) {
                    debugPendingSpaceTab = nil
                    tab = pending
                }
            default: break
            }
            #endif
        }
    }

    #if DEBUG
    private func waitForDemoContent(requireAlbum: Bool = false) async {
        if TVDebugLaunch.screen == "immersivePlayer",
           ProcessInfo.processInfo.environment["TV_IMMERSIVE_EFFECT"] != nil {
            return
        }
        var tries = 0
        while (requireAlbum ? store.albums.isEmpty : store.songs.isEmpty) && tries < 25 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            tries += 1
        }
    }
    #endif

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .home:
            TVHomeView(
                browseMemory: homeBrowseMemory,
                onReturnToTabs: returnFocusToTabs,
                openPlayer: { tab = .nowPlaying },
                openRadioLibrary: { tab = .radio },
                onModalPresentationChanged: childModalPresentationChanged
            )
        case .library:
            TVLibraryView(
                openPlayer: { tab = .nowPlaying },
                onReturnToTabs: returnFocusToTabs,
                onModalActivityChanged: childModalActivityChanged,
                filter: $libraryFilter,
                focusRequest: libraryFocusRequest,
                browseMemory: libraryBrowseMemory
            )
        case .radio:
            TVRadioPageView(
                openPlayer: { tab = .nowPlaying },
                onModalActivityChanged: childModalActivityChanged,
                onModalPresentationChanged: childModalPresentationChanged
            )
        case .spokenWord:
            TVSpokenWordView(
                openPlayer: { tab = .nowPlaying },
                onModalActivityChanged: childModalActivityChanged
            )
        case .nowPlaying:
            TVNowPlayingView(
                isTabContent: true,
                focusRequest: nowPlayingFocusRequest,
                interactionRequest: playbackInteractionRequest,
                onContentAppeared: restoreNowPlayingFocus,
                onContentModeChanged: retargetNowPlayingFocus,
                onProgressFocused: { isRoutingToScrubber = false },
                onReturnToTabs: leavePlayer,
                onModalActivityChanged: childModalActivityChanged
            )
        case .playlists: TVPlaylistsView(openPlayer: { tab = .nowPlaying })
        case .sources:
            TVSourcesView(
                focusRequest: sourcesFocusRequest,
                onModalActivityChanged: childModalActivityChanged
            )
        case .search:
            TVSearchView(
                openPlayer: { tab = .nowPlaying },
                focusRequest: searchFocusRequest,
                onModalActivityChanged: childModalActivityChanged,
                memory: searchMemory,
                onReturnToTabs: returnFocusToTabs
            )
        }
    }

    private var tabBarConfiguration: TVTabBarConfiguration {
        TVTabBarConfiguration.decode(tabBarConfigurationRawValue)
    }

    /// 顶栏上出现哪些页、什么顺序:按用户在设置里的排法,电台、有声只在有内容时出现;
    /// 被带到一个关掉的页时,临时把它插回用户顺序里的位置。
    private var visibleTabs: [Tab] {
        let spaces = ListeningSpaceVisibilityPolicy.visibleSpaces(
            hasRadioStations: !store.radioStations.isEmpty,
            hasSpokenWord: !store.library.spokenWordSongs.isEmpty
        )
        let isAvailable: (Tab) -> Bool = { item in
            switch item {
            case .radio: return spaces.contains(.radio)
            case .spokenWord: return spaces.contains(.spokenWord)
            default: return true
            }
        }
        let configuration = tabBarConfiguration
        var tabs = configuration.visibleItems(isAvailable: isAvailable)
        if let transientTab, !tabs.contains(transientTab), isAvailable(transientTab) {
            let rank = { (item: Tab) in configuration.order.firstIndex(of: item) ?? 0 }
            let insertAt = tabs.firstIndex { rank($0) > rank(transientTab) } ?? tabs.endIndex
            tabs.insert(transientTab, at: insertAt)
        }
        return tabs
    }

    /// 正在播放时播放页占满全屏;没在播放时还是普通一页(空状态),顶栏照常。
    private var hidesTabBar: Bool {
        tab == .nowPlaying && store.hasNowPlaying
    }

    private func selectTab(_ item: Tab) {
        tab = item
        guard item == .nowPlaying, store.hasNowPlaying else { return }
        // 顶栏随即收起,焦点要明确送进播放页(封面)。
        Task { @MainActor in
            await Task.yield()
            requestContentFocus(from: .nowPlaying)
        }
    }

    /// 播放页上的 Menu:回到进来之前那一页。资料库、首页、搜索把焦点放回起播的那张卡片 /
    /// 那条结果(从专辑页起播的先回专辑页),其余页面落在顶栏的当前项上(和在那一页按 Menu 的落点一致)。
    private func leavePlayer() {
        guard hidesTabBar else {
            returnFocusToTabs()
            return
        }
        let tabs = visibleTabs.filter { $0 != .nowPlaying }
        let destination = tabBeforePlayer.flatMap { tabs.contains($0) ? $0 : nil }
            ?? tabs.first ?? .home
        isRoutingToScrubber = false
        contentFocusRouting.returnToTabs()
        nowPlayingFocusRequest = nil
        // 顶栏重新可用的那一刻焦点可能先落在它的某一项上,别让这一下把页面切走。
        suppressesFocusDrivenTabSelection = true
        // 从资料库的专辑页起播的:回到资料库时先回那张专辑页(见 TVLibraryBrowseMemory)。
        libraryBrowseMemory.restoresAlbumDetail = destination == .library
        // 首页、搜索页出现时自己把焦点放回去(见 TVHomeBrowseMemory / TVSearchMemory),
        // 这里就不再把焦点送回顶栏;记不住的时候照旧回顶栏。
        homeBrowseMemory.restoresAfterPlayer = destination == .home && homeBrowseMemory.hasReturnTarget
        searchMemory.restoresAfterPlayer = destination == .search && searchMemory.hasReturnTarget
        let pageRestoresFocus = homeBrowseMemory.restoresAfterPlayer || searchMemory.restoresAfterPlayer
        // 进播放页之前那次「从顶栏下到输入框」的请求还挂着,搜索页一出现就会把焦点抢到输入框。
        searchFocusRequest = nil
        tab = destination
        Task { @MainActor in
            await Task.yield()
            if destination == .library {
                requestContentFocus(from: .library)
            } else if !pageRestoresFocus {
                tabFocusRequest &+= 1
            }
            await Task.yield()
            suppressesFocusDrivenTabSelection = false
        }
    }

    private var nowPlayingFocusMode: TVNowPlayingFocusMode {
        guard store.hasNowPlaying else { return .empty }
        return store.isLiveRadio ? .liveRadio : .song
    }

    private var rootModalPresentationCount: Int {
        [
            showSettings,
            showQueue,
            showOptions,
            store.playbackAuthentication != nil,
            certificateTrustStore.pendingRequest != nil,
            certificateTrustStore.pendingInsecureHTTPRequest != nil,
        ].filter { $0 }.count
    }

    /// `restoresContentFocus` 为 false 时弹层关闭后不改焦点,只在收起期间压住顶栏的
    /// 焦点换页 —— 焦点由弹出它的那一页自己放回。
    private func modalActivityChanged(_ active: Bool, restoresContentFocus: Bool = true) {
        modalFocusRecoveryGeneration &+= 1
        let generation = modalFocusRecoveryGeneration
        suppressesFocusDrivenTabSelection = true
        guard !active else { return }

        Task { @MainActor in
            await Task.yield()
            guard generation == modalFocusRecoveryGeneration else { return }
            if restoresContentFocus {
                if TVContentFocusRoutingPolicy.target(
                    for: focusRoutingTab(tab),
                    nowPlayingMode: nowPlayingFocusMode
                ) != nil {
                    requestContentFocus(from: tab)
                } else {
                    returnFocusToTabs()
                }
            }
            await Task.yield()
            guard generation == modalFocusRecoveryGeneration else { return }
            suppressesFocusDrivenTabSelection = false
        }
    }

    private func childModalActivityChanged(_ active: Bool) {
        hasChildModalPresentation = active
        modalActivityChanged(active || rootModalPresentationCount > 0)
    }

    /// 电台卡片的重命名 / 删除确认、首页的添加电台:关闭后焦点该回到原卡片或删掉那张的
    /// 邻居,这由那一页自己放。这里只登记弹层在不在(停掉播放快捷键、压住焦点换页),
    /// 关闭时不再把焦点送回顶栏或筛选行,否则会盖掉那一页放好的焦点。
    private func childModalPresentationChanged(_ active: Bool) {
        hasChildModalPresentation = active
        modalActivityChanged(
            active || rootModalPresentationCount > 0,
            restoresContentFocus: false
        )
    }

    private func requestContentFocus(from tab: Tab) {
        guard let request = contentFocusRouting.moveDown(
            from: focusRoutingTab(tab),
            nowPlayingMode: nowPlayingFocusMode
        ) else { return }
        applyContentFocusRequest(request)
    }

    private func restoreNowPlayingFocus(_ mode: TVNowPlayingFocusMode) {
        guard let request = contentFocusRouting.contentDidAppear(
            in: .nowPlaying,
            nowPlayingMode: mode
        ) else { return }
        applyContentFocusRequest(request)
    }

    private func retargetNowPlayingFocus(_ mode: TVNowPlayingFocusMode) {
        guard let request = contentFocusRouting.contentModeDidChange(
            in: .nowPlaying,
            nowPlayingMode: mode
        ) else { return }
        applyContentFocusRequest(request)
    }

    private func returnFocusToTabs() {
        isRoutingToScrubber = false
        contentFocusRouting.returnToTabs()
        nowPlayingFocusRequest = nil
        searchFocusRequest = nil
        tabFocusRequest &+= 1
    }

    private func tabBarFocusChanged(_ focused: Bool) {
        isTabBarFocused = focused
        if focused {
            playbackInteractionRequest &+= 1
        }
        guard focused, !suppressesFocusDrivenTabSelection, !isRoutingToScrubber else { return }
        // A horizontal tab transition is still tab-bar navigation. Clear any
        // previous content route so a newly appeared page cannot reclaim focus
        // until the user explicitly moves down again.
        contentFocusRouting.returnToTabs()
        nowPlayingFocusRequest = nil
        searchFocusRequest = nil
    }

    private func applyContentFocusRequest(_ request: TVContentFocusRequest) {
        switch request.target {
        case .libraryDefault:
            libraryFocusRequest = request.id
        case .nowPlaying:
            nowPlayingFocusRequest = request
        case .sourcesPrimary:
            sourcesFocusRequest = request.id
        case .searchField:
            searchFocusRequest = request
        }
    }

    private func focusRoutingTab(_ tab: Tab) -> TVContentFocusTab {
        switch tab {
        case .library: return .library
        case .nowPlaying: return .nowPlaying
        case .sources: return .sources
        case .search: return .search
        default: return .other
        }
    }
}

enum TVTabFocusSelectionPolicy {
    static func selection(
        focused: TVRoot.Tab?,
        active: TVRoot.Tab,
        allowsFocusDrivenSelection: Bool
    ) -> TVRoot.Tab? {
        guard allowsFocusDrivenSelection,
              let focused,
              focused != active,
              // 正在播放是全屏页:焦点横扫顶栏时不能把人拽进去,只有按下才进。
              focused != .nowPlaying else {
            return nil
        }
        return focused
    }
}

enum TVTabBarFocusTarget: Hashable {
    case tab(TVRoot.Tab)
    case settings

    var tab: TVRoot.Tab? {
        switch self {
        case let .tab(tab): return tab
        case .settings: return nil
        }
    }
}

/// tvOS 会按几何位置选择顶部栏入口；首次进入时收束到当前 tab，栏内横移不受影响。
enum TVTabBarEntryFocusPolicy {
    static func correctedTarget(
        previous: TVTabBarFocusTarget?,
        focused: TVTabBarFocusTarget?,
        active: TVRoot.Tab
    ) -> TVTabBarFocusTarget? {
        guard previous == nil,
              let focused,
              focused != .tab(active) else {
            return nil
        }
        return .tab(active)
    }
}

// MARK: - 顶部 tab bar

extension TVTabBarItem {
    /// 顶栏和设置里「顶栏菜单」共用的名字。
    var tvTitle: String {
        switch self {
        case .home: return PMString("ext.tv.nav.home")
        case .library: return String(localized: "listening_space_music")
        case .radio: return PMString("ext.tv.radio.title")
        case .spokenWord: return String(localized: "listening_space_spoken_word")
        case .nowPlaying: return PMString("ext.tv.nav.nowPlaying")
        case .playlists: return PMString("ext.tv.nav.playlists")
        case .sources: return PMString("ext.tv.nav.sources")
        case .search: return PMString("ext.tv.nav.search")
        }
    }

    var tvIcon: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "music.note"
        case .radio: return "radio.fill"
        case .spokenWord: return "books.vertical.fill"
        case .nowPlaying: return "play.circle.fill"
        case .playlists: return "music.note.list"
        case .sources: return "server.rack"
        case .search: return "magnifyingglass"
        }
    }
}

struct TVTabBar: View {
    let active: TVRoot.Tab
    /// 当前该出现的页(电台 / 有声按有无内容增减),顺序即显示顺序。
    var tabs: [TVRoot.Tab] = [.home, .library, .nowPlaying, .playlists, .sources, .search]
    var onSelect: (TVRoot.Tab) -> Void
    var onContentDown: (TVRoot.Tab) -> Void
    var focusRequest: Int
    var allowsFocusDrivenSelection = true
    var onFocusChanged: (Bool) -> Void
    var onSettings: () -> Void
    @FocusState private var focusedTarget: TVTabBarFocusTarget?
    @State private var pendingProgrammaticFocusTarget: TVTabBarFocusTarget?

    private var debugFocusTab: TVRoot.Tab? {
        #if DEBUG
        // rawValue 与原来的截图参数一一对应:home / library / radio / spokenWord / ...
        ProcessInfo.processInfo.environment["TV_FOCUS_TAB"].flatMap(TVRoot.Tab.init(rawValue:))
        #else
        return nil
        #endif
    }

    var body: some View {
        HStack(spacing: 40) {
            // 应用内标识跟随 TV 品牌色；主屏幕仍使用完整分层 App 图标。
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(TVColor.brand.opacity(0.18))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image("BrandGlyph")
                            .renderingMode(.template)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .foregroundStyle(TVColor.brand)
                            .padding(10)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(TVColor.brand.opacity(0.34), lineWidth: 1)
                    }
                    .shadow(color: TVColor.brand.opacity(0.28), radius: 12, y: 6)
                Text(verbatim: PMString("ext.tv.appName"))
                    .tvFont(.eyebrow)
                    .lineLimit(1)
                    .foregroundStyle(TVColor.text)
            }

            HStack(spacing: 8) {
                ForEach(tabs, id: \.self) { item in
                    TVTabItem(
                        label: item.tvTitle,
                        isActive: item == active,
                        isFocused: focusedTarget == .tab(item)
                    ) {
                        onSelect(item)
                    }
                    .focused($focusedTarget, equals: .tab(item))
                    .onMoveCommand { direction in
                        if direction == .down {
                            onContentDown(item)
                        }
                    }
                }
            }
            .focusSection()

            Spacer(minLength: 0)

            // 设置入口(原账户头像改为设置按钮)
            TVSettingsButton(
                isFocused: focusedTarget == .settings,
                action: onSettings
            )
            .focused($focusedTarget, equals: .settings)
        }
        .onChange(of: focusedTarget) { previous, focused in
            onFocusChanged(focused != nil)
            let bypassesEntryCorrection = focused != nil
                && focused == pendingProgrammaticFocusTarget
            pendingProgrammaticFocusTarget = nil
            if allowsFocusDrivenSelection, !bypassesEntryCorrection,
               let corrected = TVTabBarEntryFocusPolicy.correctedTarget(
                previous: previous,
                focused: focused,
                active: active
            ) {
                focusedTarget = corrected
                return
            }
            if let selection = TVTabFocusSelectionPolicy.selection(
                focused: focused?.tab,
                active: active,
                allowsFocusDrivenSelection: allowsFocusDrivenSelection
            ) {
                onSelect(selection)
            }
        }
        .onChange(of: focusRequest) {
            focusedTarget = .tab(active)
        }
        .onAppear {
            #if DEBUG
            if let debugFocusTab {
                let target = TVTabBarFocusTarget.tab(debugFocusTab)
                pendingProgrammaticFocusTarget = target
                focusedTarget = target
            }
            #endif
        }
        .padding(.horizontal, TVSpace.pageH)
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [TVColor.chrome, TVColor.chrome.opacity(0.45), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
        .focusSection()
    }
}

private struct TVSettingsButton: View {
    let isFocused: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isFocused ? TVColor.onBrand : TVColor.text)
                .frame(width: 56, height: 56)
                .background(isFocused ? AnyShapeStyle(TVColor.brand)
                                      : AnyShapeStyle(TVColor.surfaceStrong), in: Circle())
                .tvFocusRing(isFocused, radius: 28, scale: 1.08, lift: 0)
        }
        .buttonStyle(TVBareButtonStyle())
        .focusEffectDisabled()
    }
}

private struct TVTabItem: View {
    let label: String
    let isActive: Bool
    let isFocused: Bool
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Text(label)
                .tvFont(.rowTitle, weight: isActive ? .bold : .medium)
                .lineLimit(1).minimumScaleFactor(0.85)
                .foregroundStyle(isFocused ? TVColor.bg : (isActive ? TVColor.text : TVColor.textMuted))
                .padding(.horizontal, 24).padding(.vertical, 10)
                .background(isFocused ? TVColor.text : .clear,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: isFocused ? TVColor.focusShadow.opacity(0.45) : .clear,
                        radius: 10, y: 4)
                .scaleEffect(isFocused && !reduceMotion ? 1.04 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isFocused)
        }
        .buttonStyle(TVBareButtonStyle())
        .focusEffectDisabled()
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

private struct TVReturnToTabsModifier: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        content.onExitCommand(perform: enabled ? action : nil)
    }
}

// MARK: - 底部「正在播放」条

struct TVBottomBar: View {
    @Environment(TVStore.self) private var store
    var openPlayer: () -> Void
    @FocusState private var focused: Bool

    @ViewBuilder
    var body: some View {
        if store.hasNowPlaying { bar }   // 没有正在播放时不显示底部条
    }

    private var bar: some View {
        let np = store.nowPlaying
        return HStack(spacing: 16) {
            Button(action: openPlayer) {
                HStack(spacing: 24) {
                    bottomArtwork(np)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(np.title).tvFont(.rowTitle)
                            .foregroundStyle(TVColor.text).lineLimit(1)
                        Text(store.isLiveRadio ? np.artist : "\(np.artist) · \(np.album)")
                            .tvFont(.meta)
                            .foregroundStyle(TVColor.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if store.isLiveRadio {
                        HStack(spacing: 9) {
                            Circle().fill(Color.red).frame(width: 10, height: 10)
                            Text(PMString("ext.tv.radio.live"))
                                .tvFont(.meta, weight: .bold)
                            if store.currentTime > 0 {
                                Text("· \(TVFmt.time(store.currentTime))")
                                    .tvFont(.meta, design: .monospaced)
                            }
                        }
                        .foregroundStyle(TVColor.textMuted)
                        .frame(width: 460, alignment: .trailing)
                    } else {
                        VStack(spacing: 6) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(TVColor.divider).frame(height: 4)
                                    Capsule().fill(np.tint)
                                        .frame(width: geo.size.width * progress, height: 4)
                                }
                            }
                            .frame(height: 4)
                            HStack {
                                Text(TVFmt.time(store.currentTime))
                                Spacer()
                                Text(TVFmt.time(store.duration))
                            }
                            .tvFont(.meta, design: .monospaced)
                            .foregroundStyle(TVColor.textFaint)
                        }
                        .frame(width: 460)
                    }
                }
                .padding(.leading, TVSpace.pageH)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 72)
                .background(focused ? TVColor.surfaceSubtle : .clear)
            }
            .buttonStyle(TVBareButtonStyle())
            .focused($focused)
            .focusEffectDisabled()

            // 独立的播放/暂停 + 下一首键(在底部条直接控,不必进全屏播放页)。
            TVRoundBtn(icon: transportIcon, size: 56, primary: true) {
                store.togglePlayPause()
            }
            if !store.isLiveRadio {
                // 有声内容:右边这颗是前进 30 秒,不跳章。
                TVRoundBtn(icon: store.currentItemIsSpokenWord ? "goforward.30" : "forward.fill",
                           size: 48) { store.transportForward() }
            }
            Color.clear.frame(width: TVSpace.pageH - 16, height: 1)
        }
        .frame(height: 72)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, TVColor.chrome.opacity(0.72), TVColor.chrome],
                           startPoint: .top, endPoint: .bottom)
        )
        .animation(.easeOut(duration: 0.18), value: focused)
    }

    private var progress: Double {
        let dur = store.duration
        return dur > 0 ? max(0, min(1, store.currentTime / dur)) : 0
    }

    private var transportIcon: String {
        if store.isLiveRadio {
            return store.engine.status == .loading || store.engine.status == .playing
                ? "stop.fill" : "play.fill"
        }
        return store.isPlaying ? "pause.fill" : "play.fill"
    }

    @ViewBuilder
    private func bottomArtwork(_ np: TVNowPlaying) -> some View {
        if store.isLiveRadio, let station = store.currentRadioStation {
            TVRadioArtworkView(station: station, size: 48, radius: 8, store: store)
        } else {
            TVArtworkView(coverKey: np.albumID, artist: np.artist, album: np.album,
                          songID: np.songID, coverRef: np.coverRef,
                          tint: np.tint, tint2: np.tint2, glyph: np.glyph, size: 48, radius: 8)
        }
    }
}

// MARK: - 页面内容内边距(让出 tab bar / 底部条)

extension View {
    func tvPage() -> some View {
        self
            .padding(.top, TVSpace.pageTop)
            .padding(.bottom, TVSpace.pageBottom)
            .padding(.horizontal, TVSpace.pageH)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 区块小标题(eyebrow)

struct TVEyebrow: View {
    let text: String
    var color: Color = TVColor.textFaint

    var body: some View {
        Text(text.uppercased())
            .tvFont(.eyebrow).tracking(1.4)
            .foregroundStyle(color)
    }
}
#endif
#endif
