#if os(tvOS)
import SwiftUI

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

    init() {
        #if DEBUG
        // 截图预览用:SIMCTL_CHILD_TV_SCREEN=<tab> 直接进入指定页。
        switch ProcessInfo.processInfo.environment["TV_SCREEN"] {
        case "library": _tab = State(initialValue: .library)
        case "playlists": _tab = State(initialValue: .playlists)
        case "sources": _tab = State(initialValue: .sources)
        case "search": _tab = State(initialValue: .search)
        default: break
        }
        #endif
    }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()

            content
                .transition(.opacity)

            VStack(spacing: 0) {
                TVTabBar(active: tab, onSelect: { tab = $0 }, onSettings: { showSettings = true })
                Spacer(minLength: 0)
            }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                TVBottomBar(openPlayer: { showNowPlaying = true })
            }
        }
        .preferredColorScheme(.dark)
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
            switch ProcessInfo.processInfo.environment["TV_SCREEN"] {
            case "nowPlaying":
                var tries = 0
                while store.albums.isEmpty && tries < 25 {
                    try? await Task.sleep(nanoseconds: 200_000_000); tries += 1
                }
                if let album = store.albums.first { store.play(album: album) }
                showNowPlaying = true
            case "queue": showQueue = true
            case "options": showOptions = true
            case "settings": showSettings = true
            default: break
            }
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .home:      TVHomeView(openPlayer: { showNowPlaying = true })
        case .library:   TVLibraryView(openPlayer: { showNowPlaying = true })
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
    var onSettings: () -> Void

    private let tabs: [(TVRoot.Tab, String)] = [
        (.home, "首页"), (.library, "资料库"), (.playlists, "歌单"),
        (.sources, "音乐源"), (.search, "搜索"),
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
            // Logo(真实 App 图标)
            HStack(spacing: 14) {
                Image("BrandMark")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: TVColor.brand.opacity(0.33), radius: 12, y: 6)
                Text("Primuse").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
            }

            HStack(spacing: 8) {
                ForEach(tabs, id: \.0) { item in
                    TVTabItem(label: item.1, isActive: item.0 == active,
                              forceFocus: item.0 == debugFocusTab) { onSelect(item.0) }
                }
            }
            .focusSection()

            Spacer(minLength: 0)

            // 设置入口(原账户头像改为设置按钮)
            TVFocusButton(radius: 28, accent: .white, scale: 1.08, lift: 0, action: onSettings) { focused in
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(focused ? Color(hex: "#1f1c19") : .white)
                    .frame(width: 56, height: 56)
                    .background(focused ? AnyShapeStyle(Color.white)
                                        : AnyShapeStyle(Color.white.opacity(0.12)), in: Circle())
            }
        }
        .padding(.horizontal, TVSpace.pageH)
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.black.opacity(0.78), .black.opacity(0.4), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
        .focusSection()
    }
}

private struct TVTabItem: View {
    let label: String
    let isActive: Bool
    var forceFocus: Bool = false
    var action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 26, weight: isActive ? .bold : .medium))
                .foregroundStyle(isActive || focused ? .white : .white.opacity(0.62))
                .padding(.horizontal, 24).padding(.vertical, 10)
                .background(focused ? Color.white.opacity(0.18) : .clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white, lineWidth: focused ? 3 : 0)
                }
                .scaleEffect(focused ? 1.08 : 1)
                .animation(.easeOut(duration: 0.18), value: focused)
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            #if DEBUG
            if forceFocus { Task { @MainActor in focused = true } }
            #endif
        }
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
                    TVArtworkView(coverKey: np.albumID, artist: np.artist, album: np.album,
                                  tint: np.tint, tint2: np.tint2, glyph: np.glyph, size: 62, radius: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(np.title).font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white).lineLimit(1)
                        Text("\(np.artist) · \(np.album)").font(.system(size: 16))
                            .foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 6) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.16)).frame(height: 4)
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
                        .foregroundStyle(.white.opacity(0.55))
                    }
                    .frame(width: 460)
                }
                .padding(.leading, TVSpace.pageH)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 96)
                .background(focused ? Color.white.opacity(0.06) : .clear)
                .overlay(alignment: .top) {
                    Rectangle().fill(.white.opacity(focused ? 0.9 : 0)).frame(height: 3)
                }
            }
            .buttonStyle(TVBareButtonStyle())
            .focused($focused)
            .focusEffectDisabled()

            // 独立的播放/暂停 + 下一首键(在底部条直接控,不必进全屏播放页)。
            TVRoundBtn(icon: store.isPlaying ? "pause.fill" : "play.fill", size: 56, primary: true) {
                store.togglePlayPause()
            }
            TVRoundBtn(icon: "forward.fill", size: 48) { store.next() }
                .padding(.trailing, TVSpace.pageH)
        }
        .frame(height: 96)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6), .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
        )
        .animation(.easeOut(duration: 0.18), value: focused)
    }

    private var progress: Double {
        let dur = store.duration
        return dur > 0 ? max(0, min(1, store.currentTime / dur)) : 0
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
