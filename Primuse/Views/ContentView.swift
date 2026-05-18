import SwiftUI
import PrimuseKit

/// iPad sidebar 选中项。Library 之外的顶级项跟 iPhone TabView 一对一
/// (rawValueTab 暴露 0/1/2/3 给 `selectedTab` mirror),Library 还细分到
/// 子列表 (.libraryAlbums / .librarySongs 等) 直接路由 detail,少一层
/// 点击。
private enum SidebarItem: Hashable, Identifiable, CaseIterable {
    case home
    case library
    case librarySongs
    case libraryAlbums
    case libraryArtists
    case libraryPlaylists
    case search
    case settings

    var id: Self { self }

    /// 映射到 iPhone tab 的索引,保证 phone 与 pad 共享 `selectedTab` state
    /// (sidebar 子项也属于 library 这一档,统一回 1)。
    var rawValueTab: Int {
        switch self {
        case .home: return 0
        case .library, .librarySongs, .libraryAlbums, .libraryArtists, .libraryPlaylists:
            return 1
        case .search: return 2
        case .settings: return 3
        }
    }

    /// 顶级 4 项 + Library 下展开的 4 个子项,在 sidebar 里按分段渲染。
    static var topLevel: [SidebarItem] { [.home, .library, .search, .settings] }
    static var libraryChildren: [SidebarItem] {
        [.librarySongs, .libraryAlbums, .libraryArtists, .libraryPlaylists]
    }

    var titleKey: String.LocalizationValue {
        switch self {
        case .home: return "home_title"
        case .library: return "library_title"
        case .librarySongs: return "tab_songs"
        case .libraryAlbums: return "tab_albums"
        case .libraryArtists: return "tab_artists"
        case .libraryPlaylists: return "tab_playlists"
        case .search: return "search_title"
        case .settings: return "settings_title"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "books.vertical"
        case .librarySongs: return "music.note"
        case .libraryAlbums: return "square.stack.fill"
        case .libraryArtists: return "music.mic"
        case .libraryPlaylists: return "music.note.list"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

struct ContentView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    /// iPad (regular) 走 NavigationSplitView; iPhone / iPad 分屏小窗 (compact)
    /// 走 TabView。Apple 推荐用 horizontalSizeClass 而不是 idiom 来判断,以
    /// 适配 Stage Manager / 分屏 / 折叠态。
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selectedTab = 0
    /// iPad sidebar 当前选中项。iPhone 不用,sidebar 隐藏。值跟 selectedTab
    /// 保持联动 (sidebar 改 → selectedTab 也改; selectedTab 改 → sidebar
    /// 跟到对应顶级项, 但子项不自动猜测)。
    @State private var sidebarSelection: SidebarItem = .home
    @State private var searchText = ""
    @State private var showNowPlaying = false
    @State private var libraryDeepLink: LibraryDeepLink?
    /// 跨年自动弹年度报告的状态。1/1 之后用户首次进 app + 上一年听满 2 个月
    /// 时由 YearlyReportAutoTrigger 触发。
    @State private var autoYearlyReport: YearlyReportData?
    /// 首启 onboarding —— @AppStorage 持久, 关掉后永久 true。
    @AppStorage("primuse.hasSeenOnboarding") private var hasSeenOnboarding: Bool = false
    private let legacyTabBarClearance: CGFloat = 49

    @ViewBuilder
    private var tabRoot: some View {
        TabView(selection: $selectedTab) {
            HomeView(switchToSettingsTab: { selectedTab = 3 })
                .tabItem { Label(String(localized: "home_title"), systemImage: "house.fill") }
                .tag(0)

            LibraryView(deepLink: $libraryDeepLink)
                .tabItem { Label(String(localized: "library_title"), systemImage: "books.vertical") }
                .tag(1)

            SearchView(searchText: $searchText)
                .tabItem { Label(String(localized: "search_title"), systemImage: "magnifyingglass") }
                .tag(2)

            SettingsView()
                .tabItem { Label(String(localized: "settings_title"), systemImage: "gearshape") }
                .tag(3)
        }
    }

    @ViewBuilder
    private var playerAwareTabRoot: some View {
        if player.currentSong != nil {
            if #available(iOS 26.0, *) {
                tabRoot
                    .tabBarMinimizeBehavior(.onScrollDown)
                    .tabViewBottomAccessory {
                        NowPlayingAccessory(onTap: { showNowPlaying = true })
                    }
            } else {
                tabRoot
            }
        } else {
            tabRoot
        }
    }

    /// iPad 用的 sidebar + detail 双栏布局。sidebar 顶层就是 Home / 资料库 /
    /// 搜索 / 设置,detail 直接挂对应的现有视图。底部 NowPlaying accessory
    /// 走 body 的 ZStack overlay,不区分 iPhone/iPad。
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
                    ForEach(SidebarItem.libraryChildren) { item in
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
        }
    }

