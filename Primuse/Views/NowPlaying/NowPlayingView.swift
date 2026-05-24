import AVKit
import SwiftUI
import Translation
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct NowPlayingView: View {
    var onMinimize: (() -> Void)? = nil
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(PlaybackSettingsStore.self) private var playbackSettings
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL

    /// Apple Music 歌的 catalog URL ── 用来给"在 Apple Music 打开"按钮跳转。
    /// 跳转后用户能看到 Apple Music 自家的歌词 / 添加收藏 / 看艺人页等
    /// 我们没办法对 DRM 流提供的能力。
    private var appleMusicCatalogURL: URL? {
        guard let song = player.currentSong, player.isAppleMusicMode else { return nil }
        return AppServices.shared.appleMusicLibrary.catalogURL(for: song)
    }
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var lyrics: [LyricLine] = []
    @State private var isScrapingCurrentSong = false
    @State private var scrapeAlertMessage: String?
    @State private var showScrapeOptions = false
    @State private var showAddToPlaylist = false
    @State private var showCastPicker = false
    @State private var showSongInfo = false
    @State private var showSleepTimer = false
    @State private var showDeleteConfirm = false
    @State private var showTagEditor = false
    @State private var showSimilarSongs = false
    @Environment(ThemeService.self) private var theme

    // 父持有 @AppStorage 仅为了 onChange 触发 CloudKVS 同步;实际渲染字号由
    // LyricsScrollView 子 view 自己读 AppStorage("lyricsFontScale")。
    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0

    /// Whether the current song is in any playlist (not a dedicated "favorites" concept)
    private var isInAnyPlaylist: Bool {
        guard let songID = player.currentSong?.id else { return false }
        return library.playlists.contains { library.contains(songID: songID, inPlaylist: $0.id) }
    }

    /// 当前歌是否已经被加进「我喜欢」── heart 按钮渲染态 & toggle 目标。
    /// 跟 isInAnyPlaylist 是两回事: "加任意歌单"是 moreMenu 里的 add_to_playlist,
    /// "喜欢"是 heart 按钮 toggle 这个固定 system 歌单。
    private var isCurrentLiked: Bool {
        guard let songID = player.currentSong?.id else { return false }
        return library.isLiked(songID: songID)
    }

    private func toggleLikedCurrent() {
        guard let songID = player.currentSong?.id else { return }
        library.toggleLiked(songID: songID)
    }


    /// Top safe area height (dynamic island / status bar)
    private var topSafeArea: CGFloat {
        #if os(iOS)
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .keyWindow?.safeAreaInsets.top ?? 59
        #else
        // macOS 没有 dynamic island / 状态栏 safe area, 标题栏由窗口 chrome
        // 负责, NowPlayingView 内容直接顶到窗口客户区上沿即可。
        0
        #endif
    }

    /// iPad 横屏(regular size class + 宽 > 高)启用左右双栏 —— 左封面 + 控件,
    /// 右常驻歌词。其它(iPhone / iPad 竖屏 / 分屏小窗 compact)还走原来的
    /// 上下结构,showLyrics 切歌词 / 封面模式。
    private func shouldUseWideLayout(geo: GeometryProxy) -> Bool {
        sizeClass == .regular && geo.size.width > geo.size.height
    }

    var body: some View {
        GeometryReader { geo in
            let artSize = min(geo.size.width - 60, geo.size.height * 0.38)

            ZStack {
                // Opaque base — prevents content bleeding through
                Color.black.ignoresSafeArea()
                // Dynamic background from cover colors — fully opaque
                backgroundGradient.ignoresSafeArea()

                if shouldUseWideLayout(geo: geo) {
                    wideLandscapeLayout(geo: geo)
                } else {
                    portraitLayout(geo: geo, artSize: artSize)
                }
            }
        }
        .task(id: player.currentSong?.id) { await loadLyrics() }
        .sheet(isPresented: $showQueue) {
            QueueView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showScrapeOptions) {
            if let song = player.currentSong {
                ScrapeOptionsView(song: song) { u in
                    CachedArtworkView.invalidateCache(for: u.id)
                    if let oldRef = song.coverArtFileName {
                        CachedArtworkView.invalidateCache(for: oldRef)
                    }
                    Task { await loadLyrics() }
                }
                .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let song = player.currentSong {
                AddToPlaylistSheet(song: song)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showSongInfo) {
            if let song = player.currentSong {
                SongInfoSheet(song: song)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showTagEditor) {
            if let song = player.currentSong {
                TagEditorView(song: song) { updated in
                    // 元数据变更后,封面缓存可能 stale; 同步路径由 PrimuseApp
                    // 监听 songReplacementToken 统一处理 player / theme,
                    // 这里只重拉歌词(标题改了可能影响 LRC 命中)。
                    Task { await loadLyrics() }
                    _ = updated
                }
                .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showSimilarSongs) {
            if let song = player.currentSong {
                SimilarSongsSheet(seed: song)
                    .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $showCastPicker) {
            CastDevicePickerSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(String(localized: "sleep_timer"), isPresented: $showSleepTimer) {
            Button("5 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 5) }
            Button("15 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 15) }
            Button("30 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 30) }
            Button("45 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 45) }
            Button("60 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 60) }
            Button(String(localized: "sleep_at_track_end")) { player.scheduleSleepAtTrackEnd() }
                .disabled(player.currentSong == nil)
            if player.isSleepTimerActive {
                Button(String(localized: "cancel_timer"), role: .destructive) { player.cancelSleep() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .alert(String(localized: "scrape_song"),
               isPresented: Binding(get: { scrapeAlertMessage != nil }, set: { if !$0 { scrapeAlertMessage = nil } })) {
            Button("done", role: .cancel) {}
        } message: { Text(scrapeAlertMessage ?? "") }
        .alert(String(localized: "delete_song"), isPresented: $showDeleteConfirm) {
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "delete"), role: .destructive) {
                deleteCurrentSong()
            }
        } message: {
            Text(String(localized: "delete_song_message"))
        }
        .onChange(of: lyricsFontScale) { _, _ in
            CloudKVSSync.shared.markChanged(key: CloudKVSKey.lyricsFontScale)
        }
        // Handoff —— 用户在当前设备播,旁边的 Mac / iPad 在 Spotlight / 任务
        // 切换器底部出现"在 Primuse 中继续"的 chip。打开后通过 ContentView
        // 的 onContinueUserActivity 拿到完整队列上下文,在另一台设备上无缝接
        // 着播下去 (同一首歌、同样的队列顺序、相同的播放位置、同样的播放/
        // 暂停状态)。
        //
        // 队列截前 50 首是 payload size 安全垫: NSUserActivity userInfo 总
        // 大小 ~128KB,单 song.id (SHA256 hex) 64 字符,50 首 ~3.2KB,余量
        // 充裕。超过的尾部由 receiver 进入队列后,下一首靠 setQueue 内的
        // 自然推进就能继续 ── 主接力点是当前歌 + 接下来几首。
        .userActivity(
            "com.welape.yuanyin.nowplaying",
            isActive: player.currentSong != nil
        ) { activity in
            guard let song = player.currentSong else { return }
            let by = song.artistName.map { " — \($0)" } ?? ""
            activity.title = "\(song.title)\(by)"
            activity.isEligibleForHandoff = true
            // 不把 song.id 暴露给搜索 / 公开索引,handoff 直接拿去就好
            activity.isEligibleForSearch = false
            activity.isEligibleForPublicIndexing = false

            let queueIDs = Array(player.queue.prefix(50).map(\.id))
            activity.userInfo = [
                "songID": song.id,
                "queueIDs": queueIDs,
                // currentTime + snapshotTime 一起记录, receiver 用 (now -
                // snapshot) 推算"如果还在播,实际应该到哪里了",避免接力
                // 时听见同一段刚播过的内容。
                "currentTime": player.currentTime,
                "snapshotTime": Date().timeIntervalSinceReferenceDate,
                "isPlaying": player.isPlaying,
                "shuffleEnabled": player.shuffleEnabled,
                "repeatMode": player.repeatMode.rawValue,
            ]
            activity.requiredUserInfoKeys = ["songID"]
        }
    }

    // MARK: - iPad 横屏 layout (左封面 / 右歌词)
    //
    // 横屏时 showLyrics 状态不参与判断,封面 + 歌词永远并排显示。封面这一侧
    // 复用原 portrait 模式的所有控件子组件(PlaybackProgressBar, ctrlBtn,
    // VolumeSlider, AirPlayButton, moreMenu), 只是改成一个独立 VStack
    // 钉到左半屏。歌词复用 `lyricsFullView`。

    @ViewBuilder
    private func wideLandscapeLayout(geo: GeometryProxy) -> some View {
        let halfWidth = geo.size.width / 2
        // 左侧封面留 80pt 内边距,大小不超过列高 60%。这套尺寸在 iPad Pro
        // 13" 横屏 (1366x1024) 下封面 ~ 580pt,既不显空也不溢出。
        let artSize = min(halfWidth - 80, geo.size.height * 0.6)

        HStack(spacing: 0) {
            wideLeftPane(artSize: artSize)
                .frame(width: halfWidth)

            // 中缝细分隔,半透明白,跟封面阴影协调
            Rectangle()
                .fill(.white.opacity(0.06))
                .frame(width: 1)
                .padding(.vertical, 40)

            wideRightPane()
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func wideLeftPane(artSize: CGFloat) -> some View {
        VStack(spacing: 0) {
            // 顶部 grabber —— 跟 portrait 模式对齐,留出下拉关闭手势的视觉提示
            Capsule()
                .fill(.white.opacity(0.4))
                .frame(width: 48, height: 5)
                .padding(.top, topSafeArea + 6)
                .padding(.bottom, 10)

            if let error = player.lastPlaybackError {
                Text(error)
                    .font(.caption).fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.red.opacity(0.8), in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()

            CachedArtworkView(
                coverRef: player.currentSong?.coverArtFileName,
                songID: player.currentSong?.id ?? "",
                size: artSize, cornerRadius: 16,
                sourceID: player.currentSong?.sourceID,
                filePath: player.currentSong?.filePath,
                revisionToken: player.coverRevision
            )
            .scaleEffect(player.isPlaying ? 1.0 : 0.92)
            .shadow(color: .black.opacity(0.35), radius: 28, y: 12)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)

            Spacer()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(player.currentSong?.title ?? "")
                            .font(.title2).fontWeight(.bold).lineLimit(1)
                            .foregroundStyle(.white)
                        if let song = player.currentSong, song.audioQuality != .standard {
                            AudioQualityBadge(quality: song.audioQuality)
                        }
                    }
                    Text(player.currentSong?.artistName ?? "")
                        .font(.title3).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                Spacer()
                if !player.isAppleMusicMode {
                    Button { showScrapeOptions = true } label: {
                        Image(systemName: isScrapingCurrentSong ? "wand.and.stars.inverse" : "wand.and.stars")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(isScrapingCurrentSong ? 0.4 : 0.6))
                            .symbolEffect(.pulse, options: .repeating, isActive: isScrapingCurrentSong)
                    }
                    .disabled(player.currentSong == nil || isScrapingCurrentSong)
                    .padding(.trailing, 6)
                    .accessibilityLabel(Text("scrape_song"))
                } else if let url = appleMusicCatalogURL {
                    // Apple Music 歌没有刮削概念 ── 给一个跳转按钮, 用户去
                    // Apple Music app 里看官方歌词 / 加收藏 / 查艺人。
                    Button { openURL(url) } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(.trailing, 6)
                    .accessibilityLabel(Text("apple_music_open_in_app"))
                }
                Button { toggleLikedCurrent() } label: {
                    Image(systemName: isCurrentLiked ? "heart.fill" : "heart")
                        .font(.title2)
                        .foregroundStyle(isCurrentLiked ? .red : .white.opacity(0.6))
                        .contentTransition(.symbolEffect(.replace))
                }
                .disabled(player.currentSong == nil)
                .padding(.trailing, 6)
                .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))
                moreMenu
            }
            .padding(.horizontal, 36).padding(.top, 18)

            PlaybackProgressBar()
                .padding(.horizontal, 36).padding(.top, 10)

            HStack(spacing: 0) {
                Spacer()
                ctrlBtn("shuffle", active: player.shuffleEnabled) { player.shuffleEnabled.toggle() }
                Spacer()
                Button { Task { await player.previous() } } label: {
                    Image(systemName: "backward.fill").font(.title).foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)
                .accessibilityLabel("a11y_previous_track")
                Spacer()
                Button { withAnimation(.spring(response: 0.3)) { player.togglePlayPause() } } label: {
                    ZStack {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 60)).opacity(0)
                        if player.isLoading {
                            ProgressView().controlSize(.large).tint(.white)
                        } else {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 60)).foregroundStyle(.white)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                }
                .disabled(player.isLoading)
                .accessibilityLabel(player.isPlaying
                    ? String(localized: "a11y_pause")
                    : String(localized: "a11y_play"))
                Spacer()
                Button { Task { await player.next() } } label: {
                    Image(systemName: "forward.fill").font(.title).foregroundStyle(.white)
                }
                .frame(width: 56, height: 56)
                .accessibilityLabel("a11y_next_track")
                Spacer()
                ctrlBtn(player.repeatMode == .one ? "repeat.1" : "repeat", active: player.repeatMode != .off) {
                    switch player.repeatMode {
                    case .off: player.repeatMode = .all
                    case .all: player.repeatMode = .one
                    case .one: player.repeatMode = .off
                    }
                }
                Spacer()
            }
            .padding(.top, 14)

            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.white.opacity(0.4))
                VolumeSlider(value: Binding(
                    get: { Double(player.audioEngine.volume) },
                    set: { player.audioEngine.volume = Float($0) }
                ))
                Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 36).padding(.top, 12)

            // 底部 bar —— 没有歌词切换按钮(歌词永远在右栏可见),保留 AirPlay
            // 和队列入口
            HStack {
                Spacer()
                AirPlayButton().frame(width: 36, height: 36)
                Spacer()
                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet").foregroundStyle(.white.opacity(0.55))
                }
            }
            .font(.body).padding(.horizontal, 80).padding(.top, 14)

            if let song = player.currentSong {
                HStack(spacing: 4) {
                    Text(song.fileFormat.displayName)
                    if let sr = song.sampleRate { Text("·"); Text("\(sr / 1000)kHz") }
                    if sourcesStore.sources.count > 1,
                       let source = sourcesStore.source(id: song.sourceID) {
                        Text("·")
                        Image(systemName: source.type.iconName)
                        Text(source.name)
                    }
                }
                .font(.caption2).foregroundStyle(.white.opacity(0.3))
                .padding(.top, 6).padding(.bottom, 16)
            } else {
                Spacer().frame(height: 16)
            }
        }
    }

    @ViewBuilder
    private func wideRightPane() -> some View {
        VStack(spacing: 0) {
            // 跟左栏 grabber 顶端对齐
            Spacer().frame(height: topSafeArea + 21)
            lyricsFullView
                .padding(.bottom, 24)
        }
    }

    // MARK: - 原 portrait layout (iPhone + iPad 竖屏 + 分屏小窗)

    @ViewBuilder
    private func portraitLayout(geo: GeometryProxy, artSize: CGFloat) -> some View {
        VStack(spacing: 0) {
                    // Grabber handle (system-matching dimensions)
                    Capsule()
                        .fill(.white.opacity(0.4))
                        .frame(width: 48, height: 5)
                        .padding(.top, topSafeArea + 6)
                        .padding(.bottom, 10)

                    // Playback error toast
                    if let error = player.lastPlaybackError {
                        Text(error)
                            .font(.caption).fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(.red.opacity(0.8), in: Capsule())
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if showLyrics {
                        // LYRICS MODE: compact header at top
                        HStack(spacing: 10) {
                            // Tappable cover + title → switch back to cover mode
                            HStack(spacing: 10) {
                                CachedArtworkView(
                                    coverRef: player.currentSong?.coverArtFileName,
                                    songID: player.currentSong?.id ?? "",
                                    size: 44, cornerRadius: 6,
                                    sourceID: player.currentSong?.sourceID,
                                    filePath: player.currentSong?.filePath,
                                    revisionToken: player.coverRevision
                                )

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(player.currentSong?.title ?? "")
                                        .font(.subheadline).fontWeight(.semibold).lineLimit(1)
                                        .foregroundStyle(.white)
                                    Text(player.currentSong?.artistName ?? "")
                                        .font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.3)) { showLyrics = false } }

                            Spacer()

                            if !player.isAppleMusicMode {
                                Button { showScrapeOptions = true } label: {
                                    Image(systemName: isScrapingCurrentSong ? "wand.and.stars.inverse" : "wand.and.stars")
                                        .font(.title3)
                                        .foregroundStyle(.white.opacity(isScrapingCurrentSong ? 0.4 : 0.6))
                                        .symbolEffect(.pulse, options: .repeating, isActive: isScrapingCurrentSong)
                                }
                                .disabled(player.currentSong == nil || isScrapingCurrentSong)
                                .padding(.trailing, 4)
                                .accessibilityLabel(Text("scrape_song"))
                            } else if let url = appleMusicCatalogURL {
                                Button { openURL(url) } label: {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.title3)
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                                .padding(.trailing, 4)
                                .accessibilityLabel(Text("apple_music_open_in_app"))
                            }

                            Button { toggleLikedCurrent() } label: {
                                Image(systemName: isCurrentLiked ? "heart.fill" : "heart")
                                    .font(.title3)
                                    .foregroundStyle(isCurrentLiked ? .red : .white.opacity(0.6))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .disabled(player.currentSong == nil)
                            .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))

                            // More menu
                            moreMenu
                        }
                        .padding(.horizontal, 20).padding(.bottom, 6)

                        // Full screen lyrics
                        lyricsFullView
                    } else {
                        // PLAYER MODE
                        Spacer()

                        // Artwork
                        CachedArtworkView(
                            coverRef: player.currentSong?.coverArtFileName,
                            songID: player.currentSong?.id ?? "",
                            size: artSize, cornerRadius: 12,
                            sourceID: player.currentSong?.sourceID,
                            filePath: player.currentSong?.filePath,
                            revisionToken: player.coverRevision
                        )
                        .scaleEffect(player.isPlaying ? 1.0 : 0.9)
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.3)) { showLyrics = true } }

                        Spacer()
                    }

                    // Song info (player mode only — in lyrics mode it's in the top bar)
                    if !showLyrics {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(player.currentSong?.title ?? "")
                                    .font(.title3).fontWeight(.bold).lineLimit(1)
                                    .foregroundStyle(.white)
                                Text(player.currentSong?.artistName ?? "")
                                    .font(.body).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                            }
                            Spacer()

                            // Scrape button (主屏抽出, 不再藏在 ··· 菜单里)
                            if !player.isAppleMusicMode {
                                Button { showScrapeOptions = true } label: {
                                    Image(systemName: isScrapingCurrentSong ? "wand.and.stars.inverse" : "wand.and.stars")
                                        .font(.title2)
                                        .foregroundStyle(.white.opacity(isScrapingCurrentSong ? 0.4 : 0.6))
                                        .symbolEffect(.pulse, options: .repeating, isActive: isScrapingCurrentSong)
                                }
                                .disabled(player.currentSong == nil || isScrapingCurrentSong)
                                .padding(.trailing, 6)
                                .accessibilityLabel(Text("scrape_song"))
                            } else if let url = appleMusicCatalogURL {
                                Button { openURL(url) } label: {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.title2)
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                                .padding(.trailing, 6)
                                .accessibilityLabel(Text("apple_music_open_in_app"))
                            }

                            // Like button
                            Button { toggleLikedCurrent() } label: {
                                Image(systemName: isCurrentLiked ? "heart.fill" : "heart")
                                    .font(.title2)
                                    .foregroundStyle(isCurrentLiked ? .red : .white.opacity(0.6))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .disabled(player.currentSong == nil)
                            .padding(.trailing, 4)
                            .accessibilityLabel(Text(isCurrentLiked ? "a11y_unlike" : "a11y_like"))

                            // More menu
                            moreMenu
                        }
                        .padding(.horizontal, 26).padding(.top, 12)
                    }

                    // Progress — 抽成独立子 view 隔离 player.currentTime 的高频
                    // 重算,避免触发父 body re-render(进而让 toolbar Menu 的 submenu
                    // 被强制关闭)。SwiftUI Observation 是 per-body 追踪——子 view
                    // 自己读 player.currentTime,父 view body 完全不读高频属性。
                    PlaybackProgressBar()
                        .padding(.horizontal, 26).padding(.top, 8)

                    // Controls
                    HStack(spacing: 0) {
                        Spacer()
                        ctrlBtn("shuffle", active: player.shuffleEnabled) { player.shuffleEnabled.toggle() }
                        Spacer()
                        Button { Task { await player.previous() } } label: {
                            Image(systemName: "backward.fill").font(.title).foregroundStyle(.white)
                        }
                        .frame(width: 56, height: 56)
                        .accessibilityLabel("a11y_previous_track")
                        Spacer()
                        Button { withAnimation(.spring(response: 0.3)) { player.togglePlayPause() } } label: {
                            ZStack {
                                // Anchor sizing so the button doesn't reflow.
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 56)).opacity(0)
                                if player.isLoading {
                                    ProgressView()
                                        .controlSize(.large)
                                        .tint(.white)
                                } else {
                                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 56)).foregroundStyle(.white)
                                        .contentTransition(.symbolEffect(.replace))
                                }
                            }
                        }
                        .disabled(player.isLoading)
                        .accessibilityLabel(player.isPlaying
                            ? String(localized: "a11y_pause")
                            : String(localized: "a11y_play"))
                        Spacer()
                        Button { Task { await player.next() } } label: {
                            Image(systemName: "forward.fill").font(.title).foregroundStyle(.white)
                        }
                        .frame(width: 56, height: 56)
                        .accessibilityLabel("a11y_next_track")
                        Spacer()
                        ctrlBtn(player.repeatMode == .one ? "repeat.1" : "repeat", active: player.repeatMode != .off) {
                            switch player.repeatMode {
                            case .off: player.repeatMode = .all
                            case .all: player.repeatMode = .one
                            case .one: player.repeatMode = .off
                            }
                        }
                        Spacer()
                    }
                    .padding(.top, 12)

                    // Volume
                    HStack(spacing: 8) {
                        Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.white.opacity(0.4))
                        VolumeSlider(value: Binding(
                            get: { Double(player.audioEngine.volume) },
                            set: { player.audioEngine.volume = Float($0) }
                        ))
                        Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 26).padding(.top, 10)

                    // Bottom bar
                    HStack {
                        Button { withAnimation(.easeInOut(duration: 0.3)) { showLyrics.toggle() } } label: {
                            Image(systemName: showLyrics ? "text.quote" : "quote.bubble")
                                .foregroundStyle(showLyrics ? .white : .white.opacity(0.5))
                        }
                        Spacer()
                        AirPlayButton().frame(width: 36, height: 36)
                        Spacer()
                        Button { showQueue = true } label: {
                            Image(systemName: "list.bullet").foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .font(.body).padding(.horizontal, 46).padding(.top, 12)

                    // Format & source
                    if let song = player.currentSong {
                        HStack(spacing: 4) {
                            Text(song.fileFormat.displayName)
                            if let sr = song.sampleRate { Text("·"); Text("\(sr / 1000)kHz") }
                            if sourcesStore.sources.count > 1,
                               let source = sourcesStore.source(id: song.sourceID) {
                                Text("·")
                                Image(systemName: source.type.iconName)
                                Text(source.name)
                            }
                        }
                        .font(.caption2).foregroundStyle(.white.opacity(0.3)).padding(.top, 4).padding(.bottom, 6)
                    }
                }
    }

    private func deleteCurrentSong() {
        guard let song = player.currentSong else { return }
        Task {
            // Skip to next before deleting
            await player.next()
            let retainedSongs = library.songs.filter { $0.id != song.id }
            let deleteSidecars = sourceManager.shouldDeleteSidecars(for: song, retaining: retainedSongs)
            _ = await sourceManager.deleteSourceFilesAndCaches(for: song, deleteSidecars: deleteSidecars)
            // Remove from library and keep the source badge in sync.
            let remaining = library.deleteSong(song)
            sourcesStore.updateLocal(song.sourceID) { $0.songCount = remaining }
        }
    }

    // MARK: - More Menu

    private var moreMenu: some View {
        Menu {
            // 收藏 / 编辑当前歌曲
            Section {
                Button { showAddToPlaylist = true } label: {
                    Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
                }
                .disabled(player.currentSong == nil)

                Button { showSimilarSongs = true } label: {
                    Label(String(localized: "similar_songs"), systemImage: "sparkles")
                }
                .disabled(player.currentSong == nil)

                if !player.isAppleMusicMode {
                    Button { showTagEditor = true } label: {
                        Label(String(localized: "tag_editor_menu"), systemImage: "tag")
                    }
                    .disabled(player.currentSong == nil)
                }
            }

            // 信息 / 分享
            Section {
                Button { showSongInfo = true } label: {
                    Label(String(localized: "song_info"), systemImage: "info.circle")
                }
                .disabled(player.currentSong == nil)

                if let song = player.currentSong {
                    ShareLink(item: "\(song.title) - \(song.artistName ?? "")") {
                        Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                    }
                }
            }

            // 投屏 ── Apple Music DRM 流没法 push, 自动 disable; 当前在投屏时
            // menu 文案变成 "停止投屏" + 显示目标设备名。
            Section {
                Button { showCastPicker = true } label: {
                    if let renderer = player.castingRenderer {
                        Label(String(format: String(localized: "cast_casting_to_format"),
                                     renderer.friendlyName),
                              systemImage: "airplayaudio")
                    } else {
                        Label(String(localized: "cast_to_device"), systemImage: "airplayaudio")
                    }
                }
                .disabled(player.currentSong == nil || player.isAppleMusicMode)
            }

            // 阅读偏好（仅歌词模式可见）—— Picker(.menu) submenu 形式
            if showLyrics {
                Section {
                    Picker(selection: $lyricsFontScale) {
                        Text("lyrics_font_small").tag(0.85)
                        Text("lyrics_font_medium").tag(1.0)
                        Text("lyrics_font_large").tag(1.2)
                        Text("lyrics_font_xlarge").tag(1.5)
                    } label: {
                        Label(String(localized: "lyrics_font_size"), systemImage: "textformat.size")
                    }
                    .pickerStyle(.menu)

                    // 翻译快捷开关 ── 听歌时不用绕回设置, 直接 toggle。
                    // didSet 会触发 lyricsTranslationSettingsChanged 通知,
                    // TranslationView 监听到会重新启动翻译 / 清空翻译数据。
                    Button {
                        LyricsTranslationSettingsStore.shared.isEnabled.toggle()
                    } label: {
                        Label(
                            LyricsTranslationSettingsStore.shared.isEnabled
                                ? String(localized: "lyrics_translation_off")
                                : String(localized: "lyrics_translation_on"),
                            systemImage: LyricsTranslationSettingsStore.shared.isEnabled
                                ? "character.bubble.fill"
                                : "character.bubble"
                        )
                    }
                }
            }

            // 播放控制
            Section {
                Button { showSleepTimer = true } label: {
                    Label(
                        player.isSleepTimerActive ? String(localized: "sleep_timer_active") : String(localized: "sleep_timer"),
                        systemImage: player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz"
                    )
                }

                // 播放速度子菜单 — AVAudioUnitTimePitch 改 rate 即时生效,
                // 不需要重启 engine 或重 schedule buffer。1.0 是 passthrough。
                // ApplicationMusicPlayer 不支持改速度, Apple Music 模式 hide。
                if !player.isAppleMusicMode {
                    Picker(selection: Binding(
                        get: { playbackSettings.playbackRate },
                        set: { playbackSettings.playbackRate = $0 }
                    )) {
                        Text("0.5×").tag(Float(0.5))
                        Text("0.75×").tag(Float(0.75))
                        Text(String(localized: "playback_rate_normal")).tag(Float(1.0))
                        Text("1.25×").tag(Float(1.25))
                        Text("1.5×").tag(Float(1.5))
                        Text("1.75×").tag(Float(1.75))
                        Text("2.0×").tag(Float(2.0))
                    } label: {
                        Label(
                            playbackSettings.playbackRate == 1.0
                                ? String(localized: "playback_rate")
                                : String(format: "%@ %.2fx", String(localized: "playback_rate"), playbackSettings.playbackRate),
                            systemImage: "speedometer"
                        )
                    }
                    .pickerStyle(.menu)
                }
            }

            // 销毁 ── Apple Music 歌不能从猿音删 (要去 Apple Music 取消收藏)
            if !player.isAppleMusicMode {
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(String(localized: "delete_song"), systemImage: "trash")
                    }
                    .disabled(player.currentSong == nil)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.title).symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    // MARK: - Background gradient from cover dominant color

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                theme.darkAccent,
                gradientMidColor,
                .black
            ],
            startPoint: .top, endPoint: .bottom
        )
        .animation(.easeInOut(duration: 0.5), value: theme.colorID)
    }

    private var gradientMidColor: Color {
        if #available(iOS 18.0, *) {
            theme.darkAccent.mix(with: .black, by: 0.4)
        } else {
            theme.darkAccent.opacity(0.65)
        }
    }

    // MARK: - Full Lyrics

    private var lyricsFullView: some View {
        LyricsScrollView(
            lyrics: lyrics,
            player: player,
            songID: player.currentSong?.id,
            isScrapingCurrentSong: isScrapingCurrentSong,
            onScrape: { Task { await scrapeCurrentSong() } }
        )
    }

    // MARK: - Helpers

    private func ctrlBtn(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body)
                .foregroundStyle(active ? .white : .white.opacity(0.4))
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(Self.iconA11yLabel(icon))
        .accessibilityValue(active
            ? String(localized: "a11y_value_on")
            : String(localized: "a11y_value_off"))
    }

    /// SF Symbol -> VoiceOver 标签的映射, 用在 transport 控件上。
    private static func iconA11yLabel(_ icon: String) -> LocalizedStringKey {
        switch icon {
        case "shuffle": return "a11y_shuffle"
        case "repeat", "repeat.1": return "a11y_repeat"
        default: return "a11y_button_generic"
        }
    }

    private func loadLyrics() async {
        guard let song = player.currentSong else { setLyrics([]); return }
        let loadStart = Date()

        // Apple Music 走 MusicKit 原生 catalog 歌词, 不经刮削链路。先查
        // MetadataAssetStore songID cache 命中直接显示 (cache 一份避免每次切
        // 歌都走 catalog 网络); miss 再问 MusicKit, 拿到 TTML 解析后写回 cache。
        // 全失败 → setLyrics([]) 让 emptyLyricsView 显示"在 Apple Music 中查
        // 看歌词"按钮 fallback。
        if song.sourceID == AppleMusicLibraryService.systemSourceID {
            if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id),
               !cached.isEmpty {
                plog(String(format: "📜 Apple Music lyrics cache hit '%@' (%d lines)",
                            song.title, cached.count))
                setLyrics(cached)
                return
            }
            do {
                if let lyrics = try await AppServices.shared.appleMusicLibrary
                    .fetchLyrics(forAmID: song.filePath),
                   !lyrics.isEmpty {
                    _ = await MetadataAssetStore.shared.cacheLyrics(lyrics, forSongID: song.id, force: true)
                    plog(String(format: "📜 Apple Music lyrics fetched '%@' in %.0fms (%d lines)",
                                song.title, Date().timeIntervalSince(loadStart) * 1000, lyrics.count))
                    setLyrics(lyrics)
                    return
                } else {
                    plog("📜 Apple Music lyrics: no official lyrics for '\(song.title)'")
                }
            } catch {
                plog("⚠️Apple Music lyrics fetch failed for '\(song.title)': \(error.localizedDescription)")
            }
            setLyrics([])
            return
        }

        // Tier 1a: songID hash cache —— 即使 NAS path 也读 (stale-while-revalidate)。
        // 历史污染 cache 现在通过 trustedSource:false + sidecar 写后回写 cache
        // 在根源上修复, 这里允许 cache hit 立即显示, 后台再校验。
        if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id), !cached.isEmpty {
            plog(String(format: "📜 loadLyrics '%@' Tier1a hit (songID hash) in %.0fms (%d lines)", song.title, Date().timeIntervalSince(loadStart) * 1000, cached.count))
            setLyrics(cached)
            // NAS path 时, 后台校验 cache 是否 stale (NAS sidecar 才是真相)。
            // 静默成功 = no-op; 若发现差异会 update UI + cache。
            if (song.lyricsFileName ?? "").contains("/") {
                runLyricsTier3Fetch(song: song, currentCache: cached)
            }
            return
        }

        let lyricsRefIsRemote = (song.lyricsFileName ?? "").contains("/")

        // Tier 1b: legacy named ref (only for non-NAS path)
        if !lyricsRefIsRemote,
           let cached = await MetadataAssetStore.shared.lyrics(named: song.lyricsFileName) {
            await MetadataAssetStore.shared.cacheLyrics(cached, forSongID: song.id)
            plog(String(format: "📜 loadLyrics '%@' Tier1b hit (named ref) in %.0fms (%d lines)", song.title, Date().timeIntervalSince(loadStart) * 1000, cached.count))
            setLyrics(cached); return
        }

        // Tier 2: Check local audio cache for sidecar .lrc (filesystem only, zero network)
        if let cachedAudioURL = sourceManager.cachedURL(for: song),
           let lrcURL = SidecarMetadataLoader.findLyrics(for: cachedAudioURL),
           let parsed = try? LyricsParser.parse(from: lrcURL), !parsed.isEmpty {
            await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: song.id)
            plog(String(format: "📜 loadLyrics '%@' Tier2 hit (audio cache sidecar) in %.0fms (%d lines)", song.title, Date().timeIntervalSince(loadStart) * 1000, parsed.count))
            setLyrics(parsed); return
        }

        // Tier 3: 首次必走 (无 cache, 无本地 sidecar)
        setLyrics([])
        plog(String(format: "📜 loadLyrics '%@' miss Tier1+2, falling to Tier3 (NAS fetch)", song.title))
        runLyricsTier3Fetch(song: song, currentCache: nil)
    }

    /// Tier 3 NAS fetch + 校验。currentCache != nil 时为 stale-while-revalidate
    /// 模式: 已 setLyrics(currentCache), 这里只在 fingerprint 不一致时 update UI。
    private func runLyricsTier3Fetch(song: Song, currentCache: [LyricLine]?) {
        let capturedSourceManager = sourceManager
        let songID = song.id
        let songTitle = song.title
        let isRefresh = currentCache != nil

        Task {
            let tier3Start = Date()
            do {
                let connector = try await capturedSourceManager.auxiliaryConnector(for: song)
                let connectMs = Date().timeIntervalSince(tier3Start) * 1000
                let songDir = (song.filePath as NSString).deletingLastPathComponent
                let baseName = ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
                let lrcPath: String
                if let ref = song.lyricsFileName, ref.contains("/") {
                    lrcPath = ref
                } else {
                    lrcPath = (songDir as NSString).appendingPathComponent("\(baseName).lrc")
                }

                let fetchStart = Date()
                let lrcData = try await connector.fetchRange(path: lrcPath, offset: 0, length: 256 * 1024)
                let fetchMs = Date().timeIntervalSince(fetchStart) * 1000
                guard let lrcContent = String(data: lrcData, encoding: .utf8) else {
                    plog(String(format: "📜 loadLyrics '%@' Tier3 .lrc not utf8 (connect=%.0fms fetch=%.0fms)", songTitle, connectMs, fetchMs))
                    return
                }
                let parsed = LyricsParser.parse(lrcContent)
                guard !parsed.isEmpty else {
                    plog(String(format: "📜 loadLyrics '%@' Tier3 .lrc empty after parse (connect=%.0fms fetch=%.0fms %dB)", songTitle, connectMs, fetchMs, lrcData.count))
                    return
                }

                // Refresh 模式: cache 与 NAS 一致就静默退出, 不写盘不 update UI
                if let currentCache,
                   Self.lyricsFingerprint(parsed) == Self.lyricsFingerprint(currentCache) {
                    plog(String(format: "📜 lyrics refresh '%@' cache fresh, no update (%.0fms)", songTitle, Date().timeIntervalSince(tier3Start) * 1000))
                    return
                }

                let wrote = await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: songID)
                if !wrote {
                    // 写入被「不降级」拦截 (现存字级, NAS 是行级 sidecar 自动
                    // 写回的) —— UI 保持原 cache 显示, 不切到行级。
                    plog(String(format: "📜 lyrics refresh '%@' SKIP downgrade (%.0fms, cache word-level kept)", songTitle, Date().timeIntervalSince(tier3Start) * 1000))
                    return
                }
                if isRefresh {
                    plog(String(format: "📜 lyrics refresh '%@' cache STALE → updated (%.0fms, %d→%d lines)", songTitle, Date().timeIntervalSince(tier3Start) * 1000, currentCache?.count ?? 0, parsed.count))
                } else {
                    plog(String(format: "📜 loadLyrics '%@' Tier3 OK in %.0fms (connect=%.0fms fetch=%.0fms %dB %d lines)", songTitle, Date().timeIntervalSince(tier3Start) * 1000, connectMs, fetchMs, lrcData.count, parsed.count))
                }
                if player.currentSong?.id == songID {
                    setLyrics(parsed)
                }
            } catch {
                if isRefresh {
                    // refresh 失败不影响 user, 已经显示了 cache
                    plog(String(format: "📜 lyrics refresh '%@' FAILED in %.0fms (cache still shown): %@", songTitle, Date().timeIntervalSince(tier3Start) * 1000, error.localizedDescription))
                } else {
                    plog(String(format: "📜 loadLyrics '%@' Tier3 FAILED in %.0fms: %@", songTitle, Date().timeIntervalSince(tier3Start) * 1000, error.localizedDescription))
                }
            }
        }
    }

    /// Lyrics 内容 fingerprint, 用于 stale-while-revalidate 比较。
    /// LyricLine.id 是 UUID() 每次 parse 不同, 不能直接 ==。这里取
    /// 行数 + 首尾 timestamp + 首尾 text, 足够区分内容差异。
    private static func lyricsFingerprint(_ lines: [LyricLine]) -> String {
        guard let first = lines.first, let last = lines.last else { return "empty" }
        return "\(lines.count)|\(first.timestamp)|\(first.text)|\(last.timestamp)|\(last.text)"
    }

    private func setLyrics(_ value: [LyricLine]) {
        lyrics = value
        let wordLevelCount = value.filter { $0.isWordLevel }.count
        plog("📜 setLyrics: lines=\(value.count) wordLevelLines=\(wordLevelCount) firstSyllables=\(value.first?.syllables?.count ?? -1)")
        // currentLineIndex / hasWordLevelLyrics 已迁移到 LyricsScrollView 子 view,
        // 子 view 自己 onChange(of: songID) 重置 + computed property 算 hasWord。
        consumePendingLyricsJump(from: value)
    }

    /// 搜索页点歌词命中结果时, player 上挂了一个 pending hint。歌词刚加载
    /// 完就在这里 fuzzy match 找对应行的 timestamp 并 seek。命中即清, 一次性。
    /// songID 必须匹配当前 currentSong, 避免用户快速切歌时 jump 到别首。
    private func consumePendingLyricsJump(from lines: [LyricLine]) {
        guard let hint = player.pendingLyricsJump,
              let currentID = player.currentSong?.id,
              hint.songID == currentID,
              !lines.isEmpty else { return }
        // snippet 可能包含上下文行 ("...prev\nmatch\nnext..."), 提取最长一行做匹配。
        let needle = hint.snippet
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            .max(by: { $0.count < $1.count }) ?? hint.snippet
        guard !needle.isEmpty else { player.clearPendingLyricsJump(); return }
        if let match = lines.first(where: { $0.text.localizedCaseInsensitiveContains(needle) }) {
            player.seek(to: max(0, match.timestamp - 0.3))
            // 用户来这是为了看歌词上下文, 默认切到歌词面板
            withAnimation(.easeInOut(duration: 0.3)) { showLyrics = true }
        }
        player.clearPendingLyricsJump()
    }



    private func scrapeCurrentSong() async {
        guard let song = player.currentSong else { return }
        isScrapingCurrentSong = true; defer { isScrapingCurrentSong = false }
        do {
            let (u, _, _) = try await scraperService.scrapeSingle(song: song, in: library)
            CachedArtworkView.invalidateCache(for: u.id)
            if let oldRef = song.coverArtFileName { CachedArtworkView.invalidateCache(for: oldRef) }
            player.syncSongMetadata(u); player.forceRefreshNowPlayingArtwork(); await loadLyrics()
            if !lyrics.isEmpty { showLyrics = true }
            scrapeAlertMessage = String(localized: "scrape_song_success")
        } catch { scrapeAlertMessage = String(localized: "scrape_song_failed") }
    }

    private func fmt(_ t: TimeInterval) -> String {
        t.formattedDuration
    }
}

