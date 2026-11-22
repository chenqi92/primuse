#if os(iOS)
import SwiftUI
import PrimuseKit

extension HomeHeroRecommendationContent {
    var title: LocalizedStringKey {
        self == .albums ? "home_hero_content_albums" : "home_hero_content_songs"
    }
}

struct HomeHeroSettingsButton: View {
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .accessibilityLabel(Text("home_hero_style_title"))
        .accessibilityIdentifier("home.edit.heroStyle")
        .sheet(isPresented: $isPresented) { HomeHeroSettingsSheet() }
    }
}

private struct HomeHeroSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(HomeHeroStyle.storageKey) private var savedStyle: HomeHeroStyle = .carousel
    @AppStorage(HomeHeroRecommendationPolicy.contentKey) private var savedContent: HomeHeroRecommendationContent = .albums
    @AppStorage(HomeHeroRecommendationPolicy.songCountKey) private var savedSongCount = HomeHeroRecommendationPolicy.defaultSongCount
    @AppStorage(HomeHeroRecommendationPolicy.albumCountKey) private var savedAlbumCount = HomeHeroRecommendationPolicy.defaultAlbumCount
    @State private var style: HomeHeroStyle = .carousel
    @State private var content: HomeHeroRecommendationContent = .albums
    @State private var songCount = HomeHeroRecommendationPolicy.defaultSongCount
    @State private var albumCount = HomeHeroRecommendationPolicy.defaultAlbumCount

    @State private var appearances = HomeHeroCardAppearances()
    @State private var originalAppearances = HomeHeroCardAppearances()
    @State private var prepared = false
    @State private var importing = false
    @State private var saveFailed = false
    private let appearanceStore = HomeHeroCardAppearanceStore.shared

    private var canSave: Bool {
        let current = style == .medium ? appearances.medium : appearances.large
        return prepared && !importing && (!style.showsRecommendationCards || current.cover != .photo || current.photo != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("home_hero_style_title") {
                    ForEach([HomeHeroStyle.featured, .carousel, .medium, .wall], id: \.self) { option in
                        Button { style = option } label: {
                            HStack(spacing: 14) {
                                Image(systemName: option.settingsSymbol)
                                    .font(option == .medium ? .title3 : .title)
                                    .foregroundStyle(.tint)
                                    .frame(width: 38, height: 42)
                                Text(option.title).foregroundStyle(.primary)
                                Spacer()
                                if style == option { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(style == option ? .isSelected : [])
                        .accessibilityIdentifier("home.hero.style.\(option.rawValue)")
                    }
                }
                if style != .carousel {
                    Section("home_hero_content_title") {
                        ForEach(HomeHeroRecommendationContent.allCases, id: \.self) { option in
                            Button { content = option } label: {
                                HStack {
                                    Text(option.title).foregroundStyle(.primary)
                                    Spacer()
                                    if content == option { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(content == option ? .isSelected : [])
                            .accessibilityIdentifier("home.hero.content.\(option.rawValue)")
                        }
                        if content == .songs {
                            Stepper(value: $songCount, in: 1...50) {
                                Text(String(format: String(localized: "home_hero_song_count_format"), songCount))
                            }
                            .accessibilityIdentifier("home.hero.songCount")
                        } else {
                            Stepper(value: $albumCount, in: 1...12) {
                                Text(String(format: String(localized: "home_hero_album_count_format"), albumCount))
                            }
                            .accessibilityIdentifier("home.hero.albumCount")
                        }
                    }
                    if style.showsRecommendationCards {
                        Section {
                            HomeHeroCardAppearanceFields(
                                appearance: style == .medium ? $appearances.medium : $appearances.large,
                                importing: $importing
                            )
                            .id(style)
                        }
                    }
                }
            }
            .disabled(!prepared)
            .environment(\.editMode, .constant(.inactive))
            .navigationTitle("home_hero_section_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") {
                        do {
                            try appearanceStore.save(appearances, original: originalAppearances)
                        } catch {
                            saveFailed = true
                            return
                        }
                        savedContent = content
                        savedSongCount = songCount
                        savedAlbumCount = albumCount
                        savedStyle = style
                        dismiss()
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("home.hero.settings.done")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onChange(of: style) { previous, _ in
            let key: WritableKeyPath<HomeHeroCardAppearances, HomeHeroCardAppearance> = previous == .medium ? \.medium : \.large
            if appearances[keyPath: key].cover == .photo && appearances[keyPath: key].photo == nil {
                appearances[keyPath: key].cover = originalAppearances[keyPath: key].cover
            }
        }
        .alert("home_hero_save_failed", isPresented: $saveFailed) { Button("ok") {} }
        .task {
            guard !prepared else { return }
            await appearanceStore.load()
            guard !Task.isCancelled else { return }
            originalAppearances = appearanceStore.values
            appearances = originalAppearances
            prepared = true
            style = savedStyle
            content = savedContent
            songCount = HomeHeroRecommendationPolicy.songCount(savedSongCount)
            albumCount = HomeHeroRecommendationPolicy.albumCount(savedAlbumCount)
        }
    }
}

private extension HomeHeroStyle {
    var settingsSymbol: String {
        switch self {
        case .carousel: "rectangle.on.rectangle.angled"
        case .featured, .medium: "rectangle.portrait.fill"
        case .wall: "square.grid.3x3.fill"
        }
    }
}

extension HomeHeroRecommendationTheme {
    var title: String {
        switch self {
        case .daily: String(localized: "home_hero_daily_mix")
        case .catalogRewind: AIRecommendationIntentPreset.catalogRewind.localizedTitle
        case .recentCatalog: AIRecommendationIntentPreset.recentCatalog.localizedTitle
        }
    }
}

enum HomeHeroRecommendationDestination: Hashable {
    case albums
    case songs(HomeHeroRecommendationTheme)
}

struct HomeHeroRecommendationSection: View {
    let metrics: HomeHeroFeaturedMetrics
    let previewSongs: [Song]
    let isInteractive: Bool
    let catalog: HomeHeroRecommendationCatalog
    @Environment(MusicLibrary.self) private var library
    @AppStorage(HomeHeroRecommendationPolicy.contentKey) private var content: HomeHeroRecommendationContent = .albums
    @AppStorage(HomeHeroRecommendationPolicy.songCountKey) private var songCount = HomeHeroRecommendationPolicy.defaultSongCount
    @AppStorage(HomeHeroRecommendationPolicy.albumCountKey) private var albumCount = HomeHeroRecommendationPolicy.defaultAlbumCount

    @AppStorage(HomeHeroStyle.storageKey) private var style: HomeHeroStyle = .carousel
    @State private var centerIndex = 0
    @State private var scrolling = false
    @State private var visible = false
    private let appearanceStore = HomeHeroCardAppearanceStore.shared

    private var appearance: HomeHeroCardAppearance {
        style == .medium ? appearanceStore.values.medium : appearanceStore.values.large
    }

    private func focused(_ index: Int, count: Int) -> Bool {
        isInteractive && visible && !scrolling && index == min(max(0, centerIndex), count - 1)
    }

    private var models: [HomeHeroRecommendationModel] {
        content == .albums ? [catalog.albums] : HomeHeroRecommendationTheme.allCases.map { catalog.collection($0) }
    }

    private func shownSongs(for theme: HomeHeroRecommendationTheme) -> [Song] {
        if isInteractive { return catalog.collection(theme).songs }
        return HomeHeroRecommendationPreview.songs(for: theme, from: previewSongs, songCount: songCount)
    }

    private var shownAlbums: [Album] {
        if isInteractive { return catalog.albums.albums }
        return HomeHeroRecommendationPreview.albums(from: previewSongs, albumCount: albumCount, library: library)
    }

    var body: some View {
        let albums = content == .albums ? shownAlbums : []
        VStack(alignment: .leading, spacing: 12) {
            Text(content == .albums ? LocalizedStringKey("home_hero_album_picks") : "home_hero_theme_playlists").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 20)
            if isInteractive && (library.musicSongs.isEmpty || models.allSatisfy({ $0.revision > 0 && !$0.isLoading && $0.songs.isEmpty })) {
                ContentUnavailableView("library_recommendations_empty_title", systemImage: "sparkles")
            } else if content == .albums && albums.isEmpty {
                if !isInteractive || catalog.albums.isLoading || catalog.albums.revision == 0 {
                    HomeHeroFeaturedSkeleton(metrics: metrics)
                } else {
                    ContentUnavailableView("library_recommendations_empty_title", systemImage: "sparkles")
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        if content == .albums {
                            ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                                NavigationLink(value: HomeHeroRecommendationDestination.albums) {
                                    HomeHeroRecommendationCard(
                                        metrics: metrics, songs: Array(library.songs(forAlbum: album.id).prefix(appearance.cover == .collage ? 4 : 1)),
                                        title: album.title, subtitle: album.artistName ?? "",
                                        appearance: appearance, medium: style == .medium,
                                        focused: focused(index, count: albums.count)
                                    )
                                }
                                .accessibilityIdentifier("home.hero.recommendation.album.\(album.id)")
                            }
                        } else {
                            ForEach(Array(HomeHeroRecommendationTheme.allCases.enumerated()), id: \.element) { index, theme in
                                let songs = shownSongs(for: theme)
                                NavigationLink(value: HomeHeroRecommendationDestination.songs(theme)) {
                                    HomeHeroRecommendationCard(
                                        metrics: metrics, songs: CoverFlowArtwork.distinctArtworkSongs(songs, limit: 4), title: theme.title,
                                        subtitle: String(format: String(localized: "home_hero_song_count_format"), songs.count),
                                        isLoading: songs.isEmpty && catalog.collection(theme).revision == 0,
                                        appearance: appearance, theme: theme, medium: style == .medium,
                                        focused: focused(index, count: HomeHeroRecommendationTheme.allCases.count)
                                    )
                                }
                                .disabled(songs.isEmpty)
                                .accessibilityIdentifier("home.hero.recommendation.songs.\(theme.rawValue)")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .scrollTargetLayout()
                    .padding(.bottom, 12)
                }
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .onScrollGeometryChange(for: Int.self) { geometry in
                    let step = metrics.cardWidth + 14
                    let center = geometry.visibleRect.midX - metrics.cardWidth / 2
                    return Int((center / step).rounded())
                } action: { _, index in centerIndex = index }
                .onScrollPhaseChange { _, phase in scrolling = phase != .idle }
                .pmHorizontalClipExtendingUnderVerticalBar()
                .accessibilityIdentifier("home.hero.featured.cards")
            }
        }
        .onScrollVisibilityChange(threshold: 0.1) { visible = $0 }
        .task { await appearanceStore.load() }
        .modifier(HomeHeroRecommendationRefresh(models: models, contentKind: content, isEnabled: isInteractive))
    }
}

/// 界面编辑里只看版面、不去算推荐:按首页现有的封面歌排出一个大致的样子。
private enum HomeHeroRecommendationPreview {
    static func songs(for theme: HomeHeroRecommendationTheme, from previewSongs: [Song], songCount: Int) -> [Song] {
        let limit = HomeHeroRecommendationPolicy.songCount(songCount)
        let pool = theme.candidatePool(from: previewSongs, minimumCount: limit)
        let ids = HomeHeroRecommendationPolicy.candidates(
            rankedIDs: pool.map(\.id), day: HomeHeroRecommendationPolicy.dayStamp(Date()) + theme.rotationOffset,
            round: 0, excluding: [], limit: limit
        )
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    @MainActor
    static func albums(from previewSongs: [Song], albumCount: Int, library: MusicLibrary) -> [Album] {
        var seen = Set<String>()
        return Array(previewSongs.compactMap { song -> Album? in
            guard let id = song.albumID, seen.insert(id).inserted else { return nil }
            return library.visibleAlbum(id: id)
        }.prefix(HomeHeroRecommendationPolicy.albumCount(albumCount)))
    }
}

private struct HomeHeroRecommendationRefresh: ViewModifier {
    let models: [HomeHeroRecommendationModel]
    let contentKind: HomeHeroRecommendationContent
    let isEnabled: Bool
    var refreshRound = 0
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(HomeHeroRecommendationPolicy.songCountKey) private var songCount = HomeHeroRecommendationPolicy.defaultSongCount
    @AppStorage(HomeHeroRecommendationPolicy.albumCountKey) private var albumCount = HomeHeroRecommendationPolicy.defaultAlbumCount
    @State private var day = HomeHeroRecommendationPolicy.dayStamp(Date())
    @State private var handledRefreshRound = 0

    private var refreshKey: String {
        "\(models.map { $0.theme.rawValue }.joined(separator: ","))#\(day)#\(refreshRound)#\(contentKind.rawValue)#\(songCount)#\(albumCount)#\(isEnabled && scenePhase == .active)#\(library.isReady)#\(library.musicSongs.count)#\(library.musicSongsRevision)#\(intelligence.settingsStore.revision)#\(intelligence.regionAvailability.revision)"
    }

    func body(content: Content) -> some View {
        content
            .task(id: refreshKey) {
                guard isEnabled, scenePhase == .active, library.isReady else { return }
                let force = refreshRound != handledRefreshRound
                for model in models {
                    guard !Task.isCancelled else { return }
                    await model.refresh(
                        configuration: .init(content: contentKind, songCount: songCount, albumCount: albumCount),
                        library: library, intelligence: intelligence, force: force
                    )
                }
                if !Task.isCancelled { handledRefreshRound = refreshRound }
            }
            .task {
                guard isEnabled else { return }
                while !Task.isCancelled {
                    let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())) ?? Date().addingTimeInterval(86_400)
                    do { try await Task.sleep(for: .seconds(max(1, nextDay.timeIntervalSinceNow))) } catch { return }
                    day = HomeHeroRecommendationPolicy.dayStamp(Date())
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { day = HomeHeroRecommendationPolicy.dayStamp(Date()) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                day = HomeHeroRecommendationPolicy.dayStamp(Date())
            }
    }
}

struct HomeHeroRecommendationCard: View {
    let metrics: HomeHeroFeaturedMetrics
    let songs: [Song]
    let title: String
    let subtitle: String
    var isLoading = false
    var appearance = HomeHeroCardAppearance()
    var theme: HomeHeroRecommendationTheme?
    var medium = false
    var focused = false
    @ScaledMetric(relativeTo: .body) private var captionHeight: CGFloat = 84
    @Environment(CoverTintProvider.self) private var tintProvider

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: ImmersiveArtworkPalette {
        let artwork = tintSong.flatMap { song in
            tintProvider.palette(forSongID: song.id)
                ?? (tintProvider.hasAnalyzedColorlessArtwork(forSongID: song.id) ? .homeMonochrome : nil)
        }
        return appearance.palette(artwork: artwork, theme: theme)
    }

    var body: some View {
        let compact = metrics.isCompact
        let cardHeight: CGFloat = metrics.cardHeight(captionHeight: captionHeight)
        let coverWidth: CGFloat = compact ? metrics.artworkSide : metrics.cardWidth
        let captionMinHeight: CGFloat = compact ? cardHeight : captionHeight + HomeHeroFeaturedMetrics.captionScrimExtent
        let captionAlignment: Alignment = compact ? .leading : .bottomLeading
        // 竖屏封面铺满整张卡,标题、说明压在封面下沿的暗渐变上;横屏封面铺满左边一格,标题在右。
        // 转屏只换摆法、不换视图。
        let layout = compact ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(ZStackLayout(alignment: .bottomLeading))
        return layout {
            cover(width: coverWidth, height: cardHeight)
            caption
                .padding(.horizontal, 14)
                .padding(.vertical, compact ? 0 : 12)
                .frame(maxWidth: .infinity, minHeight: captionMinHeight, alignment: captionAlignment)
                .background { captionScrim }
        }
        .frame(width: metrics.cardWidth, height: cardHeight)
        .background { backdrop }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.06), lineWidth: 0.5) }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .task(id: songs.map(\.id)) {
            // 封面的颜色要第一首的;没有封面时底色从几首歌里一起取,所以几首都先取好。
            guard !appearance.customColors else { return }
            tintProvider.prepare(songs)
        }
    }

    /// 封面铺满给它的那一格(竖屏整张卡,横屏左边一格),多出来的裁掉,四周不留边。
    @ViewBuilder
    private func cover(width: CGFloat, height: CGFloat) -> some View {
        Group {
            if appearance.cover == .hidden {
                Color.clear
            } else if appearance.cover == .photo, let photo = appearance.photo {
                Image(uiImage: photo.image).resizable().scaledToFill()
            } else {
                HomeHeroRecommendationArtwork(songs: artworkSongs, side: max(width, height), showsPlaceholder: false)
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: title).font(.headline).foregroundStyle(.white).lineLimit(2)
            if isLoading {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Text(verbatim: subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            }
        }
    }

    /// 竖屏从封面中段往下慢慢压暗,白字压在什么颜色的封面上都看得清;横屏只压右边标题那一格。
    private var captionScrim: LinearGradient {
        if metrics.isCompact {
            return LinearGradient(colors: [.black.opacity(0.22), .black.opacity(0.5)],
                                  startPoint: .leading, endPoint: .trailing)
        }
        let stops: [Gradient.Stop] = [
            Gradient.Stop(color: .clear, location: 0),
            Gradient.Stop(color: .black.opacity(0.5), location: 0.55),
            Gradient.Stop(color: .black.opacity(0.66), location: 1),
        ]
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }

    @ViewBuilder
    private var backdrop: some View {
        let style = appearance.backdrop.resolved(medium: medium, album: theme == nil)
        if coverFillsCard {
            // 封面铺满整张卡时底下这层看不见,只在封面还没读出来的那一下垫着:不动,也不去取封面。
            HomeHeroCardBackdrop(style: .gradient, palette: palette, focused: false, reduceMotion: true)
        } else if let flowPalettes = coverFlowPalettes {
            // 没有封面可看:拿里面几首歌的封面模糊了慢慢流动(像 Apple Music 的动态背景)。
            CoverFlowBackdrop(palettes: flowPalettes, songs: songs, isAnimating: focused && style != .gradient)
        } else if style == .flow, followsArtwork {
            CoverFlowBackdrop(palettes: [palette], songs: songs, isAnimating: focused)
        } else {
            HomeHeroCardBackdrop(style: style, palette: palette, focused: focused, reduceMotion: reduceMotion)
        }
    }

    /// 卡上铺哪几张封面:选了四格拼贴,或者歌曲集合卡「自动」时,凑得齐四张就无缝铺成 2×2;其余只铺第一张。
    private var artworkSongs: [Song] {
        let collage = appearance.cover == .collage || (appearance.cover == .automatic && theme != nil)
        return collage ? songs : Array(songs.prefix(1))
    }

    /// 竖屏封面铺满整张卡、底下那层看不见的时候。没有封面文件名、也没读到取色的歌当作没有封面。
    private var coverFillsCard: Bool {
        guard !metrics.isCompact else { return false }
        switch appearance.cover {
        case .hidden:
            return false
        case .photo where appearance.photo != nil:
            return true
        case .automatic, .collage, .photo:
            return firstHasArtwork || songs.first?.coverArtFileName?.isEmpty == false
        }
    }

    /// 流动背景跟着封面走:自选颜色、自选照片时还是按选的颜色画渐变。
    private var followsArtwork: Bool {
        !appearance.customColors && !(appearance.cover == .photo && appearance.photo != nil)
    }

    private var firstHasArtwork: Bool {
        songs.first.map { song in
            tintProvider.palette(forSongID: song.id) != nil
                || tintProvider.hasAnalyzedColorlessArtwork(forSongID: song.id)
        } ?? false
    }

    /// 卡片上没有封面可看的时候(封面设成不显示,或者第一首根本没有封面),底色改从里面几首歌的封面取。
    /// 一首有颜色的封面都没有时返回 nil,照旧用这一类的预设色。自选颜色、自选照片时不管。
    private var coverFlowPalettes: [ImmersiveArtworkPalette]? {
        guard !appearance.customColors, !(appearance.cover == .photo && appearance.photo != nil) else { return nil }
        guard appearance.cover == .hidden || !firstHasArtwork else { return nil }
        let palettes = songs.compactMap { tintProvider.palette(forSongID: $0.id) }
        return palettes.isEmpty ? nil : palettes
    }

    private var tintSong: Song? {
        guard !appearance.customColors, appearance.cover != .hidden, appearance.cover != .photo else { return nil }
        return songs.first
    }
}

private struct HomeHeroRecommendationArtwork: View {
    let songs: [Song]
    let side: CGFloat
    var showsPlaceholder = true

    var body: some View {
        Group {
            if songs.count >= 4 {
                let tileSide = side / 2
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        artwork(songs[0], size: tileSide)
                        artwork(songs[1], size: tileSide)
                    }
                    HStack(spacing: 0) {
                        artwork(songs[2], size: tileSide)
                        artwork(songs[3], size: tileSide)
                    }
                }
            } else if let song = songs.first {
                artwork(song, size: side)
            } else if showsPlaceholder {
                Rectangle().fill(.quaternary).overlay { Image(systemName: "music.note").font(.largeTitle) }
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .accessibilityHidden(true)
    }

    private func artwork(_ song: Song, size: CGFloat) -> some View {
        // 铺满整张卡的封面按「卡片」一档解码就够:3 倍屏上差几个像素看不出来,不必每张都解成最大一档。
        CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: min(size, Self.maximumDecodeSide),
                          cornerRadius: 0, sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat,
                          showsPlaceholder: showsPlaceholder, fillsProposedSize: true)
            .frame(width: size, height: size)
    }

    private static let maximumDecodeSide: CGFloat = 256
}

/// 首页顶部的封面墙:几排小封面整体斜着,相邻两排朝相反方向慢慢横移、首尾相接,四周压暗,
/// 下面压着标题和说明。封面来自顶部卡片的推荐内容(推荐专辑或歌曲集合,数量照设置),
/// 不够一面墙就重复铺满。
///
/// - 点一张封面:推荐专辑时打开那张专辑,歌曲集合时从这首开始放这一组。
/// - 点标题:打开这一组推荐的详情(和大号、中号卡片点进去的是同一页)。
///
/// 每排只由 `HomeHeroCoverWallDrift` 按时间挪整排的位置,封面视图不随每一帧重建。
/// 不在屏幕上、页面在滑、播放页盖着、App 不在前台、开了减弱动态效果时停住;减弱动态效果时静止显示。
struct HomeHeroCoverWallSection: View {
    let metrics: HomeHeroCoverWallMetrics
    let previewSongs: [Song]
    let isInteractive: Bool
    let catalog: HomeHeroRecommendationCatalog
    @Environment(MusicLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.playerCoversContent) private var playerCoversContent
    @AppStorage(HomeHeroRecommendationPolicy.contentKey) private var content: HomeHeroRecommendationContent = .albums
    @AppStorage(HomeHeroRecommendationPolicy.songCountKey) private var songCount = HomeHeroRecommendationPolicy.defaultSongCount
    @AppStorage(HomeHeroRecommendationPolicy.albumCountKey) private var albumCount = HomeHeroRecommendationPolicy.defaultAlbumCount
    @State private var visible = false
    @State private var pageScrolling = false
    @State private var scrollWatch = HomeHeroCoverWallScrollWatch()

    /// 歌曲集合时用哪一组。
    private static let theme = HomeHeroRecommendationTheme.daily

    private var model: HomeHeroRecommendationModel {
        content == .albums ? catalog.albums : catalog.collection(Self.theme)
    }

    var body: some View {
        let albums = content == .albums ? shownAlbums : []
        let songs = content == .songs ? shownSongs : []
        let items = content == .albums ? albumItems(albums) : songItems(songs)
        Group {
            if isInteractive && (library.musicSongs.isEmpty || (model.revision > 0 && !model.isLoading && items.isEmpty)) {
                ContentUnavailableView("library_recommendations_empty_title", systemImage: "sparkles")
            } else if items.isEmpty {
                HomeHeroCoverWallSkeleton(metrics: metrics)
            } else {
                wall(items, queue: songs, count: content == .albums ? albums.count : songs.count)
            }
        }
        .padding(.bottom, 12)
        .onScrollVisibilityChange(threshold: 0.1) { visible = $0 }
        .modifier(HomeHeroRecommendationRefresh(models: [model], contentKind: content, isEnabled: isInteractive))
    }

    private var shownSongs: [Song] {
        if isInteractive { return catalog.collection(Self.theme).songs }
        return HomeHeroRecommendationPreview.songs(for: Self.theme, from: previewSongs, songCount: songCount)
    }

    private var shownAlbums: [Album] {
        if isInteractive { return catalog.albums.albums }
        return HomeHeroRecommendationPreview.albums(from: previewSongs, albumCount: albumCount, library: library)
    }

    private func albumItems(_ albums: [Album]) -> [HomeHeroCoverWallItem] {
        albums.prefix(HomeHeroCoverWallMetrics.maximumTiles).compactMap { album in
            library.songs(forAlbum: album.id).first.map { HomeHeroCoverWallItem(song: $0, album: album, queueIndex: 0) }
        }
    }

    /// 封面各不相同的前几首,同一张专辑只铺一张;记下各自在这一组里的位置,点了从那首开始放。
    private func songItems(_ songs: [Song]) -> [HomeHeroCoverWallItem] {
        var seen = Set<String>()
        var items: [HomeHeroCoverWallItem] = []
        for (index, song) in songs.enumerated() {
            let cover = song.coverArtFileName.flatMap { $0.isEmpty ? nil : $0 }
            guard seen.insert(cover ?? song.albumID ?? song.id).inserted else { continue }
            items.append(HomeHeroCoverWallItem(song: song, album: nil, queueIndex: index))
            if items.count == HomeHeroCoverWallMetrics.maximumTiles { break }
        }
        return items
    }

    private func wall(_ items: [HomeHeroCoverWallItem], queue: [Song], count: Int) -> some View {
        let moving = isInteractive && visible && !pageScrolling && !playerCoversContent
            && !reduceMotion && scenePhase == .active
        let rows = HomeHeroCoverWallLayout.rows(items, metrics: metrics)
        let shape = RoundedRectangle(cornerRadius: HomeHeroCoverWallMetrics.cornerRadius, style: .continuous)
        return ZStack(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: HomeHeroCoverWallMetrics.spacing) {
                ForEach(rows.indices, id: \.self) { index in
                    HomeHeroCoverWallRow(
                        items: rows[index], metrics: metrics, queue: queue,
                        queueRevision: model.revision, isInteractive: isInteractive
                    )
                    .equatable()
                    .modifier(HomeHeroCoverWallDrift(
                        speed: HomeHeroCoverWallLayout.speed(row: index),
                        period: metrics.loopLength,
                        phase: CGFloat(index) * metrics.step * 0.5,
                        moving: moving
                    ))
                }
            }
            .frame(width: metrics.contentWidth, height: metrics.contentHeight, alignment: .topLeading)
            .rotationEffect(.degrees(-HomeHeroCoverWallMetrics.tiltDegrees))
            .frame(width: metrics.cardWidth, height: metrics.cardHeight)
            .accessibilityHidden(true)
            HomeHeroCoverWallVignette(metrics: metrics)
            titleBlock(count: count)
        }
        .frame(width: metrics.cardWidth, height: metrics.cardHeight)
        .background(Color.black)
        .clipShape(shape)
        // 斜出卡片外面、被裁掉的那些封面不接点按,点不到下面别的区块。
        .contentShape(shape)
        .overlay { shape.stroke(.primary.opacity(0.06), lineWidth: 0.5) }
        .padding(.horizontal, 20)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minY
        } action: { _ in
            notePageMoved()
        }
        .task(id: pageScrolling) { await settleWhenPageStops() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.hero.wall")
    }

    @ViewBuilder
    private func titleBlock(count: Int) -> some View {
        let isAlbums = content == .albums
        let title: String = isAlbums ? String(localized: "home_hero_album_picks") : Self.theme.title
        let format: String = isAlbums
            ? String(localized: "home_hero_album_count_format") : String(localized: "home_hero_song_count_format")
        let subtitle = String(format: format, count)
        let label = VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(verbatim: title)
                    .font(.title3.bold())
                if isInteractive {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.bold))
                        .opacity(0.8)
                        .accessibilityHidden(true)
                }
            }
            Text(verbatim: subtitle)
                .font(.subheadline)
                .opacity(0.85)
        }
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(16)
        .contentShape(Rectangle())

        if isInteractive {
            NavigationLink(value: isAlbums ? HomeHeroRecommendationDestination.albums : .songs(Self.theme)) {
                label
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("see_all"))
            .accessibilityIdentifier("home.hero.wall.title")
        } else {
            label
        }
    }

    /// 页面一动就记下时间、先停住;停稳一小会儿再接着动。只在开始和停下时各改一次状态,
    /// 滑动途中不重画这一块。
    private func notePageMoved() {
        scrollWatch.lastMove = CACurrentMediaTime()
        if !pageScrolling { pageScrolling = true }
    }

    private func settleWhenPageStops() async {
        guard pageScrolling else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            if CACurrentMediaTime() - scrollWatch.lastMove >= 0.14 {
                pageScrolling = false
                return
            }
        }
    }
}

