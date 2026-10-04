import SwiftUI
import PrimuseKit

/// 收藏区里的一项，已经对上了资料库里的实物。
enum FavoriteCollectionEntry: Identifiable {
    case album(Album)
    case artist(Artist)
    /// 普通歌单和「我喜欢」。
    case playlist(Playlist)
    case folder(LibraryFolderNode)

    var pin: QuickAccessPinReference {
        switch self {
        case .album(let album): QuickAccessPinReference(kind: .album, itemID: album.id)
        case .artist(let artist): QuickAccessPinReference(kind: .artist, itemID: artist.id)
        case .playlist(let playlist): QuickAccessPinReference(kind: .playlist, itemID: playlist.id)
        case .folder(let node): .folder(node.id)
        }
    }

    var id: String { pin.id }

    var isLikedSongs: Bool {
        if case .playlist(let playlist) = self { return playlist.id == MusicLibrary.likedSongsPlaylistID }
        return false
    }
}

@MainActor
enum FavoriteCollectionResolver {
    static func likedSongsPlaylist(in library: MusicLibrary) -> Playlist {
        library.playlists.first(where: { $0.id == MusicLibrary.likedSongsPlaylistID })
            ?? Playlist(
                id: MusicLibrary.likedSongsPlaylistID,
                name: String(localized: "playlist_liked_name")
            )
    }

    /// 对不上的（歌单删了、源停用了、目录索引还没建好）跳过。
    static func entries(
        for pins: [QuickAccessPinReference],
        library: MusicLibrary,
        folderIndex: LibraryFolderIndex?
    ) -> [FavoriteCollectionEntry] {
        pins.compactMap { entry(for: $0, library: library, folderIndex: folderIndex) }
    }

    static func entry(
        for pin: QuickAccessPinReference,
        library: MusicLibrary,
        folderIndex: LibraryFolderIndex?
    ) -> FavoriteCollectionEntry? {
        switch pin.kind {
        case .album:
            return library.visibleAlbum(id: pin.itemID).map(FavoriteCollectionEntry.album)
        case .artist:
            return library.favoriteArtist(id: pin.itemID).map(FavoriteCollectionEntry.artist)
        case .playlist:
            if pin.itemID == MusicLibrary.likedSongsPlaylistID {
                return .playlist(likedSongsPlaylist(in: library))
            }
            return library.playlists.first(where: { $0.id == pin.itemID }).map(FavoriteCollectionEntry.playlist)
        case .folder:
            guard let id = pin.folderNodeID, let node = folderIndex?.node(withID: id) else { return nil }
            return .folder(node)
        }
    }

    static func title(_ entry: FavoriteCollectionEntry) -> String {
        switch entry {
        case .album(let album): album.title
        case .artist(let artist): artist.name
        case .playlist(let playlist):
            playlist.id == MusicLibrary.likedSongsPlaylistID
                ? String(localized: "sidebar_liked_songs")
                : playlist.name
        case .folder(let node): HomeDiscoveryText.folderTitle(node)
        }
    }

    static func subtitle(_ entry: FavoriteCollectionEntry, library: MusicLibrary) -> String {
        switch entry {
        case .album(let album):
            album.artistName ?? String(localized: "unknown_artist")
        case .artist(let artist):
            "\(artist.albumCount.formatted()) \(String(localized: "albums_count"))"
        case .playlist(let playlist):
            "\(library.songCount(forPlaylist: playlist.id).formatted()) \(String(localized: "songs_count"))"
        case .folder(let node):
            "\(node.descendantSongCount.formatted()) \(String(localized: "songs_count"))"
        }
    }

    /// 长按菜单「播放」「加入队列」用的歌。目录按目录页设定的歌曲顺序排。
    static func songs(
        _ entry: FavoriteCollectionEntry,
        library: MusicLibrary,
        folderIndex: LibraryFolderIndex?
    ) -> [Song] {
        switch entry {
        case .album(let album):
            return library.songs(forAlbum: album.id)
        case .artist(let artist):
            return library.songs(forArtist: artist.id)
        case .playlist(let playlist):
            return library.songs(forPlaylist: playlist.id)
        case .folder(let node):
            guard let folderIndex else { return [] }
            let songs = folderIndex.songIDs(in: node.id, scope: .descendants)
                .compactMap { library.unobservedVisibleSong(id: $0) }
            return LibraryFolderBrowsePolicy.sortedSongs(songs, order: HomeFolderSongOrderPreference.load())
        }
    }
}

