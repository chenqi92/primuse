import SwiftUI
import PrimuseKit

#if DEBUG
@MainActor
enum ArtistListRenderDiagnostics {
    static var didBuildLabel: ((String) -> Void)?
}
#endif

/// iPhone / iPad 上艺术家页的版式。Mac 走 master-detail，不参与这个开关。
enum ArtistLayoutMode: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var titleKey: String.LocalizationValue {
        switch self {
        case .grid: return "artist_layout_grid"
        case .list: return "artist_layout_list"
        }
    }

    var icon: String {
        switch self {
        case .grid: return "circle.grid.2x2"
        case .list: return "list.bullet"
        }
    }

    static let storageKey = "artist.layoutMode"
}

extension ArtistBrowseMode {
    var titleKey: String.LocalizationValue {
        switch self {
        case .allArtists: return "artist_browse_all"
        case .albumArtists: return "artist_browse_album_artists"
        }
    }

    var systemImage: String {
        switch self {
        case .allArtists: return "music.mic"
        case .albumArtists: return "square.stack"
        }
    }
}

struct ArtistListView: View {
    /// nil：资料库里的艺术家页，按「全部艺术家 / 专辑艺术家」设置取曲库的列表。
    private let suppliedArtists: [Artist]?
    private let intelligentRecommendationIDs: Set<String>
    @State private var searchText: String = ""
    @State private var showsMerge = false
    @State private var showsMergeSuggestions = false
    private var mergeService: ArtistMergeService { .shared }

