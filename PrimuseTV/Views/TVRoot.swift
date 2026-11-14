#if os(tvOS) || TV_FOCUS_ROUTING_HARNESS
#if os(tvOS)
import SwiftUI
import UIKit
import PrimuseKit
#endif

// MARK: - Content focus routing

enum TVContentFocusTab: Equatable, Sendable {
    case library
    case nowPlaying
    case sources
    case search
    case playlists
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
    case playlistsPrimary
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
        case .playlists:
            return .playlistsPrimary
        case .other:
            return nil
        }
    }
}

struct TVContentFocusRoutingState: Equatable, Sendable {
    private(set) var latestRequest: TVContentFocusRequest?

    func requestID(for target: TVContentFocusTarget) -> Int {
        guard let latestRequest, latestRequest.target == target else { return 0 }
        return latestRequest.id
    }

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    /// 有声页、播客页从哪张卡片 / 哪个章节页、节目页开始播放;播放页按 Menu 回来时由它恢复。
    @State private var spokenWordMemory = TVSpokenWordReturnMemory()
    @State private var podcastMemory = TVPodcastReturnMemory()
    @State private var radioMemory = TVRadioReturnMemory()
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
        case "library", "albumDetail", "libraryIndex", "albumReturn", "albumShuffleReturn",
             "artistReturn", "genreReturn":
            initialTab = .library
        case "folderReturn":
            initialTab = .library
            _libraryFilter = State(initialValue: .folders)
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
        case "podcasts", "podcastShow", "podcastDiscover", "podcastPlay": initialTab = .podcasts
        case "radioHome", "radioAdd": initialTab = .home
        case "playlists": initialTab = .playlists
        case "sources", "sourcePicker", "sourceForm", "credentials", "otp", "scan", "recycleBin",
             "googleDriveAccessChange", "cloudCompanionAuth", "localRemovals":
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
            .modifier(TVReturnToTabsModifier(enabled: hidesTabBar || !isTabBarFocused) {
                ScreenIdleHoldController.shared.noteUserInteraction()
                if hidesTabBar { leavePlayer() } else { returnFocusToTabs() }
            })
            // 播放时屏幕常亮只在沉浸画面上起作用:电视的播放页正在播放时占满全屏,全屏效果页也盖在它上面
            // (选「原生」时全屏效果就是这一页)。别的页面交给系统屏保,不再自动转到播放页。
            .screenIdleImmersiveSurface(hidesTabBar)
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
                    selectTab(.nowPlaying, requestsPlayerFocus: false)
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
                    case .podcast:
                        Text(verbatim: String(format: String(localized: "podcast_tv_http_message %@"), request.endpoint))
                    }
                }
            }
    }

    private var rootContent: some View {
        GeometryReader { _ in
            ZStack(alignment: .top) {
                TVColor.bg.ignoresSafeArea()

                // 顶栏叠在页面上面,每一页自己让出顶栏的高度(全屏播放页不让):进出播放页时
                // 新旧两页各按自己的版面交叠过渡,不会因为顶栏收放整块上下跳。
                TVTabContent(
                    selection: tab,
                    order: visibleTabs,
                    isFullScreen: isFullScreenPage,
                    onDisplayed: { item in
                        guard item == tab, item != .nowPlaying,
                              let request = contentFocusRouting.contentDidAppear(
                                in: focusRoutingTab(item), nowPlayingMode: nowPlayingFocusMode
                              ) else { return }
                        applyContentFocusRequest(request)
                    }
                ) { item in
                    content(for: item)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                TVTabBar(
                    active: tab,
                    tabs: visibleTabs,
                    onSelect: { selectTab($0) },
                    // 焦点停在「正在播放」上往下走时,下面仍是当前那一页。
                    onContentDown: { item in
                        let destination = TVTabFocusSelectionPolicy.contentDestination(focused: item, active: tab)
                        selectTab(destination)
                        requestContentFocus(from: destination)
                    },
                    focusRequest: tabFocusRequest,
                    allowsFocusDrivenSelection: !hidesTabBar && !suppressesFocusDrivenTabSelection && !isRoutingToScrubber,
                    onFocusChanged: tabBarFocusChanged,
                    onSettings: { showSettings = true }
                )
                // 播放页全屏:顶栏淡出并退出焦点,上键不会再误切到别的页。
                // 不从层级里拿掉,离开播放页时它的焦点回调还要接得住。
                .opacity(hidesTabBar ? 0 : 1)
                .offset(y: hidesTabBar ? -TVPageMotion.tabBarLift : 0)
                .animation(reduceMotion ? nil : TVPageMotion.animation, value: hidesTabBar)
                .disabled(hidesTabBar)
                .accessibilityHidden(hidesTabBar)
                .zIndex(1)
            }
        }
        // 第一次有了资料库里自己下载的播客:默认收着的播客页亮出来一次。这些文件原先在有声页,
        // 归到播客以后页面还收着的话,看起来就是丢了。之后再关掉就照用户的来。
        .onChange(of: store.library.localPodcastSongs.isEmpty, initial: true) { _, isEmpty in
            guard !isEmpty else { return }
            let key = "primuse.tv.podcastsRevealedForLocalFiles.v1"
            guard !UserDefaults.standard.bool(forKey: key) else { return }
            UserDefaults.standard.set(true, forKey: key)
            var configuration = tabBarConfiguration
            guard !configuration.isShown(.podcasts) else { return }
            configuration.setShown(true, for: .podcasts)
            tabBarConfigurationRawValue = configuration.encoded()
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
        .onChange(of: tab) { _, newTab in
            pendingLaunchTab = nil
            transientTab = tabBarConfiguration.isShown(newTab) ? nil : newTab
        }
        .onAppear {
            if !tabBarConfiguration.isShown(tab) { transientTab = tab }
        }
        .tvFullScreenCover(isPresented: $showSettings) {
            TVSettingsView(onNavigate: { tab = $0 }).environment(store)
        }
        .tvFullScreenCover(isPresented: $showQueue) {
            TVQueueView().environment(store)
        }
        .tvFullScreenCover(isPresented: $showOptions) {
            TVOptionsView().environment(store)
        }
        .tvFullScreenCover(item: Binding(
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
                selectTab(.nowPlaying)
            case "nowPlayingDemo":   // 截图用:注入演示播放态+歌词,不走真实播放
                await waitForDemoContent()
                await store.loadDemoNowPlaying()
                selectTab(.nowPlaying)
            case "lyricsTranslationDemo":
                await waitForDemoContent()
                if await store.loadLyricsTranslationDemo() {
                    selectTab(.nowPlaying)
                }
            case "nowPlayingSongArtwork":
                await waitForDemoContent()
                if await store.loadDemoNowPlaying(preferSongArtwork: true) {
                    selectTab(.nowPlaying)
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
                // TV_DEBUG_PLAY:真的放第一张专辑,量全屏效果和选择器在播放时的负载;
                // 不设时只注入演示播放态(不出声、舞台不动)。
                if ProcessInfo.processInfo.environment["TV_DEBUG_PLAY"] != nil {
                    await waitForDemoContent(requireAlbum: true)
                    if let album = store.albums.first { store.play(album: album) }
                } else {
                    await waitForDemoContent()
                    await store.loadDemoNowPlaying()
                }
                selectTab(.nowPlaying)
            case "settings", "effectPicker", "themePicker", "playerBackdrop", "diagnostics", "scrobble": showSettings = true
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
                selectTab(.nowPlaying)
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
                selectTab(.nowPlaying)
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
                selectTab(.nowPlaying)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                leavePlayer()
            case "albumShuffleReturn":
                // 模拟「专辑页里按随机播放 → 播放页按 Menu」:应回到专辑页、焦点落在开播的那一首
                // (日志 `TV album detail reopened focus=track`),不是「全部播放」。
                await waitForDemoContent(requireAlbum: true)
                guard let album = store.albums.first(where: { store.songIDs(forAlbum: $0.id).count >= 3 }) else { break }
                guard store.playResolvedQueue(songIDs: store.songIDs(forAlbum: album.id), shuffled: true) else { break }
                libraryBrowseMemory.albumID = album.id
                libraryBrowseMemory.albumDetailID = album.id
                libraryBrowseMemory.albumDetailSongID = store.currentSongID
                selectTab(.nowPlaying)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                leavePlayer()
            case "artistReturn", "genreReturn":
                // 模拟「艺人页 / 流派里点开的那一组歌里点最后一首 → 播放页按 Menu」:应重开那一页、
                // 焦点在那一首(日志 `TV focus restore … result=ok`)。
                await waitForDemoContent(requireAlbum: true)
                if TVDebugLaunch.screen == "artistReturn" {
                    guard let artist = store.artists.first(where: { store.songs(forArtistID: $0.id).count >= 3 }),
                          let song = store.songs(forArtistID: artist.id).last,
                          store.play(song, in: store.songs(forArtistID: artist.id).map(\.id)) else { break }
                    libraryFilter = .artists
                    libraryBrowseMemory.artistID = artist.id
                    libraryBrowseMemory.artistDetail = artist
                    libraryBrowseMemory.artistDetailSongID = song.id
                } else {
                    guard let genre = store.library.visibleGenres.first(where: {
                              store.library.songs(forGenre: $0.id).count >= 3
                          }) else { break }
                    let ids = store.library.songs(forGenre: genre.id).map(\.id)
                    guard let songID = ids.last, let song = store.song(songID), store.play(song, in: ids) else { break }
                    libraryFilter = .genres
                    libraryBrowseMemory.genreID = genre.id
                    libraryBrowseMemory.collectionDetail = TVBrowseDestination(id: genre.id, title: genre.name, songIDs: ids)
                    libraryBrowseMemory.collectionDetailSongID = songID
                }
                selectTab(.nowPlaying)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                leavePlayer()
            case "folderReturn":
                // 模拟「文件夹页里点一个有歌的文件夹的最后一首 → 播放页按 Menu」:应回到那一层、
                // 焦点在那一首(日志 `TV focus restore target=folderSong:… result=ok`)。
                await waitForDemoContent()
                let index = await store.makeFolderIndex()
                let visible = store.songIDSet
                var trail: [LibraryFolderNodeID] = []
                var songIDs: [String] = []
                var level = index.sourceNodes
                while songIDs.isEmpty, let node = level.first {
                    trail.append(node.id)
                    songIDs = LibraryFolderBrowsePolicy.trackOrderedSongIDs(
                        in: node.id, scope: .direct, index: index, isVisible: visible.contains
                    )
                    level = index.children(of: node.id)
                }
                guard let songID = songIDs.last, let song = store.song(songID),
                      store.play(song, in: songIDs) else { break }
                libraryBrowseMemory.folderPath = trail
                libraryBrowseMemory.folderSongID = songID
                selectTab(.nowPlaying)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                leavePlayer()
            case "spokenWordReturn":
                // 模拟「有声页书架上按一本书 → 播放页按 Menu」:焦点应回到那张书封(日志
                // `TV focus restore target=shelf:… result=ok`),不是顶栏的「有声」。
                // TV_SPOKEN_WORD_DETAIL=1 改走章节页里点第二章,回来应先重开章节页、焦点在那一章。
                await waitForDemoContent(requireAlbum: true)
                // 演示曲库里没有有声书:TV_DEBUG_MAKE_BOOK=1 把一张专辑标成有声,当一本书用。
                if ProcessInfo.processInfo.environment["TV_DEBUG_MAKE_BOOK"] == "1",
                   store.library.spokenWordSongs.isEmpty,
                   let album = store.albums.last(where: { store.songIDs(forAlbum: $0.id).count >= 3 }) {
                    SpokenWordStore.shared.setKind(.spokenWord, forSongIDs: store.songIDs(forAlbum: album.id))
                }
                var tries = 0
                while !visibleTabs.contains(.spokenWord) && tries < 25 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    tries += 1
                }
                guard visibleTabs.contains(.spokenWord) else { break }
                // 先停在有声页(书架在这一页上分组),进播放页时记下的「之前那一页」才是它。
                tab = .spokenWord
                tries = 0
                while store.spokenWordShelf(.books).books.isEmpty && tries < 25 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    tries += 1
                }
                guard let book = store.spokenWordShelf(.books).books.first(where: { !$0.isFinished }) else { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let itemIDs = book.items.map(\.id)
                if ProcessInfo.processInfo.environment["TV_SPOKEN_WORD_DETAIL"] == "1", itemIDs.count > 1 {
                    guard store.playSpokenWordBook(songIDs: itemIDs, startingAt: itemIDs[1]) else { break }
                    spokenWordMemory.detailBookID = book.id
                    spokenWordMemory.detailItemID = itemIDs[1]
                } else {
                    guard store.playSpokenWordBook(songIDs: itemIDs, startingAt: book.resumeItemID) else { break }
                }
                spokenWordMemory.cardID = "shelf:" + book.id
                selectTab(.nowPlaying)
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
    private func content(for item: Tab) -> some View {
        switch item {
        case .home:
            TVHomeView(
                browseMemory: homeBrowseMemory,
                onReturnToTabs: returnFocusToTabs,
                openPlayer: { openPlayerFromPage(from: item) },
                openRadioLibrary: { tab = .radio },
                onModalPresentationChanged: childModalPresentationChanged
            )
        case .library:
            TVLibraryView(
                openPlayer: { openPlayerFromPage(from: item) },
                onReturnToTabs: returnFocusToTabs,
                onModalActivityChanged: childModalActivityChanged,
                filter: $libraryFilter,
                focusRequest: libraryFocusRequest,
                browseMemory: libraryBrowseMemory
            )
        case .radio:
            TVRadioPageView(
                openPlayer: { openPlayerFromPage(from: item) },
                onModalActivityChanged: childModalActivityChanged,
                onModalPresentationChanged: childModalPresentationChanged,
                memory: radioMemory
            )
        case .spokenWord:
            TVSpokenWordView(
                openPlayer: { openPlayerFromPage(from: item) },
                onModalActivityChanged: childModalPresentationChanged,
                memory: spokenWordMemory
            )
        case .podcasts:
            TVPodcastsView(
                openPlayer: { openPlayerFromPage(from: item) },
                onModalActivityChanged: childModalPresentationChanged,
                memory: podcastMemory
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
        case .playlists:
            TVPlaylistsView(
                focusRequest: contentFocusRouting.requestID(for: .playlistsPrimary),
                openPlayer: { openPlayerFromPage(from: item) },
                onModalPresentationChanged: childModalPresentationChanged
            )
        case .sources:
            TVSourcesView(
                focusRequest: sourcesFocusRequest,
                onModalActivityChanged: childModalActivityChanged
            )
        case .search:
            TVSearchView(
                openPlayer: { openPlayerFromPage(from: item) },
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
        let configuration = tabBarConfiguration
        var tabs = configuration.visibleItems(isAvailable: isTabAvailable)
        if let transientTab, !tabs.contains(transientTab), isTabAvailable(transientTab) {
            let rank = { (item: Tab) in configuration.order.firstIndex(of: item) ?? 0 }
            let insertAt = tabs.firstIndex { rank($0) > rank(transientTab) } ?? tabs.endIndex
            tabs.insert(transientTab, at: insertAt)
        }
        return tabs
    }

    private func isTabAvailable(_ item: Tab) -> Bool {
        switch item {
        case .radio: return !store.radioStations.isEmpty
        case .spokenWord: return !store.library.spokenWordSongs.isEmpty
        default: return true
        }
    }

    /// 正在播放时播放页占满全屏;没在播放时还是普通一页(空状态),顶栏照常。
    private var hidesTabBar: Bool {
        isFullScreenPage(tab)
    }

    private func isFullScreenPage(_ item: Tab) -> Bool {
        item == .nowPlaying && store.hasNowPlaying
    }

    private func selectTab(_ item: Tab, playerOrigin: Tab? = nil, requestsPlayerFocus: Bool = true) {
        guard item != tab else { return }
        if item == .nowPlaying { tabBeforePlayer = playerOrigin ?? tab }
        plog("TV navigation select \(tab.rawValue)→\(item.rawValue)")
        tab = item
        guard item == .nowPlaying, store.hasNowPlaying, requestsPlayerFocus else { return }
        // 顶栏随即收起,焦点要明确送进播放页(封面)。
        Task { @MainActor in
            await Task.yield()
            guard tab == .nowPlaying, hidesTabBar else { return }
            requestContentFocus(from: .nowPlaying)
        }
    }

    /// 在页面里开播、进播放页:和在顶栏上选「正在播放」一样把焦点明确送进去。不能指望原来那张
    /// 卡片消失时 UIKit 自己把焦点挪进播放页 —— 从播放页回来时重开过的播客节目页、有声章节页,
    /// 弹出那一刻焦点在顶栏上,在里面再开播、页面关掉后焦点被还给顶栏;顶栏一收起,焦点就悬在
    /// 藏起来的顶栏上,Menu 没有人接,直接退回系统主屏。
    private func openPlayerFromPage(from source: Tab) {
        selectTab(.nowPlaying, playerOrigin: source)
    }

    /// 播放页上的 Menu:回到进来之前那一页。资料库、首页、搜索、有声、播客把焦点放回起播的那张卡片 /
    /// 那条结果(从专辑页、艺人页、章节页、节目页起播的先回那一页),其余页面落在顶栏的当前项上
    /// (和在那一页按 Menu 的落点一致)。
    private func leavePlayer() {
        guard hidesTabBar else {
            returnFocusToTabs()
            return
        }
        let tabs = visibleTabs.filter { $0 != .nowPlaying }
        let destination = TVPlayerReturnPolicy.destination(
            origin: tabBeforePlayer,
            available: Tab.allCases.filter(isTabAvailable),
            visible: tabs
        )
        if !tabBarConfiguration.isShown(destination) { transientTab = destination }
        isRoutingToScrubber = false
        contentFocusRouting.returnToTabs()
        nowPlayingFocusRequest = nil
        // 顶栏重新可用的那一刻焦点可能先落在它的某一项上,别让这一下把页面切走。
        suppressesFocusDrivenTabSelection = true
        // 从资料库的专辑页 / 艺人页起播的:回到资料库时先回那一页(见 TVLibraryBrowseMemory)。
        libraryBrowseMemory.restoresAfterPlayer = destination == .library
        // 首页、搜索、有声、播客页出现时自己把焦点放回去(见各页的返回记忆),
        // 这里就不再把焦点送回顶栏;记不住的时候照旧回顶栏。
        homeBrowseMemory.restoresAfterPlayer = destination == .home && homeBrowseMemory.hasReturnTarget
        searchMemory.restoresAfterPlayer = destination == .search && searchMemory.hasReturnTarget
        spokenWordMemory.restoresAfterPlayer = destination == .spokenWord && spokenWordMemory.hasReturnTarget
        podcastMemory.restoresAfterPlayer = destination == .podcasts && podcastMemory.hasReturnTarget
        radioMemory.restoresAfterPlayer = destination == .radio && radioMemory.stationID != nil
        let pageRestoresFocus = radioMemory.restoresAfterPlayer || homeBrowseMemory.restoresAfterPlayer || searchMemory.restoresAfterPlayer
            || spokenWordMemory.restoresAfterPlayer || podcastMemory.restoresAfterPlayer
        // 进播放页之前那次「从顶栏下到输入框」的请求还挂着,搜索页一出现就会把焦点抢到输入框。
        searchFocusRequest = nil
        tab = destination
        Task { @MainActor in
            await Task.yield()
            guard tab == destination else { return }
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
        guard tab == .nowPlaying, let request = contentFocusRouting.contentDidAppear(
            in: .nowPlaying,
            nowPlayingMode: mode
        ) else { return }
        applyContentFocusRequest(request)
    }

    private func retargetNowPlayingFocus(_ mode: TVNowPlayingFocusMode) {
        guard tab == .nowPlaying, let request = contentFocusRouting.contentModeDidChange(
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
        case .playlistsPrimary:
            // 歌单直接观察当前路由，返回顶栏时不保留可被重放的旧请求。
            break
        }
    }

    private func focusRoutingTab(_ tab: Tab) -> TVContentFocusTab {
        switch tab {
        case .library: return .library
        case .nowPlaying: return .nowPlaying
        case .sources: return .sources
        case .search: return .search
        case .playlists: return .playlists
        default: return .other
        }
    }
}

/// 一级页之间的换页:顶栏上横着换时新页从换过去的那一侧滑进来;进出全屏播放页时往里走一层 / 退回一层
/// (缩放加淡入淡出)。
///
/// 旧页在换页那一刻就 `.disabled` 交出焦点、退出交互,只是在原地淡出,放完以后不带动画地拿掉。
/// 不能让停着焦点的页带着移除过渡退场:电视主线程忙时,异步渲染线程放完移出动画、等主线程拆视图,
/// 焦点更新量位置时顺手执行了这次移除,UIKit 会断言闪退(见 10-17 那次焦点断言)。
struct TVTabContent<Content: View>: View {
    let selection: TVRoot.Tab
    /// 顶栏上此刻的顺序,决定往哪边滑。
    let order: [TVRoot.Tab]
    /// 占满全屏、不让出顶栏的页(在放东西时的播放页)。
    var isFullScreen: (TVRoot.Tab) -> Bool
    var onDisplayed: (TVRoot.Tab) -> Void
    @ViewBuilder var content: (TVRoot.Tab) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var displayed: TVRoot.Tab
    @State private var retiring: TVRoot.Tab?
    @State private var transition: TVPageTransition = .none

    init(
        selection: TVRoot.Tab,
        order: [TVRoot.Tab],
        isFullScreen: @escaping (TVRoot.Tab) -> Bool,
        onDisplayed: @escaping (TVRoot.Tab) -> Void = { _ in },
        @ViewBuilder content: @escaping (TVRoot.Tab) -> Content
    ) {
        self.selection = selection
        self.order = order
        self.isFullScreen = isFullScreen
        self.onDisplayed = onDisplayed
        self.content = content
        _displayed = State(initialValue: selection)
    }

    var body: some View {
        let mirrored = layoutDirection == .rightToLeft
        ZStack {
            ForEach(retiring.map { [$0, displayed] } ?? [displayed], id: \.self) { item in
                content(item)
                    // 过渡只作用于页面外壳，不把首次布局与内部内容更新一起插值。
                    .transaction { $0.animation = nil }
                    .padding(.top, isFullScreen(item) ? 0 : TVTabBar.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .modifier(TVPageMotion(
                        phase: item == displayed ? .shown : .leaving,
                        transition: transition,
                        mirrored: mirrored
                    ))
                    .disabled(item != displayed)
                    .allowsHitTesting(item == displayed)
                    .accessibilityHidden(item != displayed)
                    .zIndex(item == displayed ? 1 : 0)
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: TVPageMotion(phase: .arriving, transition: transition, mirrored: mirrored),
                            identity: TVPageMotion(phase: .shown, transition: transition, mirrored: mirrored)
                        ),
                        // 退场的页已经在原地淡没了,拿掉时不再放过渡(见上面的焦点断言)。
                        removal: .identity
                    ))
                    // 反向切回仍在淡出的页不会再触发 onAppear；恢复交互时也必须重发焦点。
                    .onChange(of: item == displayed, initial: true) { _, isDisplayed in
                        if isDisplayed { onDisplayed(item) }
                    }
            }
        }
        .onChange(of: selection) { _, next in
            guard next != displayed else { return }
            let kind = TVPageTransitionPolicy.transition(
                from: displayed,
                to: next,
                order: order,
                fromIsFullScreen: isFullScreen(displayed),
                toIsFullScreen: isFullScreen(next),
                reduceMotion: reduceMotion
            )
            let animates = kind != .none
            var transaction = Transaction(animation: animates ? TVPageMotion.animation : nil)
            transaction.disablesAnimations = !animates
            withTransaction(transaction) {
                transition = kind
                retiring = animates ? displayed : nil
                displayed = next
            }
        }
        .task(id: displayed) {
            guard retiring != nil else { return }
            do { try await Task.sleep(for: TVPageMotion.retireAfter) } catch { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { retiring = nil }
        }
    }
}

/// 一页在换页过渡里的位置与大小。
struct TVPageMotion: ViewModifier {
    enum Phase {
        /// 新页刚插进来时的起点。
        case arriving
        case shown
        /// 旧页退到的终点。
        case leaving
    }

    let phase: Phase
    let transition: TVPageTransition
    /// 从右往左排的语言里顶栏也是反的,滑动方向跟着反过来。
    let mirrored: Bool

    /// 先快后慢,新页很快就到位、最后轻轻停住。
    static let animation = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.42)
    /// 旧页淡没以后再拿掉。
    static let retireAfter: Duration = .milliseconds(460)
    /// 顶栏上横着换页时新页滑进来的距离、旧页退开的距离。
    static let arrivingSlide: CGFloat = 72
    static let leavingSlide: CGFloat = 40
    /// 进出全屏播放页时的远近。
    static let depthScale: CGFloat = 0.045
    /// 进全屏播放页时顶栏往上收的距离。
    static let tabBarLift: CGFloat = 28

    /// 页面里后到的整块内容(后台排好的专辑墙)出现时淡入、轻轻升起,不是一帧之内从空白跳出来。
    /// 动画跟着过渡走:内容由数据到位触发,不在任何动画事务里。拿掉时不放过渡。
    static var contentReveal: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 18)).animation(.easeOut(duration: 0.32)),
            removal: .identity
        )
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(x: offsetX)
            .opacity(phase == .shown ? 1 : 0)
    }

    private var offsetX: CGFloat {
        guard case let .slide(forward) = transition else { return 0 }
        let sign: CGFloat = (forward ? 1 : -1) * (mirrored ? -1 : 1)
        switch phase {
        case .arriving: return Self.arrivingSlide * sign
        case .shown: return 0
        case .leaving: return -Self.leavingSlide * sign
        }
    }

    private var scale: CGFloat {
        switch (transition, phase) {
        // 往里走:原来那页往前推开,播放页从稍远处落到眼前。
        case (.deeper, .arriving): 1 - Self.depthScale
        case (.deeper, .leaving): 1 + Self.depthScale
        // 退回:播放页往后退开,回到的那页从稍近处落回。
        case (.shallower, .arriving): 1 + Self.depthScale
        case (.shallower, .leaving): 1 - Self.depthScale
        default: 1
        }
    }
}

/// 弹出的整页(专辑页、艺人页、设置的下一层、弹框……)出现时从稍近处轻轻落回原位。
///
/// tvOS 给全屏覆盖层的只是四五帧的平直溶解,页面看着像直接闪出来。这里只缩放、不动透明度:
/// 淡入仍交给系统那一下溶解,页面里的焦点落点不受影响;从大往小落,四周也不会露出底下的边。
private struct TVModalPageEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(settled || reduceMotion ? 1 : 1 + TVPageMotion.depthScale)
            .onAppear {
                guard !settled else { return }
                withAnimation(reduceMotion ? nil : TVPageMotion.animation) { settled = true }
            }
    }
}