// MARK: - Custom Progress Slider (thin, no thumb)

struct ProgressSlider: View {
    let value: TimeInterval
    let total: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var isDragging = false
    @State private var dragValue: TimeInterval?

    private var safeTotal: TimeInterval { total.sanitizedDuration }
    private var displayValue: TimeInterval { (dragValue ?? value).sanitizedDuration }
    private var progress: CGFloat {
        guard safeTotal > 0 else { return 0 }
        let fraction = displayValue / safeTotal
        guard fraction.isFinite else { return 0 }
        return CGFloat(max(0, min(1, fraction)))
    }

    private func seekValue(for locationX: CGFloat, width: CGFloat) -> TimeInterval? {
        guard width > 0, safeTotal > 0 else { return nil }
        let fraction = locationX / width
        guard fraction.isFinite else { return nil }
        return Double(max(0, min(1, fraction))) * safeTotal
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackHeight: CGFloat = isDragging ? 8 : 5

            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(height: trackHeight)

                // Filled track
                Capsule()
                    .fill(.white)
                    .frame(width: max(0, min(width, width * progress)), height: trackHeight)
            }
            .frame(height: 20) // tap area
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        dragValue = seekValue(for: gesture.location.x, width: width)
                    }
                    .onEnded { gesture in
                        if let seekTime = seekValue(for: gesture.location.x, width: width) {
                            onSeek(seekTime)
                        }
                        dragValue = nil
                        withAnimation(.easeOut(duration: 0.2)) { isDragging = false }
                    }
            )
            .animation(.easeInOut(duration: 0.15), value: isDragging)
        }
        .frame(height: 20)
    }
}

