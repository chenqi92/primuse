import PrimuseKit
import SwiftUI

// 流派页与流派详情页(从 `LibraryView.swift` 搬出,6c 单元 4 U6a 在这里改成读曲库目录)。

struct GenreLibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @State private var searchText = ""
    @AppStorage(GenreSplitPreference.storageKey) private var genreSeparatorsRaw = 0
    #if os(iOS)
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    #endif
    #if os(macOS)
    @State private var selectedGenreID: String?
    #endif

    /// 目录路径(P3):目录可读且读到了就用目录的流派,否则照旧读内存模型。
    @State private var catalogGenres = GenreCatalogList()

    /// 目录读到了用目录的;模型在内存里时读内存。歌曲模型不在内存里、目录那份还没取到时为 nil:页面转圈,
    /// 不说「没有流派」(6c U6a)。
    private var sourceGenres: [LibraryGenre]? {
        if let genres = catalogGenres.readableGenres { return genres }
        // crash-pattern: allow legacy-library-api 模型在内存里时读内存(目录读不了的时候),不在时不读
        return library.isReady ? library.visibleGenres : nil
    }

    private var filteredGenres: [LibraryGenre] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (sourceGenres ?? [])
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @Environment(\.libraryStackRegistersCollectionDetails) private var stackRegistersDetails

    /// 流派名里还有不少没拆开的斜杠、逗号、竖线时，菜单里「流派拆分」那一项下面写一句有几个。
    /// 不弹提示，也不在别处显示。
    private var genreSplitHint: String? {
        let names = (sourceGenres ?? []).map(\.name)
        let count = GenreSeparatorHint.unsplitNameCount(
            in: names,
            enabled: GenreSeparatorOptions(rawValue: genreSeparatorsRaw)
        )
        guard GenreSeparatorHint.shouldHint(unsplitCount: count, totalCount: names.count) else { return nil }
        return String(format: String(localized: "genre_split_menu_hint"), count)
    }

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            if stackRegistersDetails {
                iosBody
            } else {
                iosBody
                    .navigationDestination(for: LibraryGenre.self) { genre in
                        GenreDetailView(genre: genre)
                    }
            }
            #endif
        }
        .onAppear {
            if let host = library.catalogHost { catalogGenres.activate(host: host) }
        }
        .onDisappear { catalogGenres.deactivate() }
    }

    #if os(iOS)
    @ViewBuilder
    private var iosBody: some View {
        if sourceGenres == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sourceGenres?.isEmpty == true {
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
            // 筛选加本地化排序, 一次 body 只做一遍。
            let genres = filteredGenres
            ScrollView {
                if genres.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(.top, 80)
                        .pmAppearFade(.contentAppear)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: cardMinimumWidth), spacing: 12)],
                        spacing: 12
                    ) {
                        ForEach(genres) { genre in
                            NavigationLink(value: genre) {
                                LibraryGenreCard(genre: genre, height: cardHeight)
                            }
                            .buttonStyle(.pmPressable)
                        }
                    }
                    .padding(16)
                    // iPhone Duo 竖栏：最右一列风格卡伸进竖栏，系统的玻璃胶囊浮在上面。
                    .pmCoversExtendUnderVerticalBar()
                    // 只在"有结果 ↔ 没结果"这一层重建时淡入一次, 逐键过滤的网格本身不动。
                    .pmAppearFade(.contentAppear)
                }
            }
            .pmExtendsUnderVerticalBar()
            .libraryPageFind(text: $searchText, prompt: "genre_search_placeholder")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    GenreSplitMenu(hint: genreSplitHint, titled: verticalBarEdge != nil)
                }
            }
            // 极简模式根页没有导航栏：风格数与查找排成页头。
            .minimalPageHeader {
                HStack(spacing: 4) {
                    MinimalHeaderCount(
                        text: LibraryCountText.genres(genres.count)
                    )
                    Spacer(minLength: 8)
                    MinimalHeaderActions {
                        MinimalPageFindButton()
                        GenreSplitMenu(hint: genreSplitHint)
                    }
                }
            }
        }
    }
    #endif

    #if os(macOS)
    /// 左栏选中的流派;没选过或被筛掉了就取第一个。传进来的是 body 里排好的那一份,
    /// 以前每一行都经 `selectedGenre` 重新筛、排一遍整份流派。
    private func macSelectedGenre(in genres: [LibraryGenre]) -> LibraryGenre? {
        if let selectedGenreID,
           let genre = genres.first(where: { $0.id == selectedGenreID }) {
            return genre
        }
        return genres.first
    }

    @ViewBuilder
    private var macBody: some View {
        if sourceGenres == nil {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PMColor.bg.ignoresSafeArea())
        } else if sourceGenres?.isEmpty == true {
            ContentUnavailableView(
                "no_genres",
                systemImage: "tag",
                description: Text("no_genres_desc")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PMColor.bg.ignoresSafeArea())
        } else {
            let genres = filteredGenres
            let selectedGenre = macSelectedGenre(in: genres)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("tab_genres")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(PMColor.text)
                            Spacer(minLength: 0)
                            GenreSplitMenu(hint: genreSplitHint)
                                .macControlMenuStyle()
                                .help(Text("genre_split_title"))
                        }

                        MacLibraryFindField(text: $searchText, prompt: "genre_search_placeholder", width: nil)
                    }
                    // 和艺人页的左栏同一档 26 高(`MacControlTier.toolbar`)。
                    .macControlTier(.toolbar)
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                    if genres.isEmpty {
                        Spacer(minLength: 0)
                            .accessibilityHidden(true)
                    } else {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(spacing: 2) {
                                ForEach(genres) { genre in
                                    macGenreRow(genre, selected: genre.id == selectedGenre?.id)
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
                .accessibilityElement(children: .contain)

                Rectangle().fill(PMColor.divider).frame(width: 0.5)

                Group {
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
                .accessibilityElement(children: .contain)
            }
            .background(PMColor.bg.ignoresSafeArea())
        }
    }

    private func macGenreRow(_ genre: LibraryGenre, selected: Bool) -> some View {
        Button {
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
                    Text(verbatim: "\(LibraryCountText.albums(genre.albumCount)) · \(LibraryCountText.songs(genre.songCount))")
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

/// 流派页的菜单：直达设置里的「流派拆分」，流派名里还有不少没拆开的符号时下面带一句说明。
/// 工具栏条目跑在自己的视图图里，只收值，不读环境。
private struct GenreSplitMenu: View {
    let hint: String?
    var titled = false

    var body: some View {
        Menu {
            Button {
                SettingsNavigation.shared.open("artists.genreSeparators")
            } label: {
                Label("genre_split_menu_item", systemImage: "scissors")
                if let hint {
                    Text(verbatim: hint)
                }
            }
            .accessibilityIdentifier("genres.splitSettings")
        } label: {
            #if os(macOS)
            Image(systemName: "ellipsis")
                .macControlChrome(iconOnly: true)
            #else
            PMToolbarItemLabel("genre_split_title", systemImage: "ellipsis.circle", titled: titled)
            #endif
        }
        .accessibilityLabel(Text("genre_split_title"))
        .accessibilityIdentifier("genres.menu")
    }
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
                Text(verbatim: "\(LibraryCountText.albums(genre.albumCount)) · \(LibraryCountText.songs(genre.songCount))")
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
        .accessibilityValue(Text(verbatim: "\(LibraryCountText.albums(genre.albumCount)), \(LibraryCountText.songs(genre.songCount))"))
    }
}

private struct GenreArtworkMosaic: View {
    @Environment(MusicLibrary.self) private var library
    let genre: LibraryGenre
    let artworkSize: CGFloat

    /// 代表曲不满 3 张专辑时会拿同专辑的歌补位，拼贴里同一张封面叠两次像重影，所以一张专辑只放一张。
    private var songs: [Song] {
        var seenAlbums = Set<String>()
        return genre.representativeSongIDs.compactMap { library.visibleSong(id: $0) }.filter { song in
            let albumID = song.albumID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return seenAlbums.insert(albumID.isEmpty ? "song:\(song.id)" : albumID).inserted
        }
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

struct GenreDetailView: View {
    #if os(iOS)
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(CoverTintProvider.self) private var coverTints
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(CollectionCoverWall.preferenceKey) private var usesCoverWallHeader = CollectionCoverWall.defaultEnabled
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

    /// 风格没有自己的封面, 用它的第一首代表曲 —— 也就是拼贴里最上面那张。
    private var artworkTintSong: Song? {
        genre.representativeSongIDs.lazy.compactMap { library.visibleSong(id: $0) }.first
            ?? songIDs.first.flatMap { library.visibleSong(id: $0) }
    }

    #if os(iOS)
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

    /// 详情页正文左右留白。Mac 跟头部(`MacLibraryHeader`)的 36 对齐。
    private var sectionInset: CGFloat {
        #if os(macOS)
        PMSpace.xxxl
        #else
        20
        #endif
    }

    private var countLine: String {
        "\(LibraryCountText.albums(albums.count)) · \(LibraryCountText.songs(songIDs.count))"
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
                .padding(.top, 20)
                .padding(.bottom, 16)
            }
            .navigationTitle("")
            #else
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    macHero

                    VStack(alignment: .leading, spacing: 28) {
                        LibraryReviewSection(subject: .genre(genre.id))
                            .padding(.horizontal, sectionInset)
                        if !albums.isEmpty { albumShelf }
                        if !songIDs.isEmpty { songSection }
                    }
                    .padding(.top, PMSpace.l)
                }
                .padding(.bottom, 64)
            }
            .background(PMColor.bg.ignoresSafeArea())
            .navigationTitle(Text(verbatim: genre.name))
            #endif
        }
        .toolbarTitleDisplayMode(.inline)
        #if os(iOS)
        .toolbar {
            SongSelectionToolbarItems(
                selection: selection,
                orderedIDs: { songIDs },
                titled: verticalBarEdge != nil
            )
        }
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

    #if os(macOS)
    /// 跟专辑、艺人页同一副头部: 代表封面虚化成底图、往下化进页面底色, 左边那张「封面」换成风格的拼贴。
    private var macHero: some View {
        let palette = GenreVisualStyle.palette(for: genre.id)
        return MacLibraryHeader(
            eyebrow: "genre_label",
            title: genre.name,
            subtitle: countLine,
            iconSystemName: "guitars",
            accent: palette.leading,
            darkAccent: palette.trailing,
            canPlay: !songIDs.isEmpty,
            onPlay: playAll,
            onShuffle: shuffleAll,
            showsMoreButton: false,
            artworkBackdrop: true,
            cover: AnyView(
                GenreArtworkMosaic(genre: genre, artworkSize: 112)
                    .frame(width: 196, height: 196)
            ),
            backdropSong: artworkTintSong
        )
    }
    #endif

    #if os(iOS)
    /// 头图: 风格里有 4 张以上不同的专辑封面时铺一面封面墙(和歌单同一套, 跟同一个开关), 墙下沿渐隐进整页底色;
    /// 封面不够、关了封面墙、手机横屏时是「代表封面拼贴居中 + 虚化封面底」, 跟专辑页同一副版式。
    /// 两种都不自己铺底色 —— 原来头图是一块不透明的斜向渐变, 收尾的颜色跟下面整页底色对不上, 中间一道硬边。
    @ViewBuilder
    private func hero(insets: ImmersiveLibraryDetailInsets) -> some View {
        if let wallSongs = coverWallSongs {
            coverWallHero(wallSongs, insets: insets)
        } else {
            mosaicHero(insets: insets)
        }
    }

    /// 墙要的歌: 每张专辑取一首, 最多扫前 600 首。不够上墙时返回 nil。
    private var coverWallSongs: [Song]? {
        guard usesCoverWallHeader, !usesCompactHero else { return nil }
        let pooled = CollectionCoverWall.pool(
            from: songIDs.lazy.compactMap { library.unobservedVisibleSong(id: $0) },
            focusGroupKey: nil
        )
        guard CoverWallLayoutPolicy.prefersWall(distinctCoverCount: pooled.count) else { return nil }
        return pooled.map(\.element)
    }

    private func coverWallHero(_ wallSongs: [Song], insets: ImmersiveLibraryDetailInsets) -> some View {
        VStack(spacing: 14) {
            CollectionCoverWallHeader(
                title: genre.name,
                subtitle: countLine,
                songs: wallSongs,
                nowPlaying: player.currentSong,
                wallHeight: horizontalSizeClass == .regular ? 340 : 300,
                topInset: insets.top
            ) {
                EmptyView()
            }

            heroActions
                .padding(.leading, insets.leading + 20)
                .padding(.trailing, insets.trailing + 20)
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    /// 竖屏: 拼贴居中当「封面」, 名字、数量、按钮顺着往下。手机横屏只剩三百多点高,
    /// 拼贴挪到左边、名字与按钮排进右边, 头图压到 190pt 以内, 专辑架和第一首歌才露得出来。
    private func mosaicHero(insets: ImmersiveLibraryDetailInsets) -> some View {
        let compact = usesCompactHero
        let mosaicHeight: CGFloat = compact ? 88 : 172
        let mosaicWidth = mosaicHeight * 1.46
        let topPadding: CGFloat = compact ? 18 : 52

        return VStack(alignment: compact ? .leading : .center, spacing: compact ? 14 : 18) {
            if compact {
                HStack(alignment: .center, spacing: 16) {
                    heroMosaic(width: mosaicWidth, height: mosaicHeight)
                    heroIdentity(centered: false)
                }
            } else {
                VStack(spacing: 16) {
                    heroMosaic(width: mosaicWidth, height: mosaicHeight)
                    heroIdentity(centered: true)
                }
                .frame(maxWidth: .infinity)
            }

            heroActions
        }
        // 底图铺满整幅屏幕, 文字与按钮按侧留在安全区内 —— 横屏两侧安全区不一定相等。
        .padding(.leading, insets.leading + 20)
        .padding(.trailing, insets.trailing + 20)
        .padding(.top, insets.top + topPadding)
        .padding(.bottom, compact ? 12 : 8)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            mosaicBackdrop(
                centerX: compact ? insets.leading + 20 + mosaicWidth / 2 : nil,
                centerY: insets.top + topPadding + mosaicHeight / 2,
                mosaicHeight: mosaicHeight,
                topInset: insets.top
            )
        }
    }

    private func heroMosaic(width: CGFloat, height: CGFloat) -> some View {
        GenreArtworkMosaic(genre: genre, artworkSize: height / 1.3)
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.3), radius: 20, y: 12)
            .accessibilityHidden(true)
    }

    private func heroIdentity(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 5) {
            Text(verbatim: genre.name)
                .font(usesCompactHero ? Font.title.weight(.bold) : Font.largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
                .shadow(color: .black.opacity(0.22), radius: 12, y: 2)

            Text(verbatim: countLine)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.74))
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// 两种头图共用: 「播放 · 随机」平分一行, 下面是评分与短评。
    private var heroActions: some View {
        VStack(spacing: 14) {
            LibraryDetailPlayShuffleRow(
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
    }

    /// 拼贴背后那层: 第一首代表曲的封面放大、虚化, 以拼贴为中心铺满头图上半截, 再往下化成透明,
    /// 露出整页底色(同一首歌取的色)—— 没有一道边。做法与专辑页头图一样, 每个通道压到一半,
    /// 浅色封面放大开也不会把白字和返回键冲掉。
    @ViewBuilder
    private func mosaicBackdrop(
        centerX: CGFloat?,
        centerY: CGFloat,
        mosaicHeight: CGFloat,
        topInset: CGFloat
    ) -> some View {
        if let song = artworkTintSong {
            let artworkSide = mosaicHeight / 1.3
            let mosaicBottom = centerY + mosaicHeight / 2
            GeometryReader { geometry in
                let width = geometry.size.width
                let height = max(geometry.size.height, 1)
                let fadeEnd = min(mosaicBottom + 260, height)
                let fadeStart = min(mosaicBottom + 10, fadeEnd * 0.6)
                let side = max(width, mosaicBottom + 60) * 1.3
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: artworkSide,
                    cornerRadius: 0,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat,
                    showsPlaceholder: false
                )
                .scaleEffect(side / artworkSide)
                .blur(radius: 20)
                .saturation(1.25)
                .colorMultiply(Color(white: 0.5))
                .position(x: centerX ?? width / 2, y: centerY)
                .frame(width: width, height: height)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: fadeStart / height),
                            .init(color: .black.opacity(0.32), location: (fadeStart + fadeEnd) / 2 / height),
                            .init(color: .clear, location: fadeEnd / height),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .overlay(alignment: .top) {
                    // 顶部压一点暗, 返回键和工具栏读得清。
                    LinearGradient(
                        colors: [.black.opacity(0.18), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: topInset + 64)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
    #endif

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
                .padding(.horizontal, sectionInset)
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
                ForEach(Array(ids.enumerated()), id: \.element) { index, songID in
                    if let song = library.unobservedVisibleSong(id: songID) {
                        SongRowView(
                            song: song,
                            isPlaying: player.currentSong?.id == song.id,
                            trackNumber: index + 1,
                            largestTrackNumber: ids.count,
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
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("genreSong.\(song.id)")
                        .songSelectable(
                            songID: song.id,
                            selection: selection,
                            orderedIDs: { songIDs },
                            defaultAction: SongSelectableDefaultAction.macOnly { playSong(song) }
                        )

                        if songID != lastID {
                            Divider()
                                .padding(.leading, 66)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
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
            .padding(.horizontal, sectionInset)
        }
    }

    private func detailSectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.title3.weight(.bold))
            .padding(.horizontal, sectionInset)
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
