import SwiftUI
import PrimuseKit

struct SearchView: View {
    private static let recentSearchesKey = "search_recent_queries"
    private static let recentSearchLimit = 12

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Binding var searchText: String
    @State private var searchResults: [Song] = []
    @State private var recentSearches: [String] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if searchText.isEmpty {
                    if library.visibleSongs.isEmpty {
                        ContentUnavailableView(
                            "search_empty_library",
                            systemImage: "magnifyingglass",
                            description: Text("search_empty_library_desc")
                        )
                    } else {
                        recentSearchView
                    }
                } else if searchResults.isEmpty {
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
            let matchingAlbums = library.albums.filter {
                $0.title.localizedCaseInsensitiveContains(searchText)
                || ($0.artistName?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
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
                ForEach(searchResults.prefix(30)) { song in
                    SongRowView(
                        song: song,
                        isPlaying: player.currentSong?.id == song.id
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { playSong(song) }
                }
            }
        }
        .listStyle(.plain)
    }

    private func performSearch(query: String) {
        searchTask?.cancel()
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        searchTask = Task {
            // Debounce 200ms
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            let results = library.search(query: query)
            searchResults = results
        }
    }

    private func playSong(_ song: Song) {
        let queue = searchResults.filteredPlayable()
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