    @Environment(\.pmHeightClass) private var heightClass
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicIntelligenceService.self) private var intelligence
    /// 右上角菜单里点了「补全缺少的简介」。
    @State private var requestsIntroFill = false
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:工具栏按钮带上标题。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @Environment(\.librarySectionRailActive) private var sectionRailActive

    @AppStorage(ArtistLayoutMode.storageKey)
    private var layoutModeRaw = ArtistLayoutMode.grid.rawValue

    @AppStorage(ArtistBrowseMode.storageKey)
    private var browseModeRaw = ArtistBrowseMode.allArtists.rawValue

    /// 专辑艺术家里不列只有单曲、EP 的人(本机偏好); 读一下, 改了列表跟着变。
    @AppStorage(AlbumArtistReleaseFilter.storageKey)
    private var hidesSingleOnlyAlbumArtists = false

    /// 搜索结果之类给定的一批艺人。
    init(artists: [Artist], intelligentRecommendationIDs: Set<String> = []) {
        suppliedArtists = artists
        self.intelligentRecommendationIDs = intelligentRecommendationIDs
    }

    /// 资料库里的艺术家页。
    init() {
        suppliedArtists = nil
        intelligentRecommendationIDs = []
    }

    private var layoutMode: ArtistLayoutMode {
        ArtistLayoutMode(rawValue: layoutModeRaw) ?? .grid
    }

    private var browsesLibrary: Bool { suppliedArtists == nil }

    private var browseMode: ArtistBrowseMode { .resolved(browseModeRaw) }

    private var artists: [Artist] {
        _ = hidesSingleOnlyAlbumArtists
        #if os(iOS)
        if browsesLibrary { return currentOrder?.items ?? [] }
        #endif
        return suppliedArtists ?? library.browsableArtists(browseMode)
    }

    #if os(iOS)
    /// 资料库艺人页按读音排好的顺序（后台排，和专辑页、电视艺人墙同一套：「Beyond」和「北京」挨着）。
    /// 换了列法或曲库变了，新的排好之前先显示上一份。
    @State private var orderedArtists: ArtistBrowseOrdered?

    private var orderRequest: ArtistBrowseOrderRequest? {
        // 目录路径(P3)不用内存里排好的那一份。
        guard browsesLibrary, iosCatalogKey == nil else { return nil }
        return ArtistBrowseOrderRequest(mode: browseMode, artists: library.browsableArtists(browseMode))
    }

    // MARK: Catalog path (P3)

    @State private var catalogArtists = ArtistCatalogList()

    /// 资料库「全部艺术家」、不只看喜欢、目录可读时读目录(带页内搜索);读失败的那组条件改走内存。
    private var iosCatalogKey: ArtistCatalogKey? {
        guard browsesLibrary, browseMode == .allArtists, !showsLikedOnly,
              library.catalogHost?.revisions.isReadable == true else { return nil }
        let key = ArtistCatalogKey(search: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
        return catalogArtists.failedKey == key ? nil : key
    }

    /// 正在显示的目录列表;条件刚变时先留着上一份。
    private var iosCatalogModel: LibraryListModel<LibraryArtistBrowseQuery>? {
        iosCatalogKey == nil ? nil : catalogArtists.model
    }

    private func updateIOSCatalogArtists() {
        guard let key = iosCatalogKey, let host = library.catalogHost else {
            catalogArtists.reset()
            return
        }
        catalogArtists.update(key, host: host, query: LibraryArtistBrowseQuery(
            unknownArtistName: String(localized: "unknown_artist"), search: key.search
        ))
    }

    private var currentOrder: ArtistBrowseOrdered? {
        guard let orderRequest else { return nil }
        return ArtistBrowseOrderCache.shared.entry(for: orderRequest) ?? orderedArtists
    }

    /// 右缘字母条。搜索和只看喜欢（按喜欢的先后排）时收起。
    private var railModel: LibraryIndexRailModel? {
        guard searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !showsLikedOnly else { return nil }
        if iosCatalogKey != nil { return catalogArtists.railModel(offers: true) }
        return currentOrder?.railModel
    }

    private func prepareOrder(_ request: ArtistBrowseOrderRequest) async {
        if let cached = ArtistBrowseOrderCache.shared.entry(for: request) {
            orderedArtists = cached
            return
        }
        let source = library.browsableArtists(request.mode)
        guard request.matches(source) else { return }
        let unknownArtistName = String(localized: "unknown_artist")
        let worker = Task.detached(priority: .userInitiated) { () -> ArtistBrowseOrdered? in
            ArtistBrowseOrdered.prepare(request: request, source: source, unknownArtistName: unknownArtistName)
        }
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard let result, !Task.isCancelled, orderRequest == request else { return }
        ArtistBrowseOrderCache.shared.store(result)
        let previous = orderedArtists
        orderedArtists = result
        Task.detached(priority: .utility) { withExtendedLifetime(previous) {} }
    }
    #endif

    /// 资料库艺人页第一次排序还没排好。
    private var isPreparingOrder: Bool {
        #if os(iOS)
        if iosCatalogKey != nil { return iosCatalogModel == nil }
        return browsesLibrary && currentOrder == nil
        #else
        return false
        #endif
    }

    /// 一个艺人都没有才给整页的空状态。资料库切到「专辑艺术家」后列表可能是空的
    /// （歌都没有专辑信息），那时页面照常显示，工具栏上还能切回来。
    private var hasNoArtists: Bool {
        browsesLibrary ? library.visibleArtists.isEmpty && library.visibleAlbumArtists.isEmpty : artists.isEmpty
    }

    /// 列表空了而且不是搜索 / 只看喜欢造成的。
    private var showsEmptyBrowseList: Bool {
        #if os(iOS)
        if iosCatalogKey != nil {
            // 目录路径:整页没有艺人(搜索之前)。目录计数还没数出来时先不出空状态。
            let total = LibraryHubCatalogCountsModel.shared(for: library)?.readableCounts?.artists ?? 1
            return !isPreparingOrder && total == 0
        }
        #endif
        return browsesLibrary && !isPreparingOrder && artists.isEmpty
    }

    /// 页面上显示的艺人数。
    private var displayedArtistCount: Int {
        #if os(iOS)
        if iosCatalogKey != nil { return iosCatalogModel?.count ?? 0 }
        #endif
        return filteredArtists.count
    }

    /// 「补全缺少的简介」要的艺人:目录路径下按同样的条件从内存曲库筛(P3 删内存曲库前改成按键分批取)。
    private func batchFillArtists() -> [Artist] {
        #if os(iOS)
        if let key = iosCatalogKey {
            // 和内存路径同一份艺人(「全部艺术家」),按同样的名字条件筛。
            let all = library.browsableArtists(.allArtists)
            return key.search.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(key.search) }
        }
        #endif
        return filteredArtists
    }

    /// 只看喜欢的艺人。有喜欢的艺人时才给这个开关。
    @State private var showsLikedOnly = false
    private let favorites = LibraryFavoritesStore.shared

    private var showsLikedFilter: Bool { showsLikedOnly || favorites.hasLikedArtists }

    /// 资料库里的艺术家页才给:和详情页「添加简介」同一个条件。
    private var offersIntroFill: Bool {
        browsesLibrary && (
            intelligence.isLibraryInsightAvailable
                || intelligence.libraryInsightNeedsRemoteConsent
                || intelligence.shouldExposeRemoteConfiguration
        )
    }

    private var filteredArtists: [Artist] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = showsLikedOnly ? favorites.likedArtists(in: artists) : artists
        guard !q.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func artistMenu(_ artist: Artist) -> some View {
        LibraryCollectionMenuItems(
            isLiked: favorites.isLiked(artist),
            toggleLike: { favorites.toggle(artistNamed: artist.name) },
            songs: { library.songs(forArtist: artist.id) },
            player: player,
            recentItem: .init(kind: .artist, entityID: artist.id)
        )
    }

    private func displayName(for artist: Artist) -> String {
        #if DEBUG
        ArtistListRenderDiagnostics.didBuildLabel?(artist.id)
        #endif
        let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "unknown_artist") : name
    }

    var body: some View {
        Group {
            #if os(macOS)
            macBody
                .onReceive(NotificationCenter.default.publisher(for: .primuseDetailOpenArtist)) { note in
                    guard let artist = note.object as? Artist else { return }
                    if !artists.contains(where: { $0.id == artist.id }) {
                        // 只在合辑、feat. 里出现的人不在「专辑艺术家」里，反过来「群星」只在那里:
                        // 换到列着他的那一种再选中。
                        guard browsesLibrary else { return }
                        let other: ArtistBrowseMode = browseMode == .allArtists ? .albumArtists : .allArtists
                        guard library.browsableArtists(other).contains(where: { $0.id == artist.id }) else { return }
                        browseModeRaw = other.rawValue
                    }
                    searchText = ""
                    selectedArtistID = artist.id
                    selectedCatalogArtist = artist
                }
                .task(id: usesCatalogArtistList) { updateCatalogArtistList() }
                .libraryInsightBatchFill(kind: .artist, request: $requestsIntroFill) {
                    filteredArtists.map(LibraryInsightBatchItem.artist)
                }
            #else
            iosBody
                .libraryInsightBatchFill(kind: .artist, request: $requestsIntroFill) {
                    batchFillArtists().map(LibraryInsightBatchItem.artist)
                }
                .task(id: orderRequest) {
                    guard let orderRequest else { return }
                    await prepareOrder(orderRequest)
                }
                .task(id: iosCatalogKey) { updateIOSCatalogArtists() }
            #endif
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if mergeService.isRunning || mergeService.outcome != nil {
                Button { showsMerge = true } label: {
                    HStack {
                        if mergeService.isRunning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: mergeService.outcome?.wasCancelled == true ? "stop.circle" : "checkmark.circle")
                        }
                        Text("artist_merge_title")
                        Text(mergeService.canonicalName).lineLimit(1).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(mergeService.progress.done)/\(mergeService.progress.total)").monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.bar)
                .accessibilityIdentifier("artistMerge.status")
            }
        }
        .sheet(isPresented: $showsMerge) { ArtistMergeView() }
        .sheet(isPresented: $showsMergeSuggestions) {
            ArtistMergeSuggestionsSheet { showsMergeSuggestions = false }
        }
    }

    #if os(iOS)
    private func artistDisplayMenu(titled: Bool) -> some View {
        ArtistDisplayMenu(
            modeRaw: $browseModeRaw,
            offersBrowseModes: browsesLibrary,
            showsLikedOnly: $showsLikedOnly,
            offersLikedFilter: showsLikedFilter,
            offersIntroFill: offersIntroFill,
            fillIntros: { requestsIntroFill = true },
            titled: titled
        )
    }
    #endif

    private var mergeMenu: some View {
        Menu {
            mergeMenuItems
        } label: { Label("artist_merge_title", systemImage: "person.2") }
    }

    @ViewBuilder
    private var mergeMenuItems: some View {
        if mergeService.isRunning || mergeService.outcome != nil {
            Button("artist_merge_title") { showsMerge = true }
            if mergeService.isRunning {
                Button("cancel", role: .destructive) { mergeService.cancel() }
                    .disabled(mergeService.cancellationRequested)
            }
        } else {
            Button("artist_merge_select") { showsMerge = true }
            Button("artist_merge_suggestions") { showsMergeSuggestions = true }
        }
    }

    @ViewBuilder
    private var emptyBrowseList: some View {
        ContentUnavailableView(
            "no_artists",
            systemImage: browseMode.systemImage,
            description: Text("no_artists_desc")
        )
    }

    #if os(iOS)
    @ViewBuilder
    private var iosBody: some View {
        if hasNoArtists {
            EmptyStateView(
                titleKey: "no_artists",
                descriptionKey: "no_artists_desc",
                systemImage: "music.mic"
            )
        } else {
            Group {
                switch layoutMode {
                case .grid: artistGrid.pmAppearFade()
                case .list: artistList.pmAppearFade()
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if browsesLibrary {
                    LibraryInsightBatchStatusCard(
                        kind: .artist,
                        outerPadding: EdgeInsets(top: 6, leading: 16, bottom: 4, trailing: 16)
                    )
                }
            }
            .overlay {
                if isPreparingOrder {
                    ProgressView()
                } else if showsEmptyBrowseList {
                    emptyBrowseList
                } else if displayedArtistCount == 0 {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            #if os(iOS)
            .libraryPageFind(text: $searchText, prompt: "filter_artists_placeholder")
            .toolbar {
                if sectionRailActive {
                    // 资料库分类在 Duo 竖栏里时合并与显示选项并成一个「⋯」,竖栏中间留给分类。
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            mergeMenu
                            artistDisplayMenu(titled: true)
                        } label: {
                            PMToolbarItemLabel("a11y_more_actions", systemImage: "ellipsis", titled: true)
                        }
                        .accessibilityIdentifier("artists.more")
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) { mergeMenu }
                    ToolbarItem(placement: .topBarTrailing) {
                        artistDisplayMenu(titled: verticalBarEdge != nil)
                    }
                }
            }
            // 极简模式根页没有导航栏：艺人数与列法、显示选项排成页头。
            .minimalPageHeader {
                HStack(spacing: 4) {
                    MinimalHeaderCount(
                        text: Self.artistCountText(displayedArtistCount)
                    )
                    Spacer(minLength: 8)
                    MinimalHeaderActions {
                        MinimalPageFindButton()
                        mergeMenu
                        ArtistDisplayMenu(
                            modeRaw: $browseModeRaw,
                            offersBrowseModes: browsesLibrary,
                            showsLikedOnly: $showsLikedOnly,
                            offersLikedFilter: showsLikedFilter,
                            offersIntroFill: offersIntroFill,
                            fillIntros: { requestsIntroFill = true }
                        )
                    }
                }
            }
            #endif
        }
    }

    private static func artistCountText(_ count: Int) -> String {
        LibraryCountText.artists(count)
    }

    /// 圆形头像网格：和专辑网格同一套断点（iPhone 两列、iPad 摊开更多列，手机横屏下限收到 100），
    /// 按行摆成懒加载栈。资料库里的艺人页右缘有字母条：拖动跳到那个字母，卡片里是这一段的前几位头像。
    private var artistGrid: some View {
        let artists = iosCatalogKey == nil ? filteredArtists : []
        let catalog = iosCatalogModel
        let count = iosCatalogKey == nil ? artists.count : (catalog?.count ?? 0)
        let minimumWidth = heightClass.value(150, compact: 100)
        return LibraryIndexedScrollView(
            model: railModel,
            columns: { LibraryIndexedGridColumns.count(rowWidth: $0, minimumWidth: minimumWidth, spacing: 16) },
            extendsUnderVerticalBar: true,
            countText: Self.artistCountText,
            preview: { entry in
                LibraryIndexArtistStack(artists: catalog.map { model in
                    (0..<min(entry.count, 3)).compactMap { model.item(at: entry.target + $0) }
                } ?? entry.previewItems(in: artists))
            }
        ) { layout in
            LazyVStack(alignment: .leading, spacing: heightClass.value(24, compact: 16)) {
                ForEach(0..<layout.rowCount(itemCount: count), id: \.self) { @Sendable row in
                    LazyItemCell {
                        HStack(alignment: .top, spacing: layout.columnSpacing) {
                            if let catalog {
                                // 目录路径(P3):按下标取,还没物化到的格子先画占位。
                                ForEach(Array(layout.items(inRow: row, itemCount: count)), id: \.self) { index in
                                    if let artist = catalog.item(at: index) {
                                        artistGridItem(artist)
                                            .frame(width: layout.cellWidth)
                                    } else {
                                        ArtistGridCellPlaceholder()
                                            .frame(width: layout.cellWidth)
                                    }
                                }
                            } else {
                                ForEach(artists[layout.items(inRow: row, itemCount: count)]) { artist in
                                    artistGridItem(artist)
                                        .frame(width: layout.cellWidth)
                                }
                            }
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.leading, layout.leadingPadding)
            .padding(.trailing, layout.trailingPadding)
            .padding(.vertical, 18)
        }
        .pmExtendsUnderVerticalBar()
    }

    private func artistGridItem(_ artist: Artist) -> some View {
        NavigationLink(value: artist) {
            artistGridCell(artist)
        }
        .buttonStyle(.pmPressable)
        .contextMenu { artistMenu(artist) }
        .accessibilityAction(named: Text(favorites.isLiked(artist) ? "library_favorite_unlike" : "library_favorite_like")) {
            favorites.toggle(artistNamed: artist.name)
        }
        .mediaZoomSource(.artist, id: artist.id)
    }

    private func artistGridCell(_ artist: Artist) -> some View {
        VStack(spacing: 10) {
            ArtistArtworkView(artist: artist, cornerRadius: 0)
                .clipShape(Circle())
                // 浅色照片在浅色背景上会糊掉边界,补一圈发丝线。
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
                }
                .searchRecommendationOverlay(isRecommended: intelligentRecommendationIDs.contains(artist.id), iconOnly: true)

            Text(displayName(for: artist))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
        }
    }

    /// 列表版式也是懒加载栈（系统 List 没法按行跳转、也报不出露出了哪几行），右缘同样有字母条。
    private var artistList: some View {
        let artists = iosCatalogKey == nil ? filteredArtists : []
        let catalog = iosCatalogModel
        let count = iosCatalogKey == nil ? artists.count : (catalog?.count ?? 0)
        return LibraryIndexedScrollView(
            model: railModel,
            countText: Self.artistCountText,
            preview: { entry in
                LibraryIndexArtistStack(artists: catalog.map { model in
                    (0..<min(entry.count, 3)).compactMap { model.item(at: entry.target + $0) }
                } ?? entry.previewItems(in: artists))
            }
        ) { layout in
            LazyVStack(spacing: 0) {
                // 一位歌手一格（分隔线在格子里）：懒加载栈按行号直接找到远处的目标。
                ForEach(0..<count, id: \.self) { @Sendable row in
                    LazyItemCell {
                        if let catalog {
                            // 目录路径(P3):还没物化到的行先画占位。
                            if let artist = catalog.item(at: row) {
                                artistListRow(artist, trailingPadding: layout.trailingPadding)
                            } else {
                                ArtistListRowPlaceholder(trailingPadding: layout.trailingPadding)
                            }
                        } else {
                            artistListRow(artists[row], trailingPadding: layout.trailingPadding)
                        }
                    }
                }
            }
            .scrollTargetLayout()
            .padding(.vertical, 4)
        }
    }

    private func artistListRow(_ artist: Artist, trailingPadding: CGFloat) -> some View {
        NavigationLink(value: artist) {
            HStack(spacing: 12) {
                ArtistArtworkView(
                    artist: artist,
                    size: 44,
                    cornerRadius: 22
                )
                .searchRecommendationOverlay(isRecommended: intelligentRecommendationIDs.contains(artist.id), iconOnly: true, inset: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: artist))
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text("\(LibraryCountText.albums(artist.albumCount)) · \(LibraryCountText.songs(artist.songCount))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.leading, 16)
            .padding(.trailing, trailingPadding)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(ArtistListRowButtonStyle())
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 16 + 44 + 12)
                .accessibilityHidden(true)
        }
        .contextMenu { artistMenu(artist) }
        .accessibilityAction(named: Text(favorites.isLiked(artist) ? "library_favorite_unlike" : "library_favorite_like")) {
            favorites.toggle(artistNamed: artist.name)
        }
        .mediaZoomSource(.artist, id: artist.id)
    }

    #endif

    #if os(macOS)
    /// 当前选中的艺术家 (nil → 取过滤后列表第一个), 驱动右侧详情。
    @State private var selectedArtistID: String?
    /// 资料库「全部艺术家」列法、不在查找也不只看喜欢时,左栏从曲库目录按页取(P2a)。
    @State private var catalogArtistList: LibraryListModel<LibraryArtistListQuery>?
    /// 目录列表里点选(或从别处打开)的那位。目录列表只物化可见区附近,选中的那位单独留着。
    @State private var selectedCatalogArtist: Artist?

    /// 目录的艺人顺序与 `visibleArtists` 一致(名字本地化排序、同名按首次出现),计数按可见歌曲算;
    /// 「专辑艺术家」列法、查找、只看喜欢目录还给不出一样的结果,走内存模型。
    private var usesCatalogArtistList: Bool {
        browsesLibrary
            && browseMode == .allArtists
            && !showsLikedOnly
            && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && library.catalogHost?.revisions.isReadable == true
    }

    /// 目录那一份已经取到行号(与第一页),而且没有读错。读错时这一页照旧用内存模型。
    private var showsCatalogArtistList: Bool {
        guard usesCatalogArtistList, let model = catalogArtistList,
              !model.isLoading, model.lastError == nil else { return false }
        return model.count == 0 || model.item(at: 0) != nil
    }

    private func updateCatalogArtistList() {
        guard usesCatalogArtistList, let host = library.catalogHost else {
            catalogArtistList?.deactivate()
            catalogArtistList = nil
            return
        }
        guard catalogArtistList == nil else { return }
        let model = host.artistList(visibleOnly: true)
        model.activate()
        catalogArtistList = model
    }

    private var selectedArtist: Artist? {
        if showsCatalogArtistList, let model = catalogArtistList {
            if let id = selectedArtistID, let artist = selectedCatalogArtist, artist.id == id {
                return artist
            }
            return model.item(at: 0)
        }
        if let id = selectedArtistID,
           let match = filteredArtists.first(where: { $0.id == id }) {
            return match
        }
        return filteredArtists.first
    }

    /// 设计稿 LIB-03: 左侧 280pt 艺术家列表 + 右侧选中艺术家的详情, 一体的
    /// master-detail, 而不是之前的大 hero + 卡片网格。
    @ViewBuilder
    private var macBody: some View {
        if hasNoArtists {
            ContentUnavailableView(
                "no_artists",
                systemImage: "music.mic",
                description: Text("no_artists_desc")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PMColor.bg.ignoresSafeArea())
        } else {
            HStack(spacing: 0) {
                artistListPane
                    .frame(width: 280)
                    .accessibilityElement(children: .contain)

                Rectangle()
                    .fill(PMColor.divider)
                    .frame(width: 0.5)

                Group {
                    if let artist = selectedArtist {
                        // 只在重建后淡入: 详情页一次 body 要过滤整库专辑,
                        // 不能把它拉进交叉淡入的事务里。
                        ArtistDetailView(artist: artist)
                            .pmAppearFade()
                            .id(artist.id)
                    } else if showsEmptyBrowseList || (showsCatalogArtistList && catalogArtistList?.count == 0) {
                        emptyBrowseList
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
            }
            .background(PMColor.bg.ignoresSafeArea())
        }
    }

    private var artistListPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("tab_artists")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("artistList.title")
                HStack(spacing: 8) {
                    if offersIntroFill {
                        LibraryInsightBatchMacButton { requestsIntroFill = true }
                    }
                    macMergeMenu
                    Spacer(minLength: 0)
                    if browsesLibrary {
                        macBrowseModeMenu
                    }
                }
                HStack(spacing: 8) {
                    MacLibraryFindField(text: $searchText, prompt: "filter_artists_placeholder", width: nil)
                    if showsLikedFilter {
                        LibraryLikedFilterButton(isOn: $showsLikedOnly)
                    }
                }
            }
            // 280 宽的左栏: 合并、列法、查找、只看喜欢同一档 26 高(`MacControlTier.toolbar`)。
            .macControlTier(.toolbar)
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if browsesLibrary {
                LibraryInsightBatchStatusCard(
                    kind: .artist,
                    outerPadding: EdgeInsets(top: 0, leading: 12, bottom: 10, trailing: 12)
                )
            }

            if showsCatalogArtistList, let model = catalogArtistList {
                if model.count == 0 {
                    Spacer(minLength: 0)
                        .accessibilityHidden(true)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 1) {
                            ForEach(0..<model.count, id: \.self) { index in
                                if let artist = model.item(at: index) {
                                    artistRow(artist)
                                } else {
                                    // 那一页还没取到:与一行同高的空位(36 头像 + 上下 6)。
                                    Color.clear
                                        .frame(height: 48)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.visible, axes: .vertical)
                    .accessibilityIdentifier("artistList.scroll")
                }
            } else if showsEmptyBrowseList || filteredArtists.isEmpty {
                Spacer(minLength: 0)
                    .accessibilityHidden(true)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredArtists) { artist in
                            artistRow(artist)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.visible, axes: .vertical)
                .accessibilityIdentifier("artistList.scroll")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PMColor.bg)
    }

    private var macMergeMenu: some View {
        Menu {
            mergeMenuItems
        } label: {
            macMenuLabel {
                Image(systemName: "person.2")
                    .imageScale(.small)
            }
        }
        .macControlMenuStyle()
        .help(Text("artist_merge_title"))
        .accessibilityLabel(Text("artist_merge_title"))
        .accessibilityIdentifier("artistMerge.menu")
    }

    private var macBrowseModeMenu: some View {
        Menu {
            Picker("artist_browse_mode", selection: $browseModeRaw) {
                ForEach(ArtistBrowseMode.allCases, id: \.self) { mode in
                    Text(String(localized: mode.titleKey)).tag(mode.rawValue)
                }
            }
            .pickerStyle(.inline)
            if browseMode == .albumArtists {
                Toggle("artist_browse_hide_singles_only", isOn: $hidesSingleOnlyAlbumArtists)
            }
        } label: {
            macMenuLabel {
                Text(String(localized: browseMode.titleKey))
            }
        }
        .macControlMenuStyle()
        .help(Text("artist_browse_mode"))
        .accessibilityLabel(Text("artist_browse_mode"))
        .accessibilityValue(Text(String(localized: browseMode.titleKey)))
        .accessibilityIdentifier("artistBrowseMode.menu")
    }

    private func macMenuLabel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 5) {
            content()
            Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .bold))
                .opacity(0.7)
        }
        .macControlChrome()
    }

    private func artistRow(_ artist: Artist) -> some View {
        let isSelected = selectedArtist?.id == artist.id
        return PMScrollingButton {
            selectedArtistID = artist.id
            selectedCatalogArtist = artist
        } label: {
            HStack(spacing: 10) {
                ArtistArtworkView(
                    artist: artist,
                    size: 36,
                    cornerRadius: 18
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName(for: artist))
                        .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(PMColor.text)
                        .lineLimit(1)
                    Text(LibraryCountText.songs(artist.songCount))
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .pmRowBackground(selected: isSelected)
            .contentShape(Rectangle())
        }
        .contextMenu { artistMenu(artist) }
    }
    #endif
}

