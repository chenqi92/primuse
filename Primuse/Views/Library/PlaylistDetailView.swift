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
            #if os(macOS)
            macHeader
            #else
            iosHeader
            #endif

            // Action buttons
            if songs.isEmpty == false {
                MediaDetailActionBar(
                    canPlay: playableSongs.isEmpty == false,
                    canShuffle: playableSongs.count > 1,
                    playAction: playAll,
                    shuffleAction: shuffleAll
                )
                #if os(macOS)
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                #else
                .padding(.bottom, 8)
                #endif
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
                        #if os(macOS)
                        .padding(.horizontal, 24)
                        #else
                        .padding(.horizontal)
                        #endif
                        .padding(.vertical, 8)
                        .onTapGesture { playSong(song) }
                        .contextMenu {
                            Button(role: .destructive) {
                                library.remove(songID: song.id, fromPlaylist: playlist.id)
                            } label: {
                                Label("remove_from_playlist", systemImage: "trash")
                            }
                        }

                        Divider()
                            #if os(macOS)
                            .padding(.leading, 24 + 50)
                            #else
                            .padding(.leading, 50)
                            #endif
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    #if os(macOS)
    private var macHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            StoredCoverArtView(
                fileName: currentPlaylist?.coverArtPath,
                size: 180,
                cornerRadius: 10
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(currentPlaylist?.name ?? playlist.name)
                    .font(.title)
                    .fontWeight(.bold)
                    .lineLimit(2)

                Text("\(songs.count) \(String(localized: "songs_count"))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }
    #endif

    private var iosHeader: some View {
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