/// 页面最后一次移动的时间。放在引用里改,不触发重画。
@MainActor
private final class HomeHeroCoverWallScrollWatch {
    var lastMove: CFTimeInterval = 0
}

struct HomeHeroCoverWallItem: Sendable {
    /// 取封面用的歌。
    let song: Song
    /// 推荐专辑时点开这张。
    let album: Album?
    /// 歌曲集合时从这一组的第几首开始放。
    let queueIndex: Int
}

enum HomeHeroCoverWallLayout {
    /// 每排一秒挪几点;相邻两排方向相反。
    static func speed(row: Int) -> CGFloat {
        let speeds: [CGFloat] = [14, 18, 12, 16]
        let value = speeds[row % speeds.count]
        return row.isMultiple(of: 2) ? -value : value
    }

    /// 整排的横向位置,始终在 [-period, 0] 里:一排比可见的宽度多摆一组,挪满一组正好接上开头。
    static func offset(time: TimeInterval, speed: CGFloat, period: CGFloat, phase: CGFloat) -> CGFloat {
        guard period > 0 else { return 0 }
        let travel = (CGFloat(time) * abs(speed) + phase).truncatingRemainder(dividingBy: period)
        return speed < 0 ? -travel : travel - period
    }

    /// 把封面分到各排,每排一组 `tilesPerRow` 张。凑不满整面墙时每排错开一张起头,上下两排不会一模一样。
    static func rows(_ items: [HomeHeroCoverWallItem], metrics: HomeHeroCoverWallMetrics) -> [[HomeHeroCoverWallItem]] {
        guard !items.isEmpty else { return [] }
        let perRow = metrics.tilesPerRow
        let stagger = items.count < perRow * metrics.rowCount ? 1 : 0
        return (0..<metrics.rowCount).map { row in
            let start = row * perRow + row * stagger
            return (0..<perRow).map { items[(start + $0) % items.count] }
        }
    }
}

