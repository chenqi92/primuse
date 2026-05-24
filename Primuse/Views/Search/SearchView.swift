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
    /// 自增 generation token — 防止旧 task 的 defer 覆盖新一轮 performSearch
    /// 设的 isSearching 状态。task 完成时只在 gen 还匹配时才 reset。
    @State private var searchGeneration: Int = 0

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
                } else if searchResults.isEmpty && matchingAlbums.isEmpty && appleMusic.searchResults.isEmpty {
                    // 本地 + Apple Music 都没结果时才走 "无匹配" 视图。之前的
                    // bug: 本地 0 + Apple Music 25 也会被这条分支吃掉, Apple
                    // Music section 一起不显示, 用户搜长 query "街角的晚风"
                    // 时表现成 "搜不到任何结果"。
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
            // SearchView 用自己的 NavigationStack, 没继承 ContentView 那边的
            // album / artist 目的地, 需要自己再挂一遍。
            .navigationDestination(for: PrimuseKit.Album.self) { album in
                AlbumDetailView(album: album)
            }
            .navigationDestination(for: PrimuseKit.Artist.self) { artist in
                ArtistDetailView(artist: artist)
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
            // 只 invalidate 歌词缓存 — 不立即重跑 performSearch。
            // 后台 backfill / scan 会频繁翻 searchRevision (一批 50 首一次),
            // 之前每次都触发 cancel + restart, 永远没 task 能跑完, 搜索条
            // 卡在 loading。改成 lazy: 等用户下次输入或者 query 没变也无所谓
            // (用户感知就是结果稍微 stale 而已, 而不是卡死)。
            lyricsSearchCache = LibrarySearchCache()
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

            // Albums matching — 点 row 跳到 AlbumDetailView (整张专辑曲目列表)。
            if !matchingAlbums.isEmpty {
                Section("tab_albums") {
                    ForEach(matchingAlbums.prefix(5)) { album in
                        NavigationLink(value: album) {
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
            }

            // Songs grouped by match kind — 用户能一眼区分"标题/艺术家精确命中"、
            // "歌词命中"和"拼音/模糊命中", 类似 Apple Music 搜索的分组。
            // 每组限 40 条 (worker 整体也限 120), 防止单组撑满屏。
            songSection(kind: .metadata, titleKey: "search_section_metadata")
            songSection(kind: .lyrics, titleKey: "search_section_lyrics")
            songSection(kind: .fuzzy, titleKey: "search_section_fuzzy")

            // Apple Music — 即使没结果也显示 section 标题, 让用户一眼看到
            // "为什么没有 Apple Music 推荐" (未授权 / 搜索失败 / 真没结果)。
            appleMusicSection
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var appleMusicSection: some View {
        Section {
            switch appleMusic.authState {
            case .notDetermined:
                Label("apple_music_notice_notDetermined", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            case .denied, .restricted:
                Label("apple_music_notice_denied", systemImage: "lock.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .authorized:
                if appleMusic.isSearching {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("search_apple_music_loading").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let err = appleMusic.lastSearchError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                } else if appleMusic.searchResults.isEmpty {
                    if appleMusic.lastSearchHitCount == 0 {
                        Label("apple_music_notice_no_results", systemImage: "magnifyingglass")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    // hitCount == -1 表示还没搜过, 不显示状态 (避免空 section)
                } else {
                    ForEach(appleMusic.searchResults, id: \.id) { song in
                        appleMusicRow(song)
                    }
                }
                if let err = appleMusic.lastPlaybackError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            HStack {
                Image(systemName: "applelogo")
                Text("search_section_apple_music")
            }
        }
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

        searchGeneration += 1
        let myGen = searchGeneration
        isSearching = true

        searchTask = Task {
            // 不管成功 / 取消 / 出错都要把 isSearching 关回去, 否则 UI 卡在
            // loading 状态。用 generation 防止旧 task 的 defer 覆盖新一轮
            // performSearch 设的状态 — 新 task 已 bump generation 时, 旧 task
            // defer 看到 gen 不匹配就不动 state。
            defer {
                if myGen == searchGeneration {
                    isSearching = false
                }
            }
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
