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
    /// 从哪张专辑页开始播放、点的是哪一首。播放页按 Menu 回来时先回到这张专辑页、
    /// 焦点落在那一首,再按一次才回海报墙;在专辑页里按 Menu 关掉就清空。
    var albumDetailID: String?
    var albumDetailSongID: String?
    /// 只有从播放页按 Menu 回来的那一次才重开专辑页;经顶栏换页再回来不弹。
    var restoresAlbumDetail = false
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
    @FocusState private var focusedAlbumOrder: LibraryAlbumBrowseOrder?
    @AppStorage(ArtistBrowseMode.storageKey)
    private var artistBrowseModeRaw = ArtistBrowseMode.allArtists.rawValue
    @FocusState private var focusedArtistBrowseMode: ArtistBrowseMode?
    /// 右侧字母栏上的焦点;有值时网格中央浮出这个字母。
    @FocusState private var focusedIndexBucket: String?
    /// 网格里当前聚焦的卡片属于哪个字母,字母栏据此点亮。
    @State private var currentIndexBucket: String?
    @State private var gridJumpRequest: TVGridJumpRequest?
    @State private var selectedArtist: TVArtist?
    /// 艺人墙「只看喜欢」。
    @State private var showsLikedArtistsOnly = false
    @FocusState private var focusesLikedArtistsChip: Bool
    @State private var opensPlayerAfterArtistDismissal = false
    @State private var selectedAlbum: TVAlbum?
    /// 从播放页回来重开专辑页时,焦点要落到的那一首。
    @State private var reopenedAlbumSongID: String?

    #if DEBUG
    /// 截图用的 `albumDetail` 只在首次进资料库时打开一次。
    @MainActor private static var didOpenDebugAlbumDetail = false
    #endif

    private let gridMetrics = TVBrowseGridMetrics.music
    var focusRequest = 0
    var browseMemory = TVLibraryBrowseMemory()

    var body: some View {
        GeometryReader { geo in
            let indexSections = letterIndexSections
            let indexBarSpace = indexSections.isEmpty ? 0 : TVLetterIndexBar.width + Self.indexBarGap
            let cell = gridMetrics.cellWidth(pageWidth: geo.size.width - indexBarSpace)
            VStack(alignment: .leading, spacing: 24) {
                filterStrip
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
        .onExitCommand {
            if focusedGridItem != nil || focusedIndexBucket != nil || focusedAlbumOrder != nil
                || focusedArtistBrowseMode != nil {
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
            default: break
            }
        }
        .onChange(of: filter) { _, _ in resetLetterIndex() }
        .onAppear(perform: leaveHiddenFilter)
        .onChange(of: filterConfigurationRawValue) { _, _ in leaveHiddenFilter() }
        .onChange(of: artistBrowseModeRaw) { _, _ in
            // 换了列法,上次停的那位可能已经不在墙上;网格从头开始,焦点留在切换按钮上。
            browseMemory.artistID = nil
            resetLetterIndex()
        }
        .onChange(of: albumOrderRawValue) { _, _ in
            // 换了排序方式,上次停的那张卡片在新顺序里的位置没有意义;网格从头开始,
            // 焦点留在排序按钮上。
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
                using: intelligence
            )
        }
        .fullScreenCover(item: $selectedArtist, onDismiss: finishArtistDismissal) { artist in
            TVArtistDetailView(
                artist: artist,
                openPlayer: { opensPlayerAfterArtistDismissal = true }
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
        .modifier(TVAlbumDetailPresenter(
            album: $selectedAlbum,
            openPlayer: openPlayer,
            onPresentationChanged: onModalActivityChanged,
            initialFocusSongID: reopenedAlbumSongID,
            onPlaybackStarted: { albumID, songID in
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
        .onAppear(perform: reopenAlbumDetailAfterPlayer)
        #if DEBUG
        .task {
            guard TVDebugLaunch.screen == "albumDetail", !Self.didOpenDebugAlbumDetail else { return }
            Self.didOpenDebugAlbumDetail = true
            var tries = 0
            while store.albums.isEmpty && tries < 25 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                tries += 1
            }
            selectedAlbum = store.albums.first { (4...40).contains(store.songIDs(forAlbum: $0.id).count) }
                ?? store.albums.first
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
        default:
            return []
        }
    }

    /// 从播放页按 Menu 回来:起播的那张专辑页不带动画地重新挂上,焦点落回刚播的那首。
    private func reopenAlbumDetailAfterPlayer() {
        let restores = browseMemory.restoresAlbumDetail
        browseMemory.restoresAlbumDetail = false
        guard restores, let albumID = browseMemory.albumDetailID, let album = store.album(albumID) else {
            browseMemory.albumDetailID = nil
            browseMemory.albumDetailSongID = nil
            return
        }
        reopenedAlbumSongID = browseMemory.albumDetailSongID
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { selectedAlbum = album }
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

    /// 页标题;专辑墙右侧是排序方式。
    private var titleRow: some View {
        HStack(alignment: .center, spacing: 24) {
            Text(title).tvFont(.pageTitle).foregroundStyle(TVColor.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if filter == .albums {
                albumOrderPicker
            }
            if filter == .artists {
                artistBrowseModePicker
            }
            if filter == .artists,
               showsLikedArtistsOnly || LibraryFavoritesStore.shared.hasLikedArtists {
                likedArtistsChip
            }
        }
    }

    private var likedArtistsChip: some View {
        Button {
            showsLikedArtistsOnly.toggle()
            resetLetterIndex()
        } label: {
            TVFilterChipLabel(
                title: String(localized: "library_favorite_filter_short"),
                systemImage: showsLikedArtistsOnly ? "heart.fill" : "heart",
                isSelected: showsLikedArtistsOnly,
                isFocused: focusesLikedArtistsChip
            )
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focusesLikedArtistsChip)
        .focusEffectDisabled()
        .padding(.vertical, 6)
        .accessibilityLabel(Text("library_favorite_filter"))
        .accessibilityAddTraits(showsLikedArtistsOnly ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tv.library.likedArtists")
    }

    /// 艺人墙列全部艺人还是只列专辑艺人。
    private var artistBrowseModePicker: some View {
        HStack(spacing: 12) {
            ForEach(ArtistBrowseMode.allCases, id: \.self) { mode in
                Button {
                    artistBrowseModeRaw = mode.rawValue
                } label: {
                    TVFilterChipLabel(
                        title: mode.title,
                        systemImage: mode.systemImage,
                        isSelected: mode == artistBrowseMode,
                        isFocused: focusedArtistBrowseMode == mode
                    )
                }
                .buttonStyle(TVBareButtonStyle())
                .focused($focusedArtistBrowseMode, equals: mode)
                .focusEffectDisabled()
                .accessibilityIdentifier("tv.library.artistMode." + mode.rawValue)
                .accessibilityAddTraits(mode == artistBrowseMode ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 6)
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("artist_browse_mode"))
    }

    private var albumOrderPicker: some View {
        HStack(spacing: 12) {
            // 「喜欢」只在有喜欢的专辑（或正选着它）时出现。
            ForEach(LibraryAlbumBrowseOrder.allCases.filter {
                $0 != .liked || albumOrder == .liked || LibraryFavoritesStore.shared.hasLikedAlbums
            }, id: \.self) { order in
                Button {
                    albumOrderRawValue = order.rawValue
                } label: {
                    TVFilterChipLabel(
                        title: order.title,
                        systemImage: order.systemImage,
                        isSelected: order == albumOrder,
                        isFocused: focusedAlbumOrder == order
                    )
                }
                .buttonStyle(TVBareButtonStyle())
                .focused($focusedAlbumOrder, equals: order)
                .focusEffectDisabled()
                .accessibilityIdentifier("tv.library.albumOrder." + order.rawValue)
                .accessibilityAddTraits(order == albumOrder ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 6)
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("sort_by"))
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

    private var filterStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PMString("ext.tv.library.eyebrow")).tvFont(.eyebrow)
                .foregroundStyle(TVColor.textMuted)
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
                    revealingIndex: browseMemory.albumID.flatMap { id in
                        layout.items.source.firstIndex { $0.id == id }
                    },
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
                                    if focused { browseMemory.albumID = album.id }
                                },
                                onOpen: { selectedAlbum = album },
                                focusBinding: $focusedGridItem,
                                focusID: Self.albumFocusID(album.id))
                        .accessibilityIdentifier("tv.library.album.\(index)")
                }
                .id(wallOrder)
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
                    revealingIndex: browseMemory.artistID.flatMap { id in
                        layout.items.source.firstIndex { $0.id == id }
                    },
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
                            if focused { browseMemory.artistID = artist.id }
                        },
                        focusBinding: $focusedGridItem,
                        focusID: Self.artistFocusID(artist.id)
                    )
                        .frame(width: cell)
                        .accessibilityIdentifier("tv.library.artist.\(index)")
                }
                .onAppear { revealBrowseAnchor(with: proxy) }
            } else {
                browseLayoutPlaceholder
            }
        case .songs:
            TVPagedSongIDList(songIDs: store.songIDs, alignment: .leading, action: openPlayer)
        case .genres:
            TVGenreBrowser(openPlayer: openPlayer, onModalActivityChanged: onModalActivityChanged)
        case .folders:
            TVFolderBrowser(openPlayer: openPlayer, onNavigation: onFolderNavigation)
        case .ranking:
            TVRankingBrowser(openPlayer: openPlayer, onModalActivityChanged: onModalActivityChanged)
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
        guard opensPlayerAfterArtistDismissal else { return }
        opensPlayerAfterArtistDismissal = false
        openPlayer()
    }
}

/// TV artist destination shared by Library and Search. It keeps the artist's
/// queue scope explicit instead of treating an artist card as a player shortcut.
struct TVArtistDetailView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let artist: TVArtist
    var openPlayer: () -> Void = {}

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
                    HStack(spacing: 14) {
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
                    }
                    TVMedleyButton(songIDs: artistSongIDs) { openPlayer(); dismiss() }
                    Spacer(minLength: 0)
                }
                .frame(width: 440, alignment: .leading)

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
                            TVPagedSongIDList(songIDs: artistSongIDs, alignment: .leading, action: finishPlayback)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, TVScrollEdgeFade.bottom)
                }
                .tvScrollEdgeFade()
                .focusSection()
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
    /// 在专辑页里开始播放:专辑 id 与点的那首(全部 / 随机播放时为 nil)。
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
        openPlayer()
    }
}

