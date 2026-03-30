import SwiftUI
import PrimuseKit

struct PlaylistDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    let playlist: Playlist

    private var currentPlaylist: Playlist? {
        library.playlist(id: playlist.id)
    }

    private var songs: [Song] {
        library.songs(forPlaylist: playlist.id)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Playlist header
                VStack(spacing: 8) {
                    StoredCoverArtView(
                        fileName: currentPlaylist?.coverArtPath,
                        size: 180,
                        cornerRadius: 14
                    )

                    Text(currentPlaylist?.name ?? playlist.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("\(songs.count) \(String(localized: "songs_count"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Action buttons
                HStack(spacing: 16) {
                    Button {
                        playAll()
                    } label: {
                        Label("play_all", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        player.shuffleEnabled = true
                        playAll()
                    } label: {
                        Label("shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                // Songs
                LazyVStack(spacing: 0) {
                    ForEach(songs) { song in
                        SongRowView(
                            song: song,
                            isPlaying: player.currentSong?.id == song.id,
                            showsActions: false
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .onTapGesture { playSong(song) }
                        .contextMenu {
                            Button(role: .destructive) {
                                library.remove(songID: song.id, fromPlaylist: playlist.id)
                            } label: {
                                Label("remove_from_playlist", systemImage: "trash")
                            }
                        }

                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func playAll() {
        guard let first = songs.first else { return }
        player.setQueue(songs, startAt: 0)
        Task { await player.play(song: first) }
    }

    private func playSong(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(songs, startAt: index)
        Task { await player.play(song: song) }
    }
}
