import SwiftUI
import PrimuseKit

struct SearchView: View {
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
                    if library.songs.isEmpty {
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
        }
        .onChange(of: searchText) { _, newValue in
            performSearch(query: newValue)
        }
    }

    private var recentSearchView: some View {
        List {
            if !recentSearches.isEmpty {
                Section("recent_searches") {
                    ForEach(recentSearches, id: \.self) { query in
                        Button {
                            searchText = query
                        } label: {
                            Label(query, systemImage: "clock")
                        }
                    }
                    .onDelete { recentSearches.remove(atOffsets: $0) }
                }
            }

            Section {
                HStack {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.secondary)
                    Text("\(library.songs.count) \(String(localized: "tab_songs"))")
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
        guard let index = searchResults.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(searchResults, startAt: index)
        Task { await player.play(song: song) }
        if !recentSearches.contains(searchText) {
            recentSearches.insert(searchText, at: 0)
            if recentSearches.count > 10 { recentSearches.removeLast() }
        }
    }
}