extension View {
    /// 和 `fullScreenCover` 一样,弹出的那一页带上 `TVModalPageEntrance`。全屏展示(沉浸播放页)
    /// 自己有进出动画、底是透明的,照旧用 `fullScreenCover`。
    func tvFullScreenCover<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) {
            content().modifier(TVModalPageEntrance())
        }
    }

    func tvFullScreenCover<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        fullScreenCover(item: item, onDismiss: onDismiss) { value in
            content(value).modifier(TVModalPageEntrance())
        }
    }
}

enum TVPlayerReturnPolicy {
    static func destination(
        origin: TVTabBarItem?, available: [TVTabBarItem], visible: [TVTabBarItem]
    ) -> TVTabBarItem {
        if let origin, origin != .nowPlaying, available.contains(origin) { return origin }
        return visible.first { $0 != .nowPlaying } ?? .home
    }
}

enum TVTabFocusSelectionPolicy {
    static let highlightDuration: TimeInterval = 0.18

    static func contentDestination(focused: TVRoot.Tab, active: TVRoot.Tab) -> TVRoot.Tab {
        focused == .nowPlaying ? active : focused
    }

    static func settledSelection(_ selection: TVRoot.Tab?) async -> TVRoot.Tab? {
        guard let selection else { return nil }
        // 先让焦点高亮到位，再创建目标页，避免首屏布局打断横向导航。
        do { try await Task.sleep(for: .milliseconds(220)) } catch { return nil }
        return Task.isCancelled ? nil : selection
    }

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
        case .podcasts: return String(localized: "listening_space_podcast")
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
        case .podcasts: return "antenna.radiowaves.left.and.right"
        case .nowPlaying: return "play.circle.fill"
        case .playlists: return "music.note.list"
        case .sources: return "server.rack"
        case .search: return "magnifyingglass"
        }
    }
}

