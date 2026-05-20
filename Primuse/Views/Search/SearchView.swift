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
                            imageName: "EmptyStateNoSongs",
                            systemImage: "magnifyingglass"
                        )
                    } else {
                        recentSearchView
                    }
                } else if searchResults.isEmpty && matchingAlbums.isEmpty {
                    ContentUnavailableView.search(text: searchText)
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

            // Songs matching
            Section("tab_songs") {
                ForEach(searchResults.prefix(40)) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        SongRowView(
                            song: result.song,
                            isPlaying: player.currentSong?.id == result.song.id,
                            context: SongRowView.context(for: result.song, sourcesStore: sourcesStore, backfill: backfill)
                        )

                        if result.matchKind == .lyrics {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("search_match_lyrics", systemImage: "text.quote")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let snippet = result.lyricSnippet {
                                    Text(snippet)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.leading, 54)
                        } else if result.matchKind == .fuzzy {
                            Label("search_match_fuzzy", systemImage: "sparkle.magnifyingglass")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 54)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { playSong(result.song) }
                }
            }

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
            return
        }

        let songsSnapshot = library.visibleSongs
        let albumsSnapshot = library.visibleAlbums
        let cacheSnapshot = lyricsSearchCache

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
        }
    }

    private func playSong(_ song: PrimuseKit.Song) {
        let queue = searchResults.map(\.song).filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
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
