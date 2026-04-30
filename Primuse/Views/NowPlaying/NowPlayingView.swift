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
    @State private var currentLineIndex = 0
    @State private var isScrapingCurrentSong = false
    @State private var scrapeAlertMessage: String?
    @State private var showScrapeOptions = false
    @State private var showAddToPlaylist = false
    @State private var showSongInfo = false
    @State private var showSleepTimer = false
    @State private var showDeleteConfirm = false
    @Environment(ThemeService.self) private var theme

    // Lyrics font scaling — persisted across launches; live pinch overlay during a gesture
    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0
    @State private var lyricsPinchScale: CGFloat = 1.0
    @State private var isPinchingLyrics = false

    private static let lyricsMinScale: Double = 0.7
    private static let lyricsMaxScale: Double = 1.8
    private static let lyricsActiveBaseSize: CGFloat = 28
    private static let lyricsInactiveBaseSize: CGFloat = 22

    private var effectiveLyricsScale: Double {
        let combined = lyricsFontScale * Double(lyricsPinchScale)
        return min(max(combined, Self.lyricsMinScale), Self.lyricsMaxScale)
    }

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

                    // Progress — custom thin slider
                    VStack(spacing: 4) {
                        ProgressSlider(
                            value: player.currentTime,
                            total: player.duration,
                            onSeek: { player.seek(to: $0) }
                        )
                        HStack {
                            Text(fmt(player.currentTime)); Spacer()
                            Text("-\(fmt(max(0, player.duration - player.currentTime)))")
                        }
                        .font(.caption2).foregroundStyle(.white.opacity(0.5)).monospacedDigit()
                    }
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
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 56)).foregroundStyle(.white)
                                .contentTransition(.symbolEffect(.replace))
                        }
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
        .onReceive(Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()) { _ in updateCurrentLine() }
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
        // Remove from library
        library.deleteSong(song)
    }

    // MARK: - More Menu

    private var moreMenu: some View {
        Menu {
            // Group 1: Music actions
            Section {
                Button { showScrapeOptions = true } label: {
                    Label(String(localized: "scrape_song"), systemImage: "wand.and.stars")
                }
                .disabled(player.currentSong == nil || isScrapingCurrentSong)

                Button { showAddToPlaylist = true } label: {
                    Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
                }
                .disabled(player.currentSong == nil)
            }

            // Group 1b: Lyrics font size — only relevant while viewing lyrics
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
                }
            }

            // Group 2: Utilities
            Section {
                Button { showSleepTimer = true } label: {
                    Label(
                        player.isSleepTimerActive ? String(localized: "sleep_timer_active") : String(localized: "sleep_timer"),
                        systemImage: "moon.zzz"
                    )
                }

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

            // Group 3: Destructive
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
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Spacer().frame(height: 20)

                    if lyrics.isEmpty {
                        VStack(spacing: 12) {
                            Spacer().frame(height: 60)
                            Text("no_lyrics").font(.title3).foregroundStyle(.white.opacity(0.3))
                            Button { Task { await scrapeCurrentSong() } } label: {
                                Label("scrape_song", systemImage: "wand.and.stars").font(.subheadline)
                            }
                            .buttonStyle(.bordered).tint(.white)
                            .disabled(isScrapingCurrentSong)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                            let isActive = index == currentLineIndex
                            let baseSize = isActive ? Self.lyricsActiveBaseSize : Self.lyricsInactiveBaseSize
                            Text(line.text)
                                .font(.system(size: baseSize * CGFloat(effectiveLyricsScale)))
                                .fontWeight(isActive ? .bold : .semibold)
                                .foregroundStyle(
                                    isActive ? .white
                                    : index < currentLineIndex ? .white.opacity(0.25)
                                    : .white.opacity(0.4)
                                )
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
                // Don't fight the user's pinch — auto-scroll resumes once they let go
                guard !isPinchingLyrics, idx < lyrics.count else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(lyrics[idx].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Helpers

    private func ctrlBtn(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body)
                .foregroundStyle(active ? .white : .white.opacity(0.4))
        }.frame(width: 44, height: 44)
    }

    private func loadLyrics() async {
        guard let song = player.currentSong else { lyrics = []; return }

        // Tier 1: Local cache only (no network — never block the connector during playback)
        if let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: song.id) {
            lyrics = cached; currentLineIndex = 0; return
        }
        if let cached = await MetadataAssetStore.shared.lyrics(named: song.lyricsFileName) {
            await MetadataAssetStore.shared.cacheLyrics(cached, forSongID: song.id)
            lyrics = cached; currentLineIndex = 0; return
        }

        // Tier 2: Check local audio cache for sidecar .lrc (filesystem only, zero network)
        if let cachedAudioURL = sourceManager.cachedURL(for: song),
           let lrcURL = SidecarMetadataLoader.findLyrics(for: cachedAudioURL),
           let parsed = try? LyricsParser.parse(from: lrcURL), !parsed.isEmpty {
            await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: song.id)
            lyrics = parsed; currentLineIndex = 0; return
        }

        // Tier 3: Fetch .lrc from source using an independent connector (parallel with playback)
        lyrics = []; currentLineIndex = 0
        let capturedSourceManager = sourceManager

        Task {
            do {
                // auxiliaryConnector creates a separate connection — won't block playback
                let connector = try await capturedSourceManager.auxiliaryConnector(for: song)
                let songDir = (song.filePath as NSString).deletingLastPathComponent
                let baseName = ((song.filePath as NSString).lastPathComponent as NSString).deletingPathExtension
                let lrcPath: String
                if let ref = song.lyricsFileName, ref.contains("/") {
                    lrcPath = ref
                } else {
                    lrcPath = (songDir as NSString).appendingPathComponent("\(baseName).lrc")
                }

                let lrcLocalURL = try await connector.localURL(for: lrcPath)
                let parsed = try LyricsParser.parse(from: lrcLocalURL)
                guard !parsed.isEmpty else { return }

                await MetadataAssetStore.shared.cacheLyrics(parsed, forSongID: song.id)
                // Update UI if still on the same song
                if player.currentSong?.id == song.id {
                    lyrics = parsed; currentLineIndex = 0
                }
            } catch {
                // No .lrc file — not an error
            }
        }
    }



    private func updateCurrentLine() {
        guard !lyrics.isEmpty else { return }
        let time = player.currentTime
        for (i, line) in lyrics.enumerated().reversed() {
            if time >= line.timestamp { if currentLineIndex != i { currentLineIndex = i }; break }
        }
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
