#if os(tvOS)
import SwiftUI
import PrimuseKit

/// 资料库网格的浏览位置。播放专辑会切到「正在播放」,资料库整页随之移出视图树;
/// 回来时靠它把渲染范围、滚动位置和焦点放回上次那张卡片,不再从头找起。
/// 普通引用类型而非 @Observable:焦点每挪一格就写一次,不能因此让资料库整页重算。
@MainActor
final class TVLibraryBrowseMemory {
    var albumID: String?
    var artistID: String?
    /// 上次聚焦的专辑 / 艺人在墙上的位置,同歌曲页:只用来免掉整墙逐个找。
    var albumIndex: Int?
    var artistIndex: Int?
    /// 歌曲页上次聚焦的那首和它在列表里的位置(位置只用来免掉几十万首里逐个找)。
    var songID: String?
    var songIndex: Int?
    /// 从哪张专辑页开始播放、点的是哪一首。播放页按 Menu 回来时先回到这张专辑页、
    /// 焦点落在那一首,再按一次才回海报墙;在专辑页里按 Menu 关掉就清空。
    var albumDetailID: String?
    var albumDetailSongID: String?
    /// 同上,从艺人页开始播放的:回来先重开这位艺人的页。
    var artistDetail: TVArtist?
    var artistDetailSongID: String?
    /// 同上,从流派 / 排行点开的那一组歌(`TVSongCollectionView`)里开始播放的。
    var collectionDetail: TVBrowseDestination?
    var collectionDetailSongID: String?
    /// 流派墙上点开过的那一格:关掉流派页、从播放页回来时焦点回到它。
    var genreID: String?
    /// 文件夹页停在哪一层(经顶栏换页再回来也还在这一层),和在这里开播的那首。
    var folderPath: [LibraryFolderNodeID] = []
    var folderSongID: String?
    /// 只有从播放页按 Menu 回来的那一次才重开详情页;经顶栏换页再回来不弹。
    var restoresAfterPlayer = false

    /// 开播时记下新的那一页之前,先忘掉上一次从别的详情页开播的记录。
    func forgetDetails() {
        albumDetailID = nil
        albumDetailSongID = nil
        artistDetail = nil
        artistDetailSongID = nil
        collectionDetail = nil
        collectionDetailSongID = nil
        folderSongID = nil
    }
}

/// 首页的返回位置。首页各排卡片按下就播放(或先进专辑页),首页随之移出视图树;
/// 从播放页按 Menu 回来时靠它把焦点放回进去前的那张卡片、或先重开那张专辑页。
/// 只记「按下的那一张」:焦点挪到别处再从别处开播(比如 hero 的按钮),回来就照旧落在顶栏。
@MainActor
final class TVHomeBrowseMemory {
    /// 开始播放 / 打开专辑页的那张卡片(`TVHomeView` 里带所在那一排前缀的焦点 id)。
    var cardID: String?
    /// 从首页打开的专辑页里开始播放:专辑 id 与点的那首(全部 / 随机播放时为 nil)。
    var albumDetailID: String?
    var albumDetailSongID: String?
    /// 由 `TVRoot.leavePlayer` 打上,首页出现时用掉;经顶栏换页回来不恢复。
    var restoresAfterPlayer = false

    var hasReturnTarget: Bool { cardID != nil || albumDetailID != nil }

    func forget() {
        cardID = nil
        albumDetailID = nil
        albumDetailSongID = nil
        restoresAfterPlayer = false
    }
}

extension ArtistBrowseMode {
    var title: String {
        switch self {
        case .allArtists: return String(localized: "artist_browse_all")
        case .albumArtists: return String(localized: "artist_browse_album_artists")
        }
    }

    var systemImage: String {
        switch self {
        case .allArtists: return "music.mic"
        case .albumArtists: return "square.stack"
        }
    }
}

extension LibraryAlbumBrowseOrder {
    var title: String {
        switch self {
        case .artist: return String(localized: "artist_label")
        case .title: return String(localized: "title_label")
        case .year: return String(localized: "year_label")
        case .recentlyAdded: return String(localized: "recently_added")
        case .liked: return String(localized: "library_favorite_filter_short")
        }
    }

    var systemImage: String {
        switch self {
        case .artist: return "person"
        // 不用 textformat:它在中文环境下被系统换成「格式」两个字。
        case .title: return "abc"
        case .year: return "calendar"
        case .recentlyAdded: return "clock"
        case .liked: return "heart"
        }
    }
}

extension TVLibraryFilter {
    var display: String {
        switch self {
        case .albums: return String(localized: "tab_albums")
        case .songs: return String(localized: "tab_songs")
        case .artists: return String(localized: "tab_artists")
        case .genres: return String(localized: "tab_genres")
        case .folders: return TVDiscoveryText.string("folders")
        case .years: return String(localized: "year_label")
        case .recommendations: return PMString("library_recommendations_title")
        case .ranking: return TVDiscoveryText.string("ranking")
        }
    }

    var icon: String {
        switch self {
        case .albums: return "square.stack"
        case .songs: return "music.note"
        case .artists: return "person.2"
        case .genres: return "guitars"
        case .folders: return "folder"
        case .years: return "calendar"
        case .recommendations: return "sparkles"
        case .ranking: return "chart.bar"
        }
    }
}

enum TVLibraryBackgroundWorkPolicy {
    static func refreshesRecommendations(for filter: TVLibraryView.Filter) -> Bool {
        filter == .recommendations
    }
}

/// tvOS 资料库 — 筛选条 + 网格(对应 tvos.jsx 的 TVLibraryArtboard)。
struct TVLibraryView: View {
    @Environment(TVStore.self) private var store
    @Environment(MusicIntelligenceService.self) private var intelligence
    var openPlayer: () -> Void = {}
    var onReturnToTabs: () -> Void = {}
    var onModalActivityChanged: (Bool) -> Void = { _ in }

    /// 筛选条上的项与显隐规则在 Kit(`TVLibraryFilter`),推荐、排行默认收起。
    /// 电台已是与音乐并列的一级页(TVRadioPageView),不再是资料库里的一个筛选。
    typealias Filter = TVLibraryFilter
    @Binding var filter: Filter
    @State private var recommendationCandidates: [Song] = []
    @State private var aiRecommendation = AIRecommendationViewModel()
    @AppStorage(AIRecommendationIntentStoragePolicy.storageKey)
    private var customRecommendationIntentsRawValue = ""
    @AppStorage(AIRecommendationIntentPresetVisibilityPolicy.storageKey)
    private var hiddenRecommendationPresetsRawValue = ""
    @AppStorage(AIRecommendationIntentSelectionPolicy.storageKey)
    private var selectedRecommendationIntentID =
        AIRecommendationIntentSelectionPolicy.defaultSelectionID
    @FocusState private var focusedFilter: Filter?
    /// 网格里的专辑 / 艺人卡片,值见 `albumFocusID` / `artistFocusID`。
    @FocusState private var focusedGridItem: String?
    @AppStorage(LibraryAlbumBrowseOrder.tvStorageKey)
    private var albumOrderRawValue = LibraryAlbumBrowseOrder.tvDefault.rawValue
    @AppStorage(TVLibraryFilterConfiguration.storageKey)
    private var filterConfigurationRawValue = ""
    @AppStorage(ArtistBrowseMode.storageKey)
    private var artistBrowseModeRaw = ArtistBrowseMode.allArtists.rawValue
    /// 专辑墙(含年份墙)与艺人墙每行几张,见 `TVBrowseGridMetrics.music(columns:)`。
    @AppStorage(TVBrowseGridMetrics.musicColumnsStorageKey)
    private var wallColumnsSetting = TVBrowseGridMetrics.music.columns
    /// 筛选行右端的几个菜单按钮(排序 / 列法 / 每行张数)。
    @FocusState private var focusedStripMenu: StripMenu?
    /// 右侧字母栏上的焦点;有值时网格中央浮出这个字母。
    @FocusState private var focusedIndexBucket: String?
    /// 网格里当前聚焦的卡片属于哪个字母,字母栏据此点亮。
    @State private var currentIndexBucket: String?
    @State private var gridJumpRequest: TVGridJumpRequest?
    @State private var selectedArtist: TVArtist?
    /// 艺人墙「只看喜欢」。
    @State private var showsLikedArtistsOnly = false
    @State private var opensPlayerAfterArtistDismissal = false
    @State private var selectedAlbum: TVAlbum?
    /// 从播放页回来重开专辑页时,焦点要落到的那一首。
    @State private var reopenedAlbumSongID: String?
    /// 同上,重开的艺人页 / 那一组歌里焦点要落到的那一首。
    @State private var reopenedArtistSongID: String?
    @State private var reopenedCollectionSongID: String?
    /// 流派 / 排行点开的那一组歌。
    @State private var selectedCollection: TVBrowseDestination?
    @State private var opensPlayerAfterCollectionDismissal = false
    /// 从播放页回来、文件夹页要把焦点放回的那首(只这一次)。
    @State private var folderReturnSongID: String?

    #if DEBUG
    /// 截图用的 `albumDetail` 只在首次进资料库时打开一次。
    @MainActor private static var didOpenDebugAlbumDetail = false
    #endif

    var focusRequest = 0
    var browseMemory = TVLibraryBrowseMemory()