/// 封面墙的一排:同一组封面重复摆到够长。整排的位置由外面的 `HomeHeroCoverWallDrift` 挪,
/// 这里只在封面换了时才重建。
private struct HomeHeroCoverWallRow: View, Equatable {
    let items: [HomeHeroCoverWallItem]
    let metrics: HomeHeroCoverWallMetrics
    let queue: [Song]
    let queueRevision: Int
    let isInteractive: Bool
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.displayScale) private var displayScale

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.isInteractive == rhs.isInteractive,
              lhs.queueRevision == rhs.queueRevision,
              lhs.queue.count == rhs.queue.count,
              lhs.metrics.tileSide == rhs.metrics.tileSide,
              lhs.metrics.contentWidth == rhs.metrics.contentWidth,
              lhs.metrics.tilesRenderedPerRow == rhs.metrics.tilesRenderedPerRow
        else { return false }
        return lhs.items.elementsEqual(rhs.items, by: sameTile)
    }

    nonisolated private static func sameTile(_ left: HomeHeroCoverWallItem, _ right: HomeHeroCoverWallItem) -> Bool {
        left.song.id == right.song.id
            && left.song.coverArtFileName == right.song.coverArtFileName
            && left.album?.id == right.album?.id
            && left.queueIndex == right.queueIndex
    }

    var body: some View {
        HStack(spacing: HomeHeroCoverWallMetrics.spacing) {
            ForEach(0..<metrics.tilesRenderedPerRow, id: \.self) { slot in
                tile(items[slot % items.count])
            }
        }
        .fixedSize()
        .frame(width: metrics.contentWidth, alignment: .leading)
    }

    @ViewBuilder
    private func tile(_ item: HomeHeroCoverWallItem) -> some View {
        let artwork = CachedArtworkView(
            coverRef: item.song.coverArtFileName, songID: item.song.id,
            size: metrics.thumbnailSize(displayScale: displayScale), cornerRadius: 6,
            sourceID: item.song.sourceID, filePath: item.song.filePath, fileFormat: item.song.fileFormat,
            fillsProposedSize: true
        )
        .frame(width: metrics.tileSide, height: metrics.tileSide)

        if !isInteractive {
            artwork
        } else if let album = item.album {
            NavigationLink(value: album) { artwork }
                .buttonStyle(.plain)
        } else {
            Button { play(from: item.queueIndex) } label: { artwork }
                .buttonStyle(.plain)
        }
    }

    private func play(from index: Int) {
        guard queue.indices.contains(index) else { return }
        let songs = queue
        player.shuffleEnabled = false
        Task { await player.play(queue: songs, startingAt: index) }
    }
}

