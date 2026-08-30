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

    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", recommendations = "推荐", artists = "艺术家", songs = "歌曲", playlists = "歌单", smart = "智能歌单"
        var id: String { rawValue }
        var display: String {
            switch self {
            case .all: return PMString("ext.tv.library.filter.all")
            case .recommendations: return PMString("library_recommendations_title")
            case .artists: return PMString("ext.tv.library.filter.artists")
            case .songs: return PMString("ext.tv.library.filter.songs")
            case .playlists: return PMString("ext.tv.library.filter.playlists")
            case .smart: return PMString("ext.tv.library.filter.smart")
            }
        }
    }
    @State private var filter: Filter = .all
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

    private let cols = 5
    private let gap: CGFloat = 36
    var focusRequest = 0

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            GeometryReader { geo in
                let contentW = geo.size.width - TVSpace.pageH * 2
                let cell = (contentW - gap * CGFloat(cols - 1)) / CGFloat(cols)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 30) {
                        filterStrip
                        grid(cell: cell).focusSection()
                    }
                    .tvPage()
                }
            }
        }
        .onChange(of: focusRequest) {
            focusedFilter = .all
        }
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
    }

    private var title: String {
        switch filter {
        case .all: return PMString("ext.tv.library.title.albums", store.albums.count)
        case .recommendations: return PMString("library_recommendations_title")
        case .artists: return PMString("ext.tv.library.title.artists", store.artists.count)
        case .songs: return PMString("ext.tv.library.title.songs", TVFmt.count(store.songs.count))
        case .playlists: return PMString("ext.tv.library.title.playlists", store.normalPlaylists.count)
        case .smart: return PMString("ext.tv.library.title.smart", store.smartPlaylists.count)
        }
    }

    private var filterStrip: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                TVEyebrow(text: PMString("ext.tv.library.eyebrow"))
                Text(title).font(TVFont.pageTitle).foregroundStyle(TVColor.text)
            }
            HStack(spacing: 12) {
                ForEach(Filter.allCases) { f in
                    Button {
                        filter = f
                    } label: {
                        Text(f.display)
                            .font(.system(size: 18, weight: f == filter ? .bold : .medium))
                            .foregroundStyle(f == filter ? TVColor.onBrand : TVColor.text)
                            .padding(.horizontal, 26).padding(.vertical, 12)
                            .background(f == filter ? AnyShapeStyle(TVColor.brand)
                                                    : AnyShapeStyle(TVColor.surfaceStrong),
                                        in: Capsule())
                            .tvFocusRing(
                                focusedFilter == f,
                                radius: 28,
                                accent: TVColor.focusRing,
                                scale: 1.06,
                                lift: 4
                            )
                    }
                    .buttonStyle(TVBareButtonStyle())
                    .focused($focusedFilter, equals: f)
                    .focusEffectDisabled()
                }
            }
            // 筛选条独立成焦点区:从右上角某个筛选项往下能跳到下方网格(否则横纵混在一起跳不下去)。
            .focusSection()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func grid(cell: CGFloat) -> some View {
        let columns = Array(repeating: GridItem(.fixed(cell), spacing: gap, alignment: .top), count: cols)
        switch filter {
        case .all:
            LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                ForEach(store.albums) { a in
                    TVAlbumCard(album: a, width: cell,
                                subtitleOverride: "\(a.artist) · \(a.year)", action: openPlayer)
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
                                        .font(.system(size: 19, weight: .bold))
                                    Text(intent.detail)
                                        .font(.system(size: 14))
                                        .opacity(0.75)
                                }
                                .foregroundStyle(
                                    effectiveSelectedRecommendationIntentID == intent.id
                                        ? TVColor.onBrand : TVColor.text
                                )
                                .padding(.horizontal, 24)
                                .frame(height: 66, alignment: .leading)
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
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(TVColor.text)

                LazyVStack(spacing: 10) {
                    ForEach(displayedRecommendationSongs) { song in
                        TVSongRow(
                            song: song,
                            reason: aiRecommendation.reason(for: song.id),
                            action: openPlayer
                        )
                    }
                }
            }
        case .artists:
            LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                ForEach(store.artists) { artist in
                    TVArtistCard(artist: artist, size: cell * 0.82, action: openPlayer)
                        .frame(width: cell)
                }
            }
        case .songs:
            LazyVStack(spacing: 10) {
                ForEach(store.songIDs, id: \.self) { songID in
                    if let song = store.song(songID) {
                        TVSongRow(song: song, action: openPlayer)
                    }
                }
            }
        case .playlists:
            LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                ForEach(store.normalPlaylists) { p in
                    TVPlaylistCard(playlist: p, width: cell, action: openPlayer)
                }
            }
        case .smart:
            LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                ForEach(store.smartPlaylists) { p in
                    TVPlaylistCard(playlist: p, width: cell, action: openPlayer)
                }
            }
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
                if intent.detail != intent.semanticIntent {
                    Text(PMString("ai_recommendation_intent_description_label"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(TVColor.textMuted)
                    Text(intent.detail)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(TVColor.text)
                }
                if let prompt = intent.semanticIntent {
                    Text(PMString("ai_recommendation_intent_prompt_label"))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(TVColor.textMuted)
                        .padding(.top, intent.detail == prompt ? 0 : 4)
                    Text(prompt)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(TVColor.text)
                }
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
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
                    .padding(.horizontal, 16)
                    .frame(height: 42)
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
                .padding(.horizontal, 16)
                .frame(height: 42)
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
}

/// 歌曲行 — 封面 + 标题/艺术家 + 时长。
struct TVSongRow: View {
    @Environment(TVStore.self) private var store
    let song: TVSong
    var reason: String? = nil
    var action: () -> Void = {}

    var body: some View {
        let album = store.albumOf(song)
        TVFocusButton(radius: TVRadius.card, scale: 1.02, lift: 0,
                      action: { store.play(song); action() }) { focused in
            HStack(spacing: 18) {
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", songID: song.id, coverRef: song.coverRef,
                              tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: 64, radius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    if let reason {
                        Label(reason, systemImage: "sparkles")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TVColor.brand)
                            .lineLimit(1)
                    }
                    Text(song.title).font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(TVColor.text).lineLimit(1)
                    Text(song.artist).font(.system(size: 18))
                        .foregroundStyle(TVColor.textFaint).lineLimit(1)
                }
                Spacer(minLength: 0)
                if store.isLiked(song.id) {
                    Image(systemName: "heart.fill").font(.system(size: 18))
                        .foregroundStyle(TVColor.brand)
                }
                Text(song.format).font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TVColor.textGhost)
                Text(TVFmt.time(song.duration)).font(.system(size: 18, design: .monospaced))
                    .foregroundStyle(TVColor.textFaint)
            }
            .padding(.horizontal, 22).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : TVColor.card)
        }
    }
}
#endif
