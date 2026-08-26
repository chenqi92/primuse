#if os(tvOS)
import SwiftUI
import PrimuseKit

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
    @AppStorage("primuse.ai.recommendationIntent.selected.v1")
    private var selectedRecommendationIntentID = "preset:rightNow"
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
        .task(id: recommendationRefreshKey) {
            recommendationCandidates = await store.recommendationCandidates(limit: 24)
            await aiRecommendation.refresh(
                scene: .automatic,
                intent: selectedRecommendationIntent?.semanticIntent,
                candidates: recommendationCandidates,
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
        case .playlists: return PMString("ext.tv.library.title.playlists", store.playlists.filter { $0.kind != .smart }.count)
        case .smart: return PMString("ext.tv.library.title.smart", store.playlists.filter { $0.kind == .smart }.count)
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
                                    selectedRecommendationIntentID == intent.id
                                        ? TVColor.onBrand : TVColor.text
                                )
                                .padding(.horizontal, 24)
                                .frame(height: 66, alignment: .leading)
                                .background(
                                    selectedRecommendationIntentID == intent.id
                                        ? TVColor.brand
                                        : (focused ? TVColor.surfaceStrong : TVColor.surface),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                            }
                        }
                    }
                    .padding(.vertical, 8)
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
                ForEach(store.songs) { song in
                    TVSongRow(song: song, action: openPlayer)
                }
            }
        case .playlists:
            LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                ForEach(store.playlists.filter { $0.kind != .smart }) { p in
                    TVPlaylistCard(playlist: p, width: cell, action: openPlayer)
                }
            }
        case .smart:
            LazyVGrid(columns: columns, alignment: .leading, spacing: gap) {
                ForEach(store.playlists.filter { $0.kind == .smart }) { p in
                    TVPlaylistCard(playlist: p, width: cell, action: openPlayer)
                }
            }
        }
    }

    private struct RecommendationIntent: Identifiable {
        var id: String
        var title: String
        var detail: String
        var semanticIntent: String?
    }

    private var recommendationIntents: [RecommendationIntent] {
        let presets = AIRecommendationIntentPreset.allCases.map { preset in
            RecommendationIntent(
                id: "preset:\(preset.rawValue)",
                title: PMString("ai_recommendation_intent_\(preset.rawValue)"),
                detail: PMString("ai_recommendation_intent_\(preset.rawValue)_detail"),
                semanticIntent: preset.semanticIntent
            )
        }
        let custom = AIRecommendationIntentStoragePolicy
            .decode(customRecommendationIntentsRawValue)
            .map { intent in
                RecommendationIntent(
                    id: "custom:\(intent.id.uuidString)",
                    title: intent.title,
                    detail: intent.prompt,
                    semanticIntent: intent.prompt
                )
            }
        return presets + custom
    }

    private var selectedRecommendationIntent: RecommendationIntent? {
        recommendationIntents.first { $0.id == selectedRecommendationIntentID }
            ?? recommendationIntents.first
    }

    private var recommendationRefreshKey: String {
        [
            String(store.recommendationRevision),
            selectedRecommendationIntentID,
            customRecommendationIntentsRawValue,
            String(intelligence.settingsStore.revision),
            String(intelligence.regionAvailability.revision),
        ].joined(separator: "#")
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
