#if os(macOS)
import SwiftUI
import PrimuseKit

/// Right-pane container. Owns its own NavigationStack so drilling into
/// AlbumDetail / ArtistDetail / PlaylistDetail still works inside the
/// macOS split view. Stack resets whenever sidebar selection changes.
struct MacDetailContainer: View {
    let route: MacRoute
    @Binding var searchText: String
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
                .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
                .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
        }
        .onChange(of: route) { _, _ in path = NavigationPath() }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .home:
            MacHomeView()
        case .search:
            SearchView(searchText: $searchText)
                .navigationTitle("search_title")
        case .section(let section):
            switch section {
            case .songs:
                SongListView(songs: library.visibleSongs)
                    .navigationTitle(section.title)
            case .albums:
                AlbumGridView()
                    .navigationTitle(section.title)
            case .artists:
                ArtistListView(artists: library.visibleArtists)
                    .navigationTitle(section.title)
            case .playlists:
                PlaylistListView()
                    .navigationTitle(section.title)
            }
        case .source(let id):
            // Sources don't yet have a per-source detail view — for now
            // route the click to the songs filtered by that source.
            let songs = library.visibleSongs.filter { $0.sourceID == id }
            let name = sourcesStore.sources.first(where: { $0.id == id })?.name ?? ""
            SongListView(songs: songs)
                .navigationTitle(Text(verbatim: name))
        }
    }
}
#endif