#if os(iOS)
/// 艺术家页右上角唯一的一颗「显示」：列哪些人（全部 / 专辑艺术家）、网格还是列表，
/// 有收藏的艺人时「只看收藏的」，以及补全缺少的简介。
/// 工具栏条目跑在自己的视图图里，只收 Binding、闭包与 `@AppStorage`，不读环境。
private struct ArtistDisplayMenu: View {
    @Binding var modeRaw: String
    let offersBrowseModes: Bool
    @Binding var showsLikedOnly: Bool
    let offersLikedFilter: Bool
    let offersIntroFill: Bool
    let fillIntros: () -> Void
    /// 系统竖栏里带上标题(收进溢出菜单时要用),其它时候仍是纯图标。
    var titled = false

    @AppStorage(ArtistLayoutMode.storageKey)
    private var layoutModeRaw = ArtistLayoutMode.grid.rawValue
    @AppStorage(AlbumArtistReleaseFilter.storageKey)
    private var hidesSingleOnlyAlbumArtists = false

    private var mode: ArtistBrowseMode { .resolved(modeRaw) }

    /// 列表被收窄了（只列专辑艺术家、只看收藏）时图标实心。
    private var isNarrowed: Bool {
        (offersBrowseModes && mode != .allArtists) || showsLikedOnly
    }

