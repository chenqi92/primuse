import SwiftUI
import PrimuseKit

struct AlbumGridView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicIntelligenceService.self) private var intelligence
    @State private var albumFilter = ""
    @AppStorage("library.albumReleaseFilter") private var releaseCategory = ""
    /// 右上角菜单里点了「补全缺少的简介」。
    @State private var requestsIntroFill = false
    /// 只看喜欢的专辑。有喜欢的专辑时才给这个开关。
    @State private var showsLikedOnly = false
    @AppStorage("library.hideSingleSongAlbums") private var hidesSingleSongAlbums = false
    @AppStorage(AlbumGridOrder.storageKey) private var albumOrderRawValue = AlbumGridOrder.defaultOrder.rawValue
    /// 后台准备好的筛选结果。
    @State private var displayedAlbums: AlbumGridFilteredAlbums?
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

    private var filterRequest: AlbumGridFilterRequest {
        AlbumGridFilterRequest(
            order: orderRequest, query: albumFilter.trimmingCharacters(in: .whitespacesAndNewlines),
            category: AlbumReleaseCategory(rawValue: releaseCategory), likedOnly: showsLikedOnly,
            hidesSingleSongAlbums: hidesSingleSongAlbums,
            favoritesRevision: showsLikedOnly ? favorites.revision : 0,
            categoryRevision: releaseCategory.isEmpty ? 0 : library.releaseCategoryRevision,
            membershipRevision: releaseCategory.isEmpty ? 0 : library.releaseCategoryMembershipRevision,
            overrideRevision: releaseCategory.isEmpty ? 0 : AlbumReleaseCategoryStore.shared.revision
        )
    }

    private var filteredAlbums: [Album] {
        AlbumGridFilterCache.shared.entry(for: filterRequest)?.albums ?? displayedAlbums?.albums ?? []
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
        let ordered = await AlbumGridOrderCache.shared.prepare(
            request.order, source: source, songs: songs, unknownArtistName: unknownArtistName
        )
        guard !Task.isCancelled, filterRequest == request else { return }
        let worker = Task.detached(priority: .userInitiated) {
            request.filter(
                ordered.albums, categories: categories, overrides: overrides,
                favorites: favoritesSnapshot, unknownArtistName: unknownArtistName,
                isCancelled: { Task.isCancelled }
            ).map { AlbumGridFilteredAlbums(request: request, source: source, albums: $0) }
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

    /// 手机横屏只剩两百多点高, 150 的下限会排成四列大卡片、一屏只看得到一行多。
    /// 下限降到 100 就能排到六列, 首屏露出一行半以上。
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: heightClass.value(150, compact: 100)), spacing: 16)]
    }
    #endif

    var body: some View {
        if library.visibleAlbums.isEmpty {
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
                .task(id: filterRequest) { await prepareAlbums(filterRequest) }
                .libraryInsightBatchFill(kind: .album, request: $requestsIntroFill) {
                    filteredAlbums.map(LibraryInsightBatchItem.album)
                }
            #else
            iosGrid(filteredAlbums, isPreparing: isPreparing)
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
                            text: "\(filteredAlbums.count.formatted()) \(String(localized: "albums_count"))"
                        )
                        Spacer(minLength: 8)
                        MinimalHeaderActions {
                            MinimalPageFindButton()
                            AlbumReleaseCategoryPicker(selection: $releaseCategory)
                            AlbumGridDisplayMenu(
                                order: albumOrderBinding,
                                showsLikedOnly: $showsLikedOnly,
                                hidesSingleSongAlbums: $hidesSingleSongAlbums,
                                offersLikedFilter: showsLikedFilter,
                                offersIntroFill: offersIntroFill,
                                fillIntros: { requestsIntroFill = true }
                            )
                        }
                    }
                }
                .task(id: filterRequest) { await prepareAlbums(filterRequest) }
                .libraryInsightBatchFill(kind: .album, request: $requestsIntroFill) {
                    filteredAlbums.map(LibraryInsightBatchItem.album)
                }
            #endif
        }
    }

    #if !os(macOS)
    private func iosGrid(_ albums: [Album], isPreparing: Bool) -> some View {
        ScrollView {
            if isPreparing {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else if albums.isEmpty {
                ContentUnavailableView.search(text: albumFilter)
            }
            LazyVGrid(columns: columns, spacing: heightClass.value(20, compact: 14)) {
                ForEach(albums) { album in
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
            }
            .padding()
            // iPhone Duo 竖栏：最右一列封面伸进竖栏，系统的玻璃胶囊浮在上面。
            .pmCoversExtendUnderVerticalBar()
        }
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
        return GeometryReader { proxy in
            let metrics = MacAlbumGridMetrics(viewportWidth: proxy.size.width)
            VStack(spacing: 18) {
                albumsHeader(displayedCount: albums.count)
                    .padding(.top, 24)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 18) {
                        LibraryInsightBatchStatusCard(
                            kind: .album,
                            outerPadding: EdgeInsets(top: 0, leading: PMSpace.xxxl, bottom: 0, trailing: PMSpace.xxxl)
                        )

                        if isPreparing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, minHeight: 280)
                        } else if albums.isEmpty {
                            ContentUnavailableView.search(text: albumFilter)
                                .frame(maxWidth: .infinity, minHeight: 280)
                                .padding(.horizontal, PMSpace.xxxl)
                        } else if albumViewMode == .grid {
                            LazyVGrid(
                                columns: metrics.columns,
                                alignment: .leading,
                                spacing: 24
                            ) {
                                ForEach(albums) { album in
                                    Button {
                                        openAlbum(album)
                                    } label: {
                                        macAlbumTile(album, artworkSize: metrics.artworkSize)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { albumMenu(album) }
                                    .pmHoverLift()
                                }
                            }
                            .padding(.horizontal, PMSpace.xxxl)
                            .pmAppearFade()
                        } else {
                            LazyVStack(spacing: 1) {
                                ForEach(albums) { album in
                                    Button {
                                        openAlbum(album)
                                    } label: {
                                        macAlbumListRow(album)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu { albumMenu(album) }
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

    private func albumsHeader(displayedCount: Int) -> some View {
        HStack(alignment: .bottom) {
            Text("tab_albums")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(PMColor.text)

            Spacer()

            HStack(spacing: 10) {
                Text(verbatim: String(
                    format: String(localized: "album_grid_count_sort_format"),
                    displayedCount,
                    library.visibleAlbums.count,
                    albumOrder.label
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textFaint)
                albumFilterField
                if showsLikedFilter {
                    LibraryLikedFilterButton(isOn: $showsLikedOnly)
                }
                if offersIntroFill {
                    LibraryInsightBatchMacButton { requestsIntroFill = true }
                }
                albumViewSwitcher
                AlbumReleaseCategoryPicker(selection: $releaseCategory)
                    .controlSize(.small)
                albumSortMenu
            }
        }
        .padding(.horizontal, PMSpace.xxxl)
    }

    private var albumFilterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
            TextField("", text: $albumFilter, prompt: Text("filter_albums_placeholder"))
                .textFieldStyle(.plain)
                .accessibilityLabel(Text("filter_albums_placeholder"))
                .font(.system(size: 12))
                .foregroundStyle(PMColor.text)
                .frame(width: 150)
            if !albumFilter.isEmpty {
                Button { albumFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                }
                .buttonStyle(.plain)
                .help(Text("clear"))
                .accessibilityLabel(Text("clear"))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private var albumViewSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(AlbumViewMode.allCases, id: \.self) { mode in
                Button {
                    albumViewMode = mode
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(albumViewMode == mode ? PMColor.text : PMColor.textMuted)
                        .frame(width: 26, height: 22)
                        .background(albumViewMode == mode ? PMColor.bgElev : .clear, in: .rect(cornerRadius: 5))
                        .pmAnimation(.hover, value: albumViewMode == mode)
                }
                .buttonStyle(.plain)
                .help(Text(mode.label))
                .accessibilityLabel(Text(mode.label))
            }
        }
        .padding(2)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
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
                Toggle(isOn: $hidesSingleSongAlbums) {
                    Label("album_filter_hide_single_song", systemImage: "music.note")
                }
                .accessibilityIdentifier("albumGrid.hideSingleSongAlbums")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: hidesSingleSongAlbums ? "line.3.horizontal.decrease.circle.fill" : "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(verbatim: albumOrder.label)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(PMColor.text)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
            .overlay {
                RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
        guard let browseOrder = order.browseOrder else {
            let byTitle = LibraryAlbumBrowseLayoutBuilder.layout(
                albums: albums, order: .title, unknownArtistName: unknownArtistName
            ).items
            return byTitle.indices.sorted { lhs, rhs in
                let lhsCount = byTitle[lhs].songCount
                let rhsCount = byTitle[rhs].songCount
                return lhsCount != rhsCount ? lhsCount > rhsCount : lhs < rhs
            }.map { byTitle[$0] }
        }
        return LibraryAlbumBrowseLayoutBuilder.layout(
            albums: albums, order: browseOrder, songs: songs, unknownArtistName: unknownArtistName
        ).items
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
            return AlbumGridOrderedAlbums(
                request: request, source: source,
                albums: AlbumGridOrder.sorted(source, order: request.order, songs: songs, unknownArtistName: unknownArtistName)
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
    let favoritesRevision: Int
    let categoryRevision: UInt64
    let membershipRevision: UInt64
    let overrideRevision: Int

    func filter(
        _ albums: [Album], categories: AlbumReleaseMetadataIndex?,
        overrides: [String: Set<AlbumReleaseCategory>], favorites: LibraryFavoriteLedger,
        unknownArtistName: String, isCancelled: () -> Bool = { false }
    ) -> [Album]? {
        guard !isCancelled() else { return nil }
        guard category != nil || likedOnly || hidesSingleSongAlbums || !query.isEmpty else { return albums }
        var result: [Album] = []
        for index in albums.indices {
            if index.isMultiple(of: 256), isCancelled() { return nil }
            let album = albums[index]
            if hidesSingleSongAlbums && album.songCount == 1 { continue }
            if let category,
               !(overrides[album.id] ?? categories?.categories(albumID: album.id) ?? [.album]).contains(category) { continue }
            if likedOnly && !favorites.isLiked(LibraryFavoriteKey.id(
                kind: .album, albumTitle: album.title, artistName: album.artistName ?? "",
                unknownArtistName: unknownArtistName
            )) { continue }
            if !query.isEmpty && !album.title.localizedCaseInsensitiveContains(query)
                && !(album.artistName?.localizedCaseInsensitiveContains(query) ?? false)
                && !(album.year.map(String.init)?.contains(query) ?? false) { continue }
            result.append(album)
        }
        return isCancelled() ? nil : result
    }
}

struct AlbumGridFilteredAlbums: Sendable {
    let request: AlbumGridFilterRequest
    let source: [Album]
    let albums: [Album]
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
    @Binding var hidesSingleSongAlbums: Bool
    let offersLikedFilter: Bool
    let offersIntroFill: Bool
    let fillIntros: () -> Void

    var body: some View {
        Menu {
            Picker("sort_by", selection: $order) {
                ForEach(AlbumGridOrder.menuCases, id: \.self) { option in
                    Label(option.label, systemImage: option.systemImage)
                        .tag(option)
                }
            }
            .pickerStyle(.inline)

            Section {
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
                systemImage: showsLikedOnly || hidesSingleSongAlbums
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
