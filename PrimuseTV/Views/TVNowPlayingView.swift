#if os(tvOS)
import AVKit
import SwiftUI
import PrimuseKit
import UIKit

/// tvOS 正在播放 — 左列封面+元数据+进度+传输键,右列巨幅逐字歌词(对应 TVNowPlayingArtboard)。
/// Menu 键返回;右上角可打开队列 / 选项。
struct TVNowPlayingView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var isTabContent = false
    var focusRequest: TVContentFocusRequest?
    var onContentAppeared: (TVNowPlayingFocusMode) -> Void = { _ in }
    var onContentModeChanged: (TVNowPlayingFocusMode) -> Void = { _ in }
    var onReturnToTabs: () -> Void = {}

    @State private var showQueue = false
    @State private var showOptions = false
    @State private var showImmersive = false
    @State private var immersiveStartsWithEffectPicker = false
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var fullscreenPlayerEffectRawValue = FullscreenPlayerEffect.defaultValue.rawValue
    /// 最近一次遥控操作的时间戳。播放中静置一段时间自动进入沉浸展示。
    @State private var lastInteraction = Date()
    @Namespace private var playerFocus
    @FocusState private var focusedTransport: TVNowPlayingFocusTarget?

    /// 播放中静置多久自动进入沉浸展示(设计稿「展示屏」的待机语义)。
    private let immersiveIdleThreshold: TimeInterval = 20

    private var fullscreenPlayerEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: fullscreenPlayerEffectRawValue) ?? .defaultValue
    }

    private func presentImmersivePlayer() {
        immersiveStartsWithEffectPicker = fullscreenPlayerEffect == .native
        showImmersive = true
    }

    var body: some View {
        ZStack {
            if store.hasNowPlaying { player } else { emptyState }
        }
        .onExitCommand {
            if isTabContent {
                onReturnToTabs()
            } else {
                dismiss()
            }
        }
        .onAppear {
            FullscreenPlayerEffectSync.shared.install()
            onContentAppeared(focusMode)
        }
        .task(id: focusRequest?.id) {
            guard let request = focusRequest else { return }
            await Task.yield()
            guard !Task.isCancelled, focusRequest == request else { return }
            applyFocusRequest(request)
        }
        .onChange(of: focusMode) { _, mode in
            onContentModeChanged(mode)
        }
        .fullScreenCover(isPresented: $showQueue) { TVQueueView().environment(store) }
        .fullScreenCover(isPresented: $showOptions) { TVOptionsView().environment(store) }
        .fullScreenCover(isPresented: $showImmersive) {
            TVImmersivePlayerView(
                presentsModePickerOnAppear: immersiveStartsWithEffectPicker
            )
            .environment(store)
        }
        .onChange(of: focusedTransport) { _, _ in
            // 遥控切换焦点即视为有操作,推迟自动进入沉浸展示。
            lastInteraction = Date()
        }
        .onChange(of: showImmersive) { _, presented in
            if !presented {
                immersiveStartsWithEffectPicker = false
                lastInteraction = Date()
            }
        }
        .task(id: store.hasNowPlaying) {
            // 仅普通歌曲播放态跑空闲检测:直播 / MV 有自己的画面,不进入沉浸展示。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard store.hasNowPlaying, store.isPlaying,
                      !store.isLiveRadio, !store.isMusicVideoPlaybackActive,
                      fullscreenPlayerEffect != .native,
                      !showImmersive, !showQueue, !showOptions else { continue }
                if Date().timeIntervalSince(lastInteraction) >= immersiveIdleThreshold {
                    showImmersive = true
                }
            }
        }
    }

    private var emptyState: some View {
        ZStack {
            TVAmbientBackdrop(strength: 0.55)
            VStack(spacing: 18) {
                Image(systemName: "play.circle").font(.system(size: 96))
                    .foregroundStyle(TVColor.textFaint)
                Text(PMString("ext.tv.nowPlaying.notPlaying")).font(.system(size: 40, weight: .bold)).foregroundStyle(TVColor.text)
                Text(PMString("ext.tv.nowPlaying.pickASong")).font(.system(size: 22)).foregroundStyle(TVColor.textMuted)
            }
            .padding(.top, isTabContent ? TVSpace.pageTop / 2 : 0)
        }
    }

    private var player: some View {
        let np = store.nowPlaying
        return ZStack {
            TVAmbientBackdrop(tint: np.tint, tint2: np.tint2, strength: 1)
            if store.isLiveRadio {
                liveRadioPlayer
            } else if store.isMusicVideoPlaybackActive {
                musicVideoFullScreenPlayer
            } else {
                LinearGradient(colors: playerScrim,
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                HStack(alignment: .top, spacing: 80) {
                    leftColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .focusSection()
                    lyricsColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .focusScope(playerFocus)
                .padding(.horizontal, 100)
                .padding(.top, isTabContent ? TVSpace.pageTop : 80)
                .padding(.bottom, isTabContent ? TVSpace.pageBottom : 70)
            }
        }
    }

    private var liveRadioPlayer: some View {
        ZStack {
            LinearGradient(colors: playerScrim, startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            HStack(spacing: 84) {
                if let station = store.currentRadioStation {
                    TVRadioArtworkView(station: station, size: 500, radius: 30)
                        .shadow(color: .black.opacity(0.55), radius: 42, y: 22)
                } else {
                    TVMusicPlaceholder(
                        tint: store.nowPlaying.tint,
                        tint2: store.nowPlaying.tint2,
                        size: 500,
                        radius: 30
                    )
                }

                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: PMString("ext.tv.radio.title"))
                    Text(store.nowPlaying.title)
                        .font(.system(size: 72, weight: .bold))
                        .tracking(-1.2)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2)
                        .padding(.top, 18)
                    Text(store.nowPlaying.artist)
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(TVColor.textMuted)
                        .lineLimit(2)
                        .padding(.top, 14)

                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 13, height: 13)
                            .shadow(color: .red.opacity(0.7), radius: 8)
                        Text(PMString("ext.tv.radio.live"))
                            .font(.system(size: 22, weight: .bold))
                        if store.currentTime > 0 {
                            Text("· \(TVFmt.time(store.currentTime))")
                                .font(.system(size: 21, design: .monospaced))
                        }
                    }
                    .foregroundStyle(TVColor.text)
                    .padding(.top, 26)

                    if let issue = store.playbackIssue {
                        Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(TVColor.warn)
                            .lineLimit(3)
                            .padding(.top, 22)
                    }

                    Spacer(minLength: 34)

                    HStack(spacing: 18) {
                        focusedRoundButton(
                            icon: "backward.fill",
                            size: 76,
                            target: .previous
                        ) {
                            store.previous()
                        }
                        .disabled(store.radioStations.count < 2)

                        focusedRoundButton(
                            icon: radioConnectionIsActive ? "stop.fill" : "play.fill",
                            size: 96,
                            primary: true,
                            target: .liveRadioPrimary
                        ) {
                            store.togglePlayPause()
                        }
                        .prefersDefaultFocus(true, in: playerFocus)

                        focusedRoundButton(
                            icon: "forward.fill",
                            size: 76,
                            target: .next
                        ) {
                            store.next()
                        }
                        .disabled(store.radioStations.count < 2)

                        Text(PMString(radioConnectionIsActive ? "ext.tv.radio.stop" : "ext.tv.radio.play"))
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(TVColor.textMuted)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 500, alignment: .leading)
                .focusSection()
            }
            .focusScope(playerFocus)
            .padding(.horizontal, 110)
            .padding(.top, isTabContent ? TVSpace.pageTop : 110)
            .padding(.bottom, isTabContent ? TVSpace.pageBottom : 110)
        }
    }

    private var radioConnectionIsActive: Bool {
        store.engine.status == .loading || store.engine.status == .playing
    }

    private var focusMode: TVNowPlayingFocusMode {
        guard store.hasNowPlaying else { return .empty }
        return store.isLiveRadio ? .liveRadio : .song
    }

    private func applyFocusRequest(_ request: TVContentFocusRequest?) {
        guard let request,
              request.target == TVContentFocusRoutingPolicy.target(
                  for: .nowPlaying,
                  nowPlayingMode: focusMode
              ),
              case let .nowPlaying(target) = request.target else {
            return
        }
        focusedTransport = target
    }

    private func focusedRoundButton(
        icon: String,
        size: CGFloat,
        primary: Bool = false,
        immersiveDark: Bool = false,
        target: TVNowPlayingFocusTarget,
        action: @escaping () -> Void
    ) -> some View {
        let focused = focusedTransport == target
        return Button {
            lastInteraction = Date()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(primary
                                 ? (immersiveDark ? Color(hex: "#1f1c19") : TVColor.onBrand)
                                 : (immersiveDark ? Color.white : TVColor.text))
                .frame(width: size, height: size)
                .background(primary
                            ? AnyShapeStyle(immersiveDark ? Color.white : TVColor.brand)
                            : AnyShapeStyle(immersiveDark ? Color.white.opacity(0.14) : TVColor.surfaceStrong),
                            in: Circle())
                .tvFocusRing(
                    focused,
                    radius: size / 2,
                    accent: immersiveDark ? Color.white : TVColor.focusRing,
                    scale: 1.14,
                    lift: 8
                )
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focusedTransport, equals: target)
        .focusEffectDisabled()
    }

    // MARK: 左列

    private var musicVideoFullScreenPlayer: some View {
        let np = store.nowPlaying
        return ZStack {
            TVMusicVideoSurface(player: store.engine.displayPlayer)
                .ignoresSafeArea()
                .background(.black)

            LinearGradient(
                colors: [.black.opacity(0.62), .black.opacity(0.08), .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                TVEyebrow(text: PMString("ext.tv.nowPlaying.eyebrow")).padding(.bottom, 18)
                Text(np.title)
                    .font(.system(size: 58, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(np.artist)
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.74))
                    .padding(.top, 8)
                Text(metadataLine(np))
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.52))
                    .padding(.top, 5)

                Spacer(minLength: 0)

                if let issue = store.playbackIssue {
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(TVColor.warn)
                        .lineLimit(2)
                        .padding(.bottom, 18)
                }

                scrubber(immersiveDark: true)
                    .padding(.bottom, 20)
                transport(immersiveDark: true)
            }
            .focusScope(playerFocus)
            .focusSection()
            .padding(.horizontal, 100)
            .padding(.top, isTabContent ? TVSpace.pageTop : 78)
            .padding(.bottom, isTabContent ? TVSpace.pageBottom : 70)
        }
    }

    private var leftColumn: some View {
        let np = store.nowPlaying
        return VStack(alignment: .leading, spacing: 0) {
            TVEyebrow(text: PMString("ext.tv.nowPlaying.eyebrow")).padding(.bottom, 16)
            TVArtworkView(coverKey: np.albumID, artist: np.artist, album: np.album,
                          songID: np.songID, coverRef: np.coverRef,
                          tint: np.tint, tint2: np.tint2, glyph: np.glyph, size: 420, radius: 20)
                .shadow(color: .black.opacity(0.5), radius: 36, y: 18)
            Text(np.title).font(.system(size: 48, weight: .bold)).tracking(-0.8)
                .foregroundStyle(TVColor.text).lineLimit(2).padding(.top, 26)
            Text(np.artist).font(.system(size: 26)).foregroundStyle(TVColor.textMuted).padding(.top, 8)
            Text(metadataLine(np))
                .font(.system(size: 18)).foregroundStyle(TVColor.textFaint).padding(.top, 4)

            if let issue = store.playbackIssue {
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(TVColor.warn)
                    .lineLimit(3).frame(maxWidth: 580, alignment: .leading).padding(.top, 14)
            }

            Spacer(minLength: 24)
            scrubber(immersiveDark: false).padding(.bottom, 18)
            transport(immersiveDark: false)
        }
    }

    private var playerScrim: [Color] {
        if colorScheme == .dark {
            return [.black.opacity(0.30), .black.opacity(0.12), .black.opacity(0.42)]
        }
        return [TVColor.bg.opacity(0.28), TVColor.bg.opacity(0.08), TVColor.bg.opacity(0.48)]
    }

    private func metadataLine(_ np: TVNowPlaying) -> String {
        let technical = "\(np.format) \(np.bitrate) kbps · \(String(format: "%.1f", np.sampleRate)) kHz"
        return np.album.isEmpty ? technical : "\(np.album) · \(technical)"
    }

    private func scrubber(immersiveDark: Bool) -> some View {
        let np = store.nowPlaying
        let cur = store.currentTime
        let dur = store.duration
        let p = dur > 0 ? max(0, min(1, cur / dur)) : 0
        return HStack(spacing: 16) {
            Text(TVFmt.time(cur)).font(.system(size: 16, design: .monospaced))
                .foregroundStyle(immersiveDark ? Color.white.opacity(0.60) : TVColor.textMuted)
                .frame(width: 56, alignment: .trailing)
            TVScrubber(progress: p, tint: np.tint, immersiveDark: immersiveDark,
                       currentTime: cur, duration: dur,
                       onBack: { store.skipBackward() }, onForward: { store.skipForward() })
            Text("-\(TVFmt.time(max(0, dur - cur)))").font(.system(size: 16, design: .monospaced))
                .foregroundStyle(immersiveDark ? Color.white.opacity(0.60) : TVColor.textMuted)
                .frame(width: 56, alignment: .leading)
        }
    }

    private func transport(immersiveDark: Bool) -> some View {
        HStack(spacing: 20) {
            Spacer()
            TVRoundBtn(icon: "shuffle", size: 64, active: store.shuffleEnabled,
                       immersiveDark: immersiveDark) { store.toggleShuffle() }
            if store.canPlayMusicVideo {
                TVRoundBtn(icon: store.isMusicVideoModeEnabled ? "play.rectangle.fill" : "play.rectangle",
                           size: 64,
                           active: store.isMusicVideoModeEnabled,
                           immersiveDark: immersiveDark) { store.toggleMusicVideoMode() }
            }
            focusedRoundButton(
                icon: "backward.fill",
                size: 64,
                immersiveDark: immersiveDark,
                target: .previous
            ) { store.previous() }
            focusedRoundButton(
                icon: store.isPlaying ? "pause.fill" : "play.fill",
                size: 92,
                primary: true,
                immersiveDark: immersiveDark,
                target: .songPrimary
            ) { store.togglePlayPause() }
                // 进入播放页默认聚焦播放/暂停键,避免落在进度条上误触快进快退。
                .prefersDefaultFocus(true, in: playerFocus)
            focusedRoundButton(
                icon: "forward.fill",
                size: 64,
                immersiveDark: immersiveDark,
                target: .next
            ) { store.next() }
            TVRoundBtn(icon: store.repeatMode == .one ? "repeat.1" : "repeat", size: 64,
                       active: store.repeatMode != .off,
                       immersiveDark: immersiveDark) { store.cycleRepeatMode() }
            // 队列 / 更多移到同一行——和左侧传输键焦点左右线性可达,不再困在右上角。
            TVRoundBtn(icon: "sparkles.tv", size: 64, immersiveDark: immersiveDark) {
                lastInteraction = Date()
                presentImmersivePlayer()
            }
            TVRoundBtn(icon: "list.bullet", size: 64, immersiveDark: immersiveDark) { showQueue = true }
            TVRoundBtn(icon: "ellipsis", size: 64, immersiveDark: immersiveDark) { showOptions = true }
            Spacer()
        }
    }

    // MARK: 右列 — 歌词

    @ViewBuilder
    private var lyricsColumn: some View {
        if store.lyrics.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "text.quote").font(.system(size: 48)).foregroundStyle(TVColor.textGhost)
                Text(PMString("ext.tv.nowPlaying.noLyrics")).font(.system(size: 26)).foregroundStyle(TVColor.textFaint)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            lyricsList
        }
    }

    private var lyricsList: some View {
        let cur = store.currentLyricIndex
        let followsPlayback = store.lyricsFollowPlayback
        // 跟手机端一致:整列歌词放进可滚动容器,随播放进度平滑把当前行滚到视觉中心
        //(`scrollTo(anchor:.center)` + `.smooth`),不再按 index 重算固定窗口硬跳。
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 30) {
                    Color.clear.frame(height: 260)   // 顶部留白:首行也能滚到中心
                    ForEach(Array(store.lyrics.enumerated()), id: \.offset) { i, _ in
                        lyricLine(index: i, current: cur).id(i)
                    }
                    Color.clear.frame(height: 360)   // 底部留白:末行也能滚到中心
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDisabled(followsPlayback)
            .focusable(!followsPlayback)
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                    .init(color: .black, location: 0.84), .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: cur) { _, new in
                guard followsPlayback, let new else { return }
                withAnimation(.smooth(duration: 0.55, extraBounce: 0)) { proxy.scrollTo(new, anchor: .center) }
            }
            .onChange(of: store.lyricsRevision) {
                guard store.lyricsFollowPlayback, let current = store.currentLyricIndex else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(current, anchor: .center)
                }
            }
            .onAppear {
                guard followsPlayback, let cur else { return }
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(cur, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func lyricLine(index i: Int, current cur: Int?) -> some View {
        let ln = store.lyrics[i]
        let isCur = cur == i
        let dist = cur.map { abs(i - $0) }
        let opacity = isCur ? 1 : dist.map { max(0.18, 0.5 - Double($0) * 0.1) } ?? 0.78
        // 字号固定、靠 scaleEffect 缩放——缩放能平滑动画,直接换 font size 会硬跳。
        let scale: CGFloat = isCur ? 1.0 : (cur == nil ? 0.88 : 0.78)
        let size: CGFloat = 48
        VStack(alignment: .leading, spacing: 6) {
            if isCur, !ln.syllables.isEmpty {
                TVKaraokeLine(syllables: ln.syllables, progress: store.currentLyricProgress,
                              size: size, tint: store.nowPlaying.tint)
            } else {
                // 普通 .lrc 无逐字时间——整行高亮;非当前行半透明。
                Text(ln.text).font(.system(size: size, weight: isCur ? .bold : .semibold))
                    .foregroundStyle(TVColor.text)
                    .shadow(color: isCur ? store.nowPlaying.tint.opacity(0.5) : .clear, radius: 16, y: 2)
            }
            if !ln.translation.isEmpty {
                Text(ln.translation).font(.system(size: 22)).italic()
                    .foregroundStyle(TVColor.textFaint)
            }
        }
        .scaleEffect(scale, anchor: .leading)
        .opacity(opacity)
        .animation(.smooth(duration: 0.5, extraBounce: 0), value: cur)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(ln.text))
        .accessibilityValue(Text(isCur ? PMString("playback") : ""))
        .accessibilityAddTraits(isCur ? [.isSelected] : [])
    }
}

