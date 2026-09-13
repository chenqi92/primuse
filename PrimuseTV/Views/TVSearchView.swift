#if os(tvOS)
import PrimuseKit
import SwiftUI

private enum TVSemanticSearchFeedback: Equatable {
    case idle
    case loading
    case success(provider: String, fallbackDepth: Int)
    case noMatches(provider: String, fallbackDepth: Int)
    case failed
}

/// 当前焦点所在的区域。结果列表刷新时据此判断是否需要接管焦点,
/// 避免在用户停留在输入框或建议列时被结果抢走焦点。
private enum TVSearchFocusZone: Equatable {
    case field
    case results
    case suggestions
}

/// tvOS 搜索 — 左列查询框 + 实时结果(含歌词级匹配),右列常驻建议。对应 TVSearchArtboard。
struct TVSearchView: View {
    @Environment(TVStore.self) private var store
    @Environment(MusicIntelligenceService.self) private var intelligence
    var openPlayer: () -> Void = {}
    var focusRequest: TVContentFocusRequest? = nil
    var onModalActivityChanged: (Bool) -> Void = { _ in }

    @State private var query: String = ""
    @State private var results: TVStore.TVSearchResults?
    @State private var selectedArtist: TVArtist?
    @State private var opensPlayerAfterArtistDismissal = false
    @State private var isSearching = false
    @State private var isSemanticSearching = false
    @State private var semanticFeedback: TVSemanticSearchFeedback = .idle
    @State private var focusZone: TVSearchFocusZone = .field
    @State private var lastFocusedResultID: String?
    @FocusState private var inputActive: Bool
    @FocusState private var focusedResultID: String?

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }

    // MARK: 结果切片(视觉顺序:艺术家 → 专辑 → 歌曲 → AI 补充)

    private var artistResults: [TVArtist] { results?.artists ?? [] }
    private var albumResults: [TVAlbum] { results?.albums ?? [] }
    private var primarySongResults: [TVStore.TVSearchHit] {
        (results?.songs ?? []).filter { $0.relatedConcept == nil }
    }
    private var intelligentSongResults: [TVStore.TVSearchHit] {
        (results?.songs ?? []).filter { $0.relatedConcept != nil }
    }

    /// 结果行的稳定焦点标识,顺序与视觉顺序一致;结果替换后用它做焦点对齐。
    private var resultFocusIDs: [String] {
        artistResults.map(Self.artistFocusID)
            + albumResults.map(Self.albumFocusID)
            + primarySongResults.map(Self.songFocusID)
            + intelligentSongResults.map(Self.songFocusID)
    }

    private var hasResults: Bool { !resultFocusIDs.isEmpty }

    private var showsNoMatch: Bool {
        !trimmed.isEmpty && !isSearching && !hasResults
    }

    private static func artistFocusID(_ artist: TVArtist) -> String { "artist:" + artist.id }
    private static func albumFocusID(_ album: TVAlbum) -> String { "album:" + album.id }
    private static func songFocusID(_ hit: TVStore.TVSearchHit) -> String { "song:" + hit.id }

    var body: some View {
        ZStack {
            TVAmbientBackdrop(tint: store.albums.first?.tint ?? TVColor.brand,
                              tint2: store.albums.first?.tint2 ?? .black, strength: 0.4)
            HStack(alignment: .top, spacing: 60) {
                // 左列 = 输入框 + 主结果;右列 = 建议。两列各自成焦点区:
                // 左列内上下移动只在「输入框 ↔ 结果」之间走,右移才跨到建议列。
                resultsColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
                suggestionsColumn
                    .frame(width: 460)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .focusSection()
            }
            .tvPage()
        }
        .task(id: trimmed) {
            await updateResults(for: trimmed)
        }
        .task(id: focusRequest?.id) {
            guard let request = focusRequest, request.target == .searchField else { return }
            await Task.yield()
            guard !Task.isCancelled, focusRequest == request else { return }
            focusZone = .field
            inputActive = true
        }
        .onChange(of: resultFocusIDs) { _, ids in
            reconcileResultFocus(ids)
        }
        .onChange(of: focusedResultID) { _, value in
            guard let value else { return }
            focusZone = .results
            lastFocusedResultID = value
        }
        .onChange(of: inputActive) { _, active in
            if active { focusZone = .field }
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

    // MARK: 左列 — 搜索框(单层玻璃盒) + 实时结果

    private var resultsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVEyebrow(text: PMString("ext.tv.search.eyebrow")).padding(.bottom, 16)
            searchField.padding(.bottom, 16)
            Text(PMString("ext.tv.search.hint"))
                .tvFont(.caption).foregroundStyle(TVColor.textGhost).padding(.bottom, 22)
            resultsHeader.padding(.bottom, 12)
            resultsBody
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // 单层原生输入框:tvOS 的 TextField 自带一个圆角输入框,聚焦后唤起系统键盘。
    // 不再叠自绘玻璃盒 + 近透明 TextField,避免「大框套小框」和异常高度。
    private var searchField: some View {
        HStack(spacing: 18) {
            Image(systemName: "magnifyingglass").font(.system(size: 26, weight: .semibold))
                .foregroundStyle(inputActive ? TVColor.brand : TVColor.textFaint)
            TextField(PMString("ext.tv.search.placeholder"), text: $query)
                .focused($inputActive)
                .tvFont(.input)
                .frame(maxWidth: .infinity)
            if !trimmed.isEmpty {
                TVFocusButton(radius: 18, scale: 1.06, lift: 0, action: { query = "" }) { f in
                    Text(PMString("ext.tv.search.clear"))
                        .tvFont(.caption, weight: .medium).foregroundStyle(TVColor.text)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(f ? TVColor.surfaceStrong : TVColor.surface, in: Capsule())
                }
                .onMoveCommand { direction in
                    guard direction == .down, let first = resultFocusIDs.first else { return }
                    // The narrow clear button may not geometrically overlap
                    // the first artist/album card in the results below it.
                    focusedResultID = first
                }
            }
        }
    }

    private var resultsHeader: some View {
        HStack {
            TVEyebrow(text: PMString("ext.tv.search.topResult"))
            Spacer()
            if isSearching || isSemanticSearching {
                ProgressView()
                    .controlSize(.small)
                Text(PMString("ext.tv.search.aiLoading"))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textFaint)
            } else {
                semanticStatusLabel
            }
        }
    }

    @ViewBuilder
    private var resultsBody: some View {
        if trimmed.isEmpty {
            // 空查询:只给提示文案(不可聚焦),焦点留在输入框 / 建议列。
            Text(PMString("ext.tv.search.typeToSearch"))
                .tvFont(.caption).foregroundStyle(TVColor.textFaint)
            Spacer(minLength: 0)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if !artistResults.isEmpty {
                        artistCarousel
                    }
                    if !albumResults.isEmpty {
                        albumCarousel
                    }
                    if !primarySongResults.isEmpty {
                        TVEyebrow(text: PMString("ext.tv.search.songs"))
                            .padding(.top, artistResults.isEmpty && albumResults.isEmpty ? 0 : 22)
                            .padding(.bottom, 12)
                        songList(primarySongResults)
                    }
                    if !intelligentSongResults.isEmpty {
                        TVEyebrow(text: PMString("ext.tv.search.aiSupplement"))
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                        songList(intelligentSongResults)
                    }
                    if showsNoMatch {
                        // 无匹配:纯文本(不可聚焦),焦点保持在输入框。
                        Text(PMString("ext.tv.search.noMatch")).tvFont(.caption)
                            .foregroundStyle(TVColor.textGhost)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var artistCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(artistResults) { artist in
                    TVArtistCard(
                        artist: artist,
                        size: 140,
                        action: { selectedArtist = artist }
                    )
                    .focused($focusedResultID, equals: Self.artistFocusID(artist))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
        }
    }

    private var albumCarousel: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVEyebrow(text: PMString("ext.tv.library.title.albums", albumResults.count))
                .padding(.top, artistResults.isEmpty ? 0 : 18)
                .padding(.bottom, 8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(albumResults) { album in
                        TVAlbumCard(album: album, width: 200, action: openPlayer)
                            .focused($focusedResultID, equals: Self.albumFocusID(album))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 20)
            }
        }
    }

    private func songList(_ hits: [TVStore.TVSearchHit]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(hits) { hit in
                TVSearchSongRow(
                    hit: hit,
                    focusedResultID: $focusedResultID,
                    focusID: Self.songFocusID(hit),
                    action: openPlayer
                )
            }
        }
    }

    // MARK: 右列 — 建议(常驻,随输入精化)

    private var suggestionsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            TVEyebrow(text: PMString("ext.tv.search.suggestions")).padding(.bottom, 16)
            let suggestions = store.searchSuggestions(query)
            if !suggestions.isEmpty {
                VStack(spacing: 4) {
                    ForEach(suggestions, id: \.self) { s in
                        TVFocusButton(radius: 10, scale: 1.0, lift: 0,
                                      action: { query = s },
                                      onFocusChanged: { focused in
                                          if focused { focusZone = .suggestions }
                                      }) { focused in
                            HStack {
                                Text(s).tvFont(.body).foregroundStyle(TVColor.text)
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

    // MARK: 焦点对齐

    /// 结果被替换(防抖主结果 → AI 富化结果)后保持选中项:
    /// 同一项仍在则保持,消失则落到第一条;完全没有结果时回到输入框。
    /// 仅在焦点本就位于结果区时接管,避免抢走输入框 / 建议列的焦点。
    private func reconcileResultFocus(_ ids: [String]) {
        guard focusZone == .results else { return }
        let anchor = focusedResultID ?? lastFocusedResultID
        if let anchor, ids.contains(anchor) {
            if focusedResultID != anchor {
                focusedResultID = anchor
            }
            return
        }
        if let first = ids.first {
            lastFocusedResultID = first
            focusedResultID = first
        } else {
            lastFocusedResultID = nil
            focusedResultID = nil
            focusZone = .field
            inputActive = true
        }
    }

    @MainActor
    private func updateResults(for requestedQuery: String) async {
        guard !requestedQuery.isEmpty else {
            results = nil
            isSearching = false
            isSemanticSearching = false
            semanticFeedback = .idle
            return
        }

        isSearching = true
        isSemanticSearching = false
        semanticFeedback = .idle
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }
        guard !Task.isCancelled, trimmed == requestedQuery else { return }

        let primary = await store.searchResults(requestedQuery)
        guard !Task.isCancelled, trimmed == requestedQuery else { return }
        results = primary
        isSearching = false

        guard intelligence.isSemanticSearchConfigured else { return }
        isSemanticSearching = true
        semanticFeedback = .loading
        var streamedTerms: [String] = []
        let outcome = await intelligence.semanticSearchOutcome(
            for: requestedQuery,
            onStreamEvent: { event in
                guard !Task.isCancelled, trimmed == requestedQuery else { return }
                switch event {
                case .reset:
                    streamedTerms = []
                case .term(let term):
                    guard !streamedTerms.contains(where: {
                        $0.caseInsensitiveCompare(term) == .orderedSame
                    }) else { return }
                    streamedTerms.append(term)
                case .completed:
                    break
                }
            }
        )
        guard !Task.isCancelled else { return }
        guard trimmed == requestedQuery else { return }
        switch outcome {
        case .unavailable:
            semanticFeedback = .idle
        case .failed:
            semanticFeedback = .failed
        case .empty(let providerName, let fallbackDepth):
            semanticFeedback = .noMatches(provider: providerName, fallbackDepth: fallbackDepth)
        case .success(let execution):
            let plannedConcepts = AISemanticLibraryAggregationPolicy.concepts(from: execution.plan)
            let concepts = plannedConcepts.isEmpty ? streamedTerms : plannedConcepts
            let enriched = await store.searchResults(
                requestedQuery,
                relatedConcepts: concepts
            )
            guard !Task.isCancelled, trimmed == requestedQuery else { return }
            results = enriched
            let hasSemanticMatches = enriched.songs.contains { $0.relatedConcept != nil }
            semanticFeedback = hasSemanticMatches
                ? .success(
                    provider: execution.providerName,
                    fallbackDepth: execution.fallbackDepth
                )
                : .noMatches(
                    provider: execution.providerName,
                    fallbackDepth: execution.fallbackDepth
                )
        }
        finishSemanticSearch(for: requestedQuery)
    }

    @ViewBuilder
    private var semanticStatusLabel: some View {
        switch semanticFeedback {
        case .idle, .loading:
            EmptyView()
        case .success(let provider, let fallbackDepth):
            Label(
                PMString(
                    fallbackDepth > 0
                        ? "ext.tv.search.aiSuccessFallback" : "ext.tv.search.aiSuccess",
                    provider.isEmpty ? PMString("ai_provider_default_name") : provider
                ),
                systemImage: fallbackDepth > 0
                    ? "arrow.trianglehead.branch" : "checkmark.circle.fill"
            )
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(TVColor.brand)
        case .noMatches(let provider, let fallbackDepth):
            Label(
                PMString(
                    fallbackDepth > 0
                        ? "ext.tv.search.aiNoMatchFallback" : "ext.tv.search.aiNoMatch",
                    provider.isEmpty ? PMString("ai_provider_default_name") : provider
                ),
                systemImage: "sparkles"
            )
            .tvFont(.caption)
            .foregroundStyle(TVColor.textFaint)
        case .failed:
            Label(PMString("ext.tv.search.aiFailed"), systemImage: "exclamationmark.triangle.fill")
                .tvFont(.caption)
                .foregroundStyle(.orange)
        }
    }

    @MainActor
    private func finishSemanticSearch(for requestedQuery: String) {
        if trimmed == requestedQuery {
            isSemanticSearching = false
        }
    }

    private func finishArtistDismissal() {
        guard opensPlayerAfterArtistDismissal else { return }
        opensPlayerAfterArtistDismissal = false
        openPlayer()
    }
}

private struct TVSearchSongRow: View {
    @Environment(TVStore.self) private var store
    let hit: TVStore.TVSearchHit
    @FocusState.Binding var focusedResultID: String?
    let focusID: String
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(song.title).tvFont(.cardTitle).foregroundStyle(TVColor.text).lineLimit(1)
                    if hit.isLyric, let snippet = hit.lyricSnippet, !snippet.isEmpty {
                        // 歌词命中:展示命中片段,与 iOS/macOS 一致。
                        HStack(spacing: 6) {
                            Image(systemName: "quote.opening").font(.system(size: 20)).foregroundStyle(TVColor.brand)
                            Text(snippet.replacingOccurrences(of: "\n", with: " · "))
                                .tvFont(.caption).foregroundStyle(TVColor.brand.opacity(0.9)).lineLimit(1)
                        }
                    } else if let concept = hit.relatedConcept {
                        Text(PMString("ext.tv.search.aiReason", concept))
                            .tvFont(.caption)
                            .foregroundStyle(TVColor.brand.opacity(0.9))
                            .lineLimit(1)
                    } else {
                        Text("\(song.artist) · \(album?.title ?? "")")
                            .tvFont(.caption).foregroundStyle(TVColor.textFaint).lineLimit(1)
                    }
                    if let path = song.displayPath {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .tvFont(.caption, design: .monospaced)
                        .foregroundStyle(TVColor.textGhost)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(PMString("ext.tv.search.path", path)))
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "play.fill").tvFont(.caption).foregroundStyle(TVColor.textFaint)
            }
            .padding(14).frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle)
        }
        .focused($focusedResultID, equals: focusID)
    }
}
#endif