private struct TVTabSelectionIntent: Equatable {
    let selection: TVRoot.Tab?
    let revision: Int
}

struct TVTabBar: View {
    /// 顶栏的高度。顶栏叠在页面上面,一般的页按它让出顶部(`TVTabContent`)。
    static let height: CGFloat = 110

    @AppStorage(AppIconService.storageKey) private var iconID = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    @State private var selectionIntentRevision = 0

    private var pendingSelection: TVRoot.Tab? {
        TVTabFocusSelectionPolicy.selection(
            focused: focusedTarget?.tab,
            active: active,
            allowsFocusDrivenSelection: allowsFocusDrivenSelection
        )
    }

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
            HStack(spacing: 14) {
                Image((AppIconService.shared.availableOptions.first { $0.id == iconID }?.alternateName ?? "AppIcon") + "Mark")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 50, height: 50)
                    .accessibilityHidden(true)
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
                        selectionIntentRevision &+= 1
                        onSelect(item)
                    }
                    .accessibilityIdentifier("tv.tab.\(item.rawValue)")
                    .focused($focusedTarget, equals: .tab(item))
                    .anchorPreference(key: TVTabBoundsPreferenceKey.self, value: .bounds) {
                        [item: $0]
                    }
                    .onMoveCommand { direction in
                        if direction == .down {
                            selectionIntentRevision &+= 1
                            onContentDown(item)
                        }
                    }
                }
            }
            .backgroundPreferenceValue(TVTabBoundsPreferenceKey.self) { anchors in
                GeometryReader { proxy in
                    TVTabFocusHighlight(
                        focusFrame: focusedTarget?.tab.flatMap { anchors[$0] }.map { proxy[$0] },
                        reduceMotion: reduceMotion
                    )
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
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
            selectionIntentRevision &+= 1
            pdiag("TV tab focus \(String(describing: previous))→\(String(describing: focused)) active=\(active.rawValue)")
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
        }
        .task(id: TVTabSelectionIntent(selection: pendingSelection, revision: selectionIntentRevision)) {
            let revision = selectionIntentRevision
            guard let selection = await TVTabFocusSelectionPolicy.settledSelection(pendingSelection),
                  revision == selectionIntentRevision,
                  focusedTarget?.tab == selection else { return }
            onSelect(selection)
        }
        .onChange(of: allowsFocusDrivenSelection) { _, allowsSelection in
            selectionIntentRevision &+= 1
            // 弹层或播放页收起时留下的顶栏焦点只用于恢复，不能重放成一次换页。
            if allowsSelection, focusedTarget != nil {
                focusedTarget = .tab(active)
            }
        }
        .onChange(of: focusRequest) {
            selectionIntentRevision &+= 1
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
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [TVColor.chrome, TVColor.chrome.opacity(0.45), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
        .background(TVColor.bg.ignoresSafeArea(edges: .top))
        .focusSection()
    }
}

private struct TVTabBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: [TVRoot.Tab: Anchor<CGRect>] { [:] }

    static func reduce(value: inout [TVRoot.Tab: Anchor<CGRect>], nextValue: () -> [TVRoot.Tab: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct TVTabFocusHighlight: UIViewRepresentable {
    var focusFrame: CGRect?
    var reduceMotion: Bool

    func makeUIView(context: Context) -> TVTabFocusHighlightView {
        TVTabFocusHighlightView()
    }

    func updateUIView(_ view: TVTabFocusHighlightView, context: Context) {
        view.highlight.backgroundColor = UIColor(TVColor.text)
        view.highlight.layer.shadowColor = UIColor(TVColor.focusShadow).cgColor
        view.move(to: focusFrame, reduceMotion: reduceMotion)
    }
}

/// 单一高亮由合成动画移动；切页期间 SwiftUI 重建内容时，不逐帧重算其位置。
final class TVTabFocusHighlightView: UIView {
    let highlight = UIView()
    private var targetFrame: CGRect?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        highlight.isHidden = true
        highlight.layer.cornerRadius = 16
        highlight.layer.cornerCurve = .continuous
        highlight.layer.shadowOpacity = 0.45
        highlight.layer.shadowRadius = 10
        highlight.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(highlight)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func move(to frame: CGRect?, reduceMotion: Bool) {
        guard let frame else {
            targetFrame = nil
            highlight.layer.removeAllAnimations()
            highlight.isHidden = true
            return
        }
        let animates = targetFrame != nil && !reduceMotion && window != nil
        let changed = targetFrame != frame
        targetFrame = frame
        highlight.isHidden = false
        if !animates {
            highlight.layer.removeAllAnimations()
            UIView.performWithoutAnimation { highlight.frame = frame }
        } else if changed {
            UIView.animate(
                withDuration: TVTabFocusSelectionPolicy.highlightDuration,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
            ) {
                self.highlight.frame = frame
            }
        }
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

    var body: some View {
        Button(action: action) {
            Text(label)
                .tvFont(.rowTitle, weight: .semibold)
                .lineLimit(1).minimumScaleFactor(0.85)
                .foregroundStyle(isFocused ? TVColor.bg : (isActive ? TVColor.text : TVColor.textMuted))
                .padding(.horizontal, 24).padding(.vertical, 10)
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
                        Text(store.isLiveRadio
                            ? np.artist
                            : [np.artist, np.album].filter { !$0.isEmpty }.joined(separator: " · "))
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
        } else if store.currentPodcastEpisodeID != nil {
            TVPodcastArtwork(url: np.coverRef.flatMap(URL.init(string:)), side: 48, radius: 8)
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
