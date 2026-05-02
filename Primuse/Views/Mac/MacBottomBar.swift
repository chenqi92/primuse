#if os(macOS)
import SwiftUI
import PrimuseKit

/// Apple Music macOS 风格的底栏：左侧 5 个传输键(shuffle/prev/play/next/
/// repeat)、中间 mini player 卡片(封面 + 标题 + 进度条)、右侧二级控件
/// (more / lyrics / queue / AirPlay / volume)。
///
/// 进度条不再是中间一整条 slider —— 改为 mini player 内部的极细 bar,
/// 鼠标 hover 时会变粗,点击拖动 seek。这跟 Apple Music 的视觉一致,
/// 也腾出更多空间给二级控件。
struct MacBottomBar: View {
    var isExpanded: Bool = false
    var onToggleNowPlaying: () -> Void = {}
    var onShowQueue: () -> Void = {}
    var onMiniPlayer: () -> Void = {}
    var onFullScreen: () -> Void = {}

    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine

    // AirPlay popover 直接锚定到右侧 AirPlay 按钮自身,而不是从外部
    // 接 binding 拍到整个 bar 上 —— 之前那样会让弹窗位置漂到屏幕中间。
    @State private var airPlayShown = false
    /// 封面点击弹出的「迷你播放程序 / 全屏幕」选项菜单。
    @State private var coverMenuShown = false

