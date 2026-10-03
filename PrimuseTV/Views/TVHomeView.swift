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
    @AppStorage(TVHomeSectionConfiguration.storageKey) private var homeSectionsRawValue = ""
    @State private var recommendationCandidates: [Song] = []
    @State private var aiRecommendation = AIRecommendationViewModel()
    @State private var recommendationHistoryRevision = 0
    @State private var recommendationClockRevision = 0
    @State private var showsRadioAdd = false
    /// 这次「添加电台」是从空首页的按钮打开的:加上第一个台后空态整块换成了电台排,
    /// 原来的按钮不在了,关闭时由这里把焦点放到第一张电台卡片上。
    @State private var radioAddFromEmptyState = false
    @State private var radioDeleteRequest: TVRadioDeleteRequest?
    @State private var selectedAlbum: TVAlbum?
    @FocusState private var focusedRadioID: String?
    /// 电台以外的卡片(歌曲 / 专辑),值是 `cardID(_:_:)`。播放页回来时据此放回焦点。
    @FocusState private var focusedCardID: String?
    /// 从播放页回来重开专辑页时,焦点要落到的那一首。
    @State private var reopenedAlbumSongID: String?
    /// 从播放页按 Menu 回来时放回哪张卡片,由 TVRoot 持有(首页会整页移出视图树)。
    var browseMemory = TVHomeBrowseMemory()
    /// 记住的卡片已经不在了:焦点照旧回顶栏。
    var onReturnToTabs: () -> Void = {}
    var openPlayer: () -> Void = {}
    /// 「全部电台」卡片:切到「电台」一级页。
    var openRadioLibrary: () -> Void = {}
    /// 电台的添加 / 重命名 / 删除确认弹层。只报弹层在不在,关闭后的焦点由这里和系统负责,
    /// TVRoot 不改焦点(它的关闭处理会把首页的焦点送回顶栏)。
    var onModalPresentationChanged: (Bool) -> Void = { _ in }

    /// 首页电台那一排最多放几个台。台多的时候(音乐源镜像动辄上千个)整排一次性构造
    /// 会很卡,其余的去「电台」页看,那里是懒加载的网格。
    static let homeRadioLimit = 20

    #if DEBUG
    /// 截图用的 `radioAdd` 只在首次进首页时打开一次。
    @MainActor private static var didOpenDebugRadioAdd = false
    #endif

    /// 主视觉放此刻情景推荐的那张专辑(与手机、Mac 首页同源);推荐还没算出来时
    /// 先放第一张有歌的专辑。
    private var albumPick: AlbumRecommendation? {
        guard let pick = AlbumRecommendationService.shared.currentPick,
              !store.songIDs(forAlbum: pick.albumID).isEmpty else { return nil }
        return pick
    }
    private var candidateAlbum: TVAlbum? {
        if let pick = albumPick, let album = store.album(pick.albumID) { return album }
        return store.albums.first(where: { !store.songIDs(forAlbum: $0.id).isEmpty })
            ?? store.albums.first
    }
    private var candidateAlbumSongIDs: [String] {
        guard let candidateAlbum else { return [] }
        return store.songIDs(forAlbum: candidateAlbum.id)
    }
    private var heroContent: TVHomeHeroPolicy.Content {
        TVHomeHeroPolicy.content(
            totalSongCount: store.songs.count,
            albumCount: store.albums.count,
            candidateAlbumSongCount: candidateAlbumSongIDs.count
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
    /// 整库模式直接在曲库原始数组上求和,不为整库逐首转换界面值。
    private var heroTotalDuration: Double {
        switch heroContent {
        case .album:
            return candidateAlbumSongIDs.reduce(0) { $0 + (store.library.visibleSong(id: $1)?.duration ?? 0) }
        case .song: return store.songs.source.reduce(0) { $0 + $1.duration }
        case .empty: return 0
        }
    }
    private var heroSongCount: Int {
        TVHomeHeroPolicy.displayedSongCount(
            for: heroContent,
            totalSongCount: store.songs.count,
            candidateAlbumSongCount: candidateAlbumSongIDs.count
        )
    }
    private var heroHeading: String {
        hero.artist.isEmpty ? hero.title : "\(hero.artist) · \(hero.title)"
    }
    /// 推荐理由;只有主视觉是推荐的专辑时才有。
    private var heroReason: String? {
        guard heroContent == .album, let pick = albumPick, pick.albumID == candidateAlbum?.id else { return nil }
        return pick.reason.text
    }
    private var heroEyebrow: String {
        guard heroContent == .album, albumPick != nil,
              let moment = AlbumRecommendationService.shared.moment else {
            return PMString("ext.tv.home.tonightsPick")
        }
        return moment.title
    }
    private var heroSubtitle: String {
        var parts = [PMString("ext.tv.songsCount", heroSongCount)]
        let mins = (heroTotalDuration / 60).finiteInt()
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

            if !store.hasRealLibrary && (!store.library.isReady || store.isPreparingLibraryContent) {
                ProgressView(String(localized: "library_quick_access_loading"))
                    .tvFont(.caption)
            } else if !store.hasRealLibrary && store.radioStations.isEmpty {
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
                    // 顺序与显隐在设置「首页」里调(`TVHomeSectionConfiguration`)。
                    ForEach(homeSections.visibleSections, id: \.self) { section in
                        homeSection(section)
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
        .modifier(TVAlbumDetailPresenter(
            album: $selectedAlbum,
            openPlayer: openPlayer,
            onPresentationChanged: onModalPresentationChanged,
            initialFocusSongID: reopenedAlbumSongID,
            onPlaybackStarted: { albumID, songID in
                browseMemory.albumDetailID = albumID
                browseMemory.albumDetailSongID = songID
            },
            onClosed: closeAlbumDetail
        ))
        .onAppear(perform: restoreAfterPlayer)
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
        .task(id: store.libraryBrowseRevision) {
            AlbumRecommendationService.shared.refresh(library: store.library)
            // 居家场景的点亮;场景那一排还没点亮时是空的,挂在它自己身上的任务不会跑。
            ListeningIntentService.shared.refresh(library: store.library)
        }
        .task(id: recommendationCandidateRefreshKey) {
            // 首页关掉了推荐那一排就不必再挑候选。
            guard intelligence.settingsStore.recommendationsEnabled,
                  homeSections.isShown(.recommendations) else {
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

    private var homeSections: TVHomeSectionConfiguration { .decode(homeSectionsRawValue) }

    /// 首页的一排。此刻没内容的排什么也不画(不占间距)。
    @ViewBuilder
    private func homeSection(_ section: TVHomeSection) -> some View {
        switch section {
        case .albumPick:
            if store.hasRealLibrary { heroZone }
        case .homeScenes:
            if store.hasRealLibrary {
                TVHomeSceneRow(
                    focusBinding: $focusedCardID,
                    cardID: { cardID("scene", $0.rawValue) },
                    onStarted: { playerOpener($0)() }
                )
            }
        case .recommendations:
            if intelligence.shouldShowRemoteRecommendations,
               !recommendationCandidates.isEmpty {
                intelligentRecommendationSection
            } else if !store.recommended.isEmpty {
                TVRow(label: PMString("ext.tv.home.madeForYou")) {
                    ForEach(Array(store.recommended.enumerated()), id: \.offset) { _, album in
                        albumCard(album, row: "made")
                    }
                }
            }
        case .recentlyPlayed:
            if store.hasRealLibrary {
                if !store.recentlyPlayed.isEmpty {
                    TVRow(label: PMString("ext.tv.home.recentlyPlayed")) {
                        ForEach(store.recentlyPlayed) { song in
                            TVSongCard(song: song, action: playerOpener(cardID("recent", song.id)))
                                .focused($focusedCardID, equals: cardID("recent", song.id))
                        }
                    }
                } else if heroAlbum == nil {
                    TVRow(label: PMString("ext.tv.nav.library")) {
                        ForEach(Array(store.songs.prefix(15))) { song in
                            TVSongCard(song: song, action: playerOpener(cardID("songs", song.id)))
                                .focused($focusedCardID, equals: cardID("songs", song.id))
                        }
                    }
                }
            }
        case .likedAlbums:
            if store.hasRealLibrary {
                let likedAlbums = store.likedAlbums
                if !likedAlbums.isEmpty {
                    TVRow(label: String(localized: "library_liked_albums_title")) {
                        ForEach(likedAlbums) { album in
                            albumCard(album, row: "liked")
                        }
                    }
                }
            }
        case .recentlyAdded:
            if !store.recentlyAddedAlbums.isEmpty {
                TVRow(label: PMString("ext.tv.home.recentlyAdded")) {
                    ForEach(store.recentlyAddedAlbums) { album in
                        albumCard(album, row: "added")
                    }
                }
            }
        case .radio:
            radioRow
        }
    }

    /// 有曲库没电台时也留着这一排,末尾的卡片就是电视端添加电台的入口。
    private var radioRow: some View {
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
                    action: playerOpener(cardID("radio", station.id))
                )
            }
            if store.radioStations.count > Self.homeRadioLimit {
                TVRadioAllStationsCard(count: store.radioStations.count, action: openRadioLibrary)
            }
            TVRadioAddCard(focusBinding: $focusedRadioID) { showsRadioAdd = true }
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

    // MARK: - 从播放页回来

    /// 同一张专辑 / 同一首歌会出现在好几排里,焦点 id 带上所在的那一排。
    private func cardID(_ row: String, _ id: String) -> String { row + ":" + id }

    /// 卡片开始播放:先记下是哪一张,播放页按 Menu 回来时焦点回到它。
    private func playerOpener(_ cardID: String) -> () -> Void {
        { [browseMemory, openPlayer] in
            browseMemory.cardID = cardID
            openPlayer()
        }
    }

    /// 按下专辑卡片先进专辑页;在专辑页里起播,回来时先重开专辑页,再回这张卡片。
    private func albumCard(_ album: TVAlbum, row: String) -> some View {
        let id = cardID(row, album.id)
        return TVAlbumCard(album: album, action: playerOpener(id),
                           onOpen: {
                               browseMemory.cardID = id
                               selectedAlbum = album
                           },
                           focusBinding: $focusedCardID, focusID: id)
    }

    /// 首页出现:只有从播放页按 Menu 回来的那一次才恢复;经顶栏换页回来把记的全忘掉。
    private func restoreAfterPlayer() {
        guard browseMemory.restoresAfterPlayer else {
            browseMemory.forget()
            return
        }
        browseMemory.restoresAfterPlayer = false
        if let albumID = browseMemory.albumDetailID, let album = store.album(albumID) {
            reopenedAlbumSongID = browseMemory.albumDetailSongID
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { selectedAlbum = album }
            return
        }
        browseMemory.albumDetailID = nil
        browseMemory.albumDetailSongID = nil
        focusRememberedCard()
    }

    /// 专辑页被 Menu 关掉(不是因为起播):焦点回到打开它的那张卡片。
    private func closeAlbumDetail() {
        browseMemory.albumDetailID = nil
        browseMemory.albumDetailSongID = nil
        reopenedAlbumSongID = nil
        focusRememberedCard()
    }

    /// 首页刚建出来、或专辑页刚收起时设的焦点可能被吞掉,没落上就再设一次;
    /// 那张卡片已经不在(比如那张专辑被删了)就交回顶栏。用掉即忘。
    private func focusRememberedCard() {
        guard let target = browseMemory.cardID else { return }
        browseMemory.cardID = nil
        let radioPrefix = cardID("radio", "")
        // 电台卡片用的是电台那一排自己的焦点绑定(删除后交给邻居也靠它)。
        let radioID = target.hasPrefix(radioPrefix) ? String(target.dropFirst(radioPrefix.count)) : nil
        Task { @MainActor in
            for attempt in 0..<3 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
                if let radioID { focusedRadioID = radioID } else { focusedCardID = target }
                try? await Task.sleep(nanoseconds: 100_000_000)
                if radioID.map({ focusedRadioID == $0 }) ?? (focusedCardID == target) { break }
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            let landed = radioID.map { focusedRadioID == $0 } ?? (focusedCardID == target)
            #if DEBUG
            plog("TV home return focus=\(landed ? "card" : "other") target=\(target.prefix(24))")
            #endif
            if !landed, focusedCardID == nil, focusedRadioID == nil { onReturnToTabs() }
        }
    }

    private var recommendationScene: AIRecommendationScene {
        AIRecommendationScene(rawValue: recommendationSceneRawValue) ?? .automatic
    }

    /// 推荐单位(歌曲 / 专辑 / 混合),与手机、Mac 的同一个设置项。
    @AppStorage(AIRecommendationUnit.storageKey)
    private var recommendationUnitRawValue = AIRecommendationUnit.defaultUnit.rawValue

    private var recommendationUnit: AIRecommendationUnit {
        .stored(recommendationUnitRawValue)
    }

    /// 智能推荐这一排开头的整张专辑候选:主视觉那张情景推荐之后排着的,本地
    /// `AlbumRecommender` 挑的;智能服务只在其中重排。
    private var recommendationAlbumPool: [AlbumRecommendation] {
        guard recommendationUnit.includesAlbums else { return [] }
        return AlbumRecommendationService.shared
            .forYouAlbumCandidates(excludingCurrentPick: true)
            .filter { store.album($0.albumID) != nil }
    }

    /// 要专辑时,等本地专辑推荐算出来再去问,免得冷启动先问一次只有歌曲的。
    private var recommendationAlbumsReady: Bool {
        !recommendationUnit.includesAlbums || AlbumRecommendationService.shared.recommendations != nil
    }

    private var recommendationAlbumCandidates: [AIRecommendationAlbumCandidate] {
        recommendationAlbumPool.map {
            $0.intelligenceCandidate(genre: store.library.visibleAlbum(id: $0.albumID)?.genre)
        }
    }

    /// 专辑卡在前(混合:两张),智能服务挑的先放、没挑的由本地结果补上,再接歌曲。
    private var recommendationEntries: [AIRecommendationFeedEntry] {
        AIRecommendationFeedComposer.compose(
            unit: recommendationUnit,
            intelligentAlbumKeys: aiRecommendation.isStreaming ? [] : aiRecommendation.orderedAlbumKeys,
            localAlbumKeys: recommendationAlbumPool.map(\.albumID),
            songIDs: displayedRecommendationSongs.map(\.id)
        )
    }

    private func recommendedAlbumReason(_ albumID: String) -> String {
        if let reason = aiRecommendation.albumReason(for: albumID), !reason.isEmpty { return reason }
        return recommendationAlbumPool.first { $0.albumID == albumID }?.reason.text ?? ""
    }

    /// 按下进专辑页(与首页其它专辑卡一致),整张播放在专辑页里按原曲序进行。
    private func recommendedAlbumCard(_ album: TVAlbum) -> some View {
        let id = cardID("aiAlbum", album.id)
        let reason = recommendedAlbumReason(album.id)
        return TVAlbumCard(
            album: album,
            subtitleOverride: reason.isEmpty ? nil : reason,
            action: playerOpener(id),
            onOpen: {
                browseMemory.cardID = id
                selectedAlbum = album
            },
            focusBinding: $focusedCardID,
            focusID: id
        )
    }

    private var recommendationCandidateRefreshKey: String {
        "\(store.recommendationRevision)#\(recommendationHistoryRevision)#"
            + "\(intelligence.settingsStore.recommendationsEnabled)#\(homeSections.isShown(.recommendations))"
    }

    private var recommendationRefreshKey: String {
        return [
            recommendationSceneRawValue,
            recommendationUnitRawValue,
            String(recommendationAlbumsReady),
            recommendationAlbumPool.map(\.albumID).joined(separator: "|"),
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
                ForEach(recommendationEntries) { entry in
                    switch entry {
                    case .album(let albumID):
                        if let album = store.album(albumID) {
                            recommendedAlbumCard(album)
                        }
                    case .song(let songID):
                        if let song = store.song(songID) {
                            TVSongCard(
                                song: song,
                                reason: aiRecommendation.reason(for: song.id) ?? "",
                                action: playerOpener(cardID("ai", song.id))
                            )
                            .focused($focusedCardID, equals: cardID("ai", song.id))
                        }
                    }
                }
            }
        }
        #if DEBUG
        .task(id: recommendationEntries.first?.id) {
            // 截图钩子 TV_SCREEN=homeAI:焦点放到智能推荐这一排的第一张,首页滚到这一排。
            guard TVDebugLaunch.screen == "homeAI", let first = recommendationEntries.first else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            switch first {
            case .album(let albumID): focusedCardID = cardID("aiAlbum", albumID)
            case .song(let songID): focusedCardID = cardID("ai", songID)
            }
        }
        #endif
        .task(id: recommendationRefreshKey) {
            guard recommendationAlbumsReady else { return }
            await aiRecommendation.refresh(
                scene: recommendationScene,
                candidates: recommendationCandidates,
                using: intelligence,
                unit: recommendationUnit,
                albumCandidates: recommendationAlbumCandidates
            )
        }
    }

    private func recommendationSceneButton(_ scene: AIRecommendationScene) -> some View {
        let selected = recommendationScene == scene
        return TVFocusButton(
            capsule: true,
            scale: 1.05,
            lift: 4,
            action: { recommendationSceneRawValue = scene.rawValue }
        ) { focused in
            Text(scene.localizedName)
                .tvFont(.caption, weight: .semibold)
                .foregroundStyle(focused ? TVColor.onFocusFill : (selected ? TVColor.onBrand : TVColor.text))
                .padding(.horizontal, 24)
                .padding(.vertical, 13)
                .background(
                    focused ? TVColor.focusFill : (selected ? TVColor.brand : TVColor.surface),
                    in: Capsule()
                )
        }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var heroZone: some View {
        HStack(alignment: .center, spacing: 64) {
            VStack(alignment: .leading, spacing: 0) {
                TVEyebrow(text: heroEyebrow)
                Text(heroHeading)
                    .tvFont(.heroTitle)
                    .tracking(-0.8)
                    .foregroundStyle(TVColor.text).lineLimit(2)
                    .padding(.top, 16)
                Text(heroSubtitle)
                    .tvFont(.caption).foregroundStyle(TVColor.textMuted)
                    .lineLimit(2).frame(maxWidth: 760, alignment: .leading)
                    .padding(.top, 14)
                if let heroReason {
                    Label(heroReason, systemImage: "sparkles")
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.text.opacity(0.86))
                        .lineLimit(2).frame(maxWidth: 760, alignment: .leading)
                        .padding(.top, 10)
                }
                HStack(spacing: 16) {
                    if let heroAlbum, albumPick != nil {
                        // 推荐的专辑:整张按原曲序播放,换一张在这个情景的备选之间轮换。
                        TVPillButton(title: String(localized: "album_pick_play"), systemImage: "play.fill", style: .solid,
                                     action: { playHeroAlbum(heroAlbum) })
                        TVPillButton(title: String(localized: "album_pick_another"), systemImage: "arrow.triangle.2.circlepath",
                                     action: { AlbumRecommendationService.shared.showAnother() })
                            .disabled(!AlbumRecommendationService.shared.canShowAnother)
                        // 「不再推荐」:不用长按菜单(首页随推荐、焦点频繁重算,遥控器长按出来的菜单会跟着闪),
                        // 只放一个图标,一排按钮才放得下。
                        TVFocusButton(radius: 14, scale: 1.04, lift: 6, action: {
                            guard let pick = albumPick else { return }
                            AlbumRecommendationService.shared.dismiss(albumID: pick.albumID)
                        }) { focused in
                            Image(systemName: "hand.thumbsdown")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(focused ? TVColor.onFocusFill : TVColor.text)
                                .frame(width: 36, height: 36)
                                .padding(18)
                                .background(focused ? TVColor.focusFill : TVColor.surfaceStrong)
                        }
                        .accessibilityLabel(Text("album_pick_dismiss"))
                    } else {
                        TVPillButton(title: PMString("ext.tv.home.playAll"), systemImage: "play.fill", style: .solid,
                                     action: { playHero(shuffle: false) })
                    }
                    TVPillButton(title: PMString("ext.tv.home.shuffle"), systemImage: "shuffle",
                                 action: { playHero(shuffle: true) })
                    TVMedleyButton(songIDs: store.songIDs, onStarted: openPlayer)
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

    /// 整张专辑按碟号、轨号的原曲序播放。
    private func playHeroAlbum(_ album: TVAlbum) {
        if store.playResolvedQueue(songIDs: store.songIDs(forAlbum: album.id), shuffled: false) { openPlayer() }
    }
}
#endif
