import SwiftUI
import PrimuseKit

struct HomeView: View {
    var switchToSettingsTab: (() -> Void)?
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @State private var showNowPlaying = false

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
                        .font(.title)
                        .fontWeight(.bold)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)

                    // Big now playing card (when playing)
                    if player.currentSong != nil {
                        nowPlayingCard
                    }

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
            .sheet(isPresented: $showNowPlaying) {
                NowPlayingView()
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(20)
            }
        }
    }

    // MARK: - Now Playing Card (hero card)

    private var nowPlayingCard: some View {
        Button { showNowPlaying = true } label: {
            VStack(spacing: 0) {
                // Large artwork
                CachedArtworkView(
                    coverFileName: player.currentSong?.coverArtFileName,
                    cornerRadius: 0
                )
                .frame(height: 200)
                .clipped()

                // Info + controls overlay
                VStack(spacing: 10) {
                    // Song info row
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.currentSong?.title ?? "")
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .lineLimit(1)
                            Text(player.currentSong?.artistName ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        // Controls
                        HStack(spacing: 18) {
                            Button {
                                Task { await player.previous() }
                            } label: {
                                Image(systemName: "backward.fill").font(.body)
                            }

                            Button {
                                player.togglePlayPause()
                            } label: {
                                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                    .font(.system(size: 36))
                                    .contentTransition(.symbolEffect(.replace))
                            }

                            Button {
                                Task { await player.next() }
                            } label: {
                                Image(systemName: "forward.fill").font(.body)
                            }
                        }
                        .foregroundStyle(.primary)
                    }

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary).frame(height: 4)
                            let progress = player.duration > 0 ? player.currentTime / player.duration : 0
                            Capsule().fill(Color.accentColor)
                                .frame(width: geo.size.width * max(0, min(1, CGFloat(progress))), height: 4)
                        }
                    }
                    .frame(height: 4)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    // MARK: - Content

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Recently played (Spotify 2-col grid)
            recentlyPlayedSection

            // Albums
            if !library.albums.isEmpty {
                albumsSection
            }

            // Stats
            statsSection
        }
    }

    // MARK: - Recently Played

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("recently_played")
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal, 20)

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
        let recentlyPlayed = library.recentlyPlayedSongs(limit: 6)
        if recentlyPlayed.isEmpty == false {
            return recentlyPlayed
        }

        return Array(library.songs.sorted { $0.dateAdded > $1.dateAdded }.prefix(6))
    }

    // MARK: - Albums

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("for_you")
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(library.albums.prefix(10)) { album in
                        NavigationLink(value: album) {
                            VStack(alignment: .leading, spacing: 6) {
                                CachedArtworkView(
                                    coverFileName: coverForAlbum(album),
                                    size: 140,
                                    cornerRadius: 8
                                )
                                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

                                Text(album.title)
                                    .font(.caption).fontWeight(.medium).lineLimit(1)
                                    .frame(width: 140, alignment: .leading)
                                Text(album.artistName ?? "")
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
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

    private func coverForAlbum(_ album: Album) -> String? {
        library.songs(forAlbum: album.id).first?.coverArtFileName
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
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 40)
            Image(systemName: "waveform.and.music.note")
                .font(.system(size: 56)).foregroundStyle(.tertiary)
            VStack(spacing: 8) {
                Text("welcome_title").font(.title2).fontWeight(.bold)
                Text("home_empty_desc")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            Button {
                switchToSettingsTab?()
            } label: {
                Label("manage_sources", systemImage: "externaldrive.badge.plus")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Play

    private func playSong(_ song: Song) {
        guard let index = library.songs.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(library.songs, startAt: index)
        Task { await player.play(song: song) }
    }
}

// MARK: - Recent Play Card (Spotify compact)

struct RecentPlayCard: View {
    let song: Song

    var body: some View {
        HStack(spacing: 10) {
            CachedArtworkView(coverFileName: song.coverArtFileName, size: 48, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.caption).fontWeight(.medium).lineLimit(1)
                Text(song.artistName ?? "")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
