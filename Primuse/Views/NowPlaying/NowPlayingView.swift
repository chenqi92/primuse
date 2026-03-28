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

    var body: some View {
        playerMode
        .background(Color(.systemBackground))
        .task(id: player.currentSong?.id) { await loadLyrics() }
        .onReceive(Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()) { _ in
            updateCurrentLine()
        }
        .sheet(isPresented: $showQueue) { QueueView() }
        .sheet(isPresented: $showScrapeOptions) {
            if let song = player.currentSong {
                ScrapeOptionsView(song: song) { updatedSong in
                    player.syncSongMetadata(updatedSong)
                    Task { await loadLyrics() }
                }
                .presentationDetents([.medium])
            }
        }
        .alert(
            String(localized: "scrape_song"),
            isPresented: Binding(
                get: { scrapeAlertMessage != nil },
                set: { if !$0 { scrapeAlertMessage = nil } }
            )
        ) {
            Button("done", role: .cancel) {}
        } message: {
            Text(scrapeAlertMessage ?? "")
        }
    }

    // MARK: - Player Mode (everything in one VStack, no gaps)

    private var playerMode: some View {
        GeometryReader { geo in
            let padding: CGFloat = 30
            let artSize = min(geo.size.width - padding * 2, geo.size.height * 0.40)

            VStack(spacing: 0) {
                // Top handle + album title
                Capsule().fill(.secondary.opacity(0.4)).frame(width: 36, height: 5)
                    .padding(.top, geo.safeAreaInsets.top > 0 ? 12 : 8).padding(.bottom, 4)
                HStack {
                    Button { onMinimize?() } label: {
                        Image(systemName: "chevron.down").font(.title3).fontWeight(.medium).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(player.currentSong?.albumTitle ?? "")
                        .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down").font(.title3).opacity(0)
                }
                .padding(.horizontal, 20).padding(.bottom, 6)

                Spacer()

                // Artwork OR Lyrics (Apple Music: lyrics replaces artwork area)
                ZStack {
                    if showLyrics {
                        inlineArtworkLyrics(height: artSize)
                            .transition(.opacity)
                    } else {
                        CachedArtworkView(coverFileName: player.currentSong?.coverArtFileName, size: artSize, cornerRadius: 12)
                            .scaleEffect(player.isPlaying ? 1.0 : 0.9)
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)
                            .transition(.opacity)
                    }
                }
                .frame(height: artSize)
                .animation(.easeInOut(duration: 0.3), value: showLyrics)
                .onTapGesture { withAnimation(.easeInOut(duration: 0.25)) { showLyrics.toggle() } }

                Spacer()

            // Song info
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentSong?.title ?? "").font(.title3).fontWeight(.bold).lineLimit(1)
                    Text(player.currentSong?.artistName ?? "").font(.body).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    Button { showQueue = true } label: { Label("queue_title", systemImage: "list.bullet") }
                    Button { showScrapeOptions = true } label: { Label("scrape_song", systemImage: "wand.and.stars") }
                        .disabled(player.currentSong == nil || isScrapingCurrentSong)
                } label: {
                    Image(systemName: "ellipsis.circle.fill").font(.title2)
                        .symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 26).padding(.top, 14)

            // Progress
            VStack(spacing: 4) {
                Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                       in: 0...max(player.duration, 0.1)).tint(.primary)
                HStack {
                    Text(fmt(player.currentTime)); Spacer()
                    Text("-\(fmt(max(0, player.duration - player.currentTime)))")
                }
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 26).padding(.top, 10)

            // Controls
            HStack(spacing: 0) {
                Spacer()
                ctrlBtn("shuffle", active: player.shuffleEnabled) { player.shuffleEnabled.toggle() }
                Spacer()
                Button { Task { await player.previous() } } label: {
                    Image(systemName: "backward.fill").font(.title)
                }.frame(width: 56, height: 56)
                Spacer()
                Button { withAnimation(.spring(response: 0.3)) { player.togglePlayPause() } } label: {
                    ZStack {
                        Circle().fill(.primary).frame(width: 64, height: 64)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title2).foregroundStyle(Color(.systemBackground))
                    }
                }
                Spacer()
                Button { Task { await player.next() } } label: {
                    Image(systemName: "forward.fill").font(.title)
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
                Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(player.audioEngine.volume) },
                    set: { player.audioEngine.volume = Float($0) }
                ), in: 0...1).tint(.secondary.opacity(0.5))
                Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 26).padding(.top, 12)

            // Bottom actions + format (directly below volume, no gap)
            HStack {
                Button { withAnimation(.easeInOut(duration: 0.25)) { showLyrics.toggle() } } label: {
                    Image(systemName: "quote.bubble").foregroundStyle(.secondary)
                }
                Spacer()
                AirPlayButton().frame(width: 36, height: 36)
                Spacer()
                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet").foregroundStyle(.secondary)
                }
            }
            .font(.body).padding(.horizontal, 46).padding(.top, 14)

            if let song = player.currentSong {
                HStack(spacing: 4) {
                    Text(song.fileFormat.displayName)
                    if let sr = song.sampleRate { Text("·"); Text("\(sr / 1000)kHz") }
                    if let bd = song.bitDepth, bd > 0 { Text("·"); Text("\(bd)bit") }
                }
                .font(.caption2).foregroundStyle(.tertiary).padding(.top, 4).padding(.bottom, 8)
            }
            }
            .padding(.bottom, geo.safeAreaInsets.bottom > 0 ? 0 : 8)
        }
    }

    // MARK: - Inline Lyrics (replaces artwork area, same size)

    private func inlineArtworkLyrics(height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary.opacity(0.3))

            if lyrics.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.quote").font(.title2).foregroundStyle(.tertiary)
                    Text("no_lyrics").font(.subheadline).foregroundStyle(.secondary)
                    Button { Task { await scrapeCurrentSong() } } label: {
                        Label("scrape_song", systemImage: "wand.and.stars").font(.caption)
                    }.buttonStyle(.bordered).disabled(isScrapingCurrentSong)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 14) {
                            Spacer().frame(height: height * 0.3)
                            ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                                Text(line.text)
                                    .font(index == currentLineIndex ? .title3 : .body)
                                    .fontWeight(index == currentLineIndex ? .bold : .regular)
                                    .foregroundStyle(index == currentLineIndex ? Color.primary : Color.secondary.opacity(0.4))
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: .infinity)
                                    .id(line.id)
                                    .onTapGesture { player.seek(to: line.timestamp) }
                            }
                            Spacer().frame(height: height * 0.3)
                        }
                        .padding(.horizontal, 16)
                    }
                    .onChange(of: currentLineIndex) { _, idx in
                        guard idx < lyrics.count else { return }
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(lyrics[idx].id, anchor: .center) }
                    }
                }
            }
        }
        .frame(width: height, height: height) // square, same as artwork
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Helpers

    private func ctrlBtn(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.body)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
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
            let u = try await scraperService.scrapeSingle(song: song, in: library)
            player.syncSongMetadata(u); await loadLyrics()
            if !lyrics.isEmpty { showLyrics = true }
            scrapeAlertMessage = String(localized: "scrape_song_success")
        } catch { scrapeAlertMessage = String(localized: "scrape_song_failed") }
    }

    private func fmt(_ t: TimeInterval) -> String {
        let s = max(0, t); return String(format: "%d:%02d", Int(s) / 60, Int(s) % 60)
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .secondaryLabel; v.activeTintColor = .systemBlue; v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
