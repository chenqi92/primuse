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
}
#endif

/// tvOS 根布局 — 顶部自定义 tab bar(Apple TV / Apple Music for tvOS 风) + 全屏内容。
/// 正在播放作为一级 tab，队列 / 选项 / 设置仍以全屏覆盖呈现。
struct TVRoot: View {
    /// 顺序与 iPhone / iPad / Mac 一致:首页、音乐、电台、有声,再是电视端自己的几页。
    /// 电台没有台、有声没有内容时这两页不出现(`ListeningSpaceVisibilityPolicy`)。
    enum Tab: Hashable { case home, library, radio, spokenWord, nowPlaying, playlists, sources, search }

    @Environment(TVStore.self) private var store
    @State private var tab: Tab
    @State private var libraryFilter: TVLibraryView.Filter = .albums
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
        let initialTab: Tab
        #if DEBUG
        // 截图预览用:SIMCTL_CHILD_TV_SCREEN=<tab> 直接进入指定页。
        // 电台三页(radioHome / radioAdd / radioLibrary)配合 TV_DEMO_RADIO=1 注入演示电台。
        switch TVDebugLaunch.screen {
        case "library": initialTab = .library
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
        default: initialTab = .home
        }
        #else
        initialTab = .home
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
                        onSelect: { tab = $0 },
                        onContentDown: requestContentFocus,
                        focusRequest: tabFocusRequest,
                        allowsFocusDrivenSelection: !suppressesFocusDrivenTabSelection && !isRoutingToScrubber,
                        onFocusChanged: tabBarFocusChanged,
                        onSettings: { showSettings = true }
                    )
                    .zIndex(1)
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
            }
        }
        .onChange(of: rootModalPresentationCount) { _, count in
            modalActivityChanged(count > 0 || hasChildModalPresentation)
        }
        // 电台删空 / 有声内容没了:那一页从顶栏消失,停在上面就回首页。
        .onChange(of: visibleTabs) { _, tabs in
            #if DEBUG
            if let pending = debugPendingSpaceTab, tabs.contains(pending) {
                debugPendingSpaceTab = nil
                tab = pending
                return
            }
            #endif
            if !tabs.contains(tab) { tab = .home }
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
            case "nowPlaying":
                await waitForDemoContent(requireAlbum: true)
                if let album = store.albums.first { store.play(album: album) }
                tab = .nowPlaying
            case "nowPlayingDemo":   // 截图用:注入演示播放态+歌词,不走真实播放
                await waitForDemoContent()
                await store.loadDemoNowPlaying()
                tab = .nowPlaying
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
                focusRequest: libraryFocusRequest
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
                onReturnToTabs: returnFocusToTabs,
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
                onModalActivityChanged: childModalActivityChanged
            )
        }
    }

    /// 顶栏上出现哪些页:电台、有声只在有内容时出现。
    private var visibleTabs: [Tab] {
        let spaces = ListeningSpaceVisibilityPolicy.visibleSpaces(
            hasRadioStations: !store.radioStations.isEmpty,
            hasSpokenWord: !store.library.spokenWordSongs.isEmpty
        )
        var tabs: [Tab] = [.home, .library]
        if spaces.contains(.radio) { tabs.append(.radio) }
        if spaces.contains(.spokenWord) { tabs.append(.spokenWord) }
        tabs += [.nowPlaying, .playlists, .sources, .search]
        return tabs
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
              focused != active else {
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

    private func label(for tab: TVRoot.Tab) -> String {
        switch tab {
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

    private var debugFocusTab: TVRoot.Tab? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["TV_FOCUS_TAB"] {
        case "home": return .home
        case "library": return .library
        case "radio": return .radio
        case "spokenWord": return .spokenWord
        case "nowPlaying": return .nowPlaying
        case "playlists": return .playlists
        case "sources": return .sources
        case "search": return .search
        default: return nil
        }
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
                        label: label(for: item),
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
