import AVKit
import SwiftUI
import PrimuseKit

struct NowPlayingView: View {
    var onMinimize: (() -> Void)? = nil
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var lyrics: [LyricLine] = []
    @State private var isScrapingCurrentSong = false
    @State private var scrapeAlertMessage: String?
    @State private var showScrapeOptions = false
    @State private var showAddToPlaylist = false
    @State private var showSongInfo = false
    @State private var showSleepTimer = false
    @State private var showDeleteConfirm = false
    @Environment(ThemeService.self) private var theme

    // 父持有 @AppStorage 仅为了 onChange 触发 CloudKVS 同步;实际渲染字号由
    // LyricsScrollView 子 view 自己读 AppStorage("lyricsFontScale")。
    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0

    /// Whether the current song is in any playlist (not a dedicated "favorites" concept)
    private var isInAnyPlaylist: Bool {
        guard let songID = player.currentSong?.id else { return false }
        return library.playlists.contains { library.contains(songID: songID, inPlaylist: $0.id) }
    }


    /// Top safe area height (dynamic island / status bar)
    private var topSafeArea: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .keyWindow?.safeAreaInsets.top ?? 59
    }

    var body: some View {
        GeometryReader { geo in
            let artSize = min(geo.size.width - 60, geo.size.height * 0.38)

            ZStack {
                // Opaque base — prevents content bleeding through
                Color.black.ignoresSafeArea()
                // Dynamic background from cover colors — fully opaque
                backgroundGradient.ignoresSafeArea()

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
                                    filePath: player.currentSong?.filePath
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

                            Button { showAddToPlaylist = true } label: {
                                Image(systemName: isInAnyPlaylist ? "heart.fill" : "heart")
                                    .font(.title3)
                                    .foregroundStyle(isInAnyPlaylist ? .red : .white.opacity(0.6))
                                    .contentTransition(.symbolEffect(.replace))
                            }

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
                            filePath: player.currentSong?.filePath
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

                            // Like button
                            Button {
                                showAddToPlaylist = true
                            } label: {
                                Image(systemName: isInAnyPlaylist ? "heart.fill" : "heart")
                                    .font(.title2)
                                    .foregroundStyle(isInAnyPlaylist ? .red : .white.opacity(0.6))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                            .padding(.trailing, 4)

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
                        }.frame(width: 56, height: 56)
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
                        Spacer()
                        Button { Task { await player.next() } } label: {
                            Image(systemName: "forward.fill").font(.title).foregroundStyle(.white)
                        }.frame(width: 56, height: 56)
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
                    // Invalidate cover cache so all views reload
                    CachedArtworkView.invalidateCache(for: u.id)
                    if let oldRef = song.coverArtFileName {
                        CachedArtworkView.invalidateCache(for: oldRef)
                    }
                    player.syncSongMetadata(u)
                    player.forceRefreshNowPlayingArtwork()
                    Task { await loadLyrics() }
                }
                .presentationDetents([.medium, .large])
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
        .confirmationDialog(String(localized: "sleep_timer"), isPresented: $showSleepTimer) {
            Button("15 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 15) }
            Button("30 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 30) }
            Button("45 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 45) }
            Button("60 " + String(localized: "minutes")) { player.scheduleSleep(minutes: 60) }
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
    }

    private func deleteCurrentSong() {
        guard let song = player.currentSong else { return }
        // Skip to next before deleting
        Task { await player.next() }
        // Clean caches
        let songID = song.id
        Task {
            await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
            await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: songID)
        }
        CachedArtworkView.invalidateCache(for: song.id)
        sourceManager.deleteAudioCache(for: song)
        // Remove from library and keep the source badge in sync.
        let remaining = library.deleteSong(song)
        sourcesStore.updateLocal(song.sourceID) { $0.songCount = remaining }
    }

    // MARK: - More Menu

    private var moreMenu: some View {
        Menu {
            // 收藏 / 编辑当前歌曲
            Section {
                Button { showAddToPlaylist = true } label: {
                    Label(String(localized: "add_to_playlist"),
                          systemImage: isInAnyPlaylist ? "heart.fill" : "text.badge.plus")
                }
                .disabled(player.currentSong == nil)

                Button { showScrapeOptions = true } label: {
                    Label(String(localized: "scrape_song"), systemImage: "wand.and.stars")
                }
                .disabled(player.currentSong == nil || isScrapingCurrentSong)
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
            }

            // 销毁
            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label(String(localized: "delete_song"), systemImage: "trash")
                }
                .disabled(player.currentSong == nil)
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
                theme.darkAccent.mix(with: .black, by: 0.4),
                .black
            ],
            startPoint: .top, endPoint: .bottom
        )
        .animation(.easeInOut(duration: 0.5), value: theme.colorID)
    }

    // MARK: - Full Lyrics (Apple Music style: large text, no frame constraint)

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
        }.frame(width: 44, height: 44)
    }

    private func loadLyrics() async {
        guard let song = player.currentSong else { setLyrics([]); return }
        let loadStart = Date()

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

                await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: songID)
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
        // currentLineIndex / hasWordLevelLyrics 已迁移到 LyricsScrollView 子 view,
        // 子 view 自己 onChange(of: songID) 重置 + computed property 算 hasWord。
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
            }
            .navigationTitle(String(localized: "song_info"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
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

// MARK: - LyricsScrollView (隔离的歌词渲染子 view)

/// 把歌词渲染抽出来作为独立 View,避免行切换 (`currentLineIndex` 变化) 让
/// 整个 NowPlayingView 的 body 重算,从而触发 SwiftUI Menu 内嵌的 Picker(.menu)
/// submenu 在父重算时被强制关闭(选字号弹框还没来得及选就消失)。
///
/// 通过把 currentLineIndex 等内部状态封装在子 view 里,行切换只让本 view 重算,
/// 父 view 的 Menu / sheet 不受影响。
fileprivate struct LyricsScrollView: View {
    let lyrics: [LyricLine]
    let player: AudioPlayerService
    let songID: String?
    let isScrapingCurrentSong: Bool
    let onScrape: () -> Void

    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0
    @State private var lyricsPinchScale: CGFloat = 1.0
    @State private var isPinchingLyrics = false
    @State private var currentLineIndex = 0

    private static let lyricsMinScale: Double = 0.7
    private static let lyricsMaxScale: Double = 1.8
    private static let lyricsActiveBaseSize: CGFloat = 28
    private static let lyricsInactiveBaseSize: CGFloat = 22

    private var effectiveLyricsScale: Double {
        let combined = lyricsFontScale * Double(lyricsPinchScale)
        return min(max(combined, Self.lyricsMinScale), Self.lyricsMaxScale)
    }

    private var hasWordLevelLyrics: Bool {
        lyrics.contains { $0.isWordLevel }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Spacer().frame(height: 20)

                    if lyrics.isEmpty {
                        VStack(spacing: 12) {
                            Spacer().frame(height: 60)
                            Text("no_lyrics").font(.title3).foregroundStyle(.white.opacity(0.3))
                            Button { onScrape() } label: {
                                Label("scrape_song", systemImage: "wand.and.stars").font(.subheadline)
                            }
                            .buttonStyle(.bordered).tint(.white)
                            .disabled(isScrapingCurrentSong)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        if hasWordLevelLyrics {
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

                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                            lyricsRow(line: line, index: index)
                                .id(line.id)
                                .onTapGesture { player.seek(to: line.timestamp) }
                                .padding(.vertical, 2)
                        }
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
            .onChange(of: currentLineIndex) { _, idx in
                guard !isPinchingLyrics, idx < lyrics.count else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(lyrics[idx].id, anchor: .center)
                }
            }
        }
        .onReceive(Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()) { _ in
            updateCurrentLine()
        }
        .onChange(of: songID) { _, _ in
            // 切歌时把行索引清零 + 让自动滚动重新 anchor
            currentLineIndex = 0
        }
    }

    @ViewBuilder
    private func lyricsRow(line: LyricLine, index: Int) -> some View {
        let isActive = index == currentLineIndex
        let baseSize = isActive ? Self.lyricsActiveBaseSize : Self.lyricsInactiveBaseSize
        let fontSize = baseSize * CGFloat(effectiveLyricsScale)
        let weight: Font.Weight = isActive ? .bold : .semibold
        let alignment: HorizontalAlignment = line.voice == .secondary ? .trailing : .leading

        VStack(alignment: alignment, spacing: 4) {
            singleLineContent(line: line, isActive: isActive, index: index, fontSize: fontSize, weight: weight)

            if let bgs = line.background {
                ForEach(bgs) { bg in
                    singleLineContent(line: bg, isActive: isActive, index: index, fontSize: fontSize * 0.7, weight: .medium)
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
        weight: Font.Weight
    ) -> some View {
        if isActive, line.isWordLevel {
            KaraokeLineView(
                line: line,
                fontSize: fontSize,
                weight: weight,
                activeColor: .white,
                inactiveColor: .white.opacity(0.4),
                timeAt: { date in player.interpolatedTime(at: date) }
            )
        } else {
            Text(line.text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(
                    isActive ? .white
                    : index < currentLineIndex ? .white.opacity(0.25)
                    : .white.opacity(0.4)
                )
        }
    }

    /// 行级歌词 LRC 文件的 timestamp 通常是「演唱开始那一刻」,但 LRC 制作过程
    /// 中作者按 spacebar 记录会有人为反应延迟(常见 200-400ms),用户感受是
    /// 「头两个字唱完才高亮这一行」。给行级判断加 250ms lookahead 提前切换。
    /// 字级歌词 syllable 粒度精度本来就高,不用补偿。
    private static let lineLevelLookahead: TimeInterval = 0.25

    private func updateCurrentLine() {
        guard !lyrics.isEmpty else { return }
        let time = player.interpolatedTime()
        for (i, line) in lyrics.enumerated().reversed() {
            let lookahead: TimeInterval = line.isWordLevel ? 0 : Self.lineLevelLookahead
            if time + lookahead >= line.timestamp {
                if currentLineIndex != i { currentLineIndex = i }
                break
            }
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