/// 让一排封面随时间横移。只有这一层的位置随时间变,里面那排封面(`content`)不跟着每一帧重建。
/// 停住时记下走过的时间,接着动时从原处继续。
private struct HomeHeroCoverWallDrift: ViewModifier {
    let speed: CGFloat
    let period: CGFloat
    let phase: CGFloat
    let moving: Bool
    @State private var elapsed: TimeInterval = 0
    @State private var started: TimeInterval?

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { context in
            let time = elapsed + (started.map { context.date.timeIntervalSinceReferenceDate - $0 } ?? 0)
            content.offset(x: HomeHeroCoverWallLayout.offset(time: time, speed: speed, period: period, phase: phase))
        }
        .onChange(of: moving, initial: true) { _, active in
            let now = Date().timeIntervalSinceReferenceDate
            if active {
                started = now
            } else if let started {
                elapsed += now - started
                self.started = nil
            }
        }
    }
}

/// 四周压暗、越往下越深,标题压在下沿看得清。
private struct HomeHeroCoverWallVignette: View {
    let metrics: HomeHeroCoverWallMetrics

    var body: some View {
        let stops: [Gradient.Stop] = [
            Gradient.Stop(color: .clear, location: 0.3),
            Gradient.Stop(color: .black.opacity(0.72), location: 1),
        ]
        ZStack {
            RadialGradient(
                colors: [.clear, .black.opacity(0.5)],
                center: .center,
                startRadius: metrics.cardHeight * 0.3,
                endRadius: metrics.cardWidth * 0.75
            )
            LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct HomeHeroRecommendationDetail: View {
    let model: HomeHeroRecommendationModel
    let content: HomeHeroRecommendationContent
    @State private var refreshRound = 0
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(CoverTintProvider.self) private var tintProvider
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var title: String {
        content == .albums ? String(localized: "home_hero_album_picks") : model.theme.title
    }

    private var collectionArtwork: [Song] {
        var seen = Set<String>()
        let candidates = content == .albums
            ? model.albums.compactMap { library.songs(forAlbum: $0.id).first } : model.songs
        let distinct = candidates.filter { song in
            guard let cover = song.coverArtFileName, !cover.isEmpty else { return false }
            return seen.insert(cover).inserted
        }
        return Array((distinct.isEmpty ? candidates : distinct).prefix(4))
    }

    private var coverTint: Color {
        collectionArtwork.first.flatMap { tintProvider.tint(forSongID: $0.id) } ?? .accentColor
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                collectionHeader
                if content == .albums, !model.albums.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 16)], spacing: 20) {
                        ForEach(model.albums) { album in
                            NavigationLink(value: album) { AlbumCardView(album: album, showsSongCount: true) }
                                .buttonStyle(.plain)
                                .mediaZoomSource(.album, id: album.id)
                                .accessibilityIdentifier("home.hero.recommendation.albumDetail.\(album.id)")
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 20)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.songs.enumerated()), id: \.element.id) { index, song in
                            songRow(song, index: index)
                            if index < model.songs.count - 1 {
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 20)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("home.hero.recommendation.detail")
        .modifier(HomeHeroRecommendationRefresh(models: [model], contentKind: content, isEnabled: true, refreshRound: refreshRound))
        .task(id: collectionArtwork.first?.id) { tintProvider.prepare(Array(collectionArtwork.prefix(1))) }
    }

