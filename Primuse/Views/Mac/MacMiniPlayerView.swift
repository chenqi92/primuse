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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var inheritedLayoutDirection
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsPlayerVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault
    @State private var lyrics: [LyricLine] = []
    @State private var currentIndex: Int = 0
    @State private var lyricsLoadRevision: UInt = 0
    @State private var pendingLyricsOverride: PendingLyricsOverride?
    @State private var lastManualLyricsScroll = Date.distantPast
    @State private var lyricsAutoFollowTask: Task<Void, Never>?
    @State private var airPlayShown = false
    @State private var preferences = MacUIPreferences.shared

    private var lyricsWritingDirection: LyricWritingDirection {
        LyricWritingDirectionPolicy.resolve(metadataLines: lyrics.first?.metadataLines ?? [])
    }

    private var lyricLayoutDirection: LayoutDirection {
        switch lyricsWritingDirection {
        case .natural: inheritedLayoutDirection
        case .leftToRight: .leftToRight
        case .rightToLeft: .rightToLeft
        }
    }

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
                miniTopBar

                VStack(spacing: bottomMode == .none ? 8 : 12) {
                    coverArea
                    metaArea
                    scrubber
                    if bottomMode != .none {
                        transport
                    }

                    // 歌词/队列 tab 只在展开态出现(底部面板的切换条)。
                    if bottomMode != .none {
                        subviewTabs
                            .padding(.top, 2)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 16)

                if bottomMode != .none {
                    bottomPanel
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                } else {
                    Spacer(minLength: 0)
                }
                footerToolbar
            }
            .animation(.easeInOut(duration: 0.28), value: bottomMode)
        }
        // 内容钉成设计尺寸:宽 300,高随折叠/展开在 220 / 540 间切换。
        .frame(
            width: MiniPlayerWindowController.fixedWidth,
            height: bottomMode == .none
                ? MiniPlayerWindowController.collapsedHeight
                : MiniPlayerWindowController.expandedHeight
        )
        .pmWindowDragRegion()
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: lyricsLoadTaskIdentity) {
            if player.isLiveRadio {
                lyrics = []
            } else {
                await refreshLyrics()
            }
        }
        .background {
            MacMiniPlayerTimeObserver { updateIndex(time: $0) }
        }
        .onChange(of: bottomMode) { _, new in onBottomModeChange?(new) }
        .onChange(of: player.isLiveRadio, initial: true) { _, isLive in
            if isLive, bottomMode != .none { bottomMode = .none }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseLyricsDidChange)) { note in
            guard let songID = note.object as? String,
                  songID == player.currentSong?.id else { return }
            pendingLyricsOverride = (note.userInfo?["lyrics"] as? [LyricLine]).map {
                PendingLyricsOverride(songID: songID, lyrics: $0)
            }
            lyricsLoadRevision &+= 1
        }
    }

    /// 固定的 36pt 顶部 bar — 流量灯 (close/min/zoom) 左, 中间空白可拖拽,
    /// 右侧两个按钮: 折叠/展开箭头 + 直接关窗 X (双保险, 防 NSPanel 上传统流量
    /// 灯失效用户没法关窗)。底部 0.5pt divider 让 bar 跟下方内容分开, 视觉
    /// 一定能找到。
    private var miniTopBar: some View {
        HStack(spacing: 8) {
            Spacer()

            // 折叠 / 展开
            if !player.isLiveRadio {
                Button {
                    bottomMode = bottomMode == .none ? .lyrics : .none
                } label: {
                    topBarIcon(bottomMode == .none ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .help(Text(bottomMode == .none ? "show" : "hide"))
            }

            // 关闭(收起窗口)—— 右上角关闭键,替代之前的红绿灯。
            Button { onClose() } label: {
                topBarIcon("xmark")
            }
            .buttonStyle(.plain)
            .help(Text("close"))
        }
        .padding(.trailing, 12)
        .frame(height: bottomMode == .none ? 32 : 40)
        .pmWindowDragRegion()
        // 不放背景色带 + 分隔线:控件直接浮在 ambient 渐变上,顶部不再有断层色带。
    }

    private func topBarIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(PMColor.text.opacity(0.85))
            .frame(width: 26, height: 26)
            .background(PMColor.text.opacity(0.10), in: .circle)
    }

    // MARK: - Backdrop

    private var ambientBackdrop: some View {
        // 不用共享的 `AmbientBackdrop`：它的 drawingGroup 会干扰 mini hosting。
        // 这里用跟随外观的实色底 + 封面色微光，浅色与深色均保持完整对比度。
        PMColor.bgDeep
            .overlay(
                LinearGradient(
                    colors: [
                        theme.accentColor.opacity(
                            (colorScheme == .dark ? 0.28 : 0.18) * preferences.ambientStrength
                        ),
                        .clear,
                        theme.darkAccent.opacity(
                            (colorScheme == .dark ? 0.22 : 0.12) * preferences.ambientStrength
                        ),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    /// 折叠态居中显示的 96pt 封面 — 跟设计稿 NP-Mini 一致。
    private var coverArea: some View {
        let coverSize: CGFloat = bottomMode == .none ? 76 : 96
        let cornerRadius: CGFloat = bottomMode == .none ? 8 : 10
        return Group {
            if player.isLiveRadio, let station = player.currentRadioStation {
                RadioStationArtworkView(
                    station: station,
                    size: coverSize,
                    cornerRadius: cornerRadius
                )
            } else if let song = player.currentSong {
                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id,
                    size: coverSize, cornerRadius: cornerRadius,
                    sourceID: song.sourceID, filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(PMColor.text.opacity(0.10))
                    .frame(width: coverSize, height: coverSize)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: bottomMode == .none ? 24 : 30))
                            .foregroundStyle(PMColor.textFaint)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.32 : 0.18), radius: 12, y: 5)
        .contentShape(Rectangle())
        // 点封面切换折叠/展开 —— 跟 Apple Music 一致,也作为顶栏折叠箭头的兜底
        // 入口(保证折叠态一定能展开到歌词/队列)。
        .onTapGesture {
            if !player.isLiveRadio {
                bottomMode = bottomMode == .none ? .lyrics : .none
            }
        }
    }

    /// 标题/艺术家 — 居中显示, 紧贴 cover 下方。
    private var metaArea: some View {
        VStack(spacing: 2) {
            Text(player.currentRadioStation?.name ?? player.currentSong?.title ?? "—")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(player.radioMetadataTitle ?? player.currentSong?.artistName ?? "")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textMuted)
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
                .foregroundStyle(active ? PMColor.text : PMColor.textFaint)
                .padding(.vertical, 4)
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(active ? PMColor.text : Color.clear)
                        .frame(height: 2)
                }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var footerToolbar: some View {
        if player.isLiveRadio {
            radioFooterToolbar
        } else {
            trackFooterToolbar
        }
    }

    private var radioFooterToolbar: some View {
        HStack(spacing: 8) {
            Button { airPlayShown.toggle() } label: {
                miniIcon("airplayaudio", tint: airPlayShown ? theme.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .popover(isPresented: $airPlayShown, arrowEdge: .top) {
                AudioOutputPickerView()
            }
            .help(Text("audio_output"))

            Button { Task { await player.previous() } } label: {
                miniIcon("backward.fill")
            }
            .buttonStyle(.plain)
            .disabled(!player.canSwitchRadioStation)
            .help(Text("radio_previous_station"))

            Button { player.togglePlayPause() } label: {
                miniIcon(
                    (player.isPlaying || player.isLoading) ? "stop.fill" : "play.fill",
                    tint: theme.onAccent
                )
                .background(theme.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .help(Text((player.isPlaying || player.isLoading) ? "radio_stop" : "a11y_play"))

            Button { Task { await player.next() } } label: {
                miniIcon("forward.fill")
            }
            .buttonStyle(.plain)
            .disabled(!player.canSwitchRadioStation)
            .help(Text("radio_next_station"))

            if showsPlayerVolumeBar {
                Spacer(minLength: 6)

                Image(systemName: volumeSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 14)

                PMVolumeSlider(value: Binding(
                    get: { Double(engine.volume) },
                    set: { player.setPlaybackVolume(Float($0)) }
                ), isEnabled: true)
                .frame(width: 92)
                .help(Text("volume"))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private var trackFooterToolbar: some View {
        HStack(spacing: 6) {
            // Lyrics 切换 —— 高亮 = 当前下半部分显示歌词。再点切到 .none
            // 隐藏面板,留给封面更多空间。
            Button {
                bottomMode = (bottomMode == .lyrics) ? .none : .lyrics
            } label: {
                miniIcon(bottomMode == .lyrics ? "text.bubble.fill" : "text.bubble",
                         tint: bottomMode == .lyrics ? theme.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("lyrics_word"))

            // Queue —— 切到下半部分显示当前队列。
            Button {
                bottomMode = (bottomMode == .queue) ? .none : .queue
            } label: {
                miniIcon(bottomMode == .queue ? "list.bullet.indent" : "list.bullet",
                         tint: bottomMode == .queue ? theme.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("queue_title"))

            Button { airPlayShown.toggle() } label: {
                miniIcon("airplayaudio", tint: airPlayShown ? theme.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .popover(isPresented: $airPlayShown, arrowEdge: .top) {
                AudioOutputPickerView()
            }
            .help(Text("audio_output"))

            if showsPlayerVolumeBar {
                Spacer(minLength: 8)

                Image(systemName: volumeSymbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 14)

                // AppKit slider opts out of window-background dragging, so volume
                // drags stay on the control in this borderless panel.
                PMVolumeSlider(value: Binding(
                    get: { Double(engine.volume) },
                    set: { player.setPlaybackVolume(Float($0)) }
                ), isEnabled: player.playbackSettings.outputMode == .effects,
                   accessibilityHelp: player.playbackSettings.outputMode == .highFidelity
                       ? String(localized: "volume_high_fidelity_system_hint")
                       : nil)
                .frame(width: 64)
                .help(player.playbackSettings.outputMode == .highFidelity
                    ? Text("volume_high_fidelity_system_hint")
                    : Text("volume"))
            }

            PlayerMoreMenu {
                miniIcon("ellipsis", tint: .secondary)
            }
            .frame(width: 28, height: 28)
            .fixedSize()
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 12)
        .padding(.vertical, bottomMode == .none ? 8 : 10)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
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
        MacMiniPlayerProgress(tint: theme.accentColor)
    }

    // MARK: - Transport

    private var transport: some View {
        HStack(spacing: 18) {
            // shuffle / repeat 带淡圆底,高亮时上强调色(随专辑色),跟设计稿一致。
            Button { player.shuffleEnabled.toggle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(player.shuffleEnabled ? theme.accentColor : PMColor.textMuted)
                    .frame(width: 30, height: 30)
                    .background(PMColor.text.opacity(0.06), in: .circle)
            }
            .buttonStyle(.plain)

            Button { Task { await player.previous() } } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PMColor.text)
            }
            .buttonStyle(.plain)

            // 播放/暂停 —— 实心强调色圆,设计稿里最醒目的粉色圆。
            Button { player.togglePlayPause() } label: {
                ZStack {
                    Circle().fill(theme.accentColor).frame(width: 46, height: 46)
                    // 加载/缓冲时显示转圈, 跟主界面底栏播放键一致, 免得用户以为卡住了。
                    if player.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(theme.onAccent)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(theme.onAccent)
                            .contentTransition(.symbolEffect(.replace))
                            .offset(x: player.isPlaying ? 0 : 1)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(player.isLoading)

            Button { Task { await player.next() } } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(PMColor.text)
            }
            .buttonStyle(.plain)

            Button { cycleRepeat() } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(player.repeatMode != .off ? theme.accentColor : PMColor.textMuted)
                    .frame(width: 30, height: 30)
                    .background(PMColor.text.opacity(0.06), in: .circle)
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
                    // currentIndex 在切歌/换队列瞬间可能越界, 先钳到合法区间,
                    // 否则下面构造 Range 时 lowerBound > upperBound 会 trap。
                    let count = player.queue.count
                    let cur = min(max(player.currentIndex, 0), count - 1)

                    if let current = player.currentSong {
                        Text("now_playing")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        queueRow(index: cur, song: current, isPlaying: true)
                            .padding(.bottom, 4)
                    }

                    let upNext = (cur + 1)..<count
                    if !upNext.isEmpty {
                        Text("up_next")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        ForEach(Array(upNext), id: \.self) { idx in
                            queueRow(index: idx)
                        }
                    }
                    let played = 0..<cur
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
            // 隐藏器放进 ScrollView 内容里 (而不是挂在 ScrollView 外层的
            // .background) —— 这样 enclosingScrollView 能直接拿到队列自己的
            // NSScrollView。迷你播放器这种多层嵌套下, 外层 .background 那个
            // 隐藏器是兄弟节点, 找不到, 滚动条隐不掉。
            .pmForceHideScrollers()
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func queueRow(index: Int, song overrideSong: Song? = nil, isPlaying: Bool = false) -> some View {
        // LazyVStack 懒渲染时, 队列可能已被切歌/清空缩短, index 不再有效;
        // 用 indices 判定而非直接下标, 避免越界 trap。
        if let song = overrideSong ?? (player.queue.indices.contains(index) ? player.queue[index] : nil) {
            HStack(spacing: 9) {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 32, cornerRadius: 6,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
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
            .background(isPlaying ? theme.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                        in: .rect(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture {
                player.currentIndex = index
                Task { await player.play(song: song) }
            }
        }
    }

    // MARK: - Lyrics list

    private var lyricsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .center, spacing: 14) {
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
                                .frame(maxWidth: .infinity, alignment: .center)
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
                guard Date().timeIntervalSince(lastManualLyricsScroll) >= 3 else { return }
                scrollLyrics(to: new, proxy: proxy, animated: true)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        lyricsAutoFollowTask?.cancel()
                        lastManualLyricsScroll = Date()
                    }
                    .onEnded { _ in
                        lastManualLyricsScroll = Date()
                        scheduleLyricsAutoFollow(proxy: proxy)
                    }
            )
            .task(id: lyricsScrollIdentity) {
                let targetIndex = updateIndex(time: player.currentTime)
                await Task.yield()
                guard !Task.isCancelled, let targetIndex else { return }
                scrollLyrics(to: targetIndex, proxy: proxy, animated: false)
            }
            .onDisappear {
                lyricsAutoFollowTask?.cancel()
            }
            .pmForceHideScrollers()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lyricsScrollIdentity: String {
        "\(player.currentSong?.id ?? "")|\(lyricsLoadRevision)|\(lyrics.first?.id ?? "")|\(lyrics.count)"
    }

    private struct LyricsLoadTaskIdentity: Hashable {
        let songID: String?
        let revision: UInt
    }

    private struct PendingLyricsOverride {
        let songID: String
        let lyrics: [LyricLine]
    }

    private var lyricsLoadTaskIdentity: LyricsLoadTaskIdentity {
        LyricsLoadTaskIdentity(
            songID: player.currentSong?.id,
            revision: lyricsLoadRevision
        )
    }

    private func scheduleLyricsAutoFollow(proxy: ScrollViewProxy) {
        lyricsAutoFollowTask?.cancel()
        lyricsAutoFollowTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled,
                  Date().timeIntervalSince(lastManualLyricsScroll) >= 3 else { return }
            scrollLyrics(to: currentIndex, proxy: proxy, animated: true)
        }
    }

    private func scrollLyrics(to index: Int, proxy: ScrollViewProxy, animated: Bool) {
        guard lyrics.indices.contains(index) else { return }
        let update = { proxy.scrollTo(lyrics[index].id, anchor: .center) }
        if animated {
            withAnimation(.easeInOut(duration: 0.3), update)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        }
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
                writingDirection: lyricsWritingDirection,
                timeAt: { date in player.interpolatedTime(at: date) }
            )
        } else {
            Text(line.text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(isActive ? .primary : .secondary)
                .opacity(isActive ? 1 : 0.55)
                .multilineTextAlignment(.center)
                .environment(\.layoutDirection, lyricLayoutDirection)
        }
    }

    private func shouldRenderWordTimeline(line: LyricLine, index: Int, isActive: Bool) -> Bool {
        guard line.isWordLevel else { return false }
        return isActive || abs(index - currentIndex) == 1
    }

    private func refreshLyrics() async {
        if let pendingLyricsOverride,
           pendingLyricsOverride.songID == player.currentSong?.id {
            self.pendingLyricsOverride = nil
            lyrics = pendingLyricsOverride.lyrics
            _ = updateIndex(time: player.currentTime)
            return
        }
        pendingLyricsOverride = nil
        await reloadLyrics()
    }

    private func reloadLyrics() async {
        guard let song = player.currentSong else {
            lyrics = []; currentIndex = 0; return
        }
        lyrics = []; currentIndex = 0
        let loaded = await LyricsLoader.load(for: song, sourceManager: sourceManager)
        guard !Task.isCancelled, player.currentSong?.id == song.id else { return }
        lyrics = loaded
        _ = updateIndex(time: player.currentTime)
    }

    @discardableResult
    private func updateIndex(time: TimeInterval) -> Int? {
        guard let index = LyricPlaybackPositionPolicy.activeLineIndex(
            in: lyrics,
            at: time
        ) else { return nil }
        if currentIndex != index { currentIndex = index }
        return index
    }
}

private struct MacMiniPlayerTimeObserver: View {
    @Environment(AudioPlayerService.self) private var player
    let onTimeChange: (TimeInterval) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: player.currentTime) { _, time in onTimeChange(time) }
    }
}

private struct MacMiniPlayerProgress: View {
    @Environment(AudioPlayerService.self) private var player
    let tint: Color

    var body: some View {
        Group {
            if player.isLiveRadio {
                HStack(spacing: 7) {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text("LIVE").fontWeight(.bold)
                    Spacer()
                    Text(formatTime(player.currentTime))
                }
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(PMColor.textMuted)
            } else {
                VStack(spacing: 4) {
                    ScrubberLine(
                        value: player.currentTime,
                        total: max(player.duration, 0.01),
                        tint: tint,
                        onSeek: { player.seek(to: $0) }
                    )
                    HStack {
                        Text(formatTime(player.currentTime))
                        Spacer()
                        Text(formatTime(player.duration))
                    }
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(PMColor.textFaint)
                }
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = time.finiteInt()
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Scrubber slider only commits seek on release, otherwise AVAudioEngine
/// chokes on the per-frame seeks during a drag.
private struct ScrubberLine: View {
    let value: Double
    let total: Double
    var tint: Color = .secondary
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
        .tint(tint)
    }
}
#endif
