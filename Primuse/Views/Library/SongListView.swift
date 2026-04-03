import SwiftUI
import PrimuseKit

struct SongListView: View {
    @Environment(AudioPlayerService.self) private var player
    let songs: [Song]
    @State private var sortOrder: SongSortOrder = .title
    @State private var cachedSortedSongs: [Song] = []

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
                            isPlaying: player.currentSong?.id == song.id
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
            .onChange(of: songs) { _, _ in recomputeSorted() }
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
    }

    private func playSong(_ song: Song) {
        guard let index = cachedSortedSongs.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(cachedSortedSongs, startAt: index)
        Task { await player.play(song: song) }
    }
}
