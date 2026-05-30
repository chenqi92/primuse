#if os(macOS)
import SwiftUI
import PrimuseKit

/// macOS-native "now playing" full-area view. Shown inline inside the main
/// window — covers the detail pane while the sidebar and the bottom mini
/// bar stay visible. No sheet, no drag-to-dismiss, no GeometryReader hacks.
///
/// Visual: built on `.regularMaterial` (the same surface used by sheets,
/// popovers and other macOS chrome) plus a very subtle cover-art tint, so
/// it reads as part of the same window instead of a black popup glued on
/// top. Text uses `.primary` / `.secondary` so it follows the user's
/// light/dark appearance.
///
/// Layout: artwork on the left, scrolling lyrics on the right with the
/// active line highlighted and pinned near the vertical center. Transport
/// stays in the mini bar — duplicating it here would just fight the user.
struct MacNowPlayingView: View {
    var onClose: () -> Void
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(SourceManager.self) private var sourceManager
    @Environment(ThemeService.self) private var theme

    @State private var lyrics: [LyricLine] = []
    @State private var currentIndex: Int = 0
    @State private var isScrapingCurrentSong = false
    @State private var scrapeAlertMessage: String?
    /// 当前主窗口是否处于 macOS 全屏。全屏时切到 Apple Music 风格的极
    /// 简布局——只显示巨幅封面和歌曲信息,不再排歌词列表/浮动按钮。
    @State private var isWindowFullScreen = false

    /// 与 iOS 共用同一个键 `lyricsFontScale` (0.7..1.8),通过 CloudKVS 双向同步。
    /// 之前的 `now_playing_lyrics_base_font` 是 macOS 独有的本地键,改这里
    /// 同时让 iOS 端的 4 档预设也直接生效。
    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0

    private static let lyricsMinScale: Double = 0.7
    private static let lyricsMaxScale: Double = 1.8
    private static let lyricsActiveBaseSize: CGFloat = 30
    private static let lyricsInactiveBaseSize: CGFloat = 22
    private static let lyricsActiveBaseSizeFS: CGFloat = 44
    private static let lyricsInactiveBaseSizeFS: CGFloat = 28