// MARK: - 逐字卡拉OK行

struct TVKaraokeLine: View {
    let syllables: [TVSyllable]
    let progress: Double
    let size: CGFloat
    let tint: Color

    var body: some View {
        let (highlightIdx, charT) = sweep()
        HStack(spacing: 0) {
            ForEach(Array(syllables.enumerated()), id: \.offset) { i, s in
                let active = i < highlightIdx
                let inFlight = i == highlightIdx
                let fillT: Double = active ? 1 : (inFlight ? charT : 0)
                let scale = inFlight ? 1 + 0.05 * sin(charT * .pi) : 1
                Text(s.w)
                    .foregroundStyle(TVColor.textGhost)
                    .overlay(alignment: .leading) {
                        Text(s.w)
                            .foregroundStyle(TVColor.text)
                            .shadow(color: tint.opacity(0.8), radius: 12)
                            .mask(alignment: .leading) {
                                GeometryReader { g in
                                    Rectangle().frame(width: g.size.width * fillT)
                                }
                            }
                    }
                    .scaleEffect(scale, anchor: .bottom)
            }
        }
        .font(.system(size: size, weight: .bold))
        .shadow(color: tint.opacity(0.4), radius: 16, y: 2)
    }

    /// 返回(正在唱的字下标, 该字内进度 0...1)。
    private func sweep() -> (Int, Double) {
        let total = syllables.reduce(0) { $0 + $1.d }
        let t = max(0, min(1, progress)) * total
        var acc = 0.0
        for (i, s) in syllables.enumerated() {
            if acc + s.d > t { return (i, (t - acc) / s.d) }
            acc += s.d
        }
        return (syllables.count, 0)
    }
}