    var body: some View {
        HStack(spacing: 14) {
            transportSection
                .layoutPriority(1)

            miniPlayer
                .layoutPriority(2)
                .frame(minWidth: 240, idealWidth: 360, maxWidth: 460)

            secondarySection
                .layoutPriority(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
        // 整个 bar 范围统一吃点击事件,避免空白处穿透到下层歌单 row。
        .contentShape(Rectangle())
        .onTapGesture { /* sink */ }
    }

    // MARK: - Transport (left)

    private var transportSection: some View {
        HStack(spacing: 10) {
            // 同一个 SF Symbol 名,只换 tint —— 之前 enabled 时切到
            // `shuffle.circle.fill` 视觉尺寸更大,跟 disabled 态对不齐。
            transportIcon("shuffle",
                          tint: player.shuffleEnabled ? Color.accentColor : .secondary,
                          help: "shuffle") {
                player.shuffleEnabled.toggle()
            }

            transportIcon("backward.fill", tint: .primary, help: "previous_song", size: 14) {
                Task { await player.previous() }
            }

            // 主播放键放大,跟左右两侧形成视觉对比。
            Button { player.togglePlayPause() } label: {
                ZStack {
                    Image(systemName: "play.fill").opacity(0)
                    if player.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(player.isLoading)
            .help(Text(player.isPlaying ? "pause" : "play"))

            transportIcon("forward.fill", tint: .primary, help: "next_song", size: 14) {
                Task { await player.next() }
            }

            transportIcon(repeatIconName, tint: player.repeatMode != .off ? .accentColor : .secondary,
                          help: "repeat") {
                cycleRepeat()
            }
        }
    }

    private var repeatIconName: String {
        switch player.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func cycleRepeat() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }

    private func transportIcon(_ symbol: String, tint: Color, help: LocalizedStringKey,
                                size: CGFloat = 12, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(help))
    }

    // MARK: - Mini player (center)

    private var miniPlayer: some View {
        HStack(spacing: 10) {
            // 封面区域:鼠标 hover 时浮现一个 expand 图标(Apple Music 行为),
            // 点击图标弹「迷你 / 全屏 / 桌面歌词」选项。Hover 之外区域点击
            // 直接展开 NowPlaying。
            coverHoverButton

            VStack(alignment: .leading, spacing: 3) {
                Text(player.currentSong?.title ?? "")
                    .font(.callout).fontWeight(.semibold)
                    .lineLimit(1)
                Text(metaLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                MiniProgressBar(
                    value: player.currentTime,
                    total: max(player.duration, 0.01),
                    onSeek: { player.seek(to: $0) }
                )
                .frame(height: 4)
            }
            // 文字/进度条这一块点击 → 展开 NowPlaying。
            .contentShape(Rectangle())
            .onTapGesture { onToggleNowPlaying() }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
    }

    @State private var isCoverHovering = false

    /// 封面区域 + hover 浮现的 expand 图标。Apple Music macOS 26 的标准
    /// 交互:鼠标移到封面上,封面变暗一点,中央浮现 expand icon;点击图标
    /// 弹「迷你 / 全屏 / 桌面歌词」选项菜单。
    private var coverHoverButton: some View {
        ZStack {
            artworkThumb
            // 封面叠层:半透明黑底 + 中心 expand 图标,只在 hover 时可见。
            // Button 永远在,但视觉上跟着 hover 状态淡入淡出 —— 这样 hit
            // test 一直命中 Button,不会因为元素消失出问题。
            Button { coverMenuShown = true } label: {
                ZStack {
                    Color.black.opacity(isCoverHovering ? 0.35 : 0)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .opacity(isCoverHovering ? 1 : 0)
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("mini_player"))
            .animation(.easeInOut(duration: 0.15), value: isCoverHovering)
        }
        .onHover { hovering in
            isCoverHovering = hovering
        }
        .popover(isPresented: $coverMenuShown, arrowEdge: .top) {
            coverMenuPopover
        }
    }

    private var coverMenuPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            popoverRow(symbol: "rectangle.inset.filled.on.rectangle",
                       title: "mini_player", tint: .accentColor) {
                plog("🎯 cover popover: tapped Mini Player")
                onMiniPlayer()
                coverMenuShown = false
            }
            popoverRow(symbol: "arrow.up.left.and.arrow.down.right",
                       title: "full_screen_player", tint: .secondary) {
                plog("🎯 cover popover: tapped Full Screen")
                onFullScreen()
                coverMenuShown = false
            }
            Divider().padding(.vertical, 4)
            popoverRow(symbol: "text.bubble", title: "show_desktop_lyrics", tint: .secondary) {
                plog("🎯 cover popover: tapped Desktop Lyrics")
                PrimuseAppDelegate.shared?.toggleDesktopLyrics()
                coverMenuShown = false
            }
        }
        .padding(.vertical, 6)
        .frame(width: 220)
    }

    private func popoverRow(symbol: String, title: LocalizedStringKey,
                            tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title).font(.callout)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var metaLine: String {
        let parts = [player.currentSong?.artistName, player.currentSong?.albumTitle]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.joined(separator: " — ")
    }

    private var artworkThumb: some View {
        Group {
            if player.currentSong != nil {
                CachedArtworkView(
                    coverRef: player.currentSong?.coverArtFileName,
                    songID: player.currentSong?.id ?? "",
                    size: 40, cornerRadius: 6,
                    sourceID: player.currentSong?.sourceID,
                    filePath: player.currentSong?.filePath
                )
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "music.note").foregroundStyle(.tertiary)
                    }
            }
        }
        .help(Text(isExpanded ? "close" : "now_playing"))
    }

    // MARK: - Secondary controls (right)

    private var secondarySection: some View {
        HStack(spacing: 6) {
            // More menu —— 共享 PlayerMoreMenu,跟 NowPlaying 完全一致。
            PlayerMoreMenu {
                secondaryIcon("ellipsis")
            }
            .frame(width: 30, height: 30)
            .fixedSize()
            .help(Text("more"))

            Button { onToggleNowPlaying() } label: {
                secondaryIcon(isExpanded ? "text.bubble.fill" : "text.bubble",
                              tint: isExpanded ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(Text("lyrics_word"))

            Button(action: onShowQueue) {
                secondaryIcon("list.bullet")
            }
            .buttonStyle(.plain)
            .help(Text("queue_title"))
            .disabled(player.queue.isEmpty)

            Button { airPlayShown.toggle() } label: {
                secondaryIcon("airplayaudio", tint: airPlayShown ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(Text("audio_output"))
            .popover(isPresented: $airPlayShown, arrowEdge: .top) {
                AudioOutputPickerView()
            }

            // Volume —— 紧凑型,占用空间小,跟 Apple Music 接近。
            HStack(spacing: 4) {
                Image(systemName: volumeSymbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Slider(
                    value: Binding(
                        get: { Double(engine.volume) },
                        set: { engine.volume = Float($0) }
                    ),
                    in: 0...1
                )
                .controlSize(.mini)
                .tint(.secondary)
                .frame(minWidth: 60, idealWidth: 80, maxWidth: 90)
            }
        }
    }

    private var volumeSymbol: String {
        let v = engine.volume
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.4 { return "speaker.wave.1.fill" }
        if v < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func secondaryIcon(_ symbol: String, tint: Color = .secondary) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }
}

/// 中间 mini player 里的极细进度条。常态 2pt,鼠标 hover/拖拽时膨胀到
/// 6pt 让用户更容易抓。点击位置 = 直接 seek;拖动结束才提交 seek,中
/// 途不会触发 AVAudioEngine 的频繁 seek(否则大文件直接卡死)。
private struct MiniProgressBar: View {
    let value: Double
    let total: Double
    var onSeek: (Double) -> Void

    @State private var isHovering = false
    @State private var dragValue: Double?

    private var progress: CGFloat {
        guard total > 0 else { return 0 }
        let v = (dragValue ?? value) / total
        guard v.isFinite else { return 0 }
        return CGFloat(max(0, min(1, v)))
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height: CGFloat = (isHovering || dragValue != nil) ? 6 : 2

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.tertiary)
                    .frame(height: height)
                Capsule()
                    .fill(.secondary)
                    .frame(width: max(0, min(width, width * progress)), height: height)
            }
            .frame(height: 8, alignment: .center)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.12)) { isHovering = hovering }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard width > 0, total > 0 else { return }
                        let frac = max(0, min(1, g.location.x / width))
                        dragValue = Double(frac) * total
                    }
                    .onEnded { _ in
                        if let v = dragValue { onSeek(v) }
                        dragValue = nil
                    }
            )
        }
        .frame(height: 8)
    }
}
#endif
