import SwiftUI
import PrimuseKit

enum LibrarySection: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case recommendations, favorites, playlists, artists, genres, albums, songs, spokenWord, folders, radio, statistics
    /// 按发行年代、年份浏览专辑。
    case releaseDate
    /// 订阅的播客。默认收起,在资料库设置里打开。
    case podcasts

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .recommendations: return "library_recommendations_title"
        case .favorites: return "library_quick_access"
        case .folders: return "library_browse_folder"
        case .statistics: return "stats_title"
        case .playlists: return "tab_playlists"
        case .artists: return "tab_artists"
        case .genres: return "tab_genres"
        case .albums: return "tab_albums"
        case .songs: return "tab_songs"
        case .spokenWord: return "tab_spoken_word"
        case .radio: return "radio_title"
        case .releaseDate: return "library_release_date_title"
        case .podcasts: return "listening_space_podcast"
        }
    }

    var icon: String {
        switch self {
        case .recommendations: return "sparkles"
        case .favorites: return "heart.fill"
        case .folders: return "folder.fill"
        case .statistics: return "chart.bar.fill"
        case .playlists: return "music.note.list"
        case .artists: return "music.mic"
        case .genres: return "tag.fill"
        case .albums: return "square.stack.fill"
        case .songs: return "music.note"
        case .spokenWord: return "books.vertical.fill"
        case .radio: return "radio.fill"
        case .releaseDate: return "calendar"
        case .podcasts: return ListeningSpace.podcast.systemImage
        }
    }

    var color: Color {
        switch self {
        case .recommendations: return Color(red: 0.71, green: 0.48, blue: 0.40)
        case .favorites: return .pink
        case .folders: return .orange
        case .statistics: return .green
        case .playlists: return .red
        case .artists: return .pink
        case .genres: return .teal
        case .albums: return .purple
        case .songs: return .blue
        case .spokenWord: return .brown
        case .radio: return .orange
        case .releaseDate: return .indigo
        case .podcasts: return .purple
        }
    }

    var localizedTitle: String {
        switch self {
        case .recommendations: return String(localized: "library_recommendations_title")
        case .favorites: return String(localized: "library_quick_access")
        case .folders: return String(localized: "library_browse_folder")
        case .statistics: return String(localized: "stats_title")
        case .playlists: return String(localized: "tab_playlists")
        case .artists: return String(localized: "tab_artists")
        case .genres: return String(localized: "tab_genres")
        case .albums: return String(localized: "tab_albums")
        case .songs: return String(localized: "tab_songs")
        case .spokenWord: return String(localized: "tab_spoken_word")
        case .radio: return String(localized: "radio_title")
        case .releaseDate: return String(localized: "library_release_date_title")
        case .podcasts: return String(localized: "listening_space_podcast")
        }
    }
}

enum LibraryDisplayConfiguration {
    static let sectionOrderKey = LibrarySectionLayoutPolicy.orderKey
    static let hiddenSectionsKey = LibrarySectionLayoutPolicy.hiddenKey

    /// 资料库先是藏品本身;智能推荐与听歌统计排在最后,默认还收起来。
    static let defaultSectionOrder: [LibrarySection] = [
        .favorites,
        .songs,
        .albums,
        .artists,
        .genres,
        .folders,
        .releaseDate,
        .playlists,
        .radio,
        .spokenWord,
        .podcasts,
        .recommendations,
        .statistics,
    ]

    /// 没设过显隐时收起来的分类。推荐与排行、统计在首页都有自己的区块;Mac 首页没有
    /// 统计入口,侧栏那一行就留着。播客要订阅了才有内容,用的人打开。
    static var defaultHiddenSections: Set<LibrarySection> {
        #if os(macOS)
        [.recommendations, .podcasts]
        #else
        [.recommendations, .statistics, .podcasts]
        #endif
    }

    /// 播客分类上线时已经存过显隐的人:补进隐藏集合一次,别凭空多出一行。
    static let podcastsDefaultHiddenMigrationKey = "primuse.library.podcastsDefaultHidden.v1"

    static func decodeSectionOrder(_ rawValue: String) -> [LibrarySection] {
        let stored = (LibrarySectionLayoutPolicy.decodeNames(rawValue) ?? [])
            .compactMap(LibrarySection.init(rawValue:))
        return LibrarySectionLayoutPolicy.completedOrder(stored, defaultOrder: defaultSectionOrder)
    }

    static func encodeSectionOrder(_ sections: [LibrarySection]) -> String {
        LibrarySectionLayoutPolicy.encodeNames(sections.map(\.rawValue))
    }

    /// 实际收起来的分类。从没设过(空串)时是 `defaultHiddenSections`。
    static func decodeHiddenSections(_ rawValue: String) -> Set<LibrarySection> {
        LibrarySectionLayoutPolicy.hidden(
            rawValue: rawValue,
            defaultHidden: defaultHiddenSections,
            section: LibrarySection.init(rawValue:)
        )
    }

    static func encodeHiddenSections(_ sections: Set<LibrarySection>) -> String {
        LibrarySectionLayoutPolicy.encodeNames(defaultSectionOrder.filter(sections.contains).map(\.rawValue))
    }

    static func visibleSections(orderRawValue: String, hiddenRawValue: String) -> [LibrarySection] {
        let hidden = decodeHiddenSections(hiddenRawValue)
        return decodeSectionOrder(orderRawValue).filter { !hidden.contains($0) }
    }

    /// 启动时、任何界面读资料库分类之前调一次:升级前调过顺序却没关过任何分类的人,
    /// 把「全部显示」写实,默认收起的两类不会凭空消失。
    static func migrateDefaultHiddenSectionsIfNeeded() {
        LibrarySectionLayoutPolicy.migrateDefaultHiddenIfNeeded()
        LibrarySectionLayoutPolicy.hideNewSectionIfNeeded(
            LibrarySection.podcasts.rawValue,
            migrationKey: podcastsDefaultHiddenMigrationKey
        )
    }

    static let podcastsRevealedForLocalFilesKey = "primuse.library.podcastsRevealedForLocalFiles.v1"

    /// 资料库里第一次有了本机的播客文件:播客分类亮出来一次。这些文件原先在有声书架上,
    /// 归到播客以后分类还收着的话,看起来就是丢了。
    static func revealPodcastsForLocalFilesIfNeeded() {
        LibrarySectionLayoutPolicy.revealSectionIfNeeded(
            LibrarySection.podcasts.rawValue,
            defaultHidden: defaultSectionOrder.filter(defaultHiddenSections.contains).map(\.rawValue),
            migrationKey: podcastsRevealedForLocalFilesKey
        )
    }
}

#if DEBUG
/// 编译机上无人值守取证用：往资料库某一页的导航栈里推一个值、或退一层。
/// 推入走的是和点卡片一样的值导航，转场源在屏幕上时就是缩放转场。
@MainActor
enum LibraryDebugNavigation {
    enum Target {
        case album(Album)
        case genre(LibraryGenre)
        case smartPlaylist(SmartPlaylist)
    }

    struct Request {
        let section: LibrarySection
        /// nil 表示退一层。
        let target: Target?
    }

    static let notification = Notification.Name("primuse.debug.libraryNavigation")

    static func push(_ album: Album, in section: LibrarySection) {
        post(Request(section: section, target: .album(album)))
    }

    static func push(_ genre: LibraryGenre, in section: LibrarySection) {
        post(Request(section: section, target: .genre(genre)))
    }

    static func push(_ smartPlaylist: SmartPlaylist, in section: LibrarySection) {
        post(Request(section: section, target: .smartPlaylist(smartPlaylist)))
    }

    static func pop(in section: LibrarySection) {
        post(Request(section: section, target: nil))
    }

    private static func post(_ request: Request) {
        NotificationCenter.default.post(name: notification, object: request)
    }
}
#endif

enum LibraryDeepLink: Equatable, Sendable {
    case root
    case section(LibrarySection)
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
    case song(String)
}

typealias LibraryPinKind = QuickAccessPinKind
typealias LibraryPinReference = QuickAccessPinReference

enum LibraryPinStorage {
    static let defaultsKey = "primuse.library.quickAccess.v1"
    static let likedSongsPin = LibraryPinReference(
        kind: .playlist,
        itemID: MusicLibrary.likedSongsPlaylistID
    )

    static func decode(_ rawValue: String) -> [LibraryPinReference] {
        QuickAccessPinStorageCodec.decode(rawValue, defaultPins: [likedSongsPin])
    }

    static func encode(_ pins: [LibraryPinReference]) -> String {
        QuickAccessPinStorageCodec.encode(pins)
    }

