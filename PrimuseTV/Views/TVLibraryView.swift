#if os(tvOS)
import SwiftUI
import PrimuseKit

/// 资料库网格的浏览位置。播放专辑会切到「正在播放」,资料库整页随之移出视图树;
/// 回来时靠它把渲染范围、滚动位置和焦点放回上次那张卡片,不再从头找起。
/// 普通引用类型而非 @Observable:焦点每挪一格就写一次,不能因此让资料库整页重算。
@MainActor
final class TVLibraryBrowseMemory {
    var albumID: String?
    var artistID: String?
}

enum TVLibraryBackgroundWorkPolicy {
    static func refreshesRecommendations(for filter: TVLibraryView.Filter) -> Bool {
        filter == .recommendations
    }
}

/// tvOS 资料库 — 筛选条 + 网格(对应 tvos.jsx 的 TVLibraryArtboard)。
struct TVLibraryView: View {
    @Environment(TVStore.self) private var store
    @Environment(MusicIntelligenceService.self) private var intelligence
    var openPlayer: () -> Void = {}
    var onReturnToTabs: () -> Void = {}
    var onModalActivityChanged: (Bool) -> Void = { _ in }

    enum Filter: String, CaseIterable, Identifiable {
        // 电台已是与音乐并列的一级页(TVRadioPageView),不再是资料库里的一个筛选。
        case albums, songs, artists, genres, folders, recommendations, ranking
        var id: String { rawValue }
        var display: String {
            switch self {
            case .albums: return String(localized: "tab_albums")
            case .songs: return String(localized: "tab_songs")
            case .artists: return String(localized: "tab_artists")
            case .genres: return String(localized: "tab_genres")
            case .folders: return TVDiscoveryText.string("folders")
            case .recommendations: return PMString("library_recommendations_title")
            case .ranking: return TVDiscoveryText.string("ranking")
            }
        }
        var icon: String {
            switch self {
            case .albums: return "square.stack"
            case .songs: return "music.note"
            case .artists: return "person.2"
            case .genres: return "guitars"
            case .folders: return "folder"
            case .recommendations: return "sparkles"
            case .ranking: return "chart.bar"
            }
        }
    }
    @Binding var filter: Filter
    @State private var recommendationCandidates: [Song] = []
    @State private var aiRecommendation = AIRecommendationViewModel()
    @AppStorage(AIRecommendationIntentStoragePolicy.storageKey)
    private var customRecommendationIntentsRawValue = ""
    @AppStorage(AIRecommendationIntentPresetVisibilityPolicy.storageKey)
    private var hiddenRecommendationPresetsRawValue = ""
    @AppStorage(AIRecommendationIntentSelectionPolicy.storageKey)
    private var selectedRecommendationIntentID =
        AIRecommendationIntentSelectionPolicy.defaultSelectionID
    @FocusState private var focusedFilter: Filter?
    /// 网格里的专辑 / 艺人卡片,值见 `albumFocusID` / `artistFocusID`。
    @FocusState private var focusedGridItem: String?
    @State private var selectedArtist: TVArtist?
    @State private var opensPlayerAfterArtistDismissal = false
    @State private var selectedAlbum: TVAlbum?

    #if DEBUG
    /// 截图用的 `albumDetail` 只在首次进资料库时打开一次。
    @MainActor private static var didOpenDebugAlbumDetail = false
    #endif

    private let cols = 4
    private let gap: CGFloat = 28
    var focusRequest = 0
    var browseMemory = TVLibraryBrowseMemory()

