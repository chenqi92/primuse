#if os(tvOS)
import SwiftUI
import PrimuseKit

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

/// tvOS 根布局 — 顶部自定义 tab bar(Apple TV / Apple Music for tvOS 风) + 全屏内容
/// + 底部常驻「正在播放」条。正在播放 / 队列 / 选项 / 设置都以全屏覆盖呈现。
struct TVRoot: View {
    enum Tab: Hashable { case home, library, playlists, sources, search }

    @Environment(TVStore.self) private var store
    @State private var tab: Tab = .home
    @State private var showNowPlaying = false
    @State private var showSettings = false
    @State private var showQueue = false
    @State private var showOptions = false
    @State private var libraryFocusRequest = 0
    @State private var tabFocusRequest = 0
    @State private var isTabBarFocused = true

    init() {
        #if DEBUG
        // 截图预览用:SIMCTL_CHILD_TV_SCREEN=<tab> 直接进入指定页。
        switch TVDebugLaunch.screen {
        case "library": _tab = State(initialValue: .library)
        case "playlists": _tab = State(initialValue: .playlists)
        case "sources", "sourcePicker", "sourceForm", "credentials", "otp", "scan", "recycleBin":
            _tab = State(initialValue: .sources)
        case "search": _tab = State(initialValue: .search)
        default: break
        }
        #endif
    }

    var body: some View {
        rootContent
            .modifier(TVReturnToTabsModifier(enabled: !isTabBarFocused) {
                tabFocusRequest &+= 1
            })
            .onPlayPauseCommand {
                guard store.hasNowPlaying else { return }
                store.togglePlayPause()
            }
    }

    private var rootContent: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()

            content
                .transition(.opacity)

            VStack(spacing: 0) {
                TVTabBar(
                    active: tab,
                    onSelect: { tab = $0 },
                    onLibraryDown: { libraryFocusRequest &+= 1 },
                    focusRequest: tabFocusRequest,
                    onFocusChanged: { isTabBarFocused = $0 },
                    onSettings: { showSettings = true }
                )
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                TVBottomBar(openPlayer: { showNowPlaying = true })
            }
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            TVNowPlayingView().environment(store)
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
        .task {
            #if DEBUG
            switch TVDebugLaunch.screen {
            case "nowPlaying":
                await waitForDemoContent(requireAlbum: true)
                if let album = store.albums.first { store.play(album: album) }
                showNowPlaying = true
            case "nowPlayingDemo":   // 截图用:注入演示播放态+歌词,不走真实播放
                await waitForDemoContent()
                await store.loadDemoNowPlaying()
                showNowPlaying = true
            case "nowPlayingSongArtwork":
                await waitForDemoContent()
                if await store.loadDemoNowPlaying(preferSongArtwork: true) {
                    showNowPlaying = true
                }
            case "queue":
                await waitForDemoContent()
                await store.loadDemoNowPlaying()
                showQueue = true
            case "options":
                await waitForDemoContent()
                await store.loadDemoNowPlaying()
                showOptions = true
            case "settings": showSettings = true
            default: break
            }
            #endif
        }
    }

    #if DEBUG
    private func waitForDemoContent(requireAlbum: Bool = false) async {
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
        case .home:      TVHomeView(openPlayer: { showNowPlaying = true })
        case .library:
            TVLibraryView(
                openPlayer: { showNowPlaying = true },
                focusRequest: libraryFocusRequest
            )
        case .playlists: TVPlaylistsView(openPlayer: { showNowPlaying = true })
        case .sources:   TVSourcesView()
        case .search:    TVSearchView(openPlayer: { showNowPlaying = true })
        }
    }
}

// MARK: - 顶部 tab bar

struct TVTabBar: View {
    let active: TVRoot.Tab
    var onSelect: (TVRoot.Tab) -> Void
    var onLibraryDown: () -> Void
    var focusRequest: Int
    var onFocusChanged: (Bool) -> Void
    var onSettings: () -> Void
    @FocusState private var focusedTab: TVRoot.Tab?

    private let tabs: [(TVRoot.Tab, String)] = [
        (.home, PMString("ext.tv.nav.home")), (.library, PMString("ext.tv.nav.library")),
        (.playlists, PMString("ext.tv.nav.playlists")),
        (.sources, PMString("ext.tv.nav.sources")), (.search, PMString("ext.tv.nav.search")),
    ]

    private var debugFocusTab: TVRoot.Tab? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["TV_FOCUS_TAB"] {
        case "home": return .home
        case "library": return .library
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
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(TVColor.text)
            }

            HStack(spacing: 8) {
                ForEach(tabs, id: \.0) { item in
                    TVTabItem(
                        label: item.1,
                        isActive: item.0 == active,
                        isFocused: item.0 == focusedTab
                    ) {
                        onSelect(item.0)
                    }
                    .focused($focusedTab, equals: item.0)
                }
            }
            .focusSection()
            .onChange(of: focusedTab) { _, focused in
                onFocusChanged(focused != nil)
                if let focused, focused != active { onSelect(focused) }
            }
            .onChange(of: focusRequest) {
                focusedTab = active
            }
            .onMoveCommand { direction in
                if direction == .down, focusedTab == .library {
                    onLibraryDown()
                }
            }
            .onAppear {
                #if DEBUG
                if let debugFocusTab { focusedTab = debugFocusTab }
                #endif
            }

            Spacer(minLength: 0)

            // 设置入口(原账户头像改为设置按钮)
            TVFocusButton(radius: 28, scale: 1.08, lift: 0, action: onSettings) { focused in
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
                    .frame(width: 56, height: 56)
                    .background(focused ? AnyShapeStyle(TVColor.brand)
                                        : AnyShapeStyle(TVColor.surfaceStrong), in: Circle())
            }
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

private struct TVTabItem: View {
    let label: String
    let isActive: Bool
    let isFocused: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 26, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive || isFocused ? TVColor.text : TVColor.textMuted)
                .padding(.horizontal, 24).padding(.vertical, 10)
                .background(isFocused ? TVColor.surfaceStrong : .clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(TVColor.focusRing, lineWidth: isFocused ? 3 : 0)
                }
                .scaleEffect(isFocused ? 1.08 : 1)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
        .buttonStyle(TVBareButtonStyle())
        .focusEffectDisabled()
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
                        Text(np.title).font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(TVColor.text).lineLimit(1)
                        Text(store.isLiveRadio ? np.artist : "\(np.artist) · \(np.album)")
                            .font(.system(size: 16))
                            .foregroundStyle(TVColor.textMuted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if store.isLiveRadio {
                        HStack(spacing: 9) {
                            Circle().fill(Color.red).frame(width: 10, height: 10)
                            Text(PMString("ext.tv.radio.live"))
                                .font(.system(size: 16, weight: .bold))
                            if store.currentTime > 0 {
                                Text("· \(TVFmt.time(store.currentTime))")
                                    .font(.system(size: 15, design: .monospaced))
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
                            .font(.system(size: 14, design: .monospaced))
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
                TVRoundBtn(icon: "forward.fill", size: 48) { store.next() }
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
            TVRadioArtworkView(station: station, size: 48, radius: 8)
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
    var body: some View {
        Text(text.uppercased())
            .font(TVFont.eyebrow).tracking(1.4)
            .foregroundStyle(TVColor.textFaint)
    }
}
#endif
