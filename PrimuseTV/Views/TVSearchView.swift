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

/// tvOS 搜索 — 左列查询框 + 建议(常驻),右列实时结果(含歌词级匹配)。对应 TVSearchArtboard。
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
        .task(id: trimmed) {
            await updateResults(for: trimmed)
        }
        .task(id: focusRequest?.id) {
            guard let request = focusRequest, request.target == .searchField else { return }
            await Task.yield()
            guard !Task.isCancelled, focusRequest == request else { return }
            inputActive = true
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
                    .tvFont(.input)
                    .frame(maxWidth: .infinity)
                if !trimmed.isEmpty {
                    TVFocusButton(radius: 18, scale: 1.06, lift: 0, action: { query = "" }) { f in
                        Text(PMString("ext.tv.search.clear"))
                            .tvFont(.caption, weight: .medium).foregroundStyle(TVColor.text)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(f ? TVColor.surfaceStrong : TVColor.surface, in: Capsule())
                    }
                }
            }
            .padding(.bottom, 18)

            Text(PMString("ext.tv.search.hint"))
                .tvFont(.caption).foregroundStyle(TVColor.textGhost).padding(.bottom, 28)

            // 建议常驻(随输入精化),不再只在空查询时显示。
            let suggestions = store.searchSuggestions(query)
            if !suggestions.isEmpty {
                Text(PMString("ext.tv.search.suggestions")).tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted).padding(.bottom, 10)
                VStack(spacing: 4) {
                    ForEach(suggestions, id: \.self) { s in
                        TVFocusButton(radius: 10, scale: 1.0, lift: 0,
                                      action: { query = s }) { focused in
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

    // MARK: 右列 — 结果(顶部匹配 + 歌曲/歌词命中)

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
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
            .padding(.bottom, 16)
            if let artists = results?.artists, !artists.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 22) {
                        ForEach(artists) { artist in
                            TVArtistCard(
                                artist: artist,
                                size: 140,
                                action: { selectedArtist = artist }
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)
                }
            } else {
                Text(PMString("ext.tv.search.typeToSearch")).tvFont(.caption).foregroundStyle(TVColor.textFaint)
            }

            if let albums = results?.albums, !albums.isEmpty {
                TVEyebrow(text: PMString("ext.tv.library.title.albums", albums.count))
                    .padding(.top, 24)
                    .padding(.bottom, 8)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        ForEach(albums) { album in
                            TVAlbumCard(album: album, width: 200, action: openPlayer)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 20)
                }
            }

            TVEyebrow(text: PMString("ext.tv.search.songs")).padding(.top, 28).padding(.bottom, 16)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach((results?.songs ?? []).filter { $0.relatedConcept == nil }) { hit in
                        TVSearchSongRow(hit: hit, action: openPlayer)
                    }
                    let intelligentResults = (results?.songs ?? []).filter { $0.relatedConcept != nil }
                    if !intelligentResults.isEmpty {
                        TVEyebrow(text: PMString("ext.tv.search.aiSupplement"))
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                        ForEach(intelligentResults) { hit in
                            TVSearchSongRow(hit: hit, action: openPlayer)
                        }
                    }
                    if !trimmed.isEmpty,
                       results?.songs.isEmpty != false,
                       results?.albums.isEmpty != false,
                       results?.artists.isEmpty != false,
                       !isSearching {
                        Text(PMString("ext.tv.search.noMatch")).tvFont(.caption)
                            .foregroundStyle(TVColor.textGhost).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .font(.system(size: 15, weight: .medium))
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
                            Image(systemName: "quote.opening").font(.system(size: 12)).foregroundStyle(TVColor.brand)
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
    }
}
#endif
