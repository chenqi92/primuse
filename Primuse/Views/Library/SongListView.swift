import SwiftUI
import PrimuseKit

struct SongListView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    let songs: [Song]
    @State private var sortOrder: SongSortOrder = .title
    @State private var cachedSortedSongs: [Song] = []
    @State private var searchText: String = ""
    /// ID set the cached order was built from. When `songs` changes by
    /// metadata only (backfill filling in title/duration on existing IDs)
    /// we update each row in-place instead of re-running localizedCompare
    /// across the whole list. Without this, every backfilled track would
    /// trigger an O(N log N) re-sort on the main thread, and a 1k-song
    /// list mid-scan would be visibly stuttery.
    @State private var lastSortedIDSet: Set<String> = []

    enum SongSortOrder: String, CaseIterable {
        case title, artist, album, dateAdded, format

        var label: LocalizedStringKey {
            switch self {
            case .title: return "sort_title"
            case .artist: return "sort_artist"
            case .album: return "sort_album"
            case .dateAdded: return "sort_date_added"
            case .format: return "sort_format"
            }
        }
    }

    var body: some View {
        if songs.isEmpty {
            ContentUnavailableView(
                "no_songs",
                systemImage: "music.note",
                description: Text("no_songs_desc")
            )
        } else {
            List {
                ForEach(filteredSongs) { song in
                    Button {
                        playSong(song)
                    } label: {
                        SongRowView(
                            song: song,
                            isPlaying: player.currentSong?.id == song.id,
                            context: SongRowView.context(
                                for: song,
                                sourcesStore: sourcesStore,
                                backfill: backfill
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText,
                        placement: .toolbar,
                        prompt: Text("search_songs_prompt"))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("sort_by", selection: $sortOrder) {
                            ForEach(SongSortOrder.allCases, id: \.self) { order in
                                Text(order.label).tag(order)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
            .onAppear { recomputeSorted() }
            .onChange(of: sortOrder) { _, _ in recomputeSorted() }
            .onChange(of: songs) { _, _ in updateSortedSongsIfNeeded() }
        }
    }

    /// 当前用搜索过滤后的歌曲列表;空字符串时返回完整 cachedSortedSongs。
    /// 大小写无关,匹配标题/艺术家/专辑任一字段。
    private var filteredSongs: [Song] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return cachedSortedSongs }
        return cachedSortedSongs.filter {
            $0.title.localizedCaseInsensitiveContains(q)
            || ($0.artistName?.localizedCaseInsensitiveContains(q) ?? false)
            || ($0.albumTitle?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    /// Decide whether `songs` changed structurally (added/removed), in
    /// metadata that affects the active sort field, or in metadata that
    /// doesn't. Only the first two warrant a re-sort:
    ///
    /// - ID set changed → re-sort.
    /// - ID set same, but at least one row's `sortKey` changed (e.g.
    ///   backfill filled in a previously-empty title while sorted by
    ///   title) → re-sort, otherwise the visible order would silently
    ///   diverge from the chosen sort.
    /// - ID set same, no sortKey changes → in-place patch, preserving
    ///   order to avoid an O(N log N) localizedCompare on every
    ///   backfill tick.
    private func updateSortedSongsIfNeeded() {
        let newIDSet = Set(songs.map(\.id))
        guard newIDSet == lastSortedIDSet else {
            recomputeSorted()
            return
        }
        let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        let sortKeyChanged = cachedSortedSongs.contains { old in
            guard let new = byID[old.id] else { return false }
            return sortKey(for: new) != sortKey(for: old)
        }
        if sortKeyChanged {
            recomputeSorted()
        } else {
            cachedSortedSongs = cachedSortedSongs.compactMap { byID[$0.id] }
        }
    }

    /// The string representation of whichever song field drives the
    /// active sort. Compared to detect when an in-place metadata update
    /// invalidates the cached order. `.dateAdded` and `.format` rarely
    /// change after creation, so those sorts almost always stay on the
    /// fast path; `.title` / `.artist` / `.album` re-sort during
    /// backfill, which is exactly the correctness boundary we want.
    private func sortKey(for song: Song) -> String {
        switch sortOrder {
        case .title: return song.title
        case .artist: return song.artistName ?? ""
        case .album: return song.albumTitle ?? ""
        case .dateAdded: return String(song.dateAdded.timeIntervalSince1970)
        case .format: return song.fileFormat.displayName
        }
    }

    private func recomputeSorted() {
        switch sortOrder {
        case .title:
            cachedSortedSongs = songs.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        case .artist:
            cachedSortedSongs = songs.sorted { ($0.artistName ?? "").localizedCompare($1.artistName ?? "") == .orderedAscending }
        case .album:
            cachedSortedSongs = songs.sorted { ($0.albumTitle ?? "").localizedCompare($1.albumTitle ?? "") == .orderedAscending }
        case .dateAdded:
            cachedSortedSongs = songs.sorted { $0.dateAdded > $1.dateAdded }
        case .format:
            cachedSortedSongs = songs.sorted { $0.fileFormat.displayName < $1.fileFormat.displayName }
        }
        lastSortedIDSet = Set(cachedSortedSongs.map(\.id))
    }

    private func playSong(_ song: Song) {
        let queue = cachedSortedSongs.filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        Task { await player.play(song: song) }
    }
}
