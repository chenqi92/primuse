import AVKit
import SwiftUI
import PrimuseKit

struct NowPlayingView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(\.dismiss) private var dismiss
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var lyrics: [LyricLine] = []
    @State private var currentLineIndex = 0
    @State private var isScrapingCurrentSong = false
    @State private var scrapeAlertMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Drag indicator (system-like)
            RoundedRectangle(cornerRadius: 2.5)
                .fill(.secondary.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 4)

            // Album title
            Text(player.currentSong?.albumTitle ?? "")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.bottom, 8)

            // Artwork / Lyrics toggle
            ZStack {
                if showLyrics {
                    inlineLyricsView
                        .transition(.opacity)
                } else {
                    CachedArtworkView(
                        coverFileName: player.currentSong?.coverArtFileName,
                        cornerRadius: 12
                    )
                    .padding(.horizontal, 30)
                    .scaleEffect(player.isPlaying ? 1.0 : 0.88)
                    .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showLyrics)
            .onTapGesture { withAnimation { showLyrics.toggle() } }

            Spacer().frame(height: 20)

            // Song info + menu
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.currentSong?.title ?? "")
                        .font(.title3).fontWeight(.bold).lineLimit(1)
                    Text(player.currentSong?.artistName ?? "")
                        .font(.body).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Menu {
                    Button { showQueue = true } label: {
                        Label("queue_title", systemImage: "list.bullet")
                    }
                    Button {
                        Task { await scrapeCurrentSong() }
                    } label: {
                        Label("scrape_song", systemImage: "wand.and.stars")
                    }
                    .disabled(player.currentSong == nil || isScrapingCurrentSong || scraperService.isScraping)
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 26)

            Spacer().frame(height: 16)

            // Progress
            VStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.duration, 0.1)
                )
                .tint(.primary)

                HStack {
                    Text(formatTime(player.currentTime))
                    Spacer()
                    Text("-\(formatTime(max(0, player.duration - player.currentTime)))")
                }
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 26)

            Spacer().frame(height: 20)

            // Controls
            HStack(spacing: 0) {
                Spacer()
                Button { player.shuffleEnabled.toggle() } label: {
                    Image(systemName: "shuffle").font(.body)
                        .foregroundStyle(player.shuffleEnabled ? Color.accentColor : Color.secondary)
                }.frame(width: 44, height: 44)

                Spacer()

                Button { Task { await player.previous() } } label: {
                    Image(systemName: "backward.fill").font(.title)
                }.frame(width: 60, height: 60)

                Spacer()

                Button {
                    withAnimation(.spring(response: 0.3)) { player.togglePlayPause() }
                } label: {
                    ZStack {
                        Circle().fill(.primary).frame(width: 68, height: 68)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title).foregroundStyle(Color(.systemBackground))
                    }
                }

                Spacer()

                Button { Task { await player.next() } } label: {
                    Image(systemName: "forward.fill").font(.title)
                }.frame(width: 60, height: 60)

                Spacer()

                Button {
                    switch player.repeatMode {
                    case .off: player.repeatMode = .all
                    case .all: player.repeatMode = .one
                    case .one: player.repeatMode = .off
                    }
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").font(.body)
                        .foregroundStyle(player.repeatMode != .off ? Color.accentColor : Color.secondary)
                }.frame(width: 44, height: 44)

                Spacer()
            }

            Spacer().frame(height: 20)

            // Volume
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(player.audioEngine.volume) },
                    set: { player.audioEngine.volume = Float($0) }
                ), in: 0...1).tint(.secondary.opacity(0.5))
                Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 26)

            Spacer()

            // Bottom
            HStack {
                Button { withAnimation { showLyrics.toggle() } } label: {
                    Image(systemName: showLyrics ? "text.quote" : "quote.bubble")
                        .foregroundStyle(showLyrics ? Color.accentColor : .secondary)
                }
                Spacer()
                AirPlayButton().frame(width: 36, height: 36)
                Spacer()
                Button { showQueue = true } label: {
                    Image(systemName: "list.bullet").foregroundStyle(.secondary)
                }
            }
            .font(.body)
            .padding(.horizontal, 46)
            .padding(.bottom, 8)

            // Format
            if let song = player.currentSong {
                HStack(spacing: 4) {
                    Text(song.fileFormat.displayName)
                    if let sr = song.sampleRate { Text("·"); Text("\(sr / 1000)kHz") }
                    if let bd = song.bitDepth, bd > 0 { Text("·"); Text("\(bd)bit") }
                }
                .font(.caption2).foregroundStyle(.tertiary).padding(.bottom, 6)
            }
        }
        .background(Color(.systemBackground))
        .task(id: player.currentSong?.id) {
            await loadLyrics()
        }
        .onReceive(Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()) { _ in
            updateCurrentLine()
        }
        .sheet(isPresented: $showQueue) { QueueView() }
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

    // MARK: - Inline Lyrics

    private var inlineLyricsView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    if lyrics.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "text.quote")
                                .font(.title).foregroundStyle(.tertiary)
                            Text("no_lyrics")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button {
                                Task { await scrapeCurrentSong() }
                            } label: {
                                Label("scrape_song", systemImage: "wand.and.stars")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isScrapingCurrentSong || scraperService.isScraping)
                        }
                        .padding(.top, 60)
                    } else {
                        ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, line in
                            Text(line.text)
                                .font(.title3)
                                .fontWeight(index == currentLineIndex ? .bold : .regular)
                                .foregroundStyle(index == currentLineIndex ? .primary : .secondary)
                                .multilineTextAlignment(.center)
                                .id(line.id)
                                .onTapGesture { player.seek(to: line.timestamp) }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .onChange(of: currentLineIndex) { _, newIndex in
                guard newIndex < lyrics.count else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(lyrics[newIndex].id, anchor: .center)
                }
            }
        }
        .frame(maxHeight: UIScreen.main.bounds.width - 60)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.3)))
        .padding(.horizontal, 30)
    }

    // MARK: - Lyrics Loading

    private func loadLyrics() async {
        guard let song = player.currentSong else { lyrics = []; return }
        lyrics = await MetadataAssetStore.shared.lyrics(named: song.lyricsFileName) ?? []
        currentLineIndex = 0
    }

    private func updateCurrentLine() {
        guard !lyrics.isEmpty else { return }
        let time = player.currentTime
        for (index, line) in lyrics.enumerated().reversed() {
            if time >= line.timestamp {
                if currentLineIndex != index { currentLineIndex = index }
                break
            }
        }
    }

    private func scrapeCurrentSong() async {
        guard let song = player.currentSong else { return }

        isScrapingCurrentSong = true
        defer { isScrapingCurrentSong = false }

        do {
            let updatedSong = try await scraperService.scrapeSingle(song: song, in: library)
            player.syncSongMetadata(updatedSong)
            await loadLyrics()
            if lyrics.isEmpty == false {
                showLyrics = true
            }
            scrapeAlertMessage = String(localized: "scrape_song_success")
        } catch {
            scrapeAlertMessage = String(localized: "scrape_song_failed")
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let t = max(0, time)
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .secondaryLabel
        v.activeTintColor = .systemBlue
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
