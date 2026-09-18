#if os(macOS)
import SwiftUI
import PrimuseKit

/// Right-pane container. Owns its own NavigationStack so drilling into
/// AlbumDetail / ArtistDetail / PlaylistDetail still works inside the
/// macOS split view. Stack resets whenever sidebar selection changes.
struct MacDetailContainer: View {
    let route: MacRoute
    let homeModel: MacHomeView.Model
    let listeningStatsModel: ListeningStatsView.Model
    @Binding var searchText: String
    @Binding var songLocationRequest: SongLibraryLocationRequest?
    let onShowSongInLibrary: (Song) -> Void
    let onOpenLibrarySongs: () -> Void
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationBarBackButtonHidden(true)
                .transaction { transaction in
                    transaction.animation = nil
                }
                // push/pop 本身仍然是无动画的(见 pushAlbum/pushArtist), 详情页
                // 自己淡入一下, 免得点进去像换了张截图。
                .navigationDestination(for: Album.self) { album in
                    AlbumDetailView(album: album, onMacInlineBack: popDetail)
                        .navigationBarBackButtonHidden(true)
                        .pmAppearFade()
                }
                .navigationDestination(for: Artist.self) { artist in
                    ArtistDetailView(artist: artist, onMacInlineBack: popDetail)
                        .navigationBarBackButtonHidden(true)
                        .pmAppearFade()
                }
                .navigationDestination(for: Playlist.self) { playlist in
                    PlaylistDetailView(playlist: playlist, onMacInlineBack: popDetail)
                        .navigationBarBackButtonHidden(true)
                        .pmAppearFade()
                }
                .navigationDestination(for: SmartPlaylist.self) { smart in
                    SmartPlaylistDetailView(
                        smartPlaylistID: smart.id,
                        onMacInlineBack: popDetail
                    )
                    .navigationBarBackButtonHidden(true)
                    .pmAppearFade()
                }
                // 隐藏 NavigationStack 顶部的原生 toolbar 区域 — 我们用 PMTitleBar
                // 自定义了全局 titlebar, 子视图里的 .toolbar/.searchable 不应再
                // 叠出第二条系统 bar (会出现 "搜索歌曲" + 排序按钮悬空在最顶)。
                .toolbar(.hidden, for: .windowToolbar)
        }
        .environment(\.macFolderShowInLibrary) { song in
            onShowSongInLibrary(song)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseDetailGoBack)) { _ in
            if !path.isEmpty { path.removeLast() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseSelectPlaylists)) { _ in
            // 删除当前歌单后跳「歌单」总览。若这张歌单是 push 进来的 (从总览点入),
            // 详情栈里可能还压着它的空详情 — 这里主动清栈。
            guard !path.isEmpty else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                path = NavigationPath()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseDetailOpenAlbum)) { note in
            guard let album = note.object as? Album else { return }
            if case .section(.albums) = route {
                clearDetailPath()
                return
            }
            pushAlbum(album)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseDetailOpenArtist)) { note in
            guard let artist = note.object as? Artist else { return }
            if case .section(.artists) = route {
                clearDetailPath()
                return
            }
            pushArtist(artist)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .home:
            MacHomeView(model: homeModel, openLibrarySongs: onOpenLibrarySongs)
        case .stats:
            ListeningStatsView(model: listeningStatsModel)
        case .sources:
            MacSourcesView()
                .navigationTitle("sources_title")
        case .search:
            SearchView(searchText: $searchText, onShowInLibrary: onShowSongInLibrary)
                .navigationTitle("search_title")
        case .section(let section):
            switch section {
            case .favorites:
                LibraryView(rootSection: .favorites)
            case .folders:
                HomeFolderManagementView()
            case .statistics:
                ListeningStatsView(model: listeningStatsModel)
            case .recommendations:
                AIRecommendationLibraryView()
                    .navigationTitle(section.title)
            case .songs:
                SongListView(locationRequest: $songLocationRequest)
                    .navigationTitle(section.title)
            case .albums:
                AlbumGridView()
                    .navigationTitle(section.title)
            case .artists:
                ArtistListView(artists: library.visibleArtists)
                    .navigationTitle(section.title)
            case .genres:
                GenreLibraryView()
                    .navigationTitle(section.title)
            case .playlists:
                PlaylistListView()
                    .navigationTitle(section.title)
            case .radio:
                MacRadioStationsView()
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
            let name = sourcesStore.sources.first(where: { $0.id == id })?.name ?? ""
            SongListView(sourceID: id)
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

    private func popDetail() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    private func clearDetailPath() {
        guard !path.isEmpty else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            path = NavigationPath()
        }
    }
}
#endif
