#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 首页 — Top Shelf hero + 三行横向 shelf(对应 tvos.jsx 的 TVHomeArtboard)。
struct TVHomeView: View {
    @Environment(TVStore.self) private var store
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppThemePreferences.accentHexKey)
    private var accentHex = AppThemePreferences.defaultAccentHex
    @AppStorage(AppThemePreferences.coverDrivenAmbientKey)
    private var coverDrivenAmbient = AppThemePreferences.defaultCoverDrivenAmbient
    @AppStorage("primuse.ai.recommendationScene.v1")
    private var recommendationSceneRawValue = AIRecommendationScene.automatic.rawValue
    @State private var recommendationCandidates: [Song] = []
    @State private var aiRecommendation = AIRecommendationViewModel()
    @State private var recommendationHistoryRevision = 0
    @State private var recommendationClockRevision = 0
    @State private var showsRadioAdd = false
    /// 这次「添加电台」是从空首页的按钮打开的:加上第一个台后空态整块换成了电台排,
    /// 原来的按钮不在了,关闭时由这里把焦点放到第一张电台卡片上。
    @State private var radioAddFromEmptyState = false
    @State private var radioDeleteRequest: TVRadioDeleteRequest?
    @FocusState private var focusedRadioID: String?
    var openPlayer: () -> Void = {}
    /// 「全部电台」卡片:切到资料库的「电台」。
    var openRadioLibrary: () -> Void = {}
    /// 电台的添加 / 重命名 / 删除确认弹层。只报弹层在不在,关闭后的焦点由这里和系统负责,
    /// TVRoot 不改焦点(它的关闭处理会把首页的焦点送回顶栏)。
    var onModalPresentationChanged: (Bool) -> Void = { _ in }

    /// 首页电台那一排最多放几个台。台多的时候(音乐源镜像动辄上千个)整排一次性构造
    /// 会很卡,其余的去资料库「电台」里看,那里是懒加载的网格。
    static let homeRadioLimit = 20

    #if DEBUG
    /// 截图用的 `radioAdd` 只在首次进首页时打开一次。
    @MainActor private static var didOpenDebugRadioAdd = false
    #endif

    private var candidateAlbum: TVAlbum? {
        store.albums.first(where: { !store.songs(forAlbum: $0.id).isEmpty })
            ?? store.albums.first
    }
    private var candidateAlbumSongs: [TVSong] {
        guard let candidateAlbum else { return [] }
        return store.songs(forAlbum: candidateAlbum.id)
    }
    private var heroContent: TVHomeHeroPolicy.Content {
        TVHomeHeroPolicy.content(
            totalSongCount: store.songs.count,
            albumCount: store.albums.count,
            candidateAlbumSongCount: candidateAlbumSongs.count
        )
    }
    private var heroAlbum: TVAlbum? {
        heroContent == .album ? candidateAlbum : nil
    }
    private var heroSong: TVSong? {
        heroContent == .song ? store.songs.first : nil
    }
    private var hero: TVAlbum {
        switch heroContent {
        case .album:
            return candidateAlbum ?? placeholderHero
        case .song:
            guard let song = store.songs.first else { return placeholderHero }
            let palette = store.artworkColors(forSongID: song.id)
            let title = song.title
            return TVAlbum(
                id: "song:\(song.id)",
                title: title,
                artist: song.artist,
                year: 0,
                tint: palette?.primary ?? TVColor.brand,
                tint2: palette?.secondary ?? Color(hex: "#1f3a5b"),
                glyph: title.isEmpty ? "♪" : String(title.prefix(1))
            )
        case .empty:
            return placeholderHero
        }
    }
    private var placeholderHero: TVAlbum {
        TVAlbum(id: "_", title: "Primuse", artist: "", year: 0,
                tint: TVColor.brand, tint2: .black, glyph: "♪")
    }
    private var heroSongs: [TVSong] {
        switch heroContent {
        case .album: return candidateAlbumSongs
        case .song: return store.songs
        case .empty: return []
        }
    }
    private var heroSongCount: Int {
        TVHomeHeroPolicy.displayedSongCount(
            for: heroContent,
            totalSongCount: store.songs.count,
            candidateAlbumSongCount: candidateAlbumSongs.count
        )
    }
    private var heroHeading: String {
        hero.artist.isEmpty ? hero.title : "\(hero.artist) · \(hero.title)"
    }
    private var heroSubtitle: String {
        var parts = [PMString("ext.tv.songsCount", heroSongCount)]
        let mins = (heroSongs.reduce(0) { $0 + $1.duration } / 60).finiteInt()
        if mins > 0 { parts.append(PMString("ext.tv.minCount", mins)) }
        if hero.year > 0 { parts.append("\(hero.year)") }
        if !hero.artist.isEmpty { parts.append(hero.artist) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        ZStack {
            // Top Shelf hero 背景
            TVAmbientBackdrop(tint: hero.tint, tint2: hero.tint2, strength: 0.7)
            GeometryReader { geo in
                ZStack {
                    RadialGradient(colors: [heroAmbientTint.opacity(0.4), .clear],
                                   center: UnitPoint(x: 0.8, y: 0.3),
                                   startRadius: 0, endRadius: geo.size.width * 0.5)
                    LinearGradient(colors: heroScrim,
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
            .ignoresSafeArea()

            if !store.hasRealLibrary && store.radioStations.isEmpty {
                TVEmptyState(
                    icon: "music.note.house",
                    title: PMString("ext.tv.home.empty"),
                    subtitle: PMString("ext.tv.home.emptyWithRadio"),
                    actionTitle: PMString("ext.tv.radio.add"),
                    // 没有曲库时删掉最后一个台,整页换成这个空态,删除后的焦点交给这颗按钮。
                    focusBinding: $focusedRadioID,
                    focusID: TVRadioFocusID.add,
                    action: {
                        radioAddFromEmptyState = true
                        showsRadioAdd = true
                    }
                ).tvPage()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 30) {
                    if store.hasRealLibrary {
                        heroZone
                        if !store.recentlyPlayed.isEmpty {
                            TVRow(label: PMString("ext.tv.home.recentlyPlayed")) {
                                ForEach(store.recentlyPlayed) { song in
                                    TVSongCard(song: song, action: openPlayer)
                                }
                            }
                        } else if heroAlbum == nil {
                            TVRow(label: PMString("ext.tv.nav.library")) {
                                ForEach(Array(store.songs.prefix(15))) { song in
                                    TVSongCard(song: song, action: openPlayer)
                                }
                            }
                        }
                    }
                    // 有曲库没电台时也留着这一排,末尾的卡片就是电视端添加电台的入口。
                    TVRow(
                        label: PMString("ext.tv.radio.title"),
                        sub: store.radioStations.isEmpty
                            ? nil
                            : TVRadioText.stationCount(store.radioStations.count)
                    ) {
                        let homeStations = homeRadioStations
                        // 长按挪动只在这一排里算,台不会被挪出首页。
                        let homeStationIDs = homeStations.map(\.id)
                        ForEach(homeStations) { station in
                            TVRadioStationCard(
                                station: station,
                                siblingIDs: homeStationIDs,
                                focusBinding: $focusedRadioID,
                                onDelete: {
                                    radioDeleteRequest = TVRadioDeleteRequest(station: $0, siblingIDs: homeStationIDs)
                                },
                                onModalPresentationChanged: onModalPresentationChanged,
                                action: openPlayer
                            )
                        }
                        if store.radioStations.count > Self.homeRadioLimit {
                            TVRadioAllStationsCard(count: store.radioStations.count, action: openRadioLibrary)
                        }
                        TVRadioAddCard(focusBinding: $focusedRadioID) { showsRadioAdd = true }
                    }
                    if !store.recentlyAddedAlbums.isEmpty {
                        TVRow(label: PMString("ext.tv.home.recentlyAdded")) {
                            ForEach(store.recentlyAddedAlbums) { album in
                                TVAlbumCard(album: album, action: openPlayer)
                            }
                        }
                    }
                    if intelligence.shouldShowRemoteRecommendations,
                       !recommendationCandidates.isEmpty {
                        intelligentRecommendationSection
                    } else if !store.recommended.isEmpty {
                        TVRow(label: PMString("ext.tv.home.madeForYou")) {
                            ForEach(Array(store.recommended.enumerated()), id: \.offset) { _, album in
                                TVAlbumCard(album: album, action: openPlayer)
                            }
                        }
                    }
                }
                .tvPage()
            }
            }
        }
        .fullScreenCover(isPresented: $showsRadioAdd, onDismiss: focusRadioRowAfterAdd) {
            TVRadioAddView().environment(store)
        }
        .onChange(of: showsRadioAdd) { _, shows in onModalPresentationChanged(shows) }
        .onDisappear {
            if showsRadioAdd { onModalPresentationChanged(false) }
        }
        // 删掉一张后焦点交给同一排的邻居;这一排删空了就交给「添加电台」卡片,
        // 没有曲库时则是整页空态上的「添加电台」按钮。
        .modifier(TVRadioDeleteConfirmationHost(
            request: $radioDeleteRequest,
            focus: $focusedRadioID,
            currentIDs: { homeRadioStations.map(\.id) },
            store: store,
            onPresentationChanged: onModalPresentationChanged
        ))
        #if DEBUG
        .onAppear {
            if TVDebugLaunch.screen == "radioAdd", !Self.didOpenDebugRadioAdd {
                Self.didOpenDebugRadioAdd = true
                showsRadioAdd = true
            }
        }
        #endif
        .task(id: recommendationCandidateRefreshKey) {
            guard intelligence.settingsStore.recommendationsEnabled else {
                recommendationCandidates = []
                return
            }
            recommendationCandidates = await store.recommendationCandidates(limit: 12)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primusePlaybackHistoryDidChange)) { _ in
            recommendationHistoryRevision &+= 1
        }
        .onReceive(
            Timer.publish(every: 15 * 60, on: .main, in: .common).autoconnect()
        ) { _ in
            recommendationClockRevision &+= 1
        }
    }

    private var homeRadioStations: [RadioStation] {
        Array(store.radioStations.prefix(Self.homeRadioLimit))
    }

    private func focusRadioRowAfterAdd() {
        guard radioAddFromEmptyState else { return }
        radioAddFromEmptyState = false
        guard let first = store.radioStations.first?.id else { return }
        Task { @MainActor in
            await Task.yield()
            focusedRadioID = first
        }
    }

    private var recommendationScene: AIRecommendationScene {
        AIRecommendationScene(rawValue: recommendationSceneRawValue) ?? .automatic
    }

    private var recommendationCandidateRefreshKey: String {
        "\(store.recommendationRevision)#\(recommendationHistoryRevision)#"
            + "\(intelligence.settingsStore.recommendationsEnabled)"
    }

    private var recommendationRefreshKey: String {
        return [
            recommendationSceneRawValue,
            String(intelligence.settingsStore.revision),
            String(intelligence.regionAvailability.revision),
            String(recommendationHistoryRevision),
            String(recommendationClockRevision),
            recommendationCandidates.map(\.id).joined(separator: "|"),
        ].joined(separator: "#")
    }

    private var displayedRecommendationSongs: [TVSong] {
        aiRecommendation.orderedSongs(from: recommendationCandidates).compactMap {
            store.song($0.id)
        }
    }

    private var intelligentRecommendationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(AIRecommendationScene.allCases, id: \.self) { scene in
                        recommendationSceneButton(scene)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            if let summary = aiRecommendation.summaryText {
                Text(summary)
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(2)
                    .padding(.horizontal, 20)
            }
            TVRow(
                label: PMString("ai_recommendation_home_title"),
                sub: aiRecommendation.statusText
            ) {
                ForEach(displayedRecommendationSongs) { song in
                    TVSongCard(
                        song: song,
                        reason: aiRecommendation.reason(for: song.id) ?? "",
                        action: openPlayer
                    )
                }
            }
        }
        .task(id: recommendationRefreshKey) {
            await aiRecommendation.refresh(
                scene: recommendationScene,
                candidates: recommendationCandidates,
                using: intelligence
            )
        }
    }

    private func recommendationSceneButton(_ scene: AIRecommendationScene) -> some View {
        let selected = recommendationScene == scene
        return TVFocusButton(
            radius: 14,
            scale: 1.05,
            lift: 4,
            action: { recommendationSceneRawValue = scene.rawValue }
        ) { focused in
            Text(scene.localizedName)
                .tvFont(.caption, weight: .semibold)
                .foregroundStyle(selected ? TVColor.onBrand : TVColor.text)
                .padding(.horizontal, 24)
                .padding(.vertical, 13)
                .background(
                    selected ? TVColor.brand : (focused ? TVColor.surfaceStrong : TVColor.surface),
                    in: Capsule()
                )
        }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var heroZone: some View {
        HStack(alignment: .center, spacing: 64) {
            VStack(alignment: .leading, spacing: 0) {
                TVEyebrow(text: PMString("ext.tv.home.tonightsPick"))
                Text(heroHeading)
                    .tvFont(.heroTitle)
                    .tracking(-0.8)
                    .foregroundStyle(TVColor.text).lineLimit(2)
                    .padding(.top, 16)
                Text(heroSubtitle)
                    .tvFont(.caption).foregroundStyle(TVColor.textMuted)
                    .lineLimit(2).frame(maxWidth: 760, alignment: .leading)
                    .padding(.top, 14)
                HStack(spacing: 16) {
                    TVPillButton(title: PMString("ext.tv.home.playAll"), systemImage: "play.fill", style: .solid,
                                 action: { playHero(shuffle: false) })
                    TVPillButton(title: PMString("ext.tv.home.shuffle"), systemImage: "shuffle",
                                 action: { playHero(shuffle: true) })
                }
                .padding(.top, 32)
            }
            Spacer(minLength: 0)
            heroArtwork
                .shadow(color: .black.opacity(0.5), radius: 36, y: 18)
        }
        .frame(minHeight: 420)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var heroArtwork: some View {
        if let heroAlbum {
            TVArtworkView(album: heroAlbum, size: 380, radius: 18)
        } else if let heroSong {
            TVArtworkView(
                coverKey: "",
                artist: heroSong.artist,
                album: "",
                songID: heroSong.id,
                coverRef: heroSong.coverRef,
                tint: hero.tint,
                tint2: hero.tint2,
                glyph: hero.glyph,
                size: 380,
                radius: 18
            )
        } else {
            TVMusicPlaceholder(
                tint: hero.tint,
                tint2: hero.tint2,
                size: 380,
                radius: 18
            )
        }
    }

    private var heroScrim: [Color] {
        if colorScheme == .dark {
            return [.black.opacity(0.84), .black.opacity(0.66), .black.opacity(0.16), .clear]
        }
        return [TVColor.bg.opacity(0.98), TVColor.bg.opacity(0.82),
                TVColor.bg.opacity(0.26), .clear]
    }

    private var heroAmbientTint: Color {
        coverDrivenAmbient ? hero.tint : TVColor.brand(hex: accentHex)
    }

    private func playHero(shuffle: Bool) {
        if store.playAll(shuffle: shuffle) { openPlayer() }
    }
}
#endif