    /// 把 sidebar 选项映射到具体 detail 视图。Library 的子项 (Songs / Albums
    /// / Artists / Playlists) 直接呈现对应的子 list, 并自带一个 NavigationStack
    /// + 必要的 navigationDestination,让 NavigationLink 还能正常 push 详情页。
    @ViewBuilder
    private func padDetail(for item: SidebarItem) -> some View {
        switch item {
        case .home:
            HomeView(switchToSettingsTab: { sidebarSelection = .settings; selectedTab = 3 })
        case .library:
            LibraryView(deepLink: $libraryDeepLink)
        case .librarySongs:
            librarySubpane(title: "tab_songs") { SongListView(songs: library.visibleSongs) }
        case .libraryAlbums:
            librarySubpane(title: "tab_albums") { AlbumGridView() }
        case .libraryArtists:
            librarySubpane(title: "tab_artists") { ArtistListView(artists: library.visibleArtists) }
        case .libraryPlaylists:
            librarySubpane(title: "tab_playlists") { PlaylistListView() }
        case .search:
            SearchView(searchText: $searchText)
        case .settings:
            SettingsView()
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
            if sizeClass == .regular {
                padRoot
            } else {
                playerAwareTabRoot
            }

            if player.currentSong != nil {
                if sizeClass == .regular {
                    // iPad split view 没有底部 tab bar, 直接钉一个紧凑的
                    // mini player 到 detail pane 底部。padding 给 16 留出
                    // 跟系统 home indicator 的呼吸空间。
                    LegacyNowPlayingAccessory(onTap: { showNowPlaying = true })
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                } else if #available(iOS 26.0, *) {
                    EmptyView()
                } else {
                    LegacyNowPlayingAccessory(onTap: { showNowPlaying = true })
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
                PlayerOverlay(isPresented: $showNowPlaying)
                    .zIndex(2)
            }
        }
        .onChange(of: library.visibleSongs.count) { _, _ in
            guard let cs = player.currentSong else { return }
            if !library.visibleSongs.contains(where: { $0.id == cs.id }) {
                player.stop(); player.clearQueue(); showNowPlaying = false
            }
        }
        // 跨年自动弹年度报告 ── 每次 ContentView 进入 (app 启动 / 切前台后
        // 重新出现) 都跑一次, trigger 内部用 UserDefaults 记录已弹避免重复。
        // 触发条件: 当前月份 == 1 + 上一年没弹过 + 上一年听满 ≥ 2 个不同月份。
        .task {
            if let report = YearlyReportAutoTrigger.shouldShowReport(
                library: library,
                sourcesStore: sourcesStore
            ) {
                autoYearlyReport = report
            }
        }
        .fullScreenCover(item: $autoYearlyReport) { data in
            YearlyReportView(data: data)
        }
        // 首启 onboarding —— 仅当未看过且库里没源 (避免 CloudKit 同步迟到时
        // 让老用户重看一次)
        .fullScreenCover(isPresented: Binding(
            get: { !hasSeenOnboarding && sourcesStore.sources.isEmpty },
            set: { if !$0 { hasSeenOnboarding = true } }
        )) {
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
        // SSL trust prompt
        .alert(
            String(localized: "ssl_trust_title"),
            isPresented: Binding(
                get: { SSLTrustStore.shared.pendingTrustRequest != nil },
                set: { if !$0 { SSLTrustStore.shared.resolveTrustRequest(approved: false) } }
            )
        ) {
            Button(String(localized: "trust_domain"), role: .destructive) {
                SSLTrustStore.shared.resolveTrustRequest(approved: true)
            }
            Button(String(localized: "dont_trust"), role: .cancel) {
                SSLTrustStore.shared.resolveTrustRequest(approved: false)
            }
        } message: {
            if let domain = SSLTrustStore.shared.pendingTrustRequest?.domain {
                Text("ssl_trust_message \(domain)")
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
            await player.play(song: song, caller: "Handoff")
            // play(song:) 必定从 0 开始; 立刻 seek 到接力位置, startPlaying
            // 沿用 publisher 的状态。wasPlaying=false 时 seek 后停在该点。
            player.seek(to: resumeTime, startPlaying: wasPlaying)
        }
    }

    /// Spotlight 命中 -> 路由。`song` 直接进 queue 开播; album / artist /
    /// playlist 进入资料库并推到对应详情页。
    private func handleSpotlightItem(_ item: SpotlightItem) {
        switch item {
        case .song(let id):
            guard let song = library.visibleSongs.first(where: { $0.id == id }) else { return }
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
        sidebarSelection = .library
        libraryDeepLink = link
    }
}

// MARK: - Player Overlay (handles position, drag, rounded corners)

struct PlayerOverlay: View {
    @Binding var isPresented: Bool
    /// Drives the entrance animation. Starts `false` on mount so the first
    /// frame renders off-screen (offset = screenHeight + 100); `onAppear`
    /// flips it inside a `withAnimation` so SwiftUI animates the offset to 0.
    /// Without this, the view would render immediately on-screen with no
    /// slide-in because `if showNowPlaying` mounts the view *during*
    /// presentation, not before.
    @State private var entered = false
    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false
    @State private var dismissScale: CGFloat = 1
    @State private var dismissOpacity: CGFloat = 1
    @State private var screenHeight: CGFloat = UIScreen.main.bounds.height

    /// Device screen corner radius (matches physical display)
    private let deviceCornerRadius: CGFloat = 55

    private var dismissProgress: CGFloat {
        min(1, max(0, dragOffset / 400))
    }

    /// Corner radius ramps up to device screen corner radius as user drags down
    private var topCornerRadius: CGFloat {
        if isDismissing { return deviceCornerRadius }
        return dragOffset > 5 ? min(deviceCornerRadius, dragOffset * 1.5) : 0
    }

    /// Bottom corner radius during dismiss (all corners round as it shrinks)
    private var bottomCornerRadius: CGFloat {
        isDismissing ? deviceCornerRadius : 0
    }

    var body: some View {
        NowPlayingView()
            .background {
                GeometryReader { geo in
                    Color.clear.onAppear { screenHeight = geo.size.height }
                }
            }
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: topCornerRadius,
                    bottomLeadingRadius: bottomCornerRadius,
                    bottomTrailingRadius: bottomCornerRadius,
                    topTrailingRadius: topCornerRadius
                )
            )
            .scaleEffect(
                isDismissing ? dismissScale : (1 - dismissProgress * 0.04),
                anchor: .bottom
            )
            .opacity(isDismissing ? dismissOpacity : 1)
            .offset(y: entered ? dragOffset : screenHeight + 100)
            .ignoresSafeArea()
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard !isDismissing, entered else { return }
                        dragOffset = max(0, value.translation.height)
                    }
                    .onEnded { value in
                        guard !isDismissing, entered else { return }
                        if dragOffset > 150 || value.predictedEndTranslation.height > 500 {
                            dismissPlayer()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                dragOffset = 0
                            }
                        }
                    }
            )
            .animation(.spring(response: 0.45, dampingFraction: 0.92), value: entered)
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86), value: dragOffset)
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.92)) {
                    entered = true
                }
            }
    }

    private func dismissPlayer() {
        isDismissing = true
        // Shrink toward the mini player at the bottom; on completion, drop
        // `isPresented` so the parent unmounts the overlay entirely. State
        // reset is unnecessary — the next presentation gets fresh @State.
        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
            dismissScale = 0.12
            dismissOpacity = 0
            dragOffset = screenHeight * 0.6
        } completion: {
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

@available(iOS 26.0, *)
struct NowPlayingAccessory: View {
    var onTap: () -> Void
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool { placement == .inline }

    var body: some View {
        ZStack {
            // Background tap area → opens player
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { onTap() }

            HStack(spacing: 0) {
                // Fixed left: cover art
                CachedArtworkView(
                    coverRef: player.currentSong?.coverArtFileName,
                    songID: player.currentSong?.id ?? "",
                    size: isInline ? 32 : 40,
                    cornerRadius: isInline ? 6 : 8,
                    sourceID: player.currentSong?.sourceID,
                    filePath: player.currentSong?.filePath,
                    revisionToken: player.coverRevision
                )
                .padding(.trailing, isInline ? 10 : 10)

                // Flexible middle: song title fills remaining space
                Text(player.currentSong?.title ?? "")
                    .font(isInline ? .caption : .caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Fixed right: transport controls
                HStack(spacing: isInline ? 0 : 4) {
                    Button { player.togglePlayPause() } label: {
                        ZStack {
                            Image(systemName: "play.fill")
                                .font(isInline ? .subheadline : .body)
                                .opacity(0)
                            if player.isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(isInline ? .subheadline : .body)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .frame(width: isInline ? 28 : 32, height: isInline ? 28 : 32)
                    }
                    .disabled(player.isLoading)
                    .accessibilityLabel(player.isPlaying
                        ? String(localized: "a11y_pause")
                        : String(localized: "a11y_play"))

                    if !isInline {
                        Button { Task { await player.next() } } label: {
                            Image(systemName: "forward.fill").font(.caption)
                                .frame(width: 28, height: 28)
                        }
                        .accessibilityLabel("a11y_next_track")
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, isInline ? 12 : 8)
            .padding(.vertical, isInline ? 2 : 4)
        }
    }
}



#Preview {
    ContentView()
        .environment(AudioPlayerService())
        .environment(MusicLibrary())
}
