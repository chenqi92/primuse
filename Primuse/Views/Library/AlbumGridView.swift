import SwiftUI
import PrimuseKit

struct AlbumGridView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @State private var albumFilter = ""
    /// 只看喜欢的专辑。有喜欢的专辑时才给这个开关。
    @State private var showsLikedOnly = false
    private let favorites = LibraryFavoritesStore.shared

    private var showsLikedFilter: Bool { showsLikedOnly || favorites.hasLikedAlbums }

    private func albumMenu(_ album: Album) -> some View {
        LibraryCollectionMenuItems(
            isLiked: favorites.isLiked(album),
            toggleLike: { favorites.toggle(album) },
            songs: { library.songs(forAlbum: album.id) },
            player: player
        )
    }

    private var baseAlbums: [Album] {
        showsLikedOnly ? favorites.likedAlbums(in: library.visibleAlbums) : library.visibleAlbums
    }

    private var filteredAlbums: [Album] {
        let query = albumFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = baseAlbums
        guard !query.isEmpty else { return base }
        return base.filter { album in
            album.title.localizedCaseInsensitiveContains(query)
                || (album.artistName?.localizedCaseInsensitiveContains(query) ?? false)
                || album.year.map(String.init)?.contains(query) == true
        }
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
                          library.visibleAlbums.contains(where: { $0.id == album.id }) else { return }
                    albumFilter = ""
                    openAlbum(album)
                }
            #else
            ScrollView {
                if filteredAlbums.isEmpty {
                    ContentUnavailableView.search(text: albumFilter)
                }
                LazyVGrid(columns: columns, spacing: heightClass.value(20, compact: 14)) {
                    ForEach(filteredAlbums) { album in
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
            }
            .pmExtendsUnderVerticalBar()
            .searchable(
                text: $albumFilter,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("filter_albums_placeholder")
            )
            .toolbar {
                if showsLikedFilter {
                    ToolbarItem(placement: .topBarTrailing) {
                        LibraryLikedFilterButton(isOn: $showsLikedOnly)
                    }
                }
            }
            #endif
        }
    }

    #if os(macOS)
    @State private var albumSort: AlbumSortOrder = .year
    @State private var albumViewMode: AlbumViewMode = .grid
    @State private var selectedAlbumID: String?

    private enum AlbumViewMode: String, CaseIterable, Hashable {
        case grid, list

        var icon: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .list: return "list.bullet"
            }
        }
    }

    /// 设计稿 LIB-02 的排序维度: 发行年(默认) / 标题 / 艺术家 / 曲目数。
    private enum AlbumSortOrder: CaseIterable, Hashable {
        case year, title, artist, songCount

        var label: String {
            switch self {
            case .year: return String(localized: "year_label")
            case .title: return String(localized: "title_label")
            case .artist: return String(localized: "artist_label")
            case .songCount: return String(localized: "album_sort_song_count")
            }
        }
    }

    /// 排序结果按「同一份专辑数组 + 同一档排序 + 同一个筛选词」缓存。body 在扫描
    /// 入库、悬停、打开专辑时都会重算, 以前每次都把全部专辑用 localizedCompare
    /// 重排一遍。
    @State private var macSortCache = MacAlbumSortCache()

    private var sortedAlbums: [Album] {
        let source = library.visibleAlbums
        // 只看喜欢时，喜欢的增减也要让缓存失效。
        let likedToken = showsLikedOnly ? favorites.revision : -1
        if let cached = macSortCache.value(source: source, sort: albumSort, filter: albumFilter, likedToken: likedToken) {
            return cached
        }
        let sorted: [Album]
        switch albumSort {
        case .title:
            // visibleAlbums 已经按标题 localizedCompare 排好, 筛选保持顺序。
            // 只看喜欢时底子是按喜欢先后排的, 要重排。
            sorted = showsLikedOnly
                ? filteredAlbums.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
                : filteredAlbums
        case .artist:
            sorted = filteredAlbums.sorted {
                ($0.artistName ?? "").localizedCompare($1.artistName ?? "") == .orderedAscending
            }
        case .year:
            sorted = filteredAlbums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .songCount:
            sorted = filteredAlbums.sorted { $0.songCount > $1.songCount }
        }
        macSortCache.store(sorted, source: source, sort: albumSort, filter: albumFilter, likedToken: likedToken)
        return sorted
    }

    /// 不是 Observable: 在 body 里写它不会引起重绘。持有输入数组本身, 所以它的
    /// 存储地址在缓存期间不会被别的数组复用, 可以拿地址判断是不是同一份。
    private final class MacAlbumSortCache {
        private var source: [Album] = []
        private var sort: AlbumSortOrder?
        private var filter = ""
        private var likedToken = -1
        private var value: [Album] = []

        func value(source: [Album], sort: AlbumSortOrder, filter: String, likedToken: Int) -> [Album]? {
            guard self.sort == sort, self.filter == filter, self.likedToken == likedToken,
                  Self.sameStorage(self.source, source) else { return nil }
            return value
        }

        func store(_ value: [Album], source: [Album], sort: AlbumSortOrder, filter: String, likedToken: Int) {
            self.source = source
            self.sort = sort
            self.filter = filter
            self.likedToken = likedToken
            self.value = value
        }

        private static func sameStorage(_ lhs: [Album], _ rhs: [Album]) -> Bool {
            guard lhs.count == rhs.count else { return false }
            guard !lhs.isEmpty else { return true }
            return lhs.withUnsafeBufferPointer { l in
                rhs.withUnsafeBufferPointer { r in l.baseAddress == r.baseAddress }
            }
        }
    }

    /// 设计稿 LIB-02: 不再用带大封面的 hero header (那是全部歌曲/歌单的样式),
    /// 而是左上角专辑标题 + 右上排序, 下面五列封面网格。
    @ViewBuilder
    private var macGrid: some View {
        if let selectedAlbum {
            AlbumDetailView(
                album: selectedAlbum,
                onMacInlineBack: closeAlbum
            )
            // 淡入挂在 .id 里面: 换一张专辑时身份跟着重建, 修饰符的状态才会跟着重置。
            .pmAppearFade()
            .id(selectedAlbum.id)
            .pmFadeTransition()
        } else {
            macAlbumOverview
                .pmFadeTransition()
        }
    }

    private var selectedAlbum: Album? {
        guard let selectedAlbumID else { return nil }
        return library.visibleAlbums.first { $0.id == selectedAlbumID }
    }

    private var macAlbumOverview: some View {
        let albums = sortedAlbums
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                albumsHeader(displayedCount: albums.count)

                if albums.isEmpty {
                    ContentUnavailableView.search(text: albumFilter)
                        .frame(maxWidth: .infinity, minHeight: 280)
                        .padding(.horizontal, PMSpace.xxxl)
                } else if albumViewMode == .grid {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: 24, alignment: .top)],
                        alignment: .leading,
                        spacing: 24
                    ) {
                        ForEach(albums) { album in
                            Button {
                                openAlbum(album)
                            } label: {
                                GeometryReader { proxy in
                                    macAlbumTile(album, artworkSize: proxy.size.width)
                                }
                                .aspectRatio(0.74, contentMode: .fit)
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
            .padding(.top, 24)
            .padding(.bottom, 112)
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
                    albumSort.label
                ))
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textFaint)
                albumFilterField
                if showsLikedFilter {
                    LibraryLikedFilterButton(isOn: $showsLikedOnly)
                }
                albumViewSwitcher
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
                .help(Text(mode == .grid ? "grid_view" : "list_view"))
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
            Picker("sort_by", selection: $albumSort) {
                ForEach(AlbumSortOrder.allCases, id: \.self) { order in
                    Text(verbatim: order.label).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 10, weight: .semibold))
                Text(verbatim: albumSort.label)
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
                .lineLimit(1)
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