    /// Artist IDs changed key once (case/width/diacritic folding). A pinned
    /// artist follows its new ID; the legacy pin is kept so nothing the user
    /// chose disappears.
    @discardableResult
    static func migrateArtistIdentities(
        renames: [String: String],
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !renames.isEmpty else { return false }
        let rawValue = defaults.string(forKey: defaultsKey) ?? ""
        guard !rawValue.isEmpty else { return false }
        let pins = decode(rawValue)
        var existingArtistIDs = Set(
            pins.filter { $0.kind == .artist }.map(\.itemID)
        )

        var updated: [LibraryPinReference] = []
        updated.reserveCapacity(pins.count)
        var changed = false
        for pin in pins {
            updated.append(pin)
            guard pin.kind == .artist,
                  let currentID = renames[pin.itemID],
                  !existingArtistIDs.contains(currentID) else { continue }
            existingArtistIDs.insert(currentID)
            updated.append(LibraryPinReference(kind: .artist, itemID: currentID))
            changed = true
        }
        guard changed else { return false }
        defaults.set(encode(updated), forKey: defaultsKey)
        return true
    }
}

private struct LibraryArtworkPreviewSelection: Sendable {
    var revision = ""
    /// 挑这一份时的用户改动部分(快捷访问、手选封面)。只有它变了才立刻重挑。
    var userRevision = ""
    var songs: [Song] = []
    var albums: [Album] = []
    var artists: [Artist] = []
    var playlists: [Playlist] = []
    var radioStations: [RadioStation] = []
    var albumFallbackSongs: [String: [Song]] = [:]
    var artistFallbackSongs: [String: [Song]] = [:]
}

@MainActor
private final class LibraryArtworkPreviewSessionStore {
    private struct InFlight {
        let build: SessionStableSnapshotBuild
        let task: Task<LibraryArtworkPreviewSelection, Never>
    }

    static let shared = LibraryArtworkPreviewSessionStore()

    private var cache = SessionStableSnapshotCache<LibraryArtworkPreviewSelection>()
    private var inFlight: InFlight?

    func cachedSelection(for revision: String) -> LibraryArtworkPreviewSelection? {
        cache.cachedValue(for: revision)
    }

    func invalidateForManualRefresh() {
        cache.invalidateForManualRefresh()
        inFlight?.task.cancel()
    }

    func selection(
        for revision: String,
        build: @escaping @Sendable (String) -> LibraryArtworkPreviewSelection
    ) async -> LibraryArtworkPreviewSelection? {
        if let cached = cache.cachedValue(for: revision) {
            return cached
        }

        let operation: InFlight
        if let current = inFlight,
           current.build.revision == revision,
           cache.isCurrentBuild(current.build) {
            operation = current
        } else if let current = inFlight {
            current.task.cancel()
            _ = await current.task.value
            guard !Task.isCancelled else { return nil }
            if inFlight?.build == current.build {
                inFlight = nil
            }
            return await selection(for: revision, build: build)
        } else {
            let buildContext = cache.beginBuild(for: revision)
            operation = InFlight(
                build: buildContext,
                task: Task.detached(priority: .utility) {
                    build(buildContext.randomSeed)
                }
            )
            inFlight = operation
        }

        let value = await operation.task.value
        let accepted = cache.commit(value, for: operation.build)
        if inFlight?.build == operation.build {
            inFlight = nil
        }
        if accepted { return value }
        return cache.cachedValue(for: revision)
    }
}

private enum LibraryArtworkPreviewBuilder {
    static func hasReference(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func songHasArtworkHint(_ song: Song) -> Bool {
        hasReference(song.coverArtFileName)
            || (song.sourceID == AppleMusicLibraryIdentity.sourceID && !song.filePath.isEmpty)
    }

    static func select<Item>(
        _ items: [Item],
        maximumCount: Int = 3,
        randomSeed: String,
        id: (Item) -> String,
        hasArtworkHint: (Item) -> Bool
    ) -> [Item] {
        let selectedIDs = LibraryArtworkPreviewSelectionPolicy.selectedIDs(
            from: items.map {
                LibraryArtworkPreviewCandidate(
                    id: id($0),
                    hasArtworkHint: hasArtworkHint($0)
                )
            },
            maximumCount: maximumCount,
            randomSeed: randomSeed
        )
        // 只挑几件, 别为此把整个列表复制进字典(二十多万首歌时是上百 MB 的瞬时占用)。
        let wanted = Set(selectedIDs)
        var selectedByID: [String: Item] = [:]
        for item in items {
            let key = id(item)
            guard wanted.contains(key), selectedByID[key] == nil else { continue }
            selectedByID[key] = item
            if selectedByID.count == wanted.count { break }
        }
        return selectedIDs.compactMap { selectedByID[$0] }
    }
}

/// 资料库浏览区的一段: 要么是整幅的「快速访问」货架, 要么是一串等高的分类入口。
private struct LibraryBrowseRun: Identifiable {
    let id: String
    let isQuickAccess: Bool
    let sections: [LibrarySection]
}

struct LibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(RadioStationsStore.self) private var radioStationsStore
    #if os(iOS)
    @Environment(\.appNavigationMode) private var appNavigationMode
    @Environment(\.pmHeightClass) private var heightClass
    /// 极简导航没有首页:「开始听」那一行卡片放在「歌曲」页顶上,可在界面编辑里关。
    @AppStorage(ListeningIntentService.minimalSongsVisibilityKey) private var showsMinimalStartListening = true
    #endif
    @Binding private var deepLink: LibraryDeepLink?
    private let rootSection: LibrarySection?
    private let onActiveSectionChange: (LibrarySection?) -> Void
    @State private var navigationPath = NavigationPath()
    #if DEBUG
    /// 取证钩子推入的风格页。风格的值导航登记在分类页里，从外面往路径里追加找不到它，
    /// 所以在根上另挂一个按条目推入的目的地。
    @State private var debugGenre: LibraryGenre?
    @State private var debugSmartPlaylist: SmartPlaylist?
    #endif
    /// 资料库这一层导航栈的 zoom 命名空间。
    @Namespace private var libraryZoomNamespace
    @State private var songLocationRequest: SongLibraryLocationRequest?
    @State private var didRestorePersistedPage = false
    @State private var showQuickAccessEditor = false
    @AppStorage("primuse.navigation.libraryPage.v1")
    private var persistedPageID = ""
    @AppStorage(LibraryPinStorage.defaultsKey)
    private var quickAccessRawValue = ""
    @AppStorage(HomeFolderPinStorage.key)
    private var folderPinsRawValue = ""
    /// 收藏的目录要靠目录索引才对得上标题与封面；只在收藏了目录时才建。
    @State private var favoriteFolderModel = HomeDiscoveryModel()
    @AppStorage(LibraryDisplayConfiguration.sectionOrderKey)
    private var sectionOrderRawValue = ""
    @AppStorage(LibraryDisplayConfiguration.hiddenSectionsKey)
    private var hiddenSectionsRawValue = ""
    @AppStorage(QuickAccessCoverStyle.storageKey) private var quickAccessCoverStyle = QuickAccessCoverStyle.automatic
    @AppStorage(ArtistBrowseMode.storageKey)
    private var artistBrowseModeRaw = ArtistBrowseMode.allArtists.rawValue
    @State private var artworkPreviewSelection = LibraryArtworkPreviewSelection()
    /// 上一次真正挑完封面预览的时刻, 给资料库内容驱动的重挑做节流。
    @State private var artworkPreviewBuiltAt: Date?

    private var songs: [Song] { library.visibleSongs }
    private var albums: [Album] { library.visibleAlbums }
    /// 跟艺术家页一样按「全部艺术家 / 专辑艺术家」设置：入口上的人数与头像和点进去看到的一致。
    private var artists: [Artist] { library.browsableArtists(.resolved(artistBrowseModeRaw)) }
    private var genres: [LibraryGenre] { library.visibleGenres }
    private var regularPlaylists: [Playlist] {
        library.playlists.filter { $0.id != MusicLibrary.likedSongsPlaylistID }
    }
    private var hasContent: Bool {
        !songs.isEmpty
            || !albums.isEmpty
            || !artists.isEmpty
            || !regularPlaylists.isEmpty
            || !library.smartPlaylists.isEmpty
            || !radioStationsStore.stations.isEmpty
    }
    /// 收藏区的显示顺序（见 `FavoriteCollectionStore`），已经去掉对不上的。
    private var visiblePins: [LibraryPinReference] {
        _ = quickAccessRawValue
        _ = folderPinsRawValue
        return FavoriteCollectionStore.shared.references(library: library).filter(pinExists)
    }
    /// 资料库首页的收藏货架只摆前面这些，其余在「查看全部」里。
    private var hubPins: [LibraryPinReference] {
        Array(visiblePins.prefix(usesMinimalSectionControls ? 12 : 20))
    }
    private var hasFolderFavorites: Bool {
        !FavoriteCollectionStore.collectedFolderIDs(in: folderPinsRawValue).isEmpty
    }
    private var likedPlaylist: Playlist {
        library.playlists.first(where: { $0.id == MusicLibrary.likedSongsPlaylistID })
            ?? Playlist(
                id: MusicLibrary.likedSongsPlaylistID,
                name: String(localized: "playlist_liked_name")
            )
    }
    private var visibleLibrarySections: [LibrarySection] {
        LibraryDisplayConfiguration.visibleSections(
            orderRawValue: sectionOrderRawValue,
            hiddenRawValue: hiddenSectionsRawValue
        )
        // 「有声内容」只在真的有的时候出现: 绝大多数曲库一本有声书也没有,
        // 给它们摆一个永远空着的入口是噪音。
        .filter { $0 != .spokenWord || !library.spokenWordSongs.isEmpty }
    }
    private var artworkPreviewRevision: String {
        // 电台部分用存储里缓存的摘要：这个属性一次刷新要被求值好几遍，
        // 原来每遍都把上千个台逐个拼成一长串，再拿长串去比较。
        let radioSignature = radioStationsStore.artworkRevision
        return [
            String(library.visibleSongCollectionRevision),
            String(library.albumArtworkLookupRevision),
            String(library.sourceSyncCompletionRevision),
            String(library.playlistCollectionRevision),
            radioSignature,
            artworkPreviewUserRevision,
        ].joined(separator: "#")
    }
    /// 预览签名里由用户操作决定的部分。其余部分随扫描、回填不停地变。
    private var artworkPreviewUserRevision: String {
        "\(library.artworkOverrideRevision)#\(quickAccessRawValue)#\(LibraryFavoritesStore.shared.revision)#\(artistBrowseModeRaw)"
    }