/// 收藏卡片的封面。封面样式设成统一圆形 / 方形 / 多图时也照着来，目录也不例外。
struct FavoriteCollectionArtwork: View {
    let entry: FavoriteCollectionEntry
    let size: CGFloat
    var cornerRadius: CGFloat = 16

    @AppStorage(QuickAccessCoverStyle.storageKey) private var style = QuickAccessCoverStyle.automatic

    var body: some View {
        switch entry {
        case .album(let album):
            QuickAccessArtworkView(item: .album(album), size: size, cornerRadius: cornerRadius) {
                AlbumArtworkView(album: album, size: size, cornerRadius: cornerRadius)
            }
        case .artist(let artist):
            QuickAccessArtworkView(item: .artist(artist), size: size, cornerRadius: cornerRadius) {
                ArtistArtworkView(artist: artist, size: size, cornerRadius: size / 2)
            }
        case .playlist(let playlist):
            QuickAccessArtworkView(item: .playlist(playlist), size: size, cornerRadius: cornerRadius) {
                if playlist.id == MusicLibrary.likedSongsPlaylistID {
                    FavoriteLikedSongsArtwork(size: size, cornerRadius: cornerRadius)
                } else {
                    PlaylistArtworkView(playlist: playlist, size: size, cornerRadius: cornerRadius)
                }
            }
        case .folder(let node):
            HomeFolderArtwork(node: node, size: size, cornerRadius: style == .circle ? size / 2 : cornerRadius)
        }
    }
}

/// 「我喜欢」的封面：粉红渐变上一颗心。
struct FavoriteLikedSongsArtwork: View {
    let size: CGFloat
    var cornerRadius: CGFloat = 16

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.pink, .red],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.33, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// 收藏卡片的长按菜单：取消收藏，再加上播放、随机、接下来播放、加入队列。
struct FavoriteCollectionMenuItems: View {
    let entry: FavoriteCollectionEntry
    let library: MusicLibrary
    let player: AudioPlayerService
    let folderIndex: LibraryFolderIndex?

    var body: some View {
        LibraryCollectionMenuItems(
            isLiked: true,
            toggleLike: { FavoriteCollectionStore.shared.uncollect(entry.pin, library: library) },
            songs: { FavoriteCollectionResolver.songs(entry, library: library, folderIndex: folderIndex) },
            player: player
        )
    }
}

