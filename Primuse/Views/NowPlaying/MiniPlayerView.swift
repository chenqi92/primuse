import SwiftUI
import PrimuseKit

struct MiniPlayerView: View {
    var onTap: (() -> Void)? = nil
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 0) {
                // Fixed left: cover art
                CachedArtworkView(coverFileName: player.currentSong?.coverArtFileName, size: 40, cornerRadius: 8)
                    .padding(.trailing, 10)

                // Flexible middle: song title fills remaining space
                Text(player.currentSong?.title ?? "")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Fixed right: transport controls
                HStack(spacing: 4) {
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.body)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 36, height: 36)
                    }

                    Button {
                        Task { await player.next() }
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.caption)
                            .frame(width: 32, height: 32)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