// MARK: - MV Surface

private struct TVMusicVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> TVMusicVideoLayerView {
        let view = TVMusicVideoLayerView()
        view.setPlayer(player)
        return view
    }

    func updateUIView(_ uiView: TVMusicVideoLayerView, context: Context) {
        uiView.setPlayer(player)
    }
}

private final class TVMusicVideoLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer? {
        layer as? AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer?.videoGravity = .resizeAspect
        backgroundColor = .black
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func setPlayer(_ player: AVPlayer) {
        playerLayer?.player = player
    }
}

// MARK: - 可聚焦进度条(Siri Remote 左右拖动 ∓10s 定位)

private struct TVScrubber: View {
    let progress: Double
    let tint: Color
    var immersiveDark = false
    let currentTime: Double
    let duration: Double
    var onBack: () -> Void
    var onForward: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(immersiveDark
                               ? Color.white.opacity(focused ? 0.32 : 0.16)
                               : (focused ? TVColor.surfaceStrong : TVColor.divider))
                    .frame(height: focused ? 10 : 5)
                Capsule().fill(tint)
                    .frame(width: max(0, geo.size.width * progress), height: focused ? 10 : 5)
                    .shadow(color: focused ? tint.opacity(0.8) : .clear, radius: focused ? 8 : 0)
                Circle().fill(immersiveDark ? Color.white : TVColor.text)
                    .frame(width: focused ? 30 : 16, height: focused ? 30 : 16)
                    .overlay(Circle().strokeBorder(tint, lineWidth: focused ? 4 : 0))
                    .shadow(color: tint.opacity(focused ? 0.9 : 0.5), radius: focused ? 12 : 4)
                    .offset(x: max(0, geo.size.width * progress) - (focused ? 15 : 8))
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 30)
        .padding(.vertical, 12).padding(.horizontal, 16)
        // 聚焦时整条进度条套上品牌色描边 + 辉光的高亮框,清楚区分「选中在此处」。
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(focused
                      ? (immersiveDark ? Color.white.opacity(0.12) : TVColor.surfaceStrong)
                      : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(tint, lineWidth: focused ? 3 : 0)
                }
        }
        .shadow(color: focused ? tint.opacity(0.45) : .clear, radius: focused ? 18 : 0)
        .scaleEffect(focused ? 1.03 : 1)
        .focusable(true)
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left: onBack()
            case .right: onForward()
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(PMString("playback")))
        .accessibilityValue(Text("\(TVFmt.time(currentTime)) / \(TVFmt.time(duration))"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onForward()
            case .decrement: onBack()
            @unknown default: break
            }
        }
        .animation(.easeOut(duration: 0.18), value: focused)
    }
}

