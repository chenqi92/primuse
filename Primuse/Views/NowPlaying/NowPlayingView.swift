import AVKit
import SwiftUI
import PrimuseKit

struct NowPlayingView: View {
    var onMinimize: (() -> Void)? = nil
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
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
    @Environment(ThemeService.self) private var theme

    /// Whether the current song is in ANY playlist
    private var isLiked: Bool {
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

                    if showLyrics {
                        // LYRICS MODE: compact header at top
                        HStack(spacing: 10) {
                            // Tappable cover + title → switch back to cover mode
                            HStack(spacing: 10) {
                                CachedArtworkView(
                                    coverFileName: player.currentSong?.coverArtFileName,
                                    size: 44, cornerRadius: 6
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
                                Image(systemName: isLiked ? "heart.fill" : "heart")
                                    .font(.title3)
                                    .foregroundStyle(isLiked ? .red : .white.opacity(0.6))
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
                            coverFileName: player.currentSong?.coverArtFileName,
                            size: artSize, cornerRadius: 12
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
                                Image(systemName: isLiked ? "heart.fill" : "heart")
                                    .font(.title2)
                                    .foregroundStyle(isLiked ? .red : .white.opacity(0.6))
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
                            total: max(player.duration, 0.1),
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

                    // Format
                    if let song = player.currentSong {
                        HStack(spacing: 4) {
                            Text(song.fileFormat.displayName)
                            if let sr = song.sampleRate { Text("·"); Text("\(sr / 1000)kHz") }
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
                    player.syncSongMetadata(u)
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
            Button("15 " + String(localized: "minutes")) { scheduleSleep(minutes: 15) }
            Button("30 " + String(localized: "minutes")) { scheduleSleep(minutes: 30) }
            Button("45 " + String(localized: "minutes")) { scheduleSleep(minutes: 45) }
            Button("60 " + String(localized: "minutes")) { scheduleSleep(minutes: 60) }
            if sleepTimer != nil {
                Button(String(localized: "cancel_timer"), role: .destructive) { cancelSleep() }
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        }
        .alert(String(localized: "scrape_song"),
               isPresented: Binding(get: { scrapeAlertMessage != nil }, set: { if !$0 { scrapeAlertMessage = nil } })) {
            Button("done", role: .cancel) {}
        } message: { Text(scrapeAlertMessage ?? "") }
    }

    // MARK: - More Menu

    private var moreMenu: some View {
        Menu {
            Button { showScrapeOptions = true } label: {
                Label(String(localized: "scrape_song"), systemImage: "wand.and.stars")
            }
            .disabled(player.currentSong == nil || isScrapingCurrentSong)

            Button { showAddToPlaylist = true } label: {
                Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
            }
            .disabled(player.currentSong == nil)

            Button { showSleepTimer = true } label: {
                Label(
                    sleepTimer != nil ? String(localized: "sleep_timer_active") : String(localized: "sleep_timer"),
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
                            Text(line.text)
                                .font(index == currentLineIndex ? .title : .title2)
                                .fontWeight(index == currentLineIndex ? .bold : .semibold)
                                .foregroundStyle(
                                    index == currentLineIndex ? .white
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
            .onChange(of: currentLineIndex) { _, idx in
                guard idx < lyrics.count else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(lyrics[idx].id, anchor: .center)
                }
            }
        }
        .onTapGesture { withAnimation(.easeInOut(duration: 0.3)) { showLyrics = false } }
    }

    // MARK: - Sleep Timer

    @State private var sleepTimer: Timer?

    private func scheduleSleep(minutes: Int) {
        sleepTimer?.invalidate()
        sleepTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { _ in
            Task { @MainActor in
                player.pause()
                sleepTimer = nil
            }
        }
    }

    private func cancelSleep() {
        sleepTimer?.invalidate()
        sleepTimer = nil
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
        lyrics = await MetadataAssetStore.shared.lyrics(named: song.lyricsFileName) ?? []
        currentLineIndex = 0
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
            player.syncSongMetadata(u); await loadLyrics()
            if !lyrics.isEmpty { showLyrics = true }
            scrapeAlertMessage = String(localized: "scrape_song_success")
        } catch { scrapeAlertMessage = String(localized: "scrape_song_failed") }
    }

    private func fmt(_ t: TimeInterval) -> String {
        let s = max(0, t); return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

// MARK: - Custom Progress Slider (thin, no thumb)

struct ProgressSlider: View {
    let value: TimeInterval
    let total: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var isDragging = false
    @State private var dragValue: TimeInterval?

    private var displayValue: TimeInterval { dragValue ?? value }
    private var progress: CGFloat {
        total > 0 ? CGFloat(displayValue / total) : 0
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
                        let fraction = max(0, min(1, gesture.location.x / width))
                        dragValue = Double(fraction) * total
                    }
                    .onEnded { gesture in
                        let fraction = max(0, min(1, gesture.location.x / width))
                        let seekTime = Double(fraction) * total
                        onSeek(seekTime)
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
        let minutes = Int(t) / 60
        let seconds = Int(t) % 60
        return String(format: "%d:%02d", minutes, seconds)
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
