import SwiftUI
import PrimuseKit

struct HomeView: View {
    var switchToSettingsTab: (() -> Void)?
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

    @State private var spotlightAlbums: [Album] = []

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Album spotlight carousel
            if !spotlightAlbums.isEmpty {
                spotlightCarousel
            }

            // Recently played
            recentlyPlayedSection

            // Recently added albums
            if !library.albums.isEmpty {
                recentlyAddedAlbumsSection
            }

            // Artists
            if !library.artists.isEmpty {
                artistsSection
            }
        }
        .onAppear {
            if spotlightAlbums.isEmpty {
                spotlightAlbums = Array(library.albums.shuffled().prefix(min(library.albums.count, 20)))
            }
        }
        .onChange(of: library.songCount) { _, _ in
            // Refresh spotlight when library changes (e.g. after scraping or re-scan)
            spotlightAlbums = Array(library.albums.shuffled().prefix(min(library.albums.count, 20)))
        }
    }

    // MARK: - Album Spotlight Carousel

    private var spotlightCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(spotlightAlbums) { album in
                    spotlightCard(album: album)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func spotlightCard(album: Album) -> some View {
        let cardWidth: CGFloat = UIScreen.main.bounds.width - 64

        return Button { playAlbum(album) } label: {
            HStack(spacing: 14) {
                CachedArtworkView(
                    coverFileName: library.songs(forAlbum: album.id).first?.coverArtFileName,
                    size: 120, cornerRadius: 12,
                    sourceID: library.songs(forAlbum: album.id).first?.sourceID,
                    filePath: library.songs(forAlbum: album.id).first?.filePath
                )

                VStack(alignment: .leading, spacing: 6) {
                    Spacer()
                    Text(album.title)
                        .font(.headline).fontWeight(.bold)
                        .lineLimit(2)
                    Text(album.artistName ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: "music.note")
                            .font(.caption2)
                        Text("\(album.songCount)")
                            .font(.caption)
                    }
                    .foregroundStyle(.tertiary)
                    Spacer()
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: cardWidth, height: 144)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recently Played

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("recently_played")
                .font(.title3).fontWeight(.bold).padding(.horizontal, 20)

            let songs = recentSongs
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                ForEach(songs) { song in
                    Button { playSong(song) } label: {
                        RecentPlayCard(song: song)
                    }
                    .buttonStyle(.plain)
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

    // MARK: - Recently Added Albums

    private var recentlyAddedAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("recently_added").font(.title3).fontWeight(.bold).padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(library.recentlyAddedAlbums(limit: 10)) { album in
                        Button { playAlbum(album) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CachedArtworkView(
                                    coverFileName: library.songs(forAlbum: album.id).first?.coverArtFileName,
                                    size: 140, cornerRadius: 8,
                                    sourceID: library.songs(forAlbum: album.id).first?.sourceID,
                                    filePath: library.songs(forAlbum: album.id).first?.filePath
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
                                CachedArtworkView(artistID: artist.id, artistName: artist.name,
                                                  size: 80, cornerRadius: 40)
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

    private func playAlbum(_ album: Album) {
        // Get songs for the tapped album directly
        let albumSongs = library.songs(forAlbum: album.id)
        guard let firstSong = albumSongs.first else { return }

        // Build queue: tapped album's songs first, then supplement
        var queueSongs = albumSongs
        if queueSongs.count < 20 {
            let existingIDs = Set(queueSongs.map(\.id))
            let extra = library.songs.filter { !existingIDs.contains($0.id) }.shuffled()
            queueSongs.append(contentsOf: extra)
        }

        player.setQueue(queueSongs, startAt: 0)
        Task { await player.play(song: firstSong) }
    }

    private func playSong(_ song: Song) {
        plog("🏠 playSong TAPPED: '\(song.title)' id=\(song.id.prefix(12)) path=\(song.filePath)")

        // Build queue from recently played songs, supplemented by library
        var queueSongs = library.recentlyPlayedSongs(limit: 50)
        plog("🏠 recentlyPlayed queue: \(queueSongs.count) songs, first3=\(queueSongs.prefix(3).map(\.title))")

        // If tapped song isn't in recent list, prepend it
        if !queueSongs.contains(where: { $0.id == song.id }) {
            queueSongs.insert(song, at: 0)
            plog("🏠 song not in recent, prepended")
        }

        // Supplement with library songs if queue is too small
        if queueSongs.count < 20 {
            let existingIDs = Set(queueSongs.map(\.id))
            let extra = library.songs.filter { !existingIDs.contains($0.id) }
            queueSongs.append(contentsOf: extra)
        }

        let startIndex = queueSongs.firstIndex(where: { $0.id == song.id }) ?? 0
        plog("🏠 setQueue: \(queueSongs.count) songs, startIndex=\(startIndex), songAtIndex='\(queueSongs[startIndex].title)'")
        player.setQueue(queueSongs, startAt: startIndex)
        plog("🏠 calling player.play(song: '\(song.title)')")
        Task { await player.play(song: song) }
    }
}

// MARK: - Recent Play Card

struct RecentPlayCard: View {
    let song: Song
    var body: some View {
        HStack(spacing: 10) {
            CachedArtworkView(coverFileName: song.coverArtFileName, size: 48, cornerRadius: 6, sourceID: song.sourceID, filePath: song.filePath)
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
