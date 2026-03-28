import AVKit
import SwiftUI
import PrimuseKit

struct NowPlayingView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var showLyrics = false
    @State private var showQueue = false

    var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag indicator
                Capsule()
                    .fill(.white.opacity(0.4))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)

                Spacer().frame(height: 16)

                // Artwork / Lyrics toggle area
                ZStack {
                    if showLyrics {
                        lyricsContentView
                            .transition(.opacity)
                    } else {
                        artworkView
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: showLyrics)
                .onTapGesture {
                    withAnimation { showLyrics.toggle() }
                }

                Spacer().frame(height: 20)

                // Song Info
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.currentSong?.title ?? String(localized: "unknown_title"))
                            .font(.title3).fontWeight(.bold).lineLimit(1)
                        Text(player.currentSong?.artistName ?? String(localized: "unknown_artist"))
                            .font(.body).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        Button { showQueue = true } label: {
                            Label("queue_title", systemImage: "list.bullet")
                        }
                        if let song = player.currentSong {
                            Section {
                                Label(song.fileFormat.displayName, systemImage: "waveform")
                                if let sr = song.sampleRate {
                                    Label("\(sr)Hz", systemImage: "dial.low")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 30)

                Spacer().frame(height: 16)

                // Progress slider
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
                .padding(.horizontal, 30)

                Spacer().frame(height: 20)

                // Playback Controls
                playbackControls

                Spacer().frame(height: 20)

                // Volume
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(player.audioEngine.volume) },
                        set: { player.audioEngine.volume = Float($0) }
                    ), in: 0...1)
                    .tint(.secondary.opacity(0.6))
                    Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 30)

                Spacer().frame(height: 16)

                // Bottom bar
                HStack {
                    // Lyrics toggle indicator
                    Button {
                        withAnimation { showLyrics.toggle() }
                    } label: {
                        Image(systemName: showLyrics ? "text.quote" : "quote.bubble")
                            .font(.body)
                            .foregroundStyle(showLyrics ? Color.accentColor : .secondary)
                    }

                    Spacer()
                    AirPlayButton().frame(width: 28, height: 28)
                    Spacer()

                    Button { showQueue = true } label: {
                        Image(systemName: "list.bullet")
                            .font(.body).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 50)
                .padding(.bottom, 12)

                // Format badge
                if let song = player.currentSong {
                    HStack(spacing: 6) {
                        if song.fileFormat.isLossless {
                            Image(systemName: "waveform").font(.system(size: 9))
                        }
                        Text(song.fileFormat.displayName)
                        if let sr = song.sampleRate {
                            Text("·"); Text("\(sr / 1000)kHz")
                        }
                        if let bd = song.bitDepth, bd > 0 {
                            Text("·"); Text("\(bd)bit")
                        }
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
                }
            }
        }
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showQueue) {
            QueueView()
        }
    }

    // MARK: - Artwork

    private var artworkView: some View {
        ArtworkView(data: nil, cornerRadius: 14)
            .padding(.horizontal, 44)
            .scaleEffect(player.isPlaying ? 1.0 : 0.88)
            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)
    }

    // MARK: - Inline Lyrics (replaces artwork when tapped)

    private var lyricsContentView: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Show lyrics or no-lyrics placeholder
                let lyrics = loadLyrics()
                if lyrics.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "text.quote")
                            .font(.title)
                            .foregroundStyle(.tertiary)
                        Text("no_lyrics")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ForEach(lyrics) { line in
                        Text(line.text)
                            .font(.body)
                            .fontWeight(isCurrentLine(line) ? .bold : .regular)
                            .foregroundStyle(isCurrentLine(line) ? .primary : .secondary)
                            .multilineTextAlignment(.center)
                            .onTapGesture {
                                player.seek(to: line.timestamp)
                            }
                    }
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 20)
        }
        .frame(maxHeight: UIScreen.main.bounds.width - 88) // Same height as artwork
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 44)
    }

    private func loadLyrics() -> [LyricLine] {
        // TODO: load from sidecar or cached lyrics
        return []
    }

    private func isCurrentLine(_ line: LyricLine) -> Bool {
        guard let nextIndex = loadLyrics().firstIndex(where: { $0.timestamp > player.currentTime }) else {
            return false
        }
        let currentIndex = max(0, nextIndex - 1)
        return loadLyrics()[currentIndex].id == line.id
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        HStack(spacing: 0) {
            Spacer()
            Button { player.shuffleEnabled.toggle() } label: {
                Image(systemName: "shuffle").font(.body)
                    .foregroundStyle(player.shuffleEnabled ? Color.accentColor : Color.secondary)
            }
            .frame(width: 44, height: 44)

            Spacer()

            Button { Task { await player.previous() } } label: {
                Image(systemName: "backward.fill").font(.title2)
            }
            .frame(width: 56, height: 56)

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
                Image(systemName: "forward.fill").font(.title2)
            }
            .frame(width: 56, height: 56)

            Spacer()

            Button {
                switch player.repeatMode {
                case .off: player.repeatMode = .all
                case .all: player.repeatMode = .one
                case .one: player.repeatMode = .off
                }
            } label: {
                Image(systemName: repeatIcon).font(.body)
                    .foregroundStyle(player.repeatMode != .off ? Color.accentColor : Color.secondary)
            }
            .frame(width: 44, height: 44)

            Spacer()
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Helpers

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(.systemBackground), Color(.systemBackground).opacity(0.95), Color.purple.opacity(0.08)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var repeatIcon: String {
        switch player.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let t = max(0, time)
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - AirPlay

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = AVRoutePickerView()
        v.tintColor = .secondaryLabel
        v.activeTintColor = .systemBlue
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
