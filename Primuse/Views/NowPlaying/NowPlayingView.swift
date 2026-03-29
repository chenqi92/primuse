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
    @State private var dominantColor: Color = Color(red: 0.15, green: 0.1, blue: 0.2)

    var body: some View {
        GeometryReader { geo in
            let artSize = min(geo.size.width - 60, geo.size.height * 0.38)

            ZStack {
                // Dynamic background from cover colors
                backgroundGradient.ignoresSafeArea()

                VStack(spacing: 0) {
                    // System-style grabber
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.white.opacity(0.3))
                        .frame(width: 36, height: 5)
                        .padding(.top, 8)
                        .padding(.bottom, 10)

                    if showLyrics {
                        // LYRICS MODE: full screen lyrics
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

                    // Song info
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(player.currentSong?.title ?? "")
                                .font(.title3).fontWeight(.bold).lineLimit(1)
                                .foregroundStyle(.white)
                            Text(player.currentSong?.artistName ?? "")
                                .font(.body).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                        Spacer()
                        Menu {
                            Button { showQueue = true } label: { Label("queue_title", systemImage: "list.bullet") }
                            Button { showScrapeOptions = true } label: { Label("scrape_song", systemImage: "wand.and.stars") }
                                .disabled(player.currentSong == nil || isScrapingCurrentSong)
                        } label: {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.title2).symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .padding(.horizontal, 26).padding(.top, 12)

                    // Progress
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                               in: 0...max(player.duration, 0.1)).tint(.white)
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
                        Slider(value: Binding(
                            get: { Double(player.audioEngine.volume) },
                            set: { player.audioEngine.volume = Float($0) }
                        ), in: 0...1).tint(.white.opacity(0.4))
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
        .alert(String(localized: "scrape_song"),
               isPresented: Binding(get: { scrapeAlertMessage != nil }, set: { if !$0 { scrapeAlertMessage = nil } })) {
            Button("done", role: .cancel) {}
        } message: { Text(scrapeAlertMessage ?? "") }
    }

    // MARK: - Background gradient from cover dominant color

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [dominantColor, dominantColor.opacity(0.6), .black],
            startPoint: .top, endPoint: .bottom
        )
        .animation(.easeInOut(duration: 0.5), value: dominantColor.description)
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
        extractCoverColor(from: song.coverArtFileName)
    }

    private func extractCoverColor(from fileName: String?) {
        guard let fileName, !fileName.isEmpty else {
            dominantColor = Color(red: 0.15, green: 0.1, blue: 0.2)
            return
        }

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("primuse_covers")
        let url = cacheDir.appendingPathComponent(fileName)

        // Also check MetadataAssets/artwork
        let artworkDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Primuse/MetadataAssets/artwork")
        let artworkUrl = artworkDir.appendingPathComponent(fileName)

        let fileURL = FileManager.default.fileExists(atPath: url.path) ? url
            : FileManager.default.fileExists(atPath: artworkUrl.path) ? artworkUrl : nil

        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            dominantColor = Color(red: 0.15, green: 0.1, blue: 0.2)
            return
        }

        // Downsample to 1x1 pixel to get average color
        let size = CGSize(width: 4, height: 4)
        UIGraphicsBeginImageContextWithOptions(size, true, 1)
        image.draw(in: CGRect(origin: .zero, size: size))
        let smallImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let cgImage = smallImage?.cgImage,
              let dataProvider = cgImage.dataProvider,
              let pixelData = dataProvider.data else {
            dominantColor = Color(red: 0.15, green: 0.1, blue: 0.2)
            return
        }

        let data2: UnsafePointer<UInt8> = CFDataGetBytePtr(pixelData)
        // Sample the center pixel area
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        let sampleCount = 16 // 4x4
        for i in 0..<sampleCount {
            let offset = i * 4
            r += CGFloat(data2[offset])
            g += CGFloat(data2[offset + 1])
            b += CGFloat(data2[offset + 2])
        }
        r /= CGFloat(sampleCount) * 255.0
        g /= CGFloat(sampleCount) * 255.0
        b /= CGFloat(sampleCount) * 255.0

        // Darken slightly for better readability with white text
        let darken: CGFloat = 0.6
        dominantColor = Color(red: r * darken, green: g * darken, blue: b * darken)
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
        v.tintColor = UIColor.white.withAlphaComponent(0.5)
        v.activeTintColor = .white
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