/// 专辑页:按下专辑封面先看到整张专辑的曲目,从哪一首点下去就从哪一首播,
/// 整张专辑仍是队列。「全部播放 / 随机播放 / 串烧」与艺人页同一排布。
struct TVAlbumDetailView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// 打开时的那份;封面取色、曲库刷新后按 id 重新取。
    let fallback: TVAlbum
    /// 打开时焦点落到的曲目;nil 落在「全部播放」。
    var initialFocusSongID: String?
    /// 开始播放:专辑 id 与点的那首(全部 / 随机 / 串烧时为 nil)。
    var openPlayer: (String, String?) -> Void = { _, _ in }
    /// 当前显示的专辑。补全专辑信息改了专辑名时专辑会换 id,跟着它的歌走过去。
    @State private var albumID: String
    @State private var showsAlbumScrape = false
    @State private var songIDsBeforeScrape: [String] = []
    @State private var showsRestoreConfirmation = false
    /// 「恢复文件标签」进行中 / 刚做完:显示在按钮下面,离开这一页才清掉。
    @State private var restoreProgress: TVRestoreFileTagsProgress?
    /// 恢复按钮与确认面板里的两颗按钮,值见 `RestoreFocus`。
    @FocusState private var focusedRestoreControl: String?
    @FocusState private var focusedTrackID: String?
    @Namespace private var detailFocus

    private enum RestoreFocus {
        static let button = "restore.button"
        static let cancel = "restore.cancel"
    }

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
        let hasEditedSongs = songIDs.contains { store.library.song(id: $0)?.userMetadataEditedAt != nil }
        ZStack {
            TVAmbientBackdrop(tint: album.tint, tint2: album.tint2, strength: 0.55)
            TVColor.bg.opacity(0.34).ignoresSafeArea()
            HStack(alignment: .top, spacing: 72) {
                VStack(alignment: .leading, spacing: 22) {
                    TVArtworkView(album: album, size: 300, radius: 18)
                    Text(album.title)
                        .tvFont(.pageTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(album.artist)
                        .tvFont(.body)
                        .foregroundStyle(TVColor.textMuted)
                        .lineLimit(2)
                    Text(verbatim: Self.summary(album: album, songs: songs))
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint)
                    HStack(spacing: 14) {
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
                    }
                    .disabled(songIDs.isEmpty)
                    // 串烧与补全并成第二排(所以这一栏比艺人页宽),放不下(长语言)才各占一行。
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) { secondaryActions(songIDs) }
                        VStack(alignment: .leading, spacing: 22) { secondaryActions(songIDs) }
                    }
                    // 恢复完按钮仍留着(不再有改过的歌时按下去什么也不做),免得焦点所在的按钮消失。
                    if hasEditedSongs || restoreProgress != nil {
                        restoreSection(songIDs, hasEditedSongs: hasEditedSongs)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 540, alignment: .leading)
                .focusSection()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        TVLibraryInsightBlock(
                            subject: Self.insightSubject(album: album, songs: []),
                            details: { Self.insightSubject(album: album, songs: songs, library: store.library) }
                        )
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
                            TVPagedList(tracks, alignment: .leading, spacing: 10) { _, track, onFocusChanged in
                                VStack(alignment: .leading, spacing: 10) {
                                    if let disc = track.discHeader {
                                        Text(verbatim: "\(String(localized: "disc_label")) \(disc)")
                                            .tvFont(.eyebrow, weight: .semibold)
                                            .foregroundStyle(TVColor.textMuted)
                                            .padding(.top, track.id == tracks.first?.id ? 0 : 18)
                                            .padding(.leading, 22)
                                    }
                                    trackRow(track, albumArtist: album.artist, onFocusChanged: onFocusChanged) {
                                        guard store.play(track.song, in: songIDs) else { return }
                                        finishPlayback(songID: track.id)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, TVScrollEdgeFade.bottom)
                }
                .tvScrollEdgeFade()
                .focusSection()
            }
            .padding(.horizontal, 100)
            .padding(.vertical, 72)
            // 确认面板盖在上面时底下不接焦点,方向键出不了面板。
            .disabled(showsRestoreConfirmation)

            if showsRestoreConfirmation {
                restoreConfirmation(songIDs)
                    .transition(.opacity)
                    .zIndex(5)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showsRestoreConfirmation)
        .focusScope(detailFocus)
        .onExitCommand {
            if showsRestoreConfirmation {
                closeRestoreConfirmation()
            } else {
                dismiss()
            }
        }
        .task {
            // 从播放页回来:焦点放回刚播的那首。覆盖层呈现完、曲目行建出来之前设的焦点会被丢掉,
            // 没落上就隔一会儿再设(机器忙的时候呈现会慢),最多等一秒多。
            guard let initialFocusSongID else { return }
            for attempt in 0..<4 {
                try? await Task.sleep(nanoseconds: attempt == 0 ? 350_000_000 : 300_000_000)
                guard !Task.isCancelled else { return }
                focusedTrackID = initialFocusSongID
                try? await Task.sleep(nanoseconds: 150_000_000)
                if focusedTrackID == initialFocusSongID { break }
            }
            #if DEBUG
            plog("TV album detail reopened focus=\(focusedTrackID == initialFocusSongID ? "track" : "other")")
            #endif
        }
        #if DEBUG
        .task {
            // 截图用:TV_SCREEN=albumDetail TV_RESTORE_DEBUG=1 先把第一首的标题改掉并打上「用户编辑」
            // (相当于刮削改过),弹出确认面板,6 秒后真的恢复;日志 `TV restore debug` 前后对比标题。
            guard ProcessInfo.processInfo.environment["TV_RESTORE_DEBUG"] == "1",
                  let songID = store.songIDs(forAlbum: albumID).first,
                  var edited = store.library.song(id: songID) else { return }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let original = edited.title
            edited.title = original + " · Scraped"
            edited.userMetadataEditedAt = Date()
            store.library.replaceSong(edited)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            showsRestoreConfirmation = true
            focusedRestoreControl = RestoreFocus.cancel
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            restoreFileTags(store.songIDs(forAlbum: albumID))
            while restoreProgress?.isFinished != true {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            let after = store.library.song(id: songID)
            plog("TV restore debug before=\(original) edited=\(edited.title) after=\(after?.title ?? "-")"
                 + " stamp=\(after?.userMetadataEditedAt == nil ? "cleared" : "kept")")
        }
        #endif
        .fullScreenCover(isPresented: $showsAlbumScrape, onDismiss: followAlbumAfterScrape) {
            TVAlbumScrapeView(albumID: albumID).environment(store)
        }
        .accessibilityIdentifier("tv.album.detail")
    }

    @ViewBuilder
    private func secondaryActions(_ songIDs: [String]) -> some View {
        TVMedleyButton(songIDs: songIDs) { finishPlayback(songID: nil) }
        TVPillButton(
            title: String(localized: "tv_scrape_album_title"),
            systemImage: "wand.and.stars",
            action: {
                songIDsBeforeScrape = songIDs
                showsAlbumScrape = true
            }
        )
        .disabled(songIDs.isEmpty)
    }

    // MARK: 恢复文件标签

    private func restoreSection(_ songIDs: [String], hasEditedSongs: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            TVPillButton(
                title: String(localized: "restore_file_tags"),
                systemImage: "arrow.uturn.backward",
                focusBinding: $focusedRestoreControl,
                focusID: RestoreFocus.button,
                action: {
                    guard hasEditedSongs, restoreProgress?.isFinished != false else { return }
                    showsRestoreConfirmation = true
                    Task { @MainActor in
                        await Task.yield()
                        focusedRestoreControl = RestoreFocus.cancel
                    }
                }
            )
            .accessibilityIdentifier("tv.album.restoreFileTags")
            if let restoreProgress {
                Text(verbatim: Self.restoreStatus(restoreProgress))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textFaint)
                    .monospacedDigit()
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

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
            focusedRestoreControl = RestoreFocus.button
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
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(TVColor.brand)
                        .opacity(isCurrent ? 1 : 0)
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
        .contextMenu { TVSongLikeMenuItem(store: store, songID: song.id) }
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
        finishPlayback(songID: nil)
    }

    private func finishPlayback(songID: String?) {
        openPlayer(albumID, songID)
        dismiss()
    }
}

