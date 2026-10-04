import SwiftUI
import PrimuseKit

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

    @Environment(\.pmHeightClass) private var heightClass
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:工具栏按钮带上标题。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge

    @AppStorage(ArtistLayoutMode.storageKey)
    private var layoutModeRaw = ArtistLayoutMode.grid.rawValue

    @AppStorage(ArtistBrowseMode.storageKey)
    private var browseModeRaw = ArtistBrowseMode.allArtists.rawValue

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
        suppliedArtists ?? library.browsableArtists(browseMode)
    }

    /// 一个艺人都没有才给整页的空状态。资料库切到「专辑艺术家」后列表可能是空的
    /// （歌都没有专辑信息），那时页面照常显示，工具栏上还能切回来。
    private var hasNoArtists: Bool {
        browsesLibrary ? library.visibleArtists.isEmpty && library.visibleAlbumArtists.isEmpty : artists.isEmpty
    }

    /// 列表空了而且不是搜索 / 只看喜欢造成的。
    private var showsEmptyBrowseList: Bool {
        browsesLibrary && artists.isEmpty
    }

    /// 只看喜欢的艺人。有喜欢的艺人时才给这个开关。
    @State private var showsLikedOnly = false
    private let favorites = LibraryFavoritesStore.shared

    private var showsLikedFilter: Bool { showsLikedOnly || favorites.hasLikedArtists }

    private var filteredArtists: [Artist] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = showsLikedOnly ? favorites.likedArtists(in: artists) : artists
        guard !q.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func artistMenu(_ artist: Artist) -> some View {
        LibraryCollectionMenuItems(
            isLiked: favorites.isLiked(artistNamed: artist.name),
            toggleLike: { favorites.toggle(artistNamed: artist.name) },
            songs: { library.songs(forArtist: artist.id) },
            player: player
        )
    }

    private func displayName(for artist: Artist) -> String {
        let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "unknown_artist") : name
    }

    var body: some View {
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
            }
        #else
        iosBody
        #endif
    }

    @ViewBuilder
    private var emptyBrowseList: some View {
        ContentUnavailableView(
            "no_artists",
            systemImage: browseMode.systemImage,
            description: Text("no_artists_desc")
        )
    }

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
            .overlay {
                if showsEmptyBrowseList {
                    emptyBrowseList
                } else if filteredArtists.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            #if os(iOS)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("filter_artists_placeholder")
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ArtistDisplayMenu(
                        modeRaw: $browseModeRaw,
                        offersBrowseModes: browsesLibrary,
                        showsLikedOnly: $showsLikedOnly,
                        offersLikedFilter: showsLikedFilter,
                        titled: verticalBarEdge != nil
                    )
                }
            }
            #endif
        }
    }

    /// 圆形头像网格。`.adaptive` 让 iPhone 落到两列、iPad 自然摊开更多列,
    /// 和专辑网格用的是同一套断点 —— 手机横屏下的下限也一起收到 100。
    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: heightClass.value(150, compact: 100)), spacing: 16)]
    }

    private var artistGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: heightClass.value(24, compact: 16)) {
                ForEach(filteredArtists) { artist in
                    NavigationLink(value: artist) {
                        artistGridCell(artist)
                    }
                    .buttonStyle(.pmPressable)
                    .contextMenu { artistMenu(artist) }
                    .accessibilityAction(named: Text(favorites.isLiked(artistNamed: artist.name) ? "library_favorite_unlike" : "library_favorite_like")) {
                        favorites.toggle(artistNamed: artist.name)
                    }
                    .mediaZoomSource(.artist, id: artist.id)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .pmExtendsUnderVerticalBar()
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

    private var artistList: some View {
        List(filteredArtists) { artist in
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

                        Text("\(artist.albumCount) \(String(localized: "albums_count")) · \(artist.songCount) \(String(localized: "songs_count"))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contextMenu { artistMenu(artist) }
            .mediaZoomSource(.artist, id: artist.id)
        }
        .listStyle(.plain)
        .pmExtendsUnderVerticalBar()
    }

    #if os(macOS)
    /// 当前选中的艺术家 (nil → 取过滤后列表第一个), 驱动右侧详情。
    @State private var selectedArtistID: String?

    private var selectedArtist: Artist? {
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
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(PMColor.bg.ignoresSafeArea())
        }
    }

    private var artistListPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("tab_artists")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Spacer(minLength: 0)
                    if browsesLibrary {
                        macBrowseModeMenu
                    }
                }
                HStack(spacing: 8) {
                    artistFilterField
                    if showsLikedFilter {
                        LibraryLikedFilterButton(isOn: $showsLikedOnly)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if showsEmptyBrowseList {
                emptyBrowseList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredArtists.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredArtists) { artist in
                            artistRow(artist)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PMColor.bg)
    }

    private var macBrowseModeMenu: some View {
        Menu {
            Picker("artist_browse_mode", selection: $browseModeRaw) {
                ForEach(ArtistBrowseMode.allCases, id: \.self) { mode in
                    Text(String(localized: mode.titleKey)).tag(mode.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(String(localized: browseMode.titleKey))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(PMColor.text)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
            .overlay {
                RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("artist_browse_mode"))
        .accessibilityIdentifier("artistBrowseMode.menu")
    }

    private var artistFilterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
            TextField("", text: $searchText, prompt: Text("filter_artists_placeholder"))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(PMColor.text)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.s))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.s, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func artistRow(_ artist: Artist) -> some View {
        let isSelected = selectedArtist?.id == artist.id
        return Button {
            selectedArtistID = artist.id
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
                    Text("\(artist.songCount) \(String(localized: "songs_count"))")
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
        .buttonStyle(.plain)
        .contextMenu { artistMenu(artist) }
    }
    #endif
}

#if os(iOS)
/// 艺术家页右上角唯一的一颗「显示」：列哪些人（全部 / 专辑艺术家）、网格还是列表，
/// 以及有收藏的艺人时「只看收藏的」。
/// 工具栏条目跑在自己的视图图里，只收 Binding 与 `@AppStorage`，不读环境。
private struct ArtistDisplayMenu: View {
    @Binding var modeRaw: String
    let offersBrowseModes: Bool
    @Binding var showsLikedOnly: Bool
    let offersLikedFilter: Bool
    /// 系统竖栏里带上标题(收进溢出菜单时要用),其它时候仍是纯图标。
    var titled = false

    @AppStorage(ArtistLayoutMode.storageKey)
    private var layoutModeRaw = ArtistLayoutMode.grid.rawValue

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