    var body: some View {
        GeometryReader { geo in
            let indexSections = letterIndexSections
            let indexBarSpace = indexSections.isEmpty ? 0 : TVLetterIndexBar.width + Self.indexBarGap
            let cell = gridMetrics.cellWidth(pageWidth: geo.size.width - indexBarSpace)
            VStack(alignment: .leading, spacing: 24) {
                filterStrip(trailingInset: indexBarSpace)
                ScrollViewReader { proxy in
                    HStack(alignment: .top, spacing: Self.indexBarGap) {
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 30) {
                                titleRow
                                    .id("tv.library.contentTop")
                                grid(cell: cell, proxy: proxy, onFolderNavigation: {
                                    proxy.scrollTo("tv.library.contentTop", anchor: .top)
                                })
                            }
                            .padding(.horizontal, TVBrowseGridMetrics.edgeInset)
                            .padding(.top, 8)
                            .padding(.bottom, TVSpace.pageBottom)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .focusSection()
                        .overlay { TVLetterIndexWatermark(bucket: focusedIndexBucket) }
                        .onAppear { revealBrowseAnchor(with: proxy) }
                        .id(filter)
                        if !indexSections.isEmpty {
                            TVLetterIndexBar(
                                availableBuckets: Set(indexSections.map(\.bucket)),
                                currentBucket: currentIndexBucket,
                                focusedBucket: $focusedIndexBucket,
                                onSelect: jumpToIndexBucket
                            )
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                    }
                }
            }
            .padding(.horizontal, TVSpace.pageH)
            .padding(.top, TVSpace.pageTop)
        }
        .background(TVColor.bg)
        // 焦点停在网格深处时,第一次 Menu 先回到筛选条(网格位置不动),再按一次才回顶栏。
        // 排序 / 列法 / 每行张数这几个菜单就在筛选条右端,从它们按 Menu 直接回顶栏。
        .onExitCommand {
            if focusedGridItem != nil || focusedIndexBucket != nil {
                focusedFilter = filter
            } else {
                onReturnToTabs()
            }
        }
        .onChange(of: focusRequest) { restoreContentFocus() }
        .task(id: BrowseLayoutRequest(
            filter: filter,
            albumOrder: wallOrder,
            artistMode: artistBrowseMode,
            revision: store.libraryBrowseRevision,
            favoritesRevision: wallOrder == .liked ? LibraryFavoritesStore.shared.revision : 0
        )) {
            switch filter {
            case .albums, .years: await store.prepareAlbumBrowseLayout(wallOrder)
            case .artists: await store.prepareArtistBrowseLayout(artistBrowseMode)
            case .songs: await store.prepareSongBrowseLayout()
            default: break
            }
        }
        .onChange(of: filter) { _, _ in resetLetterIndex() }
        .onAppear(perform: leaveHiddenFilter)
        .onChange(of: filterConfigurationRawValue) { _, _ in leaveHiddenFilter() }
        .onChange(of: artistBrowseModeRaw) { _, _ in
            // 换了列法,上次停的那位可能已经不在墙上;网格从头开始,焦点留在列法菜单上。
            browseMemory.artistID = nil
            resetLetterIndex()
        }
        .onChange(of: albumOrderRawValue) { _, _ in
            // 换了排序方式,上次停的那张卡片在新顺序里的位置没有意义;网格从头开始,
            // 焦点留在排序菜单上。
            browseMemory.albumID = nil
            resetLetterIndex()
        }
        .onAppear(perform: normalizeRecommendationIntentSelectionIfNeeded)
        .onChange(of: selectedRecommendationIntentID) { _, _ in
            normalizeRecommendationIntentSelectionIfNeeded()
        }
        .onChange(of: customRecommendationIntentsRawValue) { _, _ in
            normalizeRecommendationIntentSelectionIfNeeded()
        }
        .onChange(of: hiddenRecommendationPresetsRawValue) { _, _ in
            normalizeRecommendationIntentSelectionIfNeeded()
        }
        .task(id: recommendationTaskKey) {
            guard TVLibraryBackgroundWorkPolicy.refreshesRecommendations(for: filter) else {
                return
            }
            let candidates = await store.recommendationCandidates(limit: 24)
            guard !Task.isCancelled,
                  TVLibraryBackgroundWorkPolicy.refreshesRecommendations(for: filter) else {
                return
            }
            recommendationCandidates = candidates
            await aiRecommendation.refresh(
                scene: .automatic,
                intent: selectedRecommendationIntent?.semanticIntent,
                candidates: candidates,
                using: intelligence,
                reuseSurface: .tvLibrary
            )
        }
        .fullScreenCover(item: $selectedArtist, onDismiss: finishArtistDismissal) { artist in
            TVArtistDetailView(
                artist: artist,
                openPlayer: {
                    browseMemory.forgetDetails()
                    browseMemory.artistDetail = artist
                    browseMemory.artistDetailSongID = store.currentSongID
                    opensPlayerAfterArtistDismissal = true
                },
                initialFocusSongID: reopenedArtistSongID
            )
                .environment(store)
        }
        .onChange(of: selectedArtist) { _, artist in
            onModalActivityChanged(artist != nil)
        }
        .onDisappear {
            if selectedArtist != nil {
                onModalActivityChanged(false)
            }
        }
        .fullScreenCover(item: $selectedCollection, onDismiss: finishCollectionDismissal) { destination in
            TVSongCollectionView(
                destination: destination,
                openPlayer: {
                    browseMemory.forgetDetails()
                    browseMemory.collectionDetail = destination
                    browseMemory.collectionDetailSongID = store.currentSongID
                    opensPlayerAfterCollectionDismissal = true
                },
                initialFocusSongID: reopenedCollectionSongID
            )
                .environment(store)
        }
        .onChange(of: selectedCollection != nil) { _, active in
            onModalActivityChanged(active)
        }
        .onDisappear {
            if selectedCollection != nil {
                onModalActivityChanged(false)
            }
        }
        .modifier(TVAlbumDetailPresenter(
            album: $selectedAlbum,
            openPlayer: openPlayer,
            onPresentationChanged: onModalActivityChanged,
            initialFocusSongID: reopenedAlbumSongID,
            onPlaybackStarted: { albumID, songID in
                browseMemory.forgetDetails()
                browseMemory.albumDetailID = albumID
                browseMemory.albumDetailSongID = songID
            },
            onClosed: {
                browseMemory.albumDetailID = nil
                browseMemory.albumDetailSongID = nil
                reopenedAlbumSongID = nil
                restoreContentFocus()
            }
        ))
        .onAppear(perform: reopenDetailAfterPlayer)
        #if DEBUG
        .task {
            guard TVDebugLaunch.screen == "albumDetail", !Self.didOpenDebugAlbumDetail else { return }
            Self.didOpenDebugAlbumDetail = true
            var tries = 0
            while store.albums.isEmpty && tries < 25 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                tries += 1
            }
            // TV_ALBUM_DETAIL=<专辑名片段> 打开指定的专辑;TV_ALBUM_DETAIL_PLAY=1 进页后播第一首
            // (留在专辑页,看正在播放那一行)。
            let environment = ProcessInfo.processInfo.environment
            let wanted = environment["TV_ALBUM_DETAIL"].flatMap { name in
                store.albums.first { $0.title.localizedCaseInsensitiveContains(name) }
            }
            selectedAlbum = wanted
                ?? store.albums.first { (4...40).contains(store.songIDs(forAlbum: $0.id).count) }
                ?? store.albums.first
            if environment["TV_ALBUM_DETAIL_PLAY"] == "1", let album = selectedAlbum {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                let songIDs = store.songIDs(forAlbum: album.id)
                if let first = songIDs.first.flatMap({ store.song($0) }) {
                    _ = store.play(first, in: songIDs)
                }
            }
        }
        .task {
            // 截图用:TV_SCREEN=libraryIndex 等专辑墙排好后从字母栏跳到 TV_INDEX_JUMP(默认 M)。
            // TV_LIBRARY_FILTER=artists 看艺人墙,TV_ALBUM_ORDER=title|artist|year|recentlyAdded 换排序。
            guard TVDebugLaunch.screen == "libraryIndex", !Self.didRunDebugIndexJump else { return }
            Self.didRunDebugIndexJump = true
            let environment = ProcessInfo.processInfo.environment
            if let order = environment["TV_ALBUM_ORDER"].flatMap(LibraryAlbumBrowseOrder.init(rawValue:)) {
                albumOrderRawValue = order.rawValue
            }
            // TV_LIBRARY_FILTER=artists|years 换到艺人墙 / 年份墙。
            if let requested = environment["TV_LIBRARY_FILTER"].flatMap(Filter.init(rawValue:)) {
                filter = requested
            }
            // TV_LIKED_ARTISTS=1:艺人墙只看喜欢的。
            if environment["TV_LIKED_ARTISTS"] == "1" { showsLikedArtistsOnly = true }
            // TV_ARTIST_MODE=albumArtists|allArtists:艺人墙的列法。
            if let mode = environment["TV_ARTIST_MODE"].flatMap(ArtistBrowseMode.init(rawValue:)) {
                artistBrowseModeRaw = mode.rawValue
            }
            // TV_GRID_COLUMNS=4…7:专辑 / 艺人墙每行几张。
            if let columns = environment["TV_GRID_COLUMNS"].flatMap({ Int($0) }) {
                wallColumnsSetting = columns
            }
            let bucket = environment["TV_INDEX_JUMP"] ?? "M"
            guard bucket != "-" else { return }
            var tries = 0
            while letterIndexSections.isEmpty && tries < 50 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                tries += 1
            }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let target = letterIndexSections.first { $0.bucket >= bucket }?.bucket ?? letterIndexSections.last?.bucket
            if let target { jumpToIndexBucket(target) }
        }
        #endif
    }

    #if DEBUG
    @MainActor private static var didRunDebugIndexJump = false
    #endif

    private static let indexBarGap: CGFloat = 16

    private var albumOrder: LibraryAlbumBrowseOrder { .resolved(albumOrderRawValue) }
    private var artistBrowseMode: ArtistBrowseMode { .resolved(artistBrowseModeRaw) }

    /// 专辑墙实际用的排序:「年份」筛选就是按年份排、按年代分段的专辑墙。
    private var wallOrder: LibraryAlbumBrowseOrder { filter == .years ? .year : albumOrder }

    /// 专辑墙(含年份墙)与艺人墙:筛选行右端多一个「每行几张」菜单,网格按它排。
    private var showsWallControls: Bool {
        filter == .albums || filter == .years || filter == .artists
    }

    /// 网格的尺子。只有专辑 / 艺人墙跟「每行几张」走;其余筛选不用它排卡片,照旧一行四张。
    private var gridMetrics: TVBrowseGridMetrics {
        showsWallControls ? .music(columns: wallColumnsSetting) : .music
    }

    private enum StripMenu: Hashable {
        case albumOrder, artistBrowse, gridColumns
    }

    private var filterConfiguration: TVLibraryFilterConfiguration {
        .decode(filterConfigurationRawValue)
    }

    /// 停在被关掉的筛选上(设置里刚关、或从旧版本带过来)就回到专辑墙。
    private func leaveHiddenFilter() {
        let resolved = filterConfiguration.resolved(filter)
        if resolved != filter { filter = resolved }
    }

    /// 专辑墙分段的标题:按年份排时分段是年代(和手机上「发行日期」页同一套),其余是首字母。
    private static func albumSectionTitle(_ bucket: String) -> String {
        switch ReleaseDateBrowseLayout.Era(id: bucket) {
        case .decade(let start):
            String(format: String(localized: "library_release_date_decade_format"), start)
        case .earlier:
            String(
                format: String(localized: "library_release_date_earlier_format"),
                ReleaseDateBrowseLayoutBuilder.earliestDecade
            )
        case .unknown:
            String(localized: "library_release_date_unknown")
        case nil:
            bucket
        }
    }

    private struct BrowseLayoutRequest: Equatable {
        let filter: Filter
        let albumOrder: LibraryAlbumBrowseOrder
        let artistMode: ArtistBrowseMode
        let revision: Int
        /// 按「喜欢」排时，点了 / 取消喜欢也要重排。
        let favoritesRevision: Int
    }

    /// 当前网格的首字母分段;没有(其他筛选、按年份 / 最近添加)时不显示字母栏。
    private var letterIndexSections: [LibraryBrowseSection] {
        switch filter {
        case .albums:
            guard albumOrder.hasLetterIndex else { return [] }
            return store.albumBrowseLayout(albumOrder)?.sections ?? []
        case .artists:
            guard !showsLikedArtistsOnly else { return [] }
            return store.artistBrowseLayout(artistBrowseMode)?.sections ?? []
        case .songs:
            return store.songBrowseLayout()?.sections ?? []
        default:
            return []
        }
    }

    /// 从播放页按 Menu 回来:起播的那张专辑页 / 艺人页 / 那一组歌不带动画地重新挂上,
    /// 焦点落回刚播的那首;在文件夹里开播的,文件夹页自己把焦点放回那首。
    private func reopenDetailAfterPlayer() {
        let restores = browseMemory.restoresAfterPlayer
        browseMemory.restoresAfterPlayer = false
        guard restores else {
            browseMemory.forgetDetails()
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        if let albumID = browseMemory.albumDetailID, let album = store.album(albumID) {
            reopenedAlbumSongID = browseMemory.albumDetailSongID
            withTransaction(transaction) { selectedAlbum = album }
        } else if let artist = browseMemory.artistDetail, !store.songs(forArtistID: artist.id).isEmpty {
            reopenedArtistSongID = browseMemory.artistDetailSongID
            withTransaction(transaction) { selectedArtist = artist }
        } else if let destination = browseMemory.collectionDetail {
            reopenedCollectionSongID = browseMemory.collectionDetailSongID
            withTransaction(transaction) { selectedCollection = destination }
        } else if filter == .folders, let songID = browseMemory.folderSongID {
            folderReturnSongID = songID
        } else {
            browseMemory.forgetDetails()
        }
    }

    private func jumpToIndexBucket(_ bucket: String) {
        currentIndexBucket = bucket
        gridJumpRequest = TVGridJumpRequest(bucket: bucket, serial: (gridJumpRequest?.serial ?? 0) + 1)
    }

    private func noteFocusedSection(_ bucket: String) {
        if currentIndexBucket != bucket { currentIndexBucket = bucket }
    }

    private func resetLetterIndex() {
        currentIndexBucket = nil
        gridJumpRequest = nil
    }

    private static func albumFocusID(_ id: String) -> String { "album:" + id }
    private static func artistFocusID(_ id: String) -> String { "artist:" + id }
    private static func songFocusID(_ id: String) -> String { "song:" + id }

    /// 歌曲页上次聚焦的那首在当前列表里的位置;记下的位置对不上(曲库变了)才逐个找。
    /// 记住的那张卡片在当前墙上的位置:先认记下的位置,对不上 (曲库变了) 才整墙逐个找。
    private static func rememberedIndex<Element: Identifiable>(
        of id: String?, at index: Int?, in source: [Element]
    ) -> Int? where Element.ID == String {
        guard let id else { return nil }
        if let index, source.indices.contains(index), source[index].id == id { return index }
        return source.firstIndex { $0.id == id }
    }

    private func rememberedSongIndex(in ids: [String]) -> Int? {
        guard let id = browseMemory.songID else { return nil }
        if let index = browseMemory.songIndex, ids.indices.contains(index), ids[index] == id { return index }
        return ids.firstIndex(of: id)
    }

    /// 当前筛选下记住的那张卡片;已从曲库消失的不算。
    private var browseAnchorFocusID: String? {
        switch filter {
        case .albums, .years:
            guard let id = browseMemory.albumID, store.album(id) != nil else { return nil }
            return Self.albumFocusID(id)
        case .artists:
            guard let id = browseMemory.artistID,
                  store.browsableArtists(artistBrowseMode).contains(where: { $0.id == id }) else {
                return nil
            }
            return Self.artistFocusID(id)
        case .songs:
            guard let id = browseMemory.songID, store.song(id) != nil else { return nil }
            return Self.songFocusID(id)
        case .genres:
            guard let id = browseMemory.genreID,
                  store.library.visibleGenres.contains(where: { $0.id == id }) else { return nil }
            return TVGenreBrowser.focusID(id)
        default:
            return nil
        }
    }

    /// 网格重建后先滚到记住的卡片:懒加载网格只为可见区域建视图,
    /// 不滚过去,稍后按下方向键时那张卡片还不存在,焦点就放不上去。
    private func revealBrowseAnchor(with proxy: ScrollViewProxy) {
        let anchor: String?
        switch filter {
        case .albums, .years: anchor = browseMemory.albumID
        case .artists: anchor = browseMemory.artistID
        case .songs: anchor = browseMemory.songID
        case .genres: anchor = browseMemory.genreID
        default: anchor = nil
        }
        guard let anchor, browseAnchorFocusID != nil else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(anchor, anchor: .center)
        }
    }

    /// 从顶栏按下、关掉弹层之后焦点回到哪:有记住的卡片就回到它,否则落在筛选条。
    private func restoreContentFocus() {
        if let focusID = browseAnchorFocusID {
            focusedGridItem = focusID
        } else {
            focusedFilter = filter
        }
    }

    /// 页标题与字母栏提示;排序、列法、每行几张在筛选行右端(`stripMenus`)。
    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).tvFont(.pageTitle).foregroundStyle(TVColor.text)
                .lineLimit(1)
            // 右边有字母栏时提示一句:几千位艺人、几万首歌不用一行行往下翻。
            if !letterIndexSections.isEmpty {
                Label(PMString("ext.tv.library.indexHint"), systemImage: "arrow.right.to.line")
                    .tvFont(.meta)
                    .foregroundStyle(TVColor.textFaint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 筛选行右端:专辑墙的排序、艺人墙的列法(连同「只看收藏的」),以及两面墙的每行几张。
    /// 都收成菜单按钮,按钮上只写当前那一项:标题旁不再摆一排和筛选长得一样的胶囊,
    /// 「艺术家」「年份」也不会上下两行各出现一次。图标用排序 / 筛选 / 网格,和左边的筛选分得开。
    private var stripMenus: some View {
        HStack(spacing: 14) {
            if filter == .albums {
                albumOrderMenu
            }
            if filter == .artists {
                artistBrowseMenu
            }
            gridColumnsMenu
        }
    }

    /// 筛选行右端的一颗菜单按钮:外观同筛选胶囊(不画选中色,聚焦时反白),按下弹出系统菜单。
    /// 菜单里的选项用 `Toggle`,当前那一项带勾(同播放页长按菜单里的睡眠定时)。
    /// 选完菜单收起,焦点回到这颗按钮上。
    private func stripMenu<Content: View>(
        _ menu: StripMenu,
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let items = content()
        return Menu {
            items
        } label: {
            TVFilterChipLabel(
                title: title,
                systemImage: systemImage,
                isFocused: focusedStripMenu == menu
            )
        }
        .menuStyle(.button)
        .buttonStyle(TVBareButtonStyle())
        .focused($focusedStripMenu, equals: menu)
        .focusEffectDisabled()
    }

    /// 专辑墙的排序方式。选了别的排序,网格从头排(见 `onChange(of: albumOrderRawValue)`)。
    private var albumOrderMenu: some View {
        stripMenu(.albumOrder, title: Self.sortChipTitle(albumOrder), systemImage: "arrow.up.arrow.down") {
            Section(String(localized: "sort_by")) {
                // 「喜欢」只在有喜欢的专辑（或正选着它）时出现。
                ForEach(LibraryAlbumBrowseOrder.allCases.filter {
                    $0 != .liked || albumOrder == .liked || LibraryFavoritesStore.shared.hasLikedAlbums
                }, id: \.self) { order in
                    Toggle(isOn: Binding(
                        get: { order == albumOrder },
                        set: { _ in albumOrderRawValue = order.rawValue }
                    )) {
                        Label(order.title, systemImage: order.systemImage)
                    }
                }
            }
        }
        .accessibilityLabel(Text("sort_by"))
        .accessibilityValue(Text(albumOrder.title))
        .accessibilityIdentifier("tv.library.albumOrder")
    }

    /// 排序按钮上的字:「按艺术家」而不是「艺术家」,不和同一行的筛选「艺术家」「年份」撞名。
    /// 菜单里有「排序方式」标题,选项照旧用短名。
    private static func sortChipTitle(_ order: LibraryAlbumBrowseOrder) -> String {
        switch order {
        case .artist: return String(localized: "tv_library_sort_by_artist")
        case .title: return String(localized: "tv_library_sort_by_title")
        case .year: return String(localized: "tv_library_sort_by_year")
        case .recentlyAdded, .liked: return order.title
        }
    }

    /// 艺人墙列全部艺人还是只列专辑艺人;「只看收藏的」也收在这个菜单里,
    /// 有喜欢的艺人(或正开着)才出现。开着时按钮换成实心心形,标题后缀「收藏」。
    private var artistBrowseMenu: some View {
        var chipTitle = artistBrowseMode.title
        if showsLikedArtistsOnly {
            chipTitle += " · " + String(localized: "library_favorite_filter_short")
        }
        return stripMenu(
            .artistBrowse,
            title: chipTitle,
            systemImage: showsLikedArtistsOnly ? "heart.fill" : "line.3.horizontal.decrease"
        ) {
            Section(String(localized: "artist_browse_mode")) {
                ForEach(ArtistBrowseMode.allCases, id: \.self) { mode in
                    Toggle(isOn: Binding(
                        get: { mode == artistBrowseMode },
                        set: { _ in artistBrowseModeRaw = mode.rawValue }
                    )) {
                        Label(mode.title, systemImage: mode.systemImage)
                    }
                }
            }
            if showsLikedArtistsOnly || LibraryFavoritesStore.shared.hasLikedArtists {
                Section {
                    Toggle(isOn: Binding(
                        get: { showsLikedArtistsOnly },
                        set: { isOn in
                            showsLikedArtistsOnly = isOn
                            resetLetterIndex()
                        }
                    )) {
                        Label(String(localized: "library_favorite_filter"), systemImage: "heart")
                    }
                }
            }
        }
        .accessibilityLabel(Text("artist_browse_mode"))
        .accessibilityValue(Text(chipTitle))
        .accessibilityIdentifier("tv.library.artistMode")
    }

    /// 专辑墙(含年份墙)、艺人墙每行几张:张数越多海报越小,一屏看得越多。
    /// 换了之后网格按新列数整面重建(见 `grid` 里的 `.id`),记住的那张卡片照旧放回,
    /// 窗口起点按新列数整行对齐。
    private var gridColumnsMenu: some View {
        let current = gridMetrics.columns
        return stripMenu(
            .gridColumns,
            title: Self.gridColumnsTitle(current),
            systemImage: "square.grid.3x3"
        ) {
            Section(String(localized: "tv_library_grid_columns")) {
                ForEach(TVBrowseGridMetrics.musicColumnOptions, id: \.self) { count in
                    Toggle(isOn: Binding(
                        get: { count == current },
                        set: { _ in wallColumnsSetting = count }
                    )) {
                        Text(Self.gridColumnsTitle(count))
                    }
                }
            }
        }
        .accessibilityLabel(Text("tv_library_grid_columns"))
        .accessibilityValue(Text(Self.gridColumnsTitle(current)))
        .accessibilityIdentifier("tv.library.gridColumns")
    }

    private static func gridColumnsTitle(_ count: Int) -> String {
        String(format: String(localized: "tv_library_grid_columns_format"), count)
    }

    private var title: String {
        switch filter {
        case .albums:
            // 选「喜欢」时数的是墙上那几张,不是整库。
            let count = albumOrder == .liked
                ? store.albumBrowseLayout(.liked)?.items.count ?? 0
                : store.albums.count
            return PMString("ext.tv.library.title.albums", count)
        case .recommendations: return PMString("library_recommendations_title")
        case .artists:
            let count = showsLikedArtistsOnly
                ? store.likedArtistBrowseLayout(artistBrowseMode).items.count
                : store.browsableArtists(artistBrowseMode).count
            return PMString("ext.tv.library.title.artists", count)
        case .songs: return PMString("ext.tv.library.title.songs", TVFmt.count(store.songs.count))
        case .genres, .folders, .years, .ranking: return filter.display
        }
    }

    /// 第一行:左边是横向滚动的筛选胶囊,右端是当前这面墙的菜单(`stripMenus`,不随胶囊滚走)。
    /// 整行一个焦点区:从最后一颗筛选往右就到菜单。菜单右沿让出 `trailingInset`(字母栏那一列),
    /// 与网格右沿对齐、不压在字母栏上方,从菜单往下落到网格第一行而不是字母栏。
    private func filterStrip(trailingInset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PMString("ext.tv.library.eyebrow")).tvFont(.eyebrow)
                .foregroundStyle(TVColor.textMuted)
            HStack(spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(filterConfiguration.visibleFilters) { item in
                            Button { filter = item } label: {
                                TVFilterChipLabel(
                                    title: item.display,
                                    systemImage: item.icon,
                                    isSelected: item == filter,
                                    isFocused: focusedFilter == item
                                )
                            }
                            .buttonStyle(TVBareButtonStyle())
                            .focused($focusedFilter, equals: item)
                            .focusEffectDisabled()
                            .accessibilityIdentifier("tv.library.category." + item.rawValue)
                            .accessibilityAddTraits(item == filter ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity)
                if showsWallControls {
                    stripMenus
                        .padding(.trailing, TVBrowseGridMetrics.edgeInset + trailingInset)
                }
            }
            .frame(height: 80)
        }
        .focusSection()
    }

    @ViewBuilder
    private func grid(cell: CGFloat, proxy: ScrollViewProxy, onFolderNavigation: @escaping () -> Void) -> some View {
        let columns = gridMetrics.gridItems(cell: cell)
        let gap = gridMetrics.gap
        switch filter {
        case .albums, .years:
            if let layout = store.albumBrowseLayout(wallOrder) {
                TVIndexedGrid(
                    items: layout.items, sections: layout.sections, columns: columns, spacing: gap,
                    revealingIndex: Self.rememberedIndex(
                        of: browseMemory.albumID, at: browseMemory.albumIndex, in: layout.items.source
                    ),
                    jumpRequest: gridJumpRequest,
                    scrollProxy: proxy,
                    focusItem: { focusedGridItem = Self.albumFocusID($0) },
                    onSectionFocused: noteFocusedSection,
                    sectionTitle: Self.albumSectionTitle
                ) { index, album, focusChanged in
                    TVAlbumCard(album: album, width: cell,
                                subtitleOverride: album.year > 0 ? "\(album.artist) · \(album.year)" : album.artist,
                                action: openPlayer,
                                onFocusChanged: { focused in
                                    focusChanged(focused)
                                    if focused {
                                        browseMemory.albumID = album.id
                                        browseMemory.albumIndex = index
                                    }
                                },
                                onOpen: { selectedAlbum = album },
                                focusBinding: $focusedGridItem,
                                focusID: Self.albumFocusID(album.id))
                        .accessibilityIdentifier("tv.library.album.\(index)")
                }
                // 换排序或每行张数都整面重建:窗口起点、已渲染张数是按旧排序 / 旧列数攒下的。
                // 重建时记住的那张卡片由 `revealingIndex` 放回,窗口按新列数整行对齐。
                .id("\(wallOrder.rawValue)#\(columns.count)")
                .onAppear { revealBrowseAnchor(with: proxy) }
            } else {
                browseLayoutPlaceholder
            }
        case .recommendations:
            VStack(alignment: .leading, spacing: 22) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(recommendationIntents) { intent in
                            TVFocusButton(
                                radius: 18,
                                scale: 1.05,
                                lift: 4,
                                action: {
                                    selectedRecommendationIntentID = intent.id
                                    CloudKVSSync.shared.markChanged(
                                        key: CloudKVSKey.aiRecommendationSelectedIntent
                                    )
                                }
                            ) { focused in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(intent.title)
                                        .tvFont(.caption, weight: .semibold)
                                    Text(intent.detail)
                                        .tvFont(.meta)
                                        .lineLimit(2, reservesSpace: true)
                                        .opacity(0.75)
                                }
                                .foregroundStyle(
                                    focused ? TVColor.onFocusFill
                                        : (effectiveSelectedRecommendationIntentID == intent.id
                                           ? TVColor.onBrand : TVColor.text)
                                )
                                .padding(.horizontal, 24)
                                .frame(width: 250, height: 110, alignment: .leading)
                                .background(
                                    focused ? TVColor.focusFill
                                        : (effectiveSelectedRecommendationIntentID == intent.id
                                           ? TVColor.brand : TVColor.surface),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                if let selectedRecommendationIntent {
                    recommendationIntentDetails(selectedRecommendationIntent)
                }

                HStack(spacing: 10) {
                    Image(systemName: aiRecommendation.summaryText == nil
                          ? "iphone.and.arrow.forward" : "sparkles")
                    Text(aiRecommendation.statusText)
                    if let summary = aiRecommendation.summaryText {
                        Text("· \(summary)").foregroundStyle(TVColor.textMuted)
                    }
                }
                .tvFont(.caption, weight: .semibold)
                .foregroundStyle(TVColor.text)

                let recommendationSongs = displayedRecommendationSongs
                let recommendationQueueSongIDs = recommendationSongs.map(\.id)
                LazyVStack(spacing: 10) {
                    ForEach(recommendationSongs) { song in
                        TVSongRow(
                            song: song,
                            reason: aiRecommendation.reason(for: song.id),
                            queueSongIDs: recommendationQueueSongIDs,
                            action: openPlayer
                        )
                    }
                }
            }
        case .artists:
            if let layout = showsLikedArtistsOnly
                ? store.likedArtistBrowseLayout(artistBrowseMode)
                : store.artistBrowseLayout(artistBrowseMode) {
                TVIndexedGrid(
                    items: layout.items, sections: layout.sections, columns: columns, spacing: gap,
                    revealingIndex: Self.rememberedIndex(
                        of: browseMemory.artistID, at: browseMemory.artistIndex, in: layout.items.source
                    ),
                    jumpRequest: gridJumpRequest,
                    scrollProxy: proxy,
                    focusItem: { focusedGridItem = Self.artistFocusID($0) },
                    onSectionFocused: noteFocusedSection
                ) { index, artist, focusChanged in
                    TVArtistCard(
                        artist: artist,
                        size: cell * 0.82,
                        action: { selectedArtist = artist },
                        onFocusChanged: { focused in
                            focusChanged(focused)
                            if focused {
                                browseMemory.artistID = artist.id
                                browseMemory.artistIndex = index
                            }
                        },
                        focusBinding: $focusedGridItem,
                        focusID: Self.artistFocusID(artist.id)
                    )
                        .frame(width: cell)
                        .accessibilityIdentifier("tv.library.artist.\(index)")
                }
                // 同专辑墙:每行张数变了整面重建,窗口按新列数整行对齐。
                .id(columns.count)
                .onAppear { revealBrowseAnchor(with: proxy) }
            } else {
                browseLayoutPlaceholder
            }
        case .songs:
            // 几千首也能按右侧字母栏跳:按标题读音排好、分段,只渲染一个窗口(同艺人墙)。
            if let layout = store.songBrowseLayout() {
                let songIDs = layout.items
                TVIndexedGrid(
                    items: TVSongIDItems(ids: songIDs), sections: layout.sections,
                    columns: [GridItem(.flexible())], spacing: 10,
                    revealingIndex: rememberedSongIndex(in: songIDs),
                    jumpRequest: gridJumpRequest,
                    scrollProxy: proxy,
                    focusItem: { focusedGridItem = Self.songFocusID($0) },
                    onSectionFocused: noteFocusedSection
                ) { index, item, focusChanged in
                    if let song = store.song(item.id) {
                        TVSongRow(
                            song: song,
                            queueSongIDs: songIDs,
                            action: openPlayer,
                            onFocusChanged: { focused in
                                focusChanged(focused)
                                if focused {
                                    browseMemory.songID = item.id
                                    browseMemory.songIndex = index
                                }
                            },
                            focusBinding: $focusedGridItem,
                            focusID: Self.songFocusID(item.id)
                        )
                    }
                }
                .onAppear { revealBrowseAnchor(with: proxy) }
            } else {
                browseLayoutPlaceholder
            }
        case .genres:
            TVGenreBrowser(
                revealingGenreID: browseMemory.genreID,
                focusBinding: $focusedGridItem,
                onOpen: { destination in
                    browseMemory.genreID = destination.id
                    selectedCollection = destination
                }
            )
        case .folders:
            TVFolderBrowser(
                openPlayer: {
                    browseMemory.forgetDetails()
                    browseMemory.folderSongID = store.currentSongID
                    openPlayer()
                },
                onNavigation: onFolderNavigation,
                revealRow: { proxy.scrollTo($0, anchor: .center) },
                browseMemory: browseMemory,
                focusBinding: $focusedGridItem,
                returnSongID: $folderReturnSongID
            )
        case .ranking:
            TVRankingBrowser(onOpen: { selectedCollection = $0 })
        }
    }

    /// 第一次打开专辑 / 艺人墙、或刚换排序方式时,后台排序要零点几秒。
    private var browseLayoutPlaceholder: some View {
        ProgressView()
            .frame(maxWidth: .infinity, minHeight: 320)
    }

    private enum RecommendationIntentKind {
        case defaultSelection
        case preset(AIRecommendationIntentPreset)
        case custom(UUID)
    }

    private struct RecommendationIntent: Identifiable {
        var id: String
        var title: String
        var detail: String
        var semanticIntent: String?
        var kind: RecommendationIntentKind
    }

    private var recommendationIntents: [RecommendationIntent] {
        let visiblePresets = [AIRecommendationIntentPreset.balanced]
            + AIRecommendationIntentPresetVisibilityPolicy.visiblePresets(
                hiddenRecommendationPresetsRawValue
            )
        let presets = visiblePresets.map { preset in
            RecommendationIntent(
                id: preset.selectionID,
                title: preset.localizedTitle,
                detail: preset.localizedDetail,
                semanticIntent: preset.semanticIntent,
                kind: preset == .balanced ? .defaultSelection : .preset(preset)
            )
        }
        let custom = AIRecommendationIntentStoragePolicy
            .decode(customRecommendationIntentsRawValue)
            .map { intent in
                RecommendationIntent(
                    id: intent.selectionID,
                    title: intent.title,
                    detail: intent.prompt,
                    semanticIntent: intent.prompt,
                    kind: .custom(intent.id)
                )
            }
        return presets + custom
    }

    private var effectiveSelectedRecommendationIntentID: String {
        AIRecommendationIntentSelectionPolicy.normalizedSelectionID(
            selectedRecommendationIntentID,
            availableSelectionIDs: Set(recommendationIntents.map(\.id))
        )
    }

    private var selectedRecommendationIntent: RecommendationIntent? {
        recommendationIntents.first { $0.id == effectiveSelectedRecommendationIntentID }
            ?? recommendationIntents.first
    }

    private var recommendationRefreshKey: String {
        [
            String(store.recommendationRevision),
            effectiveSelectedRecommendationIntentID,
            customRecommendationIntentsRawValue,
            hiddenRecommendationPresetsRawValue,
            String(intelligence.settingsStore.revision),
            String(intelligence.regionAvailability.revision),
        ].joined(separator: "#")
    }

    private var recommendationTaskKey: String {
        TVLibraryBackgroundWorkPolicy.refreshesRecommendations(for: filter)
            ? "active#\(recommendationRefreshKey)"
            : "inactive"
    }

    private func normalizeRecommendationIntentSelectionIfNeeded() {
        let normalizedID = effectiveSelectedRecommendationIntentID
        guard normalizedID != selectedRecommendationIntentID else { return }
        selectedRecommendationIntentID = normalizedID
        CloudKVSSync.shared.markChanged(
            key: CloudKVSKey.aiRecommendationSelectedIntent
        )
    }

    private func removeRecommendationIntent(_ intent: RecommendationIntent) {
        switch intent.kind {
        case .defaultSelection:
            return
        case .preset(let preset):
            hiddenRecommendationPresetsRawValue =
                AIRecommendationIntentPresetVisibilityPolicy.hiding(
                    preset,
                    in: hiddenRecommendationPresetsRawValue
                )
            CloudKVSSync.shared.markChanged(
                key: CloudKVSKey.aiRecommendationHiddenPresets
            )
        case .custom(let id):
            let remaining = AIRecommendationIntentStoragePolicy
                .decode(customRecommendationIntentsRawValue)
                .filter { $0.id != id }
            customRecommendationIntentsRawValue =
                AIRecommendationIntentStoragePolicy.encode(remaining)
            CloudKVSSync.shared.markChanged(
                key: CloudKVSKey.aiRecommendationIntents
            )
        }
    }

    @ViewBuilder
    private func recommendationIntentDetails(_ intent: RecommendationIntent) -> some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text(intent.detail)
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch intent.kind {
            case .defaultSelection:
                EmptyView()
            case .preset, .custom:
                TVFocusButton(radius: 12, scale: 1.04, lift: 3) {
                    removeRecommendationIntent(intent)
                } label: { focused in
                    Label(
                        PMString("ai_recommendation_custom_remove"),
                        systemImage: "trash"
                    )
                    .tvFont(.caption, weight: .semibold)
                    .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 60)
                    .background(
                        focused ? TVColor.brand : TVColor.surfaceStrong,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
            }
        }
        .padding(18)
        .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 16))

        if !AIRecommendationIntentPresetVisibilityPolicy
            .hiddenPresets(hiddenRecommendationPresetsRawValue).isEmpty {
            TVFocusButton(radius: 12, scale: 1.03, lift: 2) {
                hiddenRecommendationPresetsRawValue =
                    AIRecommendationIntentPresetVisibilityPolicy.restoringAll()
                CloudKVSSync.shared.markChanged(
                    key: CloudKVSKey.aiRecommendationHiddenPresets
                )
            } label: { focused in
                Label(
                    PMString("ai_recommendation_presets_restore"),
                    systemImage: "arrow.counterclockwise"
                )
                .tvFont(.caption, weight: .semibold)
                .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
                .padding(.horizontal, 16)
                .frame(minHeight: 60)
                .background(
                    focused ? TVColor.brand : TVColor.surfaceStrong,
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
        }
    }

    private var displayedRecommendationSongs: [TVSong] {
        aiRecommendation.orderedSongs(from: recommendationCandidates).compactMap {
            store.song($0.id)
        }
    }

    private func finishArtistDismissal() {
        reopenedArtistSongID = nil
        guard opensPlayerAfterArtistDismissal else {
            browseMemory.artistDetail = nil
            browseMemory.artistDetailSongID = nil
            return
        }
        opensPlayerAfterArtistDismissal = false
        TVModalHandoff.afterFocusSettles(openPlayer)
    }

    private func finishCollectionDismissal() {
        reopenedCollectionSongID = nil
        guard opensPlayerAfterCollectionDismissal else {
            browseMemory.collectionDetail = nil
            browseMemory.collectionDetailSongID = nil
            return
        }
        opensPlayerAfterCollectionDismissal = false
        TVModalHandoff.afterFocusSettles(openPlayer)
    }
}

