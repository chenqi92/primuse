#if os(macOS)
import SwiftUI
import PrimuseKit

/// 迷你播放器内容。竖排:工具条 / 进度 / 传输键 / 滚动歌词。整体材质用
/// regularMaterial + 封面虚化做 ambient 背景,跟 NowPlaying 风格统一。
/// iOS 端同名 MiniPlayerView 是底栏 mini 卡片,跟这个全窗口 mini 播放
/// 器作用不同,所以这里命名为 `MacMiniPlayerView`。
struct MacMiniPlayerView: View {
    var onClose: () -> Void = {}
    /// 由 controller 注入,bottomMode 切换时回调,用来 resize NSWindow
    /// 高度——展开歌词/队列就拉长窗口,折叠回去就缩成一小块。
    var onBottomModeChange: ((BottomMode) -> Void)? = nil

    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine
    @Environment(SourceManager.self) private var sourceManager
    @Environment(ThemeService.self) private var theme
    @State private var lyrics: [LyricLine] = []
    @State private var currentIndex: Int = 0
    @State private var airPlayShown = false

    /// 下半部分内容模式 —— 跟 Apple Music 一样,Lyrics / Queue 是互斥的
    /// 内容面板,工具条上的按钮高亮的就是当前激活模式。默认折叠 (.none)
    /// 时窗口只剩工具条 + 进度条 + 传输键这一小块;点击歌词/队列再让
    /// controller 把窗口拉高。
    enum BottomMode { case lyrics, queue, none }
    @State private var bottomMode: BottomMode = .none

