import SwiftUI
import WatchKit

/// Watch 端的正在播放, 一屏放下, 不用滚动 (#353)。
///
/// 布局: 左上播放列表、右上更多; 中间封面 (有歌词时点一下换成歌词); 歌名 / 艺人;
/// 底部上一首 · 播放暂停 (外圈是进度) · 下一首。有声内容两侧换成快退 / 快进,
/// 电台只有能换台时才有两侧键。
///
/// 数字表冠调 iPhone 的音量 (系统音量控件, 和 Apple Music 一样, 戴着 AirPods 时就是
/// AirPods 的音量)。控件平时藏着, 转表冠时才在表冠一侧亮出来, 停下后淡出。
/// 拖进度挪到「更多 → 调整进度」, 在那一页里表冠调进度。
struct NowPlayingWatchView: View {
    @Environment(WatchPlayerStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    /// 封面和歌词两面, 记住上次停在哪一面。
    @AppStorage("watch.nowPlaying.showsLyrics") private var prefersLyrics = false
    @State private var showsQueue = false
    @State private var showsOptions = false
    /// 每加一次, 音量控件就重新要一次表冠: 回到这页、从后台回来、关掉弹出页之后
    /// 表冠都被别的页面拿走过。
    @State private var volumeFocusRequest = 0
    /// 音量控件这会儿亮着没有。手表收不到表冠转动, 靠 iPhone 推来的音量变化判断。
    @State private var showsVolume = false
    @State private var volumeHideTask: Task<Void, Never>?

    var body: some View {
        Group {
            if store.hasSong {
                playerLayout
            } else {
                WatchEmptyStateView()
            }
        }
        .containerBackground(for: .navigation) {
            WatchNowPlayingBackdrop(cover: store.coverImage, accent: store.accent)
        }
        .toolbar {
            if store.hasSong, !store.isLiveStream {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showsQueue = true
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel(WatchString("ext.watch.queue.title"))
                }
            }
            if store.hasSong {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsOptions = true
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(WatchString("ext.watch.more.title"))
                }
            }
        }
        .navigationDestination(isPresented: $showsQueue) {
            LibraryWatchView()
        }
        .sheet(isPresented: $showsOptions, onDismiss: requestVolumeFocus) {
            WatchPlaybackOptionsView()
        }
        .onAppear {
            store.requestCurrentState()
            requestVolumeFocus()
            #if DEBUG
            openDemoScreenIfNeeded()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { requestVolumeFocus() }
        }
        .onChange(of: store.hasSong) { _, hasSong in
            if hasSong { requestVolumeFocus() }
        }
        .onChange(of: store.volumeActivity) { _, _ in
            revealVolume()
        }
    }

    private var playerLayout: some View {
        // 量一下顶上那一行 (时间和两颗按钮) 占了多高, 封面往上伸进两颗按钮中间。
        GeometryReader { proxy in
            VStack(spacing: 4) {
                stage(topReach: WatchNowPlayingMetrics.artworkTopReach(
                    navigationBarHeight: proxy.safeAreaInsets.top
                ))
                titleBlock
                WatchTransportControls()
                    .padding(.top, 2)
                    .opacity(store.isReachable ? 1 : 0.45)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, WatchNowPlayingMetrics.bottomInset)
        }
        // 底部安全区留给系统的底栏, 这页没有底栏: 播放键往下放, 封面多出这一截高度。
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var showsLyricsFace: Bool {
        prefersLyrics && store.hasLyrics && !store.isLiveStream
    }

    /// 封面 / 歌词那一块吃掉标题和播放键剩下的高度, 所以各种表盘尺寸、各档字号都放得下。
    /// 封面上沿再往上伸 `topReach`, 到时间下面、两颗按钮中间那块空地 (和 Apple Music 一样);
    /// 歌词一行行很宽, 仍待在按钮下面。
    private func stage(topReach: CGFloat) -> some View {
        ZStack {
            if showsLyricsFace {
                WatchLyricsPanel()
                    .padding(.horizontal, 4)
                    .padding(.top, topReach)
                    .transition(.opacity)
            } else {
                WatchArtworkView()
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: WatchNowPlayingMetrics.maxArtworkSide)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, -topReach)
        .contentShape(Rectangle())
        .onTapGesture {
            guard store.hasLyrics, !store.isLiveStream else { return }
            withAnimation(.easeInOut(duration: 0.25)) { prefersLyrics.toggle() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(store.hasLyrics && !store.isLiveStream ? .isButton : [])
        .accessibilityHint(store.hasLyrics && !store.isLiveStream
            ? WatchString(showsLyricsFace ? "ext.watch.lyrics.hide" : "ext.watch.lyrics.show")
            : "")
        // 音量控件贴在表冠这一侧, 平时藏着不占地方, 转表冠时才亮出来、盖在封面或歌词上。
        // 系统按自己的尺寸画这个圆环, 不跟外面给的框走 (41mm 上调音量时约 47pt, 右边一截跑到屏外),
        // 所以按它最大的样子留框、整体缩小, 再从屏幕边上收进来一点。
        .overlay(alignment: .trailing) {
            WatchCompanionVolumeControl(tint: store.accent, focusRequest: volumeFocusRequest)
                .frame(width: WatchNowPlayingMetrics.volumeControlNativeSide,
                       height: WatchNowPlayingMetrics.volumeControlNativeSide)
                .background(.black.opacity(0.45), in: Circle().inset(by: 4))
                .scaleEffect(WatchNowPlayingMetrics.volumeControlScale)
                .frame(width: WatchNowPlayingMetrics.volumeControlSide,
                       height: WatchNowPlayingMetrics.volumeControlSide)
                .padding(.trailing, 2)
                .opacity(showsVolume ? 1 : WatchNowPlayingMetrics.hiddenVolumeOpacity)
        }
        .overlay(alignment: .top) {
            if !store.isReachable {
                WatchUnreachableBadge()
            }
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 0) {
            Text(store.title)
                .font(.headline)
                .lineLimit(1)
            if store.isLiveStream {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                    Text(store.artist.isEmpty ? WatchString("ext.watch.radio.live") : store.artist)
                        .lineLimit(1)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if !store.artist.isEmpty, !showsLyricsFace {
                // 歌词面把艺人这一行的高度让给歌词。
                Text(store.artist)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }

    private func requestVolumeFocus() {
        volumeFocusRequest &+= 1
    }

    /// 音量变了: 亮出音量控件, 停下 1.5 秒再淡出; 连着调时一直顺延。
    private func revealVolume() {
        withAnimation(.easeOut(duration: 0.15)) { showsVolume = true }
        volumeHideTask?.cancel()
        volumeHideTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.4)) { showsVolume = false }
        }
    }

    #if DEBUG
    /// 截图用: PRIMUSE_WATCH_DEMO_SCREEN=queue / options 直接打开那一页, volume 让音量控件一直亮着。
    private func openDemoScreenIfNeeded() {
        switch store.demoScreen {
        case "queue": showsQueue = true
        case "options", "seek": showsOptions = true
        case "volume": showsVolume = true
        default: break
        }
    }
    #endif
}

/// 几种表盘尺寸共用的比例 (40mm 宽 162pt 到 Ultra / 46mm 宽 205–208pt)。
enum WatchNowPlayingMetrics {
    static var screenWidth: CGFloat { WKInterfaceDevice.current().screenBounds.width }
    /// 播放暂停键连外圈进度的直径。比封面小一截, 封面才是这一页的主角。
    static var playDiameter: CGFloat { min(58, max(44, (screenWidth * 0.28).rounded())) }
    static var sideDiameter: CGFloat { (playDiameter * 0.76).rounded() }
    /// 系统音量圆环自己画多大: 模拟器上约 38pt, 真机调音量时约 47pt。按大的留。
    static let volumeControlNativeSide: CGFloat = 48
    static let volumeControlScale: CGFloat = 0.7
    static var volumeControlSide: CGFloat { (volumeControlNativeSide * volumeControlScale).rounded() }
    /// 音量控件藏起来时不设成 0: 完全透明的控件有可能被系统当成看不见, 表冠就交不到它手上。
    /// 留这一点点肉眼看不出来。
    static let hiddenVolumeOpacity: Double = 0.02
    /// 封面伸进顶上那一行之后两边是按钮, 宽度不能超过两颗按钮之间的空地。
    static var maxArtworkSide: CGFloat { (screenWidth * 0.56).rounded() }
    /// 封面往顶上那一行里伸多少: 时间在这一行上半截, 下半截两颗按钮之间是空的。
    static func artworkTopReach(navigationBarHeight: CGFloat) -> CGFloat {
        (navigationBarHeight * 0.2).rounded()
    }
    /// 播放键离屏幕下沿的距离, 圆角处两侧键不被切到。
    static var bottomInset: CGFloat { screenWidth >= 190 ? 10 : 6 }
}

/// 封面。没有封面时用主色渐变垫一个符号; 暂停时略微缩小 (和 Apple Music 一样)。
struct WatchArtworkView: View {
    @Environment(WatchPlayerStore.self) private var store

    var body: some View {
        Color.clear
            .overlay {
                if let cover = store.coverImage {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(
                        colors: [store.accent.opacity(0.85), store.accent.opacity(0.35)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .overlay {
                        Image(systemName: placeholderSymbol)
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                if store.hasLyrics, !store.isLiveStream {
                    // 提示这里点一下能看歌词。
                    Image(systemName: "quote.bubble.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(.black.opacity(0.45), in: Circle())
                        .padding(4)
                        .accessibilityHidden(true)
                }
            }
            .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
            .scaleEffect(store.isPlaying || store.isLoading ? 1 : 0.88)
            .animation(.spring(duration: 0.35), value: store.isPlaying)
    }

    private var placeholderSymbol: String {
        if store.isLiveStream { return "radio.fill" }
        if store.usesSkipIntervals { return "book.fill" }
        return "music.note"
    }
}

/// 歌词那一面: 当前这句大字, 下一句淡显在下面; 间奏时显示省略号。
struct WatchLyricsPanel: View {
    @Environment(WatchPlayerStore.self) private var store

    var body: some View {
        ZStack {
            Group {
                if store.currentLyric.isEmpty {
                    Image(systemName: "ellipsis")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .symbolEffect(.variableColor.iterative, isActive: store.isPlaying)
                } else {
                    // 小表盘上高度只够两三行: 放不下就先缩字, 再省掉下一句。
                    // 候选里当前这句不能限行数: 限了就被截成那几行, 量出来永远「放得下」,
                    // 长句停在大字号上被截断, 轮不到后面的小字号。
                    ViewThatFits(in: .vertical) {
                        lines(current: .title3, nextLines: 2)
                        lines(current: .body, nextLines: 1)
                        lines(current: .body, nextLines: 0)
                        lines(current: .footnote, nextLines: 0)
                        // 最小字号也放不下: 再缩一点, 还不够才截断。
                        lines(current: .footnote, nextLines: 0, minimumScale: 0.75)
                    }
                }
            }
            .multilineTextAlignment(.center)
            .id(store.currentLyric)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 10)),
                removal: .opacity
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.3), value: store.currentLyric)
    }

    private func lines(current font: Font.TextStyle, nextLines: Int, minimumScale: CGFloat = 1) -> some View {
        VStack(spacing: 4) {
            Text(store.currentLyric)
                .font(.system(font, design: .rounded).weight(.semibold))
                .foregroundStyle(.white)
                .minimumScaleFactor(minimumScale)
            if nextLines > 0, !store.nextLyric.isEmpty {
                Text(store.nextLyric)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(nextLines)
            }
        }
    }
}

/// 整页底色: 封面糊开铺满, 再压一层主色到黑的渐变, 文字和按钮都看得清。
struct WatchNowPlayingBackdrop: View {
    let cover: UIImage?
    let accent: Color
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        // 先让底色占满整块容器, 封面再盖上去裁掉多出的部分。直接把 scaledToFill 的封面放进
        // ZStack 当底, 容器背景只铺到底部安全区上沿, 下面露出一截黑边。
        Color.black
            .overlay {
                if let cover {
                    Image(uiImage: cover)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 26, opaque: true)
                        .saturation(1.2)
                        .opacity(isLuminanceReduced ? 0.3 : 0.7)
                }
            }
            .overlay {
                LinearGradient(
                    colors: [
                        accent.opacity(cover == nil ? 0.5 : 0.2),
                        .black.opacity(0.6),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .clipped()
            .ignoresSafeArea()
    }
}

/// iPhone 不可达时浮在封面上方的提示: 这时按键都只会重新拉一次状态。
struct WatchUnreachableBadge: View {
    var body: some View {
        Label(WatchString("ext.watch.unreachable.badge"), systemImage: "iphone.slash")
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

/// 还没有播放 / 连不上 iPhone。
struct WatchEmptyStateView: View {
    @Environment(WatchPlayerStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: store.isReachable ? "music.note" : "iphone.slash")
                    .font(.system(size: 34))
                    .foregroundStyle(store.isReachable ? store.accent : .secondary)
                    .padding(.top, 8)
                Text(WatchString(store.isReachable
                                 ? "ext.watch.nowPlaying.empty.title"
                                 : "ext.watch.nowPlaying.empty.unreachableTitle"))
                    .font(.headline)
                Text(WatchString(store.isReachable
                                 ? "ext.watch.nowPlaying.empty.reachable"
                                 : "ext.watch.nowPlaying.empty.unreachable"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if !store.isReachable {
                    Button(WatchString("ext.watch.retry")) {
                        store.requestCurrentState()
                    }
                    .padding(.top, 4)
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
    }
}