// MARK: - Volume Slider (thin, matching ProgressSlider style)

struct VolumeSlider: View {
    @Binding var value: Double

    @State private var isDragging = false
    @State private var localValue: Double?

    private var displayValue: Double { localValue ?? value }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = CGFloat(max(0, min(1, displayValue)))
            let trackHeight: CGFloat = isDragging ? 8 : 5

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(.white)
                    .frame(width: max(0, min(width, width * progress)), height: trackHeight)
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        isDragging = true
                        localValue = Double(max(0, min(1, gesture.location.x / width)))
                        value = localValue!
                    }
                    .onEnded { _ in
                        localValue = nil
                        withAnimation(.easeOut(duration: 0.2)) { isDragging = false }
                    }
            )
            .animation(.easeInOut(duration: 0.15), value: isDragging)
        }
        .frame(height: 20)
    }
}

// MARK: - Song Info Sheet

struct SongInfoSheet: View {
    let song: Song
    @Environment(\.dismiss) private var dismiss
    @Environment(SourcesStore.self) private var sourcesStore
    @State private var showSimilarSongs = false

    var body: some View {
        NavigationStack {
            List {
                infoRow(String(localized: "title_label"), song.title)
                if let artist = song.artistName { infoRow(String(localized: "artist_label"), artist) }
                if let album = song.albumTitle { infoRow(String(localized: "album_label"), album) }
                if let genre = song.genre { infoRow(String(localized: "genre_label"), genre) }
                if let year = song.year { infoRow(String(localized: "year_label"), "\(year)") }
                if let track = song.trackNumber { infoRow(String(localized: "track_label"), "\(track)") }

                Section(String(localized: "technical_info")) {
                    infoRow(String(localized: "format_label"), song.fileFormat.displayName)
                    if let sr = song.sampleRate {
                        infoRow(String(localized: "sample_rate_label"), "\(sr) Hz")
                    }
                    if let bits = song.bitDepth {
                        infoRow(String(localized: "bit_depth_label"), "\(bits) bit")
                    }
                    infoRow(String(localized: "duration_label"), formatDuration(song.duration))
                    if let source = sourcesStore.source(id: song.sourceID) {
                        infoRow(String(localized: "source_label"), source.name)
                    }
                }

                Section {
                    Button {
                        showSimilarSongs = true
                    } label: {
                        Label(String(localized: "similar_songs"), systemImage: "sparkles")
                    }
                }
            }
            .navigationTitle(String(localized: "song_info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showSimilarSongs) {
                SimilarSongsSheet(seed: song)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        t.formattedDuration
    }
}

// MARK: - Add to Playlist Sheet

struct AddToPlaylistSheet: View {
    let song: Song
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var showNewPlaylist = false
    @State private var newPlaylistName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showNewPlaylist = true
                    } label: {
                        Label(String(localized: "new_playlist"), systemImage: "plus.circle.fill")
                    }
                }

                Section(String(localized: "playlists_title")) {
                    if library.playlists.isEmpty {
                        ContentUnavailableView {
                            Label(String(localized: "no_playlists"), systemImage: "music.note.list")
                        }
                    } else {
                        ForEach(library.playlists) { playlist in
                            playlistRow(playlist: playlist)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "add_to_playlist"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .alert(String(localized: "new_playlist"), isPresented: $showNewPlaylist) {
                TextField(String(localized: "playlist_name"), text: $newPlaylistName)
                Button(String(localized: "cancel"), role: .cancel) { newPlaylistName = "" }
                Button(String(localized: "create")) {
                    guard !newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    let pl = library.createPlaylist(name: newPlaylistName)
                    library.add(songID: song.id, toPlaylist: pl.id)
                    newPlaylistName = ""
                }
            }
        }
    }

    @ViewBuilder
    private func playlistRow(playlist: Playlist) -> some View {
        let isAdded = library.contains(songID: song.id, inPlaylist: playlist.id)
        Button {
            if isAdded {
                library.remove(songID: song.id, fromPlaylist: playlist.id)
            } else {
                library.add(songID: song.id, toPlaylist: playlist.id)
            }
        } label: {
            HStack {
                StoredCoverArtView(fileName: playlist.coverArtPath, size: 40, cornerRadius: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.body)
                    let count = library.songs(forPlaylist: playlist.id).count
                    Text("\(count) \(String(localized: "songs_count"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isAdded ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isAdded ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

#if os(iOS)
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor.white.withAlphaComponent(0.5)
        v.activeTintColor = .white
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#else
/// macOS 上 AVRoutePickerView 是 NSView, tint / activeTint API 也不一样。
/// 但 NowPlayingView 的 iOS 全屏播放器 (含 AirPlay 按钮) 在 macOS 上不会出现
/// (Mac 用 MacNowPlayingView), 这里给一个能编译的占位空视图, 避免 import
/// 链断开。真用到再走 AVRoutePickerView (NSView) 适配。
struct AirPlayButton: View {
    var body: some View { Color.clear.frame(width: 44, height: 44) }
}
#endif

// MARK: - LyricsScrollView (隔离的歌词渲染子 view)

/// 把歌词渲染抽出来作为独立 View,避免行切换 (`currentLineIndex` 变化) 让
/// 整个 NowPlayingView 的 body 重算,从而触发 SwiftUI Menu 内嵌的 Picker(.menu)
/// submenu 在父重算时被强制关闭(选字号弹框还没来得及选就消失)。
///
/// 通过把 currentLineIndex 等内部状态封装在子 view 里,行切换只让本 view 重算,
/// 父 view 的 Menu / sheet 不受影响。
struct LyricsScrollView: View {
    let lyrics: [LyricLine]
    let player: AudioPlayerService
    let songID: String?
    let isScrapingCurrentSong: Bool
    let onScrape: () -> Void

    @Environment(\.openURL) private var openURL
    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0
    @State private var lyricsPinchScale: CGFloat = 1.0
    @State private var isPinchingLyrics = false
    @State private var currentLineIndex = 0
    @State private var wordLineFrames: [String: CGRect] = [:]

    // 用户手动拖动歌词时, 暂时冻结自动滚动 ── 否则刚拖到想看的位置, 下一帧
    // auto follow 又把视图拽回当前行, 等于不能浏览。lastUserScrollTime 静止
    // 超过 manualScrollGracePeriod 后恢复 auto follow。
    @State private var lastUserScrollTime: Date = .distantPast
    /// 字级模式下, 用户手动拖出的偏移。nil 表示当前由 auto follow 接管。
    @State private var manualWordOffset: CGFloat? = nil
    /// 拖动 session 开始时的偏移基准 (用于把 translation.height 累加上去)。
    @State private var wordDragStartOffset: CGFloat = 0
    /// 最近一次 auto follow 计算出的偏移 ── 当用户开始拖动时作为起点, 避免
    /// 起手就跳。
    @State private var lastAutoWordOffset: CGFloat = 0
    private static let manualScrollGracePeriod: TimeInterval = 3.0

    // Translation —— system translation framework
    // 离线 + 免费, 翻译结果走 LyricsTranslationCache 持久化, 切歌时按当前
    // 启用状态触发批量翻译。
    @State private var translatedTextByLineID: [String: String] = [:]
    @State private var translationSettings = LyricsTranslationSettingsStore.shared

    private static let lyricsMinScale: Double = 0.7
    private static let lyricsMaxScale: Double = 1.8
    private static let lyricsActiveBaseSize: CGFloat = 28
    private static let lyricsInactiveBaseSize: CGFloat = 22
    private static let lyricsWordLevelBaseSize: CGFloat = 26

    private var effectiveLyricsScale: Double {
        let combined = lyricsFontScale * Double(lyricsPinchScale)
        return min(max(combined, Self.lyricsMinScale), Self.lyricsMaxScale)
    }

    private var hasWordLevelLyrics: Bool {
        lyrics.contains { $0.isWordLevel }
    }

    var body: some View {
        Group {
            if lyrics.isEmpty {
                emptyLyricsView
            } else if hasWordLevelLyrics {
                smoothWordLyricsView
            } else {
                lineLevelLyricsView
            }
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            updateCurrentLine()
        }
        .onChange(of: songID) { _, _ in
            // 切歌时把行索引清零 + 让自动滚动重新 anchor
            currentLineIndex = 0
            wordLineFrames = [:]
        }
        .lyricsTranslationTaskIfAvailable(
            songID: songID,
            lyrics: lyrics,
            settings: translationSettings,
            translatedTextByLineID: $translatedTextByLineID
        )
    }

    private var emptyLyricsView: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 60)
            if player.isAppleMusicMode {
                // Apple Music DRM 歌词没有公开 API 拉给第三方 app, 我们做不了
                // 本地刮削。引导用户去 Apple Music app 看官方歌词。
                Text("apple_music_lyrics_not_available")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                if let song = player.currentSong,
                   let url = AppServices.shared.appleMusicLibrary.catalogURL(for: song) {
                    Button { openURL(url) } label: {
                        Label("apple_music_view_lyrics", systemImage: "applelogo")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered).tint(.white)
                }
            } else {
                Text("no_lyrics").font(.title3).foregroundStyle(.white.opacity(0.3))
                Button { onScrape() } label: {
                    Label("scrape_song", systemImage: "wand.and.stars").font(.subheadline)
                }
                .buttonStyle(.bordered).tint(.white)
                .disabled(isScrapingCurrentSong)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var lineLevelLyricsView: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Spacer().frame(height: 20)

                    ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                        lyricsRow(line: line, index: index)
                            .id(line.id)
                            .onTapGesture { player.seek(to: line.timestamp) }
                            .padding(.vertical, 2)
                    }

                    Spacer().frame(height: 80)
                }
                .padding(.horizontal, 24)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        isPinchingLyrics = true
                        lyricsPinchScale = value.magnification
                    }
                    .onEnded { value in
                        let next = lyricsFontScale * Double(value.magnification)
                        lyricsFontScale = min(max(next, Self.lyricsMinScale), Self.lyricsMaxScale)
                        lyricsPinchScale = 1.0
                        isPinchingLyrics = false
                    }
            )
            // 监听任意拖动手势 → 刷新 lastUserScrollTime, 让 onChange 里的 auto
                // scrollTo 暂时退让, 用户能往上往下浏览其他歌词。
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in lastUserScrollTime = Date() }
                    .onEnded { _ in lastUserScrollTime = Date() }
            )
            .onChange(of: currentLineIndex) { _, idx in
                guard !isPinchingLyrics, idx < lyrics.count else { return }
                // 用户手动滚动后 manualScrollGracePeriod 内不要把视图拽回当前行,
                // 否则刚拖到想看的位置又被自动 scrollTo 弹回, 等同不能浏览。
                guard Date().timeIntervalSince(lastUserScrollTime) >= Self.manualScrollGracePeriod
                else { return }
                withAnimation(.smooth(duration: 0.34, extraBounce: 0)) {
                    proxy.scrollTo(lyrics[idx].id, anchor: .center)
                }
            }
        }
    }

    private var smoothWordLyricsView: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { ctx in
                let now = player.interpolatedTime(at: ctx.date)
                let autoOffset = smoothWordContentOffset(at: now, viewportHeight: geo.size.height)
                // 用户手动拖动接管期 (lastUserScrollTime + grace 内): 用 manualWordOffset;
                // 静止超过 grace 后清掉手动状态, 平滑回到 auto follow。
                // resolveWordOffset 还会把最新 autoOffset 缓存进 lastAutoWordOffset
                // 供 DragGesture 起手取用。
                let displayOffset = resolveWordOffset(autoOffset: autoOffset)

                VStack(alignment: .leading, spacing: 12) {
                    Spacer().frame(height: 20)

                    wordLevelBadge

                    ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                        // 字级模式: row 整体明暗 / 缩放都用基于 now 的连续函数接管,
                        // 内部 foregroundStyle 全用 .white 实色 (dimmedByAmbient=true)。
                        // - opacity:  active 行 1.0, 远行 0.4 / 0.25; 用 wordLevelScrollLead /
                        //             Duration 同步窗口, 跟滚动一气呵成。
                        // - scale:    active 行 1.06, 渐进过渡 ── 给"近大远小"的纵深感。
                        let activity = rowVisualActivity(at: now, index: index)
                        lyricsRow(line: line, index: index, dimmedByAmbient: true)
                            .id(line.id)
                            .opacity(activity.opacity)
                            .scaleEffect(activity.scale, anchor: line.voice == .secondary ? .trailing : .leading)
                            .onTapGesture { player.seek(to: line.timestamp) }
                            .padding(.vertical, 2)
                            .background(rowFrameReader(id: line.id))
                    }

                    Spacer().frame(height: 80)
                }
                .padding(.horizontal, 24)
                .coordinateSpace(name: SmoothWordLyricsCoordinateSpace.name)
                .offset(y: displayOffset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .onPreferenceChange(LyricRowFramePreferenceKey.self) { frames in
                    wordLineFrames = frames
                }
            }
        }
        .clipped()
        // 顶/底 fade mask: viewport 边缘的歌词不要硬切, 用 LinearGradient 让它
        // 自然渐隐 ── 像歌词从黑暗中浮现 / 退去, 没有"切边"的廉价感。Apple Music
        // 同款手法。clear 区域占 12%, 内部 88% 全显示。
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .black, location: 0.12),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .contentShape(Rectangle())  // GeometryReader 自身不响应手势, 给整个区域加命中区
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    isPinchingLyrics = true
                    lyricsPinchScale = value.magnification
                }
                .onEnded { value in
                    let next = lyricsFontScale * Double(value.magnification)
                    lyricsFontScale = min(max(next, Self.lyricsMinScale), Self.lyricsMaxScale)
                    lyricsPinchScale = 1.0
                    isPinchingLyrics = false
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if manualWordOffset == nil {
                        // 起手: 以当前 auto offset 作为基准, 避免视图突然跳到顶部。
                        wordDragStartOffset = lastAutoWordOffset
                        manualWordOffset = lastAutoWordOffset
                    }
                    manualWordOffset = wordDragStartOffset + value.translation.height
                    lastUserScrollTime = Date()
                }
                .onEnded { value in
                    if let cur = manualWordOffset {
                        wordDragStartOffset = cur
                    }
                    lastUserScrollTime = Date()
                }
        )
    }

    /// 决定字级歌词视图当前应该用哪个 offset:
    /// - 用户在 grace period 内拖动过 → 用手动偏移
    /// - 否则 → 用 auto follow 偏移, 顺便把 manual 状态清空
    /// 同时记录最新 auto offset, DragGesture 起手时拿来当基准。
    private func resolveWordOffset(autoOffset: CGFloat) -> CGFloat {
        lastAutoWordOffset = autoOffset
        let withinGrace = Date().timeIntervalSince(lastUserScrollTime) < Self.manualScrollGracePeriod
        if withinGrace, let manual = manualWordOffset {
            return manual
        }
        // 退出 grace: 清掉手动状态, 让下一帧开始走 auto follow。
        if manualWordOffset != nil {
            manualWordOffset = nil
        }
        return autoOffset
    }

    private var wordLevelBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform")
                .font(.caption2)
            Text("lyrics_word_level_badge")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.white.opacity(0.6))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(.white.opacity(0.12)))
        .padding(.bottom, 4)
    }

    private func rowFrameReader(id: String) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: LyricRowFramePreferenceKey.self,
                value: [id: proxy.frame(in: .named(SmoothWordLyricsCoordinateSpace.name))]
            )
        }
    }

    private func smoothWordContentOffset(at time: TimeInterval, viewportHeight: CGFloat) -> CGFloat {
        guard !lyrics.isEmpty else { return 0 }
        let singingIndex = currentSingingLineIndex(at: time)
        let nextIndex = min(singingIndex + 1, lyrics.count - 1)

        guard let currentFrame = wordLineFrames[lyrics[singingIndex].id] else { return 0 }
        let currentCenter = currentFrame.midY
        let targetCenter: CGFloat

        if nextIndex > singingIndex, let nextFrame = wordLineFrames[lyrics[nextIndex].id] {
            let nextTimestamp = lyrics[nextIndex].timestamp
            let progress = lineScrollProgress(time: time, nextTimestamp: nextTimestamp)
            targetCenter = currentCenter + (nextFrame.midY - currentCenter) * progress
        } else {
            targetCenter = currentCenter
        }

        let visualAnchor = viewportHeight * 0.42
        return visualAnchor - targetCenter
    }

    private func currentSingingLineIndex(at time: TimeInterval) -> Int {
        for (i, line) in lyrics.enumerated().reversed() where time >= line.timestamp {
            return i
        }
        return 0
    }

    private func lineScrollProgress(time: TimeInterval, nextTimestamp: TimeInterval) -> CGFloat {
        let raw = (time - (nextTimestamp - Self.wordLevelScrollLead)) / Self.wordLevelScrollDuration
        let clamped = max(0, min(1, raw))
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// dimmedByAmbient: 字级模式调用时传 true ── 表明行整体明暗由外层基于 now
    /// 的连续 ambient opacity 接管, row 内部不要再按 isActive 离散切换颜色,
    /// 否则跟外层 .opacity multiply 会双重叠加 + 跳变。
    @ViewBuilder
    private func lyricsRow(line: LyricLine, index: Int, dimmedByAmbient: Bool = false) -> some View {
        let isActive = index == currentLineIndex
        let baseSize = hasWordLevelLyrics
            ? Self.lyricsWordLevelBaseSize
            : isActive ? Self.lyricsActiveBaseSize : Self.lyricsInactiveBaseSize
        let fontSize = baseSize * CGFloat(effectiveLyricsScale)
        // weight 在 dimmedByAmbient 模式下也固定 .semibold ── 字级模式 active 行
        // 已经有 syllable 扫光 + scale bounce 强调, weight 跳变只会增加视觉颗粒感。
        let weight: Font.Weight = dimmedByAmbient ? .semibold : (isActive ? .bold : .semibold)
        let alignment: HorizontalAlignment = line.voice == .secondary ? .trailing : .leading

        VStack(alignment: alignment, spacing: 4) {
            singleLineContent(line: line, isActive: isActive, index: index, fontSize: fontSize, weight: weight, dimmedByAmbient: dimmedByAmbient)

            // 歌词翻译 — 在原文下面以略小的字号显示, 仅当启用且当前行有翻译。
            // 字号取原文的 0.65 + medium weight, 视觉上是 secondary。
            if let translated = translatedTextByLineID[line.id], !translated.isEmpty {
                Text(translated)
                    .font(.system(size: fontSize * 0.65, weight: .medium))
                    .foregroundStyle(
                        dimmedByAmbient
                            ? .white.opacity(0.7)
                            : isActive ? .white.opacity(0.7)
                            : index < currentLineIndex ? .white.opacity(0.18)
                            : .white.opacity(0.28)
                    )
                    // 长翻译在窄屏 / 大字号下要 wrap 多行。不加 fixedSize 时 SwiftUI
                    // 会优先单行 + 截断显示省略号。
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let bgs = line.background {
                ForEach(bgs) { bg in
                    singleLineContent(line: bg, isActive: isActive, index: index, fontSize: fontSize * 0.7, weight: .medium, dimmedByAmbient: dimmedByAmbient)
                        .opacity(0.7)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: line.voice == .secondary ? .trailing : .leading)
    }

    @ViewBuilder
    private func singleLineContent(
        line: LyricLine,
        isActive: Bool,
        index: Int,
        fontSize: CGFloat,
        weight: Font.Weight,
        dimmedByAmbient: Bool = false
    ) -> some View {
        if shouldRenderWordTimeline(line: line, index: index, isActive: isActive, dimmedByAmbient: dimmedByAmbient) {
            // dimmedByAmbient 模式: KaraokeLineView 内部用固定 active=1.0 / inactive=0.4
            // 对比, 外层 ambient opacity 接管 row 整体明暗。这样无论 row 处于 future /
            // active / past, syllable 扫光的对比度都一致, 只是整体亮度被 ambient
            // 平滑过渡。
            let inactiveOpacity: Double = dimmedByAmbient ? 0.4
                : (isActive ? 0.4 : (index < currentLineIndex ? 0.25 : 0.4))
            let activeOpacity: Double = dimmedByAmbient ? 1.0
                : (isActive ? 1.0 : inactiveOpacity)
            KaraokeLineView(
                line: line,
                fontSize: fontSize,
                weight: weight,
                activeColor: .white.opacity(activeOpacity),
                inactiveColor: .white.opacity(inactiveOpacity),
                timeAt: { date in player.interpolatedTime(at: date) }
            )
        } else {
            Text(line.text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(
                    dimmedByAmbient
                        ? .white
                        : isActive ? .white
                        : index < currentLineIndex ? .white.opacity(0.25)
                        : .white.opacity(0.4)
                )
                // 长歌词在窄屏 / 放大字号下需要 wrap 多行。不加 fixedSize 时 SwiftUI
                // 在某些 layout 约束下会单行 + 省略号; 而靠近当前行时切到 KaraokeLineView
                // (它有 fixedSize) 会展开多行 → 视觉上"省略号展开收起"的跳动。
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 字级模式 row 的视觉状态 ── opacity 和 scale 都基于同一个 activity 0..1
    /// 连续值派生, 保证两者节奏一致。
    private struct RowActivity {
        var opacity: Double
        var scale: Double
    }

    /// 字级模式专用 ── 计算指定行的视觉激活度 (0..1, 0=远行, 1=正在唱), 然后
    /// 一次性派生 opacity / scale。两者同节奏渐变, 行从 active → past 的过渡
    /// 跟 scroll offset 在同一套时间窗口 (wordLevelScrollLead /
    /// wordLevelScrollDuration) 内同步发生 ── 位置 / 颜色 / 缩放是一个事件的
    /// 不同面, 不再有"先滑动后跳暗"的不协调感。
    private func rowVisualActivity(at now: TimeInterval, index: Int) -> RowActivity {
        guard index >= 0, index < lyrics.count else {
            return RowActivity(opacity: 0.4, scale: 1.0)
        }
        let myStart = lyrics[index].timestamp
        // 最后一行没有"下一行 timestamp", 假设它持续 8s ── 短于这个时长歌曲也
        // 早就结束了, 长于的话最多就是最后一行没有渐暗效果, 不影响中间行。
        let nextStart: TimeInterval = (index + 1 < lyrics.count)
            ? lyrics[index + 1].timestamp
            : myStart + 8.0

        // 视觉过渡窗口跟 scroll lookahead 解耦。
        //
        // 之前 opacity / scale 用 scroll 同款窗口 (lookahead=0.42s, duration=0.54s):
        // 下一行在当前行还没唱完时就开始变亮 / 变大, 中间过渡有 0.5s+ 的"中间
        // 状态"。眼睛看到的是 active(1.0) → 过渡中(0.6) → 远行(0.4) 三档深度,
        // 配合 fadeIn 的 0.4→0.6→1.0 反向过渡, 切换瞬间感受到"第三档浅色快速
        // 变深"的视觉跳跃。
        //
        // 缩短到 0.18s + 围绕行真正切换的时刻 (myStart / nextStart) 后, 过渡
        // 几乎瞬时, 中间档持续时间不到一帧的两三倍, 主观上只剩 active / 非
        // active 两档。scroll 不变, 行的位置仍然平滑滑过 ── 视觉上像"灯光
        // 跟着行走": 行先滑到中心, 灯光打到它身上瞬间亮起。
        let visualWindow: TimeInterval = 0.18
        let fadeInStart = myStart - visualWindow / 2
        let fadeInEnd = myStart + visualWindow / 2
        let fadeOutStart = nextStart - visualWindow / 2
        let fadeOutEnd = nextStart + visualWindow / 2

        let activity: Double
        if now < fadeInStart { activity = 0 }
        else if now < fadeInEnd {
            activity = smoothstep((now - fadeInStart) / max(fadeInEnd - fadeInStart, 0.001))
        } else if now < fadeOutStart { activity = 1 }
        else if now < fadeOutEnd {
            activity = 1 - smoothstep((now - fadeOutStart) / max(fadeOutEnd - fadeOutStart, 0.001))
        } else { activity = 0 }

        // opacity: 两档 ── 非 active 0.4 / active 1.0。
        let opacity = 0.4 + 0.6 * activity

        // scale: 非 active 1.0 / active 1.12 ── 比之前的 1.06 更夸张, 给"聚焦
        // 灯光打在你身上"的强调感, 让 active 行更突出。
        let scale = 1.0 + 0.12 * activity

        return RowActivity(opacity: opacity, scale: scale)
    }

    private func smoothstep(_ t: Double) -> Double {
        let c = max(0, min(1, t))
        return c * c * (3 - 2 * c)
    }

    private func shouldRenderWordTimeline(line: LyricLine, index: Int, isActive: Bool, dimmedByAmbient: Bool = false) -> Bool {
        guard line.isWordLevel else { return false }
        // dimmedByAmbient 模式 (字级歌词): 只让 active 行走 KaraokeLineView 扫光,
        // 相邻 ±1 行也走普通 Text。
        //
        // 原因: KaraokeLineView 内部 inactive syllable 用 .white.opacity(0.4) 实现
        // 双层 Text 的"扫光底色对比"; 而 row 外层 ambient opacity 在非 active 行
        // 也是 0.4。两者 multiply → 0.16, 比远行 (普通 Text × 0.4 = 0.4) 显著
        // 暗一档 ── 用户看到的"下一行比下下行还暗"就是这个双重 multiply 造成。
        //
        // 代价: 下一行失去"提前 100ms 预热扫光"的细节, 行真正切到 active 时才
        // 启动扫光。lookahead 100ms 在视觉上几乎不可察觉, 取舍合理。
        if dimmedByAmbient { return isActive }
        return isActive || abs(index - currentLineIndex) == 1
    }

    /// 行级歌词 LRC 文件的 timestamp 通常是「演唱开始那一刻」,但 LRC 制作过程
    /// 中作者按 spacebar 记录会有人为反应延迟(常见 200-400ms),用户感受是
    /// 「头两个字唱完才高亮这一行」。给行级判断加 250ms lookahead 提前切换。
    /// 字级歌词 syllable 粒度精度本来就高,但行切换时也需要一点预热时间;
    /// 否则下一行会在第一个字开唱时才从普通行切成逐字 Timeline,跨行会显得顿。
    private static let lineLevelLookahead: TimeInterval = 0.25
    private static let wordLevelLineLookahead: TimeInterval = 0.10
    private static let wordLevelScrollLead: TimeInterval = 0.42
    private static let wordLevelScrollDuration: TimeInterval = 0.54

    private func updateCurrentLine() {
        guard !lyrics.isEmpty else { return }
        let time = player.interpolatedTime()
        for (i, line) in lyrics.enumerated().reversed() {
            let lookahead: TimeInterval = line.isWordLevel ? Self.wordLevelLineLookahead : Self.lineLevelLookahead
            if time + lookahead >= line.timestamp {
                if currentLineIndex != i { currentLineIndex = i }
                break
            }
        }
    }
}

private enum SmoothWordLyricsCoordinateSpace {
    static let name = "smoothWordLyricsContent"
}

private struct LyricRowFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private extension View {
    @ViewBuilder
    func lyricsTranslationTaskIfAvailable(
        songID: String?,
        lyrics: [LyricLine],
        settings: LyricsTranslationSettingsStore,
        translatedTextByLineID: Binding<[String: String]>
    ) -> some View {
        if #available(iOS 18.0, *) {
            modifier(
                LyricsTranslationTaskModifier(
                    songID: songID,
                    lyrics: lyrics,
                    settings: settings,
                    translatedTextByLineID: translatedTextByLineID
                )
            )
        } else {
            self
        }
    }
}

@available(iOS 18.0, *)
private struct LyricsTranslationTaskModifier: ViewModifier {
    let songID: String?
    let lyrics: [LyricLine]
    let settings: LyricsTranslationSettingsStore
    @Binding var translatedTextByLineID: [String: String]
    @State private var translationConfig: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .onChange(of: songID) { _, _ in
                translatedTextByLineID = [:]
                refreshTranslationConfig()
            }
            .onChange(of: lyrics.count) { _, _ in
                translatedTextByLineID = [:]
                refreshTranslationConfig()
            }
            .onChange(of: settings.isEnabled) { _, _ in
                refreshTranslationConfig()
            }
            .onChange(of: settings.targetLanguageCode) { _, _ in
                translatedTextByLineID = [:]
                refreshTranslationConfig()
            }
            .onAppear {
                refreshTranslationConfig()
                primeFromCache()
            }
            .translationTask(translationConfig) { session in
                await runTranslation(session: session)
            }
    }

    /// 重置 translationConfig 让 .translationTask 重新触发。
    /// 设 nil → 设新值, SwiftUI 才会重跑 task。
    private func refreshTranslationConfig() {
        guard settings.isEnabled, !lyrics.isEmpty else {
            translationConfig = nil
            return
        }
        let target = Locale.Language(identifier: settings.targetLanguageCode)
        // source: nil 让 framework 自动检测 (英、日、韩混排都能处理)
        translationConfig = TranslationSession.Configuration(source: nil, target: target)
    }

    /// 进入歌词或换歌时, 先用 cache 命中的填上, 用户立刻看到已翻译内容。
    private func primeFromCache() {
        guard settings.isEnabled else { return }
        let target = settings.targetLanguageCode
        let cache = LyricsTranslationCache.shared
        var hits: [String: String] = [:]
        for line in lyrics where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let t = cache.translation(for: line.text, targetLang: target) {
                hits[line.id] = t
            }
        }
        if !hits.isEmpty { translatedTextByLineID = hits }
    }

    /// 翻译当前歌全部未翻译过的行, 结果存 cache + 更新 UI。
    /// 系统第一次用某语言对会触发语言模型下载提示, 用户取消时 throw error,
    /// 静默丢弃 (此次显示不出翻译, 下次再试)。
    private func runTranslation(session: TranslationSession) async {
        let target = settings.targetLanguageCode
        let cache = LyricsTranslationCache.shared
        // 找出还没翻译的行 (cache miss + state 里也没)
        let pending: [(id: String, text: String)] = lyrics.compactMap { line in
            let t = line.text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            if translatedTextByLineID[line.id] != nil { return nil }
            if let cached = cache.translation(for: line.text, targetLang: target) {
                // cache 命中但 state 里漏了, 顺手填上
                translatedTextByLineID[line.id] = cached
                return nil
            }
            // 24h 内标记过翻译失败的不再重试 — 系统对不支持的语言对/已经
            // 是目标语言的源文是确定性 throw, 每次播都重试白白吃 CPU。
            if cache.isMarkedFailed(source: line.text, targetLang: target) {
                return nil
            }
            return (line.id, line.text)
        }
        guard !pending.isEmpty else { return }

        // 批量翻译 — clientIdentifier 用 line.id 让 response 可对回原行
        let requests = pending.map {
            TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id)
        }
        var newCachePairs: [(source: String, translated: String)] = []
        var newStateUpdates: [String: String] = [:]
        do {
            for try await response in session.translate(batch: requests) {
                let id = response.clientIdentifier ?? ""
                let translated = response.targetText
                if !id.isEmpty { newStateUpdates[id] = translated }
                newCachePairs.append((response.sourceText, translated))
            }
        } catch {
            // 用户拒绝下载语言模型 / 不支持的语言对 / 网络错 (语言下载阶段)
            // 不弹错, UI 自然不显示翻译就行。把这次没回来的行打上 negative
            // mark, 24h 内不再 retry 同样的 batch。已经回来的 partial 走下面
            // bulkSet, 不浪费。
            plog("⚠️ Lyrics translation failed: \(error.localizedDescription)")
            let translatedTexts = Set(newCachePairs.map { $0.source })
            let failed = pending.map { $0.text }.filter { !translatedTexts.contains($0) }
            if !failed.isEmpty {
                cache.markFailed(sources: failed, targetLang: target)
            }
        }
        // 即便中途 throw, 已经回来的 partial response 也写进 cache, 不然下次
        // 播这首歌全部行都得重翻一次。
        if !newCachePairs.isEmpty {
            cache.bulkSet(newCachePairs, targetLang: target)
            // 一次性 merge state, 避免逐个 setter 触发多次 SwiftUI 重算
            translatedTextByLineID.merge(newStateUpdates) { _, new in new }
        }
    }
}

// MARK: - PlaybackProgressBar (隔离 player.currentTime 高频读)

/// 进度条 + 双端时间标签。父 NowPlayingView body 不直接读 `player.currentTime`,
/// 把高频属性的 Observation 追踪限制在本 view 内。这样 currentTime 每 0.5s 变化
/// 只重算本 view,不会让父 body 重算 → 父 view 里的 SwiftUI Menu submenu (字号
/// 选择)在用户操作期间不会被强制关闭。
fileprivate struct PlaybackProgressBar: View {
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        VStack(spacing: 4) {
            ProgressSlider(
                value: player.currentTime,
                total: player.duration,
                onSeek: { player.seek(to: $0) }
            )
            HStack {
                Text(player.currentTime.formattedDuration); Spacer()
                Text("-\(max(0, player.duration - player.currentTime).formattedDuration)")
            }
            .font(.caption2).foregroundStyle(.white.opacity(0.5)).monospacedDigit()
        }
    }
}

// MARK: - Cast Device Picker

/// 投屏目标设备选择。读 DLNARendererService.discoveredRenderers, 显示 LAN 内
/// 所有 MediaRenderer; 顶部"本机播放"项 = 取消投屏 (stopCasting); 选中其它项
/// = startCasting。当前已投屏的设备旁打 checkmark。
struct CastDevicePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioPlayerService.self) private var player
    @Environment(DLNARendererService.self) private var renderer

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await player.stopCasting(); dismiss() }
                    } label: {
                        HStack {
                            Image(systemName: "iphone")
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("cast_local_device")
                                    .font(.body)
                                Text("cast_local_subtitle")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !player.isCastingMode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                let remoteRenderers = renderer.discoveredRenderers.values.sorted { $0.friendlyName < $1.friendlyName }
                if remoteRenderers.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("cast_scanning")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("cast_dlna_required_hint")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                } else {
                    Section {
                        ForEach(remoteRenderers) { dev in
                            Button {
                                Task { await player.startCasting(to: dev); dismiss() }
                            } label: {
                                HStack {
                                    Image(systemName: "tv.and.hifispeaker.fill")
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(dev.friendlyName)
                                            .font(.body)
                                            .lineLimit(1)
                                        if let model = dev.modelName {
                                            Text(dev.manufacturer.map { "\($0) · \(model)" } ?? model)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        } else {
                                            Text(dev.host)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if player.castingRenderer?.udn == dev.udn {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("cast_lan_devices")
                    }
                }
            }
            .navigationTitle("cast_picker_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { renderer.refreshRemoteRenderers() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(Text("refresh"))
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .task {
                // 进 sheet 立刻主动扫一遍, 不等下一次周期触发
                renderer.refreshRemoteRenderers()
            }
        }
    }
}
