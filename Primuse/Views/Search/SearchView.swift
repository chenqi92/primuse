import SwiftUI
import MusicKit
import PrimuseKit

struct SearchView: View {
    private static let recentSearchesKey = "search_recent_queries"
    private static let recentSearchLimit = 12

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(AppleMusicService.self) private var appleMusic
    @Binding var searchText: String
    @State private var searchResults: [LibrarySearchResult] = []
    @State private var matchingAlbums: [PrimuseKit.Album] = []
    @State private var recentSearches: [String] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var lyricsSearchCache = LibrarySearchCache()
    /// 是否正在跑一次搜索 (含 debounce + detached worker)。用来在结果还没
    /// 出来时显示 loading 占位, 避免 200ms+ 窗口里先闪一下 "无匹配" 再
    /// 跳到结果。
    @State private var isSearching: Bool = false
    /// 当前已经渲染的结果对应的 query。如果它与 searchText 不一致, 说明
    /// 屏幕上还是上一轮的旧结果, ContentUnavailableView 不该出来。
    @State private var renderedQuery: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if searchText.isEmpty {
                    if library.visibleSongs.isEmpty {
                        // Empty-library prompt — distinct from
                        // "no search results", so use the unified
                        // illustration. The "no matches for query"
                        // path keeps Apple's polished system view.
                        EmptyStateView(
                            titleKey: "search_empty_library",
                            descriptionKey: "search_empty_library_desc",
                            systemImage: "magnifyingglass"
                        )
                    } else {
                        recentSearchView
                    }
                } else if searchResults.isEmpty && matchingAlbums.isEmpty {
                    // 搜索中 (或 query 还没追上渲染) 时不立刻 "无匹配", 否则
                    // 200ms+ 的窗口里会先闪 ContentUnavailableView 再蹦出结果。
                    // 等 worker 完成且 renderedQuery == searchText 才判定真的无匹配。
                    if isSearching || renderedQuery != searchText {
                        searchingPlaceholder
                    } else {
                        ContentUnavailableView.search(text: searchText)
                    }
                } else {
                    searchResultsView
                }
            }
            .navigationTitle("search_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            .searchable(text: $searchText, prompt: Text("search_prompt"))
            .onSubmit(of: .search) {
                addRecentSearch(searchText)
            }
        }
        .onAppear(perform: loadRecentSearches)
        .onReceive(NotificationCenter.default.publisher(for: CloudKVSSync.externalChangeNotification)) { note in
            guard let key = note.userInfo?["key"] as? String,
                  key == Self.recentSearchesKey else { return }
            loadRecentSearches()
        }
        .onChange(of: searchText) { _, newValue in
            performSearch(query: newValue)
            // 同步触发 Apple Music 搜索, 服务内部自己 debounce + 鉴权
            appleMusic.search(query: newValue)
        }
        .onChange(of: library.searchRevision) { _, _ in
            lyricsSearchCache = LibrarySearchCache()
            performSearch(query: searchText)
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private var recentSearchView: some View {
        List {
            if !recentSearches.isEmpty {
                Section {
                    ForEach(recentSearches, id: \.self) { query in
                        Button {
                            addRecentSearch(query)
                            searchText = query
                        } label: {
                            Label(query, systemImage: "clock")
                        }
                    }
                    .onDelete(perform: deleteRecentSearches)
                } header: {
                    HStack {
                        Text("recent_searches")
                        Spacer()
                        Button("clear_all", role: .destructive, action: clearRecentSearches)
                            .font(.caption)
                    }
                }
            }

            Section {
                HStack {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.secondary)
                    Text("\(library.visibleSongs.count) \(String(localized: "tab_songs"))")
                    Spacer()
                    Text("\(library.albums.count) \(String(localized: "tab_albums"))")
                    Text("·")
                    Text("\(library.artists.count) \(String(localized: "tab_artists"))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("library")
            }
        }
    }

    private var searchResultsView: some View {
        List {
            // 旧结果仍在屏上, 但新一轮搜索还在跑 — 顶部加一条细 progress,
            // 让用户知道结果会刷新, 而不是误以为屏幕卡住。
            if isSearching && renderedQuery != searchText {
                Section {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("search_running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Albums matching
            if !matchingAlbums.isEmpty {
                Section("tab_albums") {
                    ForEach(matchingAlbums.prefix(5)) { album in
                        HStack(spacing: 12) {
                            CachedArtworkView(albumID: album.id, albumTitle: album.title,
                                              artistName: album.artistName, size: 44, cornerRadius: 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.title).font(.subheadline).lineLimit(1)
                                Text(album.artistName ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // Songs grouped by match kind — 用户能一眼区分"标题/艺术家精确命中"、
            // "歌词命中"和"拼音/模糊命中", 类似 Apple Music 搜索的分组。
            // 每组限 40 条 (worker 整体也限 120), 防止单组撑满屏。
            songSection(kind: .metadata, titleKey: "search_section_metadata")
            songSection(kind: .lyrics, titleKey: "search_section_lyrics")
            songSection(kind: .fuzzy, titleKey: "search_section_fuzzy")

            // Apple Music — 只在用户已授权且查到结果时显示。未授权状态走
            // Settings 入口让用户主动 opt-in,不在搜索这条路径里弹系统授权
            // 对话框 (用户搜歌时被弹会很迷)。
            if appleMusic.authState == .authorized {
                if !appleMusic.searchResults.isEmpty {
                    Section {
                        ForEach(appleMusic.searchResults, id: \.id) { song in
                            appleMusicRow(song)
                        }
                    } header: {
                        HStack {
                            Image(systemName: "applelogo")
                            Text("search_section_apple_music")
                        }
                    }
                } else if appleMusic.isSearching {
                    Section {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("search_apple_music_loading")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let err = appleMusic.lastPlaybackError {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    /// 一组按 matchKind 过滤的歌曲 Section。空组直接 noop, 不显示标题。
    @ViewBuilder
    private func songSection(kind: LibrarySearchMatchKind, titleKey: LocalizedStringKey) -> some View {
        let bucket = searchResults.filter { $0.matchKind == kind }.prefix(40)
        if !bucket.isEmpty {
            Section {
                ForEach(Array(bucket)) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        SongRowView(
                            song: result.song,
                            isPlaying: player.currentSong?.id == result.song.id,
                            context: SongRowView.context(for: result.song, sourcesStore: sourcesStore, backfill: backfill)
                        )
                        if result.matchKind == .lyrics, let snippet = result.lyricSnippet {
                            // 歌词命中: 把命中的句子(含上下文)展开, 让用户一眼看到为什么命中。
                            Text(snippet)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 54)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        playSong(result.song, lyricsHint: result.lyricSnippet, matchKind: result.matchKind)
                    }
                }
            } header: {
                Text(titleKey)
            }
        }
    }

    private func appleMusicRow(_ song: MusicKit.Song) -> some View {
        Button {
            Task { await appleMusic.play(song) }
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: song.artwork?.url(width: 88, height: 88)) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.secondary.opacity(0.15)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(.subheadline).lineLimit(1)
                    Text(song.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "applelogo").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    private func performSearch(query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else {
            searchResults = []
            matchingAlbums = []
            isSearching = false
            renderedQuery = ""
            return
        }

        let songsSnapshot = library.visibleSongs
        let albumsSnapshot = library.visibleAlbums
        let cacheSnapshot = lyricsSearchCache

        isSearching = true

        searchTask = Task {
            // Debounce 200ms
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            let worker = Task.detached(priority: .userInitiated) {
                LibrarySearchWorker.compute(
                    query: query,
                    songs: songsSnapshot,
                    albums: albumsSnapshot,
                    cache: cacheSnapshot
                )
            }
            let output = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled else { return }
            searchResults = output.songResults
            matchingAlbums = output.albumResults
            lyricsSearchCache = output.cache
            renderedQuery = query
            isSearching = false
        }
    }

    private var searchingPlaceholder: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("search_running")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private func playSong(_ song: PrimuseKit.Song, lyricsHint: String? = nil, matchKind: LibrarySearchMatchKind? = nil) {
        let queue = searchResults.map(\.song).filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        // 歌词命中: 让 NowPlayingView 加载完歌词后自动 seek 到那行;
        // 同时打开全屏 NowPlayingView 让用户能立刻看到上下文。
        if matchKind == .lyrics, let snippet = lyricsHint, !snippet.isEmpty {
            player.requestLyricsJump(songID: song.id, snippet: snippet)
            NotificationCenter.default.post(name: .primuseRequestShowNowPlaying, object: nil)
        }
        Task { await player.play(song: song) }
        addRecentSearch(searchText)
    }

    private func loadRecentSearches() {
        recentSearches = UserDefaults.standard.stringArray(forKey: Self.recentSearchesKey) ?? []
    }

    private func addRecentSearch(_ query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return }

        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmedQuery) == .orderedSame }
        recentSearches.insert(trimmedQuery, at: 0)

        if recentSearches.count > Self.recentSearchLimit {
            recentSearches = Array(recentSearches.prefix(Self.recentSearchLimit))
        }

        saveRecentSearches()
    }

    private func deleteRecentSearches(at offsets: IndexSet) {
        recentSearches.remove(atOffsets: offsets)
        saveRecentSearches()
    }

    private func clearRecentSearches() {
        recentSearches.removeAll()
        saveRecentSearches()
    }

    private func saveRecentSearches() {
        UserDefaults.standard.set(recentSearches, forKey: Self.recentSearchesKey)
        CloudKVSSync.shared.markChanged(key: Self.recentSearchesKey)
    }
}
