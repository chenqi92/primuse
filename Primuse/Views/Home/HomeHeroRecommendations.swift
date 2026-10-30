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
                }
            }
            .environment(\.editMode, .constant(.inactive))
            .navigationTitle("home_hero_section_title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") {
                        savedContent = content
                        savedSongCount = songCount
                        savedAlbumCount = albumCount
                        savedStyle = style
                        dismiss()
                    }
                    .accessibilityIdentifier("home.hero.settings.done")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
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
        VStack(alignment: .leading, spacing: 12) {
            Text("home_hero_daily_title").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 20)
            if isInteractive && (library.musicSongs.isEmpty || models.allSatisfy({ $0.revision > 0 && !$0.isLoading && $0.songs.isEmpty })) {
                ContentUnavailableView("library_recommendations_empty_title", systemImage: "sparkles")
            } else if content == .albums && shownAlbums.isEmpty {
                if !isInteractive || catalog.albums.isLoading || catalog.albums.revision == 0 {
                    HomeHeroFeaturedSkeleton(metrics: metrics)
                } else {
                    ContentUnavailableView("library_recommendations_empty_title", systemImage: "sparkles")
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        if content == .albums {
                            ForEach(shownAlbums) { album in
                                NavigationLink(value: HomeHeroRecommendationDestination.albums) {
                                    HomeHeroRecommendationCard(
                                        metrics: metrics, songs: Array(library.songs(forAlbum: album.id).prefix(1)),
                                        title: album.title, subtitle: album.artistName ?? ""
                                    )
                                }
                                .accessibilityIdentifier("home.hero.recommendation.album.\(album.id)")
                            }
                        } else {
                            ForEach(HomeHeroRecommendationTheme.allCases, id: \.self) { theme in
                                let songs = shownSongs(for: theme)
                                NavigationLink(value: HomeHeroRecommendationDestination.songs(theme)) {
                                    HomeHeroRecommendationCard(
                                        metrics: metrics, songs: Array(songs.prefix(4)), title: theme.title,
                                        subtitle: String(format: String(localized: "home_hero_song_count_format"), songs.count),
                                        isLoading: songs.isEmpty && catalog.collection(theme).revision == 0
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
                .pmHorizontalClipExtendingUnderVerticalBar()
                .accessibilityIdentifier("home.hero.featured.cards")
            }
        }
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
        "\(models.map { $0.theme.rawValue }.joined(separator: ","))#\(day)#\(refreshRound)#\(contentKind.rawValue)#\(songCount)#\(albumCount)#\(library.musicSongs.count)#\(library.musicSongsRevision)#\(intelligence.settingsStore.revision)#\(intelligence.regionAvailability.revision)"
    }

    func body(content: Content) -> some View {
        content
            .task(id: refreshKey) {
                guard isEnabled else { return }
                let force = refreshRound != handledRefreshRound
                handledRefreshRound = refreshRound
                for model in models {
                    guard !Task.isCancelled else { return }
                    await model.refresh(
                        configuration: .init(content: contentKind, songCount: songCount, albumCount: albumCount),
                        library: library, intelligence: intelligence, force: force
                    )
                }
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
    @ScaledMetric(relativeTo: .body) private var captionHeight: CGFloat = 84
    @Environment(CoverTintProvider.self) private var tintProvider
    @Environment(\.self) private var environment

    var body: some View {
        let tint = songs.first.flatMap { tintProvider.tint(forSongID: $0.id) } ?? Color(red: 0.24, green: 0.28, blue: 0.34)
        let resolved = tint.resolve(in: environment)
        let background = ThemeAccentContrastPolicy.legible(.init(
            red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue)
        ), for: .light)
        let layout = metrics.isCompact ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        return layout {
            HomeHeroRecommendationArtwork(songs: songs, side: metrics.artworkSide)
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
        .background(Color(.sRGB, red: background.red, green: background.green, blue: background.blue))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18).stroke(.primary.opacity(0.06), lineWidth: 0.5) }
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .task(id: songs.first?.id) { tintProvider.prepare(Array(songs.prefix(1))) }
    }
}

private struct HomeHeroRecommendationArtwork: View {
    let songs: [Song]
    let side: CGFloat

    var body: some View {
        Group {
            if songs.count >= 4 {
                VStack(spacing: 1) {
                    HStack(spacing: 1) { artwork(songs[0], size: (side - 1) / 2); artwork(songs[1], size: (side - 1) / 2) }
                    HStack(spacing: 1) { artwork(songs[2], size: (side - 1) / 2); artwork(songs[3], size: (side - 1) / 2) }
                }
            } else if let song = songs.first {
                artwork(song, size: side)
            } else {
                Rectangle().fill(.quaternary).overlay { Image(systemName: "music.note").font(.largeTitle) }
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .accessibilityHidden(true)
    }

    private func artwork(_ song: Song, size: CGFloat) -> some View {
        CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: size, cornerRadius: 0,
                          sourceID: song.sourceID, filePath: song.filePath, fileFormat: song.fileFormat)
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
        content == .albums ? String(localized: "home_hero_daily_title") : model.theme.title
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
                    SongRowTrackNumber(number: index + 1, largestNumber: model.songs.count)
                        .font(.body).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: song.title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
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
