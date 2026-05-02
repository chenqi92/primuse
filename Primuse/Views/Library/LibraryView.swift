import SwiftUI
import PrimuseKit

enum LibrarySection: String, CaseIterable, Hashable {
    case playlists, artists, albums, songs

    var title: LocalizedStringKey {
        switch self {
        case .playlists: return "tab_playlists"
        case .artists: return "tab_artists"
        case .albums: return "tab_albums"
        case .songs: return "tab_songs"
        }
    }

    var icon: String {
        switch self {
        case .playlists: return "music.note.list"
        case .artists: return "music.mic"
        case .albums: return "square.stack.fill"
        case .songs: return "music.note"
        }
    }

    var color: Color {
        switch self {
        case .playlists: return .red
        case .artists: return .pink
        case .albums: return .purple
        case .songs: return .blue
        }
    }
}

struct LibraryView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @State private var navigationPath = NavigationPath()

    private var songs: [Song] { library.visibleSongs }
    private var albums: [Album] { library.visibleAlbums }
    private var artists: [Artist] { library.visibleArtists }
    private var playlists: [Playlist] { library.playlists }
    private var hasContent: Bool { !songs.isEmpty }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                // Category navigation
                Section {
                    ForEach(LibrarySection.allCases, id: \.self) { section in
                        NavigationLink(value: section) {
                            Label {
                                Text(section.title)
                            } icon: {
                                Image(systemName: section.icon)
                                    .foregroundStyle(section.color)
                            }
                        }
                    }
                }

                if hasContent {
                    // Recently added
                    Section {
                        NavigationLink(value: LibrarySection.songs) {
                            HStack {
                                Text("recently_added")
                                    .font(.headline)
                                Spacer()
                                Text("see_all")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        // 2-column grid of recent songs/albums (no NavigationLink to avoid arrows)
                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)
                        ], spacing: 14) {
                            ForEach(recentItems) { item in
                                RecentItemCard(item: item)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if let song = item.song {
                                            playSong(song)
                                        } else if let album = item.album {
                                            playAlbum(album)
                                        }
                                    }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    // Stats
                    Section {
                        HStack {
                            statLabel("\(songs.count)", String(localized: "tab_songs"))
                            Divider().frame(height: 20)
                            statLabel("\(albums.count)", String(localized: "tab_albums"))
                            Divider().frame(height: 20)
                            statLabel("\(artists.count)", String(localized: "tab_artists"))
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    // Empty state
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 40))
                                .foregroundStyle(.tertiary)

                            Text("welcome_title")
                                .font(.headline)
                            Text("welcome_desc")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            NavigationLink {
                                SourcesView()
                            } label: {
                                Text("manage_sources").fontWeight(.medium)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("library_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: LibrarySection.self) { section in
                switch section {
                case .albums: AlbumGridView().navigationTitle(section.title)
                case .artists: ArtistListView(artists: artists).navigationTitle(section.title)
                case .songs: SongListView(songs: songs).navigationTitle(section.title)
                case .playlists: PlaylistListView().navigationTitle(section.title)
                }
            }
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
        }
    }

    // MARK: - Recent Items

    private var recentItems: [RecentItem] {
        if !albums.isEmpty {
            return albums.prefix(6).map { album in
                let firstSong = library.songs(forAlbum: album.id).first
                return RecentItem(
                    id: album.id,
                    title: album.title,
                    subtitle: album.artistName ?? "",
                    coverFileName: firstSong?.coverArtFileName,
                    songID: firstSong?.id,
                    sourceID: firstSong?.sourceID,
                    filePath: firstSong?.filePath,
                    song: nil,
                    album: album
                )
            }
        }
        return songs.prefix(6).map { song in
            RecentItem(
                id: song.id,
                title: song.title,
                subtitle: song.artistName ?? "",
                coverFileName: song.coverArtFileName,
                songID: song.id,
                sourceID: song.sourceID,
                filePath: song.filePath,
                song: song,
                album: nil
            )
        }
    }

    // MARK: - Helpers

    private func statLabel(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func playAlbum(_ album: Album) {
        let queue = library.songs(forAlbum: album.id).filteredPlayable()
        guard let first = queue.first else { return }
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }

    private func playSong(_ song: Song) {
        let queue = songs.filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        Task { await player.play(song: song) }
    }
}

// MARK: - Recent Item

struct RecentItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let coverFileName: String?
    let songID: String?
    let sourceID: String?
    let filePath: String?
    let song: Song?
    let album: Album?
}

struct RecentItemCard: View {
    let item: RecentItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedArtworkView(coverRef: item.coverFileName, songID: item.songID ?? "", cornerRadius: 8,
                              sourceID: item.sourceID, filePath: item.filePath)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)

            Text(item.title)
                .font(.caption)
                .lineLimit(1)

            Text(item.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

#Preview {
    LibraryView()
        .environment(AudioPlayerService())
        .environment(MusicLibrary())
}
