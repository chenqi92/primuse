import SwiftUI
import PrimuseKit

/// iPad sidebar 顶层入口。`rawValue` 跟 iPhone TabView 的 tag 对齐,
/// 这样 `selectedTab: Int` 同一份 state 两端都能复用,sidebar 切到设置
/// 等同于 phone 端切 tab 3。
private enum SidebarItem: Int, CaseIterable, Identifiable, Hashable {
    case home = 0
    case library = 1
    case search = 2
    case settings = 3

    var id: Int { rawValue }

    var titleKey: String.LocalizationValue {
        switch self {
        case .home: return "home_title"
        case .library: return "library_title"
        case .search: return "search_title"
        case .settings: return "settings_title"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "books.vertical"
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
    @State private var searchText = ""
    @State private var showNowPlaying = false
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

            LibraryView()
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
            // 显式 sidebar style + ForEach + selection — Label 单独配 tag 在
            // iPad 上有时不响应点击。改用 ForEach 让 SwiftUI 把每一行当真正
            // 的 list row 渲染,并通过 button-style selection 触发。
            // iOS 的 List(selection:) 单选签名要求 Binding<Hashable?>。
            let selection = Binding<Int?>(
                get: { selectedTab },
                set: { if let v = $0 { selectedTab = v } }
            )
            List(selection: selection) {
                ForEach(SidebarItem.allCases) { item in
                    Label(String(localized: item.titleKey), systemImage: item.icon)
                        .tag(item.rawValue as Int?)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Primuse")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            // 现有 Home/Library/Settings/Search 自己内部都有 NavigationStack,
            // 直接挂在 detail 里; 不再额外包 stack 防止双重导航 chrome。
            switch selectedTab {
            case 1: LibraryView()
            case 2: SearchView(searchText: $searchText)
            case 3: SettingsView()
            default: HomeView(switchToSettingsTab: { selectedTab = 3 })
            }
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
        // Spotlight 搜歌点击 ── identifier 形如 "song:<id>" / "album:<id>" 等,
        // song 直接播,其他先切到资料库标签让用户落地(后续可以做完整 deep link)。
        .onContinueUserActivity("com.apple.corespotlight.searchableitem") { activity in
            guard let item = SpotlightIndexService.identifier(from: activity) else { return }
            handleSpotlightItem(item)
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

    /// Spotlight 命中 -> 路由。`song` 直接进 queue 开播; album / artist /
    /// playlist 暂时只把用户带到资料库 tab (深链落到具体详情页留作后续)。
    private func handleSpotlightItem(_ item: SpotlightItem) {
        switch item {
        case .song(let id):
            guard let song = library.visibleSongs.first(where: { $0.id == id }) else { return }
            // 命中歌 + 整库剩下的拼起来当队列,跟 Siri / Shortcuts 同款行为
            let rest = library.visibleSongs.filter { $0.id != id }
            player.setQueue([song] + rest, startAt: 0)
            Task { await player.play(song: song, caller: "Spotlight") }
        case .album, .artist, .playlist:
            // TODO: 深链到具体详情页 — 需要 LibraryView 暴露一个 path binding。
            selectedTab = 1
        }
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

                    if !isInline {
                        Button { Task { await player.next() } } label: {
                            Image(systemName: "forward.fill").font(.caption)
                                .frame(width: 28, height: 28)
                        }
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
