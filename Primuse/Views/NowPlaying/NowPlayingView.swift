import SwiftUI
import PrimuseKit
import AVKit

struct NowPlayingView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var showLyrics = false
    @State private var showQueue = false
    @State private var artworkScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Blurred background
            backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Drag indicator
                Capsule()
                    .fill(.white.opacity(0.4))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)

                Spacer().frame(height: 20)

                // Album Artwork with animation
                ArtworkView(data: nil, cornerRadius: 14)
                    .padding(.horizontal, 44)
                    .scaleEffect(player.isPlaying ? 1.0 : 0.88)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: player.isPlaying)

                Spacer().frame(height: 28)

                // Song Info + Menu
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(player.currentSong?.title ?? String(localized: "unknown_title"))
                            .font(.title3)
                            .fontWeight(.bold)
                            .lineLimit(1)

                        Text(player.currentSong?.artistName ?? String(localized: "unknown_artist"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Menu {
                        Button {
                            showQueue = true
                        } label: {
                            Label("queue_title", systemImage: "list.bullet")
                        }
                        Button {
                            showLyrics = true
                        } label: {
                            Label("lyrics_title", systemImage: "quote.bubble")
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

                Spacer().frame(height: 20)

                // Progress Bar
                VStack(spacing: 6) {
                    ProgressSlider(
                        value: Binding(
                            get: { player.currentTime },
                            set: { player.seek(to: $0) }
                        ),
                        total: max(player.duration, 1)
                    )

                    HStack {
                        Text(formatTime(player.currentTime))
                        Spacer()
                        Text("-\(formatTime(max(0, player.duration - player.currentTime)))")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                .padding(.horizontal, 30)

                Spacer().frame(height: 24)

                // Playback Controls
                HStack(spacing: 0) {
                    Spacer()

                    Button {
                        player.shuffleEnabled.toggle()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.body)
                            .foregroundStyle(player.shuffleEnabled ? Color.accentColor : Color.secondary)
                    }
                    .frame(width: 44, height: 44)

                    Spacer()

                    Button {
                        Task { await player.previous() }
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.title2)
                    }
                    .frame(width: 56, height: 56)

                    Spacer()

                    // Main play/pause
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            player.togglePlayPause()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.primary)
                                .frame(width: 68, height: 68)
                            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title)
                                .foregroundStyle(Color(.systemBackground))
                        }
                    }

                    Spacer()

                    Button {
                        Task { await player.next() }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title2)
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
                        Image(systemName: repeatIcon)
                            .font(.body)
                            .foregroundStyle(player.repeatMode != .off ? Color.accentColor : Color.secondary)
                    }
                    .frame(width: 44, height: 44)

                    Spacer()
                }
                .padding(.horizontal, 10)

                Spacer().frame(height: 24)

                // Volume slider
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: .constant(0.7), in: 0...1)
                        .tint(.secondary.opacity(0.6))
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 30)

                Spacer().frame(height: 20)

                // Bottom bar
                HStack {
                    Button {
                        showLyrics = true
                    } label: {
                        Image(systemName: "quote.bubble")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    AirPlayButton()
                        .frame(width: 28, height: 28)

                    Spacer()

                    Button {
                        showQueue = true
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 50)
                .padding(.bottom, 16)

                // Format badge
                if let song = player.currentSong {
                    HStack(spacing: 6) {
                        if song.fileFormat.isLossless {
                            Image(systemName: "waveform")
                                .font(.system(size: 9))
                        }
                        Text(song.fileFormat.displayName)
                        if let sr = song.sampleRate {
                            Text("·")
                            Text("\(sr / 1000)kHz")
                        }
                        if let bd = song.bitDepth, bd > 0 {
                            Text("·")
                            Text("\(bd)bit")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
                }
            }
        }
        .presentationDragIndicator(.hidden)
        .sheet(isPresented: $showLyrics) {
            LyricsView()
        }
        .sheet(isPresented: $showQueue) {
            QueueView()
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(.systemBackground),
                Color(.systemBackground).opacity(0.95),
                Color.purple.opacity(0.08),
            ],
            startPoint: .top,
            endPoint: .bottom
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
        let minutes = Int(t) / 60
        let seconds = Int(t) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Custom Progress Slider

struct ProgressSlider: View {
    @Binding var value: TimeInterval
    let total: TimeInterval
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progress = CGFloat(value / total)
            let fillWidth = min(width * progress, width)

            ZStack(alignment: .leading) {
                // Track
                Capsule()
                    .fill(.secondary.opacity(0.2))
                    .frame(height: isDragging ? 8 : 4)

                // Fill
                Capsule()
                    .fill(.primary)
                    .frame(width: fillWidth, height: isDragging ? 8 : 4)

                // Thumb (only when dragging)
                if isDragging {
                    Circle()
                        .fill(.primary)
                        .frame(width: 14, height: 14)
                        .offset(x: fillWidth - 7)
                }
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        withAnimation(.easeOut(duration: 0.1)) { isDragging = true }
                        let ratio = gesture.location.x / width
                        value = max(0, min(total, TimeInterval(ratio) * total))
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.2)) { isDragging = false }
                    }
            )
        }
        .frame(height: 14)
        .animation(.easeOut(duration: 0.15), value: isDragging)
    }
}

// MARK: - AirPlay Button

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let routePickerView = AVRoutePickerView()
        routePickerView.tintColor = .secondaryLabel
        routePickerView.activeTintColor = .systemBlue
        return routePickerView
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
