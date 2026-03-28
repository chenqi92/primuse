import SwiftUI
import PrimuseKit

struct SongRowView: View {
    let song: Song
    var isPlaying: Bool = false
    var showAlbum: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            // Track number or playing indicator
            Group {
                if isPlaying {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative)
                        .foregroundStyle(.tint)
                } else if let trackNumber = song.trackNumber {
                    Text("\(trackNumber)")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24)
            .font(.caption)

            // Song info
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)

                HStack(spacing: 4) {
                    if let artist = song.artistName {
                        Text(artist)
                    }
                    if showAlbum, let album = song.albumTitle {
                        Text("·")
                        Text(album)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            // Format badge
            if song.fileFormat.isLossless {
                Text(song.fileFormat.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            // Duration
            Text(formatDuration(song.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
