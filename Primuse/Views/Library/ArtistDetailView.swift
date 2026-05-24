import SwiftUI
import PrimuseKit

struct ArtistDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    let artist: Artist

    private var albums: [Album] {
        library.visibleAlbums.filter {
            $0.artistID == artist.id || $0.artistName == artist.name
        }
    }

    private var songs: [Song] {
        library.songs(forArtist: artist.id)
    }

    private var playableSongs: [Song] {
        songs.filteredPlayable()
    }

    private var visibleSongCount: Int {
        songs.count
    }

    private let columns = [
        GridItem(.adaptive(minimum: 100), spacing: 12)
    ]

    var body: some View {
        Group {
            #if os(macOS)
            ScrollView(.vertical, showsIndicators: false) {
                detailContent
                    .frame(maxWidth: 980, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.bottom, 112)
            }
            #else
            ScrollView {
                detailContent
            }
            #endif
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var detailContent: some View {
        VStack(spacing: 24) {
                #if os(macOS)
                macHeader
                #else
                iosHeader
                #endif

                if albums.isEmpty && songs.isEmpty {
                    ContentUnavailableView(
                        "no_songs",
                        systemImage: "music.mic",
                        description: Text("no_songs_desc")
                    )
                    .padding(.top, 24)
                }

                if songs.isEmpty == false {
                    MediaDetailActionBar(
                        canPlay: playableSongs.isEmpty == false,
                        canShuffle: playableSongs.count > 1,
                        playAction: playAll,
                        shuffleAction: shuffleAll
                    )
                    #if os(macOS)
                    .padding(.horizontal, 24)
                    #else
                    .padding(.bottom, 2)
                    #endif
                }

                // Albums
                if !albums.isEmpty {
                    VStack(alignment: .leading) {
                        Text("albums_section")
                            .font(.title3)
                            .fontWeight(.semibold)
                            #if os(macOS)
                            .padding(.horizontal, 24)
                            #else
                            .padding(.horizontal)
                            #endif

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(albums) { album in
                                NavigationLink(value: album) {
                                    AlbumCardView(album: album)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        #if os(macOS)
                        .padding(.horizontal, 24)
                        #else
                        .padding(.horizontal)
                        #endif
                    }
                }

                // All songs
                if !songs.isEmpty {
                    VStack(alignment: .leading) {
                        Text("all_songs_section")
                            .font(.title3)
                            .fontWeight(.semibold)
                            #if os(macOS)
                            .padding(.horizontal, 24)
                            #else
                            .padding(.horizontal)
                            #endif

                        LazyVStack(spacing: 0) {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                SongRowView(
                                    song: song,
                                    isPlaying: player.currentSong?.id == song.id,
                                    context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                                )
                                #if os(macOS)
                                .padding(.horizontal, 12)
                                #else
                                .padding(.horizontal)
                                #endif
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    playSong(song)
                                }

                                if index != songs.count - 1 {
                                    Divider()
                                    #if os(macOS)
                                        .padding(.leading, 68)
                                    #else
                                        .padding(.leading, 50)
                                    #endif
                                }
                            }
                        }
                        #if os(macOS)
                        .padding(.horizontal, 12)
                        .background(.background.secondary, in: .rect(cornerRadius: 8))
                        .padding(.horizontal, 24)
                        #endif
                    }
                }
        }
    }

    #if os(macOS)
    private var macHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            CachedArtworkView(
                artistID: artist.id,
                artistName: artist.name,
                size: 140,
                cornerRadius: 70
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(artist.name)
                    .font(.title)
                    .fontWeight(.bold)
                    .lineLimit(2)

                Text("\(albums.count) \(String(localized: "albums_count")) · \(visibleSongCount) \(String(localized: "songs_count"))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }
    #endif

    private var iosHeader: some View {
        VStack(spacing: 8) {
            CachedArtworkView(artistID: artist.id, artistName: artist.name,
                              size: 120, cornerRadius: 60)

            Text(artist.name)
                .font(.title)
                .fontWeight(.bold)

            Text("\(albums.count) \(String(localized: "albums_count")) · \(visibleSongCount) \(String(localized: "songs_count"))")
                .font(.subheadline)
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

    private func playSong(_ song: Song) {
        let queue = songs.filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        Task { await player.play(song: song) }
    }
}
