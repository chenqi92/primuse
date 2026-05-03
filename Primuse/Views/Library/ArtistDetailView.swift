import SwiftUI
import PrimuseKit

struct ArtistDetailView: View {
    @Environment(MusicLibrary.self) private var library
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

    private var visibleSongCount: Int {
        songs.count
    }

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 16)
    ]

    var body: some View {
        ScrollView {
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

                        LazyVGrid(columns: columns, spacing: 16) {
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
                            ForEach(songs) { song in
                                SongRowView(
                                    song: song,
                                    context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                                )
                                #if os(macOS)
                                .padding(.horizontal, 24)
                                #else
                                .padding(.horizontal)
                                #endif
                                .padding(.vertical, 8)
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
            }
        }
        .navigationBarTitleDisplayMode(.inline)
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
}
