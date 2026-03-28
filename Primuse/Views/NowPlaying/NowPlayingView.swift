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
        GeometryReader { geo in
            ZStack {
                // Background — dark gradient (Apple Music style)
                Color.black.ignoresSafeArea()
                LinearGradient(
                    colors: [Color.purple.opacity(0.35), Color.black],
                    startPoint: .top, endPoint: .center
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Top bar
                    topBar

                    Spacer().frame(height: 12)

                    // Artwork / Lyrics toggle
                    ZStack {
                        if showLyrics {
                            lyricsContentView(height: geo.size.width - 60)
                                .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        } else {
                            CachedArtworkView(
                                coverFileName: player.currentSong?.coverArtFileName,
                                cornerRadius: 12
                            )
                            .padding(.horizontal, 30)
                            .scaleEffect(player.isPlaying ? 1.0 : 0.9)
                            .shadow(color: .black.opacity(0.5), radius: 30, y: 15)
                            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: showLyrics)
                    .onTapGesture { withAnimation { showLyrics.toggle() } }

                    Spacer().frame(height: 24)

                    // Song info
                    songInfoBar

                    Spacer().frame(height: 16)

                    // Progress
                    progressBar

                    Spacer().frame(height: 20)

                    // Controls
                    playbackControls

                    Spacer().frame(height: 20)

                    // Volume
                    volumeBar

                    Spacer()

                    // Bottom actions
                    bottomBar

                    // Format info
                    formatBadge
                }
                .padding(.horizontal, 4)
            }
        }
        .foregroundStyle(.white)
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showQueue) { QueueView() }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            VStack(spacing: 1) {
                Text(player.currentSong?.albumTitle ?? "")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            Menu {
                Button { showQueue = true } label: { Label("queue_title", systemImage: "list.bullet") }
                // Scrape current song
                Button {
                    // TODO: trigger scrape for current song
                } label: { Label("scrape_song", systemImage: "wand.and.stars") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }

    // MARK: - Song Info

    private var songInfoBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(player.currentSong?.title ?? "")
                    .font(.title3)
                    .fontWeight(.bold)
                    .lineLimit(1)
                Text(player.currentSong?.artistName ?? "")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 26)
    }

    // MARK: - Progress

    private var progressBar: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.1)
            )
            .tint(.white)

            HStack {
                Text(formatTime(player.currentTime))
                Spacer()
                Text("-\(formatTime(max(0, player.duration - player.currentTime)))")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.5))
            .monospacedDigit()
        }
        .padding(.horizontal, 26)
    }

    // MARK: - Playback Controls

    private var playbackControls: some View {
        HStack(spacing: 0) {
            Spacer()

            Button { player.shuffleEnabled.toggle() } label: {
                Image(systemName: "shuffle")
                    .font(.body)
                    .foregroundStyle(player.shuffleEnabled ? .white : .white.opacity(0.4))
            }
            .frame(width: 44, height: 44)

            Spacer()

            Button { Task { await player.previous() } } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }
            .frame(width: 60, height: 60)

            Spacer()

            Button {
                withAnimation(.spring(response: 0.3)) { player.togglePlayPause() }
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
            }

            Spacer()

            Button { Task { await player.next() } } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .foregroundStyle(.white)
            }
            .frame(width: 60, height: 60)

            Spacer()

            Button {
                switch player.repeatMode {
                case .off: player.repeatMode = .all
                case .all: player.repeatMode = .one
                case .one: player.repeatMode = .off
                }
            } label: {
                Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.body)
                    .foregroundStyle(player.repeatMode != .off ? .white : .white.opacity(0.4))
            }
            .frame(width: 44, height: 44)

            Spacer()
        }
    }

    // MARK: - Volume

    private var volumeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
            Slider(value: Binding(
                get: { Double(player.audioEngine.volume) },
                set: { player.audioEngine.volume = Float($0) }
            ), in: 0...1)
            .tint(.white.opacity(0.5))
            Image(systemName: "speaker.wave.3.fill")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 26)
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        HStack {
            Button { withAnimation { showLyrics.toggle() } } label: {
                Image(systemName: showLyrics ? "text.quote" : "quote.bubble")
                    .foregroundStyle(showLyrics ? .white : .white.opacity(0.5))
            }
            Spacer()
            AirPlayButton().frame(width: 28, height: 28)
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet")
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .font(.body)
        .padding(.horizontal, 46)
        .padding(.bottom, 8)
    }

    private var formatBadge: some View {
        Group {
            if let song = player.currentSong {
                HStack(spacing: 4) {
                    Text(song.fileFormat.displayName)
                    if let sr = song.sampleRate {
                        Text("·"); Text("\(sr / 1000)kHz")
                    }
                    if let bd = song.bitDepth, bd > 0 {
                        Text("·"); Text("\(bd)bit")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.3))
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Inline Lyrics

    private func lyricsContentView(height: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("no_lyrics")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.top, 60)
                Text("tap_to_scrape")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.2))
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.05))
        )
        .padding(.horizontal, 30)
    }

    // MARK: - Helpers

    private func formatTime(_ time: TimeInterval) -> String {
        let t = max(0, time)
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - AirPlay

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor.white.withAlphaComponent(0.5)
        v.activeTintColor = .white
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
