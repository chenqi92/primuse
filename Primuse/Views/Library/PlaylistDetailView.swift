import SwiftUI
import PrimuseKit

struct PlaylistDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    let playlist: Playlist

    private var currentPlaylist: Playlist? {
        library.playlist(id: playlist.id)
    }

    private var songs: [Song] {
        library.songs(forPlaylist: playlist.id)
    }

    private var playableSongs: [Song] {
        songs.filteredPlayable()
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
                if songs.isEmpty == false {
                    MediaDetailActionBar(
                        canPlay: playableSongs.isEmpty == false,
                        canShuffle: playableSongs.count > 1,
                        playAction: playAll,
                        shuffleAction: shuffleAll
                    )
                }

                // Songs
                if songs.isEmpty {
                    ContentUnavailableView(
                        "no_songs",
                        systemImage: "music.note",
                        description: Text("no_songs_desc")
                    )
                    .padding(.top, 24)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(songs) { song in
                            SongRowView(
                                song: song,
                                isPlaying: player.currentSong?.id == song.id,
                                showsActions: false,
                                context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
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
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func playAll() {
        let queue = playableSongs
        guard let first = queue.first else { return }
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }

    private func shuffleAll() {
        player.shuffleEnabled = true
        playAll()
    }

    private func playSong(_ song: Song) {
        let queue = playableSongs
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        Task { await player.play(song: song) }
    }
}
