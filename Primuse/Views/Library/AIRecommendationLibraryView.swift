import SwiftUI
import PrimuseKit

private struct AIRecommendationIntentChoice: Identifiable, Hashable {
    var id: String
    var title: String
    var detail: String
    var semanticIntent: String?

    static func all(
        customRawValue: String,
        hiddenPresetsRawValue: String
    ) -> [AIRecommendationIntentChoice] {
        let visiblePresets = [AIRecommendationIntentPreset.balanced]
            + AIRecommendationIntentPresetVisibilityPolicy.visiblePresets(
                hiddenPresetsRawValue
            )
        let presets = visiblePresets.map { preset in
            AIRecommendationIntentChoice(
                id: preset.selectionID,
                title: preset.localizedTitle,
                detail: preset.localizedDetail,
                semanticIntent: preset.semanticIntent
            )
        }
        let custom = AIRecommendationIntentStoragePolicy.decode(customRawValue).map { intent in
            AIRecommendationIntentChoice(
                id: intent.selectionID,
                title: intent.title,
                detail: intent.prompt,
                semanticIntent: intent.prompt
            )
        }
        return presets + custom
    }
}

/// A library-sized recommendation destination. The local discovery engine is
/// always the source of playable candidates; a configured remote provider may
/// only reorder those candidates and explain the result.
struct AIRecommendationLibraryView: View {
    private static let recommendationPoolSize = 36
    private static let recommendationPageSize = 12
    private static let minimumRecommendationPageSize = 10

    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(CoverTintProvider.self) private var tintProvider
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AIRecommendationIntentStoragePolicy.storageKey)
    private var customIntentsRawValue = ""
    @AppStorage(AIRecommendationIntentPresetVisibilityPolicy.storageKey)
    private var hiddenPresetsRawValue = ""
    @AppStorage(AIRecommendationIntentSelectionPolicy.storageKey)
    private var selectedIntentID = AIRecommendationIntentSelectionPolicy.defaultSelectionID
    @AppStorage("primuse.ai.recommendationScene.v1")
    private var recommendationSceneRawValue = AIRecommendationScene.automatic.rawValue

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
    #if os(macOS)
    @State private var showsSongDiscovery = false
    /// 给了就是 Mac 窗口右侧的推荐面板: 一行标题带全部播放与关闭, 歌单成一列紧凑的行。
    private let panelOnClose: (() -> Void)?

    init(panelOnClose: (() -> Void)? = nil) {
        self.panelOnClose = panelOnClose
    }

    private var isPanel: Bool { panelOnClose != nil }
    #endif

    private var intentChoices: [AIRecommendationIntentChoice] {
        AIRecommendationIntentChoice.all(
            customRawValue: customIntentsRawValue,
            hiddenPresetsRawValue: hiddenPresetsRawValue
        )
    }

    private var effectiveSelectedIntentID: String {
        AIRecommendationIntentSelectionPolicy.normalizedSelectionID(
            selectedIntentID,
            availableSelectionIDs: Set(intentChoices.map(\.id))
        )
    }

    private var selectedIntent: AIRecommendationIntentChoice {
        intentChoices.first { $0.id == effectiveSelectedIntentID }
            ?? intentChoices[0]
    }

    private var recommendationScene: AIRecommendationScene {
        AIRecommendationScene(rawValue: recommendationSceneRawValue) ?? .automatic
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
            recommendationSceneRawValue,
            selectedIntent.id,
            customIntentsRawValue,
            hiddenPresetsRawValue,
            String(library.visibleSongCollectionRevision),
            library.songReplacementToken.uuidString,
            String(intelligence.settingsStore.revision),
            String(intelligence.regionAvailability.revision),
            String(historyRevision),
        ].joined(separator: "#")
    }

    private var localContentRevision: String {
        [
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
        .onAppear(perform: normalizeIntentSelectionIfNeeded)
        .onChange(of: selectedIntentID) { _, _ in
            normalizeIntentSelectionIfNeeded()
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
        .onChange(of: customIntentsRawValue) { _, _ in
            normalizeIntentSelectionIfNeeded()
        }
        .onChange(of: hiddenPresetsRawValue) { _, _ in
            normalizeIntentSelectionIfNeeded()
        }
        .onChange(of: aiRecommendation.orderedSongIDs) { _, _ in
            appendNewStreamingRecommendationsToOwnedQueue()
        }
        .onDisappear {
            streamedQueueSongIDs = nil
        }
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
                if !musicVideoPicks.isEmpty {
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
        .task(id: musicVideoRefreshKey) { refreshMusicVideoPicks() }
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
                            Image(systemName: "slider.horizontal.3")
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

                    ForEach(AIRecommendationScene.allCases, id: \.self) { scene in
                        let isSelected = recommendationScene == scene
                        Button {
                            recommendationSceneRawValue = scene.rawValue
                        } label: {
                            Label(scene.localizedName, systemImage: sceneIcon(scene))
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

    private func sceneIcon(_ scene: AIRecommendationScene) -> String {
        switch scene {
        case .automatic: "sparkles"
        case .driving: "car.fill"
        case .focus: "brain.head.profile"
        case .workout: "figure.run"
        case .relaxation: "leaf.fill"
        case .bedtime: "moon.stars.fill"
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

    private var musicVideoRefreshKey: String {
        [
            String(library.musicVideoSongs.count),
            library.musicVideoSongs.first?.id ?? "",
            localResults.prefix(12).map(\.song.id).joined(separator: ","),
            String(HomeHeroRecommendationPolicy.dayStamp(Date())),
        ].joined(separator: "#")
    }

    private func refreshMusicVideoPicks() {
        let videos = library.musicVideoSongs
        guard !videos.isEmpty else {
            if !musicVideoPicks.isEmpty { musicVideoPicks = [] }
            return
        }
        var seen = Set<String>()
        let artistIDs = localResults.compactMap(\.song.artistID).filter { seen.insert($0).inserted }
        let byID = Dictionary(videos.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = MusicVideoRecommendationPolicy.recommended(
            videos.map { .init(id: $0.id, artistID: $0.artistID, dateAdded: $0.dateAdded) },
            favoriteArtistIDs: artistIDs,
            recentlyPlayedIDs: [],
            now: Date(),
            day: HomeHeroRecommendationPolicy.dayStamp(Date()),
            limit: 10
        )
        let next = ids.compactMap { byID[$0] }
        if next.map(\.id) != musicVideoPicks.map(\.id) { musicVideoPicks = next }
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
                        Image(systemName: "slider.horizontal.3")
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
                    ForEach(AIRecommendationScene.allCases, id: \.self) { scene in
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
        let recommendationPoolSize = Self.recommendationPoolSize
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
            intent: selectedIntent.semanticIntent,
            candidates: results.map(\.song),
            using: intelligence,
            forceRefresh: forceAIRefresh,
            maximumResults: Self.recommendationPageSize,
            minimumResults: Self.minimumRecommendationPageSize,
            reuseSurface: .library
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

        let appended = await aiRecommendation.refresh(
            scene: recommendationScene,
            intent: selectedIntent.semanticIntent,
            candidates: remaining.map(\.song),
            using: intelligence,
            maximumResults: Self.recommendationPageSize,
            minimumResults: min(Self.minimumRecommendationPageSize, remaining.count),
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

    private func normalizeIntentSelectionIfNeeded() {
        let normalizedID = effectiveSelectedIntentID
        guard normalizedID != selectedIntentID else { return }
        selectIntent(normalizedID)
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
