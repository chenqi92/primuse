import SwiftUI
import PrimuseKit

struct SongRowView: View {
    @Environment(MusicLibrary.self) private var library
    let song: Song
    var isPlaying: Bool = false
    var showAlbum: Bool = true
    var showsPlaylistActions: Bool = true

    @State private var showCreatePlaylistAlert = false
    @State private var playlistName = ""

    var body: some View {
        HStack(spacing: 12) {
            // Playing indicator
            Group {
                if isPlaying {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative)
                        .foregroundStyle(.tint)
                } else {
                    Image(systemName: "music.note")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20)
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

            // Format badge (all formats)
            Text(song.fileFormat.displayName)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .foregroundStyle(song.fileFormat.isLossless ? Color.blue : Color.secondary)
                .background(song.fileFormat.isLossless ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 3))

            // Duration
            Text(formatDuration(song.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if showsPlaylistActions {
                Menu {
                    if library.playlists.isEmpty == false {
                        ForEach(library.playlists) { playlist in
                            let isIncluded = library.contains(songID: song.id, inPlaylist: playlist.id)
                            Button {
                                if isIncluded == false {
                                    library.add(songID: song.id, toPlaylist: playlist.id)
                                }
                            } label: {
                                Label(
                                    playlist.name,
                                    systemImage: isIncluded ? "checkmark.circle.fill" : "plus.circle"
                                )
                            }
                            .disabled(isIncluded)
                        }

                        Divider()
                    }

                    Button {
                        showCreatePlaylistAlert = true
                    } label: {
                        Label("new_playlist", systemImage: "text.badge.plus")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
        .alert("new_playlist", isPresented: $showCreatePlaylistAlert) {
            TextField("playlist_name", text: $playlistName)
            Button("cancel", role: .cancel) {
                playlistName = ""
            }
            Button("create") {
                createPlaylistAndAddSong()
            }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func createPlaylistAndAddSong() {
        let trimmedName = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else { return }
        let playlist = library.createPlaylist(name: trimmedName)
        library.add(songID: song.id, toPlaylist: playlist.id)
        playlistName = ""
    }
}