/// TV artist destination shared by Library and Search. It keeps the artist's
/// queue scope explicit instead of treating an artist card as a player shortcut.
struct TVArtistDetailView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let artist: TVArtist
    /// 开始播放时调用,这时 `store.currentSongID` 就是开播的那一首。
    var openPlayer: () -> Void = {}
    /// 打开时焦点落到的歌(从播放页回来时是刚播的那首);nil 照系统默认落在「全部播放」。
    var initialFocusSongID: String? = nil

    @FocusState private var focusedSongID: String?

    private var songs: [TVSong] { store.songs(forArtistID: artist.id) }

    var body: some View {
        // 一次算好:歌曲数、列表、播放全部三处都要用,别让同一次刷新反复扫这个艺人。
        let artistSongIDs = songs.map(\.id)
        ZStack {
            TVAmbientBackdrop(tint: artist.tint, tint2: artist.tint2, strength: 0.55)
            TVColor.bg.opacity(0.34).ignoresSafeArea()
            HStack(alignment: .top, spacing: 72) {
                VStack(alignment: .leading, spacing: 24) {
                    TVArtistArtworkView(artist: artist, size: 280)
                    Text(artist.name)
                        .tvFont(.pageTitle)
                        .foregroundStyle(TVColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(PMString("ext.tv.songsCount", artistSongIDs.count))
                        .tvFont(.body)
                        .foregroundStyle(TVColor.textMuted)
                    // 左栏只有 440 宽，中文的两颗按钮加一颗心就放不下一行，放不下的折到下一行。
                    TVButtonFlow {
                        TVPillButton(
                            title: PMString("ext.tv.home.playAll"),
                            systemImage: "play.fill",
                            style: .solid,
                            action: { play(shuffled: false) }
                        )
                        TVPillButton(
                            title: PMString("ext.tv.home.shuffle"),
                            systemImage: "shuffle",
                            action: { play(shuffled: true) }
                        )
                        TVFavoriteIconButton(
                            isLiked: LibraryFavoritesStore.shared.isLiked(artistNamed: artist.name),
                            action: { LibraryFavoritesStore.shared.toggle(artistNamed: artist.name) }
                        )
                        TVMedleyButton(songIDs: artistSongIDs) { openPlayer(); dismiss() }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 440, alignment: .leading)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            TVLibraryInsightBlock(subject: insightIdentity, details: insightDetails)
                            TVEyebrow(text: PMString("ext.tv.search.songs"))
                                .padding(.bottom, 6)
                            if artistSongIDs.isEmpty {
                                TVEmptyState(
                                    icon: "music.note",
                                    title: PMString("ext.tv.search.noMatch")
                                )
                                .frame(minHeight: 360)
                            } else {
                                TVPagedSongIDList(
                                    songIDs: artistSongIDs,
                                    alignment: .leading,
                                    action: finishPlayback,
                                    focusBinding: $focusedSongID,
                                    revealingSongID: initialFocusSongID
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                        .padding(.bottom, TVScrollEdgeFade.bottom)
                    }
                    .tvScrollEdgeFade()
                    .focusSection()
                    .tvRestoresFocus(to: initialFocusSongID, in: $focusedSongID, reveal: {
                        if let initialFocusSongID { proxy.scrollTo(initialFocusSongID, anchor: .center) }
                    })
                }
            }
            .padding(.horizontal, 100)
            .padding(.vertical, 72)
        }
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("tv.artist.detail")
    }

    private var insightIdentity: LibraryInsightSubject {
        .artist(name: artist.name, genres: [], albums: [], tracks: [])
    }

    /// 按下生成时才收集:这位艺人的专辑、前几首歌和最常见的风格。
    private func insightDetails() -> LibraryInsightSubject {
        let artistSongs = songs
        var seenAlbumIDs: Set<String> = []
        let albums = artistSongs.compactMap { song -> LibraryInsightSubject.AlbumReference? in
            guard seenAlbumIDs.insert(song.albumID).inserted, let album = store.album(song.albumID) else {
                return nil
            }
            return .init(title: album.title, year: album.year > 0 ? album.year : nil)
        }
        return .artist(
            name: artist.name,
            genres: LibraryInsightSubject.topGenres(artistSongs.map { store.library.song(id: $0.id)?.genre }),
            albums: albums,
            tracks: artistSongs.prefix(20).map(\.title)
        )
    }

    private func play(shuffled: Bool) {
        guard store.playResolvedQueue(songIDs: songs.map(\.id), shuffled: shuffled) else {
            return
        }
        finishPlayback()
    }

    private func finishPlayback() {
        openPlayer()
        dismiss()
    }
}

/// 专辑页的挂载:由持有专辑卡片的页面(资料库 / 首页 / 搜索)各挂一份。
/// 在专辑页里开始播放时先记下「关闭后去播放页」,等覆盖层真正收起再切换,
/// 不在覆盖层还在时换掉底下的页面。
struct TVAlbumDetailPresenter: ViewModifier {
    @Environment(TVStore.self) private var store
    @Binding var album: TVAlbum?
    var openPlayer: () -> Void
    /// 登记弹层在不在(停掉播放快捷键、压住顶栏的焦点换页),与艺人页用同一条通道。
    var onPresentationChanged: (Bool) -> Void = { _ in }
    /// 打开时焦点落到的曲目(从播放页回来时是刚播的那首);nil 落在「全部播放」。
    var initialFocusSongID: String? = nil
    /// 在专辑页里开始播放:专辑 id 与开播的那首(点的那首,或全部 / 随机 / 串烧开播的第一首)。
    var onPlaybackStarted: (String, String?) -> Void = { _, _ in }
    /// 用户在专辑页按 Menu 关掉(不是因为开始播放而收起)。
    var onClosed: () -> Void = {}
    @State private var opensPlayerAfterDismissal = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $album, onDismiss: finishDismissal) { album in
                TVAlbumDetailView(
                    albumID: album.id,
                    fallback: album,
                    initialFocusSongID: initialFocusSongID,
                    openPlayer: { albumID, songID in
                        onPlaybackStarted(albumID, songID)
                        opensPlayerAfterDismissal = true
                    }
                )
                .environment(store)
            }
            .onChange(of: album) { _, album in
                onPresentationChanged(album != nil)
            }
            .onDisappear {
                if album != nil {
                    onPresentationChanged(false)
                }
            }
    }

    private func finishDismissal() {
        guard opensPlayerAfterDismissal else {
            onClosed()
            return
        }
        opensPlayerAfterDismissal = false
        TVModalHandoff.afterFocusSettles(openPlayer)
    }
}