    var body: some View {
        ZStack {
            ambientBackdrop
            VStack(spacing: 0) {
                // 固定顶部 32pt top bar — 流量灯左, 折叠箭头右。设计稿 NP-Mini
                // 的 title bar 高度就是 32pt。之前用 .overlay(.topLeading) 在
                // titlebarAppearsTransparent + fullSizeContentView 的 NSPanel 上
                // 显示/命中都不稳定 (用户报告 "展开队列后看不到流量灯, 没法关闭"),
                // 改成真实布局元素就稳定可靠了。
                miniTopBar

                VStack(spacing: 10) {
                    coverArea
                    metaArea
                    scrubber

                    // 折叠态(220pt)只展示封面 / 标题 / 进度,跟设计稿 NP-Mini
                    // collapsed 一致;传输键、歌词/队列 tab、底部工具条都放到
                    // 展开态(540pt)。否则折叠高度装不下全部内容,顶部流量灯 +
                    // 关闭键会被挤出可视区——用户反馈的"顶部消失、没法关闭"正是
                    // 内容溢出裁切造成的。
                    if bottomMode != .none {
                        transport
                        subviewTabs
                            .padding(.top, 4)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)

                if bottomMode != .none {
                    bottomPanel
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    footerToolbar
                } else {
                    Spacer(minLength: 0)
                }
            }
            .animation(.easeInOut(duration: 0.28), value: bottomMode)
        }
        // 固定内容尺寸:宽恒 300,高随折叠/展开在 220 / 540 间切换。承载这个 view
        // 的 NSHostingView 会按内容 fitting size 决定 mini player 窗口大小(顶层
        // hosting view 这个行为关不掉),所以这里把 fitting size 直接钉成设计尺寸,
        // 窗口就正好是 300×220 / 300×540,不会被 ScrollView 等无界内容撑成一大片。
        .frame(
            width: MiniPlayerWindowController.fixedWidth,
            height: bottomMode == .none
                ? MiniPlayerWindowController.collapsedHeight
                : MiniPlayerWindowController.expandedHeight
        )
        .task(id: player.currentSong?.id) { await reloadLyrics() }
        .onChange(of: player.currentTime) { _, t in updateIndex(time: t) }
        .onChange(of: bottomMode) { _, new in onBottomModeChange?(new) }
        .onReceive(NotificationCenter.default.publisher(for: .primuseLyricsDidChange)) { note in
            guard let songID = note.object as? String,
                  songID == player.currentSong?.id else { return }
            Task { await reloadLyrics() }
        }
    }

    /// 固定的 36pt 顶部 bar — 流量灯 (close/min/zoom) 左, 中间空白可拖拽,
    /// 右侧两个按钮: 折叠/展开箭头 + 直接关窗 X (双保险, 防 NSPanel 上传统流量
    /// 灯失效用户没法关窗)。底部 0.5pt divider 让 bar 跟下方内容分开, 视觉
    /// 一定能找到。
    private var miniTopBar: some View {
        HStack(spacing: 8) {
            PMWindowTrafficLights()
                .padding(.leading, 12)
            Spacer()
            // 折叠 / 展开
            Button {
                bottomMode = bottomMode == .none ? .lyrics : .none
            } label: {
                Image(systemName: bottomMode == .none ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.black.opacity(0.32), in: .circle)
                    .overlay { Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
            }
            .buttonStyle(.plain)
            .help(Text(bottomMode == .none ? "show" : "hide"))

            // 直接关窗 X — 万一系统标准流量灯没渲染出来 (NSPanel +
            // fullSizeContentView 历史已经踩过坑), 用户依然有明确的关窗入口。
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.black.opacity(0.32), in: .circle)
                    .overlay { Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .help(Text("close"))
        }
        .frame(height: 36)
        .background {
            Rectangle()
                .fill(Color.black.opacity(0.18))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(.white.opacity(0.10)).frame(height: 0.5)
                }
        }
    }

    // MARK: - Backdrop

    private var ambientBackdrop: some View {
        AmbientBackdrop(
            accent: theme.accentColor,
            darkAccent: theme.darkAccent,
            strength: 0.78
        )
        .ignoresSafeArea()
    }

    /// 折叠态居中显示的 96pt 封面 — 跟设计稿 NP-Mini 一致。
    private var coverArea: some View {
        Group {
            if let song = player.currentSong {
                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id,
                    size: 96, cornerRadius: 10,
                    sourceID: song.sourceID, filePath: song.filePath
                )
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.12))
                    .frame(width: 96, height: 96)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.55))
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.32), radius: 12, y: 5)
    }

    /// 标题/艺术家 — 居中显示, 紧贴 cover 下方。
    private var metaArea: some View {
        VStack(spacing: 2) {
            Text(player.currentSong?.title ?? "—")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(player.currentSong?.artistName ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Top toolbar

    private var subviewTabs: some View {
        HStack(spacing: 16) {
            miniTab("lyrics_word", mode: .lyrics)
            miniTab("queue_title", mode: .queue)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func miniTab(_ title: LocalizedStringKey, mode: BottomMode) -> some View {
        let active = bottomMode == mode
        return Button {
            bottomMode = mode
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? .white : .white.opacity(0.5))
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(active ? Color.white : Color.clear)
                        .frame(height: 2)
                }
        }
        .buttonStyle(.plain)
    }

    private var footerToolbar: some View {
        HStack(spacing: 6) {
            // Lyrics 切换 —— 高亮 = 当前下半部分显示歌词。再点切到 .none
            // 隐藏面板,留给封面更多空间。
            Button {
                bottomMode = (bottomMode == .lyrics) ? .none : .lyrics
            } label: {
                miniIcon(bottomMode == .lyrics ? "text.bubble.fill" : "text.bubble",
                         tint: bottomMode == .lyrics ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("lyrics_word"))

            // Queue —— 切到下半部分显示当前队列。
            Button {
                bottomMode = (bottomMode == .queue) ? .none : .queue
            } label: {
                miniIcon(bottomMode == .queue ? "list.bullet.indent" : "list.bullet",
                         tint: bottomMode == .queue ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("queue_title"))

            Button { airPlayShown.toggle() } label: {
                miniIcon("airplayaudio", tint: airPlayShown ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .popover(isPresented: $airPlayShown, arrowEdge: .top) {
                AudioOutputPickerView()
            }
            .help(Text("audio_output"))

            Spacer(minLength: 8)

            Image(systemName: volumeSymbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 14)

            MiniVolumeSlider(value: Binding(
                get: { Double(engine.volume) },
                set: { engine.volume = Float($0) }
            ))
            .frame(width: 60, height: 14)

            PlayerMoreMenu {
                miniIcon("ellipsis", tint: .secondary)
            }
            .frame(width: 28, height: 28)
            .fixedSize()
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
        }
    }

    private var volumeSymbol: String {
        let v = engine.volume
        if v <= 0.001 { return "speaker.slash.fill" }
        if v < 0.4 { return "speaker.wave.1.fill" }
        if v < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    private func miniIcon(_ symbol: String, tint: Color = .secondary) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        VStack(spacing: 4) {
            ScrubberLine(
                value: player.currentTime,
                total: max(player.duration, 0.01),
                onSeek: { player.seek(to: $0) }
            )
            HStack {
                Text(formatTime(player.currentTime))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 22) {
            Button { player.shuffleEnabled.toggle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 14))
                    .foregroundStyle(player.shuffleEnabled ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            Button { Task { await player.previous() } } label: {
                Image(systemName: "backward.fill").font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)

            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            Button { Task { await player.next() } } label: {
                Image(systemName: "forward.fill").font(.system(size: 18, weight: .semibold))
            }
            .buttonStyle(.plain)

            Button { cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 14))
                    .foregroundStyle(player.repeatMode != .off ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
    }

    private func cycleRepeat() {
        switch player.repeatMode {
        case .off: player.repeatMode = .all
        case .all: player.repeatMode = .one
        case .one: player.repeatMode = .off
        }
    }

    // MARK: - Bottom panel (lyrics / queue / hidden)

    @ViewBuilder
    private var bottomPanel: some View {
        switch bottomMode {
        case .lyrics: lyricsList
        case .queue: queueList
        case .none:
            Color.clear.frame(maxHeight: 0)
        }
    }

    private var queueList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 8) {
                if player.queue.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note.list")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                        Text("queue_empty")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
                } else {
                    if let current = player.currentSong {
                        Text("now_playing")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        queueRow(index: player.currentIndex, song: current, isPlaying: true)
                            .padding(.bottom, 4)
                    }

                    let upNext = (player.currentIndex + 1)..<player.queue.count
                    if !upNext.isEmpty {
                        Text("up_next")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        ForEach(Array(upNext), id: \.self) { idx in
                            queueRow(index: idx)
                        }
                    }
                    let played = 0..<player.currentIndex
                    if !played.isEmpty {
                        Text("played")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                        ForEach(Array(played), id: \.self) { idx in
                            queueRow(index: idx).opacity(0.55)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private func queueRow(index: Int, song overrideSong: Song? = nil, isPlaying: Bool = false) -> some View {
        let song = overrideSong ?? player.queue[index]
        return HStack(spacing: 9) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 32, cornerRadius: 6,
                sourceID: song.sourceID,
                filePath: song.filePath
            )
            .overlay {
                if isPlaying {
                    Color.black.opacity(0.32)
                        .clipShape(.rect(cornerRadius: 6))
                    Image(systemName: "waveform")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.caption).lineLimit(1)
                Text(song.artistName ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isPlaying ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                    in: .rect(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            player.currentIndex = index
            Task { await player.play(song: song) }
        }
    }

    // MARK: - Lyrics list

    private var lyricsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if lyrics.isEmpty {
                        if player.currentSong == nil {
                            Color.clear.frame(height: 1)
                        } else {
                            Text("no_lyrics")
                                .font(.callout).foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 20)
                        }
                    } else {
                        Spacer().frame(height: 30)
                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { i, line in
                            let active = i == currentIndex
                            miniLyricLine(line: line, index: i, isActive: active)
                                .id(line.id)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { player.seek(to: line.timestamp) }
                                .animation(.easeInOut(duration: 0.25), value: currentIndex)
                        }
                        Spacer().frame(height: 60)
                    }
                }
                .padding(.horizontal, 4)
            }
            .onChange(of: currentIndex) { _, new in
                guard !lyrics.isEmpty, new < lyrics.count else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(lyrics[new].id, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func miniLyricLine(line: LyricLine, index: Int, isActive: Bool) -> some View {
        let fontSize: CGFloat = isActive ? 18 : 14
        let weight: Font.Weight = isActive ? .bold : .regular
        if shouldRenderWordTimeline(line: line, index: index, isActive: isActive) {
            KaraokeLineView(
                line: line,
                fontSize: fontSize,
                weight: weight,
                activeColor: .primary.opacity(isActive ? 1 : 0.72),
                inactiveColor: .secondary.opacity(isActive ? 0.55 : 0.42),
                timeAt: { date in player.interpolatedTime(at: date) }
            )
        } else {
            Text(line.text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(isActive ? .primary : .secondary)
                .opacity(isActive ? 1 : 0.55)
        }
    }

    private func shouldRenderWordTimeline(line: LyricLine, index: Int, isActive: Bool) -> Bool {
        guard line.isWordLevel else { return false }
        return isActive || abs(index - currentIndex) == 1
    }

    private func reloadLyrics() async {
        guard let song = player.currentSong else {
            lyrics = []; currentIndex = 0; return
        }
        lyrics = []; currentIndex = 0
        let loaded = await LyricsLoader.load(for: song, sourceManager: sourceManager)
        guard player.currentSong?.id == song.id else { return }
        lyrics = loaded
        updateIndex(time: player.currentTime)
    }

    private func updateIndex(time: TimeInterval) {
        guard !lyrics.isEmpty else { return }
        for i in (0..<lyrics.count).reversed() where time >= lyrics[i].timestamp {
            if currentIndex != i { currentIndex = i }
            return
        }
        if currentIndex != 0 { currentIndex = 0 }
    }

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Scrubber slider only commits seek on release, otherwise AVAudioEngine
/// chokes on the per-frame seeks during a drag.
private struct ScrubberLine: View {
    let value: Double
    let total: Double
    var onSeek: (Double) -> Void

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        Slider(
            value: Binding(
                get: { isDragging ? dragValue : value },
                set: { dragValue = $0 }
            ),
            in: 0...max(total, 0.01),
            onEditingChanged: { editing in
                if editing { isDragging = true; dragValue = value }
                else { isDragging = false; onSeek(dragValue) }
            }
        )
        .controlSize(.small)
        .tint(.secondary)
    }
}

private struct MiniVolumeSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = CGFloat(max(0, min(1, value)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(height: 3)
                Capsule()
                    .fill(.white.opacity(0.78))
                    .frame(width: width * fraction, height: 3)
            }
            .frame(height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard width > 0 else { return }
                        value = Double(max(0, min(1, gesture.location.x / width)))
                    }
            )
        }
    }
}
#endif
