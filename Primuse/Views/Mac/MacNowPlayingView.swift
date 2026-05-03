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
    @Environment(SourcesStore.self) private var sourcesStore

    @State private var lyrics: [LyricLine] = []
    @State private var currentIndex: Int = 0
    @State private var isScrapingCurrentSong = false
    @State private var scrapeAlertMessage: String?
    @State private var showAddToPlaylist = false
    /// 当前主窗口是否处于 macOS 全屏。全屏时切到 Apple Music 风格的极
    /// 简布局——只显示巨幅封面和歌曲信息,不再排歌词列表/浮动按钮。
    @State private var isWindowFullScreen = false

    /// 与 iOS 共用同一个键 `lyricsFontScale` (0.7..1.8),通过 CloudKVS 双向同步。
    /// 之前的 `now_playing_lyrics_base_font` 是 macOS 独有的本地键,改这里
    /// 同时让 iOS 端的 4 档预设也直接生效。
    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0

    private static let lyricsMinScale: Double = 0.7
    private static let lyricsMaxScale: Double = 1.8
    private static let lyricsActiveBaseSize: CGFloat = 22
    private static let lyricsInactiveBaseSize: CGFloat = 17

    private var isInAnyPlaylist: Bool {
        guard let songID = player.currentSong?.id else { return false }
        return library.playlists.contains { library.contains(songID: songID, inPlaylist: $0.id) }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            backdrop

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

            floatingControls
                .padding(18)
        }
        .task(id: player.currentSong?.id) { await reloadLyrics() }
        .onChange(of: player.currentTime) { _, t in updateIndex(time: t) }
        .onChange(of: lyricsFontScale) { _, _ in
            CloudKVSSync.shared.markChanged(key: CloudKVSKey.lyricsFontScale)
        }
        // 监听主窗口进入/退出全屏(macOS NSWindow 通知),切换布局。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isWindowFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isWindowFullScreen = false
        }
        // heart 直接弹「加入播放列表」sheet,这里独立保留;其余 more 菜单
        // 项全部走 PlayerMoreMenu(底栏 + NowPlaying 共用同一份逻辑)。
        .sheet(isPresented: $showAddToPlaylist) {
            if let song = player.currentSong {
                AddToPlaylistSheet(song: song)
            }
        }
        .alert(String(localized: "scrape_song"),
               isPresented: Binding(get: { scrapeAlertMessage != nil },
                                    set: { if !$0 { scrapeAlertMessage = nil } })) {
            Button("done", role: .cancel) {}
        } message: { Text(scrapeAlertMessage ?? "") }
    }

    // MARK: - Sections

    /// 完全铺满的 ambient backdrop —— 之前 `regularMaterial + 0.35
    /// 透明度的 cover blur` 在浅色模式下两侧像两条白边,封面色完全
    /// 没扩散到边缘。改成: 底层放放大的封面虚化(更高 opacity + 更大
    /// scaleEffect 保证铺满) → 上面叠 ultraThinMaterial 软化 → 外层
    /// .ignoresSafeArea 让 backdrop 也覆盖到 NowPlaying 容器边缘外。
    private var backdrop: some View {
        ZStack {
            // 浅色基底,确保 cover blur 没图时也不会透出底层 detail 视图。
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
                .blur(radius: 60)
                .opacity(0.55)
                .scaleEffect(2.4)
                .clipped()
                .allowsHitTesting(false)
            }
            // 软化 cover 的强烈色块,变成 Apple Music 那种朦胧渐变感。
            Rectangle().fill(.ultraThinMaterial)
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
                Text(player.currentSong?.title ?? "")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(player.currentSong?.artistName ?? "")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let album = player.currentSong?.albumTitle, !album.isEmpty {
                    Text(album)
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
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
                                    .foregroundStyle(.tertiary)
                                Button {
                                    Task { await scrapeCurrentSong() }
                                } label: {
                                    Label("scrape_song", systemImage: "wand.and.stars")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .disabled(isScrapingCurrentSong)
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        }
                    } else {
                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { i, line in
                            let isActive = i == currentIndex
                            let baseSize = isActive ? Self.lyricsActiveBaseSize : Self.lyricsInactiveBaseSize
                            Text(line.text)
                                .font(.system(size: baseSize * CGFloat(lyricsFontScale),
                                              weight: isActive ? .semibold : .regular))
                                .foregroundStyle(isActive ? .primary : .secondary)
                                .opacity(isActive ? 1 : 0.6)
                                .id(line.id)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { player.seek(to: line.timestamp) }
                                .animation(.easeInOut(duration: 0.25), value: currentIndex)
                        }
                    }
                    Spacer(minLength: 200).frame(height: 200)
                }
                .padding(.horizontal, 24)
            }
            .onChange(of: currentIndex) { _, new in
                guard !lyrics.isEmpty, new < lyrics.count else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(lyrics[new].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Floating controls (top-right of the window)

    private var floatingControls: some View {
        HStack(spacing: 8) {
            // Heart
            Button { showAddToPlaylist = true } label: {
                circleIcon(isInAnyPlaylist ? "heart.fill" : "heart",
                           tint: isInAnyPlaylist ? Color.red : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("add_to_playlist"))
            .disabled(player.currentSong == nil)

            // Font smaller
            Button {
                lyricsFontScale = max(Self.lyricsMinScale, lyricsFontScale - 0.15)
            } label: {
                circleIcon("textformat.size.smaller")
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .help(Text("lyrics_font_smaller"))
            .disabled(lyrics.isEmpty)

            // Font larger
            Button {
                lyricsFontScale = min(Self.lyricsMaxScale, lyricsFontScale + 0.15)
            } label: {
                circleIcon("textformat.size.larger")
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
    private func circleIcon(_ symbol: String, tint: Color = .secondary) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
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