/// 歌曲行 — 封面 + 标题/艺术家 + 时长。
struct TVSongRow: View {
    @Environment(TVStore.self) private var store
    let song: TVSong
    var reason: String? = nil
    var queueSongIDs: [String]? = nil
    var action: () -> Void = {}
    /// 长列表分页要知道焦点走到哪一行了,见 `TVPagedSongIDList`。
    var onFocusChanged: (Bool) -> Void = { _ in }

    var body: some View {
        let album = store.albumOf(song)
        TVFocusButton(radius: TVRadius.card, scale: 1.02, lift: 0,
                      action: {
                          // 列表内点歌保持该列表为队列,并沿用当前随机开关;
                          // 没给列表时按可见曲库顺序续播。
                          if let queueSongIDs {
                              guard store.play(song, in: queueSongIDs) else { return }
                          } else { store.play(song) }
                          action()
                      },
                      onFocusChanged: onFocusChanged) { focused in
            HStack(spacing: 18) {
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", songID: song.id, coverRef: song.coverRef,
                              tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: 64, radius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    if let reason {
                        Label(reason, systemImage: "sparkles")
                            .tvFont(.meta, weight: .semibold)
                            .foregroundStyle(TVColor.brand)
                            .lineLimit(1)
                    }
                    Text(song.title).tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text).lineLimit(2)
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
        .contextMenu { TVSongLikeMenuItem(store: store, songID: song.id) }
    }
}

/// 歌曲行长按菜单里的喜欢 / 取消喜欢,与播放页封面菜单同一种写法。
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
    }
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

    @Environment(TVStore.self) private var store

    var body: some View {
        TVPagedList(songIDs, id: \.self, alignment: alignment, spacing: spacing) { _, songID, onFocusChanged in
            if let song = store.song(songID) {
                TVSongRow(
                    song: song,
                    queueSongIDs: songIDs,
                    action: action,
                    onFocusChanged: onFocusChanged
                )
            }
        }
    }
}
#endif