/// 专辑页大封面的缓慢浮动:六七秒一个来回地上浮几点、略微放大,投影跟着变远变淡,像离开了
/// 页面;左右再按另一个节奏挪一点,两个节奏错开就不显得机械。只动封面这一层(动画限定在
/// 修饰器里,页面推入的位移不会被带着循环),「减弱动态效果」打开时静止。
private struct TVArtworkGentleFloat: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lifted = false
    @State private var drifted = false

    func body(content: Content) -> some View {
        content
            .animation(reduceMotion ? nil : .easeInOut(duration: 6.5).repeatForever(autoreverses: true)) {
                $0
                    .shadow(
                        color: TVColor.focusShadow.opacity(lifted ? 0.75 : 0.55),
                        radius: lifted ? 34 : 20,
                        x: 0,
                        y: lifted ? 26 : 12
                    )
                    .scaleEffect(lifted ? 1.02 : 1)
                    .offset(y: lifted ? -7 : 0)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 9.5).repeatForever(autoreverses: true)) {
                $0.offset(x: drifted ? 4 : 0)
            }
            .task(id: reduceMotion) {
                guard !reduceMotion else {
                    lifted = false
                    drifted = false
                    return
                }
                // 等页面推入的动画走完再开始,封面先稳稳落位。
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                lifted = true
                drifted = true
            }
    }
}

