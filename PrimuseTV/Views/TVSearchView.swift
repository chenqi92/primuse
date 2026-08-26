#if os(tvOS)
import PrimuseKit
import SwiftUI

/// tvOS 搜索 — 左列查询框 + 建议(常驻),右列实时结果(含歌词级匹配)。对应 TVSearchArtboard。
struct TVSearchView: View {
    @Environment(TVStore.self) private var store
    @Environment(MusicIntelligenceService.self) private var intelligence
    var openPlayer: () -> Void = {}
    var focusRequest: TVContentFocusRequest? = nil

    @State private var query: String = ""
    @State private var results: (top: TVArtist?, songs: [TVStore.TVSearchHit]) = (nil, [])
    @State private var isSemanticSearching = false
    @FocusState private var inputActive: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: store.albums.first?.tint ?? TVColor.brand,
                              tint2: store.albums.first?.tint2 ?? .black, strength: 0.4)
            HStack(alignment: .top, spacing: 60) {
                // 两列各撑满高度,右列结果区从左列任意行往右都可达(焦点区 frame 不再只占顶部)。
                leftColumn.frame(maxHeight: .infinity, alignment: .topLeading).focusSection()
                rightColumn.frame(maxHeight: .infinity, alignment: .topLeading).focusSection()
            }
            .tvPage()
        }
        .onChange(of: query) { _, q in
            results = store.searchHits(q)
            if q.trimmingCharacters(in: .whitespaces).isEmpty {
                isSemanticSearching = false
            }
        }
        .task(id: trimmed) {
            await updateSemanticResults(for: trimmed)
        }
        .task(id: focusRequest?.id) {
            guard let request = focusRequest, request.target == .searchField else { return }
            await Task.yield()
            guard !Task.isCancelled, focusRequest == request else { return }
            inputActive = true
        }
    }

    // MARK: 左列 — 搜索框(单层玻璃盒) + 建议(常驻)

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVEyebrow(text: PMString("ext.tv.search.eyebrow")).padding(.bottom, 16)

            // 单层原生输入框:tvOS 的 TextField 自带一个圆角输入框,聚焦后唤起系统键盘。
            // 不再叠自绘玻璃盒 + 近透明 TextField,避免「大框套小框」和异常高度。
            HStack(spacing: 18) {
                Image(systemName: "magnifyingglass").font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(inputActive ? TVColor.brand : TVColor.textFaint)
                TextField(PMString("ext.tv.search.placeholder"), text: $query)
                    .focused($inputActive)
                    .font(.system(size: 28, weight: .semibold))
                    .frame(maxWidth: .infinity)
                if !trimmed.isEmpty {
                    TVFocusButton(radius: 18, scale: 1.06, lift: 0, action: { query = "" }) { f in
                        Text(PMString("ext.tv.search.clear"))
                            .font(.system(size: 17, weight: .medium)).foregroundStyle(TVColor.text)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(f ? TVColor.surfaceStrong : TVColor.surface, in: Capsule())
                    }
                }
            }
            .padding(.bottom, 18)

            Text(PMString("ext.tv.search.hint"))
                .font(.system(size: 15)).foregroundStyle(TVColor.textGhost).padding(.bottom, 28)

            // 建议常驻(随输入精化),不再只在空查询时显示。
            let suggestions = store.searchSuggestions(query)
            if !suggestions.isEmpty {
                Text(PMString("ext.tv.search.suggestions")).font(.system(size: 18))
                    .foregroundStyle(TVColor.textMuted).padding(.bottom, 10)
                VStack(spacing: 4) {
                    ForEach(suggestions, id: \.self) { s in
                        TVFocusButton(radius: 10, scale: 1.0, lift: 0,
                                      action: { query = s }) { focused in
                            HStack {
                                Text(s).font(.system(size: 22)).foregroundStyle(TVColor.text)
                                Spacer()
                            }
                            .padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: .infinity)
                            .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 右列 — 结果(顶部匹配 + 歌曲/歌词命中)

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TVEyebrow(text: PMString("ext.tv.search.topResult"))
                Spacer()
                if isSemanticSearching {
                    ProgressView()
                        .controlSize(.small)
                    Text(PMString("ext.tv.search.aiLoading"))
                        .font(.system(size: 15))
                        .foregroundStyle(TVColor.textFaint)
                }
            }
            .padding(.bottom, 16)
            if let artist = results.top {
                TVFocusButton(radius: 16, scale: 1.02, lift: 4, action: openPlayer) { focused in
                    HStack(spacing: 20) {
                        TVCoverArt(tint: artist.tint, tint2: artist.tint2, glyph: artist.glyph, size: 92, radius: 46)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(artist.name).font(.system(size: 32, weight: .bold)).foregroundStyle(TVColor.text)
                            Text(PMString("ext.tv.search.artistMeta", artist.songCount))
                                .font(.system(size: 18)).foregroundStyle(TVColor.textFaint)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(20).frame(maxWidth: .infinity)
                    .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle)
                }
            } else {
                Text(PMString("ext.tv.search.typeToSearch")).font(.system(size: 22)).foregroundStyle(TVColor.textFaint)
            }

            TVEyebrow(text: PMString("ext.tv.search.songs")).padding(.top, 28).padding(.bottom, 16)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(results.songs) { hit in
                        TVSearchSongRow(hit: hit, action: openPlayer)
                    }
                    if !trimmed.isEmpty, results.songs.isEmpty {
                        Text(PMString("ext.tv.search.noMatch")).font(.system(size: 18))
                            .foregroundStyle(TVColor.textGhost).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func updateSemanticResults(for requestedQuery: String) async {
        guard !requestedQuery.isEmpty else {
            isSemanticSearching = false
            return
        }
        isSemanticSearching = intelligence.isSemanticSearchConfigured
        guard intelligence.isSemanticSearchConfigured else { return }
        do {
            try await Task.sleep(for: .milliseconds(400))
        } catch {
            finishSemanticSearch(for: requestedQuery)
            return
        }
        guard !Task.isCancelled,
              let plan = await intelligence.semanticSearchPlan(for: requestedQuery),
              !Task.isCancelled else {
            finishSemanticSearch(for: requestedQuery)
            return
        }
        guard trimmed == requestedQuery else { return }
        let concepts = AISemanticLibraryAggregationPolicy.concepts(from: plan)
        results = store.searchHits(requestedQuery, relatedConcepts: concepts)
        finishSemanticSearch(for: requestedQuery)
    }

    @MainActor
    private func finishSemanticSearch(for requestedQuery: String) {
        if trimmed == requestedQuery {
            isSemanticSearching = false
        }
    }
}

private struct TVSearchSongRow: View {
    @Environment(TVStore.self) private var store
    let hit: TVStore.TVSearchHit
    var action: () -> Void = {}

    var body: some View {
        let song = hit.song
        let album = store.albumOf(song)
        TVFocusButton(radius: 10, scale: 1.0, lift: 0,
                      action: { store.play(song); action() }) { focused in
            HStack(spacing: 16) {
                TVArtworkView(coverKey: album?.id ?? "", artist: album?.artist ?? song.artist,
                              album: album?.title ?? "", songID: song.id, coverRef: song.coverRef,
                              tint: album?.tint ?? TVColor.brand,
                              tint2: album?.tint2 ?? .black, glyph: album?.glyph ?? "♪", size: 56, radius: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).font(.system(size: 22, weight: .semibold)).foregroundStyle(TVColor.text).lineLimit(1)
                    if hit.isLyric, let snippet = hit.lyricSnippet, !snippet.isEmpty {
                        // 歌词命中:展示命中片段,与 iOS/macOS 一致。
                        HStack(spacing: 6) {
                            Image(systemName: "quote.opening").font(.system(size: 12)).foregroundStyle(TVColor.brand)
                            Text(snippet.replacingOccurrences(of: "\n", with: " · "))
                                .font(.system(size: 15)).foregroundStyle(TVColor.brand.opacity(0.9)).lineLimit(1)
                        }
                    } else if let concept = hit.relatedConcept {
                        Text(PMString("ext.tv.search.aiReason", concept))
                            .font(.system(size: 15))
                            .foregroundStyle(TVColor.brand.opacity(0.9))
                            .lineLimit(1)
                    } else {
                        Text("\(song.artist) · \(album?.title ?? "")")
                            .font(.system(size: 16)).foregroundStyle(TVColor.textFaint).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(TVColor.textFaint)
            }
            .padding(14).frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle)
        }
    }
}
#endif