/// 「收藏」整页：歌单、专辑、艺人、目录都在这里，按类型筛、拖动排序在「编辑」里。
///
/// 资料库的「收藏」分类、Mac 侧栏与极简外壳的「收藏」页、首页收藏区的「查看全部」都是它。
/// 专辑、艺人、歌单走值导航，外层导航栈要登记这三种目的地。
struct FavoriteCollectionView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @AppStorage(LibraryPinStorage.defaultsKey) private var pinsRawValue = ""
    @AppStorage(HomeFolderPinStorage.key) private var folderPinsRawValue = ""
    @State private var folderModel = HomeDiscoveryModel()
    @State private var kindFilter: QuickAccessPinKind?
    @State private var showsEditor = false

    /// 筛选胶囊的顺序。
    private static let kindOrder: [QuickAccessPinKind] = [.playlist, .album, .artist, .folder]

    private var references: [QuickAccessPinReference] {
        _ = pinsRawValue
        _ = folderPinsRawValue
        return FavoriteCollectionStore.shared.references(library: library)
    }

    private var hasFolderFavorites: Bool {
        !FavoriteCollectionStore.collectedFolderIDs(in: folderPinsRawValue).isEmpty
    }

    private var gridMinimum: CGFloat {
        #if os(macOS)
        150
        #else
        140
        #endif
    }

    var body: some View {
        let references = self.references
        // 目录要等目录索引建好才对得上；那之前先不摆，也不当成「还没有收藏」。
        let all = FavoriteCollectionResolver.entries(
            for: references,
            library: library,
            folderIndex: folderModel.index
        )
        let kinds = Self.kindOrder.filter { kind in all.contains { $0.pin.kind == kind } }
        let shown = kindFilter.map { kind in all.filter { $0.pin.kind == kind } } ?? all

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                #if os(macOS)
                macHeader
                #endif
                if kinds.count > 1 {
                    filterBar(kinds: kinds, entries: all)
                }
                if all.isEmpty, folderModel.index != nil || !hasFolderFavorites {
                    emptyState
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: gridMinimum), spacing: 16, alignment: .top)],
                        alignment: .leading,
                        spacing: 22
                    ) {
                        ForEach(shown) { entry in
                            card(entry)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 16)
        }
        .pmExtendsUnderVerticalBar()
        .background {
            if hasFolderFavorites {
                HomeDiscoveryObserver(model: folderModel)
            }
        }
        .onChange(of: kinds) { _, kinds in
            if let kindFilter, !kinds.contains(kindFilter) { self.kindFilter = nil }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("edit") { showsEditor = true }
                    .accessibilityIdentifier("favorites.edit")
            }
        }
        #endif
        .sheet(isPresented: $showsEditor) {
            FavoriteCollectionEditor()
                .environment(folderModel)
        }
    }

    #if os(macOS)
    private var macHeader: some View {
        HStack {
            Text("library_quick_access")
                .font(.title3.weight(.bold))
            Spacer()
            Button("edit") { showsEditor = true }
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
    }
    #endif

    private func filterBar(kinds: [QuickAccessPinKind], entries: [FavoriteCollectionEntry]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                RadioFilterChip(
                    title: String(localized: "search_chip_all"),
                    systemImage: "square.grid.2x2",
                    count: entries.count,
                    isSelected: kindFilter == nil
                ) { kindFilter = nil }
                ForEach(kinds, id: \.self) { kind in
                    RadioFilterChip(
                        title: Self.title(for: kind),
                        systemImage: Self.icon(for: kind),
                        count: entries.lazy.filter { $0.pin.kind == kind }.count,
                        isSelected: kindFilter == kind
                    ) { kindFilter = kindFilter == kind ? nil : kind }
                }
            }
            .padding(.horizontal, 16)
        }
        .pmStopsAtVerticalBar()
    }

    private static func title(for kind: QuickAccessPinKind) -> String {
        switch kind {
        case .playlist: String(localized: "tab_playlists")
        case .album: String(localized: "tab_albums")
        case .artist: String(localized: "tab_artists")
        case .folder: HomeDiscoveryText.string("folders")
        }
    }

    private static func icon(for kind: QuickAccessPinKind) -> String {
        switch kind {
        case .playlist: "music.note.list"
        case .album: "square.stack"
        case .artist: "music.mic"
        case .folder: "folder"
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("library_quick_access_selected_empty", systemImage: "heart")
        } description: {
            Text("favorites_empty_description")
        } actions: {
            Button("library_add_quick_access") { showsEditor = true }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func card(_ entry: FavoriteCollectionEntry) -> some View {
        switch entry {
        case .album(let album):
            NavigationLink(value: album) { cardLabel(entry) }
                .buttonStyle(.pmPressable)
                .contextMenu { menu(entry) }
                .mediaZoomSource(.album, id: album.id)
        case .artist(let artist):
            NavigationLink(value: artist) { cardLabel(entry) }
                .buttonStyle(.pmPressable)
                .contextMenu { menu(entry) }
                .mediaZoomSource(.artist, id: artist.id)
        case .playlist(let playlist):
            NavigationLink(value: playlist) { cardLabel(entry) }
                .buttonStyle(.pmPressable)
                .contextMenu { menu(entry) }
                .mediaZoomSource(.playlist, id: playlist.id)
        case .folder(let node):
            NavigationLink {
                HomeFolderBrowser(nodeID: node.id)
                    .environment(folderModel)
            } label: {
                cardLabel(entry)
            }
            .buttonStyle(.pmPressable)
            .contextMenu { menu(entry) }
        }
    }

    private func menu(_ entry: FavoriteCollectionEntry) -> some View {
        FavoriteCollectionMenuItems(
            entry: entry,
            library: library,
            player: player,
            folderIndex: folderModel.index
        )
    }

    private func cardLabel(_ entry: FavoriteCollectionEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geometry in
                FavoriteCollectionArtwork(entry: entry, size: geometry.size.width)
                    .environment(folderModel)
            }
            .aspectRatio(1, contentMode: .fit)

            Text(FavoriteCollectionResolver.title(entry))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Text(FavoriteCollectionResolver.subtitle(entry, library: library))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - 编辑收藏

/// 编辑页里一条已收藏项背后的真实对象。解析一次存起来，行渲染时不再回头去整库里线性查找。
private struct FavoriteCollectionEditorRow: Identifiable {
    let pin: QuickAccessPinReference
    /// 指向的对象可能已经不在资料库里（源被移除、歌被删）。保留这一行但不渲染，
    /// `onMove` 的下标才能继续跟收藏顺序对齐。
    let entry: FavoriteCollectionEntry?
    let matchesQuery: Bool
    var id: String { pin.id }
}

/// 一次整库筛选的产物。这部分放到后台算完再整体交给视图；已收藏的那几条则在
/// 主线程同步解析（都是 O(1) 查找），勾选后立刻出现，不用等后台那一轮。
private struct FavoriteCollectionEditorContent: Sendable {
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []
    var playlistSongCounts: [String: Int] = [:]
}

/// 整库筛选的实际工作。写成文件作用域的自由函数，明确不带任何 actor 隔离，
/// 可以直接在后台任务里跑。
private func buildFavoriteCollectionEditorContent(
    pins: [QuickAccessPinReference],
    albums: [Album],
    artists: [Artist],
    playlists: [Playlist],
    playlistSongCounts: [String: Int],
    query: String
) -> FavoriteCollectionEditorContent {
    let pinnedAlbumIDs = Set(pins.lazy.filter { $0.kind == .album }.map(\.itemID))
    let pinnedArtistIDs = Set(pins.lazy.filter { $0.kind == .artist }.map(\.itemID))
    let pinnedPlaylistIDs = Set(pins.lazy.filter { $0.kind == .playlist }.map(\.itemID))

    return FavoriteCollectionEditorContent(
        albums: QuickAccessCandidatePolicy.filtered(
            albums,
            id: \.id,
            pinnedIDs: pinnedAlbumIDs,
            query: query,
            searchFields: { [$0.title, $0.artistName] }
        ),
        artists: QuickAccessCandidatePolicy.filtered(
            artists,
            id: \.id,
            pinnedIDs: pinnedArtistIDs,
            query: query,
            searchFields: { [$0.name] }
        ),
        playlists: QuickAccessCandidatePolicy.filtered(
            playlists,
            id: \.id,
            pinnedIDs: pinnedPlaylistIDs,
            query: query,
            searchFields: { [$0.name] }
        ),
        playlistSongCounts: playlistSongCounts
    )
}

/// 「编辑收藏」：拖动排序、取消收藏，再从资料库里挑专辑、艺人、歌单加进来。
/// 目录在目录页里收藏，这里只排序和取消。
struct FavoriteCollectionEditor: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(HomeDiscoveryModel.self) private var folderModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(LibraryPinStorage.defaultsKey) private var pinsRawValue = ""
    @AppStorage(HomeFolderPinStorage.key) private var folderPinsRawValue = ""
    @State private var searchText = ""
    /// 收藏顺序合一次要对账本、过整库专辑，记下来；整库筛选时每个候选都要查一次集合。
    @State private var selection = Selection()
    @State private var content = FavoriteCollectionEditorContent()
    @State private var isBuilding = false

    private struct Selection {
        var key: String?
        var pins: [QuickAccessPinReference] = []
        var identifiers: Set<QuickAccessPinReference> = []
    }

    private var store: FavoriteCollectionStore { .shared }

    private var selectionKey: String {
        [
            pinsRawValue,
            folderPinsRawValue,
            String(LibraryFavoritesStore.shared.revision),
            String(library.searchRevision),
        ].joined(separator: "\u{1F}")
    }

    private var pins: [QuickAccessPinReference] { selection.pins }

    /// 顺序与 `pins` 严格一致，`onMove` 的下标才对得上。
    private var rows: [FavoriteCollectionEditorRow] {
        pins.map { pin in
            guard let entry = FavoriteCollectionResolver.entry(
                for: pin,
                library: library,
                folderIndex: folderModel.index
            ) else {
                return FavoriteCollectionEditorRow(pin: pin, entry: nil, matchesQuery: false)
            }
            return FavoriteCollectionEditorRow(
                pin: pin,
                entry: entry,
                matchesQuery: QuickAccessCandidatePolicy.matches(
                    query: searchText,
                    fields: [
                        FavoriteCollectionResolver.title(entry),
                        FavoriteCollectionResolver.subtitle(entry, library: library),
                    ]
                )
            )
        }
    }

    /// 只要输入变了就重算一次。资料库在后台扫描期间更新时这一页也跟着刷新。
    private var rebuildKey: String {
        [
            String(library.searchRevision),
            String(library.playlistCollectionRevision),
            selectionKey,
            searchText,
        ].joined(separator: "\u{1F}")
    }

    var body: some View {
        let rows = self.rows
        NavigationStack {
            List {
                if searchText.isEmpty || rows.contains(where: \.matchesQuery) {
                    Section {
                        if pins.isEmpty {
                            Label("library_quick_access_selected_empty", systemImage: "heart")
                                .foregroundStyle(.secondary)
                        } else if searchText.isEmpty {
                            ForEach(rows) { row in
                                selectedRow(row)
                            }
                            .onMove(perform: movePins)
                        } else {
                            ForEach(rows.filter(\.matchesQuery)) { row in
                                selectedRow(row)
                            }
                        }
                    } header: {
                        HStack {
                            Text("library_quick_access_selected")
                            Spacer()
                            Text(verbatim: rows.lazy.filter { $0.entry != nil }.count.formatted())
                                .monospacedDigit()
                        }
                    }
                }

                if isBuilding {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("library_quick_access_loading").foregroundStyle(.secondary)
                    }
                }

                if !content.albums.isEmpty {
                    Section("tab_albums") {
                        ForEach(content.albums) { album in
                            pinButton(QuickAccessPinReference(kind: .album, itemID: album.id)) {
                                AlbumArtworkView(album: album, size: 42, cornerRadius: 7)
                            } title: {
                                Text(album.title)
                            } subtitle: {
                                Text(album.artistName ?? String(localized: "unknown_artist"))
                            }
                        }
                    }
                }

                if !content.artists.isEmpty {
                    Section("tab_artists") {
                        ForEach(content.artists) { artist in
                            pinButton(QuickAccessPinReference(kind: .artist, itemID: artist.id)) {
                                ArtistArtworkView(artist: artist, size: 42, cornerRadius: 21)
                            } title: {
                                Text(artist.name)
                            } subtitle: {
                                Text(verbatim: "\(artist.albumCount) \(String(localized: "albums_count"))")
                            }
                        }
                    }
                }

                if !content.playlists.isEmpty {
                    Section("tab_playlists") {
                        ForEach(content.playlists) { playlist in
                            pinButton(QuickAccessPinReference(kind: .playlist, itemID: playlist.id)) {
                                editorPlaylistArtwork(playlist)
                            } title: {
                                Text(playlist.name)
                            } subtitle: {
                                Text(playlistSubtitle(playlist))
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            .searchable(
                text: $searchText,
                placement: .toolbar,
                prompt: Text("library_quick_access_search_prompt")
            )
            #else
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("library_quick_access_search_prompt")
            )
            #endif
            .navigationTitle("library_edit_quick_access")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") {
                        dismiss()
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(searchText.isEmpty ? .active : .inactive))
            #endif
        }
        .onChange(of: selectionKey, initial: true) { _, key in
            guard selection.key != key else { return }
            let pins = store.references(library: library)
            selection = Selection(key: key, pins: pins, identifiers: Set(pins))
        }
        .task(id: rebuildKey) {
            await rebuildContent()
        }
    }

    /// 整库筛选。专辑与艺术家来自资料库已经排好序的集合，歌单来自用户排定的
    /// 顺序 —— 这里一律保持原顺序，既省掉一次 localizedCompare 全表排序，也不会
    /// 把用户排好的歌单顺序又打乱一次。
    private func rebuildContent() async {
        let query = searchText
        let currentPins = selection.pins
        let albumsSnapshot = library.visibleAlbums
        let artistsSnapshot = library.visibleArtists
        let liked = FavoriteCollectionResolver.likedSongsPlaylist(in: library)
        let playlistsSnapshot = [liked] + library.playlists.filter {
            $0.id != MusicLibrary.likedSongsPlaylistID
        }
        var songCounts: [String: Int] = [:]
        songCounts.reserveCapacity(playlistsSnapshot.count)
        for playlist in playlistsSnapshot {
            songCounts[playlist.id] = library.songCount(forPlaylist: playlist.id)
        }

        isBuilding = true
        let built = await Task.detached(priority: .userInitiated) {
            buildFavoriteCollectionEditorContent(
                pins: currentPins,
                albums: albumsSnapshot,
                artists: artistsSnapshot,
                playlists: playlistsSnapshot,
                playlistSongCounts: songCounts,
                query: query
            )
        }.value
        guard !Task.isCancelled else { return }
        content = built
        isBuilding = false
    }

    private func playlistSubtitle(_ playlist: Playlist) -> String {
        // 后台那一轮还没落地时(刚收藏了一个新歌单)直接现算一次, 不显示 0。
        String(
            format: String(localized: "carplay_playlist_song_count_format"),
            content.playlistSongCounts[playlist.id]
                ?? library.songCount(forPlaylist: playlist.id)
        )
    }

    @ViewBuilder
    private func selectedRow(_ row: FavoriteCollectionEditorRow) -> some View {
        if let entry = row.entry {
            pinButton(row.pin) {
                switch entry {
                case .album(let album):
                    AlbumArtworkView(album: album, size: 42, cornerRadius: 7)
                case .artist(let artist):
                    ArtistArtworkView(artist: artist, size: 42, cornerRadius: 21)
                case .playlist(let playlist):
                    editorPlaylistArtwork(playlist)
                case .folder(let node):
                    HomeFolderArtwork(node: node, size: 42, cornerRadius: 7)
                }
            } title: {
                Text(FavoriteCollectionResolver.title(entry))
            } subtitle: {
                if case .playlist(let playlist) = entry {
                    Text(playlistSubtitle(playlist))
                } else {
                    Text(FavoriteCollectionResolver.subtitle(entry, library: library))
                }
            }
        }
    }

    private func pinButton<Artwork: View, Title: View, Subtitle: View>(
        _ pin: QuickAccessPinReference,
        @ViewBuilder artwork: () -> Artwork,
        @ViewBuilder title: () -> Title,
        @ViewBuilder subtitle: () -> Subtitle
    ) -> some View {
        let isSelected = selection.identifiers.contains(pin)

        return Button {
            store.setCollected(!isSelected, pin, library: library)
        } label: {
            HStack(spacing: 12) {
                artwork()

                VStack(alignment: .leading, spacing: 2) {
                    title()
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    subtitle()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func editorPlaylistArtwork(_ playlist: Playlist) -> some View {
        if playlist.id == MusicLibrary.likedSongsPlaylistID {
            FavoriteLikedSongsArtwork(size: 42, cornerRadius: 7)
        } else {
            PlaylistArtworkView(playlist: playlist, size: 42, cornerRadius: 7)
        }
    }

    private func movePins(from source: IndexSet, to destination: Int) {
        guard searchText.isEmpty else { return }
        var updated = selection.pins
        updated.move(fromOffsets: source, toOffset: destination)
        selection.pins = updated
        store.setOrder(updated)
    }
}
