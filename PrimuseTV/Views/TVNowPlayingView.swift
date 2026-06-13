#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 正在播放 — 左列封面+元数据+进度+传输键,右列巨幅逐字歌词(对应 TVNowPlayingArtboard)。
/// Menu 键返回;右上角可打开队列 / 选项。
struct TVNowPlayingView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var showQueue = false
    @State private var showOptions = false
    @Namespace private var playerFocus

    var body: some View {
        ZStack {
            if store.hasNowPlaying { player } else { emptyState }
        }
        .onExitCommand { dismiss() }
        .fullScreenCover(isPresented: $showQueue) { TVQueueView().environment(store) }
        .fullScreenCover(isPresented: $showOptions) { TVOptionsView().environment(store) }
    }

    private var emptyState: some View {
        ZStack {
            TVAmbientBackdrop(strength: 0.55)
            VStack(spacing: 18) {
                Image(systemName: "play.circle").font(.system(size: 96))
                    .foregroundStyle(.white.opacity(0.5))
                Text(PMString("ext.tv.nowPlaying.notPlaying")).font(.system(size: 40, weight: .bold)).foregroundStyle(.white)
                Text(PMString("ext.tv.nowPlaying.pickASong")).font(.system(size: 22)).foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var player: some View {
        let np = store.nowPlaying
        return ZStack {
            TVAmbientBackdrop(tint: np.tint, tint2: np.tint2, strength: 1)
            // 暗色蒙层:浅色专辑底色下白字标题不再和背景同色看不清。
            LinearGradient(colors: [.black.opacity(0.5), .black.opacity(0.28), .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            HStack(alignment: .top, spacing: 80) {
                leftColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusSection()
                lyricsColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .focusScope(playerFocus)
            .padding(.horizontal, 100).padding(.top, 80).padding(.bottom, 70)
        }
    }

    // MARK: 左列

    private var leftColumn: some View {
        let np = store.nowPlaying
        return VStack(alignment: .leading, spacing: 0) {
            TVEyebrow(text: PMString("ext.tv.nowPlaying.eyebrow")).padding(.bottom, 16)
            TVArtworkView(coverKey: np.albumID, artist: np.artist, album: np.album,
                          tint: np.tint, tint2: np.tint2, glyph: np.glyph, size: 420, radius: 20)
                .shadow(color: .black.opacity(0.5), radius: 36, y: 18)
            Text(np.title).font(.system(size: 48, weight: .bold)).tracking(-0.8)
                .foregroundStyle(.white).lineLimit(2).padding(.top, 26)
            Text(np.artist).font(.system(size: 26)).foregroundStyle(.white.opacity(0.72)).padding(.top, 8)
            Text("\(np.album) · \(np.format) \(np.bitrate) kbps · \(np.sampleRate, specifier: "%.1f") kHz")
                .font(.system(size: 18)).foregroundStyle(.white.opacity(0.5)).padding(.top, 4)

            if let issue = store.playbackIssue {
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(TVColor.warn)
                    .lineLimit(3).frame(maxWidth: 580, alignment: .leading).padding(.top, 14)
            }

            Spacer(minLength: 24)
            scrubber.padding(.bottom, 18)
            transport
        }
    }

    private var scrubber: some View {
        let np = store.nowPlaying
        let cur = store.currentTime
        let dur = store.duration
        let p = dur > 0 ? max(0, min(1, cur / dur)) : 0
        return HStack(spacing: 16) {
            Text(TVFmt.time(cur)).font(.system(size: 16, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6)).frame(width: 56, alignment: .trailing)
            TVScrubber(progress: p, tint: np.tint,
                       onBack: { store.skipBackward() }, onForward: { store.skipForward() })
            Text("-\(TVFmt.time(max(0, dur - cur)))").font(.system(size: 16, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6)).frame(width: 56, alignment: .leading)
        }
    }

    private var transport: some View {
        HStack(spacing: 20) {
            Spacer()
            TVRoundBtn(icon: "shuffle", size: 64, active: store.shuffleEnabled) { store.toggleShuffle() }
            TVRoundBtn(icon: "backward.fill", size: 64) { store.previous() }
            TVRoundBtn(icon: store.isPlaying ? "pause.fill" : "play.fill", size: 92,
                       primary: true) { store.togglePlayPause() }
                // 进入播放页默认聚焦播放/暂停键,避免落在进度条上误触快进快退。
                .prefersDefaultFocus(true, in: playerFocus)
            TVRoundBtn(icon: "forward.fill", size: 64) { store.next() }
            TVRoundBtn(icon: store.repeatMode == .one ? "repeat.1" : "repeat", size: 64,
                       active: store.repeatMode != .off) { store.cycleRepeatMode() }
            // 队列 / 更多移到同一行——和左侧传输键焦点左右线性可达,不再困在右上角。
            TVRoundBtn(icon: "list.bullet", size: 64) { showQueue = true }
            TVRoundBtn(icon: "ellipsis", size: 64) { showOptions = true }
            Spacer()
        }
    }

    // MARK: 右列 — 歌词

    @ViewBuilder
    private var lyricsColumn: some View {
        if store.lyrics.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "text.quote").font(.system(size: 48)).foregroundStyle(.white.opacity(0.35))
                Text(PMString("ext.tv.nowPlaying.noLyrics")).font(.system(size: 26)).foregroundStyle(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            lyricsList
        }
    }

    private var lyricsList: some View {
        let cur = store.currentLyricIndex
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
            .scrollDisabled(true)   // tvOS:只随播放自动滚,不接受遥控滚动
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                    .init(color: .black, location: 0.84), .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .onChange(of: cur) { _, new in
                withAnimation(.smooth(duration: 0.55, extraBounce: 0)) { proxy.scrollTo(new, anchor: .center) }
            }
            .onChange(of: store.lyrics.count) { _, _ in proxy.scrollTo(cur, anchor: .center) }
            .onAppear { proxy.scrollTo(cur, anchor: .center) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func lyricLine(index i: Int, current cur: Int) -> some View {
        let ln = store.lyrics[i]
        let isCur = i == cur
        let dist = abs(i - cur)
        let opacity = isCur ? 1 : max(0.18, 0.5 - Double(dist) * 0.1)
        // 字号固定、靠 scaleEffect 缩放——缩放能平滑动画,直接换 font size 会硬跳。
        let scale: CGFloat = isCur ? 1.0 : 0.78
        let size: CGFloat = 48
        VStack(alignment: .leading, spacing: 6) {
            if isCur, !ln.syllables.isEmpty {
                TVKaraokeLine(syllables: ln.syllables, progress: store.currentLyricProgress,
                              size: size, tint: store.nowPlaying.tint)
            } else {
                // 普通 .lrc 无逐字时间——整行高亮;非当前行半透明。
                Text(ln.text).font(.system(size: size, weight: isCur ? .bold : .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: isCur ? store.nowPlaying.tint.opacity(0.5) : .clear, radius: 16, y: 2)
            }
            if !ln.translation.isEmpty {
                Text(ln.translation).font(.system(size: 22)).italic()
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .scaleEffect(scale, anchor: .leading)
        .opacity(opacity)
        .animation(.smooth(duration: 0.5, extraBounce: 0), value: cur)
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
                    .foregroundStyle(.white.opacity(0.42))
                    .overlay(alignment: .leading) {
                        Text(s.w)
                            .foregroundStyle(.white)
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

// MARK: - 可聚焦进度条(Siri Remote 左右拖动 ∓10s 定位)

private struct TVScrubber: View {
    let progress: Double
    let tint: Color
    var onBack: () -> Void
    var onForward: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(focused ? 0.32 : 0.16))
                    .frame(height: focused ? 10 : 5)
                Capsule().fill(tint)
                    .frame(width: max(0, geo.size.width * progress), height: focused ? 10 : 5)
                    .shadow(color: focused ? tint.opacity(0.8) : .clear, radius: focused ? 8 : 0)
                Circle().fill(.white)
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
                .fill(Color.white.opacity(focused ? 0.12 : 0))
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
        .animation(.easeOut(duration: 0.18), value: focused)
    }
}

// MARK: - 圆形传输按钮

struct TVRoundBtn: View {
    let icon: String
    var size: CGFloat = 68
    var primary: Bool = false
    var active: Bool = false   // 开启态(随机/循环)——图标染品牌色
    var action: () -> Void = {}

    var body: some View {
        TVFocusButton(radius: size / 2, accent: .white, scale: 1.14, lift: 8, action: action) { _ in
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(primary ? Color(hex: "#1f1c19") : (active ? TVColor.brand : .white))
                .frame(width: size, height: size)
                .background(primary ? AnyShapeStyle(.white) : AnyShapeStyle(Color.white.opacity(0.14)),
                            in: Circle())
        }
    }
}
#endif
