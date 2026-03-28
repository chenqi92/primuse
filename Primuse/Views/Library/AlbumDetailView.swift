import SwiftUI
import PrimuseKit

struct AlbumDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    let album: Album

    private var songs: [Song] {
        library.songs(forAlbum: album.id)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Album header
                VStack(spacing: 12) {
                    StoredCoverArtView(
                        fileName: songs.first?.coverArtFileName,
                        size: 220,
                        cornerRadius: 14
                    )

                    Text(album.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)

                    Text(album.artistName ?? String(localized: "unknown_artist"))
                        .font(.body)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        if let year = album.year {
                            Text("\(year)")
                        }
                        Text("\(album.songCount) \(String(localized: "songs_count"))")
                        Text(formatDuration(album.totalDuration))
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                        shuffleAll()
                    } label: {
                        Label("shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)

                // Track list
                LazyVStack(spacing: 0) {
                    ForEach(songs) { song in
                        SongRowView(
                            song: song,
                            isPlaying: player.currentSong?.id == song.id,
                            showAlbum: false
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            playSong(song)
                        }

                        Divider()
                            .padding(.leading, 50)
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

    private func shuffleAll() {
        player.shuffleEnabled = true
        playAll()
    }

    private func playSong(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(songs, startAt: index)
        Task { await player.play(song: song) }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
