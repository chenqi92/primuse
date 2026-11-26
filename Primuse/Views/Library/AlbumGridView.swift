import SwiftUI
import PrimuseKit

struct AlbumGridView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @State private var albumFilter = ""
    @AppStorage("library.albumReleaseFilter") private var releaseCategory = ""
    /// 右上角菜单里点了「补全缺少的简介」。
    @State private var requestsIntroFill = false
    /// 只看喜欢的专辑。有喜欢的专辑时才给这个开关。
    @State private var showsLikedOnly = false
    /// 只看离线可用（含本机、已下载与完整缓存）的专辑。
    @State private var showsOfflineOnly = false
    @State private var offlineAlbumIDs: Set<String> = []
    @State private var offlineAlbumFilterRevision = 0
    @AppStorage("library.hideSingleSongAlbums") private var hidesSingleSongAlbums = false
    @AppStorage(AlbumGridOrder.storageKey) private var albumOrderRawValue = AlbumGridOrder.defaultOrder.rawValue
    /// 后台准备好的筛选结果。
    @State private var displayedAlbums: AlbumGridFilteredAlbums?
    /// 目录路径的列表(P3)。
    @State private var catalogList = AlbumGridCatalogList()
    private let favorites = LibraryFavoritesStore.shared

    private var showsLikedFilter: Bool { showsLikedOnly || favorites.hasLikedAlbums }

    /// 和详情页「添加简介」同一个条件:有 AI 可问、只差授权,或至少能去设置里配一个。
    private var offersIntroFill: Bool {
        intelligence.isLibraryInsightAvailable
            || intelligence.libraryInsightNeedsRemoteConsent
            || intelligence.shouldExposeRemoteConfiguration
    }

    private var albumOrder: AlbumGridOrder { .resolved(albumOrderRawValue) }

    private var albumOrderBinding: Binding<AlbumGridOrder> {
        Binding(get: { albumOrder }, set: { albumOrderRawValue = $0.rawValue })
    }

    @ViewBuilder
    private func albumMenu(_ album: Album) -> some View {
        AlbumReleaseCategoryMenu(album: album)
        LibraryCollectionMenuItems(
            isLiked: favorites.isLiked(album),
            toggleLike: { favorites.toggle(album) },
            songs: { library.songs(forAlbum: album.id) },
            player: player,
            donation: .album(id: album.id)
        )
    }

    private var orderRequest: AlbumGridOrderRequest {
        AlbumGridOrderRequest(order: albumOrder, albums: library.visibleAlbums)
    }

    private var effectiveOfflineOnly: Bool {
        showsOfflineOnly || sourceManager.isGlobalOfflineMode
    }

    private var offlineFilterTaskKey: String {
        guard effectiveOfflineOnly else { return "off" }
        return "on-\(library.visibleSongCollectionRevision)-\(sourceManager.offlineAudioSnapshotRevision)-\(sourcesStore.sources.count)"
    }

    private func refreshOfflineAlbumIDs() async {
        guard effectiveOfflineOnly else {
            if !offlineAlbumIDs.isEmpty {
                offlineAlbumIDs = []
                offlineAlbumFilterRevision &+= 1
            }
            return
        }
        let localSourceIDs = SourceManager.localDeviceSourceIDs(in: sourcesStore.sources)
        let songs = library.visibleSongs
        let playableIDs = await sourceManager.offlinePlayableSongIDs(in: songs, localSourceIDs: localSourceIDs)
        guard !Task.isCancelled else { return }
        var matched = Set<String>()
        for album in library.visibleAlbums {
            if library.songs(forAlbum: album.id).contains(where: { playableIDs.contains($0.id) }) {
                matched.insert(album.id)
            }
        }
        if offlineAlbumIDs != matched {
            offlineAlbumIDs = matched
            offlineAlbumFilterRevision &+= 1
        }
    }

    private var filterRequest: AlbumGridFilterRequest {
        AlbumGridFilterRequest(
            order: orderRequest, query: albumFilter.trimmingCharacters(in: .whitespacesAndNewlines),
            category: AlbumReleaseCategory(rawValue: releaseCategory), likedOnly: showsLikedOnly,
            hidesSingleSongAlbums: hidesSingleSongAlbums,
            offlineOnly: effectiveOfflineOnly,
            offlineRevision: effectiveOfflineOnly ? offlineAlbumFilterRevision : 0,
            favoritesRevision: showsLikedOnly ? favorites.revision : 0,
            categoryRevision: releaseCategory.isEmpty ? 0 : library.releaseCategoryRevision,
            membershipRevision: releaseCategory.isEmpty ? 0 : library.releaseCategoryMembershipRevision,
            overrideRevision: releaseCategory.isEmpty ? 0 : AlbumReleaseCategoryStore.shared.revision
        )
    }

    private var displayedResult: AlbumGridFilteredAlbums? {
        AlbumGridFilterCache.shared.entry(for: filterRequest) ?? displayedAlbums
    }

    // MARK: Catalog path (P3)

    /// 目录可读、按艺术家/标题/年份排、没有按发行类别筛时读目录;其余照旧排内存里的专辑。
    /// 读目录失败的那组条件改走内存路径。
    private var catalogKey: AlbumGridCatalogKey? {
        guard !effectiveOfflineOnly,
              library.catalogHost?.revisions.isReadable == true,
              let order = albumOrder.browseOrder, order == .artist || order == .title || order == .year,
              releaseCategory.isEmpty else { return nil }
        let key = AlbumGridCatalogKey(
            order: order, query: albumFilter.trimmingCharacters(in: .whitespacesAndNewlines),
            likedOnly: showsLikedOnly, hidesSingleSongAlbums: hidesSingleSongAlbums,
            favoritesRevision: showsLikedOnly ? favorites.revision : 0
        )
        return catalogList.failedKey == key ? nil : key
    }

    /// 正在显示的目录列表;条件刚变时先留着上一份,新的取好再换。
    private var catalogModel: LibraryListModel<LibraryAlbumBrowseQuery>? {
        catalogKey == nil ? nil : catalogList.model
    }

    private func updateCatalogList() {
        guard let key = catalogKey, let host = library.catalogHost else {
            catalogList.reset()
            return
        }
        let unknownArtistName = String(localized: "unknown_artist")
        let predicate = AlbumGridAlbumPredicate(
            query: key.query, likedOnly: key.likedOnly, hidesSingleSongAlbums: key.hidesSingleSongAlbums,
            favorites: favorites.ledger, unknownArtistName: unknownArtistName
        )
        catalogList.update(key, host: host, query: LibraryAlbumBrowseQuery(
            order: key.order, unknownArtistName: unknownArtistName,
            currentYear: Calendar.current.component(.year, from: Date()),
            predicate: predicate.isEmpty ? nil : predicate
        ))
    }

    /// 页面上显示的专辑数。
    private var displayedAlbumCount: Int {
        if catalogKey != nil { return catalogModel?.count ?? 0 }
        return filteredAlbums.count
    }

    /// 曲库里的可见专辑数(目录可读时数目录)。
    private var totalAlbumCount: Int {
        if let counts = LibraryHubCatalogCountsModel.shared(for: library)?.readableCounts { return counts.albums }
        return library.visibleAlbums.count
    }

    /// 「补全缺少的简介」要的专辑:目录路径下按同样的条件从内存曲库筛(P3 删内存曲库前改成按键分批取)。
    private func batchFillAlbums() -> [Album] {
        guard let key = catalogKey else { return filteredAlbums }
        let predicate = AlbumGridAlbumPredicate(
            query: key.query, likedOnly: key.likedOnly, hidesSingleSongAlbums: key.hidesSingleSongAlbums,
            favorites: favorites.ledger, unknownArtistName: String(localized: "unknown_artist")
        )
        return library.visibleAlbums.filter(predicate.matches)
    }

    private var filteredAlbums: [Album] {
        displayedResult?.albums ?? []
    }

    private var isPreparing: Bool {
        displayedAlbums == nil && AlbumGridFilterCache.shared.entry(for: filterRequest) == nil
    }

    private func prepareAlbums(_ request: AlbumGridFilterRequest) async {
        if let cached = AlbumGridFilterCache.shared.entry(for: request) {
            displayedAlbums = cached
            return
        }
        let source = library.visibleAlbums
        guard request.order.matches(source) else { return }
        let categories = request.category == nil ? nil : library.releaseCategorySnapshot
        let overrides: [String: Set<AlbumReleaseCategory>]
        if request.category != nil {
            guard let resolved = await library.resolvedReleaseOverrides(AlbumReleaseCategoryStore.shared.snapshot) else { return }
            overrides = resolved
        } else { overrides = [:] }
        guard !Task.isCancelled, filterRequest == request else { return }
        let favoritesSnapshot = favorites.ledger
        let songs = request.order.order == .recentlyAdded ? library.visibleSongs : []
        let unknownArtistName = String(localized: "unknown_artist")
        let allowedOfflineIDs = request.offlineOnly ? offlineAlbumIDs : nil
        let ordered = await AlbumGridOrderCache.shared.prepare(
            request.order, source: source, songs: songs, unknownArtistName: unknownArtistName
        )
        guard !Task.isCancelled, filterRequest == request else { return }
        let worker = Task.detached(priority: .userInitiated) {
            request.filter(
                ordered.albums, categories: categories, overrides: overrides,
                favorites: favoritesSnapshot, unknownArtistName: unknownArtistName,
                offlineAlbumIDs: allowedOfflineIDs,
                isCancelled: { Task.isCancelled }
            ).map { albums in
                AlbumGridFilteredAlbums(
                    request: request, source: source, albums: albums,
                    railModel: request.offersIndexRail(albumCount: albums.count)
                        ? AlbumGridFilteredAlbums.railModel(albums: albums, ordered: ordered)
                        : nil
                )
            }
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard let result, !Task.isCancelled, filterRequest == request else { return }
        AlbumGridFilterCache.shared.store(result)
        let previous = displayedAlbums
        displayedAlbums = result
        Task.detached(priority: .utility) { withExtendedLifetime(previous) {} }
    }

    #if !os(macOS)
    @Environment(\.pmHeightClass) private var heightClass

    #endif

    var body: some View {
        if totalAlbumCount == 0 {
            EmptyStateView(
                titleKey: "no_albums",
                descriptionKey: "no_albums_desc",
                systemImage: "square.stack"
            )
        } else {
            #if os(macOS)
            macGrid
                .onReceive(NotificationCenter.default.publisher(for: .primuseDetailOpenAlbum)) { note in
                    guard let album = note.object as? Album,
                          library.visibleAlbum(id: album.id) != nil else { return }
                    albumFilter = ""
                    openAlbum(album)
                }
                .task(id: offlineFilterTaskKey) {
                    await refreshOfflineAlbumIDs()
                }
                .task(id: catalogKey == nil ? filterRequest : nil) {
                    if catalogKey == nil { await prepareAlbums(filterRequest) }
                }
                .task(id: catalogKey) { updateCatalogList() }
                .libraryInsightBatchFill(kind: .album, request: $requestsIntroFill) {
                    batchFillAlbums().map(LibraryInsightBatchItem.album)
                }
            #else
            Group {
                if catalogKey != nil {
                    iosCatalogGrid(catalogModel)
                } else {
                    iosGrid(displayedResult, isPreparing: isPreparing)
                }
            }
                .safeAreaInset(edge: .top, spacing: 0) {
                    LibraryInsightBatchStatusCard(
                        kind: .album,
                        outerPadding: EdgeInsets(top: 6, leading: 16, bottom: 4, trailing: 16)
                    )
                }
                .pmExtendsUnderVerticalBar()
                .libraryPageFind(text: $albumFilter, prompt: "filter_albums_placeholder")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        AlbumReleaseCategoryPicker(selection: $releaseCategory)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        AlbumGridDisplayMenu(
                            order: albumOrderBinding,
                            showsLikedOnly: $showsLikedOnly,
                            showsOfflineOnly: $showsOfflineOnly,
                            isGlobalOfflineMode: sourceManager.isGlobalOfflineMode,
                            hidesSingleSongAlbums: $hidesSingleSongAlbums,
                            offersLikedFilter: showsLikedFilter,
                            offersIntroFill: offersIntroFill,
                            fillIntros: { requestsIntroFill = true }
                        )
                    }
                }
                // 极简模式根页没有导航栏：专辑数与排序、显示选项排成页头。
                .minimalPageHeader {
                    HStack(spacing: 4) {
                        MinimalHeaderCount(
                            text: "\(displayedAlbumCount.formatted()) \(String(localized: "albums_count"))"
                        )
                        Spacer(minLength: 8)
                        MinimalHeaderActions {
                            MinimalPageFindButton()
                            AlbumReleaseCategoryPicker(selection: $releaseCategory)
                            AlbumGridDisplayMenu(
                                order: albumOrderBinding,
                                showsLikedOnly: $showsLikedOnly,
                                showsOfflineOnly: $showsOfflineOnly,
                                isGlobalOfflineMode: sourceManager.isGlobalOfflineMode,
                                hidesSingleSongAlbums: $hidesSingleSongAlbums,
                                offersLikedFilter: showsLikedFilter,
                                offersIntroFill: offersIntroFill,
                                fillIntros: { requestsIntroFill = true }
                            )
                        }
                    }
                }
                .task(id: offlineFilterTaskKey) {
                    await refreshOfflineAlbumIDs()
                }
                .task(id: catalogKey == nil ? filterRequest : nil) {
                    if catalogKey == nil { await prepareAlbums(filterRequest) }
                }
                .task(id: catalogKey) { updateCatalogList() }
                .libraryInsightBatchFill(kind: .album, request: $requestsIntroFill) {
                    batchFillAlbums().map(LibraryInsightBatchItem.album)
                }
            #endif
        }
    }

    #if !os(macOS)
    /// 按标题、艺术家排时右缘有字母条（搜索时收起）：拖动跳到那个字母，卡片里是这一段的前几张封面。
    /// 网格按行摆：一行一个滚动目标，字母条按行号跳过去。
    private func iosGrid(_ result: AlbumGridFilteredAlbums?, isPreparing: Bool) -> some View {
        let albums = result?.albums ?? []
        // 手机横屏只剩两百多点高, 150 的下限会排成四列大卡片、一屏只看得到一行多。
        // 下限降到 100 就能排到六列, 首屏露出一行半以上。
        let minimumWidth = heightClass.value(150, compact: 100)
        let rowSpacing = heightClass.value(20, compact: 14)
        return LibraryIndexedScrollView(
            model: result?.railModel,
            columns: { LibraryIndexedGridColumns.count(rowWidth: $0, minimumWidth: minimumWidth, spacing: 16) },
            extendsUnderVerticalBar: true,
            countText: { "\($0.formatted()) \(String(localized: "albums_count"))" },
            preview: { entry in
                LibraryIndexAlbumStack(albums: entry.previewItems(in: albums))
            }
        ) { layout in
            if isPreparing {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if albums.isEmpty {
                ContentUnavailableView.search(text: albumFilter)
            }
            LazyVStack(alignment: .leading, spacing: rowSpacing) {
                // 一行一格、每格包一层：远距离跳转时前面的行不会被逐个建出来。
                ForEach(0..<layout.rowCount(itemCount: albums.count), id: \.self) { @Sendable row in
                    LazyItemCell {
                        HStack(alignment: .top, spacing: layout.columnSpacing) {
                            ForEach(albums[layout.items(inRow: row, itemCount: albums.count)]) { album in
                                albumCell(album)
                                    .frame(width: layout.cellWidth)
                            }
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 16)
            .padding(.leading, layout.leadingPadding)
            .padding(.trailing, layout.trailingPadding)
        }
    }

    /// 目录路径的网格:与 `iosGrid` 同样的行排法,还没物化到的格子先画占位。
    private func iosCatalogGrid(_ model: LibraryListModel<LibraryAlbumBrowseQuery>?) -> some View {
        let count = model?.count ?? 0
        let minimumWidth = heightClass.value(150, compact: 100)
        let rowSpacing = heightClass.value(20, compact: 14)
        let offersRail = filterRequest.offersIndexRail(albumCount: count)
        return LibraryIndexedScrollView(
            model: model == nil ? nil : catalogList.railModel(offers: offersRail),
            columns: { LibraryIndexedGridColumns.count(rowWidth: $0, minimumWidth: minimumWidth, spacing: 16) },
            extendsUnderVerticalBar: true,
            countText: { "\($0.formatted()) \(String(localized: "albums_count"))" },
            preview: { entry in
                LibraryIndexAlbumStack(albums: (0..<min(entry.count, 3)).compactMap { model?.item(at: entry.target + $0) })
            }
        ) { layout in
            if model == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if count == 0 {
                ContentUnavailableView.search(text: albumFilter)
            }
            LazyVStack(alignment: .leading, spacing: rowSpacing) {
                ForEach(0..<layout.rowCount(itemCount: count), id: \.self) { @Sendable row in
                    LazyItemCell {
                        HStack(alignment: .top, spacing: layout.columnSpacing) {
                            ForEach(Array(layout.items(inRow: row, itemCount: count)), id: \.self) { index in
                                if let album = model?.item(at: index) {
                                    albumCell(album)
                                        .frame(width: layout.cellWidth)
                                } else {
                                    AlbumCardPlaceholder()
                                        .frame(width: layout.cellWidth)
                                }
                            }
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 16)
            .padding(.leading, layout.leadingPadding)
            .padding(.trailing, layout.trailingPadding)
        }
    }

    private func albumCell(_ album: Album) -> some View {
        NavigationLink(value: album) {
            AlbumCardView(album: album)
        }
        .buttonStyle(.pmPressable)
        .contextMenu { albumMenu(album) }
        .accessibilityAction(named: Text(favorites.isLiked(album) ? "library_favorite_unlike" : "library_favorite_like")) {
            favorites.toggle(album)
        }
        .mediaZoomSource(.album, id: album.id)
    }
    #endif

    #if os(macOS)
    @State private var albumViewMode: AlbumViewMode = .grid
    @State private var selectedAlbumID: String?

    private enum AlbumViewMode: String, CaseIterable, Hashable {
        case grid, list

        var label: LocalizedStringKey {
            self == .grid ? "songs_view_grid" : "songs_view_list"
        }

        var icon: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .list: return "list.bullet"
            }
        }
    }

    /// 设计稿 LIB-02: 不再用带大封面的 hero header (那是全部歌曲/歌单的样式),
    /// 而是左上角专辑标题 + 右上排序, 下面五列封面网格。
    @ViewBuilder
    private var macGrid: some View {
        ZStack {
            // Keep the overview mounted: replacing its branch destroys the
            // scroll view and returns both grid and list modes to the top.
            macAlbumOverview
                .opacity(selectedAlbum == nil ? 1 : 0)
                .disabled(selectedAlbum != nil)
                .allowsHitTesting(selectedAlbum == nil)
                .accessibilityHidden(selectedAlbum != nil)

            if let selectedAlbum {
                AlbumDetailView(
                    album: selectedAlbum,
                    onMacInlineBack: closeAlbum
                )
                // 淡入挂在 .id 里面: 换一张专辑时身份跟着重建, 修饰符的状态才会跟着重置。
                .pmAppearFade()
                .id(selectedAlbum.id)
                .pmFadeTransition()
                .zIndex(1)
            }
        }
    }

    private var selectedAlbum: Album? {
        guard let selectedAlbumID else { return nil }
        return library.visibleAlbum(id: selectedAlbumID)
    }

    private var macAlbumOverview: some View {
        let albums = filteredAlbums
        // 目录路径(P3):按下标取,还没物化到的格子先画占位。
        let usesCatalog = catalogKey != nil
        let catalog = catalogModel
        let count = usesCatalog ? (catalog?.count ?? 0) : albums.count
        let preparing = usesCatalog ? catalog == nil : isPreparing
        return GeometryReader { proxy in
            let metrics = MacAlbumGridMetrics(viewportWidth: proxy.size.width)
            VStack(spacing: 18) {
                albumsHeader(displayedCount: count)
                    .padding(.top, 28)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                        LibraryInsightBatchStatusCard(
                            kind: .album,
                            outerPadding: EdgeInsets(top: 0, leading: PMSpace.xxxl, bottom: 0, trailing: PMSpace.xxxl)
                        )

                        if preparing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, minHeight: 280)
                        } else if count == 0 {
                            ContentUnavailableView.search(text: albumFilter)
                                .frame(maxWidth: .infinity, minHeight: 280)
                                .padding(.horizontal, PMSpace.xxxl)
                        } else if albumViewMode == .grid {
                            LazyVGrid(
                                columns: metrics.columns,
                                alignment: .leading,
                                spacing: 24
                            ) {
                                if usesCatalog {
                                    ForEach(0..<count, id: \.self) { index in
                                        if let album = catalog?.item(at: index) {
                                            macAlbumGridButton(album, artworkSize: metrics.artworkSize)
                                        } else {
                                            macAlbumTilePlaceholder(artworkSize: metrics.artworkSize)
                                        }
                                    }
                                } else {
                                    ForEach(albums) { album in
                                        macAlbumGridButton(album, artworkSize: metrics.artworkSize)
                                    }
                                }
                            }
                            .padding(.horizontal, PMSpace.xxxl)
                            .pmAppearFade()
                        } else {
                            LazyVStack(spacing: 1) {
                                if usesCatalog {
                                    ForEach(0..<count, id: \.self) { index in
                                        if let album = catalog?.item(at: index) {
                                            macAlbumListButton(album)
                                        } else {
                                            macAlbumListRowPlaceholder
                                        }
                                    }
                                } else {
                                    ForEach(albums) { album in
                                        macAlbumListButton(album)
                                    }
                                }
                            }
                            .padding(.horizontal, PMSpace.xxxl)
                            .pmAppearFade()
                        }
                    }
                    .padding(.bottom, 112)
                }
            }
        }
        .background(PMColor.bg.ignoresSafeArea())
    }

    private func macAlbumGridButton(_ album: Album, artworkSize: CGFloat) -> some View {
        PMScrollingButton {
            openAlbum(album)
        } label: {
            macAlbumTile(album, artworkSize: artworkSize)
        }
        .contextMenu { albumMenu(album) }
        .pmHoverLift()
    }

    private func macAlbumListButton(_ album: Album) -> some View {
        PMScrollingButton {
            openAlbum(album)
        } label: {
            macAlbumListRow(album)
        }
        .contextMenu { albumMenu(album) }
    }

    /// 还没物化到的网格格子:与 `macAlbumTile` 同样的尺寸。
    private func macAlbumTilePlaceholder(artworkSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                .fill(.quaternary)
                .frame(width: artworkSize, height: artworkSize)
            Text(verbatim: "Album title")
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(2, reservesSpace: true)
                .padding(.top, 10)
            Text(verbatim: "Artist")
                .font(.system(size: 11.5))
                .lineLimit(1)
                .padding(.top, 1)
            Text(verbatim: "2000 · 10")
                .font(.system(size: 10.5))
                .lineLimit(1)
                .padding(.top, 2)
        }
        .redacted(reason: .placeholder)
        .frame(width: artworkSize, alignment: .leading)
        .accessibilityHidden(true)
    }

    /// 还没物化到的列表行:与 `macAlbumListRow` 同样的高度。
    private var macAlbumListRowPlaceholder: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Album title").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(verbatim: "Artist · 2000").font(.system(size: 10.5)).lineLimit(1)
            }
            .redacted(reason: .placeholder)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityHidden(true)
    }

    private func openAlbum(_ album: Album) {
        pmWithAnimation(.list) {
            selectedAlbumID = album.id
        }
    }

    private func closeAlbum() {
        pmWithAnimation(.list) {
            selectedAlbumID = nil
        }
    }

    /// 和电台、播客页同一种页头: 标题一行, 右侧控件同一档 32 高(`MacControlTier.header`),
    /// 计数与排序方式写在标题下面一行 —— 原来挤在控件中间, 窄窗口里第一个被挤掉的就是它。
    private func albumsHeader(displayedCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: PMSpace.m) {
                Text("tab_albums")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: PMSpace.m)

                HStack(spacing: 8) {
                    MacLibraryFindField(text: $albumFilter, prompt: "filter_albums_placeholder", width: 180)
                    if showsLikedFilter {
                        LibraryLikedFilterButton(isOn: $showsLikedOnly)
                    }
                    if offersIntroFill {
                        LibraryInsightBatchMacButton { requestsIntroFill = true }
                    }
                    albumViewSwitcher
                    albumReleaseCategoryMenu
                    albumSortMenu
                }
            }

            Text(verbatim: String(
                format: String(localized: "album_grid_count_sort_format"),
                displayedCount,
                totalAlbumCount,
                albumOrder.label
            ))
            .font(.system(size: 13))
            .foregroundStyle(PMColor.textMuted)
            .lineLimit(1)
        }
        .padding(.horizontal, PMSpace.xxxl)
    }

    private var albumViewSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(AlbumViewMode.allCases, id: \.self) { mode in
                Button {
                    albumViewMode = mode
                } label: {
                    Image(systemName: mode.icon)
                        .macSegment(selected: albumViewMode == mode, iconOnly: true)
                }
                .buttonStyle(.plain)
                .help(Text(mode.label))
                .accessibilityLabel(Text(mode.label))
                .accessibilityAddTraits(albumViewMode == mode ? .isSelected : [])
            }
        }
        .macSegmentedContainer()
    }

    /// 「全部 / 专辑 / 单曲与 EP / 现场」: 原来是系统的弹出菜单(小号), 和旁边自绘的键高矮、样子都不一样。
    private var albumReleaseCategoryMenu: some View {
        Menu {
            Picker("release_category", selection: $releaseCategory) {
                Text("release_category_all").tag("")
                ForEach(AlbumReleaseCategory.allCases) { category in
                    Text(LocalizedStringKey(category.titleKey)).tag(category.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            MacControlMenuLabel(
                AlbumReleaseCategory(rawValue: releaseCategory).map { LocalizedStringKey($0.titleKey) }
                    ?? "release_category_all"
            )
        }
        .macControlMenuStyle()
        .help(Text("release_category"))
        .accessibilityLabel(Text("release_category"))
        .accessibilityIdentifier("albums.releaseCategory")
    }

    private var albumSortMenu: some View {
        Menu {
            Picker("sort_by", selection: albumOrderBinding) {
                ForEach(AlbumGridOrder.menuCases, id: \.self) { order in
                    Text(verbatim: order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
            Section {
                Toggle(isOn: Binding(
                    get: { effectiveOfflineOnly },
                    set: { if !sourceManager.isGlobalOfflineMode { showsOfflineOnly = $0 } }
                )) {
                    Label("filter_offline_available", systemImage: "wifi.slash")
                }
                .disabled(sourceManager.isGlobalOfflineMode)
                Toggle(isOn: $hidesSingleSongAlbums) {
                    Label("album_filter_hide_single_song", systemImage: "music.note")
                }
                .accessibilityIdentifier("albumGrid.hideSingleSongAlbums")
            }
        } label: {
            MacControlMenuLabel(
                verbatim: albumOrder.label,
                systemImage: hidesSingleSongAlbums || effectiveOfflineOnly ? "line.3.horizontal.decrease.circle.fill" : "arrow.up.arrow.down"
            )
        }
        .macControlMenuStyle()
        .help(Text("sort_by"))
    }

    private func macAlbumTile(_ album: Album, artworkSize: CGFloat) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            AlbumArtworkView(album: album, size: artworkSize, cornerRadius: PMRadius.m)
            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)

            Text(album.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(2, reservesSpace: true)
                .help(album.title)
                .padding(.top, 10)

            if let artist = album.artistName, !artist.isEmpty {
                Text(artist)
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .padding(.top, 1)
            }

            Text(verbatim: albumMetaLine(album))
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
                .lineLimit(1)
                .padding(.top, 2)
        }
        .frame(width: artworkSize, alignment: .leading)
    }

    private func macAlbumListRow(_ album: Album) -> some View {
        return HStack(spacing: 12) {
            AlbumArtworkView(album: album, size: 44, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(verbatim: [album.artistName, albumMetaLine(album)]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                    .joined(separator: " · "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .pmRowBackground(cornerRadius: 6)
        .contentShape(Rectangle())
    }

    private func albumMetaLine(_ album: Album) -> String {
        var parts: [String] = []
        if let year = album.year {
            parts.append("\(year)")
        }
        parts.append("\(album.songCount) \(String(localized: "songs_count"))")
        return parts.joined(separator: " · ")
    }
    #endif
}

/// 专辑页的排序方式。前四种与电视专辑墙同一套口径（Kit `LibraryAlbumBrowseOrder`：
/// 名字先转写成拉丁字母再排，「Beyond」和「北京」都在 B 下；按艺术家时同一位的专辑按年份
/// 从早到晚）；Mac 另有「曲目数」。
enum AlbumGridOrder: String, Hashable, Sendable {
    case artist
    case title
    case year
    case recentlyAdded
    case songCount

    static let storageKey = "primuse.library.albumSort.v1"

    #if os(macOS)
    /// 设计稿 LIB-02 的维度在前，发行年为默认。
    static let menuCases: [AlbumGridOrder] = [.year, .title, .artist, .recentlyAdded, .songCount]
    static let defaultOrder: AlbumGridOrder = .year
    #else
    static let menuCases: [AlbumGridOrder] = [.artist, .title, .year, .recentlyAdded]
    static let defaultOrder: AlbumGridOrder = .title
    #endif

    static func resolved(_ rawValue: String) -> AlbumGridOrder {
        guard let order = AlbumGridOrder(rawValue: rawValue), menuCases.contains(order) else {
            return defaultOrder
        }
        return order
    }

    var browseOrder: LibraryAlbumBrowseOrder? {
        switch self {
        case .artist: return .artist
        case .title: return .title
        case .year: return .year
        case .recentlyAdded: return .recentlyAdded
        case .songCount: return nil
        }
    }

    var label: String {
        switch self {
        case .artist: return String(localized: "artist_label")
        case .title: return String(localized: "title_label")
        case .year: return String(localized: "year_label")
        case .recentlyAdded: return String(localized: "recently_added")
        case .songCount: return String(localized: "album_sort_song_count")
        }
    }

    var systemImage: String {
        switch self {
        case .artist: return "person"
        // 不用 textformat:它在中文环境下被系统换成「格式」两个字。
        case .title: return "abc"
        case .year: return "calendar"
        case .recentlyAdded: return "clock"
        case .songCount: return "music.note.list"
        }
    }

    /// 在后台调用。「曲目数」多的在前，一样多的按标题。
    static func sorted(
        _ albums: [Album],
        order: AlbumGridOrder,
        songs: [Song],
        unknownArtistName: String
    ) -> [Album] {
        layout(albums, order: order, songs: songs, unknownArtistName: unknownArtistName).items
    }

    /// 排好的专辑连同分段（按标题、艺术家排时是首字母，按年份排时是年代，其余没有）。
    static func layout(
        _ albums: [Album],
        order: AlbumGridOrder,
        songs: [Song],
        unknownArtistName: String
    ) -> LibraryBrowseLayout<Album> {
        guard let browseOrder = order.browseOrder else {
            let byTitle = LibraryAlbumBrowseLayoutBuilder.layout(
                albums: albums, order: .title, unknownArtistName: unknownArtistName
            ).items
            let items = byTitle.indices.sorted { lhs, rhs in
                let lhsCount = byTitle[lhs].songCount
                let rhsCount = byTitle[rhs].songCount
                return lhsCount != rhsCount ? lhsCount > rhsCount : lhs < rhs
            }.map { byTitle[$0] }
            return LibraryBrowseLayout(items: items, sections: [])
        }
        return LibraryAlbumBrowseLayoutBuilder.layout(
            albums: albums, order: browseOrder, songs: songs, unknownArtistName: unknownArtistName
        )
    }
}

/// 一次排序的输入：排序方式 + 曲库的可见专辑数组本身。曲库每次发布都换一份新数组，
/// 所以数组按存储地址与个数认；排好的结果（`AlbumGridOrderedAlbums`）留着那份数组，
/// 它的地址在被留着期间不会分给别的数组。
struct AlbumGridOrderRequest: Hashable, Sendable {
    let order: AlbumGridOrder
    private let sourceAddress: Int
    private let sourceCount: Int

    init(order: AlbumGridOrder, albums: [Album]) {
        self.order = order
        sourceCount = albums.count
        sourceAddress = albums.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { Int(bitPattern: $0) } ?? 0
        }
    }

    func matches(_ albums: [Album]) -> Bool {
        self == AlbumGridOrderRequest(order: order, albums: albums)
    }
}

/// 排好的专辑，连同排它时的那份可见专辑数组（留着它，见 `AlbumGridOrderRequest`）。
struct AlbumGridOrderedAlbums: Sendable {
    let request: AlbumGridOrderRequest
    let source: [Album]
    let albums: [Album]
    /// 排序给的分段（字母或年代），和 `albums` 一一对应。
    var sections: [LibraryBrowseSection] = []
}

/// 最近一次排好的结果，各专辑页共用：换页回来、iPad 侧栏和资料库里同时开着都不必重排。
/// 不是 Observable：body 里读它不会引起重绘，结果由各页自己的 @State 交付。
@MainActor
final class AlbumGridOrderCache {
    static let shared = AlbumGridOrderCache()

    private var latest: AlbumGridOrderedAlbums?
    private var pending: (generation: Int, request: AlbumGridOrderRequest, task: Task<AlbumGridOrderedAlbums, Never>)?
    private var preparationGeneration = 0

    func prepare(
        _ request: AlbumGridOrderRequest, source: [Album], songs: [Song], unknownArtistName: String
    ) async -> AlbumGridOrderedAlbums {
        if let cached = entry(for: request) { return cached }
        if let pending, pending.request == request { return await pending.task.value }
        let previous = pending?.task
        previous?.cancel()
        preparationGeneration &+= 1
        let generation = preparationGeneration
        let task = Task.detached(priority: .userInitiated) {
            // Sorting is shared by filter requests; typing must not start another whole-library sort.
            _ = await previous?.value
            guard !Task.isCancelled else { return AlbumGridOrderedAlbums(request: request, source: source, albums: []) }
            let layout = AlbumGridOrder.layout(source, order: request.order, songs: songs, unknownArtistName: unknownArtistName)
            return AlbumGridOrderedAlbums(
                request: request, source: source, albums: layout.items, sections: layout.sections
            )
        }
        pending = (generation, request, task)
        let result = await task.value
        if pending?.generation == generation {
            pending = nil
            store(result)
        }
        return result
    }

    func entry(for request: AlbumGridOrderRequest) -> AlbumGridOrderedAlbums? {
        latest?.request == request ? latest : nil
    }

    func store(_ entry: AlbumGridOrderedAlbums) {
        let previous = latest
        latest = entry
        Task.detached(priority: .utility) { withExtendedLifetime(previous) {} }
    }
}

struct AlbumGridFilterRequest: Hashable, Sendable {
    let order: AlbumGridOrderRequest
    let query: String
    let category: AlbumReleaseCategory?
    let likedOnly: Bool
    let hidesSingleSongAlbums: Bool
    var offlineOnly: Bool = false
    var offlineRevision: Int = 0
    let favoritesRevision: Int
    let categoryRevision: UInt64
    let membershipRevision: UInt64
    let overrideRevision: Int

    /// 字母条只在按标题、艺术家排，而且不在搜索时出；专辑少于一屏半也不出。
    func offersIndexRail(albumCount: Int) -> Bool {
        #if os(iOS)
        return query.isEmpty && order.order.browseOrder?.hasLetterIndex == true && albumCount >= 24
        #else
        return false
        #endif
    }

    func filter(
        _ albums: [Album], categories: AlbumReleaseMetadataIndex?,
        overrides: [String: Set<AlbumReleaseCategory>], favorites: LibraryFavoriteLedger,
        unknownArtistName: String,
        offlineAlbumIDs: Set<String>? = nil,
        isCancelled: () -> Bool = { false }
    ) -> [Album]? {
        guard !isCancelled() else { return nil }
        let predicate = AlbumGridAlbumPredicate(
            query: query, likedOnly: likedOnly, hidesSingleSongAlbums: hidesSingleSongAlbums,
            favorites: favorites, unknownArtistName: unknownArtistName
        )
        guard category != nil || offlineAlbumIDs != nil || !predicate.isEmpty else { return albums }
        var result: [Album] = []
        for index in albums.indices {
            if index.isMultiple(of: 256), isCancelled() { return nil }
            let album = albums[index]
            if let offlineAlbumIDs, !offlineAlbumIDs.contains(album.id) { continue }
            if let category,
               !(overrides[album.id] ?? categories?.categories(albumID: album.id) ?? [.album]).contains(category) { continue }
            guard predicate.matches(album) else { continue }
            result.append(album)
        }
        return isCancelled() ? nil : result
    }
}

/// 专辑页筛选里与发行类别无关的几项(隐藏单曲专辑、只看喜欢、页内搜索)。内存路径和目录路径共用,
/// 两边筛出来的专辑一样。
struct AlbumGridAlbumPredicate: Sendable {
    let query: String
    let likedOnly: Bool
    let hidesSingleSongAlbums: Bool
    let favorites: LibraryFavoriteLedger
    let unknownArtistName: String

    var isEmpty: Bool { query.isEmpty && !likedOnly && !hidesSingleSongAlbums }

    func matches(_ album: Album) -> Bool {
        if hidesSingleSongAlbums && album.songCount == 1 { return false }
        if likedOnly && !favorites.isLiked(LibraryFavoriteKey.id(
            kind: .album, albumTitle: album.title, artistName: album.artistName ?? "",
            unknownArtistName: unknownArtistName
        )) { return false }
        if !query.isEmpty && !album.title.localizedCaseInsensitiveContains(query)
            && !(album.artistName?.localizedCaseInsensitiveContains(query) ?? false)
            && !(album.year.map(String.init)?.contains(query) ?? false) { return false }
        return true
    }
}

struct AlbumGridFilteredAlbums: Sendable {
    let request: AlbumGridFilterRequest
    let source: [Album]
    let albums: [Album]
    /// 右缘字母条（只在 iPhone、iPad 上建）。
    var railModel: LibraryIndexRailModel? = nil

    /// 在后台调用。`albums` 是 `ordered.albums` 筛掉一部分、顺序不变的结果，按 id 对回原位置重新切段。
    static func railModel(albums: [Album], ordered: AlbumGridOrderedAlbums) -> LibraryIndexRailModel? {
        let sections: [LibraryBrowseSection]
        if albums.count == ordered.albums.count {
            sections = ordered.sections
        } else {
            var kept: [Int] = []
            kept.reserveCapacity(albums.count)
            var cursor = 0
            for album in albums {
                while cursor < ordered.albums.count, ordered.albums[cursor].id != album.id { cursor += 1 }
                guard cursor < ordered.albums.count else { return nil }
                kept.append(cursor)
                cursor += 1
            }
            sections = LibraryBrowseLayout<Album>.sections(ordered.sections, keeping: kept)
        }
        let model = LibraryIndexRailModel(sections: sections)
        return model.isUseful ? model : nil
    }
}

@MainActor
final class AlbumGridFilterCache {
    static let shared = AlbumGridFilterCache()
    private var latest: AlbumGridFilteredAlbums?

    func entry(for request: AlbumGridFilterRequest) -> AlbumGridFilteredAlbums? {
        latest?.request == request ? latest : nil
    }

    func store(_ entry: AlbumGridFilteredAlbums) {
        let previous = latest
        latest = entry
        Task.detached(priority: .utility) { withExtendedLifetime(previous) {} }
    }
}

#if !os(macOS)
/// 工具栏条目跑在自己的视图图里，只收 Binding 与闭包、不读环境。
private struct AlbumGridDisplayMenu: View {
    @Binding var order: AlbumGridOrder
    @Binding var showsLikedOnly: Bool
    @Binding var showsOfflineOnly: Bool
    let isGlobalOfflineMode: Bool
    @Binding var hidesSingleSongAlbums: Bool
    let offersLikedFilter: Bool
    let offersIntroFill: Bool
    let fillIntros: () -> Void

    var body: some View {
        let effectiveOffline = showsOfflineOnly || isGlobalOfflineMode
        Menu {
            Picker("sort_by", selection: $order) {
                ForEach(AlbumGridOrder.menuCases, id: \.self) { option in
                    Label(option.label, systemImage: option.systemImage)
                        .tag(option)
                }
            }
            .pickerStyle(.inline)

            Section {
                Toggle(
                    isOn: Binding(
                        get: { effectiveOffline },
                        set: { if !isGlobalOfflineMode { showsOfflineOnly = $0 } }
                    )
                ) {
                    Label("filter_offline_available", systemImage: "wifi.slash")
                }
                .disabled(isGlobalOfflineMode)
                if offersLikedFilter {
                    Toggle(isOn: $showsLikedOnly) {
                        Label("library_favorite_filter", systemImage: "heart")
                    }
                }
                Toggle(isOn: $hidesSingleSongAlbums) {
                    Label("album_filter_hide_single_song", systemImage: "music.note")
                }
                .accessibilityIdentifier("albumGrid.hideSingleSongAlbums")
            }

            if offersIntroFill {
                Section {
                    LibraryInsightBatchMenuItem(start: fillIntros)
                }
            }
        } label: {
            Label(
                "songs_display_mode",
                systemImage: showsLikedOnly || hidesSingleSongAlbums || effectiveOffline
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityIdentifier("albumGrid.sort")
    }
}
#endif

#if os(macOS)
/// One measurement per viewport; all cards in a row share an exact square size.
struct MacAlbumGridMetrics {
    let artworkSize: CGFloat
    let columnCount: Int
    private let spacing: CGFloat = 24

    init(viewportWidth: CGFloat) {
        let available = max(0, viewportWidth - 2 * PMSpace.xxxl)
        columnCount = max(1, Int((available + 24) / (150 + 24)))
        artworkSize = max(0, (available - CGFloat(columnCount - 1) * 24) / CGFloat(columnCount))
    }

    var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(artworkSize), spacing: spacing, alignment: .top),
              count: columnCount)
    }
}
#endif