// MARK: - 圆形传输按钮

struct TVRoundBtn: View {
    let icon: String
    var size: CGFloat = 68
    var primary: Bool = false
    var active: Bool = false   // 开启态(随机/循环)——图标染品牌色
    var immersiveDark: Bool = false
    var accessibilityLabel: String?
    var action: () -> Void = {}

    var body: some View {
        TVFocusButton(radius: size / 2,
                      accent: immersiveDark ? Color.white : TVColor.focusRing,
                      scale: 1.14, lift: 8, action: action) { _ in
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(primary
                                 ? (immersiveDark ? Color(hex: "#1f1c19") : TVColor.onBrand)
                                 : (active ? TVColor.brand : (immersiveDark ? Color.white : TVColor.text)))
                .frame(width: size, height: size)
                .background(primary
                            ? AnyShapeStyle(immersiveDark ? Color.white : TVColor.brand)
                            : AnyShapeStyle(immersiveDark ? Color.white.opacity(0.14) : TVColor.surfaceStrong),
                            in: Circle())
        }
        .accessibilityLabel(Text(accessibilityLabel ?? Self.defaultAccessibilityLabel(for: icon)))
    }

    private static func defaultAccessibilityLabel(for icon: String) -> String {
        switch icon {
        case "shuffle": return PMString("shuffle")
        case "repeat", "repeat.1": return PMString("repeat")
        case "list.bullet": return PMString("queue_title")
        case "ellipsis": return PMString("more")
        case "sparkles.tv": return PMString("ext.tv.settings.immersive")
        case "play.rectangle", "play.rectangle.fill": return PMString("playback")
        default: return icon
        }
    }
}
#endif
