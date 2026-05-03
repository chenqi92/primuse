import SwiftUI
import PrimuseKit

struct AlbumDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    let album: Album

    private var songs: [Song] {
        library.songs(forAlbum: album.id)
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

            // Track list
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
                            showAlbum: false,
                            context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                        )
                        #if os(macOS)
                        .padding(.horizontal, 24)
                        #else
                        .padding(.horizontal)
                        #endif
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            playSong(song)
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
    /// macOS 横向 header:左封面、右元数据。比居中大封面更适合宽 detail 区,
    /// 跟 Music.app / iTunes 的专辑详情视觉对齐。
    private var macHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            CachedArtworkView(
                albumID: album.id,
                albumTitle: album.title,
                artistName: album.artistName,
                size: 180,
                cornerRadius: 10
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(album.title)
                    .font(.title)
                    .fontWeight(.bold)
                    .lineLimit(2)

                Text(album.artistName ?? String(localized: "unknown_artist"))
                    .font(.title3)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if let year = album.year {
                        Text("\(year)")
                    }
                    if album.year != nil { dotSeparator }
                    Text("\(songs.count) \(String(localized: "songs_count"))")
                    dotSeparator
                    Text(formatDuration(songs.reduce(0) { $0 + $1.duration.sanitizedDuration }))
                }
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
    }

    private var dotSeparator: some View {
        Text("·").foregroundStyle(.tertiary)
    }
    #endif

    private var iosHeader: some View {
        VStack(spacing: 12) {
            CachedArtworkView(albumID: album.id, albumTitle: album.title,
                              artistName: album.artistName,
                              size: 220, cornerRadius: 14)

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
                Text("\(songs.count) \(String(localized: "songs_count"))")
                Text(formatDuration(songs.reduce(0) { $0 + $1.duration.sanitizedDuration }))
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        duration.formattedShort
    }
}