    private var isCurrentLiked: Bool {
        guard let songID = player.currentSong?.id else { return false }
        return library.isLiked(songID: songID)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            backdrop

            if player.currentSong == nil {
                emptyNowPlaying
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 48)
            } else {
                // 全屏与普通展开复用同一套「左封面 + 右滚动歌词」布局,
                // 只是字号 / 间距更大、退出全屏按钮替换关闭按钮。这样
                // 全屏下也能看到完整滚动歌词,而不是像桌面歌词那样只
                // 显示当前一两句。
                HStack(alignment: .top, spacing: isWindowFullScreen ? 56 : 36) {
                    artworkPane
                        .frame(width: isWindowFullScreen ? 480 : 380)
                        .frame(maxHeight: .infinity)
                    lyricsPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(.horizontal, isWindowFullScreen ? 64 : 40)
                .padding(.top, isWindowFullScreen ? 56 : 32)
                .padding(.bottom, isWindowFullScreen ? 48 : 24)
            }

            floatingControls
                .padding(18)
        }
        .task(id: player.currentSong?.id) { await reloadLyrics() }
        .onChange(of: player.currentTime) { _, t in updateIndex(time: t) }
        .onChange(of: lyricsFontScale) { _, _ in
            CloudKVSSync.shared.markChanged(key: CloudKVSKey.lyricsFontScale)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseLyricsDidChange)) { note in
            guard let songID = note.object as? String,
                  songID == player.currentSong?.id else { return }
            Task { await reloadLyrics() }
        }
        // 监听主窗口进入/退出全屏(macOS NSWindow 通知),切换布局。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isWindowFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isWindowFullScreen = false
        }
        .alert(String(localized: "scrape_song"),
               isPresented: Binding(get: { scrapeAlertMessage != nil },
                                    set: { if !$0 { scrapeAlertMessage = nil } })) {
            Button("done", role: .cancel) {}
        } message: { Text(scrapeAlertMessage ?? "") }
    }

    // MARK: - Sections

    private var emptyNowPlaying: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(.primary.opacity(0.06))
                    .frame(width: 118, height: 118)
                Image(systemName: "music.note")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                Text("player_empty_title")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.white)
                Text("player_empty_message")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: 520)
        }
    }

    /// 1.6 重设计后的 ambient backdrop — 由 ThemeService 的动态 accent (从封面提取)
    /// 驱动多色斑模糊, 替代之前的 cover blur + ultraThinMaterial 组合, 让背景跟着
    /// 当前歌曲色调走, 跟设计稿 AmbientBackdrop 视觉一致。
    ///
    /// 关键: 先铺一层不透明的 `bgDeep` 实色底。`AmbientBackdrop` 内部对整组 (含自身
    /// 底色) 施加了 `.opacity(strength)`, 单独用时会半透 —— 这个 view 是盖在
    /// MacDetailContainer (首页仪表盘) 之上的 overlay, 不补底就会"穿透"看到后面的
    /// 内容。补一层不透明底后整页变实, 顶部玻璃按钮也回到暗背景上、白色图标恢复可读。
    private var backdrop: some View {
        ZStack {
            PMColor.ambientDarkBase
            AmbientBackdrop(
                accent: theme.accentColor,
                darkAccent: theme.darkAccent,
                strength: 0.85,
                forceDark: true
            )
        }
        .ignoresSafeArea()
    }

    private var artworkPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 0)
            Group {
                if let song = player.currentSong {
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: nil,
                        cornerRadius: 14,
                        sourceID: song.sourceID,
                        filePath: song.filePath
                    )
                    .aspectRatio(1, contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.quaternary)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.system(size: 80))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .frame(maxWidth: 460)
            .shadow(color: .black.opacity(0.18), radius: 20, y: 8)

            VStack(alignment: .leading, spacing: 6) {
                if let format = player.currentSong?.fileFormat.displayName, !format.isEmpty {
                    Text(format.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.62))
                }
                Text(player.currentSong?.title ?? "")
                    .font(.system(size: isWindowFullScreen ? 44 : 32, weight: .bold))
                    .tracking(-0.6)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(player.currentSong?.artistName ?? "")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                if let album = player.currentSong?.albumTitle, !album.isEmpty {
                    Text(album)
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 460, alignment: .leading)

            Spacer(minLength: 0)
        }
    }

    private var lyricsPane: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Spacer(minLength: 80).frame(height: 80)
                    if lyrics.isEmpty {
                        if player.currentSong == nil {
                            Color.clear.frame(height: 1)
                        } else {
                            VStack(spacing: 12) {
                                Text("no_lyrics")
                                    .font(.title3)
                                    .foregroundStyle(.white.opacity(0.6))
                                Button {
                                    Task { await scrapeCurrentSong() }
                                } label: {
                                    Label("scrape_song", systemImage: "wand.and.stars")
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(Color.white.opacity(0.18), in: Capsule())
                                        .overlay { Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
                                        .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                                .disabled(isScrapingCurrentSong)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    } else {
                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { i, line in
                            let isActive = i == currentIndex
                            let baseSize = activeFontSize(isActive: isActive)
                            macLyricLine(line: line, index: i, isActive: isActive, fontSize: baseSize)
                                .id(line.id)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { player.seek(to: line.timestamp) }
                                .animation(.easeInOut(duration: 0.25), value: currentIndex)
                        }
                    }
                    Spacer(minLength: 200).frame(height: 200)
                }
                .padding(.horizontal, PMSpace.l24)
            }
            .pmVerticalFadeMask(startStop: 0.12, endStop: 0.88)
            .onChange(of: currentIndex) { _, new in
                guard !lyrics.isEmpty, new < lyrics.count else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(lyrics[new].id, anchor: .center)
                }
            }
        }
    }

    private func activeFontSize(isActive: Bool) -> CGFloat {
        if isWindowFullScreen {
            return isActive ? Self.lyricsActiveBaseSizeFS : Self.lyricsInactiveBaseSizeFS
        }
        return isActive ? Self.lyricsActiveBaseSize : Self.lyricsInactiveBaseSize
    }

    @ViewBuilder
    private func macLyricLine(line: LyricLine, index: Int, isActive: Bool, fontSize: CGFloat) -> some View {
        let scaledSize = fontSize * CGFloat(lyricsFontScale)
        let weight: Font.Weight = isActive ? .semibold : .regular
        let tint = theme.accentColor
        if shouldRenderWordTimeline(line: line, index: index, isActive: isActive) {
            KaraokeLineView(
                line: line,
                fontSize: scaledSize,
                weight: weight,
                activeColor: isActive ? tint : .white.opacity(0.6),
                inactiveColor: .white.opacity(isActive ? 0.55 : 0.32),
                timeAt: { date in player.interpolatedTime(at: date) }
            )
            .shadow(color: isActive ? tint.opacity(0.45) : .clear, radius: 14)
        } else {
            Text(line.text)
                .font(.system(size: scaledSize, weight: weight))
                .foregroundStyle(isActive ? .white : .white.opacity(0.5))
                .opacity(isActive ? 1 : 0.7)
        }
    }

    private func shouldRenderWordTimeline(line: LyricLine, index: Int, isActive: Bool) -> Bool {
        guard line.isWordLevel else { return false }
        return isActive || abs(index - currentIndex) == 1
    }

    // MARK: - Floating controls (top-right of the window)

    private var floatingControls: some View {
        HStack(spacing: 8) {
            // Heart
            Button { toggleLikedCurrent() } label: {
                circleIcon(isCurrentLiked ? "heart.fill" : "heart",
                           tint: isCurrentLiked ? Color.white : Color.white.opacity(0.85),
                           fill: isCurrentLiked ? theme.accentColor : nil)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
            .disabled(player.currentSong == nil)

            Button {} label: {
                circleIcon("text.bubble.fill",
                           tint: Color.white,
                           fill: theme.accentColor.opacity(0.9))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("lyrics_word"))
            .disabled(player.currentSong == nil)

            Button {
                onClose()
                NotificationCenter.default.post(name: .primuseFocusSearch, object: nil)
            } label: {
                circleIcon("magnifyingglass")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("search_title"))

            // Font smaller
            Button {
                lyricsFontScale = max(Self.lyricsMinScale, lyricsFontScale - 0.15)
            } label: {
                Text(verbatim: "A-")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("lyrics_font_smaller"))
            .disabled(lyrics.isEmpty)

            // Font larger
            Button {
                lyricsFontScale = min(Self.lyricsMaxScale, lyricsFontScale + 0.15)
            } label: {
                Text(verbatim: "A+")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("lyrics_font_larger"))
            .disabled(lyrics.isEmpty)

            // 复用底栏共享的 PlayerMoreMenu,确保两处菜单项一致。
            PlayerMoreMenu {
                circleIcon("ellipsis")
            }
            .frame(width: 36, height: 36)
            .fixedSize()
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("more"))

            // Close —— 全屏时改成"退出全屏",非全屏时是"收起歌词"。
            Button {
                if isWindowFullScreen {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                } else {
                    onClose()
                }
            } label: {
                circleIcon(isWindowFullScreen
                           ? "arrow.down.right.and.arrow.up.left"
                           : "chevron.down")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("close"))
            .keyboardShortcut(.cancelAction)
        }
    }

    /// 关键: 把 36×36 frame + contentShape 放在 Button 的 label 内部
    /// (而不是包在 Button 外面),这样整个圆形区域都是 Button 的有效点击
    /// 区——之前 .frame 套在 Button 外面,Button 的实际命中区只跟图标
    /// 一样大,玻璃外圈那一圈点了没反应。
    private func circleIcon(_ symbol: String,
                            tint: Color = .white.opacity(0.85),
                            fill: Color? = nil) -> some View {
        ZStack {
            if let fill {
                Circle().fill(fill)
            }
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: 36, height: 36)
        .contentShape(Circle())
    }

    private func toggleLikedCurrent() {
        guard let songID = player.currentSong?.id else { return }
        library.toggleLiked(songID: songID)
    }

    // MARK: - Lyrics loading

    private func reloadLyrics() async {
        guard let song = player.currentSong else {
            lyrics = []; currentIndex = 0; return
        }
        // 先清掉上一首的内容,避免在异步加载途中显示「上首歌的歌词」。
        lyrics = []; currentIndex = 0

        let loaded = await LyricsLoader.load(for: song, sourceManager: sourceManager)
        // 异步等待期间用户可能跳到了下一首,这时把当前结果写回去就会
        // 把"上一首的歌词"显示在新歌上。`task(id:)` 理论上会取消旧任务
        // 但 LyricsLoader 内部网络拉取不一定及时响应取消,做一道防御。
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

    // MARK: - Actions

    private func scrapeCurrentSong() async {
        guard let song = player.currentSong else { return }
        isScrapingCurrentSong = true
        defer { isScrapingCurrentSong = false }
        do {
            let (u, _, _) = try await scraperService.scrapeSingle(song: song, in: library)
            CachedArtworkView.invalidateCache(for: u.id)
            if let oldRef = song.coverArtFileName { CachedArtworkView.invalidateCache(for: oldRef) }
            player.syncSongMetadata(u)
            player.forceRefreshNowPlayingArtwork()
            await reloadLyrics()
            scrapeAlertMessage = String(localized: "scrape_song_success")
        } catch {
            scrapeAlertMessage = String(localized: "scrape_song_failed")
        }
    }

    // 删除歌曲流程已移到 PlayerMoreMenu,这里不再保留 deleteCurrentSong。
}
#endif