    init(
        deepLink: Binding<LibraryDeepLink?> = .constant(nil),
        rootSection: LibrarySection? = nil,
        onActiveSectionChange: @escaping (LibrarySection?) -> Void = { _ in }
    ) {
        self._deepLink = deepLink
        self.rootSection = rootSection
        self.onActiveSectionChange = onActiveSectionChange
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            rootContent
            .navigationTitle(rootSection?.title ?? "library_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            .pmVerticalBarTitleEdge()
            #if os(iOS)
            .minimalNavigationRoot()
            #endif
            .navigationDestination(for: LibrarySection.self) { section in
                sectionDestination(section)
            }
            .navigationDestination(for: Album.self) { album in
                AlbumDetailView(album: album)
                    .mediaZoomDestination(.album, id: album.id)
                    .onAppear {
                        persistedPageID = "album:\(album.id)"
                        onActiveSectionChange(.albums)
                    }
            }
            .navigationDestination(for: Artist.self) { artist in
                ArtistDetailView(artist: artist)
                    .mediaZoomDestination(.artist, id: artist.id)
                    .onAppear {
                        persistedPageID = "artist:\(artist.id)"
                        onActiveSectionChange(.artists)
                    }
            }
            .navigationDestination(for: Playlist.self) { playlist in
                PlaylistDetailView(playlist: playlist)
                    .mediaZoomDestination(.playlist, id: playlist.id)
                    .onAppear {
                        persistedPageID = "playlist:\(playlist.id)"
                        onActiveSectionChange(.playlists)
                    }
            }
            .onAppear {
                if deepLink == nil, rootSection == nil {
                    restorePersistedPageIfNeeded()
                } else {
                    applyDeepLink(deepLink)
                }
            }
            .onChange(of: deepLink) { _, newValue in
                applyDeepLink(newValue)
            }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: LibraryDebugNavigation.notification)) { note in
                // 经典外观只有一个资料库栈(rootSection 为 nil);顶部 tab 外壳里每个分类各有一个,只认点名的那个。
                guard let request = note.object as? LibraryDebugNavigation.Request,
                      rootSection == nil || rootSection == request.section else { return }
                switch request.target {
                case .album(let album): navigationPath.append(album)
                case .genre(let genre): debugGenre = genre
                case .smartPlaylist(let smart): debugSmartPlaylist = smart
                case nil: if !navigationPath.isEmpty { navigationPath.removeLast() }
                }
            }
            .navigationDestination(item: $debugGenre) { genre in
                GenreDetailView(genre: genre)
            }
            .navigationDestination(item: $debugSmartPlaylist) { smart in
                SmartPlaylistDetailView(smartPlaylistID: smart.id)
            }
            #endif
            .onChange(of: navigationPath.count) { _, count in
                if didRestorePersistedPage && count == 0 {
                    persistedPageID = ""
                    onActiveSectionChange(nil)
                }
            }
            .task(id: library.visibleSongCollectionRevision) {
                let version = SongListSnapshotVersion(
                    collectionRevision: library.visibleSongCollectionRevision,
                    replacementToken: library.songReplacementToken
                )
                let songsSnapshot = library.visibleSongs
                guard !songsSnapshot.isEmpty else { return }
                do {
                    // Coalesce scanner bursts, then prepare the default order
                    // while the user is still on the library hub. SongListView
                    // reuses the same in-flight/cached snapshot on navigation.
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                _ = await SongListSnapshotStore.shared.snapshot(
                    scopeKey: SongListSnapshotStore.libraryScopeKey,
                    version: version,
                    order: .title,
                    songs: songsSnapshot
                )
            }
            .sheet(isPresented: $showQuickAccessEditor) {
                FavoriteCollectionEditor()
                    .environment(favoriteFolderModel)
            }
        }
        .mediaZoomNamespace(libraryZoomNamespace)
    }

    @ViewBuilder
    private var rootContent: some View {
        if let rootSection {
            destination(for: rootSection)
        } else if hasContent {
            libraryHub
        } else {
            emptyLibraryState
        }
    }

    private func sectionDestination(_ section: LibrarySection) -> some View {
        destination(for: section)
            .navigationTitle(section.title)
            .toolbarTitleDisplayMode(.inline)
            #if os(iOS)
            .minimalNavigationRoot()
            .navigationBarBackButtonHidden(appNavigationMode == .minimal)
            #endif
            .onAppear {
                persistedPageID = "section:\(section.rawValue)"
                onActiveSectionChange(section)
            }
    }

    private var libraryHub: some View {
        let previewRevision = artworkPreviewRevision
        return ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                browseLibrarySection
            }
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .pmExtendsUnderVerticalBar()
        .background {
            if hasFolderFavorites {
                HomeDiscoveryObserver(model: favoriteFolderModel)
            }
        }
        .task(id: previewRevision) {
            await refreshArtworkPreviews(for: previewRevision)
        }
        .serverCatalogPullToRefresh {
            LibraryArtworkPreviewSessionStore.shared.invalidateForManualRefresh()
            artworkPreviewSelection = LibraryArtworkPreviewSelection()
            artworkPreviewBuiltAt = nil
            await refreshArtworkPreviews(for: artworkPreviewRevision)
        }
        .onAppear {
            if navigationPath.isEmpty {
                onActiveSectionChange(nil)
            }
        }
    }

    private var quickAccessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("library_quick_access") {
                if !visiblePins.isEmpty {
                    NavigationLink(value: LibrarySection.favorites) {
                        HStack(spacing: 5) {
                            Text("see_all")
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.favorites.seeAll")
                }
            }

            if usesMinimalSectionControls {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140), spacing: 16, alignment: .topLeading)],
                    alignment: .leading,
                    spacing: 24
                ) {
                    quickAccessItems
                }
                .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        quickAccessItems
                    }
                    .padding(.horizontal, 16)
                }
                .pmStopsAtVerticalBar()
                .contentMargins(.horizontal, 0, for: .scrollContent)
            }
        }
    }

    private var quickAccessItems: some View {
        Group {
            ForEach(hubPins) { pin in
                pinnedItemCard(pin)
            }

            Button {
                showQuickAccessEditor = true
            } label: {
                addQuickAccessLabel
            }
            .buttonStyle(.plain)
        }
    }

    /// 手机横屏 (纵向紧凑) 下分类入口排两列。Mac 没有纵向尺寸等级, 恒为 false。
    private var usesCompactBrowseLayout: Bool {
        #if os(iOS)
        heightClass.isCompact
        #else
        false
        #endif
    }

    /// 分类入口的列数。竖屏与 iPad 仍是一列(与原来的竖排完全一致); 手机横屏下
    /// 行宽有 700 多点, 一列只放得下一张 72pt 高的卡片, 右边整片空着。
    private var browseCategoryColumns: [GridItem] {
        usesCompactBrowseLayout
            ? [GridItem(.adaptive(minimum: 300), spacing: 0, alignment: .top)]
            : [GridItem(.flexible())]
    }

    private var browseLibrarySection: some View {
        Group {
            if !visibleLibrarySections.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("library_browse")

                    LazyVStack(spacing: 10) {
                        ForEach(browseRuns) { run in
                            if run.isQuickAccess {
                                quickAccessSection
                                    .padding(.vertical, 8)
                            } else {
                                LazyVGrid(columns: browseCategoryColumns, spacing: 10) {
                                    ForEach(run.sections) { section in
                                        NavigationLink(value: section) {
                                            libraryCategoryRow(section)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.horizontal, 16)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// 把连续的分类入口并成一段, 让它们共用一个网格。
    ///
    /// 「快速访问」不是等高的入口卡片, 而是一条整幅的横向货架 —— 混进两列网格
    /// 会把它所在的那一行撑到两百多点, 旁边的入口卡片跟着被吊在半空。所以货架
    /// 始终独占一行, 只有入口卡片进网格; 用户排的分区顺序不变。
    private var browseRuns: [LibraryBrowseRun] {
        var runs: [LibraryBrowseRun] = []
        var pending: [LibrarySection] = []

        func flushPending() {
            guard let first = pending.first else { return }
            runs.append(LibraryBrowseRun(
                id: "categories:\(first.rawValue)",
                isQuickAccess: false,
                sections: pending
            ))
            pending.removeAll()
        }

        for section in visibleLibrarySections {
            if section == .favorites {
                flushPending()
                runs.append(LibraryBrowseRun(
                    id: "quickAccess",
                    isQuickAccess: true,
                    sections: []
                ))
            } else {
                pending.append(section)
            }
        }
        flushPending()
        return runs
    }

    private func sectionHeader<Trailing: View>(
        _ titleKey: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack {
            Text(titleKey)
                .font(.title3.weight(.bold))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
    }

    private func sectionHeader(_ titleKey: LocalizedStringKey) -> some View {
        sectionHeader(titleKey) {
            EmptyView()
        }
    }

    private func likedArtwork(size: CGFloat, cornerRadius: CGFloat) -> some View {
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
        .shadow(color: .pink.opacity(0.18), radius: 8, y: 4)
    }

    private func quickAccessLabel<Artwork: View>(
        title: String,
        subtitle: String,
        @ViewBuilder artwork: @escaping (CGFloat) -> Artwork
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if usesMinimalSectionControls {
                GeometryReader { geometry in
                    artwork(geometry.size.width)
                }
                .aspectRatio(1, contentMode: .fit)
            } else {
                artwork(116)
                    .frame(width: 116, height: 116)
            }

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(usesMinimalSectionControls ? 2 : 1)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: usesMinimalSectionControls ? nil : 116, alignment: .leading)
        .frame(maxWidth: usesMinimalSectionControls ? .infinity : nil, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var addQuickAccessLabel: some View {
        quickAccessLabel(
            title: String(localized: "library_add_quick_access"),
            subtitle: String(format: String(localized: "favorites_count_format"), visiblePins.count)
        ) { size in
            ZStack {
                RoundedRectangle(cornerRadius: quickAccessCoverStyle == .circle ? size / 2 : 16, style: .continuous)
                    .fill(Color.secondary.opacity(0.07))
                RoundedRectangle(cornerRadius: quickAccessCoverStyle == .circle ? size / 2 : 16, style: .continuous)
                    .stroke(
                        Color.secondary.opacity(0.32),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func pinnedItemCard(_ pin: LibraryPinReference) -> some View {
        switch pin.kind {
        case .album:
            if let album = library.visibleAlbum(id: pin.itemID) {
                NavigationLink(value: album) {
                    quickAccessLabel(
                        title: album.title,
                        subtitle: album.artistName ?? String(localized: "unknown_artist")
                    ) { size in
                        QuickAccessArtworkView(item: .album(album), size: size, cornerRadius: 16) {
                            libraryAlbumArtwork(album, size: size, cornerRadius: 16, showsPlaceholder: true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { favoriteMenu(.album(album)) }
                .mediaZoomSource(.album, id: album.id)
            }
        case .artist:
            if let artist = library.favoriteArtist(id: pin.itemID) {
                NavigationLink(value: artist) {
                    quickAccessLabel(
                        title: artist.name,
                        subtitle: countText(artist.albumCount, unitKey: "albums_count")
                    ) { size in
                        QuickAccessArtworkView(item: .artist(artist), size: size, cornerRadius: 16) {
                            libraryArtistArtwork(artist, size: size, cornerRadius: size / 2, showsPlaceholder: true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { favoriteMenu(.artist(artist)) }
                .mediaZoomSource(.artist, id: artist.id)
            }
        case .playlist:
            if pin.itemID == MusicLibrary.likedSongsPlaylistID {
                NavigationLink(value: likedPlaylist) {
                    quickAccessLabel(
                        title: String(localized: "sidebar_liked_songs"),
                        subtitle: countText(
                            library.songCount(forPlaylist: MusicLibrary.likedSongsPlaylistID),
                            unitKey: "songs_count"
                        )
                    ) { size in
                        QuickAccessArtworkView(item: .playlist(likedPlaylist), size: size, cornerRadius: 16) {
                            likedArtwork(size: size, cornerRadius: 16)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { favoriteMenu(.playlist(likedPlaylist)) }
                .mediaZoomSource(.playlist, id: likedPlaylist.id)
            } else if let playlist = regularPlaylists.first(where: { $0.id == pin.itemID }) {
                NavigationLink(value: playlist) {
                    quickAccessLabel(
                        title: playlist.name,
                        subtitle: countText(
                            library.songCount(forPlaylist: playlist.id),
                            unitKey: "songs_count"
                        )
                    ) { size in
                        QuickAccessArtworkView(item: .playlist(playlist), size: size, cornerRadius: 16) {
                            playlistArtwork(playlist, size: size, cornerRadius: 16)
                        }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { favoriteMenu(.playlist(playlist)) }
                .mediaZoomSource(.playlist, id: playlist.id)
            }
        case .folder:
            if let id = pin.folderNodeID, let node = favoriteFolderModel.index?.node(withID: id) {
                NavigationLink {
                    HomeFolderBrowser(nodeID: node.id)
                        .environment(favoriteFolderModel)
                } label: {
                    quickAccessLabel(
                        title: HomeDiscoveryText.folderTitle(node),
                        subtitle: countText(node.descendantSongCount, unitKey: "songs_count")
                    ) { size in
                        FavoriteCollectionArtwork(entry: .folder(node), size: size)
                            .environment(favoriteFolderModel)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { favoriteMenu(.folder(node)) }
            }
        case .book:
            if let favorite = FavoriteCollectionResolver.book(id: pin.itemID, library: library) {
                NavigationLink {
                    SpokenWordBookDetailView(bookID: favorite.book.id)
                } label: {
                    quickAccessLabel(
                        title: favorite.book.title,
                        subtitle: SpokenWordBookSupport.subtitle(favorite.book)
                    ) { size in
                        FavoriteCollectionArtwork(entry: .book(favorite), size: size)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { favoriteMenu(.book(favorite)) }
            }
        }
    }

    private func favoriteMenu(_ entry: FavoriteCollectionEntry) -> some View {
        FavoriteCollectionMenuItems(
            entry: entry,
            library: library,
            player: player,
            folderIndex: favoriteFolderModel.index
        )
    }

    private func libraryCategoryRow(_ section: LibrarySection) -> some View {
        HStack(spacing: 13) {
            Image(systemName: section.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(section.color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(categoryCountText(section))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            categoryPreview(section)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 72)
        .background(
            Color.secondary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.1), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func categoryPreview(_ section: LibrarySection) -> some View {
        switch section {
        case .favorites, .folders, .statistics, .releaseDate:
            EmptyView()
        case .recommendations:
            overlappingPreview(previewSongs) { song in
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 36,
                    cornerRadius: 7,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
            }
        case .songs:
            overlappingPreview(previewSongs) { song in
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 36,
                    cornerRadius: 7,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
            }
        case .spokenWord:
            overlappingPreview(Array(library.spokenWordSongs.prefix(3))) { song in
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 36,
                    cornerRadius: 7,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
            }
        case .albums:
            artworkPreview(
                previewAlbums,
                placeholderIcon: "square.stack",
                cornerRadius: 7
            ) { album in
                libraryAlbumArtwork(
                    album,
                    size: 36,
                    cornerRadius: 7,
                    showsPlaceholder: false
                )
            }
        case .artists:
            artworkPreview(
                previewArtists,
                placeholderIcon: "music.mic",
                cornerRadius: 18
            ) { artist in
                libraryArtistArtwork(
                    artist,
                    size: 36,
                    cornerRadius: 18,
                    showsPlaceholder: false
                )
            }
        case .genres:
            overlappingPreview(previewGenreSongs) { song in
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 36,
                    cornerRadius: 7,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
            }
        case .playlists:
            overlappingPreview(previewPlaylists) { playlist in
                playlistArtwork(playlist, size: 36, cornerRadius: 7)
            }
        case .radio:
            overlappingPreview(previewRadioStations) { station in
                RadioStationArtworkView(station: station, size: 36, cornerRadius: 7)
            }
        case .podcasts:
            overlappingPreview(Array(PodcastStore.shared.shows.prefix(3))) { show in
                PodcastArtwork(show: show, size: 36, cornerRadius: 7)
            }
        }
    }

    private var hasCurrentArtworkPreviewSelection: Bool {
        artworkPreviewSelection.revision == artworkPreviewRevision
    }

    /// 挑过一次之后就一直显示挑好的那份, 直到新的一份挑完。以前签名一变就先
    /// 退回列表最前面三个, 扫描时每次入库预览都要来回跳一下、整排封面重新加载。
    private var hasArtworkPreviewSelection: Bool {
        !artworkPreviewSelection.revision.isEmpty
    }

    private var previewSongs: [Song] {
        hasArtworkPreviewSelection
            ? artworkPreviewSelection.songs
            : Array(songs.prefix(3))
    }

    private var previewAlbums: [Album] {
        hasArtworkPreviewSelection
            ? artworkPreviewSelection.albums
            : Array(albums.prefix(3))
    }

    private var previewArtists: [Artist] {
        hasArtworkPreviewSelection
            ? artworkPreviewSelection.artists
            : Array(artists.prefix(3))
    }

    private var previewGenreSongs: [Song] {
        genres.prefix(3).compactMap { genre in
            genre.representativeSongIDs.lazy.compactMap { library.visibleSong(id: $0) }.first
        }
    }

    private var previewPlaylists: [Playlist] {
        hasArtworkPreviewSelection
            ? artworkPreviewSelection.playlists
            : Array(regularPlaylists.prefix(3))
    }

    private var previewRadioStations: [RadioStation] {
        hasArtworkPreviewSelection
            ? artworkPreviewSelection.radioStations
            : Array(radioStationsStore.stations.prefix(3))
    }

    private func albumFallbackSongs(_ album: Album) -> [Song] {
        if let songs = artworkPreviewSelection.albumFallbackSongs[album.id] {
            return songs
        }
        if hasCurrentArtworkPreviewSelection {
            return []
        }
        return library.preferredArtworkSong(forAlbumID: album.id).map { [$0] } ?? []
    }

    private func artistFallbackSongs(_ artist: Artist) -> [Song] {
        artworkPreviewSelection.artistFallbackSongs[artist.id] ?? []
    }

    private func libraryAlbumArtwork(
        _ album: Album,
        size: CGFloat,
        cornerRadius: CGFloat,
        showsPlaceholder: Bool
    ) -> some View {
        ZStack {
            if showsPlaceholder {
                artworkPlaceholder(
                    size: size,
                    cornerRadius: cornerRadius,
                    icon: "square.stack"
                )
            }

            ForEach(Array(albumFallbackSongs(album).reversed())) { song in
                fallbackSongArtwork(song, size: size)
            }

            AlbumArtworkView(
                album: album,
                size: size,
                cornerRadius: cornerRadius,
                showsPlaceholder: false
            )
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func libraryArtistArtwork(
        _ artist: Artist,
        size: CGFloat,
        cornerRadius: CGFloat,
        showsPlaceholder: Bool
    ) -> some View {
        ZStack {
            if showsPlaceholder {
                artworkPlaceholder(
                    size: size,
                    cornerRadius: cornerRadius,
                    icon: "music.mic"
                )
            }

            ForEach(Array(artistFallbackSongs(artist).reversed())) { song in
                fallbackSongArtwork(song, size: size)
            }

            ArtistArtworkView(
                artist: artist,
                size: size,
                cornerRadius: cornerRadius,
                showsPlaceholder: false
            )
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func artworkPlaceholder(
        size: CGFloat,
        cornerRadius: CGFloat,
        icon: String
    ) -> some View {
        CachedArtworkView(
            coverRef: nil,
            songID: nil,
            size: size,
            cornerRadius: cornerRadius,
            placeholderIcon: icon,
            showsPlaceholder: true
        )
    }

    private func fallbackSongArtwork(_ song: Song, size: CGFloat) -> some View {
        CachedArtworkView(
            coverRef: song.coverArtFileName,
            songID: song.id,
            size: size,
            cornerRadius: 0,
            sourceID: song.sourceID,
            filePath: song.filePath,
            fileFormat: song.fileFormat,
            showsPlaceholder: false
        )
    }

    private func overlappingPreview<Item: Identifiable, Content: View>(
        _ items: [Item],
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        HStack(spacing: -10) {
            if items.isEmpty {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: 36, height: 36)
            } else {
                ForEach(items) { item in
                    content(item)
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        }
                }
            }
        }
        .frame(width: 68, alignment: .trailing)
    }

    private func artworkPreview<Item: Identifiable, Content: View>(
        _ items: [Item],
        placeholderIcon: String,
        cornerRadius: CGFloat,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        ZStack(alignment: .trailing) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
                Image(systemName: placeholderIcon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 36, height: 36)

            HStack(spacing: -10) {
                ForEach(items) { item in
                    content(item)
                }
            }
        }
        .frame(width: 68, height: 36, alignment: .trailing)
    }

    @ViewBuilder
    private func playlistArtwork(_ playlist: Playlist, size: CGFloat, cornerRadius: CGFloat) -> some View {
        PlaylistArtworkView(playlist: playlist, size: size, cornerRadius: cornerRadius)
    }

    @MainActor
    private func refreshArtworkPreviews(for revision: String) async {
        if artworkPreviewSelection.revision == revision { return }
        if let cached = LibraryArtworkPreviewSessionStore.shared.cachedSelection(
            for: revision
        ) {
            artworkPreviewSelection = cached
            return
        }
        let userRevision = artworkPreviewUserRevision
        // 封面预览只是入口上的装饰, 不需要跟着扫描、回填实时换: 已经有一份、
        // 而且变的只是资料库内容时, 最少隔一段才重挑(签名再变会取消这次等待,
        // 按上次挑完的时刻重新算)。快捷访问、手选封面这些用户改动照常立刻重挑。
        let delaySeconds: TimeInterval
        if hasArtworkPreviewSelection, artworkPreviewSelection.userRevision == userRevision {
            let elapsed = artworkPreviewBuiltAt.map { Date().timeIntervalSince($0) }
            delaySeconds = LibraryDerivedRefreshPolicy.artworkPreviewDelay(sinceLastRefresh: elapsed)
        } else {
            delaySeconds = LibraryDerivedRefreshPolicy.artworkPreviewDebounce
        }
        do {
            try await Task.sleep(for: .seconds(delaySeconds))
        } catch {
            return
        }
        guard !Task.isCancelled, artworkPreviewRevision == revision else { return }
        let songsSnapshot = songs
        let albumsSnapshot = albums
        let artistsSnapshot = artists
        let playlistsSnapshot = regularPlaylists
        let radioSnapshot = radioStationsStore.stations
        // 收藏货架上摆出来的那几张才要备用封面。
        let pinnedAlbumIDs = Set(hubPins.compactMap { pin in
            pin.kind == .album ? pin.itemID : nil
        })
        let pinnedArtistIDs = Set(hubPins.compactMap { pin in
            pin.kind == .artist ? pin.itemID : nil
        })

        // 只看真的设过封面的那几个, 不再对每张专辑、每个艺人逐个问一遍 ——
        // 那是主线程上随整库大小走的一趟。
        var albumOverrides = Set<String>()
        var artistOverrides = Set<String>()
        var playlistOverrides = Set<String>()
        for override in library.allArtworkOverrides {
            let presentation = library.artworkPresentation(for: override.owner)
            guard presentation.uploadedContentID != nil || presentation.selectedSong != nil else {
                continue
            }
            switch override.owner.kind {
            case .album: albumOverrides.insert(override.owner.id)
            case .artist: artistOverrides.insert(override.owner.id)
            case .playlist: playlistOverrides.insert(override.owner.id)
            }
        }
        let albumOverrideIDs = albumOverrides
        let artistOverrideIDs = artistOverrides
        let playlistOverrideIDs = playlistOverrides
        // 歌单成员只取 id(字典取值 + 写时复制), 判断有没有封面线索放到后台。
        let playlistMemberIDs = Dictionary(
            playlistsSnapshot.map { ($0.id, library.rawSongIDs(forPlaylist: $0.id)) },
            uniquingKeysWith: { first, _ in first }
        )

        let selection = await LibraryArtworkPreviewSessionStore.shared.selection(
            for: revision
        ) { randomSeed in
            // 只要几组 id, 不复制一份整库歌曲数组。
            var albumIDsWithSongArtworkHint = Set<String>()
            var artistIDsWithSongArtworkHint = Set<String>()
            var songIDsWithArtworkHint = Set<String>()
            for song in songsSnapshot where LibraryArtworkPreviewBuilder.songHasArtworkHint(song) {
                songIDsWithArtworkHint.insert(song.id)
                if let albumID = song.albumID { albumIDsWithSongArtworkHint.insert(albumID) }
                if let artistID = song.artistID { artistIDsWithSongArtworkHint.insert(artistID) }
            }
            let playlistIDsWithMemberArtworkHint = Set(playlistMemberIDs.compactMap { entry in
                entry.value.contains(where: songIDsWithArtworkHint.contains) ? entry.key : nil
            })

            let selectedSongs = LibraryArtworkPreviewBuilder.select(
                songsSnapshot,
                randomSeed: "\(randomSeed)#songs",
                id: \Song.id,
                hasArtworkHint: LibraryArtworkPreviewBuilder.songHasArtworkHint
            )
            let selectedAlbums = LibraryArtworkPreviewBuilder.select(
                albumsSnapshot,
                randomSeed: "\(randomSeed)#albums",
                id: \Album.id
            ) { album in
                albumOverrideIDs.contains(album.id)
                    || MetadataAssetStore.shared.hasAlbumCover(forAlbumID: album.id)
                    || albumIDsWithSongArtworkHint.contains(album.id)
            }
            let selectedArtists = LibraryArtworkPreviewBuilder.select(
                artistsSnapshot,
                randomSeed: "\(randomSeed)#artists",
                id: \Artist.id
            ) { artist in
                artistOverrideIDs.contains(artist.id)
                    || LibraryArtworkPreviewBuilder.hasReference(artist.thumbnailPath)
                    || MetadataAssetStore.shared.hasArtistImage(forArtistID: artist.id)
                    || artistIDsWithSongArtworkHint.contains(artist.id)
            }
            let selectedPlaylists = LibraryArtworkPreviewBuilder.select(
                playlistsSnapshot,
                randomSeed: "\(randomSeed)#playlists",
                id: \Playlist.id
            ) { playlist in
                playlistOverrideIDs.contains(playlist.id)
                    || (
                        playlist.hasDedicatedCoverArt
                            && LibraryArtworkPreviewBuilder.hasReference(playlist.coverArtPath)
                    )
                    || playlistIDsWithMemberArtworkHint.contains(playlist.id)
            }
            let selectedRadioStations = LibraryArtworkPreviewBuilder.select(
                radioSnapshot,
                randomSeed: "\(randomSeed)#radio",
                id: \RadioStation.id
            ) { station in
                station.logoData.map(ArtworkImageCompatibility.isCompleteImage) == true
                    || LibraryArtworkPreviewBuilder.hasReference(station.logoFileName)
            }

            let fallbackAlbumIDs = pinnedAlbumIDs.union(selectedAlbums.map(\.id))
            let albumGroups = Dictionary(grouping: songsSnapshot.filter { song in
                song.albumID.map(fallbackAlbumIDs.contains) == true
            }) { $0.albumID ?? "" }
            let albumFallbackSongs = albumGroups.mapValues { albumSongs in
                LibraryArtworkPreviewBuilder.select(
                    albumSongs,
                    randomSeed: "\(randomSeed)#album#\(albumSongs.first?.albumID ?? "")",
                    id: \Song.id,
                    hasArtworkHint: LibraryArtworkPreviewBuilder.songHasArtworkHint
                )
            }

            let fallbackArtistIDs = pinnedArtistIDs.union(selectedArtists.map(\.id))
            let artistGroups = Dictionary(grouping: songsSnapshot.filter { song in
                song.artistID.map(fallbackArtistIDs.contains) == true
            }) { $0.artistID ?? "" }
            let artistFallbackSongs = artistGroups.mapValues { artistSongs in
                LibraryArtworkPreviewBuilder.select(
                    artistSongs,
                    randomSeed: "\(randomSeed)#artist#\(artistSongs.first?.artistID ?? "")",
                    id: \Song.id,
                    hasArtworkHint: LibraryArtworkPreviewBuilder.songHasArtworkHint
                )
            }

            return LibraryArtworkPreviewSelection(
                revision: revision,
                userRevision: userRevision,
                songs: selectedSongs,
                albums: selectedAlbums,
                artists: selectedArtists,
                playlists: selectedPlaylists,
                radioStations: selectedRadioStations,
                albumFallbackSongs: albumFallbackSongs,
                artistFallbackSongs: artistFallbackSongs
            )
        }

        guard !Task.isCancelled,
              artworkPreviewRevision == revision,
              let selection else { return }
        artworkPreviewSelection = selection
        artworkPreviewBuiltAt = Date()
    }

    private func categoryCountText(_ section: LibrarySection) -> String {
        switch section {
        case .favorites:
            return String(localized: "library_quick_access")
        case .folders:
            return countText(songs.count, unitKey: "songs_count")
        case .statistics:
            return String(localized: "stats_section_label")
        case .releaseDate:
            return String(localized: "library_release_date_subtitle")
        case .recommendations:
            return String(localized: "library_recommendations_subtitle")
        case .songs:
            // 「歌曲」只数音乐,有声内容在有声那一页按书计。
            return countText(library.musicSongs.count, unitKey: "songs_count")
        case .spokenWord:
            return countText(library.spokenWordSongs.count, unitKey: "songs_count")
        case .albums:
            return countText(albums.count, unitKey: "albums_count")
        case .artists:
            return countText(artists.count, unitKey: "artists_count")
        case .genres:
            return countText(genres.count, unitKey: "genres_count")
        case .playlists:
            return countText(
                regularPlaylists.count + library.smartPlaylists.count,
                unitKey: "playlists_count"
            )
        case .radio:
            return countText(radioStationsStore.stations.count, unitKey: "radio_stations_count")
        case .podcasts:
            return countText(PodcastStore.shared.shows.count, unitKey: "podcast_shows_count")
        }
    }

    private func countText(_ count: Int, unitKey: String.LocalizationValue) -> String {
        "\(count.formatted()) \(String(localized: unitKey))"
    }

    private var usesMinimalSectionControls: Bool {
        #if os(iOS)
        appNavigationMode == .minimal
        #else
        false
        #endif
    }

    @ViewBuilder
    private func destination(for section: LibrarySection) -> some View {
        switch section {
        case .favorites:
            FavoriteCollectionView()
        case .folders:
            HomeFolderManagementView(usesInlineControls: usesMinimalSectionControls)
        case .statistics:
            ListeningStatsScreen(usesInlineSourcePicker: usesMinimalSectionControls)
        case .releaseDate:
            ReleaseDateLibraryView()
        case .recommendations:
            AIRecommendationLibraryView()
        case .songs:
            SongListView(locationRequest: $songLocationRequest)
                #if os(iOS)
                .environment(\.songListShowsListeningIntents, usesMinimalSectionControls && showsMinimalStartListening)
                #endif
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
            RadioStationsView()
        case .podcasts:
            PodcastLibraryView()
        }
    }

    private var emptyLibraryState: some View {
        ContentUnavailableView {
            Label("welcome_title", systemImage: "music.note.list")
        } description: {
            Text("welcome_desc")
        } actions: {
            // 两个按钮等宽：文案长度不同，让宽度跟着文字走会让它们上下参差。
            // 图标沿用各自在设置页与电台页已有的符号，和上方标题的图标呼应。
            VStack(spacing: 12) {
                manageSourcesButton
                    .buttonStyle(.borderedProminent)
                    .prominentLabelOnAccent()

                NavigationLink(value: LibrarySection.radio) {
                    Label("radio_manage", systemImage: "radio")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            // 空状态是整屏留白，不限宽的话按钮在 iPad 与桌面上会拉成一条横杠。
            .frame(maxWidth: 280)
        }
    }

    private var manageSourcesLabel: some View {
        Label(
            "manage_sources",
            systemImage: "externaldrive.connected.to.line.below"
        )
        .frame(maxWidth: .infinity)
    }

    /// iOS 上跳到「设置 › 音乐源」，而不是把音乐源页推进资料库自己的导航栈。
    ///
    /// 这个按钮只活在空状态里，而空状态在扫到第一首歌的那一刻就会被换成资料库
    /// 主页 —— 那时用户正停在被它推出来的音乐源页上。承载 NavigationLink 的视图
    /// 从层级里消失之后，推出去的那一页就成了没有主人的页面，返回键跟着不见，
    /// 用户被困在里面。设置页自己的导航栈根视图不会中途换掉，音乐源页也本来就
    /// 住在那里，所以两个入口（这里和首页）都汇到那一处。
    @ViewBuilder
    private var manageSourcesButton: some View {
        #if os(iOS)
        Button {
            SettingsNavigation.shared.open(SettingsPage.sources.id)
        } label: {
            manageSourcesLabel
        }
        #else
        NavigationLink {
            SourcesContentView()
        } label: {
            manageSourcesLabel
        }
        #endif
    }

    private func pinExists(_ pin: LibraryPinReference) -> Bool {
        switch pin.kind {
        case .album:
            return library.visibleAlbum(id: pin.itemID) != nil
        case .artist:
            return library.favoriteArtist(id: pin.itemID) != nil
        case .playlist:
            if pin.itemID == MusicLibrary.likedSongsPlaylistID { return true }
            return regularPlaylists.contains { $0.id == pin.itemID }
        case .folder:
            return pin.folderNodeID.flatMap { favoriteFolderModel.index?.node(withID: $0) } != nil
        case .book:
            return library.spokenWordBookIDs.values.contains(pin.itemID)
        }
    }

    private func applyDeepLink(_ link: LibraryDeepLink?) {
        guard let link else { return }
        didRestorePersistedPage = true
        var path = NavigationPath()
        switch link {
        case .root:
            songLocationRequest = nil
            persistedPageID = ""
            onActiveSectionChange(nil)
        case .section(let section):
            persistedPageID = "section:\(section.rawValue)"
            path.append(section)
            onActiveSectionChange(section)
        case .album(let album):
            path.append(album)
        case .artist(let artist):
            path.append(artist)
        case .playlist(let playlist):
            path.append(playlist)
        case .song(let songID):
            songLocationRequest = SongLibraryLocationRequest(songID: songID)
            persistedPageID = "section:\(LibrarySection.songs.rawValue)"
            path.append(LibrarySection.songs)
        }
        navigationPath = path
        deepLink = nil
    }

    private func restorePersistedPageIfNeeded() {
        guard !didRestorePersistedPage else { return }
        didRestorePersistedPage = true
        var path = NavigationPath()
        if let rawValue = identifier(in: persistedPageID, after: "section:"),
           let section = LibrarySection(rawValue: rawValue),
           visibleLibrarySections.contains(section) {
            path.append(section)
        } else if let itemID = identifier(in: persistedPageID, after: "album:"),
                  let album = albums.first(where: { $0.id == itemID }) {
            path.append(album)
        } else if let itemID = identifier(in: persistedPageID, after: "artist:"),
                  let artist = artists.first(where: { $0.id == itemID }) {
            path.append(artist)
        } else if let itemID = identifier(in: persistedPageID, after: "playlist:") {
            if let playlist = library.playlists.first(where: { $0.id == itemID }) {
                path.append(playlist)
            } else if itemID == MusicLibrary.likedSongsPlaylistID {
                path.append(likedPlaylist)
            } else {
                persistedPageID = ""
                return
            }
        } else {
            persistedPageID = ""
            return
        }
        navigationPath = path
    }

    private func identifier(in value: String, after prefix: String) -> String? {
        guard value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }
}

private struct GenreVisualPalette {
    let leading: Color
    let trailing: Color
}

private enum GenreVisualStyle {
    private static let palettes: [GenreVisualPalette] = [
        .init(
            leading: Color(red: 0.16, green: 0.46, blue: 0.43),
            trailing: Color(red: 0.05, green: 0.19, blue: 0.27)
        ),
        .init(
            leading: Color(red: 0.66, green: 0.27, blue: 0.39),
            trailing: Color(red: 0.25, green: 0.08, blue: 0.22)
        ),
        .init(
            leading: Color(red: 0.64, green: 0.42, blue: 0.12),
            trailing: Color(red: 0.25, green: 0.14, blue: 0.06)
        ),
        .init(
            leading: Color(red: 0.37, green: 0.31, blue: 0.68),
            trailing: Color(red: 0.13, green: 0.10, blue: 0.30)
        ),
        .init(
            leading: Color(red: 0.18, green: 0.43, blue: 0.66),
            trailing: Color(red: 0.06, green: 0.16, blue: 0.33)
        ),
        .init(
            leading: Color(red: 0.61, green: 0.26, blue: 0.18),
            trailing: Color(red: 0.25, green: 0.09, blue: 0.07)
        ),
    ]

    static func palette(for genreID: String) -> GenreVisualPalette {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in genreID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return palettes[Int(hash % UInt64(palettes.count))]
    }
}

struct GenreLibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @State private var searchText = ""
    #if os(iOS)
    @Environment(\.pmHeightClass) private var heightClass
    #endif
    #if os(macOS)
    @State private var selectedGenreID: String?
    #endif

    private var filteredGenres: [LibraryGenre] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.visibleGenres
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
            .navigationDestination(for: LibraryGenre.self) { genre in
                GenreDetailView(genre: genre)
            }
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var iosBody: some View {
        if library.visibleGenres.isEmpty {
            EmptyStateView(
                titleKey: "no_genres",
                descriptionKey: "no_genres_desc",
                systemImage: "tag"
            )
            .pmAppearFade(.contentAppear)
        } else {
            // 手机横屏下卡片降一档: 竖屏 2 列 × 142 高, 横屏 4-5 列 × 112 高,
            // 一屏能看到两行而不是一行半。
            let cardMinimumWidth = heightClass.value(156, compact: 124)
            let cardHeight = heightClass.value(142, compact: 112)
            ScrollView {
                if filteredGenres.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 80)
                        .pmAppearFade(.contentAppear)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: cardMinimumWidth), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(filteredGenres) { genre in
                            NavigationLink(value: genre) {
                                LibraryGenreCard(genre: genre, height: cardHeight)
                            }
                            .buttonStyle(.pmPressable)
                        }
                    }
                    .padding(16)
                    // 只在"有结果 ↔ 没结果"这一层重建时淡入一次, 逐键过滤的网格本身不动。
                    .pmAppearFade(.contentAppear)
                }
            }
            .pmExtendsUnderVerticalBar()
            .libraryPageFind(text: $searchText, prompt: "genre_search_placeholder")
        }
    }
    #endif

    #if os(macOS)
    private var selectedGenre: LibraryGenre? {
        if let selectedGenreID,
           let genre = filteredGenres.first(where: { $0.id == selectedGenreID }) {
            return genre
        }
        return filteredGenres.first
    }

    @ViewBuilder
    private var macBody: some View {
        if library.visibleGenres.isEmpty {
            ContentUnavailableView(
                "no_genres",
                systemImage: "tag",
                description: Text("no_genres_desc")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PMColor.bg.ignoresSafeArea())
        } else {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("tab_genres")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(PMColor.text)

                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 11))
                                .foregroundStyle(PMColor.textFaint)
                            TextField(
                                "",
                                text: $searchText,
                                prompt: Text("genre_search_placeholder")
                            )
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(PMColor.glassBtn, in: RoundedRectangle(cornerRadius: PMRadius.s))
                        .overlay {
                            RoundedRectangle(cornerRadius: PMRadius.s)
                                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                    if filteredGenres.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 2) {
                                ForEach(filteredGenres) { genre in
                                    macGenreRow(genre)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.bottom, 24)
                        }
                    }
                }
                .frame(width: 280)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(PMColor.bg)

                Rectangle().fill(PMColor.divider).frame(width: 0.5)

                if let selectedGenre {
                    // 淡入挂在 .id 里面: 换流派时身份重建, 修饰符的状态才会跟着重置。
                    GenreDetailView(genre: selectedGenre)
                        .pmAppearFade()
                        .id(selectedGenre.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(PMColor.bg.ignoresSafeArea())
        }
    }

    private func macGenreRow(_ genre: LibraryGenre) -> some View {
        let selected = selectedGenre?.id == genre.id
        return Button {
            selectedGenreID = genre.id
        } label: {
            HStack(spacing: 10) {
                GenreArtworkMosaic(genre: genre, artworkSize: 30)
                    .frame(width: 52, height: 40)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: genre.name)
                        .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(verbatim: "\(genre.albumCount) \(String(localized: "albums_count")) · \(genre.songCount) \(String(localized: "songs_count"))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .pmRowBackground(selected: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif
}

private struct LibraryGenreCard: View {
    let genre: LibraryGenre
    /// 卡片高度由调用处按纵向尺寸等级给, 卡片自己不读环境 —— 它也编进 Mac target。
    var height: CGFloat = 142

    var body: some View {
        let palette = GenreVisualStyle.palette(for: genre.id)
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [palette.leading, palette.trailing],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            GenreArtworkMosaic(genre: genre, artworkSize: 66)
                .frame(width: 116, height: 86)
                .offset(x: 62, y: 12)
                .opacity(0.88)

            LinearGradient(
                colors: [.black.opacity(0.12), .black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: genre.name)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(verbatim: "\(genre.albumCount) \(String(localized: "albums_count")) · \(genre.songCount) \(String(localized: "songs_count"))")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .lineLimit(1)
            }
            .padding(13)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: genre.name))
        .accessibilityValue(Text(verbatim: "\(genre.albumCount) \(String(localized: "albums_count")), \(genre.songCount) \(String(localized: "songs_count"))"))
    }
}

private struct GenreArtworkMosaic: View {
    @Environment(MusicLibrary.self) private var library
    let genre: LibraryGenre
    let artworkSize: CGFloat

    private var songs: [Song] {
        genre.representativeSongIDs.compactMap { library.visibleSong(id: $0) }
    }

    var body: some View {
        ZStack {
            if songs.isEmpty {
                RoundedRectangle(cornerRadius: artworkSize * 0.18, style: .continuous)
                    .fill(.white.opacity(0.14))
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: artworkSize * 0.28, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.74))
                    }
                    .frame(width: artworkSize, height: artworkSize)
            } else {
                ForEach(Array(songs.prefix(3).enumerated()), id: \.element.id) { index, song in
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: artworkSize,
                        cornerRadius: artworkSize * 0.16,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: artworkSize * 0.16)
                            .stroke(.white.opacity(0.28), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(0.26), radius: artworkSize * 0.07, y: artworkSize * 0.04)
                    .rotationEffect(.degrees((Double(index) - Double(songs.count - 1) / 2) * 7))
                    .offset(x: (CGFloat(index) - CGFloat(songs.count - 1) / 2) * artworkSize * 0.34)
                    .zIndex(Double(index))
                }
            }
        }
    }
}

#if DEBUG && os(iOS)
/// 调试取证页（`LibraryDetailEvidenceHost`）用：流派详情页本身是这个文件私有的。
struct DebugGenreDetailEvidencePage: View {
    let genre: LibraryGenre

    var body: some View {
        GenreDetailView(genre: genre)
    }
}
#endif

private struct GenreDetailView: View {
    #if os(iOS)
    @Environment(\.legacyBottomChromeOverlayActive)
    private var legacyBottomChromeOverlayActive
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(CoverTintProvider.self) private var coverTints
    @Environment(\.colorScheme) private var colorScheme
    #endif
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill

    let genre: LibraryGenre
    @State private var selection = SongSelectionModel()

    /// 手机横屏 (纵向紧凑) 才压缩 hero。Mac 没有纵向尺寸等级, 恒为 false。
    private var usesCompactHero: Bool {
        #if os(iOS)
        heightClass.isCompact
        #else
        false
        #endif
    }

    /// IDs only: a broad genre can hold most of a large library, and every
    /// body pass used to copy all of its songs several times.
    private var songIDs: [String] { library.songIDs(forGenre: genre.id) }

    #if os(iOS)
    /// 风格没有自己的封面, 用它的第一首代表曲 —— 也就是马赛克里最上面那张。
    private var artworkTintSong: Song? {
        genre.representativeSongIDs.lazy.compactMap { library.visibleSong(id: $0) }.first
            ?? songIDs.first.flatMap { library.visibleSong(id: $0) }
    }

    /// 取不到封面色时退回这个风格原来的固定配色, 风格之间仍然分得开。
    private var tint: LibraryDetailTintStyle {
        let artworkColor = artworkTintSong.flatMap { coverTints.tint(forSongID: $0.id) }
        return .artwork(
            artworkColor ?? GenreVisualStyle.palette(for: genre.id).leading,
            colorScheme: colorScheme
        )
    }
    #endif

    private var albums: [Album] {
        library.albums(forGenre: genre.id).sorted { lhs, rhs in
            let lhsYear = lhs.year ?? Int.min
            let rhsYear = rhs.year ?? Int.min
            if lhsYear != rhsYear { return lhsYear > rhsYear }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            ImmersiveLibraryDetailScrollView { insets in
                hero(insets: insets)
            } content: {
                VStack(alignment: .leading, spacing: 28) {
                    if !albums.isEmpty { albumShelf }
                    if !songIDs.isEmpty { songSection }
                }
                .padding(.top, 28)
                .padding(.bottom, BottomChromeClearancePolicy.clearance(
                    legacyOverlayActive: legacyBottomChromeOverlayActive,
                    legacy: 64,
                    baseline: 16
                ))
            }
            .navigationTitle("")
            #else
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero(insets: ImmersiveLibraryDetailInsets())

                    if !albums.isEmpty { albumShelf }
                    if !songIDs.isEmpty { songSection }
                }
                .padding(.bottom, 64)
            }
            .background(PMColor.bg.ignoresSafeArea())
            .navigationTitle(Text(verbatim: genre.name))
            #endif
        }
        .toolbarTitleDisplayMode(.inline)
        #if os(iOS)
        .libraryDetailTint(from: artworkTintSong)
        .minimalNavigationDetail()
        .librarySearchContext {
            LibrarySearchScope(title: genre.name, songIDs: Set(songIDs), kind: .genre)
        }
        #endif
        .songBatchActions(
            selection: selection,
            orderedIDs: { songIDs },
            resolve: { library.song(id: $0) }
        )
    }

    /// 竖屏的 `topInset + 100` 是照着状态栏 + 导航栏标定的; 手机横屏顶部安全区塌成 0,
    /// 那 100 就白占了整块首屏。紧凑高度下顶部留白、标题字号、马赛克都降一档,
    /// hero 压到 170pt 以内, 专辑架和第一首歌才露得出来。结构不变。
    private func hero(insets: ImmersiveLibraryDetailInsets) -> some View {
        let compact = usesCompactHero
        #if os(macOS)
        // Mac 的头图上面没有状态栏和导航栏要让, 照 iPhone 留 100 点就是标题上方一大块空白。
        let heroTopPadding: CGFloat = 36
        #else
        let heroTopPadding: CGFloat = compact ? 28 : 100
        #endif
        let heroBottomPadding: CGFloat = compact ? 14 : 28
        let blockSpacing: CGFloat = compact ? 10 : 16
        let titleLineLimit = compact ? 1 : 2
        let mosaicWidth: CGFloat = compact ? 150 : 220
        let mosaicHeight: CGFloat = compact ? 100 : 150
        let mosaicArtworkSize: CGFloat = compact ? 80 : 116

        return VStack(alignment: .leading, spacing: blockSpacing) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: genre.name)
                    #if os(macOS)
                    .font(.system(size: 42, weight: .bold))
                    #else
                    .font(compact ? Font.title.weight(.bold) : Font.largeTitle.weight(.bold))
                    #endif
                    .foregroundStyle(.white)
                    .lineLimit(titleLineLimit)
                    .minimumScaleFactor(compact ? 0.82 : 1)
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    verbatim:
                        "\(albums.count) \(String(localized: "albums_count")) · \(songIDs.count) \(String(localized: "songs_count"))"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.74))
            }

            LibraryDetailPlayShuffleRow(
                fillsWidth: false,
                stacksAtLargeType: false,
                playDisabled: songIDs.isEmpty,
                shuffleDisabled: songIDs.count < 2,
                play: playAll,
                shuffle: shuffleAll
            )

            LibraryReviewSection(
                subject: .genre(genre.id),
                compact: true,
                onArtwork: true
            )
        }
        // 渐变底图铺满整幅屏幕, 文字与按钮按侧留在安全区内 —— 横屏两侧不一定相等。
        .padding(.leading, insets.leading + 20)
        .padding(.trailing, insets.trailing + 20)
        .padding(.top, insets.top + heroTopPadding)
        .padding(.bottom, heroBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            heroBackdrop(
                insets: insets,
                mosaicWidth: mosaicWidth,
                mosaicHeight: mosaicHeight,
                mosaicArtworkSize: mosaicArtworkSize
            )
        }
        .clipped()
    }

    /// 头图底: 整页底色打底, 右上角压那叠代表封面, 再往下化进页面底色 ——
    /// 接下去的专辑架和歌曲列表用的就是这个颜色, 所以看不出头图在哪儿结束。
    private func heroBackdrop(
        insets: ImmersiveLibraryDetailInsets,
        mosaicWidth: CGFloat,
        mosaicHeight: CGFloat,
        mosaicArtworkSize: CGFloat
    ) -> some View {
        #if os(iOS)
        let leading = tint.top
        let trailing = tint.bottom
        let fade = LinearGradient(
            stops: [
                .init(color: .black.opacity(0.05), location: 0),
                .init(color: tint.top.opacity(0.42), location: 0.55),
                .init(color: tint.top, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        #else
        let palette = GenreVisualStyle.palette(for: genre.id)
        let leading = palette.leading
        let trailing = palette.trailing
        let fade = LinearGradient(
            colors: [.black.opacity(0.05), .black.opacity(0.76)],
            startPoint: .top,
            endPoint: .bottom
        )
        #endif

        return LinearGradient(
            colors: [leading, trailing],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            GenreArtworkMosaic(genre: genre, artworkSize: mosaicArtworkSize)
                .frame(width: mosaicWidth, height: mosaicHeight)
                .padding(.top, insets.top + 12)
                .padding(.trailing, insets.trailing + 16)
                .opacity(0.8)
                .accessibilityHidden(true)
        }
        .overlay { fade }
    }

    private var albumShelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            detailSectionTitle("albums_section")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            AlbumCardView(album: album).frame(width: 142)
                        }
                        .buttonStyle(.plain)
                        .mediaZoomSource(.album, id: album.id)
                    }
                }
                .padding(.horizontal, 20)
            }
            .pmStopsAtVerticalBar()
            .contentMargins(.horizontal, 0, for: .scrollContent)
        }
    }

    private var songSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            detailSectionTitle("all_songs_section")

            let ids = songIDs
            let lastID = ids.last
            LazyVStack(spacing: 0) {
                ForEach(ids, id: \.self) { songID in
                    if let song = library.unobservedVisibleSong(id: songID) {
                        SongRowView(
                            song: song,
                            isPlaying: player.currentSong?.id == song.id,
                            selection: selection,
                            context: SongRowView.context(
                                for: song,
                                sourcesStore: sourcesStore,
                                backfill: backfill
                            )
                        )
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { playSong(song) }
                        .songSelectable(
                            songID: song.id,
                            selection: selection,
                            orderedIDs: { songIDs }
                        )

                        if songID != lastID {
                            Divider().padding(.leading, 66)
                        }
                    }
                }
            }
            #if os(iOS)
            .songRowColumnsContainer()
            .libraryDetailSection(tint: tint)
            #else
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.primary.opacity(0.06), lineWidth: 0.5)
            }
            #endif
            .padding(.horizontal, 20)
        }
    }

    private func detailSectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .padding(.horizontal, 20)
    }

    private func playAll() {
        let ids = songIDs
        guard !ids.isEmpty else { return }
        Task { await player.play(queueIDs: ids) }
    }

    private func shuffleAll() {
        let ids = songIDs
        guard !ids.isEmpty else { return }
        player.shuffleEnabled = true
        Task { await player.play(queueIDs: ids, order: .shuffled) }
    }

    private func playSong(_ song: Song) {
        let ids = songIDs
        guard let index = ids.firstIndex(of: song.id) else { return }
        SiriMediaInteractionDonor.donate(song: song)
        Task { await player.play(queueIDs: ids, startingAt: index) }
    }
}

#Preview {
    LibraryView()
        .environment(MusicLibrary())
}
