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
    var switchToSourcesTab: (() -> Void)?
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library

    private var songs: [Song] { library.songs }
    private var albums: [Album] { library.albums }
    private var artists: [Artist] { library.artists }
    private var playlists: [Playlist] { library.playlists }
    private var hasContent: Bool { !songs.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Apple Music style category list
                    categorySectionList
                        .padding(.top, 4)

                    if hasContent {
                        // Recently Added (2-column grid like Apple Music)
                        recentlyAddedSection
                            .padding(.top, 16)
                    } else {
                        emptyStateView
                            .padding(.top, 32)
                    }

                    Spacer(minLength: 100)
                }
            }
            .navigationTitle("library_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: LibrarySection.self) { section in
                switch section {
                case .albums: AlbumGridView(albums: albums).navigationTitle(section.title)
                case .artists: ArtistListView(artists: artists).navigationTitle(section.title)
                case .songs: SongListView(songs: songs).navigationTitle(section.title)
                case .playlists: PlaylistListView(playlists: playlists).navigationTitle(section.title)
                }
            }
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
        }
    }

    // MARK: - Category List (Apple Music style — full-width rows with icons)

    private var categorySectionList: some View {
        VStack(spacing: 0) {
            ForEach(LibrarySection.allCases, id: \.self) { section in
                NavigationLink(value: section) {
                    HStack(spacing: 12) {
                        Image(systemName: section.icon)
                            .font(.title3)
                            .foregroundStyle(section.color)
                            .frame(width: 28)

                        Text(section.title)
                            .font(.body)
                            .foregroundStyle(.primary)

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)

                if section != LibrarySection.allCases.last {
                    Divider()
                        .padding(.leading, 60)
                }
            }
        }
    }

    // MARK: - Recently Added (2-column grid, Apple Music style)

    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section header
            HStack {
                Text("recently_added")
                    .font(.title3)
                    .fontWeight(.bold)
                Spacer()
                NavigationLink(value: LibrarySection.songs) {
                    Text("see_all")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 20)

            // 2-column grid
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ],
                spacing: 20
            ) {
                ForEach(recentItems) { item in
                    RecentItemCard(item: item)
                        .onTapGesture {
                            if let song = item.song { playSong(song) }
                        }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var recentItems: [RecentItem] {
        // Group by album, show album covers if available, else songs
        if !albums.isEmpty {
            return albums.prefix(8).map { album in
                RecentItem(
                    id: album.id,
                    title: album.title,
                    subtitle: album.artistName ?? "",
                    song: nil
                )
            }
        }
        return songs.prefix(8).map { song in
            RecentItem(
                id: song.id,
                title: song.title,
                subtitle: song.artistName ?? "",
                song: song
            )
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note.house.fill")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text("welcome_title")
                    .font(.headline)
                Text("welcome_desc")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
            }

            Button {
                switchToSourcesTab?()
            } label: {
                Text("add_source")
                    .fontWeight(.medium)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Play

    private func playSong(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(songs, startAt: index)
        if let url = URL(string: song.filePath) {
            Task { await player.play(song: song, from: url) }
        }
    }
}

// MARK: - Recent Item Model

struct RecentItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let song: Song?
}

// MARK: - Recent Item Card (album art style)

struct RecentItemCard: View {
    let item: RecentItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Album artwork placeholder with generated gradient
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(cardGradient)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)

                VStack(spacing: 4) {
                    Image(systemName: "music.note")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.9))
                }
            }

            Text(item.title)
                .font(.caption)
                .lineLimit(1)

            Text(item.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var cardGradient: LinearGradient {
        let hash = abs(item.title.hashValue)
        let hue = Double(hash % 360) / 360.0
        let hue2 = (hue + 0.08).truncatingRemainder(dividingBy: 1.0)
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.45, brightness: 0.75),
                Color(hue: hue2, saturation: 0.55, brightness: 0.55),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#Preview {
    LibraryView()
        .environment(AudioPlayerService())
        .environment(MusicLibrary())
}
