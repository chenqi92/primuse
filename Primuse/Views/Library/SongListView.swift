import SwiftUI
import PrimuseKit

struct SongListView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    let songs: [Song]
    @State private var sortOrder: SongSortOrder = .title
    @State private var cachedSortedSongs: [Song] = []
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
                ForEach(cachedSortedSongs) { song in
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("sort_by", selection: $sortOrder) {
                            ForEach(SongSortOrder.allCases, id: \.self) { order in
                                Text(order.label).tag(order)
                            }
                        }
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

    /// Decide whether `songs` changed structurally (added/removed) or only
    /// in metadata (backfill replaced a Song in place). Only the structural
    /// case warrants a re-sort.
    private func updateSortedSongsIfNeeded() {
        let newIDSet = Set(songs.map(\.id))
        if newIDSet == lastSortedIDSet {
            // Same set of songs, just metadata updates — patch in place,
            // preserving the user's current sort order. New title / artist
            // / duration values flow into rows without a full re-sort.
            let byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
            cachedSortedSongs = cachedSortedSongs.compactMap { byID[$0.id] }
        } else {
            recomputeSorted()
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
