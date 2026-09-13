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
    @State private var appleMusic = TVAppleMusicCatalog()
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
    /// 目录结果里把曲库已经有的那几首去掉,同一首歌不该在一页里出现两次。
    private var appleMusicResults: [AppleMusicCatalogHit] {
        AppleMusicCatalogSearchPolicy.deduplicated(
            appleMusic.hits,
            excludingItemIDs: Set(
                (primarySongResults + intelligentSongResults).map(\.song.id)
            )
        )
    }

    private var resultFocusIDs: [String] {
        artistResults.map(Self.artistFocusID)
            + albumResults.map(Self.albumFocusID)
            + primarySongResults.map(Self.songFocusID)
            + intelligentSongResults.map(Self.songFocusID)
            + appleMusic.artists.map(Self.appleMusicArtistFocusID)
            + appleMusic.albums.map(Self.appleMusicAlbumFocusID)
            + appleMusicResults.map(Self.appleMusicFocusID)
            + (canRequestAppleMusicAuthorization ? [Self.appleMusicAuthFocusID] : [])
    }

    /// 未授权时用授权入口顶替内容。目录搜索不会主动弹授权框,这一行是
    /// 用户在搜索页唯一能够开始授权的地方。
    private var showsAppleMusicAuthorization: Bool {
        !trimmed.isEmpty && appleMusic.needsAuthorization
    }

    /// 被拒绝或受限之后系统不再弹框,`request()` 会立刻返回原状态,
    /// 那时只提示去 tvOS 设置里改,不给一个按下去没反应的按钮。
    private var canRequestAppleMusicAuthorization: Bool {
        showsAppleMusicAuthorization && appleMusic.authorization == .notDetermined
    }

    private var hasAppleMusicContent: Bool {
        !appleMusicResults.isEmpty || !appleMusic.albums.isEmpty || !appleMusic.artists.isEmpty
    }

    private var hasResults: Bool { !resultFocusIDs.isEmpty }

    private var showsNoMatch: Bool {
        !trimmed.isEmpty && !isSearching && !hasResults
    }

    private static func artistFocusID(_ artist: TVArtist) -> String { "artist:" + artist.id }
    private static func albumFocusID(_ album: TVAlbum) -> String { "album:" + album.id }
    private static func songFocusID(_ hit: TVStore.TVSearchHit) -> String { "song:" + hit.id }
    private static func appleMusicFocusID(_ hit: AppleMusicCatalogHit) -> String {
        "appleMusic:" + hit.id
    }
    private static func appleMusicAlbumFocusID(_ hit: AppleMusicCatalogAlbumHit) -> String {
        "appleMusicAlbum:" + hit.id
    }
    private static func appleMusicArtistFocusID(_ hit: AppleMusicCatalogArtistHit) -> String {
        "appleMusicArtist:" + hit.id
    }
    private static let appleMusicAuthFocusID = "appleMusicAuth"

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

    // 单层输入框:系统自带的圆角框就是唯一的一层,只把宽度撑满。
    private var searchField: some View {
        HStack(spacing: 18) {
            Image(systemName: "magnifyingglass").font(.system(size: 26, weight: .semibold))
                .foregroundStyle(inputActive ? TVColor.brand : TVColor.textFaint)
            TVTextFieldBox {
                TextField(PMString("ext.tv.search.placeholder"), text: $query)
                    .focused($inputActive)
            }
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
                    if hasAppleMusicContent || appleMusic.isSearching || showsAppleMusicAuthorization {
                        TVEyebrow(text: PMString("ext.tv.search.appleMusic"))
                            .padding(.top, 22)
                            .padding(.bottom, 8)
                        if showsAppleMusicAuthorization {
                            appleMusicAuthorizationPrompt
                        } else if !hasAppleMusicContent, appleMusic.isSearching {
                            HStack(spacing: 12) {
                                ProgressView().tint(TVColor.brand)
                                Text(PMString("ext.tv.search.appleMusicSearching"))
                                    .tvFont(.caption).foregroundStyle(TVColor.textFaint)
                            }
                            .padding(.vertical, 10)
                        } else {
                            if !appleMusic.artists.isEmpty { appleMusicArtistCarousel }
                            if !appleMusic.albums.isEmpty { appleMusicAlbumCarousel }
                            if !appleMusicResults.isEmpty { appleMusicList }
                        }
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

    @ViewBuilder
    private var appleMusicAuthorizationPrompt: some View {
        if canRequestAppleMusicAuthorization {
            TVFocusButton(radius: 16, scale: 1.0, lift: 0, action: authorizeAppleMusic) { focused in
                appleMusicAuthorizationCard(focused: focused)
            }
            .focused($focusedResultID, equals: Self.appleMusicAuthFocusID)
            .padding(.horizontal, 14)
        } else {
            appleMusicAuthorizationCard(focused: false)
                .padding(.horizontal, 14)
        }
    }

    private func appleMusicAuthorizationCard(focused: Bool) -> some View {
        HStack(spacing: 18) {
            Image(systemName: "music.note")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(focused ? TVColor.text : TVColor.brand)
            VStack(alignment: .leading, spacing: 6) {
                if canRequestAppleMusicAuthorization {
                    Text(PMString("ext.tv.search.appleMusicAuthorize"))
                        .tvFont(.cardTitle, weight: focused ? .bold : .medium)
                        .foregroundStyle(TVColor.text)
                }
                Text(PMString(Self.authorizationHintKey(appleMusic.authorization)))
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TVColor.surfaceStrong,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// 被拒绝或受限时系统不会再弹框,只能引导用户去 tvOS 设置里改。
    private static func authorizationHintKey(_ state: AppleMusicAuthorizationState) -> String {
        switch state {
        case .denied: return "ext.tv.appleMusic.needsAuthorization"
        case .restricted: return "ext.tv.appleMusic.restricted"
        default: return "ext.tv.search.appleMusicAuthorizeHint"
        }
    }

    private func authorizeAppleMusic() {
        Task { @MainActor in
            guard await appleMusic.requestAuthorization() == .authorized else { return }
            appleMusic.search(trimmed)
        }
    }

    private var appleMusicArtistCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(appleMusic.artists) { artist in
                    TVAppleMusicCircleCard(
                        title: artist.name,
                        subtitle: PMString("ext.tv.search.appleMusicTopSongs"),
                        artworkURL: artist.artworkURL,
                        glyph: "person.fill",
                        action: { store.playAppleMusicArtist(artist); openPlayer() }
                    )
                    .focused($focusedResultID, equals: Self.appleMusicArtistFocusID(artist))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 16)
        }
    }

    private var appleMusicAlbumCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(appleMusic.albums) { album in
                    TVAppleMusicTileCard(
                        title: album.title,
                        subtitle: album.artistName,
                        artworkURL: album.artworkURL,
                        glyph: "opticaldisc",
                        width: 200,
                        action: { store.playAppleMusicAlbum(album); openPlayer() }
                    )
                    .focused($focusedResultID, equals: Self.appleMusicAlbumFocusID(album))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 18)
        }
    }

    private var appleMusicList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(appleMusicResults) { hit in
                TVAppleMusicSearchRow(
                    hit: hit,
                    focusedResultID: $focusedResultID,
                    focusID: Self.appleMusicFocusID(hit),
                    action: openPlayer
                )
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
        // 目录搜索与曲库搜索并行:它自带防抖,未授权时直接不发请求,
        // 所以每次输入变化交给它即可。
        appleMusic.search(requestedQuery)
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
            .tvFont(.meta, weight: .medium)
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
/// Apple Music 目录结果的一行。与曲库结果行外观一致,只是封面来自网络、
/// 右侧带一个 Apple Music 角标,让用户知道这条不在自己的曲库里。
private struct TVAppleMusicSearchRow: View {
    @Environment(TVStore.self) private var store
    let hit: AppleMusicCatalogHit
    @FocusState.Binding var focusedResultID: String?
    let focusID: String
    var action: () -> Void = {}

    var body: some View {
        TVFocusButton(radius: 10, scale: 1.0, lift: 0,
                      action: { store.playAppleMusicCatalogHit(hit); action() }) { focused in
            HStack(spacing: 16) {
                artwork
                VStack(alignment: .leading, spacing: 6) {
                    Text(hit.title).tvFont(.cardTitle)
                        .foregroundStyle(TVColor.text).lineLimit(1)
                    Text(hit.albumTitle.isEmpty
                         ? hit.artistName
                         : "\(hit.artistName) · \(hit.albumTitle)")
                        .tvFont(.caption).foregroundStyle(TVColor.textFaint).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(PMString("ext.tv.search.appleMusicBadge"))
                    .tvFont(.meta, weight: .semibold)
                    .foregroundStyle(TVColor.brand)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(TVColor.brand.opacity(0.16), in: Capsule())
                Image(systemName: "play.fill").tvFont(.caption).foregroundStyle(TVColor.textFaint)
            }
            .padding(14).frame(maxWidth: .infinity)
            .background(focused ? TVColor.surfaceStrong : TVColor.surfaceSubtle)
        }
        .focused($focusedResultID, equals: focusID)
        .accessibilityLabel(Text("\(hit.title) · \(hit.artistName)"))
    }

    private var artwork: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(TVColor.surface)
            .overlay {
                if let url = hit.artworkURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "music.note")
                            .font(.system(size: 22))
                            .foregroundStyle(TVColor.textGhost)
                    }
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 22))
                        .foregroundStyle(TVColor.textGhost)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
#endif