    var body: some View {
        Menu {
            if offersBrowseModes {
                Picker("artist_browse_mode", selection: $modeRaw) {
                    ForEach(ArtistBrowseMode.allCases, id: \.self) { option in
                        Label(String(localized: option.titleKey), systemImage: option.systemImage)
                            .tag(option.rawValue)
                    }
                }
                .pickerStyle(.inline)
                if mode == .albumArtists {
                    Section {
                        Toggle(isOn: $hidesSingleOnlyAlbumArtists) {
                            Label("artist_browse_hide_singles_only", systemImage: "square.stack")
                        }
                    }
                }
            }

            Picker("artist_layout", selection: $layoutModeRaw) {
                ForEach(ArtistLayoutMode.allCases) { option in
                    Label(String(localized: option.titleKey), systemImage: option.icon)
                        .tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)

            if offersLikedFilter {
                Section {
                    Toggle(isOn: $showsLikedOnly) {
                        Label("library_favorite_filter", systemImage: "heart")
                    }
                }
            }

            if offersIntroFill {
                Section {
                    LibraryInsightBatchMenuItem(start: fillIntros)
                }
            }
        } label: {
            PMToolbarItemLabel(
                "songs_display_mode",
                systemImage: isNarrowed
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle",
                titled: titled
            )
        }
        .accessibilityLabel(Text("songs_display_mode"))
        .accessibilityIdentifier("artistBrowseMode.menu")
    }
}
#endif

#if os(iOS)
/// 列表版式的一行按下时整行垫一层淡底，和系统列表一样。
private struct ArtistListRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.08 : 0))
    }
}

