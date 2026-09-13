#if os(tvOS)
import SwiftUI
import PrimuseKit

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
    @State private var selectedArtist: TVArtist?
    @State private var opensPlayerAfterArtistDismissal = false

    private let cols = 4
    private let gap: CGFloat = 28
    var focusRequest = 0

    var body: some View {
        GeometryReader { geo in
            let contentW = geo.size.width - TVSpace.pageH * 2 - 28
            let cell = max(140, (contentW - gap * CGFloat(cols - 1)) / CGFloat(cols))
            VStack(alignment: .leading, spacing: 24) {
                filterStrip
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        Text(title).tvFont(.pageTitle).foregroundStyle(TVColor.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        grid(cell: cell)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, TVSpace.pageBottom)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .focusSection()
                .id(filter)
            }
            .padding(.horizontal, TVSpace.pageH)
            .padding(.top, TVSpace.pageTop)
        }
        .background(TVColor.bg)
        .onExitCommand(perform: onReturnToTabs)
        .onChange(of: focusRequest) { focusedFilter = filter }
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
    private func grid(cell: CGFloat) -> some View {
        let columns = Array(repeating: GridItem(.fixed(cell), spacing: gap, alignment: .top), count: cols)
        switch filter {
        case .albums:
            LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                ForEach(store.albums) { a in
                    TVAlbumCard(album: a, width: cell,
                                subtitleOverride: a.year > 0 ? "\(a.artist) · \(a.year)" : a.artist, action: openPlayer)
                }
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
                                        .font(.system(size: 20))
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
            LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                ForEach(store.artists) { artist in
                    TVArtistCard(
                        artist: artist,
                        size: cell * 0.82,
                        action: { selectedArtist = artist }
                    )
                        .frame(width: cell)
                }
            }
        case .songs:
            let librarySongIDs = store.songIDs
            LazyVStack(spacing: 10) {
                ForEach(librarySongIDs, id: \.self) { songID in
                    if let song = store.song(songID) {
                        TVSongRow(song: song, queueSongIDs: librarySongIDs, action: openPlayer)
                    }
                }
            }
        case .genres:
            TVGenreBrowser(openPlayer: openPlayer, onModalActivityChanged: onModalActivityChanged)
        case .folders:
            TVFolderBrowser(openPlayer: openPlayer)
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
                    Text(PMString("ext.tv.songsCount", songs.count))
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
                    Spacer(minLength: 0)
                }
                .frame(width: 440, alignment: .leading)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        TVEyebrow(text: PMString("ext.tv.search.songs"))
                            .padding(.bottom, 6)
                        if songs.isEmpty {
                            TVEmptyState(
                                icon: "music.note",
                                title: PMString("ext.tv.search.noMatch")
                            )
                            .frame(minHeight: 360)
                        } else {
                            ForEach(songs) { song in
                                TVSongRow(song: song, queueSongIDs: songs.map(\.id), action: finishPlayback)
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

/// 歌曲行 — 封面 + 标题/艺术家 + 时长。
struct TVSongRow: View {
    @Environment(TVStore.self) private var store
    let song: TVSong
    var reason: String? = nil
    var queueSongIDs: [String]? = nil
    var action: () -> Void = {}

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
                      }) { focused in
            HStack(spacing: 18) {
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", songID: song.id, coverRef: song.coverRef,
                              tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: 64, radius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    if let reason {
                        Label(reason, systemImage: "sparkles")
                            .font(.system(size: 20, weight: .semibold))
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
                Text(song.format).font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(TVColor.textGhost)
                Text(TVFmt.time(song.duration)).font(.system(size: 22, design: .monospaced))
                    .foregroundStyle(TVColor.textFaint)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : TVColor.card)
        }
    }
}
#endif
