#if os(macOS)
import SwiftUI
import PrimuseKit

/// Right-pane container. Owns its own NavigationStack so drilling into
/// AlbumDetail / ArtistDetail / PlaylistDetail still works inside the
/// macOS split view. Stack resets whenever sidebar selection changes.
struct MacDetailContainer: View {
    let route: MacRoute
    let homeModel: MacHomeView.Model
    let listeningStatsModel: ListeningStatsScreen.Model
    @Binding var searchText: String
    @Binding var songLocationRequest: SongLibraryLocationRequest?
    @Binding var spokenWordBookRequest: String?
    let onShowSongInLibrary: (Song) -> Void
    let onOpenLibrarySongs: () -> Void
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            content
                #if DEBUG
                .onAppear {
                    MacRouteTiming.mark("appear")
                    MacRouteTiming.markNextTurn("first frame")
                }
                #endif
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
                .navigationDestination(for: MacSearchCollectionDestination.self) { destination in
                    SearchCollectionDetailView(result: destination.result, onMacInlineBack: popDetail)
                        .navigationBarBackButtonHidden(true)
                        .pmAppearFade()
                }
                .navigationDestination(for: MacSpokenWordBookDestination.self) { destination in
                    SpokenWordBookDetailView(bookID: destination.bookID, onMacInlineBack: popDetail)
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
        }
        .environment(\.macFolderShowInLibrary) { song in
            onShowSongInLibrary(song)
        }
        .onAppear { consumeSpokenWordBookRequest() }
        .onChange(of: spokenWordBookRequest) { _, _ in consumeSpokenWordBookRequest() }
        .onReceive(NotificationCenter.default.publisher(for: .primuseDetailGoBack)) { _ in
            if !path.isEmpty { path.removeLast() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseRevealSearchResults)) { _ in
            // 标题栏里接着搜: 从结果点进去的专辑 / 艺人 / 歌单还压着时退回结果页。
            guard case .search = route else { return }
            clearDetailPath()
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
            // 专辑分区由网格自己打开;目录现拼的专辑网格里没有,照常推进详情栈。
            if case .section(.albums) = route, !AppleMusicCatalogAlbumIdentity.isCatalogAlbum(album.id) {
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
        // 这一栏的页面都不设 navigationTitle: 它会变成窗口标题, 每换一页 AppKit 就重排一次
        // 标题栏, 把红绿灯挪回系统默认的高度再被我们摆回来, 看着就是闪一下。窗口标题一直是
        // App 名, 页面名在页面自己的页头里。
        switch route {
        case .home:
            MacHomeView(model: homeModel, openLibrarySongs: onOpenLibrarySongs)
        case .stats:
            ListeningStatsScreen(model: listeningStatsModel)
        case .sources:
            MacSourcesView()
        case .search:
            SearchView(searchText: $searchText, onShowInLibrary: onShowSongInLibrary)
        case .section(let section):
            switch section {
            case .favorites:
                // 直接放在这一栏的栈里: 套一层 LibraryView 就多一个嵌套的导航栈, 从收藏点进去的
                // 专辑、艺人、歌单落在里层栈, 拿不到下面登记的、带返回键的详情页。
                FavoriteCollectionView()
            case .folders:
                HomeFolderManagementView()
            case .statistics:
                ListeningStatsScreen(model: listeningStatsModel)
            case .releaseDate:
                ReleaseDateLibraryView()
            case .recommendations:
                AIRecommendationLibraryView()
            case .songs:
                SongListView(locationRequest: $songLocationRequest)
            case .spokenWord:
                SpokenWordLibraryView()
            case .albums:
                AlbumGridView()
            case .artists:
                ArtistListView()
            case .genres:
                GenreLibraryView()
            case .playlists:
                PlaylistListView()
            case .radio:
                MacRadioStationsView()
            case .podcasts:
                PodcastLibraryView()
            }
        case .liked:
            PlaylistDetailView(
                playlist: library.playlists.first(where: { $0.id == MusicLibrary.likedSongsPlaylistID })
                    ?? Playlist(id: MusicLibrary.likedSongsPlaylistID, name: String(localized: "playlist_liked_name"))
            )
        case .playlist(let playlist):
            PlaylistDetailView(playlist: playlist)
        case .smartPlaylist(let smart):
            SmartPlaylistDetailView(smartPlaylistID: smart.id)
        case .source(let id):
            // Sources don't yet have a per-source detail view — for now
            // route the click to the songs filtered by that source.
            let name = sourcesStore.sources.first(where: { $0.id == id })?.name ?? ""
            SongListView(sourceID: id)
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

    /// 播放页「转到这本书」: 只在「有声」一栏取走请求, 书压在书架上面。
    private func consumeSpokenWordBookRequest() {
        guard let bookID = spokenWordBookRequest,
              case .section(.spokenWord) = route else { return }
        spokenWordBookRequest = nil
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            path = NavigationPath()
            path.append(MacSpokenWordBookDestination(bookID: bookID))
        }
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

/// 详情栈里的一本有声书。单独一个类型, 免得和别处以 String 压栈的目的地撞上。
struct MacSpokenWordBookDestination: Hashable {
    let bookID: String
}

/// 搜索结果里点进去的歌单 / 文件夹。压进 path 才能被返回键和「接着搜」退掉;
/// 按目标比较, 免得比对路径时把整个文件夹的歌曲 id 过一遍。
struct MacSearchCollectionDestination: Hashable {
    let result: SearchCollectionResult

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.result.id == rhs.result.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(result.id)
    }
}
#endif