/// 专辑页:按下专辑封面先看到整张专辑的曲目,从哪一首点下去就从哪一首播,整张专辑仍是队列。
/// 像打开的 CD 盒:左栏是封面(后面探出半张盘)、艺人、全部播放 / 随机播放和专辑简介
/// (长了自己慢慢滚,按下看全文);右栏是曲目;专辑文件夹里有封底图时铺成整页背景。
/// 串烧、补全专辑信息、恢复文件标签收在「更多」里。
struct TVAlbumDetailView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// 打开时的那份;封面取色、曲库刷新后按 id 重新取。
    let fallback: TVAlbum
    /// 打开时焦点落到的曲目;nil 落在「全部播放」。
    var initialFocusSongID: String?
    /// 开始播放:专辑 id 与开播的那首(全部 / 随机 / 串烧是开播的第一首;不是本专辑的歌时为 nil)。
    var openPlayer: (String, String?) -> Void = { _, _ in }
    /// 当前显示的专辑。补全专辑信息改了专辑名时专辑会换 id,跟着它的歌走过去。
    @State private var albumID: String
    @State private var showsAlbumScrape = false
    @State private var songIDsBeforeScrape: [String] = []
    @State private var showsRestoreConfirmation = false
    /// 长按曲目选了「从本机移除」,等确认。
    @State private var pendingRemoval: TVLibraryRemovalRequest?
    /// 「恢复文件标签」进行中 / 刚做完:显示在按钮下面,离开这一页才清掉。
    @State private var restoreProgress: TVRestoreFileTagsProgress?
    /// 这张专辑里有在电视上补全 / 匹配改过标签的歌(只补空缺的不打「用户编辑」标记)。
    @State private var hasLocallyScrapedSongs = false
    /// 资料库里只收了几首的 Apple Music 专辑:目录里其余的曲目(见 `TVAppleMusicPlayer.albumRemainder`)。
    @State private var appleMusicRemainder: TVAppleMusicPlayer.AlbumRemainder?
    /// 专辑文件夹里的封底(见 `TVAlbumBackArtwork`),没有就是 nil、背景照旧是封面取色。
    @State private var backCover: BackCover?
    /// 「更多」里选了串烧,等流量确认(见 `TVMedleyConfirmation`)。
    @State private var pendingMedleyIDs: [String]?
    /// 「更多」按钮与确认面板里的「取消」,值见 `RestoreFocus`。
    @FocusState private var focusedRestoreControl: String?
    @FocusState private var focusedTrackID: String?
    @Namespace private var detailFocus

    private enum RestoreFocus {
        static let more = "album.more"
        static let cancel = "restore.cancel"
    }

    private struct BackCover {
        let id: String
        let image: CGImage
    }

    /// 左栏宽:封面加探出来的半张盘,下面一排按钮放得下四颗(德语这类长文案放不下的折到下一行)。
    private static let leftColumnWidth: CGFloat = 660
    private static let coverSize: CGFloat = 260

    init(
        albumID: String,
        fallback: TVAlbum,
        initialFocusSongID: String? = nil,
        openPlayer: @escaping (String, String?) -> Void = { _, _ in }
    ) {
        self.fallback = fallback
        self.initialFocusSongID = initialFocusSongID
        self.openPlayer = openPlayer
        _albumID = State(initialValue: albumID)
    }

    /// 「关于这张专辑」:`songs` 为空时只是身份(专辑名 + 艺人),按下生成时再带上曲目与风格。
    static func insightSubject(album: TVAlbum, songs: [TVSong], library: MusicLibrary? = nil) -> LibraryInsightSubject {
        let artist = album.artist == String(localized: "unknown_artist") ? "" : album.artist
        return .album(
            title: album.title,
            artist: artist,
            year: album.year > 0 ? album.year : nil,
            genres: library.map { library in
                LibraryInsightSubject.topGenres(songs.map { library.song(id: $0.id)?.genre })
            } ?? [],
            tracks: songs.map(\.title)
        )
    }

    private struct Track: Identifiable {
        let id: String
        let song: TVSong
        let number: Int
        /// 多碟专辑里每张碟的第一首带上碟号,在它上面画分组标题。
        let discHeader: Int?
    }

    var body: some View {
        let album = store.album(albumID) ?? fallback
        let songs = store.songs(forAlbum: albumID)
        let songIDs = songs.map(\.id)
        let tracks = Self.tracks(for: songs, library: store.library)
        // 有手动编辑或刮削改过、不再跟随文件标签的歌时才给「恢复文件标签」。
        let hasEditedSongs = hasLocallyScrapedSongs
            || songIDs.contains { store.library.song(id: $0)?.userMetadataEditedAt != nil }
        ZStack {
            TVAmbientBackdrop(
                tint: album.tint, tint2: album.tint2, strength: 0.55,
                image: backCover?.image, imageID: backCover?.id
            )
            // 封底上多是密密的字:压得比封面取色底再暗一些,左栏的字和右边的曲目才看得清。
            TVColor.bg.opacity(backCover == nil ? 0.34 : 0.46).ignoresSafeArea()
            HStack(alignment: .top, spacing: 64) {
                leftColumn(album: album, songs: songs, songIDs: songIDs, hasEditedSongs: hasEditedSongs)
                    .frame(width: Self.leftColumnWidth, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .focusSection()

                ScrollViewReader { trackListProxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            TVEyebrow(text: PMString("ext.tv.search.songs"))
                                .padding(.bottom, 6)
                            if tracks.isEmpty {
                                TVEmptyState(
                                    icon: "music.note",
                                    title: PMString("ext.tv.search.noMatch")
                                )
                                .frame(minHeight: 360)
                            } else {
                                // 「未知专辑」这类大专辑可能上千首,照样分页渲染。
                                TVPagedList(
                                    tracks, alignment: .leading, spacing: 10,
                                    revealing: initialFocusSongID.flatMap { id in tracks.firstIndex { $0.id == id } }
                                ) { index, track, onFocusChanged in
                                    VStack(alignment: .leading, spacing: 10) {
                                        if let disc = track.discHeader {
                                            Text(verbatim: "\(String(localized: "disc_label")) \(disc)")
                                                .tvFont(.eyebrow, weight: .semibold)
                                                .foregroundStyle(TVColor.textMuted)
                                                .padding(.top, track.id == tracks.first?.id ? 0 : 18)
                                                .padding(.leading, 22)
                                        }
                                        trackRow(
                                            track,
                                            nextTrackID: tracks.indices.contains(index + 1) ? tracks[index + 1].id : nil,
                                            albumArtist: album.artist,
                                            onFocusChanged: onFocusChanged
                                        ) {
                                            guard store.play(track.song, in: songIDs) else { return }
                                            finishPlayback(songID: track.id)
                                        }
                                    }
                                }
                            }
                            if let remainder = appleMusicRemainder {
                                appleMusicRemainderSection(remainder, albumArtist: album.artist)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 20)
                        .padding(.bottom, TVScrollEdgeFade.bottom)
                    }
                    .tvScrollEdgeFade()
                    .focusSection()
                    .task {
                        // 从播放页回来:焦点放回刚播的那首。覆盖层呈现完、曲目行建出来之前设的焦点会被丢掉,
                        // 没落上就隔一会儿再设(机器忙、刚换了语言时呈现会慢),最多等三秒多;长专辑里那一首在
                        // 屏幕外时懒加载的列表还没建它那一行,先滚过去。
                        guard let initialFocusSongID else { return }
                        for attempt in 0..<8 {
                            try? await Task.sleep(nanoseconds: attempt == 0 ? 350_000_000 : 300_000_000)
                            guard !Task.isCancelled else { return }
                            trackListProxy.scrollTo(initialFocusSongID, anchor: .center)
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            focusedTrackID = initialFocusSongID
                            try? await Task.sleep(nanoseconds: 150_000_000)
                            if focusedTrackID == initialFocusSongID { break }
                        }
                        #if DEBUG
                        plog("TV album detail reopened focus=\(focusedTrackID == initialFocusSongID ? "track" : "other")")
                        #endif
                    }
                }
            }
            .padding(.horizontal, 100)
            // 系统已经在上下各留了安全边距,这里只再让一点:简介要用左栏剩下的高度。
            .padding(.top, 20)
            .padding(.bottom, 28)
            // 确认面板盖在上面时底下不接焦点,方向键出不了面板。
            .disabled(showsRestoreConfirmation)

            if showsRestoreConfirmation {
                restoreConfirmation(songIDs)
                    // 收起时立刻拿掉,不淡出:焦点还在面板的按钮上,淡出放完那一下若碰上
                    // 送回「更多」键的那次焦点更新,UIKit 会断言闪退(见 `closeRestoreConfirmation`)。
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    .zIndex(5)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsRestoreConfirmation)
        .focusScope(detailFocus)
        .modifier(TVLibraryRemovalConfirmation(request: $pendingRemoval))
        .modifier(TVMedleyConfirmation(pendingIDs: $pendingMedleyIDs) { finishPlayback(songID: store.currentSongID) })
        .onExitCommand {
            if showsRestoreConfirmation {
                closeRestoreConfirmation()
            } else {
                dismiss()
            }
        }
        #if DEBUG
        .task {
            // 截图用:TV_SCREEN=albumDetail TV_RESTORE_DEBUG=1 先把第一首的标题改掉并打上「用户编辑」
            // (相当于刮削改过),弹出确认面板,6 秒后真的恢复;日志 `TV restore debug` 前后对比标题。
            // CUE 专辑上还把这一首的专辑艺术家、碟号换掉(补全拆专辑的样子),它会先离开这张专辑,
            // 恢复时靠同一张 CUE 的其它轨把它带回来;日志里 `tracks=` 是前后的曲目数。
            guard ProcessInfo.processInfo.environment["TV_RESTORE_DEBUG"] == "1",
                  let songID = store.songIDs(forAlbum: albumID).first,
                  var edited = store.library.song(id: songID) else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let original = edited.title
            let tracksBefore = store.songIDs(forAlbum: albumID).count
            edited.title = original + " · Scraped"
            if edited.isCueTrack {
                edited.albumArtistName = "Scraped Album Artist"
                edited.discNumber = 2
            }
            edited.userMetadataEditedAt = Date()
            store.library.replaceSong(edited)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let tracksSplit = store.songIDs(forAlbum: albumID).count
            showsRestoreConfirmation = true
            focusedRestoreControl = RestoreFocus.cancel
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            restoreFileTags(store.songIDs(forAlbum: albumID))
            while restoreProgress?.isFinished != true {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            let after = store.library.song(id: songID)
            plog("TV restore debug before=\(original) edited=\(edited.title) after=\(after?.title ?? "-")"
                 + " stamp=\(after?.userMetadataEditedAt == nil ? "cleared" : "kept")"
                 + " cue=\(edited.isCueTrack) tracks=\(tracksBefore)->\(tracksSplit)->\(store.songIDs(forAlbum: albumID).count)"
                 + " albumArtist=\(after?.albumArtistName ?? "-") disc=\(after?.discNumber.map(String.init) ?? "-")")
        }
        #endif
        .fullScreenCover(isPresented: $showsAlbumScrape, onDismiss: albumScrapeDismissed) {
            TVAlbumScrapeView(albumID: albumID).environment(store)
        }
        .task(id: songIDs) { await refreshLocallyScrapedSongs(songIDs) }
        .task(id: songIDs) { await loadAppleMusicRemainder(album: album, songIDs: songIDs) }
        .task(id: albumID) { await loadBackCover() }
        .accessibilityIdentifier("tv.album.detail")
    }

    /// 左栏:封面(后面探出半张盘)、专辑名、艺人、年份 · 首数 · 时长、一排按钮,剩下的高度都给简介。
    private func leftColumn(album: TVAlbum, songs: [TVSong], songIDs: [String], hasEditedSongs: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TVAlbumCaseArtwork(album: album, size: Self.coverSize, spinning: isPlayingThisAlbum) {
                TVArtworkView(album: album, size: Self.coverSize, radius: 14)
                    .modifier(TVArtworkGentleFloat())
            }
            Text(album.title)
                .tvFont(.pageTitle)
                .foregroundStyle(TVColor.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 30)
            Text(album.artist)
                .tvFont(.body)
                .foregroundStyle(TVColor.textMuted)
                .lineLimit(1)
                .padding(.top, 8)
            Text(verbatim: Self.summary(album: album, songs: songs))
                .tvFont(.caption)
                .foregroundStyle(TVColor.textFaint)
                .padding(.top, 6)
            TVButtonFlow {
                TVPillButton(
                    title: String(localized: "play_all"),
                    systemImage: "play.fill",
                    style: .solid,
                    action: { play(songIDs, shuffled: false) }
                )
                .prefersDefaultFocus(initialFocusSongID == nil, in: detailFocus)
                TVPillButton(
                    title: String(localized: "shuffle"),
                    systemImage: "shuffle",
                    action: { play(songIDs, shuffled: true) }
                )
                if let libraryAlbum = store.library.visibleAlbum(id: albumID) {
                    TVFavoriteIconButton(
                        isLiked: LibraryFavoritesStore.shared.isLiked(libraryAlbum),
                        action: { LibraryFavoritesStore.shared.toggle(libraryAlbum) }
                    )
                }
                moreMenu(songIDs, hasEditedSongs: hasEditedSongs)
            }
            .disabled(songIDs.isEmpty)
            .padding(.top, 26)
            if let restoreProgress {
                Text(verbatim: Self.restoreStatus(restoreProgress))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textFaint)
                    .monospacedDigit()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
            }
            // 简介拿剩下的高度:放不下的部分自己慢慢往上滚,按下看全文。
            TVLibraryInsightBlock(
                subject: Self.insightSubject(album: album, songs: []),
                details: { Self.insightSubject(album: album, songs: songs, library: store.library) },
                fillsHeight: true
            )
            .padding(.top, 28)
            .layoutPriority(-1)
        }
    }

    /// 这张专辑里的歌正在放(暂停时盘停下)。
    private var isPlayingThisAlbum: Bool {
        guard store.hasNowPlaying, store.isPlaying, let current = store.currentSongID else { return false }
        return store.song(current)?.albumID == albumID
    }

    /// 「更多」:串烧、补全专辑信息、恢复文件标签。外观同旁边的「喜欢」。选完菜单先收起、
    /// 焦点回到这颗按钮上,再弹确认框或打开补全页(见 `TVModalHandoff`)。
    private func moreMenu(_ songIDs: [String], hasEditedSongs: Bool) -> some View {
        let focused = focusedRestoreControl == RestoreFocus.more
        return Menu {
            Button(String(localized: "medley_play_selection"), systemImage: "rectangle.stack.badge.play") {
                TVModalHandoff.afterFocusSettles { pendingMedleyIDs = songIDs }
            }
            .disabled(!store.canPlayMedley(songIDs: songIDs))
            Button(String(localized: "tv_scrape_album_title"), systemImage: "wand.and.stars") {
                TVModalHandoff.afterFocusSettles {
                    songIDsBeforeScrape = songIDs
                    showsAlbumScrape = true
                }
            }
            // 有手动编辑或刮削改过、不再跟随文件标签的歌时才有。
            if hasEditedSongs {
                Button(String(localized: "restore_file_tags"), systemImage: "arrow.uturn.backward") {
                    TVModalHandoff.afterFocusSettles {
                        showsRestoreConfirmation = true
                        Task { @MainActor in
                            await Task.yield()
                            focusedRestoreControl = RestoreFocus.cancel
                        }
                    }
                }
                .disabled(restoreProgress?.isFinished == false)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(focused ? TVColor.onFocusFill : TVColor.text)
                .frame(width: 36, height: 36)
                .padding(18)
                .background(focused ? TVColor.focusFill : TVColor.surfaceStrong)
                .tvFocusRing(focused, radius: 14, scale: 1.04, lift: 6)
        }
        .menuStyle(.button)
        .buttonStyle(TVBareButtonStyle())
        .focused($focusedRestoreControl, equals: RestoreFocus.more)
        .focusEffectDisabled()
        .accessibilityLabel(Text("more"))
        .accessibilityIdentifier("tv.album.more")
    }

    /// 专辑文件夹里有封底就铺成背景;专辑换了 id(补全改了专辑名)跟着重找。
    private func loadBackCover() async {
        guard let firstSongID = store.songIDs(forAlbum: albumID).first else {
            backCover = nil
            return
        }
        let found = await TVAlbumBackArtwork.softenedFirstImage(forAlbumSongID: firstSongID, store: store)
        guard !Task.isCancelled else { return }
        #if DEBUG
        plog("TV album back cover album=\(albumID.prefix(12)) found=\(found != nil)")
        #endif
        backCover = found.map { BackCover(id: $0.id, image: $0.image) }
    }

    private func albumScrapeDismissed() {
        followAlbumAfterScrape()
        Task { @MainActor in await refreshLocallyScrapedSongs(store.songIDs(forAlbum: albumID)) }
    }

    /// 专辑里全是 Apple Music 的歌时,问一次目录这张专辑还有哪些曲目资料库里没有。
    private func loadAppleMusicRemainder(album: TVAlbum, songIDs: [String]) async {
        let librarySongs = songIDs.compactMap { store.library.song(id: $0) }
        guard !librarySongs.isEmpty,
              librarySongs.allSatisfy({ $0.sourceID == AppleMusicLibraryIdentity.sourceID }) else {
            appleMusicRemainder = nil
            return
        }
        let remainder = await TVAppleMusicPlayer.albumRemainder(
            title: album.title,
            artist: album.artist,
            librarySongs: librarySongs
        )
        guard !Task.isCancelled else { return }
        appleMusicRemainder = remainder
    }

    /// 曲目列表下面一段:Apple Music 上这张专辑其余的曲目。选中哪首都按 Apple Music 整张专辑
    /// 从那首开始放 —— 这几首不在曲库里,进不了电视的曲库队列。
    @ViewBuilder
    private func appleMusicRemainderSection(
        _ remainder: TVAppleMusicPlayer.AlbumRemainder,
        albumArtist: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "applelogo")
                .font(.system(size: 20, weight: .semibold))
            TVEyebrow(text: "Apple Music")
        }
        .foregroundStyle(TVColor.textFaint)
        .padding(.top, 28)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        ForEach(remainder.tracks) { track in
            appleMusicTrackRow(track, remainder: remainder, albumArtist: albumArtist)
        }
    }

    /// 资料库里没有的一首:字色压淡一档,没有长按菜单(收藏、加歌单都要曲库里的歌)。
    private func appleMusicTrackRow(
        _ track: TVAppleMusicPlayer.AlbumRemainder.Track,
        remainder: TVAppleMusicPlayer.AlbumRemainder,
        albumArtist: String
    ) -> some View {
        let showsArtist = !track.artist.isEmpty
            && track.artist.localizedCaseInsensitiveCompare(albumArtist) != .orderedSame
        return TVFocusButton(
            radius: 16, scale: 1.02, lift: 0,
            action: {
                store.playAppleMusicAlbum(
                    id: remainder.albumID,
                    title: remainder.title,
                    artist: remainder.artist,
                    startTrackID: track.id
                )
                finishPlayback(songID: nil)
            },
            focusBinding: $focusedTrackID, focusID: "appleMusic." + track.id
        ) { focused in
            HStack(spacing: 22) {
                Text(verbatim: "\(track.number)")
                    .tvFont(.caption, design: .monospaced)
                    .foregroundStyle(TVColor.textFaint)
                    .frame(width: 56, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).tvFont(.rowTitle)
                        .foregroundStyle(focused ? TVColor.text : TVColor.textMuted)
                        .lineLimit(1)
                    if showsArtist {
                        Text(track.artist).tvFont(.caption)
                            .foregroundStyle(TVColor.textFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                Text(TVFmt.time(track.duration))
                    .tvFont(.meta, design: .monospaced)
                    .foregroundStyle(TVColor.textFaint)
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 84)
            .background(focused ? TVColor.surfaceStrong : TVColor.card.opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("tv.album.appleMusicTrack.\(track.id)")
    }

    private func refreshLocallyScrapedSongs(_ songIDs: [String]) async {
        hasLocallyScrapedSongs = await store.metadataScraper.hasLocalTagChanges(songIDs: songIDs)
    }

    // MARK: 恢复文件标签

    private static func restoreStatus(_ progress: TVRestoreFileTagsProgress) -> String {
        if progress.isFinished {
            return String(
                format: String(localized: "metadata_status_reread_result_format"),
                Int64(progress.completed), Int64(progress.failed), Int64(progress.skipped)
            )
        }
        return String(
            format: String(localized: "metadata_status_reread_progress_format"),
            Int64(progress.processed), Int64(progress.total)
        )
    }

    /// 电视端弹框统一是「压暗背景 + 居中面板」;默认焦点在「取消」上。
    private func restoreConfirmation(_ songIDs: [String]) -> some View {
        ZStack {
            TVColor.bg.opacity(0.62).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text(String(localized: "restore_file_tags"))
                    .tvFont(.sectionTitle)
                    .foregroundStyle(TVColor.text)
                Text(String(localized: "restore_file_tags_message"))
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 18) {
                    TVPillButton(
                        title: String(localized: "restore_file_tags_confirm"),
                        systemImage: "arrow.uturn.backward",
                        style: .solid,
                        action: { restoreFileTags(songIDs) }
                    )
                    TVPillButton(
                        title: String(localized: "cancel"),
                        systemImage: "xmark",
                        focusBinding: $focusedRestoreControl,
                        focusID: RestoreFocus.cancel,
                        action: closeRestoreConfirmation
                    )
                }
            }
            .padding(36)
            .frame(width: 860, alignment: .leading)
            .tvPanel(radius: 22)
            // 面板底色是半透明的,压在曲目列表上会透出底下的字:垫一层不透明的页面底色。
            .background(TVColor.bg, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .focusSection()
        .accessibilityIdentifier("tv.album.restoreFileTags.confirm")
    }

    private func closeRestoreConfirmation() {
        showsRestoreConfirmation = false
        Task { @MainActor in
            await Task.yield()
            focusedRestoreControl = RestoreFocus.more
        }
    }

    private func restoreFileTags(_ songIDs: [String]) {
        closeRestoreConfirmation()
        songIDsBeforeScrape = songIDs
        restoreProgress = TVRestoreFileTagsProgress(total: songIDs.count)
        let scraper = store.metadataScraper
        Task { @MainActor in
            restoreProgress = await scraper.restoreFileTags(songIDs: songIDs) { restoreProgress = $0 }
            // 换回文件里的专辑名后,这张专辑的歌可能归到了另一个专辑 id 下。
            followAlbumAfterScrape()
            await refreshLocallyScrapedSongs(store.songIDs(forAlbum: albumID))
        }
    }

    /// 补全改了专辑名(或专辑艺人)时,这张专辑的歌归到了新的专辑 id 下。
    private func followAlbumAfterScrape() {
        defer { songIDsBeforeScrape = [] }
        guard store.songIDs(forAlbum: albumID).isEmpty,
              let moved = songIDsBeforeScrape.lazy.compactMap({ store.song($0)?.albumID }).first else { return }
        albumID = moved
    }

    private func trackRow(
        _ track: Track,
        nextTrackID: String?,
        albumArtist: String,
        onFocusChanged: @escaping (Bool) -> Void,
        action: @escaping () -> Void
    ) -> some View {
        let song = track.song
        let isCurrent = store.hasNowPlaying && store.currentSongID == song.id
        let showsArtist = !song.artist.isEmpty
            && song.artist.localizedCaseInsensitiveCompare(albumArtist) != .orderedSame
        return TVFocusButton(
            radius: 16, scale: 1.02, lift: 0,
            action: action, onFocusChanged: onFocusChanged,
            focusBinding: $focusedTrackID, focusID: track.id
        ) { focused in
            HStack(spacing: 22) {
                ZStack(alignment: .trailing) {
                    Text(verbatim: "\(track.number)")
                        .tvFont(.caption, design: .monospaced)
                        .foregroundStyle(TVColor.textFaint)
                        .opacity(isCurrent ? 0 : 1)
                    if isCurrent {
                        TVNowPlayingBars(isPlaying: store.isPlaying)
                    }
                }
                .frame(width: 56, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).tvFont(.rowTitle)
                        .foregroundStyle(isCurrent ? TVColor.brand : TVColor.text)
                        .lineLimit(1)
                    if showsArtist {
                        Text(song.artist).tvFont(.caption)
                            .foregroundStyle(TVColor.textFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                // 随机时和下一首连着放(#335)。
                if let nextTrackID, store.isShuffleJoined(song.id, to: nextTrackID) {
                    Image(systemName: "link").font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(TVColor.textFaint)
                        .accessibilityLabel(Text("shuffle_link_joined_a11y"))
                }
                if store.isLiked(song.id) {
                    Image(systemName: "heart.fill").font(.system(size: 22))
                        .foregroundStyle(TVColor.brand)
                }
                Text(TVFmt.time(song.duration))
                    .tvFont(.meta, design: .monospaced)
                    .foregroundStyle(TVColor.textFaint)
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 84)
            .background(focused ? TVColor.surfaceStrong : TVColor.card,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .contextMenu {
            TVSongLikeMenuItem(store: store, songID: song.id)
            Button("song_remove_from_device", systemImage: "minus.circle", role: .destructive) {
                pendingRemoval = TVLibraryRemovalRequest(title: song.title, songIDs: [song.id])
            }
        }
        .accessibilityIdentifier("tv.album.track.\(track.id)")
    }

    /// 年份 · 首数 · 总时长。
    private static func summary(album: TVAlbum, songs: [TVSong]) -> String {
        var parts: [String] = []
        if album.year > 0 { parts.append("\(album.year)") }
        parts.append(PMString("ext.tv.songsCount", songs.count))
        let total = songs.reduce(0) { $0 + TimeInterval.sanitized($1.duration) }
        if total > 0 { parts.append(total.formattedDuration) }
        return parts.joined(separator: " · ")
    }

    /// 轨号取标签里的(CUE 分轨就是 CUE 里的轨号),没有就按专辑里的顺序编号。
    /// `songs(forAlbum:)` 已按碟号、轨号排好,这里只标出每张碟的起点。
    private static func tracks(for songs: [TVSong], library: MusicLibrary) -> [Track] {
        let details = songs.map { library.song(id: $0.id) }
        let discs = Set(details.compactMap { $0?.discNumber }.filter { $0 > 0 })
        let isMultiDisc = discs.count > 1
        var previousDisc: Int?
        return songs.enumerated().map { index, song in
            let detail = details[index]
            let disc = detail?.discNumber ?? 0
            let header: Int?
            if isMultiDisc, disc > 0, disc != previousDisc {
                header = disc
                previousDisc = disc
            } else {
                header = nil
            }
            let number = detail?.trackNumber.flatMap { $0 > 0 ? $0 : nil } ?? index + 1
            return Track(id: song.id, song: song, number: number, discHeader: header)
        }
    }

    private func play(_ songIDs: [String], shuffled: Bool) {
        guard store.playResolvedQueue(songIDs: songIDs, shuffled: shuffled) else { return }
        // 全部 / 随机播放也记下开播的那一首:从播放页回来焦点落在它那一行,不是「全部播放」。
        finishPlayback(songID: store.currentSongID)
    }

    private func finishPlayback(songID: String?) {
        openPlayer(albumID, songID)
        dismiss()
    }
}

/// 歌曲行 — 封面 + 标题/艺术家 + 时长。
struct TVSongRow: View {
    @Environment(TVStore.self) private var store
    @State private var pendingRemoval: TVLibraryRemovalRequest?
    let song: TVSong
    var reason: String? = nil
    var queueSongIDs: [String]? = nil
    var action: () -> Void = {}
    /// 长列表分页要知道焦点走到哪一行了,见 `TVPagedSongIDList`。
    var onFocusChanged: (Bool) -> Void = { _ in }
    /// 父视图的焦点绑定(见 `TVFocusButton`):字母栏跳转、回到歌曲页时把焦点放到这一行。
    var focusBinding: FocusState<String?>.Binding? = nil
    var focusID: String? = nil

    var body: some View {
        let album = store.albumOf(song)
        let isCurrent = store.hasNowPlaying && store.currentSongID == song.id
        TVFocusButton(radius: TVRadius.card, scale: 1.02, lift: 0,
                      action: {
                          // 列表内点歌保持该列表为队列,并沿用当前随机开关;
                          // 没给列表时按可见曲库顺序续播。
                          if let queueSongIDs {
                              guard store.play(song, in: queueSongIDs) else { return }
                          } else { store.play(song) }
                          action()
                      },
                      onFocusChanged: onFocusChanged,
                      focusBinding: focusBinding,
                      focusID: focusID) { focused in
            HStack(spacing: 18) {
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", songID: song.id, coverRef: song.coverRef,
                              tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: 64, radius: 8)
                    .overlay {
                        if isCurrent {
                            ZStack {
                                Color.black.opacity(0.42)
                                TVNowPlayingBars(isPlaying: store.isPlaying, color: .white, barWidth: 4, height: 22)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    if let reason {
                        Label(reason, systemImage: "sparkles")
                            .tvFont(.meta, weight: .semibold)
                            .foregroundStyle(TVColor.brand)
                            .lineLimit(1)
                    }
                    Text(song.title).tvFont(.cardTitle)
                        .foregroundStyle(isCurrent ? TVColor.brand : TVColor.text).lineLimit(2)
                    Text(song.artist).tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint).lineLimit(1)
                }
                Spacer(minLength: 0)
                if store.isLiked(song.id) {
                    Image(systemName: "heart.fill").font(.system(size: 22))
                        .foregroundStyle(TVColor.brand)
                }
                Text(song.format).tvFont(.meta, weight: .semibold)
                    .foregroundStyle(TVColor.textGhost)
                Text(TVFmt.time(song.duration)).tvFont(.caption, design: .monospaced)
                    .foregroundStyle(TVColor.textFaint)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : TVColor.card)
        }
        .contextMenu {
            TVSongLikeMenuItem(store: store, songID: song.id)
            Button("song_remove_from_device", systemImage: "minus.circle", role: .destructive) {
                pendingRemoval = TVLibraryRemovalRequest(title: song.title, songIDs: [song.id])
            }
        }
        .modifier(TVLibraryRemovalConfirmation(request: $pendingRemoval))
    }
}

/// 歌曲行长按菜单里的喜欢 / 取消喜欢与不喜欢(#193),与播放页封面菜单同一种写法。
/// 按值传入 store:菜单内容可能挪到独立宿主里求值,不读 `@Environment`。
struct TVSongLikeMenuItem: View {
    let store: TVStore
    let songID: String

    var body: some View {
        let liked = store.isLiked(songID)
        Button(
            PMString(liked ? "ext.tv.options.loved" : "ext.tv.options.love"),
            systemImage: liked ? "heart.fill" : "heart"
        ) {
            store.toggleLiked(songID)
        }
        if store.canDislike(songID) {
            let disliked = store.isDisliked(songID)
            Button(
                disliked ? String(localized: "song_undislike") : String(localized: "song_dislike"),
                systemImage: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown"
            ) {
                store.toggleDisliked(songID)
            }
        }
        // 随机时连播(#335):和专辑里相邻的那首连着放,开着的打勾。
        ForEach(ShuffleLinkDirection.allCases, id: \.self) { direction in
            if store.shuffleLinkNeighborTitle(songID, direction) != nil {
                Button(
                    direction == .next
                        ? String(localized: "shuffle_link_next_long")
                        : String(localized: "shuffle_link_previous_long"),
                    systemImage: store.isShuffleLinked(songID, direction)
                        ? "checkmark"
                        : (direction == .next ? "forward.end" : "backward.end")
                ) {
                    store.toggleShuffleLink(songID, direction)
                }
            }
        }
        // 设过播放时间段的歌,长按就能开关它;时间段本身在播放页「更多」里编辑。
        if let song = store.library.song(id: songID), store.supportsPlaybackRange(for: song),
           let range = SongPlaybackRangeStore.shared.range(for: song) {
            let format = range.isEnabled
                ? String(localized: "playback_range_turn_off %@")
                : String(localized: "playback_range_turn_on %@")
            Button(
                String(format: format, SongPlaybackRangePolicy.rangeLabel(range)),
                systemImage: "selection.pin.in.out"
            ) {
                SongPlaybackRangeStore.shared.setEnabled(!range.isEnabled, for: song)
            }
        }
    }
}

/// 歌曲页给 `TVIndexedGrid` 的条目:只包一层 id,不为几十万首歌各建一份界面值。
struct TVSongIDItems: RandomAccessCollection {
    struct Item: Identifiable {
        let id: String
    }

    let ids: [String]
    var startIndex: Int { ids.startIndex }
    var endIndex: Int { ids.endIndex }
    subscript(position: Int) -> Item { Item(id: ids[position]) }
}

/// 由歌曲 ID 列表驱动的分页歌曲列表。
///
/// 整份列表一次性交给 `ForEach`,遥控器就会失去响应 —— 原因和行数上限见
/// `TVLongListPagingPolicy`。点歌仍以完整列表入队,分页只影响渲染多少行。
struct TVPagedSongIDList: View {
    let songIDs: [String]
    var alignment: HorizontalAlignment = .center
    var spacing: CGFloat = 10
    var action: () -> Void = {}
    /// 父视图的焦点绑定,每一行的焦点 id 是 `focusIDPrefix` + 歌曲 id(从播放页回来时放回刚播的那首)。
    var focusBinding: FocusState<String?>.Binding? = nil
    var focusIDPrefix = ""
    /// 首次渲染就要覆盖到的那一首,免得它排在第一页之后、焦点放不上去。
    var revealingSongID: String? = nil

    @Environment(TVStore.self) private var store

    var body: some View {
        TVPagedList(
            songIDs, id: \.self, alignment: alignment, spacing: spacing,
            revealing: revealingSongID.flatMap { songIDs.firstIndex(of: $0) }
        ) { _, songID, onFocusChanged in
            if let song = store.song(songID) {
                TVSongRow(
                    song: song,
                    queueSongIDs: songIDs,
                    action: action,
                    onFocusChanged: onFocusChanged,
                    focusBinding: focusBinding,
                    focusID: focusBinding == nil ? nil : focusIDPrefix + songID
                )
            }
        }
    }
}
#endif
