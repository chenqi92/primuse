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

                        // 2-column grid of recent songs/albums
                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12)
                        ], spacing: 14) {
                            ForEach(recentItems) { item in
                                RecentItemCard(item: item)
                                    .onTapGesture {
                                        if let song = songs.first(where: { $0.id == item.id }) {
                                            playSong(song)
                                        } else if let album = albums.first(where: { $0.id == item.id }) {
                                            // Navigate to album — handled by navigationDestination
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
                            Image(systemName: "waveform.and.music.note")
                                .font(.system(size: 40))
                                .foregroundStyle(.tertiary)

                            Text("welcome_title")
                                .font(.headline)
                            Text("welcome_desc")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            Button {
                                switchToSourcesTab?()
                            } label: {
                                Text("add_source").fontWeight(.medium)
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
                case .albums: AlbumGridView(albums: albums).navigationTitle(section.title)
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
            return albums.prefix(6).map {
                RecentItem(id: $0.id, title: $0.title, subtitle: $0.artistName ?? "", song: nil)
            }
        }
        return songs.prefix(6).map {
            RecentItem(id: $0.id, title: $0.title, subtitle: $0.artistName ?? "", song: $0)
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

    private func playSong(_ song: Song) {
        guard let index = songs.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(songs, startAt: index)
        Task { await player.play(song: song) }
    }
}

// MARK: - Recent Item

struct RecentItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let song: Song?
}

struct RecentItemCard: View {
    let item: RecentItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(cardGradient)
                    .aspectRatio(1, contentMode: .fit)
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)

                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.8))
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
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.45, brightness: 0.75),
                Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.55, brightness: 0.55)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

#Preview {
    LibraryView()
        .environment(AudioPlayerService())
        .environment(MusicLibrary())
}
