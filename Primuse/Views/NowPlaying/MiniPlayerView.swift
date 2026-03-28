import SwiftUI
import PrimuseKit

struct MiniPlayerView: View {
    @Environment(AudioPlayerService.self) private var player
    @State private var progressWidth: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator at top
            GeometryReader { geometry in
                let progress = player.duration > 0 ? player.currentTime / player.duration : 0
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geometry.size.width * CGFloat(progress), height: 2)
                    .animation(.linear(duration: 0.5), value: player.currentTime)
            }
            .frame(height: 2)

            HStack(spacing: 12) {
                // Cover art with play indicator
                ZStack(alignment: .bottomTrailing) {
                    CachedArtworkView(coverFileName: player.currentSong?.coverArtFileName, size: 44, cornerRadius: 8)

                    if player.isPlaying {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative)
                            .font(.system(size: 8))
                            .foregroundStyle(.white)
                            .padding(2)
                            .background(Color.accentColor)
                            .clipShape(Circle())
                            .offset(x: 3, y: 3)
                    }
                }

                // Song info
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.currentSong?.title ?? "")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    Text(player.currentSong?.artistName ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                // Controls
                HStack(spacing: 16) {
                    Button {
                        withAnimation(.spring(response: 0.3)) {
                            player.togglePlayPause()
                        }
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 32, height: 32)
                    }

                    Button {
                        Task { await player.next() }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.body)
                            .frame(width: 32, height: 32)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}
