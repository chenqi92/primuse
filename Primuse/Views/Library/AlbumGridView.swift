import SwiftUI
import PrimuseKit

struct AlbumGridView: View {
    @Environment(MusicLibrary.self) private var library
    #if !os(macOS)
    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 16)
    ]
    #endif

    var body: some View {
        if library.albums.isEmpty {
            EmptyStateView(
                titleKey: "no_albums",
                descriptionKey: "no_albums_desc",
                systemImage: "square.stack"
            )
        } else {
            #if os(macOS)
            macGrid
            #else
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(library.albums) { album in
                        NavigationLink(value: album) {
                            AlbumCardView(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            #endif
        }
    }

    #if os(macOS)
    @Environment(AudioPlayerService.self) private var player

    private var macGrid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                MacLibraryHeader(
                    eyebrow: "library_title",
                    title: "tab_albums",
                    subtitle: "\(library.albums.count) \(String(localized: "albums_count"))",
                    iconSystemName: "square.stack.fill",
                    coverSong: library.visibleSongs.first(where: { $0.coverArtFileName?.isEmpty == false }),
                    onPlay: { playAllAlbums(shuffled: false) },
                    onShuffle: { playAllAlbums(shuffled: true) }
                )

                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 160, maximum: 200), spacing: PMSpace.l, alignment: .top)
                ], alignment: .leading, spacing: PMSpace.l24) {
                    ForEach(library.albums) { album in
                        NavigationLink(value: album) {
                            macAlbumTile(album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, PMSpace.xxxl)
                .padding(.top, PMSpace.l)
            }
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
    }

    private func macAlbumTile(_ album: Album) -> some View {
        let song = library.songs(forAlbum: album.id).first
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                CachedArtworkView(
                    coverRef: song?.coverArtFileName,
                    songID: song?.id ?? "",
                    cornerRadius: PMRadius.m,
                    sourceID: song?.sourceID,
                    filePath: song?.filePath
                )
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
            }
            Text(album.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            if let artist = album.artistName {
                Text(artist)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
        }
    }

    private func playAllAlbums(shuffled: Bool) {
        let songs = library.albums
            .flatMap { library.songs(forAlbum: $0.id) }
            .filteredPlayable()
        guard !songs.isEmpty else { return }
        let queue = shuffled ? songs.shuffled() : songs
        guard let first = queue.first else { return }
        player.shuffleEnabled = shuffled
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }
    #endif
}
