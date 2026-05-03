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
                // Artist header
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
                            .padding(.horizontal)

                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(albums) { album in
                                NavigationLink(value: album) {
                                    AlbumCardView(album: album)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                // All songs
                if !songs.isEmpty {
                    VStack(alignment: .leading) {
                        Text("all_songs_section")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .padding(.horizontal)

                        LazyVStack(spacing: 0) {
                            ForEach(songs) { song in
                                SongRowView(
                                    song: song,
                                    context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                                )
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                                Divider().padding(.leading, 50)
                            }
                        }
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
