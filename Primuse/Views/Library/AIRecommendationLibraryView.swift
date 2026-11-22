import SwiftUI
import PrimuseKit

/// A library-sized recommendation destination. The local discovery engine is
/// always the source of playable candidates; a configured remote provider may
/// only reorder those candidates and explain the result.
struct AIRecommendationLibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(CoverTintProvider.self) private var tintProvider
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AIRecommendationIntentStoragePolicy.storageKey)
    private var customIntentsRawValue = ""
    @AppStorage(AIRecommendationIntentPresetVisibilityPolicy.storageKey)
    private var hiddenPresetsRawValue = ""
    @AppStorage(AIRecommendationIntentPresetOverridePolicy.storageKey)
    private var presetOverridesRawValue = ""
    @AppStorage(AIRecommendationIntentSelectionPolicy.storageKey)
    private var selectedIntentID = AIRecommendationIntentSelectionPolicy.defaultSelectionID
    @AppStorage("primuse.ai.recommendationScene.v1")
    private var recommendationSceneRawValue = AIRecommendationScene.automatic.rawValue
    @AppStorage(AIRecommendationSceneConfigurationPolicy.storageKey)
    private var sceneConfigurationRawValue = ""

    @State private var localResults: [MusicDiscoveryResult] = []
    @State private var aiRecommendation = AIRecommendationViewModel()
    @State private var refreshGeneration: UInt64 = 0
    @State private var historyRevision = 0
    @State private var isLoadingMore = false
    @State private var loadMoreFailed = false
    @State private var preparedLocalContentRevision: String?
    @State private var streamedQueueSongIDs: [String]?
    /// 「推荐 MV」那一排:按这一页推荐出来的歌里的艺人挑。
    @State private var musicVideoPicks: [Song] = []
    @State private var playlistSong: Song?
    @State private var showsIntentManager = false
    @State private var showsSceneSettings = false
    #if os(iOS)
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:工具栏按钮带上标题。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @Environment(\.librarySectionRailActive) private var sectionRailActive
    #endif
    #if os(macOS)
    @State private var showsSongDiscovery = false
    /// 给了就是 Mac 窗口右侧的推荐面板: 一行标题带全部播放与关闭, 歌单成一列紧凑的行。
    private let panelOnClose: (() -> Void)?

    init(panelOnClose: (() -> Void)? = nil) {
        self.panelOnClose = panelOnClose
    }

    private var isPanel: Bool { panelOnClose != nil }
    #endif

    private var intentChoices: [AIRecommendationIntentOption] {
        AIRecommendationIntentCatalog.options(
            customRawValue: customIntentsRawValue,
            hiddenPresetsRawValue: hiddenPresetsRawValue,
            presetOverridesRawValue: presetOverridesRawValue
        )
    }

    private var effectiveSelectedIntentID: String {
        AIRecommendationIntentSelectionPolicy.normalizedSelectionID(
            selectedIntentID,
            availableSelectionIDs: Set(intentChoices.map(\.id))
        )
    }

    private var selectedIntent: AIRecommendationIntentOption {
        intentChoices.first { $0.id == effectiveSelectedIntentID }
            ?? intentChoices[0]
    }

    private var sceneConfiguration: AIRecommendationSceneConfiguration {
        AIRecommendationSceneConfigurationPolicy.decode(sceneConfigurationRawValue)
    }

    /// 选中的场景;它被关掉了就按第一个还显示的场景算。
    private var recommendationScene: AIRecommendationScene {
        sceneConfiguration.resolvedSelection(
            AIRecommendationScene(rawValue: recommendationSceneRawValue) ?? .automatic
        )
    }

    private var sceneSettings: AIRecommendationSceneSettings {
        sceneConfiguration.settings(for: recommendationScene)
    }

    private var displayedResults: [MusicDiscoveryResult] {
        let byID = Dictionary(
            localResults.map { ($0.song.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let ordered = aiRecommendation.orderedSongs(from: localResults.map(\.song))
        return ordered.compactMap { byID[$0.id] }
    }

    private var canLoadMore: Bool {
        !aiRecommendation.orderedSongIDs.isEmpty
            && aiRecommendation.orderedSongIDs.count < localResults.count
    }

    private var contentRevision: String {
        [
            recommendationScene.rawValue,
            selectedIntent.id,
            selectedIntent.prompt ?? "",
            String(sceneSettings.songCount),
            sceneSettings.refreshInterval?.rawValue ?? "",
            String(library.visibleSongCollectionRevision),
            library.songReplacementToken.uuidString,
            String(intelligence.settingsStore.revision),
            String(intelligence.regionAvailability.revision),
            String(historyRevision),
        ].joined(separator: "#")
    }

    private var localContentRevision: String {
        [
            String(sceneSettings.candidatePoolSize),
            String(library.visibleSongCollectionRevision),
            library.songReplacementToken.uuidString,
            String(historyRevision),
        ].joined(separator: "#")
    }

    private var recommendationPresentationState: DeferredContentPresentationState {
        if aiRecommendation.isStreaming, displayedResults.isEmpty {
            return .loading
        }
        return DeferredContentPresentationPolicy.resolve(
            isPrepared: preparedLocalContentRevision == localContentRevision
                || !localResults.isEmpty,
            hasContent: !displayedResults.isEmpty
        )
    }

    private var refreshState: AIRecommendationRefreshState {
        AIRecommendationRefreshState(
            contentRevision: contentRevision,
            isSceneActive: scenePhase == .active
        )
    }

    var body: some View {
        Group {
            if !library.visibleSongs.contains(where: \.isPlayable) {
                ContentUnavailableView {
                    Label("library_recommendations_empty_title", systemImage: "sparkles")
                } description: {
                    Text("library_recommendations_empty_description")
                }
            } else {
                recommendationContent
            }
        }
        #if os(macOS)
        // 面板铺在侧栏同款的半透明底上, 自己不再垫底色。
        .background(isPanel ? Color.clear : PMColor.bg)
        #endif
        .onAppear(perform: normalizeSelectionsIfNeeded)
        .onChange(of: selectedIntentID) { _, _ in
            normalizeSelectionsIfNeeded()
        }
        .task(id: refreshState) {
            guard refreshState.shouldRefresh else { return }
            await refresh()
        }
        .task(id: aiRecommendation.retryAvailableAt) {
            guard let retryAt = aiRecommendation.retryAvailableAt else { return }
            do {
                try await Task.sleep(for: .seconds(max(0, retryAt.timeIntervalSinceNow)))
                aiRecommendation.finishRetryCooldown()
            } catch { }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primusePlaybackHistoryDidChange)) { _ in
            historyRevision &+= 1
        }
        // 方向被删、场景被关(这台或别的设备上)时选中的那一项改成还在的。
        .onChange(of: selectionInputs) { _, _ in
            normalizeSelectionsIfNeeded()
        }
        .onChange(of: aiRecommendation.orderedSongIDs) { _, _ in
            appendNewStreamingRecommendationsToOwnedQueue()
        }
        .onDisappear {
            streamedQueueSongIDs = nil
        }
        .modifier(customizationChrome)
    }

    private var selectionInputs: [String] {
        [customIntentsRawValue, hiddenPresetsRawValue, recommendationSceneRawValue, sceneConfigurationRawValue]
    }

    /// 右上角的「选歌方向」「推荐场景」两颗键和它们打开的设置页。
    private var customizationChrome: AIRecommendationCustomizationChrome {
        #if os(iOS)
        AIRecommendationCustomizationChrome(
            showsIntentManager: $showsIntentManager,
            showsSceneSettings: $showsSceneSettings,
            currentScene: recommendationScene,
            titledToolbarItems: verticalBarEdge != nil,
            collapsesToolbarItems: sectionRailActive
        )
        #else
        AIRecommendationCustomizationChrome(
            showsIntentManager: $showsIntentManager,
            showsSceneSettings: $showsSceneSettings,
            currentScene: recommendationScene
        )
        #endif
    }

    /// iOS 的迷你条由标签页外层统一让位，这里只留基线间距；macOS 沿用原值。
    private var bottomChromeClearance: CGFloat {
        #if os(iOS)
        16
        #else
        96
        #endif
    }

    @ViewBuilder
    private var recommendationContent: some View {
        #if os(macOS)
        if isPanel {
            VStack(spacing: 0) {
                panelHeader
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        recommendationControls
                        if showsSongDiscoveryEntry {
                            songDiscoveryEntry
                        }
                        if showsActionableStatus {
                            statusPanel
                        }
                        recommendationGrid
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 20)
                }
            }
        } else {
            pageContent
        }
        #else
        pageContent
        #endif
    }

    private var pageContent: some View {
        let videoRequest = MusicVideoRecommendationPolicy.Request(
            catalogRevision: library.musicVideoContentRevision, favoriteArtistIDs: localResults.compactMap(\.song.artistID),
            recentlyPlayedIDs: [], day: HomeHeroRecommendationPolicy.dayStamp(Date()),
            limit: sceneSettings.showsMusicVideos ? 10 : 0
        )
        #if os(macOS)
        let showsIndicators = false
        #else
        let showsIndicators = true
        #endif
        return ScrollView(.vertical, showsIndicators: showsIndicators) {
            LazyVStack(alignment: .leading, spacing: platformSectionSpacing) {
                mixCard
                pageControls
                if showsActionableStatus {
                    statusPanel
                }
                if sceneSettings.showsMusicVideos, !musicVideoPicks.isEmpty {
                    musicVideoShelf
                }
                Text("library_recommendations_songs_title")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(platformPrimaryTextColor)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 2)
                recommendationGrid
                if showsSongDiscoveryEntry {
                    songDiscoveryEntry
                }
            }
            .padding(.horizontal, platformHorizontalPadding)
            .padding(.top, platformTopPadding)
            .padding(.bottom, bottomChromeClearance)
        }
        // iPhone Duo 竖栏：推荐卡片和按钮停在竖栏左侧。
        .pmExtendsUnderVerticalBar()
        .task(id: videoRequest) {
            let next = await videoRequest.picks(from: library.musicVideoSongs, now: Date())
            guard !Task.isCancelled else { return }
            musicVideoPicks = next
        }
        .task(id: mixCardSongs.map(\.id)) { tintProvider.prepare(mixCardSongs) }
        .sheet(item: $playlistSong) { song in
            AddToPlaylistSheet(song: song)
        }
    }

    /// 页头那张卡:推荐出来的前几首拼成封面,底色从它们的封面取色、慢慢流动;下面全部播放、随机、重新生成。
    private var mixCard: some View {
        let songs = mixCardSongs
        let palettes = songs.compactMap { tintProvider.palette(forSongID: $0.id) }
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let playable = displayedResults.map(\.song).filteredPlayable()
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("library_recommendations_title", systemImage: "sparkles")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.78))
                        .labelStyle(.titleAndIcon)
                    Text(verbatim: mixTitle)
                        .font(platformTitleFont)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(verbatim: mixSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                mixCollage(songs)
            }
            HStack(spacing: 10) {
                Button(action: playAll) {
                    Label("play_all", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .foregroundStyle(.black)
                        .background(.white, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(playable.isEmpty)
                Button(action: shufflePlay) {
                    mixCircleIcon("shuffle")
                }
                .buttonStyle(.plain)
                .disabled(playable.isEmpty)
                .accessibilityLabel(Text("shuffle"))
                Spacer(minLength: 0)
                #if os(macOS)
                // Mac 的推荐页没有导航栏:两颗设置键排在卡片里刷新键的左边。
                Button { showsIntentManager = true } label: {
                    mixCircleIcon("wand.and.stars")
                }
                .buttonStyle(.plain)
                .help(Text("ai_recommendation_intents_settings_title"))
                .accessibilityLabel(Text("ai_recommendation_intents_settings_title"))
                Button { showsSceneSettings = true } label: {
                    mixCircleIcon("slider.horizontal.3")
                }
                .buttonStyle(.plain)
                .help(Text("ai_recommendation_scenes_title"))
                .accessibilityLabel(Text("ai_recommendation_scenes_title"))
                #endif
                if intelligence.isPersonalizedRecommendationsConfigured {
                    Button {
                        Task { await refresh(forceAIRefresh: true) }
                    } label: {
                        Group {
                            if aiRecommendation.isStreaming {
                                ProgressView().controlSize(.small).tint(.white)
                                    .frame(width: 38, height: 38)
                                    .background(.white.opacity(0.2), in: Circle())
                            } else {
                                mixCircleIcon("arrow.clockwise")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(aiRecommendation.isStreaming || aiRecommendation.retryAvailableAt != nil || isLoadingMore)
                    .accessibilityLabel(Text("ai_recommendation_refresh"))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            CoverFlowBackdrop(palettes: palettes, isAnimating: scenePhase == .active)
                .overlay {
                    LinearGradient(
                        colors: [.black.opacity(0.12), .black.opacity(0.42)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.recommendations.mix")
    }

    private func mixCircleIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(.white.opacity(0.2), in: Circle())
            .contentShape(Circle())
    }

    /// 右上角四张封面拼成一格;不够四首时只放第一张。
    @ViewBuilder
    private func mixCollage(_ songs: [Song]) -> some View {
        let side: CGFloat = 92
        Group {
            if songs.count >= 4 {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        mixArtwork(songs[0], side: side / 2)
                        mixArtwork(songs[1], side: side / 2)
                    }
                    HStack(spacing: 0) {
                        mixArtwork(songs[2], side: side / 2)
                        mixArtwork(songs[3], side: side / 2)
                    }
                }
            } else if let song = songs.first {
                mixArtwork(song, side: side)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.16))
                    .overlay {
                        Image(systemName: "sparkles")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        .accessibilityHidden(true)
    }

    private func mixArtwork(_ song: Song, side: CGFloat) -> some View {
        CachedArtworkView(
            coverRef: song.coverArtFileName,
            songID: song.id,
            size: side,
            cornerRadius: 0,
            sourceID: song.sourceID,
            filePath: song.filePath,
            fileFormat: song.fileFormat
        )
        .frame(width: side, height: side)
    }

    private var mixCardSongs: [Song] {
        Array(displayedResults.prefix(4).map(\.song))
    }

    /// 选了方向写方向,选了场景写场景,都没选时就叫「为你挑选」。
    private var mixTitle: String {
        if effectiveSelectedIntentID != AIRecommendationIntentSelectionPolicy.defaultSelectionID {
            return selectedIntent.title
        }
        if recommendationScene != .automatic {
            return recommendationScene.localizedName
        }
        return String(localized: "library_recommendations_mix_title")
    }

    private var mixSubtitle: String {
        let count = displayedResults.count
        guard count > 0 else { return String(localized: "library_recommendations_eyebrow") }
        let artists = displayedResults.prefix(6).compactMap { library.artistDisplayName(for: $0.song) }
        var seen = Set<String>()
        let names = artists.filter { seen.insert($0).inserted }.prefix(3)
        let countText = String(format: String(localized: "home_hero_song_count_format"), count)
        return names.isEmpty ? countText : countText + " · " + names.joined(separator: "、")
    }

    /// 页面上的场景与选歌方向:一行胶囊,第一颗是选歌方向(点开挑),后面是场景。选了方向时下面写一句说明。
    private var pageControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Menu {
                        intentMenuContent
                    } label: {
                        let hasIntent = effectiveSelectedIntentID != AIRecommendationIntentSelectionPolicy.defaultSelectionID
                        HStack(spacing: 5) {
                            Image(systemName: "wand.and.stars")
                            if hasIntent {
                                Text(verbatim: selectedIntent.title).lineLimit(1)
                            } else {
                                Text("library_recommendations_theme").lineLimit(1)
                            }
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(hasIntent ? Color.white : platformAccentColor)
                        .padding(.horizontal, 13)
                        .frame(height: 32)
                        .background(hasIntent ? platformAccentColor : platformAccentColor.opacity(0.12), in: Capsule())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)

                    Rectangle()
                        .fill(platformDividerColor)
                        .frame(width: 0.5, height: 20)

                    ForEach(sceneConfiguration.visibleScenes, id: \.self) { scene in
                        let isSelected = recommendationScene == scene
                        Button {
                            recommendationSceneRawValue = scene.rawValue
                        } label: {
                            Label(scene.localizedName, systemImage: scene.recommendationIcon)
                                .labelStyle(.titleAndIcon)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.white : platformPrimaryTextColor)
                                .padding(.horizontal, 13)
                                .frame(height: 32)
                                .background(isSelected ? platformAccentColor : platformChipBackground, in: Capsule())
                                .overlay {
                                    if !isSelected {
                                        Capsule().stroke(platformDividerColor, lineWidth: 0.5)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .pmStopsAtVerticalBar()

            if effectiveSelectedIntentID != AIRecommendationIntentSelectionPolicy.defaultSelectionID {
                Text(verbatim: selectedIntent.detail)
                    .font(.caption)
                    .foregroundStyle(platformSecondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 选歌方向的菜单内容:不加方向在最上面,其余分一段。页面胶囊和 Mac 面板共用。
    @ViewBuilder
    private var intentMenuContent: some View {
        Button {
            selectIntent(AIRecommendationIntentSelectionPolicy.defaultSelectionID)
        } label: {
            if effectiveSelectedIntentID
                == AIRecommendationIntentSelectionPolicy.defaultSelectionID {
                // 选中项只靠勾选图标表达；macOS 27 起菜单默认隐藏图标。
                Label("library_recommendations_theme_none", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
            } else {
                Text("library_recommendations_theme_none")
            }
        }
        let selectableChoices = intentChoices.filter {
            $0.id != AIRecommendationIntentSelectionPolicy.defaultSelectionID
        }
        if !selectableChoices.isEmpty {
            Divider()
            ForEach(selectableChoices) { choice in
                Button {
                    selectIntent(choice.id)
                } label: {
                    if effectiveSelectedIntentID == choice.id {
                        Label {
                            Text(verbatim: choice.title)
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                        .labelStyle(.titleAndIcon)
                    } else {
                        Text(verbatim: choice.title)
                    }
                }
            }
        }
        Divider()
        Button {
            showsIntentManager = true
        } label: {
            Label("ai_recommendation_intents_edit", systemImage: "pencil")
        }
    }

    /// 「推荐 MV」:这一页推荐出来的歌里有哪些艺人,就先挑他们的 MV。
    private var musicVideoShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("library_recommendations_music_videos")
                .font(.title3.weight(.bold))
                .foregroundStyle(platformPrimaryTextColor)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(musicVideoPicks) { song in
                        MusicVideoCard(
                            song: song,
                            play: { MusicVideoPlayback.play(song, in: musicVideoPicks, player: player) },
                            addToPlaylist: { playlistSong = song }
                        )
                        .frame(width: platformMusicVideoCardWidth)
                    }
                }
                .padding(.bottom, 4)
            }
            .pmStopsAtVerticalBar()
        }
        .accessibilityIdentifier("library.recommendations.musicVideos")
    }

    private var recommendationControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("library_recommendations_intent_title")
                    .font(.headline)
                    .foregroundStyle(platformPrimaryTextColor)
                Spacer()
                Menu {
                    intentMenuContent
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "wand.and.stars")
                        if effectiveSelectedIntentID
                            == AIRecommendationIntentSelectionPolicy.defaultSelectionID {
                            Text("library_recommendations_theme")
                                .lineLimit(1)
                        } else {
                            Text(verbatim: selectedIntent.title)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(platformAccentColor)
                }
                .menuStyle(.borderlessButton)
            }

            if effectiveSelectedIntentID
                != AIRecommendationIntentSelectionPolicy.defaultSelectionID {
                Text(verbatim: selectedIntent.detail)
                    .font(.caption)
                    .foregroundStyle(platformSecondaryTextColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(platformChipBackground, in: RoundedRectangle(cornerRadius: 10))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(sceneConfiguration.visibleScenes, id: \.self) { scene in
                        Button {
                            recommendationSceneRawValue = scene.rawValue
                        } label: {
                            Text(scene.localizedName)
                                .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                recommendationScene == scene
                                    ? Color.white
                                    : platformPrimaryTextColor
                            )
                            .padding(.horizontal, 13)
                            .frame(height: 32)
                            .background(
                                recommendationScene == scene
                                    ? platformAccentColor
                                    : platformChipBackground,
                                in: Capsule()
                            )
                            .overlay {
                                if recommendationScene != scene {
                                    Capsule().stroke(platformDividerColor, lineWidth: 0.5)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(
                            recommendationScene == scene ? .isSelected : []
                        )
                    }
                }
            }
            .pmStopsAtVerticalBar()
        }
    }

    /// 曲库以外的新歌要问 AI;所在地区不提供任何智能服务时不出入口。
    private var showsSongDiscoveryEntry: Bool {
        intelligence.isSongDiscoveryAvailable
            || intelligence.songDiscoveryNeedsRemoteConsent
            || intelligence.shouldExposeRemoteConfiguration
    }

    @ViewBuilder
    private var songDiscoveryEntry: some View {
        #if os(macOS)
        Button {
            showsSongDiscovery = true
        } label: {
            songDiscoveryEntryLabel
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsSongDiscovery) {
            AISongDiscoveryView()
        }
        #else
        NavigationLink {
            AISongDiscoveryView()
                .minimalNavigationDetail()
        } label: {
            songDiscoveryEntryLabel
        }
        .buttonStyle(.plain)
        #endif
    }

    private var songDiscoveryEntryLabel: some View {
        HStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(platformAccentColor)
                .frame(width: 36, height: 36)
                .background(platformAccentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("ai_song_discovery_title")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(platformPrimaryTextColor)
                Text("ai_song_discovery_entry_detail")
                    .font(.caption)
                    .foregroundStyle(platformSecondaryTextColor)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(platformSecondaryTextColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(platformCardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(platformDividerColor, lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var statusPanel: some View {
        // 尾部的刷新 / 设置按钮 30pt 高, 图标与文字若顶对齐就会整体偏上; 按中线对齐。
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: statusIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 24, height: 24)
                .background(statusColor.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(aiRecommendation.statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(platformPrimaryTextColor)
                if let retryAt = aiRecommendation.retryAvailableAt {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(AIRetryCountdown.text(until: retryAt, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(platformSecondaryTextColor)
                    }
                }
                if let summary = aiRecommendation.summaryText {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(platformSecondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                } else if showsLocalFallbackDetail {
                    Text("library_recommendations_local_fallback_detail")
                        .font(.caption)
                        .foregroundStyle(platformSecondaryTextColor)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if aiRecommendation.isStreaming {
                    ProgressView().controlSize(.small)
                } else if intelligence.isPersonalizedRecommendationsConfigured {
                    Button {
                        Task { await refresh(forceAIRefresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(platformChipBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(platformAccentColor)
                    .accessibilityLabel("ai_recommendation_refresh")
                    .disabled(aiRecommendation.retryAvailableAt != nil || isLoadingMore)
                }

                if intelligence.shouldExposeRemoteConfiguration {
                    #if os(macOS)
                    Button {
                        SettingsWindowController.shared.show(tab: .intelligence)
                    } label: {
                        intelligenceSettingsIcon
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(platformAccentColor)
                    .accessibilityLabel("ai_settings_title")
                    #else
                    NavigationLink {
                        AISettingsView()
                            #if os(iOS)
                            .minimalNavigationDetail()
                            #endif
                    } label: {
                        intelligenceSettingsIcon
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(platformAccentColor)
                    .accessibilityLabel("ai_settings_title")
                    #endif
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(platformCardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(platformDividerColor, lineWidth: 0.5)
        }
    }

    private var intelligenceSettingsIcon: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 30, height: 30)
            .background(platformChipBackground, in: Circle())
    }

    private var recommendationGrid: some View {
        VStack(spacing: 14) {
            switch recommendationPresentationState {
            case .loading:
                #if os(macOS)
                if isPanel {
                    panelLoadingList
                        .pmAppearFade(.contentAppear)
                } else {
                    recommendationLoadingGrid
                        .pmAppearFade(.contentAppear)
                }
                #else
                recommendationLoadingGrid
                    .pmAppearFade(.contentAppear)
                #endif
            case .content:
                #if os(macOS)
                if isPanel {
                    panelResultsList
                        .pmAppearFade(.contentAppear)
                } else {
                    recommendationResultsGrid
                        .pmAppearFade(.contentAppear)
                }
                #else
                recommendationResultsGrid
                    .pmAppearFade(.contentAppear)
                #endif
            case .empty:
                recommendationResolvedEmptyState
                    .pmAppearFade(.contentAppear)
            }

            if canLoadMore || isLoadingMore || loadMoreFailed {
                VStack(spacing: 8) {
                    if loadMoreFailed {
                        Text("library_recommendations_more_failed")
                            .font(.caption)
                            .foregroundStyle(platformSecondaryTextColor)
                            .multilineTextAlignment(.center)
                    }
                    if canLoadMore || isLoadingMore {
                        Button {
                            Task { await loadMoreRecommendations() }
                        } label: {
                            HStack(spacing: 7) {
                                if isLoadingMore {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "sparkles")
                                }
                                Text("library_recommendations_more")
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .foregroundStyle(platformPrimaryTextColor)
                            .background(platformChipBackground, in: Capsule())
                            .overlay {
                                Capsule().stroke(platformDividerColor, lineWidth: 0.5)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoadingMore || aiRecommendation.isStreaming
                            || aiRecommendation.retryAvailableAt != nil)
                    }
                }
            }
        }
    }

    /// 推荐出来的歌,一行一首:封面、序号和歌名、艺人,下面一行写推荐理由。宽画布上分两栏。
    private var recommendationResultsGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.adaptive(minimum: platformRowMinimumWidth, maximum: 640), spacing: 24, alignment: .top),
            ],
            alignment: .leading,
            spacing: 0
        ) {
            // 网格嵌在页面的 LazyVStack 里，异步渲染帧会在别的线程上现建格子，见 `LazyItemCell`。
            ForEach(Array(displayedResults.enumerated()), id: \.element.id) { @Sendable index, result in
                LazyItemCell {
                    Button {
                        play(result.song)
                    } label: {
                        recommendationRow(result, ordinal: index + 1)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { rowMenu(result.song) }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .animation(.snappy(duration: 0.28), value: aiRecommendation.orderedSongIDs)
    }

    @ViewBuilder
    private func rowMenu(_ song: Song) -> some View {
        Button { play(song) } label: { Label("play", systemImage: "play.fill") }
            .disabled(!song.isPlayable)
        Button {
            _ = player.insertNextInQueue([song])
        } label: {
            Label("insert_next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .disabled(!song.isPlayable)
        Button {
            player.appendToQueue([song])
        } label: {
            Label("add_to_queue", systemImage: "text.badge.plus")
        }
        .disabled(!song.isPlayable)
        Button {
            playlistSong = song
        } label: {
            Label("add_to_playlist", systemImage: "music.note.list")
        }
    }

    private func recommendationRow(_ result: MusicDiscoveryResult, ordinal: Int) -> some View {
        let song = result.song
        let isCurrent = player.currentSong?.id == song.id
        return HStack(alignment: .center, spacing: 12) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: platformRowArtworkSize,
                cornerRadius: 8,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            .frame(width: platformRowArtworkSize, height: platformRowArtworkSize)
            .shadow(color: .black.opacity(0.1), radius: 3, y: 2)

            VStack(alignment: .leading, spacing: 2) {
                SongRowNumberedTitle(number: ordinal, title: song.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isCurrent ? platformAccentColor : platformPrimaryTextColor)
                    .lineLimit(1)
                Text(
                    verbatim: library.artistDisplayName(for: song)
                        ?? String(localized: "unknown_artist")
                )
                    .font(.subheadline)
                    .foregroundStyle(platformSecondaryTextColor)
                    .lineLimit(1)
                if let reason = aiRecommendation.reason(for: song.id) {
                    Label(reason, systemImage: "sparkles")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(platformAccentColor)
                        .lineLimit(2)
                        .padding(.top, 1)
                } else {
                    Text(String(localized: String.LocalizationValue(result.primaryReason.localizationKey)))
                        .font(.caption)
                        .foregroundStyle(platformSecondaryTextColor.opacity(0.85))
                        .lineLimit(1)
                        .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isCurrent {
                Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(platformAccentColor)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(platformDividerColor)
                .frame(height: 0.5)
                .padding(.leading, platformRowArtworkSize + 12)
        }
        .contentShape(Rectangle())
    }

    private func shufflePlay() {
        let queue = player.shufflePlayOrder(displayedResults.map(\.song).filteredPlayable())
        guard let first = queue.first else { return }
        player.shuffleEnabled = true
        // 打乱了的队列不再跟着 AI 一首首写出来的顺序往后追加。
        streamedQueueSongIDs = nil
        SiriMediaInteractionDonor.donate(song: first)
        Task { await player.play(queue: queue, startingAt: 0) }
    }

    #if os(macOS)
    /// 面板顶上一行: 标题、全部播放、关闭。
    private var panelHeader: some View {
        HStack(spacing: 8) {
            Label("library_recommendations_title", systemImage: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .labelStyle(.titleAndIcon)
            Spacer(minLength: 6)
            Button(action: playAll) {
                Label("play_all", systemImage: "play.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .foregroundStyle(Color.white)
                    .background(platformAccentColor, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(displayedResults.map(\.song).filteredPlayable().isEmpty)
            Menu {
                Button { showsIntentManager = true } label: {
                    Label("ai_recommendation_intents_settings_title", systemImage: "wand.and.stars")
                }
                Button { showsSceneSettings = true } label: {
                    Label("ai_recommendation_scenes_title", systemImage: "slider.horizontal.3")
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 24, height: 24)
                    .background(PMColor.glassBtn, in: .circle)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(Text("library_recommendations_customize"))
            Button {
                panelOnClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 24, height: 24)
                    .background(PMColor.glassBtn, in: .circle)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text("close"))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    /// 面板里一列紧凑的行; AI 一首首写出来时从右边滑进来。
    private var panelResultsList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(displayedResults.enumerated()), id: \.element.id) { index, result in
                Button {
                    play(result.song)
                } label: {
                    panelRow(result, ordinal: index + 1)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.snappy(duration: 0.28), value: aiRecommendation.orderedSongIDs)
    }

    private func panelRow(_ result: MusicDiscoveryResult, ordinal: Int) -> some View {
        let song = result.song
        let isCurrent = player.currentSong?.id == song.id
        return HStack(spacing: 11) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 44,
                cornerRadius: 7,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            VStack(alignment: .leading, spacing: 2) {
                SongRowNumberedTitle(number: ordinal, title: song.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCurrent ? platformAccentColor : platformPrimaryTextColor)
                    .lineLimit(1)
                Text(verbatim: library.artistDisplayName(for: song) ?? String(localized: "unknown_artist"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(platformSecondaryTextColor)
                    .lineLimit(1)
                if let reason = aiRecommendation.reason(for: song.id) {
                    Label(reason, systemImage: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(platformAccentColor)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .pmRowBackground(cornerRadius: 8)
        .contentShape(Rectangle())
    }

    private var panelLoadingList: some View {
        LoadingSkeletonGroup {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<7, id: \.self) { index in
                    HStack(spacing: 11) {
                        recommendationSkeletonBlock(width: 44, height: 44, cornerRadius: 7)
                        VStack(alignment: .leading, spacing: 6) {
                            recommendationSkeletonBlock(width: 120 + CGFloat((index % 3) * 24), height: 11)
                            recommendationSkeletonBlock(width: 80, height: 9)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
        }
    }
    #endif

    private var recommendationLoadingGrid: some View {
        LoadingSkeletonGroup {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: platformRowMinimumWidth, maximum: 640), spacing: 24, alignment: .top),
                ],
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(0..<8, id: \.self) { @Sendable index in
                    LazyItemCell {
                        HStack(spacing: 12) {
                            recommendationSkeletonBlock(
                                width: platformRowArtworkSize,
                                height: platformRowArtworkSize,
                                cornerRadius: 8
                            )
                            VStack(alignment: .leading, spacing: 7) {
                                recommendationSkeletonBlock(width: 140 + CGFloat((index % 3) * 26), height: 13)
                                recommendationSkeletonBlock(width: 90 + CGFloat((index % 2) * 20), height: 11)
                                recommendationSkeletonBlock(width: 170, height: 9)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                    }
                }
            }
        }
    }

    private var recommendationResolvedEmptyState: some View {
        ContentUnavailableView {
            Label("library_recommendations_empty_title", systemImage: "sparkles")
        } description: {
            Text("library_recommendations_empty_description")
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func recommendationSkeletonBlock(
        width: CGFloat? = nil,
        height: CGFloat,
        cornerRadius: CGFloat = 5
    ) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(platformSkeletonFill)
            .frame(width: width, height: height)
    }

    @MainActor
    private func refresh(forceAIRefresh: Bool = false) async {
        let operationRefreshState = refreshState
        let operationLocalContentRevision = localContentRevision
        guard operationRefreshState.shouldRefresh else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        loadMoreFailed = false
        let input = MusicDiscoveryEngine.recommendationInput(in: library)
        let settings = sceneSettings
        let recommendationPoolSize = settings.candidatePoolSize
        let results = await Task.detached(priority: .userInitiated) {
            MusicDiscoveryEngine.dailyRecommendations(
                from: input,
                limit: recommendationPoolSize
            )
        }.value
        guard generation == refreshGeneration,
              !Task.isCancelled,
              operationRefreshState == refreshState,
              refreshState.shouldRefresh else { return }
        localResults = results
        preparedLocalContentRevision = operationLocalContentRevision
        await aiRecommendation.refresh(
            scene: recommendationScene,
            intent: selectedIntent.prompt,
            candidates: results.map(\.song),
            using: intelligence,
            forceRefresh: forceAIRefresh,
            maximumResults: settings.songCount,
            minimumResults: settings.minimumResults,
            candidateLimit: recommendationPoolSize,
            reuseSurface: .library,
            refreshInterval: settings.refreshInterval
        )
    }

    @MainActor
    private func loadMoreRecommendations() async {
        guard !isLoadingMore, !aiRecommendation.isStreaming,
              aiRecommendation.retryAvailableAt == nil,
              refreshState.shouldRefresh else { return }
        let selectedIDs = Set(aiRecommendation.orderedSongIDs)
        let remaining = localResults.filter { !selectedIDs.contains($0.song.id) }
        guard !remaining.isEmpty else { return }

        let operationRefreshState = refreshState
        isLoadingMore = true
        loadMoreFailed = false
        defer { isLoadingMore = false }

        let settings = sceneSettings
        let appended = await aiRecommendation.refresh(
            scene: recommendationScene,
            intent: selectedIntent.prompt,
            candidates: remaining.map(\.song),
            using: intelligence,
            maximumResults: settings.songCount,
            minimumResults: min(settings.minimumResults, remaining.count),
            candidateLimit: settings.candidatePoolSize,
            appending: true
        )
        guard !Task.isCancelled,
              operationRefreshState == refreshState,
              refreshState.shouldRefresh else { return }
        loadMoreFailed = !appended
    }

    private func play(_ song: Song) {
        let visibleQueue = displayedResults.map(\.song).filteredPlayable()
        let fallbackQueue = aiRecommendation.isStreaming
            ? localResults.map(\.song).filteredPlayable()
            : []
        let songsByID = Dictionary(
            (visibleQueue + fallbackQueue).map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let orderedIDs = AIRecommendationPlaybackQueuePolicy.orderedSongIDs(
            visibleSongIDs: visibleQueue.map(\.id),
            fallbackSongIDs: fallbackQueue.map(\.id),
            selectedSongID: song.id
        )
        let queue = orderedIDs.compactMap { songsByID[$0] }
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.shuffleEnabled = false
        beginTrackingStreamingQueue(
            queue,
            hasFallbackTail: queue.count > visibleQueue.count
        )
        let selected = queue[index]
        SiriMediaInteractionDonor.donate(song: selected)
        Task { await player.play(queue: queue, startingAt: index) }
    }

    private func playAll() {
        let visibleQueue = displayedResults.map(\.song).filteredPlayable()
        guard let selected = visibleQueue.first else { return }
        let fallbackQueue = aiRecommendation.isStreaming
            ? localResults.map(\.song).filteredPlayable()
            : []
        let songsByID = Dictionary(
            (visibleQueue + fallbackQueue).map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let orderedIDs = AIRecommendationPlaybackQueuePolicy.orderedSongIDs(
            visibleSongIDs: visibleQueue.map(\.id),
            fallbackSongIDs: fallbackQueue.map(\.id),
            selectedSongID: selected.id
        )
        let queue = orderedIDs.compactMap { songsByID[$0] }
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        beginTrackingStreamingQueue(
            queue,
            hasFallbackTail: queue.count > visibleQueue.count
        )
        SiriMediaInteractionDonor.donate(song: first)
        Task { await player.play(queue: queue, startingAt: 0) }
    }

    private func beginTrackingStreamingQueue(
        _ queue: [Song],
        hasFallbackTail: Bool
    ) {
        streamedQueueSongIDs = aiRecommendation.isStreaming && !hasFallbackTail
            ? queue.map(\.id)
            : nil
    }

    private func appendNewStreamingRecommendationsToOwnedQueue() {
        guard let expectedQueueSongIDs = streamedQueueSongIDs else { return }
        let desiredQueue = displayedResults.map(\.song).filteredPlayable()
        let desiredQueueSongIDs = desiredQueue.map(\.id)
        let decision = AIRecommendationQueueSyncPolicy.decision(
            expectedQueueSongIDs: expectedQueueSongIDs,
            actualQueueSongIDs: player.queue.map(\.id),
            desiredQueueSongIDs: desiredQueueSongIDs
        )

        switch decision {
        case .unchanged:
            return
        case .relinquish:
            streamedQueueSongIDs = nil
        case let .append(songIDs):
            let songsByID = Dictionary(
                desiredQueue.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            let additions = songIDs.compactMap { songsByID[$0] }
            guard additions.map(\.id) == songIDs else {
                streamedQueueSongIDs = nil
                return
            }
            player.appendToQueue(additions)
            streamedQueueSongIDs = desiredQueueSongIDs
        }
    }

    private func selectIntent(_ id: String) {
        selectedIntentID = id
        CloudKVSSync.shared.markChanged(
            key: CloudKVSKey.aiRecommendationSelectedIntent
        )
    }

    private func normalizeSelectionsIfNeeded() {
        let normalizedID = effectiveSelectedIntentID
        if normalizedID != selectedIntentID {
            selectIntent(normalizedID)
        }
        let scene = recommendationScene
        if scene.rawValue != recommendationSceneRawValue {
            recommendationSceneRawValue = scene.rawValue
        }
    }

    private var statusIcon: String {
        switch aiRecommendation.feedback {
        case .idle: return "iphone.and.arrow.forward"
        case .loading: return "sparkles"
        case .needsConsent: return "hand.raised.fill"
        case .success: return "checkmark.circle.fill"
        case .localFallback: return "arrow.uturn.backward.circle.fill"
        }
    }

    private var statusColor: Color {
        switch aiRecommendation.feedback {
        case .success: return .green
        case .needsConsent: return .orange
        case .localFallback: return .orange
        case .idle, .loading: return platformAccentColor
        }
    }

    private var showsLocalFallbackDetail: Bool {
        if case .localFallback = aiRecommendation.feedback {
            return aiRecommendation.orderedSongIDs.isEmpty
        }
        return false
    }

    private var showsActionableStatus: Bool {
        if aiRecommendation.isPartial { return true }
        switch aiRecommendation.feedback {
        case .needsConsent, .localFallback, .loading:
            return true
        case .idle, .success:
            return false
        }
    }

    #if os(macOS)
    private var platformHorizontalPadding: CGFloat { PMSpace.xxxl }
    private var platformTopPadding: CGFloat { PMSpace.l24 }
    private var platformSectionSpacing: CGFloat { PMSpace.l }
    private var platformRowMinimumWidth: CGFloat { 340 }
    private var platformRowArtworkSize: CGFloat { 52 }
    private var platformMusicVideoCardWidth: CGFloat { 260 }
    private var platformTitleFont: Font { PMFont.pageTitle(28) }
    private var platformAccentColor: Color { PMColor.brand }
    private var platformPrimaryTextColor: Color { PMColor.text }
    private var platformSecondaryTextColor: Color { PMColor.textMuted }
    private var platformCardBackground: Color { PMColor.bgElev }
    private var platformChipBackground: Color { PMColor.glassBtn }
    private var platformDividerColor: Color { PMColor.dividerStrong }
    private var platformSkeletonFill: Color { PMColor.glassBtn }
    #else
    private var platformHorizontalPadding: CGFloat { 20 }
    private var platformTopPadding: CGFloat { 16 }
    private var platformSectionSpacing: CGFloat { 16 }
    private var platformRowMinimumWidth: CGFloat { 320 }
    private var platformRowArtworkSize: CGFloat { 54 }
    private var platformMusicVideoCardWidth: CGFloat { 230 }
    private var platformTitleFont: Font { .title.bold() }
    private var platformAccentColor: Color { .accentColor }
    private var platformPrimaryTextColor: Color { .primary }
    private var platformSecondaryTextColor: Color { .secondary }
    private var platformCardBackground: Color { Color.secondary.opacity(0.075) }
    private var platformChipBackground: Color { Color.secondary.opacity(0.09) }
    private var platformDividerColor: Color { Color.secondary.opacity(0.18) }
    private var platformSkeletonFill: Color { Color.secondary.opacity(0.14) }
    #endif
}

// MARK: - 自定义:选歌方向与推荐场景

private extension AIRecommendationScene {
    var recommendationIcon: String {
        switch self {
        case .automatic: "sparkles"
        case .driving: "car.fill"
        case .focus: "brain.head.profile"
        case .workout: "figure.run"
        case .relaxation: "leaf.fill"
        case .bedtime: "moon.stars.fill"
        }
    }
}

/// 推荐页右上角的「选歌方向」「推荐场景」两颗键(iPhone、iPad 的导航栏与极简页头)和它们打开的设置页。
/// Mac 的两颗键排在页面卡片和侧边面板的标题行里,这里只挂设置页。
private struct AIRecommendationCustomizationChrome: ViewModifier {
    @Binding var showsIntentManager: Bool
    @Binding var showsSceneSettings: Bool
    let currentScene: AIRecommendationScene
    #if os(iOS)
    /// 系统工具栏竖排到侧边时(iPhone Duo)按钮带上标题。
    let titledToolbarItems: Bool
    /// 资料库分类在 Duo 竖栏里时两颗键收进一个「⋯」,竖栏中间留给分类。
    let collapsesToolbarItems: Bool
    #endif

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .toolbar {
                if collapsesToolbarItems {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            customizationButtons(titled: true)
                        } label: {
                            PMToolbarItemLabel("a11y_more_actions", systemImage: "ellipsis", titled: true)
                        }
                        .accessibilityIdentifier("library.recommendations.more")
                    }
                } else {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        customizationButtons(titled: titledToolbarItems)
                    }
                }
            }
            // 极简模式根页没有导航栏:两颗键排在页头右边。
            .minimalPageHeader {
                HStack(spacing: 4) {
                    Spacer(minLength: 8)
                    MinimalHeaderActions {
                        customizationButtons(titled: false)
                    }
                }
            }
            #endif
            .sheet(isPresented: $showsIntentManager) {
                AIRecommendationIntentManagerView()
            }
            .sheet(isPresented: $showsSceneSettings) {
                AIRecommendationSceneSettingsView(initiallyExpandedScene: currentScene)
            }
    }

    #if os(iOS)
    @ViewBuilder
    private func customizationButtons(titled: Bool) -> some View {
        Button {
            showsIntentManager = true
        } label: {
            PMToolbarItemLabel(
                "ai_recommendation_intents_settings_title",
                systemImage: "wand.and.stars",
                titled: titled
            )
        }
        .accessibilityLabel(Text("ai_recommendation_intents_settings_title"))
        .accessibilityIdentifier("library.recommendations.directions")
        Button {
            showsSceneSettings = true
        } label: {
            PMToolbarItemLabel("ai_recommendation_scenes_title", systemImage: "slider.horizontal.3", titled: titled)
        }
        .accessibilityLabel(Text("ai_recommendation_scenes_title"))
        .accessibilityIdentifier("library.recommendations.scenes")
    }
    #endif
}

/// 正在改的一条选歌方向:新加的,或列表里已有的。
private enum AIRecommendationIntentEditTarget: Identifiable, Hashable {
    case new
    case existing(AIRecommendationIntentOption)

    var id: String {
        switch self {
        case .new: "new"
        case .existing(let option): option.id
        }
    }

    var option: AIRecommendationIntentOption? {
        if case .existing(let option) = self { return option }
        return nil
    }
}

/// 「选歌方向」:内置方向可以改名字和提示词、移除、还原,也可以加自己的方向。
private struct AIRecommendationIntentManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AIRecommendationIntentStoragePolicy.storageKey)
    private var customIntentsRawValue = ""
    @AppStorage(AIRecommendationIntentPresetVisibilityPolicy.storageKey)
    private var hiddenPresetsRawValue = ""
    @AppStorage(AIRecommendationIntentPresetOverridePolicy.storageKey)
    private var presetOverridesRawValue = ""
    @AppStorage(AIRecommendationIntentSelectionPolicy.storageKey)
    private var selectedIntentID = AIRecommendationIntentSelectionPolicy.defaultSelectionID
    #if os(macOS)
    @State private var editingTarget: AIRecommendationIntentEditTarget?
    #endif

    private var options: [AIRecommendationIntentOption] {
        AIRecommendationIntentCatalog.options(
            customRawValue: customIntentsRawValue,
            hiddenPresetsRawValue: hiddenPresetsRawValue,
            presetOverridesRawValue: presetOverridesRawValue
        )
    }

    private var customIntents: [AICustomRecommendationIntent] {
        AIRecommendationIntentStoragePolicy.decode(customIntentsRawValue)
    }

    private var canAddIntent: Bool {
        customIntents.count < AIRecommendationIntentStoragePolicy.maximumCustomIntents
    }

    private var hasHiddenPresets: Bool {
        !AIRecommendationIntentPresetVisibilityPolicy.hiddenPresets(hiddenPresetsRawValue).isEmpty
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            MacSheetHeader(
                Text("ai_recommendation_intents_settings_title"),
                systemImage: "wand.and.stars",
                onClose: { dismiss() }
            )
            form
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
        .frame(width: 520, height: 560)
        .background(PMColor.bg)
        .sheet(item: $editingTarget) { target in
            editor(for: target)
        }
        #else
        NavigationStack {
            form
                .navigationTitle("ai_recommendation_intents_settings_title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("done") { dismiss() }
                    }
                }
        }
        #endif
    }

    private var form: some View {
        Form {
            Section {
                ForEach(options.filter { $0.source != .defaultSelection }) { option in
                    row(for: option)
                }
            } footer: {
                Text("ai_recommendation_intents_manager_footer")
            }

            Section {
                editLink(.new) {
                    Label("ai_recommendation_custom_add", systemImage: "plus")
                }
                .disabled(!canAddIntent)
                if hasHiddenPresets {
                    Button("ai_recommendation_presets_restore", systemImage: "arrow.counterclockwise") {
                        restoreHiddenPresets()
                    }
                }
            }
        }
    }

    private func row(for option: AIRecommendationIntentOption) -> some View {
        editLink(.existing(option)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: option.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if option.isModifiedPreset {
                        Text("ai_recommendation_intent_modified")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                Text(verbatim: option.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        #if os(iOS)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                remove(option)
            } label: {
                Label("ai_recommendation_custom_remove", systemImage: "trash")
            }
        }
        #else
        .contextMenu {
            Button(role: .destructive) {
                remove(option)
            } label: {
                Label("ai_recommendation_custom_remove", systemImage: "trash")
            }
        }
        #endif
    }

    /// iPhone、iPad 推进去;Mac 的弹框里不推导航,另开一个弹框。
    @ViewBuilder
    private func editLink<RowLabel: View>(
        _ target: AIRecommendationIntentEditTarget,
        @ViewBuilder label: () -> RowLabel
    ) -> some View {
        #if os(iOS)
        NavigationLink {
            editor(for: target)
        } label: {
            label()
        }
        #else
        Button {
            editingTarget = target
        } label: {
            HStack(spacing: 8) {
                label()
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #endif
    }

    private func editor(for target: AIRecommendationIntentEditTarget) -> some View {
        let option = target.option
        var removal: (() -> Void)?
        var presetRestore: (() -> Void)?
        if let option {
            removal = { remove(option) }
            if option.isModifiedPreset, case .preset(let preset) = option.source {
                presetRestore = { restorePreset(preset) }
            }
        }
        return AIRecommendationIntentEditor(
            target: target,
            options: options,
            onSave: { title, prompt in save(target, title: title, prompt: prompt) },
            onRemove: removal,
            onRestorePreset: presetRestore
        )
    }

    private func save(_ target: AIRecommendationIntentEditTarget, title: String, prompt: String) {
        switch target {
        case .new:
            guard canAddIntent,
                  let intent = AIRecommendationIntentStoragePolicy.makeIntent(title: title, prompt: prompt)
            else { return }
            customIntentsRawValue = AIRecommendationIntentStoragePolicy.encode(customIntents + [intent])
            CloudKVSSync.shared.markChanged(key: CloudKVSKey.aiRecommendationIntents)
            // 在推荐页上加的方向多半就是要马上用的。
            select(intent.selectionID)
        case .existing(let option):
            switch option.source {
            case .defaultSelection:
                return
            case .preset(let preset):
                presetOverridesRawValue = AIRecommendationIntentPresetOverridePolicy.setting(
                    preset,
                    title: title,
                    prompt: prompt,
                    in: presetOverridesRawValue
                )
                CloudKVSSync.shared.markChanged(key: CloudKVSKey.aiRecommendationPresetOverrides)
            case .custom(let id):
                guard let updated = AIRecommendationIntentStoragePolicy.updating(
                    id: id,
                    title: title,
                    prompt: prompt,
                    in: customIntents
                ) else { return }
                customIntentsRawValue = AIRecommendationIntentStoragePolicy.encode(updated)
                CloudKVSSync.shared.markChanged(key: CloudKVSKey.aiRecommendationIntents)
            }
        }
    }

    private func remove(_ option: AIRecommendationIntentOption) {
        switch option.source {
        case .defaultSelection:
            return
        case .preset(let preset):
            hiddenPresetsRawValue = AIRecommendationIntentPresetVisibilityPolicy.hiding(
                preset,
                in: hiddenPresetsRawValue
            )
            CloudKVSSync.shared.markChanged(key: CloudKVSKey.aiRecommendationHiddenPresets)
            // 移除时连改写一起丢掉,以后「恢复内置方向」拿回来的是原样。
            if AIRecommendationIntentPresetOverridePolicy.override(for: preset, in: presetOverridesRawValue) != nil {
                restorePreset(preset)
            }
        case .custom(let id):
            customIntentsRawValue = AIRecommendationIntentStoragePolicy.encode(
                customIntents.filter { $0.id != id }
            )
            CloudKVSSync.shared.markChanged(key: CloudKVSKey.aiRecommendationIntents)
        }
        if selectedIntentID == option.id {
            select(AIRecommendationIntentSelectionPolicy.defaultSelectionID)
        }
    }

    private func restorePreset(_ preset: AIRecommendationIntentPreset) {
        presetOverridesRawValue = AIRecommendationIntentPresetOverridePolicy.removing(
            preset,
            in: presetOverridesRawValue
        )
        CloudKVSSync.shared.markChanged(key: CloudKVSKey.aiRecommendationPresetOverrides)
    }

    private func restoreHiddenPresets() {
        hiddenPresetsRawValue = AIRecommendationIntentPresetVisibilityPolicy.restoringAll()
        CloudKVSSync.shared.markChanged(key: CloudKVSKey.aiRecommendationHiddenPresets)
    }

    private func select(_ selectionID: String) {
        selectedIntentID = selectionID
        CloudKVSSync.shared.markChanged(key: CloudKVSKey.aiRecommendationSelectedIntent)
    }
}

/// 改一条选歌方向的名字和交给智能服务的提示词。
private struct AIRecommendationIntentEditor: View {
    let target: AIRecommendationIntentEditTarget
    /// 推荐页上现有的全部方向,查重名用。
    let options: [AIRecommendationIntentOption]
    let onSave: (_ title: String, _ prompt: String) -> Void
    let onRemove: (() -> Void)?
    let onRestorePreset: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(MusicIntelligenceService.self) private var intelligence
    @State private var title: String
    @State private var prompt: String
    private let initialTitle: String
    private let initialPrompt: String

    init(
        target: AIRecommendationIntentEditTarget,
        options: [AIRecommendationIntentOption],
        onSave: @escaping (_ title: String, _ prompt: String) -> Void,
        onRemove: (() -> Void)?,
        onRestorePreset: (() -> Void)?
    ) {
        self.target = target
        self.options = options
        self.onSave = onSave
        self.onRemove = onRemove
        self.onRestorePreset = onRestorePreset
        let title = target.option?.title ?? ""
        let prompt = target.option?.prompt ?? ""
        _title = State(initialValue: title)
        _prompt = State(initialValue: prompt)
        initialTitle = title
        initialPrompt = prompt
    }

    /// 内置 AI 收 160 字,只用自己的服务时放开。
    private var promptLimit: Int {
        intelligence.promptCharacterLimit(for: .recommendations)
    }

    private var hasTitleConflict: Bool {
        AIRecommendationIntentCatalog.hasTitleConflict(title, excludingID: target.option?.id, in: options)
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasTitleConflict
            && (title != initialTitle || prompt != initialPrompt)
    }

    private var screenTitle: String {
        target.option?.title ?? String(localized: "ai_recommendation_custom_add")
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            MacSheetHeader(Text(verbatim: screenTitle), systemImage: "wand.and.stars", onClose: { dismiss() })
            form
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            MacSheetFooter {
                Button("cancel") { dismiss() }
                    .buttonStyle(MacSheetButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("save") { save() }
                    .buttonStyle(MacSheetButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .frame(width: 480, height: 500)
        .background(PMColor.bg)
        #else
        form
            .navigationTitle(Text(verbatim: screenTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") { save() }
                        .disabled(!canSave)
                }
            }
        #endif
    }

    private var form: some View {
        Form {
            Section {
                TextField("ai_recommendation_custom_title_placeholder", text: $title)
                    .onChange(of: title) { _, value in
                        let limit = AIRecommendationIntentStoragePolicy.maximumTitleLength
                        if value.count > limit { title = String(value.prefix(limit)) }
                    }
                    .accessibilityIdentifier("library.recommendations.directionTitle")
            } header: {
                Text("ai_recommendation_intent_name_label")
            } footer: {
                if hasTitleConflict {
                    Text("ai_recommendation_intent_title_conflict")
                        .foregroundStyle(.red)
                }
            }

            Section {
                TextField("ai_recommendation_custom_prompt_placeholder", text: $prompt, axis: .vertical)
                    .lineLimit(4...12)
                    .onChange(of: prompt) { _, value in
                        if value.count > promptLimit { prompt = String(value.prefix(promptLimit)) }
                    }
                    .accessibilityIdentifier("library.recommendations.directionPrompt")
            } header: {
                Text("ai_recommendation_intent_prompt_label")
            } footer: {
                Text("ai_recommendation_intent_prompt_footer \(prompt.count) \(promptLimit)")
            }

            if let onRestorePreset {
                Section {
                    Button("ai_recommendation_intent_restore_preset", systemImage: "arrow.uturn.backward") {
                        onRestorePreset()
                        dismiss()
                    }
                }
            }

            if let onRemove {
                Section {
                    Button("ai_recommendation_custom_remove", systemImage: "trash", role: .destructive) {
                        onRemove()
                        dismiss()
                    }
                }
            }
        }
    }

    private func save() {
        guard canSave else { return }
        onSave(title, prompt)
        dismiss()
    }
}

/// 「推荐场景」:哪些场景排在推荐页上,每个场景每次加载几首、多久重新问一次智能服务、要不要推荐 MV。
private struct AIRecommendationSceneSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MusicIntelligenceService.self) private var intelligence
    @AppStorage(AIRecommendationSceneConfigurationPolicy.storageKey)
    private var configurationRawValue = ""
    @AppStorage(AIRecommendationRefreshInterval.storageKey)
    private var defaultRefreshRawValue = AIRecommendationRefreshInterval.defaultInterval.rawValue
    @State private var expandedScenes: Set<AIRecommendationScene>

    init(initiallyExpandedScene: AIRecommendationScene) {
        _expandedScenes = State(initialValue: [initiallyExpandedScene])
    }

    private var configuration: AIRecommendationSceneConfiguration {
        AIRecommendationSceneConfigurationPolicy.decode(configurationRawValue)
    }

    /// 「跟随默认」后面写上默认此刻实际是哪一档(「智能」设置里的刷新频率)。
    private var defaultRefreshTitle: String {
        let resolved = intelligence.resolvedRecommendationRefreshInterval(
            AIRecommendationRefreshInterval.stored(defaultRefreshRawValue)
        )
        return String(
            format: String(localized: "ai_recommendation_scene_refresh_default_format"),
            resolved.localizedTitle
        )
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            MacSheetHeader(
                Text("ai_recommendation_scenes_title"),
                systemImage: "slider.horizontal.3",
                onClose: { dismiss() }
            )
            form
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
        }
        .frame(width: 520, height: 600)
        .background(PMColor.bg)
        #else
        NavigationStack {
            form
                .navigationTitle("ai_recommendation_scenes_title")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("done") { dismiss() }
                    }
                }
        }
        #endif
    }

    private var form: some View {
        Form {
            Section {
                ForEach(AIRecommendationScene.allCases, id: \.self) { scene in
                    AIRecommendationSceneSettingsGroup(
                        scene: scene,
                        configuration: configuration,
                        defaultRefreshTitle: defaultRefreshTitle,
                        isExpanded: expansionBinding(for: scene),
                        update: update
                    )
                }
            } footer: {
                Text("ai_recommendation_scenes_footer")
            }
        }
    }

    private func expansionBinding(for scene: AIRecommendationScene) -> Binding<Bool> {
        Binding(
            get: { expandedScenes.contains(scene) },
            set: { isExpanded in
                if isExpanded {
                    expandedScenes.insert(scene)
                } else {
                    expandedScenes.remove(scene)
                }
            }
        )
    }

    private func update(_ change: (inout AIRecommendationSceneConfiguration) -> Void) {
        var value = configuration
        change(&value)
        let encoded = AIRecommendationSceneConfigurationPolicy.encode(value)
        guard encoded != configurationRawValue else { return }
        configurationRawValue = encoded
        CloudKVSSync.shared.markChanged(key: CloudKVSKey.aiRecommendationScenes)
    }
}

/// 「推荐场景」里的一个场景:收起时一行名字和概况,展开是它的几项设置。
private struct AIRecommendationSceneSettingsGroup: View {
    let scene: AIRecommendationScene
    let configuration: AIRecommendationSceneConfiguration
    let defaultRefreshTitle: String
    @Binding var isExpanded: Bool
    let update: ((inout AIRecommendationSceneConfiguration) -> Void) -> Void

    private var settings: AIRecommendationSceneSettings {
        configuration.settings(for: scene)
    }

    private var isVisible: Bool {
        configuration.isVisible(scene)
    }

    private var accentColor: Color {
        #if os(macOS)
        PMColor.brand
        #else
        Color.accentColor
        #endif
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Toggle("ai_recommendation_scene_visible", isOn: visibilityBinding)
                .disabled(isVisible && !configuration.canHide(scene))
            Picker("ai_recommendation_scene_song_count", selection: settingBinding(\.songCount)) {
                ForEach(AIRecommendationSceneSettings.songCountChoices, id: \.self) { count in
                    Text(verbatim: Self.songCountText(count)).tag(count)
                }
            }
            .pickerStyle(.menu)
            Picker("ai_recommendation_refresh_interval", selection: settingBinding(\.refreshInterval)) {
                Text(verbatim: defaultRefreshTitle).tag(AIRecommendationRefreshInterval?.none)
                ForEach(AIRecommendationSceneSettings.refreshIntervalChoices, id: \.self) { interval in
                    Text(verbatim: interval.localizedTitle).tag(Optional(interval))
                }
            }
            .pickerStyle(.menu)
            Toggle("ai_recommendation_scene_shows_music_videos", isOn: settingBinding(\.showsMusicVideos))
            if settings != .default {
                Button("Restore Defaults", systemImage: "arrow.counterclockwise") {
                    update { $0.setSettings(.default, for: scene) }
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: scene.recommendationIcon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isVisible ? accentColor : Color.secondary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: scene.localizedName)
                        .foregroundStyle(isVisible ? Color.primary : Color.secondary)
                    Text(verbatim: summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier("library.recommendations.scene." + scene.rawValue)
    }

    private var summary: String {
        guard isVisible else { return String(localized: "ai_recommendation_scene_hidden") }
        var parts = [
            Self.songCountText(settings.songCount),
            settings.refreshInterval?.localizedTitle
                ?? String(localized: "ai_recommendation_scene_refresh_default_short"),
        ]
        if !settings.showsMusicVideos {
            parts.append(String(localized: "ai_recommendation_scene_no_music_videos"))
        }
        return parts.joined(separator: " · ")
    }

    private static func songCountText(_ count: Int) -> String {
        String(format: String(localized: "ai_recommendation_scene_song_count_format"), count)
    }

    private var visibilityBinding: Binding<Bool> {
        Binding(
            get: { isVisible },
            set: { visible in update { $0.setVisible(visible, for: scene) } }
        )
    }

    private func settingBinding<Value>(
        _ keyPath: WritableKeyPath<AIRecommendationSceneSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                update { configuration in
                    var next = configuration.settings(for: scene)
                    next[keyPath: keyPath] = value
                    configuration.setSettings(next, for: scene)
                }
            }
        )
    }
}

/// 「多久后可重试」。一分钟以内按秒倒数；按天、按月的额度用完时服务端给的是到下个周期的时间，
/// 按天、小时、分钟说，不写成几十万秒。
enum AIRetryCountdown {
    static func text(until retryAt: Date, now: Date) -> String {
        let seconds = max(0, Int(ceil(retryAt.timeIntervalSince(now))))
        guard seconds >= 60 else {
            return String(format: String(localized: "ai_recommendation_retry_countdown_format"), seconds)
        }
        let remaining = Duration.seconds(seconds).formatted(.units(
            allowed: [.days, .hours, .minutes],
            width: .abbreviated,
            maximumUnitCount: 2,
            fractionalPart: .hide(rounded: .up)
        ))
        return String(format: String(localized: "ai_recommendation_retry_after_format"), remaining)
    }
}
