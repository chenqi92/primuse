#if os(macOS)
import SwiftUI
import AppKit
import PrimuseKit

/// 1.6 重设计后的 macOS 根布局: 自定义 TitleBar + Sidebar + Detail + BottomBar 四件套,
/// 不再依赖 NavigationSplitView。标题栏背景透明且内容延伸至顶部,导航和搜索由
/// `PMTitleBar` 绘制,窗口控制保留 AppKit 原生实现。
struct MacContentView: View {
    @State private var selection: MacRoute = .home
    @State private var sidebarCollapsed: Bool = false
    @State private var savedSidebarCollapsed: Bool = false
    @State private var nowPlayingPresented = false
    @State private var queuePresented = false
    @State private var isWindowFullScreen = false
    @State private var hostWindow: NSWindow?
    @State private var searchText = ""
    @State private var songLocationRequest: SongLibraryLocationRequest?
    @State private var didRestorePersistedRoute = false
    @State private var preferences = MacUIPreferences.shared
    @State private var showNewPlaylist = false
    @State private var showSmartEditor = false
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

    @Environment(\.openWindow) private var openWindow
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("primuse.hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("primuse.navigation.macRoute.v1") private var persistedRouteID = "home"

    var body: some View {
        VStack(spacing: 0) {
            if !isFullScreenNowPlaying {
                PMTitleBar(
                    searchText: $searchText,
                    sidebarCollapsed: $sidebarCollapsed,
                    selection: $selection,
                    onAddSource: { selectRoute(.sources) },
                    onAudioOutput: { /* 由 BottomBar 右侧的喇叭按钮 popover 接管 */ }
                )
            }

            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    MacSidebar(selection: $selection, onOpenTool: { activeTool = $0 })
                        .frame(width: preferences.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                ZStack {
                    MacDetailContainer(
                        route: selection,
                        searchText: $searchText,
                        songLocationRequest: $songLocationRequest,
                        onShowSongInLibrary: showSongInLibrary
                    )
                        .background(PMColor.bg.ignoresSafeArea())

                    if nowPlayingPresented {
                        MacNowPlayingView(onClose: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                nowPlayingPresented = false
                            }
                        }, isScrapingCurrentSong: isScrapingCurrentSongLyrics,
                           canTranscribeAudio: canTranscribeCurrentSongAudio,
                           onScrapeCurrentSong: startCurrentSongLyricsScrape,
                           onTranscribeAudio: openCurrentSongAudioTranscriptionEditor,
                           onToggleQueue: {
                               withAnimation(.easeInOut(duration: 0.25)) {
                                   queuePresented.toggle()
                               }
                           })
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if queuePresented {
                    MacQueuePanel(onClose: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            queuePresented = false
                        }
                    })
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
                    MacBottomBar(
                        isExpanded: nowPlayingPresented,
                        isQueueShown: queuePresented,
                        onToggleNowPlaying: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                nowPlayingPresented.toggle()
                            }
                        },
                        onToggleQueue: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                queuePresented.toggle()
                            }
                        },
                        onMiniPlayer: {
                            PrimuseAppDelegate.shared?.toggleMiniPlayer()
                        },
                        onFullScreen: {
                            PrimuseAppDelegate.shared?.toggleFullScreenPlayer()
                        }
                    )
                }
            }
        }
        .songBatchRemovalFeedback()
        .environment(\.pmAppearance, preferences.appearance)
        .background(PMColor.bg.ignoresSafeArea())
        .background(PMWindowChromeConfigurator())
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $showInitialOnboarding) {
            OnboardingView()
                .frame(minWidth: 720, minHeight: 560)
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
        .onChange(of: colorScheme, initial: true) { _, _ in
            // `.system` 下 AppKit 不会重新调用偏好 setter；由根视图监听实际
            // effective appearance，重绘带明暗资源变体的 Dock 图标。
            preferences.applyAppIcon()
        }
        .onChange(of: selection) { _, route in
            persistedRouteID = persistenceID(for: route)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseSidebarRequestNewPlaylist)) { _ in
            newPlaylistName = ""
            newPlaylistDescription = ""
            showNewPlaylist = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseSidebarRequestNewSmartPlaylist)) { _ in
            showSmartEditor = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseRequestExpandNowPlaying)) { note in
            let animated = note.userInfo?[PrimuseNowPlayingExpansion.animatedKey] as? Bool ?? true
            if animated {
                withAnimation(.easeInOut(duration: 0.25)) {
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
        .onReceive(NotificationCenter.default.publisher(for: .primuseSelectScrobble)) { _ in
            activeTool = .scrobble
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseSelectPlaylists)) { _ in
            // 歌单总览页已移除 (侧栏已直接列出全部歌单 + 智能歌单)。删除当前歌单后
            // 回到首页, 而不是再跳那个不稳定的总览页。
            selectRoute(.home)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseSelectRadio)) { _ in
            selectRoute(.section(.radio))
        }
        .background {
            PMWindowResolver { window in
                hostWindow = window
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow else { return }
            isWindowFullScreen = true
            savedSidebarCollapsed = sidebarCollapsed
            withAnimation(.easeInOut(duration: 0.25)) {
                sidebarCollapsed = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow, window === hostWindow else { return }
            isWindowFullScreen = false
            withAnimation(.easeInOut(duration: 0.25)) {
                sidebarCollapsed = savedSidebarCollapsed
            }
        }
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
        case .scrobble:
            ScrobbleSettingsView()
        }
    }

    private var isFullScreenNowPlaying: Bool {
        isWindowFullScreen && nowPlayingPresented
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
        return intelligence.isAudioTranscriptionConfigured
            && AIAudioTranscriptionPolicy.supportsInput(format: song.fileFormat)
            && song.sourceID != AppleMusicLibraryIdentity.sourceID
            && song.cueSheetPath == nil
            && (song.duration <= 0
                || song.duration <= AIAudioTranscriptionPolicy.maximumDuration)
    }

    private func openCurrentSongAudioTranscriptionEditor() {
        guard canTranscribeCurrentSongAudio,
              lyricsScrapeTask == nil,
              let song = player.currentSong else { return }
        lyricsTranscriptionEditorTargetSong = song
    }

    private func selectRoute(_ route: MacRoute) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selection = route
        }
    }

    private func showSongInLibrary(_ song: Song) {
        songLocationRequest = SongLibraryLocationRequest(songID: song.id)
        selectRoute(.section(.songs))
    }

    private func restorePersistedRouteIfNeeded() {
        guard !didRestorePersistedRoute else { return }
        didRestorePersistedRoute = true
        selection = route(for: persistedRouteID) ?? .home
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
#endif
