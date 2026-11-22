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
        return prepared && !importing && (style == .carousel || current.cover != .photo || current.photo != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("home_hero_style_title") {
                    ForEach([HomeHeroStyle.featured, .carousel, .medium], id: \.self) { option in
                        Button { style = option } label: {
                            HStack(spacing: 14) {
                                Image(systemName: option == .carousel ? "rectangle.on.rectangle.angled" : "rectangle.portrait.fill")
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
                    Section {
                        HomeHeroCardAppearanceFields(
                            appearance: style == .medium ? $appearances.medium : $appearances.large,
                            importing: $importing
                        )
                        .id(style)
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
        let pool = theme.candidatePool(from: previewSongs, minimumCount: HomeHeroRecommendationPolicy.songCount(songCount))
        let ids = HomeHeroRecommendationPolicy.candidates(
            rankedIDs: pool.map(\.id), day: HomeHeroRecommendationPolicy.dayStamp(Date()) + theme.rotationOffset,
            round: 0, excluding: [], limit: HomeHeroRecommendationPolicy.songCount(songCount)
        )
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    private var shownAlbums: [Album] {
        if isInteractive { return catalog.albums.albums }
        var seen = Set<String>()
        return Array(previewSongs.compactMap { song -> Album? in
            guard let id = song.albumID, seen.insert(id).inserted else { return nil }
            return library.visibleAlbum(id: id)
        }.prefix(HomeHeroRecommendationPolicy.albumCount(albumCount)))
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
                                        metrics: metrics, songs: Array(songs.prefix(4)), title: theme.title,
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
        let layout = metrics.isCompact ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        let coverSide = metrics.artworkSide * (theme == nil ? 0.87 : 0.68)
        return layout {
            Group {
                if appearance.cover == .hidden {
                    Color.clear
                } else if appearance.cover == .photo, let photo = appearance.photo {
                    Image(uiImage: photo.image).resizable().scaledToFill()
                } else {
                    HomeHeroRecommendationArtwork(
                        songs: appearance.cover == .collage ? songs : Array(songs.prefix(1)),
                        side: coverSide, showsPlaceholder: false
                    )
                }
            }
            .frame(width: coverSide, height: coverSide)
            .clipShape(.rect(cornerRadius: 8))
            .shadow(color: .black.opacity(0.24), radius: 7, y: 3)
            .frame(width: metrics.artworkSide, height: metrics.artworkSide)
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title).font(.headline).foregroundStyle(.white).lineLimit(2)
                if isLoading {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text(verbatim: subtitle).font(.subheadline).foregroundStyle(.white).lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: metrics.isCompact ? max(metrics.artworkSide, captionHeight) : captionHeight)
        }
        .frame(width: metrics.cardWidth)
        .background {
            Group {
                if let flowPalettes = coverFlowPalettes {
                    // 没有封面可看:拿里面几首歌的封面模糊了慢慢流动(像 Apple Music 的动态背景)。
                    CoverFlowBackdrop(
                        palettes: flowPalettes, songs: songs,
                        isAnimating: focused && appearance.backdrop.resolved(medium: medium, album: theme == nil) != .gradient
                    )
                } else if appearance.backdrop.resolved(medium: medium, album: theme == nil) == .flow, followsArtwork {
                    CoverFlowBackdrop(palettes: [palette], songs: songs, isAnimating: focused)
                } else {
                    HomeHeroCardBackdrop(style: appearance.backdrop.resolved(medium: medium, album: theme == nil),
                                         palette: palette, focused: focused, reduceMotion: reduceMotion)
                }
            }
                .overlay {
                    LinearGradient(stops: [.init(color: .clear, location: 0.15),
                                           .init(color: .black.opacity(0.60), location: metrics.isCompact ? 0.46 : 0.72),
                                           .init(color: .black.opacity(0.67), location: 1)],
                                   startPoint: metrics.isCompact ? .leading : .top,
                                   endPoint: metrics.isCompact ? .trailing : .bottom)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.06), lineWidth: 0.5) }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .task(id: songs.map(\.id)) {
            // 封面的颜色要第一首的;没有封面时底色从几首歌里一起取,所以几首都先取好。
            guard !appearance.customColors else { return }
            tintProvider.prepare(songs)
        }
    }

    /// 卡片上没有封面可看的时候(封面设成不显示,或者第一首根本没有封面),底色改从里面几首歌的封面取。
    /// 一首有颜色的封面都没有时返回 nil,照旧用这一类的预设色。自选颜色、自选照片时不管。
    private var coverFlowPalettes: [ImmersiveArtworkPalette]? {
        guard !appearance.customColors, !(appearance.cover == .photo && appearance.photo != nil) else { return nil }
        let firstHasArtwork = songs.first.map { song in
            tintProvider.palette(forSongID: song.id) != nil
                || tintProvider.hasAnalyzedColorlessArtwork(forSongID: song.id)
        } ?? false
        guard appearance.cover == .hidden || !firstHasArtwork else { return nil }
        let palettes = songs.compactMap { tintProvider.palette(forSongID: $0.id) }
        return palettes.isEmpty ? nil : palettes
    }

    /// 流动背景跟着封面走:自选颜色、自选照片时还是按选的颜色画渐变。
    private var followsArtwork: Bool {
        !appearance.customColors && !(appearance.cover == .photo && appearance.photo != nil)
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
        CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: size, cornerRadius: 0,
                          sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat,
                          showsPlaceholder: showsPlaceholder)
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