    var body: some View {
        GeometryReader { geo in
            let contentW = geo.size.width - TVSpace.pageH * 2 - 28
            let cell = max(140, (contentW - gap * CGFloat(cols - 1)) / CGFloat(cols))
            VStack(alignment: .leading, spacing: 24) {
                filterStrip
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 30) {
                            Text(title).tvFont(.pageTitle).foregroundStyle(TVColor.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id("tv.library.contentTop")
                            grid(cell: cell, onFolderNavigation: {
                                proxy.scrollTo("tv.library.contentTop", anchor: .top)
                            })
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .padding(.bottom, TVSpace.pageBottom)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
                    .onAppear { revealBrowseAnchor(with: proxy) }
                    .id(filter)
                }
            }
            .padding(.horizontal, TVSpace.pageH)
            .padding(.top, TVSpace.pageTop)
        }
        .background(TVColor.bg)
        // 焦点停在网格深处时,第一次 Menu 先回到筛选条(网格位置不动),再按一次才回顶栏。
        .onExitCommand {
            if focusedGridItem != nil {
                focusedFilter = filter
            } else {
                onReturnToTabs()
            }
        }
        .onChange(of: focusRequest) { restoreContentFocus() }
        .onAppear(perform: normalizeRecommendationIntentSelectionIfNeeded)
        .onChange(of: selectedRecommendationIntentID) { _, _ in
            normalizeRecommendationIntentSelectionIfNeeded()
        }
        .onChange(of: customRecommendationIntentsRawValue) { _, _ in
            normalizeRecommendationIntentSelectionIfNeeded()
        }
        .onChange(of: hiddenRecommendationPresetsRawValue) { _, _ in
            normalizeRecommendationIntentSelectionIfNeeded()
        }
        .task(id: recommendationTaskKey) {
            guard TVLibraryBackgroundWorkPolicy.refreshesRecommendations(for: filter) else {
                return
            }
            let candidates = await store.recommendationCandidates(limit: 24)
            guard !Task.isCancelled,
                  TVLibraryBackgroundWorkPolicy.refreshesRecommendations(for: filter) else {
                return
            }
            recommendationCandidates = candidates
            await aiRecommendation.refresh(
                scene: .automatic,
                intent: selectedRecommendationIntent?.semanticIntent,
                candidates: candidates,
                using: intelligence
            )
        }
        .fullScreenCover(item: $selectedArtist, onDismiss: finishArtistDismissal) { artist in
            TVArtistDetailView(
                artist: artist,
                openPlayer: { opensPlayerAfterArtistDismissal = true }
            )
                .environment(store)
        }
        .onChange(of: selectedArtist) { _, artist in
            onModalActivityChanged(artist != nil)
        }
        .onDisappear {
            if selectedArtist != nil {
                onModalActivityChanged(false)
            }
        }
        .modifier(TVAlbumDetailPresenter(
            album: $selectedAlbum,
            openPlayer: openPlayer,
            onPresentationChanged: onModalActivityChanged
        ))
        #if DEBUG
        .task {
            guard TVDebugLaunch.screen == "albumDetail", !Self.didOpenDebugAlbumDetail else { return }
            Self.didOpenDebugAlbumDetail = true
            var tries = 0
            while store.albums.isEmpty && tries < 25 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                tries += 1
            }
            selectedAlbum = store.albums.first { (4...40).contains(store.songs(forAlbum: $0.id).count) }
                ?? store.albums.first
        }
        #endif
    }

    private static func albumFocusID(_ id: String) -> String { "album:" + id }
    private static func artistFocusID(_ id: String) -> String { "artist:" + id }

    /// 当前筛选下记住的那张卡片;已从曲库消失的不算。
    private var browseAnchorFocusID: String? {
        switch filter {
        case .albums:
            guard let id = browseMemory.albumID, store.album(id) != nil else { return nil }
            return Self.albumFocusID(id)
        case .artists:
            guard let id = browseMemory.artistID, store.artists.contains(where: { $0.id == id }) else {
                return nil
            }
            return Self.artistFocusID(id)
        default:
            return nil
        }
    }

    /// 网格重建后先滚到记住的卡片:懒加载网格只为可见区域建视图,
    /// 不滚过去,稍后按下方向键时那张卡片还不存在,焦点就放不上去。
    private func revealBrowseAnchor(with proxy: ScrollViewProxy) {
        let anchor: String?
        switch filter {
        case .albums: anchor = browseMemory.albumID
        case .artists: anchor = browseMemory.artistID
        default: anchor = nil
        }
        guard let anchor, browseAnchorFocusID != nil else { return }
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(anchor, anchor: .center)
        }
    }

    /// 从顶栏按下、关掉弹层之后焦点回到哪:有记住的卡片就回到它,否则落在筛选条。
    private func restoreContentFocus() {
        if let focusID = browseAnchorFocusID {
            focusedGridItem = focusID
        } else {
            focusedFilter = filter
        }
    }

    private var title: String {
        switch filter {
        case .albums: return PMString("ext.tv.library.title.albums", store.albums.count)
        case .recommendations: return PMString("library_recommendations_title")
        case .artists: return PMString("ext.tv.library.title.artists", store.artists.count)
        case .songs: return PMString("ext.tv.library.title.songs", TVFmt.count(store.songs.count))
        case .genres, .folders, .ranking: return filter.display
        }
    }

    private var filterStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(PMString("ext.tv.library.eyebrow")).tvFont(.eyebrow)
                .foregroundStyle(TVColor.textMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(Filter.allCases) { item in
                        Button { filter = item } label: {
                            Label(item.display, systemImage: item.icon)
                                .tvFont(.caption, weight: item == filter ? .semibold : .regular)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .frame(minHeight: 64)
                                .padding(.horizontal, 18)
                                .foregroundStyle(item == filter ? TVColor.onBrand : TVColor.text)
                                .background(item == filter ? TVColor.brand : TVColor.card, in: .rect(cornerRadius: 14))
                                .tvFocusRing(focusedFilter == item, radius: 14, scale: 1.02, lift: 0)
                        }
                        .buttonStyle(TVBareButtonStyle())
                        .focused($focusedFilter, equals: item)
                        .focusEffectDisabled()
                        .accessibilityIdentifier("tv.library.category." + item.rawValue)
                        .accessibilityAddTraits(item == filter ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            .frame(height: 80)
        }
        .focusSection()
    }

    @ViewBuilder
    private func grid(cell: CGFloat, onFolderNavigation: @escaping () -> Void) -> some View {
        let columns = Array(repeating: GridItem(.fixed(cell), spacing: gap, alignment: .top), count: cols)
        switch filter {
        case .albums:
            TVPagedGrid(
                items: store.albums, columns: columns, spacing: gap,
                revealing: browseMemory.albumID
            ) { index, album, focusChanged in
                TVAlbumCard(album: album, width: cell,
                            subtitleOverride: album.year > 0 ? "\(album.artist) · \(album.year)" : album.artist,
                            action: openPlayer,
                            onFocusChanged: { focused in
                                focusChanged(focused)
                                if focused { browseMemory.albumID = album.id }
                            },
                            onOpen: { selectedAlbum = album },
                            focusBinding: $focusedGridItem,
                            focusID: Self.albumFocusID(album.id))
                    .accessibilityIdentifier("tv.library.album.\(index)")
            }
        case .recommendations:
            VStack(alignment: .leading, spacing: 22) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(recommendationIntents) { intent in
                            TVFocusButton(
                                radius: 18,
                                scale: 1.05,
                                lift: 4,
                                action: {
                                    selectedRecommendationIntentID = intent.id
                                    CloudKVSSync.shared.markChanged(
                                        key: CloudKVSKey.aiRecommendationSelectedIntent
                                    )
                                }
                            ) { focused in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(intent.title)
                                        .tvFont(.caption, weight: .semibold)
                                    Text(intent.detail)
                                        .tvFont(.meta)
                                        .lineLimit(2, reservesSpace: true)
                                        .opacity(0.75)
                                }
                                .foregroundStyle(
                                    effectiveSelectedRecommendationIntentID == intent.id
                                        ? TVColor.onBrand : TVColor.text
                                )
                                .padding(.horizontal, 24)
                                .frame(width: 250, height: 110, alignment: .leading)
                                .background(
                                    effectiveSelectedRecommendationIntentID == intent.id
                                        ? TVColor.brand
                                        : (focused ? TVColor.surfaceStrong : TVColor.surface),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                if let selectedRecommendationIntent {
                    recommendationIntentDetails(selectedRecommendationIntent)
                }

                HStack(spacing: 10) {
                    Image(systemName: aiRecommendation.summaryText == nil
                          ? "iphone.and.arrow.forward" : "sparkles")
                    Text(aiRecommendation.statusText)
                    if let summary = aiRecommendation.summaryText {
                        Text("· \(summary)").foregroundStyle(TVColor.textMuted)
                    }
                }
                .tvFont(.caption, weight: .semibold)
                .foregroundStyle(TVColor.text)

                let recommendationSongs = displayedRecommendationSongs
                let recommendationQueueSongIDs = recommendationSongs.map(\.id)
                LazyVStack(spacing: 10) {
                    ForEach(recommendationSongs) { song in
                        TVSongRow(
                            song: song,
                            reason: aiRecommendation.reason(for: song.id),
                            queueSongIDs: recommendationQueueSongIDs,
                            action: openPlayer
                        )
                    }
                }
            }
        case .artists:
            TVPagedGrid(
                items: store.artists, columns: columns, spacing: gap,
                revealing: browseMemory.artistID
            ) { index, artist, focusChanged in
                TVArtistCard(
                    artist: artist,
                    size: cell * 0.82,
                    action: { selectedArtist = artist },
                    onFocusChanged: { focused in
                        focusChanged(focused)
                        if focused { browseMemory.artistID = artist.id }
                    },
                    focusBinding: $focusedGridItem,
                    focusID: Self.artistFocusID(artist.id)
                )
                    .frame(width: cell)
                    .accessibilityIdentifier("tv.library.artist.\(index)")
            }
        case .songs:
            TVPagedSongIDList(songIDs: store.songIDs, alignment: .leading, action: openPlayer)
        case .genres:
            TVGenreBrowser(openPlayer: openPlayer, onModalActivityChanged: onModalActivityChanged)
        case .folders:
            TVFolderBrowser(openPlayer: openPlayer, onNavigation: onFolderNavigation)
        case .ranking:
            TVRankingBrowser(openPlayer: openPlayer, onModalActivityChanged: onModalActivityChanged)
        }
    }

    private enum RecommendationIntentKind {
        case defaultSelection
        case preset(AIRecommendationIntentPreset)
        case custom(UUID)
    }

    private struct RecommendationIntent: Identifiable {
        var id: String
        var title: String
        var detail: String
        var semanticIntent: String?
        var kind: RecommendationIntentKind
    }

    private var recommendationIntents: [RecommendationIntent] {
        let visiblePresets = [AIRecommendationIntentPreset.balanced]
            + AIRecommendationIntentPresetVisibilityPolicy.visiblePresets(
                hiddenRecommendationPresetsRawValue
            )
        let presets = visiblePresets.map { preset in
            RecommendationIntent(
                id: preset.selectionID,
                title: preset.localizedTitle,
                detail: preset.localizedDetail,
                semanticIntent: preset.semanticIntent,
                kind: preset == .balanced ? .defaultSelection : .preset(preset)
            )
        }
        let custom = AIRecommendationIntentStoragePolicy
            .decode(customRecommendationIntentsRawValue)
            .map { intent in
                RecommendationIntent(
                    id: intent.selectionID,
                    title: intent.title,
                    detail: intent.prompt,
                    semanticIntent: intent.prompt,
                    kind: .custom(intent.id)
                )
            }
        return presets + custom
    }

    private var effectiveSelectedRecommendationIntentID: String {
        AIRecommendationIntentSelectionPolicy.normalizedSelectionID(
            selectedRecommendationIntentID,
            availableSelectionIDs: Set(recommendationIntents.map(\.id))
        )
    }

    private var selectedRecommendationIntent: RecommendationIntent? {
        recommendationIntents.first { $0.id == effectiveSelectedRecommendationIntentID }
            ?? recommendationIntents.first
    }

    private var recommendationRefreshKey: String {
        [
            String(store.recommendationRevision),
            effectiveSelectedRecommendationIntentID,
            customRecommendationIntentsRawValue,
            hiddenRecommendationPresetsRawValue,
            String(intelligence.settingsStore.revision),
            String(intelligence.regionAvailability.revision),
        ].joined(separator: "#")
    }

    private var recommendationTaskKey: String {
        TVLibraryBackgroundWorkPolicy.refreshesRecommendations(for: filter)
            ? "active#\(recommendationRefreshKey)"
            : "inactive"
    }

    private func normalizeRecommendationIntentSelectionIfNeeded() {
        let normalizedID = effectiveSelectedRecommendationIntentID
        guard normalizedID != selectedRecommendationIntentID else { return }
        selectedRecommendationIntentID = normalizedID
        CloudKVSSync.shared.markChanged(
            key: CloudKVSKey.aiRecommendationSelectedIntent
        )
    }

    private func removeRecommendationIntent(_ intent: RecommendationIntent) {
        switch intent.kind {
        case .defaultSelection:
            return
        case .preset(let preset):
            hiddenRecommendationPresetsRawValue =
                AIRecommendationIntentPresetVisibilityPolicy.hiding(
                    preset,
                    in: hiddenRecommendationPresetsRawValue
                )
            CloudKVSSync.shared.markChanged(
                key: CloudKVSKey.aiRecommendationHiddenPresets
            )
        case .custom(let id):
            let remaining = AIRecommendationIntentStoragePolicy
                .decode(customRecommendationIntentsRawValue)
                .filter { $0.id != id }
            customRecommendationIntentsRawValue =
                AIRecommendationIntentStoragePolicy.encode(remaining)
            CloudKVSSync.shared.markChanged(
                key: CloudKVSKey.aiRecommendationIntents
            )
        }
    }

    @ViewBuilder
    private func recommendationIntentDetails(_ intent: RecommendationIntent) -> some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text(intent.detail)
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            switch intent.kind {
            case .defaultSelection:
                EmptyView()
            case .preset, .custom:
                TVFocusButton(radius: 12, scale: 1.04, lift: 3) {
                    removeRecommendationIntent(intent)
                } label: { focused in
                    Label(
                        PMString("ai_recommendation_custom_remove"),
                        systemImage: "trash"
                    )
                    .tvFont(.caption, weight: .semibold)
                    .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 60)
                    .background(
                        focused ? TVColor.brand : TVColor.surfaceStrong,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
            }
        }
        .padding(18)
        .background(TVColor.surface, in: RoundedRectangle(cornerRadius: 16))

        if !AIRecommendationIntentPresetVisibilityPolicy
            .hiddenPresets(hiddenRecommendationPresetsRawValue).isEmpty {
            TVFocusButton(radius: 12, scale: 1.03, lift: 2) {
                hiddenRecommendationPresetsRawValue =
                    AIRecommendationIntentPresetVisibilityPolicy.restoringAll()
                CloudKVSSync.shared.markChanged(
                    key: CloudKVSKey.aiRecommendationHiddenPresets
                )
            } label: { focused in
                Label(
                    PMString("ai_recommendation_presets_restore"),
                    systemImage: "arrow.counterclockwise"
                )
                .tvFont(.caption, weight: .semibold)
                .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
                .padding(.horizontal, 16)
                .frame(minHeight: 60)
                .background(
                    focused ? TVColor.brand : TVColor.surfaceStrong,
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
        }
    }

    private var displayedRecommendationSongs: [TVSong] {
        aiRecommendation.orderedSongs(from: recommendationCandidates).compactMap {
            store.song($0.id)
        }
    }

    private func finishArtistDismissal() {
        guard opensPlayerAfterArtistDismissal else { return }
        opensPlayerAfterArtistDismissal = false
        openPlayer()
    }
}

/// TV artist destination shared by Library and Search. It keeps the artist's
/// queue scope explicit instead of treating an artist card as a player shortcut.
struct TVArtistDetailView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let artist: TVArtist
    var openPlayer: () -> Void = {}

    private var songs: [TVSong] { store.songs(forArtistID: artist.id) }

    var body: some View {
        // 一次算好:歌曲数、列表、播放全部三处都要用,别让同一次刷新反复扫这个艺人。
        let artistSongIDs = songs.map(\.id)
        ZStack {
            TVAmbientBackdrop(tint: artist.tint, tint2: artist.tint2, strength: 0.55)
            TVColor.bg.opacity(0.34).ignoresSafeArea()
            HStack(alignment: .top, spacing: 72) {
                VStack(alignment: .leading, spacing: 24) {
                    TVArtistArtworkView(artist: artist, size: 280)
                    Text(artist.name)
                        .tvFont(.pageTitle)
                        .foregroundStyle(TVColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(PMString("ext.tv.songsCount", artistSongIDs.count))
                        .tvFont(.body)
                        .foregroundStyle(TVColor.textMuted)
                    HStack(spacing: 14) {
                        TVPillButton(
                            title: PMString("ext.tv.home.playAll"),
                            systemImage: "play.fill",
                            style: .solid,
                            action: { play(shuffled: false) }
                        )
                        TVPillButton(
                            title: PMString("ext.tv.home.shuffle"),
                            systemImage: "shuffle",
                            action: { play(shuffled: true) }
                        )
                    }
                    TVMedleyButton(songIDs: artistSongIDs) { openPlayer(); dismiss() }
                    Spacer(minLength: 0)
                }
                .frame(width: 440, alignment: .leading)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        TVEyebrow(text: PMString("ext.tv.search.songs"))
                            .padding(.bottom, 6)
                        if artistSongIDs.isEmpty {
                            TVEmptyState(
                                icon: "music.note",
                                title: PMString("ext.tv.search.noMatch")
                            )
                            .frame(minHeight: 360)
                        } else {
                            TVPagedSongIDList(songIDs: artistSongIDs, alignment: .leading, action: finishPlayback)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                .focusSection()
            }
            .padding(.horizontal, 100)
            .padding(.vertical, 72)
        }
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("tv.artist.detail")
    }

    private func play(shuffled: Bool) {
        guard store.playResolvedQueue(songIDs: songs.map(\.id), shuffled: shuffled) else {
            return
        }
        finishPlayback()
    }

    private func finishPlayback() {
        openPlayer()
        dismiss()
    }
}

/// 专辑页的挂载:由持有专辑卡片的页面(资料库 / 首页 / 搜索)各挂一份。
/// 在专辑页里开始播放时先记下「关闭后去播放页」,等覆盖层真正收起再切换,
/// 不在覆盖层还在时换掉底下的页面。
struct TVAlbumDetailPresenter: ViewModifier {
    @Environment(TVStore.self) private var store
    @Binding var album: TVAlbum?
    var openPlayer: () -> Void
    /// 登记弹层在不在(停掉播放快捷键、压住顶栏的焦点换页),与艺人页用同一条通道。
    var onPresentationChanged: (Bool) -> Void = { _ in }
    @State private var opensPlayerAfterDismissal = false

    func body(content: Content) -> some View {
        content
            .fullScreenCover(item: $album, onDismiss: finishDismissal) { album in
                TVAlbumDetailView(
                    albumID: album.id,
                    fallback: album,
                    openPlayer: { opensPlayerAfterDismissal = true }
                )
                .environment(store)
            }
            .onChange(of: album) { _, album in
                onPresentationChanged(album != nil)
            }
            .onDisappear {
                if album != nil {
                    onPresentationChanged(false)
                }
            }
    }

    private func finishDismissal() {
        guard opensPlayerAfterDismissal else { return }
        opensPlayerAfterDismissal = false
        openPlayer()
    }
}

/// 专辑页:按下专辑封面先看到整张专辑的曲目,从哪一首点下去就从哪一首播,
/// 整张专辑仍是队列。「全部播放 / 随机播放 / 串烧」与艺人页同一排布。
struct TVAlbumDetailView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let albumID: String
    /// 打开时的那份;封面取色、曲库刷新后按 id 重新取。
    let fallback: TVAlbum
    var openPlayer: () -> Void = {}
    @Namespace private var detailFocus

    private struct Track: Identifiable {
        let id: String
        let song: TVSong
        let number: Int
        /// 多碟专辑里每张碟的第一首带上碟号,在它上面画分组标题。
        let discHeader: Int?
    }

    var body: some View {
        let album = store.album(albumID) ?? fallback
        let songs = store.songs(forAlbum: albumID)
        let songIDs = songs.map(\.id)
        let tracks = Self.tracks(for: songs, library: store.library)
        ZStack {
            TVAmbientBackdrop(tint: album.tint, tint2: album.tint2, strength: 0.55)
            TVColor.bg.opacity(0.34).ignoresSafeArea()
            HStack(alignment: .top, spacing: 72) {
                VStack(alignment: .leading, spacing: 22) {
                    TVArtworkView(album: album, size: 300, radius: 18)
                    Text(album.title)
                        .tvFont(.pageTitle)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(album.artist)
                        .tvFont(.body)
                        .foregroundStyle(TVColor.textMuted)
                        .lineLimit(2)
                    Text(verbatim: Self.summary(album: album, songs: songs))
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint)
                    HStack(spacing: 14) {
                        TVPillButton(
                            title: String(localized: "play_all"),
                            systemImage: "play.fill",
                            style: .solid,
                            action: { play(songIDs, shuffled: false) }
                        )
                        .prefersDefaultFocus(true, in: detailFocus)
                        TVPillButton(
                            title: String(localized: "shuffle"),
                            systemImage: "shuffle",
                            action: { play(songIDs, shuffled: true) }
                        )
                    }
                    .disabled(songIDs.isEmpty)
                    TVMedleyButton(songIDs: songIDs) { finishPlayback() }
                    Spacer(minLength: 0)
                }
                .frame(width: 440, alignment: .leading)
                .focusSection()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 10) {
                        TVEyebrow(text: PMString("ext.tv.search.songs"))
                            .padding(.bottom, 6)
                        if tracks.isEmpty {
                            TVEmptyState(
                                icon: "music.note",
                                title: PMString("ext.tv.search.noMatch")
                            )
                            .frame(minHeight: 360)
                        } else {
                            // 「未知专辑」这类大专辑可能上千首,照样分页渲染。
                            TVPagedList(tracks, alignment: .leading, spacing: 10) { _, track, onFocusChanged in
                                VStack(alignment: .leading, spacing: 10) {
                                    if let disc = track.discHeader {
                                        Text(verbatim: "\(String(localized: "disc_label")) \(disc)")
                                            .tvFont(.eyebrow, weight: .semibold)
                                            .foregroundStyle(TVColor.textMuted)
                                            .padding(.top, track.id == tracks.first?.id ? 0 : 18)
                                            .padding(.leading, 22)
                                    }
                                    trackRow(track, albumArtist: album.artist, onFocusChanged: onFocusChanged) {
                                        guard store.play(track.song, in: songIDs) else { return }
                                        finishPlayback()
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                .focusSection()
            }
            .padding(.horizontal, 100)
            .padding(.vertical, 72)
        }
        .focusScope(detailFocus)
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("tv.album.detail")
    }

    private func trackRow(
        _ track: Track,
        albumArtist: String,
        onFocusChanged: @escaping (Bool) -> Void,
        action: @escaping () -> Void
    ) -> some View {
        let song = track.song
        let isCurrent = store.hasNowPlaying && store.currentSongID == song.id
        let showsArtist = !song.artist.isEmpty
            && song.artist.localizedCaseInsensitiveCompare(albumArtist) != .orderedSame
        return TVFocusButton(
            radius: 16, scale: 1.02, lift: 0, ring: false,
            action: action, onFocusChanged: onFocusChanged
        ) { focused in
            HStack(spacing: 22) {
                ZStack(alignment: .trailing) {
                    Text(verbatim: "\(track.number)")
                        .tvFont(.caption, design: .monospaced)
                        .foregroundStyle(TVColor.textFaint)
                        .opacity(isCurrent ? 0 : 1)
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(TVColor.brand)
                        .opacity(isCurrent ? 1 : 0)
                }
                .frame(width: 56, alignment: .trailing)
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).tvFont(.rowTitle)
                        .foregroundStyle(isCurrent ? TVColor.brand : TVColor.text)
                        .lineLimit(1)
                    if showsArtist {
                        Text(song.artist).tvFont(.caption)
                            .foregroundStyle(TVColor.textFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if store.isLiked(song.id) {
                    Image(systemName: "heart.fill").font(.system(size: 22))
                        .foregroundStyle(TVColor.brand)
                }
                Text(TVFmt.time(song.duration))
                    .tvFont(.meta, design: .monospaced)
                    .foregroundStyle(TVColor.textFaint)
            }
            .padding(.horizontal, 22)
            .frame(minHeight: 84)
            .background(focused ? TVColor.surfaceStrong : TVColor.card,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("tv.album.track.\(track.id)")
    }

    /// 年份 · 首数 · 总时长。
    private static func summary(album: TVAlbum, songs: [TVSong]) -> String {
        var parts: [String] = []
        if album.year > 0 { parts.append("\(album.year)") }
        parts.append(PMString("ext.tv.songsCount", songs.count))
        let total = songs.reduce(0) { $0 + TimeInterval.sanitized($1.duration) }
        if total > 0 { parts.append(total.formattedDuration) }
        return parts.joined(separator: " · ")
    }

    /// 轨号取标签里的(CUE 分轨就是 CUE 里的轨号),没有就按专辑里的顺序编号。
    /// `songs(forAlbum:)` 已按碟号、轨号排好,这里只标出每张碟的起点。
    private static func tracks(for songs: [TVSong], library: MusicLibrary) -> [Track] {
        let details = songs.map { library.song(id: $0.id) }
        let discs = Set(details.compactMap { $0?.discNumber }.filter { $0 > 0 })
        let isMultiDisc = discs.count > 1
        var previousDisc: Int?
        return songs.enumerated().map { index, song in
            let detail = details[index]
            let disc = detail?.discNumber ?? 0
            let header: Int?
            if isMultiDisc, disc > 0, disc != previousDisc {
                header = disc
                previousDisc = disc
            } else {
                header = nil
            }
            let number = detail?.trackNumber.flatMap { $0 > 0 ? $0 : nil } ?? index + 1
            return Track(id: song.id, song: song, number: number, discHeader: header)
        }
    }

    private func play(_ songIDs: [String], shuffled: Bool) {
        guard store.playResolvedQueue(songIDs: songIDs, shuffled: shuffled) else { return }
        finishPlayback()
    }

    private func finishPlayback() {
        openPlayer()
        dismiss()
    }
}

/// 歌曲行 — 封面 + 标题/艺术家 + 时长。
struct TVSongRow: View {
    @Environment(TVStore.self) private var store
    let song: TVSong
    var reason: String? = nil
    var queueSongIDs: [String]? = nil
    var action: () -> Void = {}
    /// 长列表分页要知道焦点走到哪一行了,见 `TVPagedSongIDList`。
    var onFocusChanged: (Bool) -> Void = { _ in }

    var body: some View {
        let album = store.albumOf(song)
        TVFocusButton(radius: TVRadius.card, scale: 1.02, lift: 0,
                      action: {
                          // 列表内点歌保持该列表为队列,并沿用当前随机开关;
                          // 没给列表时按可见曲库顺序续播。
                          if let queueSongIDs {
                              guard store.play(song, in: queueSongIDs) else { return }
                          } else { store.play(song) }
                          action()
                      },
                      onFocusChanged: onFocusChanged) { focused in
            HStack(spacing: 18) {
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", songID: song.id, coverRef: song.coverRef,
                              tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: 64, radius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    if let reason {
                        Label(reason, systemImage: "sparkles")
                            .tvFont(.meta, weight: .semibold)
                            .foregroundStyle(TVColor.brand)
                            .lineLimit(1)
                    }
                    Text(song.title).tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text).lineLimit(2)
                    Text(song.artist).tvFont(.caption)
                        .foregroundStyle(TVColor.textFaint).lineLimit(1)
                }
                Spacer(minLength: 0)
                if store.isLiked(song.id) {
                    Image(systemName: "heart.fill").font(.system(size: 22))
                        .foregroundStyle(TVColor.brand)
                }
                Text(song.format).tvFont(.meta, weight: .semibold)
                    .foregroundStyle(TVColor.textGhost)
                Text(TVFmt.time(song.duration)).tvFont(.caption, design: .monospaced)
                    .foregroundStyle(TVColor.textFaint)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : TVColor.card)
        }
    }
}

/// 由歌曲 ID 列表驱动的分页歌曲列表。
///
/// 整份列表一次性交给 `ForEach`,遥控器就会失去响应 —— 原因和行数上限见
/// `TVLongListPagingPolicy`。点歌仍以完整列表入队,分页只影响渲染多少行。
struct TVPagedSongIDList: View {
    let songIDs: [String]
    var alignment: HorizontalAlignment = .center
    var spacing: CGFloat = 10
    var action: () -> Void = {}

    @Environment(TVStore.self) private var store

    var body: some View {
        TVPagedList(songIDs, id: \.self, alignment: alignment, spacing: spacing) { _, songID, onFocusChanged in
            if let song = store.song(songID) {
                TVSongRow(
                    song: song,
                    queueSongIDs: songIDs,
                    action: action,
                    onFocusChanged: onFocusChanged
                )
            }
        }
    }
}
#endif
