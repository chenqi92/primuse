import SwiftUI
import PrimuseKit

struct PlaylistDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    let playlist: Playlist
    @State private var songs: [Song] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Playlist header
                VStack(spacing: 8) {
                    CoverArtView(data: nil, size: 180, cornerRadius: 14)

                    Text(playlist.name)
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
                            isPlaying: player.currentSong?.id == song.id
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .onTapGesture { playSong(song) }

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
        if let url = URL(string: first.filePath) {
            Task { await player.play(song: first, from: url) }
        }
    }

    private func playSong(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(songs, startAt: index)
        if let url = URL(string: song.filePath) {
            Task { await player.play(song: song, from: url) }
        }
    }
}
