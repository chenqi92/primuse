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
                .id(route.stableID)
                .transaction { transaction in
                    transaction.animation = nil
                }
                .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
                .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
                .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
                // 隐藏 NavigationStack 顶部的原生 toolbar 区域 — 我们用 PMTitleBar
                // 自定义了全局 titlebar, 子视图里的 .toolbar/.searchable 不应再
                // 叠出第二条系统 bar (会出现 "搜索歌曲" + 排序按钮悬空在最顶)。
                .toolbar(.hidden, for: .windowToolbar)
        }
        .onChange(of: route) { _, _ in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                path = NavigationPath()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseDetailGoBack)) { _ in
            if !path.isEmpty { path.removeLast() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseSelectPlaylists)) { _ in
            // 删除当前歌单后跳「歌单」总览。若这张歌单是 push 进来的 (从总览点入),
            // 选中路由没变, onChange 不触发, 详情栈里还压着它的空详情 — 这里主动
            // 清栈, 保证回到干净的总览。
            guard !path.isEmpty else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                path = NavigationPath()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseDetailOpenAlbum)) { note in
            guard let album = note.object as? Album else { return }
            pushAlbum(album)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseDetailOpenArtist)) { note in
            guard let artist = note.object as? Artist else { return }
            pushArtist(artist)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .home:
            MacHomeView()
        case .stats:
            ListeningStatsView()
        case .sources:
            MacSourcesView()
                .navigationTitle("sources_title")
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
        case .liked:
            PlaylistDetailView(
                playlist: library.playlists.first(where: { $0.id == MusicLibrary.likedSongsPlaylistID })
                    ?? Playlist(id: MusicLibrary.likedSongsPlaylistID, name: String(localized: "playlist_liked_name"))
            )
            .navigationTitle("playlist_liked_name")
        case .playlist(let playlist):
            PlaylistDetailView(playlist: playlist)
                .navigationTitle(Text(verbatim: playlist.name))
        case .smartPlaylist(let smart):
            SmartPlaylistDetailView(smartPlaylistID: smart.id)
                .navigationTitle(Text(verbatim: smart.name))
        case .source(let id):
            // Sources don't yet have a per-source detail view — for now
            // route the click to the songs filtered by that source.
            let songs = library.visibleSongs.filter { $0.sourceID == id }
            let name = sourcesStore.sources.first(where: { $0.id == id })?.name ?? ""
            SongListView(songs: songs)
                .navigationTitle(Text(verbatim: name))
        }
    }

    private func pushAlbum(_ album: Album) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            path.append(album)
        }
    }

    private func pushArtist(_ artist: Artist) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            path.append(artist)
        }
    }
}
#endif