    private var collectionHeader: some View {
        VStack(alignment: .leading, spacing: 20) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 18))
            layout {
                HomeHeroRecommendationArtwork(songs: collectionArtwork, side: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: coverTint.opacity(0.16), radius: 12, y: 5)
                VStack(alignment: .leading, spacing: 8) {
                    Text(Date(), format: .dateTime.month().day())
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(verbatim: title)
                        .font(.title.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("home.hero.recommendation.title")
                    Text(String(format: String(localized: content == .albums
                        ? "home_hero_album_count_format" : "home_hero_song_count_format"),
                                content == .albums ? model.albums.count : model.songs.count))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            let controls = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 10))
                : AnyLayout(HStackLayout(spacing: 12))
            controls {
                Button {
                    let songs = content == .albums && !model.albums.isEmpty
                        ? model.albums.flatMap { library.songs(forAlbum: $0.id).filteredPlayable() }
                        : model.songs
                    play(songs, startingAt: 0)
                } label: {
                    Label("play_all", systemImage: "play.fill")
                        .font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .prominentLabelOnAccent()
                .controlSize(.large)
                .disabled(model.songs.isEmpty)
                .accessibilityIdentifier("home.hero.recommendation.playAll")

                Button { refreshRound += 1 } label: {
                    HStack(spacing: 8) {
                        if model.isLoading { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                        Text("home_hero_refresh")
                    }
                    .font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.isLoading)
                .accessibilityIdentifier("home.hero.recommendation.refresh")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .background {
            LinearGradient(colors: [coverTint.opacity(colorScheme == .dark ? 0.20 : 0.10), .clear],
                           startPoint: .topLeading, endPoint: .bottom)
        }
    }

    private func songRow(_ song: Song, index: Int) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        return HStack(spacing: 0) {
            Button { play(model.songs, startingAt: index) } label: {
                HStack(spacing: 12) {
                    HomeHeroRecommendationArtwork(songs: [song], side: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            SongRowTrackNumber(number: index + 1, largestNumber: model.songs.count)
                            Text(verbatim: song.title)
                                .font(.body.weight(.medium))
                                .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        }
                        if let artist = song.artistName, !artist.isEmpty {
                            Text(verbatim: artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if song.duration.isFinite, song.duration > 0, !dynamicTypeSize.isAccessibilitySize {
                        Text(song.duration.formattedDuration)
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.hero.recommendation.song.\(song.id)")
            .contextMenu { queueActions(for: song) }
            Menu { queueActions(for: song) } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold)).foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("more"))
            .accessibilityIdentifier("home.hero.recommendation.more.\(song.id)")
        }
    }

    @ViewBuilder
    private func queueActions(for song: Song) -> some View {
        Button { _ = player.insertNextInQueue([song]) } label: { Label("insert_next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.appendToQueue([song]) } label: { Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
    }

    private func play(_ songs: [Song], startingAt index: Int) {
        guard songs.indices.contains(index) else { return }
        player.shuffleEnabled = false
        Task { await player.play(queue: songs, startingAt: index) }
    }
}
#endif