/// 资料库艺人页一次排序的输入：列法 + 曲库给的那份数组。曲库每次发布都换一份新数组，
/// 所以数组按存储地址与个数认（同 `AlbumGridOrderRequest`）；排好的结果留着那份数组，
/// 它的地址在被留着期间不会分给别的数组。
struct ArtistBrowseOrderRequest: Hashable, Sendable {
    let mode: ArtistBrowseMode
    private let sourceAddress: Int
    private let sourceCount: Int

    init(mode: ArtistBrowseMode, artists: [Artist]) {
        self.mode = mode
        sourceCount = artists.count
        sourceAddress = artists.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.map { Int(bitPattern: $0) } ?? 0
        }
    }

    func matches(_ artists: [Artist]) -> Bool {
        self == ArtistBrowseOrderRequest(mode: mode, artists: artists)
    }
}

/// 按读音排好的艺人，连同字母条。
struct ArtistBrowseOrdered: Sendable {
    let request: ArtistBrowseOrderRequest
    let source: [Artist]
    let items: [Artist]
    let railModel: LibraryIndexRailModel?

    /// 在后台调用。「未知艺术家」排最后。
    static func prepare(
        request: ArtistBrowseOrderRequest, source: [Artist], unknownArtistName: String
    ) -> ArtistBrowseOrdered? {
        let layout = LibraryArtistBrowseLayoutBuilder.layout(artists: source, unknownArtistName: unknownArtistName)
        guard !Task.isCancelled else { return nil }
        let model = LibraryIndexRailModel(sections: layout.sections)
        return ArtistBrowseOrdered(
            request: request, source: source, items: layout.items,
            railModel: layout.items.count >= 24 && model.isUseful ? model : nil
        )
    }
}

/// 最近一次排好的结果：换页回来、iPad 侧栏和资料库里同时开着都不必重排。
/// 不是 Observable：结果由各页自己的 @State 交付。
@MainActor
final class ArtistBrowseOrderCache {
    static let shared = ArtistBrowseOrderCache()
    private var latest: ArtistBrowseOrdered?

    func entry(for request: ArtistBrowseOrderRequest) -> ArtistBrowseOrdered? {
        latest?.request == request ? latest : nil
    }

    func store(_ entry: ArtistBrowseOrdered) {
        let previous = latest
        latest = entry
        Task.detached(priority: .utility) { withExtendedLifetime(previous) {} }
    }
}
#endif
