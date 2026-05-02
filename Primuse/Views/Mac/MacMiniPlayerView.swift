#if os(macOS)
import SwiftUI
import PrimuseKit

/// 迷你播放器内容。竖排:工具条 / 进度 / 传输键 / 滚动歌词。整体材质用
/// regularMaterial + 封面虚化做 ambient 背景,跟 NowPlaying 风格统一。
/// iOS 端同名 MiniPlayerView 是底栏 mini 卡片,跟这个全窗口 mini 播放
/// 器作用不同,所以这里命名为 `MacMiniPlayerView`。
struct MacMiniPlayerView: View {
    var onClose: () -> Void = {}

    @Environment(AudioPlayerService.self) private var player
    @Environment(AudioEngine.self) private var engine
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @State private var lyrics: [LyricLine] = []
    @State private var currentIndex: Int = 0
    @State private var airPlayShown = false
    @State private var volumeShown = false

    /// 下半部分内容模式 —— 跟 Apple Music 一样,Lyrics / Queue 是互斥的
    /// 内容面板,工具条上的按钮高亮的就是当前激活模式。
    enum BottomMode { case lyrics, queue, none }
    @State private var bottomMode: BottomMode = .lyrics

    var body: some View {
        ZStack {
            ambientBackdrop
            VStack(spacing: 12) {
                topToolbar
                scrubber
                transport
                Divider().opacity(0.3)
                bottomPanel
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        .task(id: player.currentSong?.id) { await reloadLyrics() }
        .onChange(of: player.currentTime) { _, t in updateIndex(time: t) }
    }

    // MARK: - Backdrop

    private var ambientBackdrop: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let song = player.currentSong {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: nil,
                    cornerRadius: 0,
                    sourceID: song.sourceID,
                    filePath: song.filePath
                )
                .blur(radius: 50)
                .opacity(0.55)
                .scaleEffect(2.0)
                .clipped()
                .allowsHitTesting(false)
            }
            Rectangle().fill(.ultraThinMaterial)
        }
        .ignoresSafeArea()
    }

    // MARK: - Top toolbar

    private var topToolbar: some View {
        HStack(spacing: 6) {
            PlayerMoreMenu {
                miniIcon("ellipsis")
            }
            .frame(width: 28, height: 28)
            .fixedSize()
            .glassEffect(.regular.interactive(), in: .circle)

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

            // Volume —— 点击弹一个小 popover,里面是音量 slider。
            Button { volumeShown.toggle() } label: {
                miniIcon(volumeSymbol, tint: volumeShown ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .popover(isPresented: $volumeShown, arrowEdge: .top) {
                volumePopover
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var volumePopover: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.caption).foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { Double(engine.volume) },
                    set: { engine.volume = Float($0) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .frame(width: 160)
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
                Text("-\(formatTime(max(0, player.duration - player.currentTime)))")
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
            LazyVStack(alignment: .leading, spacing: 6) {
                if player.queue.isEmpty {
                    Text("queue_empty")
                        .font(.callout).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).padding(.top, 30)
                } else {
                    let upNext = (player.currentIndex + 1)..<player.queue.count
                    if !upNext.isEmpty {
                        Text("up_next")
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        ForEach(Array(upNext), id: \.self) { idx in
                            queueRow(index: idx)
                        }
                    }
                    let played = 0..<player.currentIndex
                    if !played.isEmpty {
                        Text("played")
                            .font(.caption).fontWeight(.semibold)
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
    }

    private func queueRow(index: Int) -> some View {
        let song = player.queue[index]
        return HStack(spacing: 8) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 28, cornerRadius: 4,
                sourceID: song.sourceID,
                filePath: song.filePath
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).font(.caption).lineLimit(1)
                Text(song.artistName ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
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
                            Text(line.text)
                                .font(.system(size: active ? 18 : 14, weight: active ? .bold : .regular))
                                .foregroundStyle(active ? .primary : .secondary)
                                .opacity(active ? 1 : 0.55)
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
#endif
