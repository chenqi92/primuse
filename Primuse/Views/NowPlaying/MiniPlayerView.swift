import SwiftUI
import PrimuseKit

struct MiniPlayerView: View {
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        HStack(spacing: 10) {
            // Cover art
            CachedArtworkView(coverFileName: player.currentSong?.coverArtFileName, size: 40, cornerRadius: 8)

            // Song info
            VStack(alignment: .leading, spacing: 1) {
                Text(player.currentSong?.title ?? "")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(player.currentSong?.artistName ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Play/Pause
            Button {
                player.togglePlayPause()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.body)
                    .contentTransition(.symbolEffect(.replace))
            }

            // Next
            Button {
                Task { await player.next() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Progress bar at bottom
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                let progress = player.duration > 0 ? player.currentTime / player.duration : 0
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, progress))), height: 2)
            }
            .frame(height: 2)
        }
    }
}
