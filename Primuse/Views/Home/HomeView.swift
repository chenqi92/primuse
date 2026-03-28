import SwiftUI
import PrimuseKit

struct HomeView: View {
    var switchToSettingsTab: (() -> Void)?
    var expandPlayer: (() -> Void)?
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library

    private var hasContent: Bool { !library.songs.isEmpty }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return String(localized: "greeting_morning")
        case 12..<18: return String(localized: "greeting_afternoon")
        case 18..<22: return String(localized: "greeting_evening")
        default: return String(localized: "greeting_night")
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Greeting
                    Text(greeting)
                        .font(.title2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)

                    if hasContent {
                        contentView
                    } else {
                        emptyView
                    }
                }
                .padding(.bottom, 100)
            }
            .navigationTitle("home_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
        }
    }

    // MARK: - Content

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Now playing compact card (if playing)
            if player.currentSong != nil {
                nowPlayingCompactCard
            }

            // Recently played
            recentlyPlayedSection

            // Albums
            if !library.albums.isEmpty {
                albumsSection
            }

            // Artists
            if !library.artists.isEmpty {
                artistsSection
            }

            // Stats
            statsSection
        }
    }

    // MARK: - Now Playing Compact Card

    private var nowPlayingCompactCard: some View {
        Button { expandPlayer?() } label: {
            HStack(spacing: 12) {
                CachedArtworkView(coverFileName: player.currentSong?.coverArtFileName, size: 56, cornerRadius: 10)

                VStack(alignment: .leading, spacing: 3) {
                    Text("now_playing").font(.caption2).fontWeight(.medium)
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    Text(player.currentSong?.title ?? "").font(.subheadline).fontWeight(.semibold).lineLimit(1)
                    Text(player.currentSong?.artistName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer()

                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 38))
                        .contentTransition(.symbolEffect(.replace))
                }

                Button { Task { await player.next() } } label: {
                    Image(systemName: "forward.fill").font(.body).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    // MARK: - Recently Played

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("recently_played")
                .font(.title3).fontWeight(.bold).padding(.horizontal, 20)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                ForEach(recentSongs.prefix(6)) { song in
                    RecentPlayCard(song: song)
                        .onTapGesture { playSong(song) }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var recentSongs: [Song] {
        let recent = library.recentlyPlayedSongs(limit: 6)
        if !recent.isEmpty { return recent }
        return Array(library.songs.sorted { $0.dateAdded > $1.dateAdded }.prefix(6))
    }

    // MARK: - Albums

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("for_you").font(.title3).fontWeight(.bold).padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(library.albums.prefix(10)) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 6) {
                                CachedArtworkView(
                                    coverFileName: library.songs(forAlbum: album.id).first?.coverArtFileName,
                                    size: 140, cornerRadius: 8
                                )
                                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                                Text(album.title).font(.caption).fontWeight(.medium).lineLimit(1)
                                    .frame(width: 140, alignment: .leading)
                                Text(album.artistName ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    .frame(width: 140, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Artists

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("tab_artists").font(.title3).fontWeight(.bold).padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(library.artists.prefix(8)) { artist in
                        NavigationLink(value: artist) {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(.quaternary)
                                    .frame(width: 80, height: 80)
                                    .overlay {
                                        Image(systemName: "music.mic")
                                            .font(.title2).foregroundStyle(.secondary)
                                    }
                                Text(artist.name).font(.caption).lineLimit(1).frame(width: 80)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 0) {
            statItem("\(library.songCount)", String(localized: "tab_songs"))
            Divider().frame(height: 20)
            statItem("\(library.albumCount)", String(localized: "tab_albums"))
            Divider().frame(height: 20)
            statItem("\(library.artistCount)", String(localized: "tab_artists"))
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 20)
    }

    private func statItem(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 40)
            Image(systemName: "waveform.and.music.note").font(.system(size: 56)).foregroundStyle(.tertiary)
            VStack(spacing: 8) {
                Text("welcome_title").font(.title2).fontWeight(.bold)
                Text("home_empty_desc").font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            Button { switchToSettingsTab?() } label: {
                Label("manage_sources", systemImage: "externaldrive.badge.plus")
                    .fontWeight(.semibold).frame(maxWidth: .infinity).padding(.vertical, 14)
            }.buttonStyle(.borderedProminent).padding(.horizontal, 40)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private func playSong(_ song: Song) {
        guard let index = library.songs.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(library.songs, startAt: index)
        Task { await player.play(song: song) }
    }
}

// MARK: - Recent Play Card

struct RecentPlayCard: View {
    let song: Song
    var body: some View {
        HStack(spacing: 10) {
            CachedArtworkView(coverFileName: song.coverArtFileName, size: 48, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.caption).fontWeight(.medium).lineLimit(1)
                Text(song.artistName ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
