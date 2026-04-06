import SwiftUI
import PrimuseKit

struct HomeView: View {
    var switchToSettingsTab: (() -> Void)?
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library

    private var hasContent: Bool { !library.visibleSongs.isEmpty }
    private var heroPreviewAlbums: [Album] { Array(library.recentlyAddedAlbums(limit: 3)) }

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

    private var contentView: some View {
        VStack(alignment: .leading, spacing: 24) {
            libraryHeroSection

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
    }

    // MARK: - Library Hero

    private var libraryHeroSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(greeting)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.82))

                    Text("home_library_mix_title")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    Text("home_library_mix_subtitle")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))
                }

                Spacer(minLength: 0)
                heroArtworkPreview
            }

            HStack(spacing: 10) {
                heroStatCard(symbol: "music.note.list", value: library.songCount, label: String(localized: "songs_count"))
                heroStatCard(symbol: "square.stack.fill", value: library.albumCount, label: String(localized: "albums_count"))
                heroStatCard(symbol: "music.mic", value: library.artistCount, label: String(localized: "artists_count"))
            }

            HStack(spacing: 12) {
                Button { playLibrary(shuffled: true) } label: {
                    Label("shuffle", systemImage: "shuffle")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.black)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                Button { playLibrary(shuffled: false) } label: {
                    Label("play_all", systemImage: "play.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(.white.opacity(0.14))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(.white.opacity(0.14), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Text("home_library_mix_hint")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
        }
        .padding(20)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.95),
                                Color.blue.opacity(0.82),
                                Color.black.opacity(0.72)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(.white.opacity(0.14))
                    .frame(width: 180, height: 180)
                    .offset(x: 110, y: -90)

                Circle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 150, height: 150)
                    .offset(x: -120, y: 90)
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .padding(.horizontal, 16)
    }

    private var heroArtworkPreview: some View {
        ZStack {
            if heroPreviewAlbums.isEmpty {
                Image(systemName: "music.note")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 92, height: 92)
                    .background(.white.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            } else {
                ForEach(Array(heroPreviewAlbums.enumerated()), id: \.offset) { index, album in
                    let song = library.songs(forAlbum: album.id).first

                    CachedArtworkView(
                        coverRef: song?.coverArtFileName,
                        songID: song?.id ?? "",
                        size: 72,
                        cornerRadius: 18,
                        sourceID: song?.sourceID,
                        filePath: song?.filePath
                    )
                    .rotationEffect(.degrees(index == 0 ? -8 : (index == 1 ? 0 : 8)))
                    .offset(x: CGFloat(index * 18 - 18), y: index == 1 ? 0 : 10)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                    .zIndex(index == 1 ? 1 : 0)
                }
            }
        }
        .frame(width: 110, height: 96)
    }

    private func heroStatCard(symbol: String, value: Int, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))

            Text("\(value)")
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundStyle(.white)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Recently Played

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("recently_played")
                .font(.title3).fontWeight(.bold).padding(.horizontal, 20)

            let songs = recentSongs
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    // Display in pairs (two rows per column) for compact layout
                    ForEach(Array(stride(from: 0, to: songs.count, by: 2)), id: \.self) { i in
                        VStack(spacing: 8) {
                            Button { playSong(songs[i]) } label: {
                                RecentPlayCard(song: songs[i])
                            }
                            .buttonStyle(.plain)

                            if i + 1 < songs.count {
                                Button { playSong(songs[i + 1]) } label: {
                                    RecentPlayCard(song: songs[i + 1])
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(width: 200)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var recentSongs: [Song] {
        let recent = library.recentlyPlayedSongs(limit: 30)
        if !recent.isEmpty { return recent }
        return Array(library.visibleSongs.sorted { $0.dateAdded > $1.dateAdded }.prefix(30))
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
                                let albumSong = library.songs(forAlbum: album.id).first
                                CachedArtworkView(
                                    coverRef: albumSong?.coverArtFileName,
                                    songID: albumSong?.id ?? "",
                                    size: 140, cornerRadius: 8,
                                    sourceID: albumSong?.sourceID,
                                    filePath: albumSong?.filePath
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
            Image(systemName: "music.note.list").font(.system(size: 56)).foregroundStyle(.tertiary)
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
            let extra = library.visibleSongs.filter { !existingIDs.contains($0.id) }.shuffled()
            queueSongs.append(contentsOf: extra)
        }

        player.shuffleEnabled = false
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
            let extra = library.visibleSongs.filter { !existingIDs.contains($0.id) }
            queueSongs.append(contentsOf: extra)
        }

        let startIndex = queueSongs.firstIndex(where: { $0.id == song.id }) ?? 0
        plog("🏠 setQueue: \(queueSongs.count) songs, startIndex=\(startIndex), songAtIndex='\(queueSongs[startIndex].title)'")
        player.shuffleEnabled = false
        player.setQueue(queueSongs, startAt: startIndex)
        plog("🏠 calling player.play(song: '\(song.title)')")
        Task { await player.play(song: song) }
    }

    private func playLibrary(shuffled: Bool) {
        guard !library.visibleSongs.isEmpty else { return }

        let queueSongs = shuffled ? library.visibleSongs.shuffled() : library.visibleSongs
        guard let firstSong = queueSongs.first else { return }

        player.shuffleEnabled = false
        player.setQueue(queueSongs, startAt: 0)
        Task { await player.play(song: firstSong) }
    }
}

// MARK: - Recent Play Card

struct RecentPlayCard: View {
    let song: Song
    var body: some View {
        HStack(spacing: 10) {
            CachedArtworkView(coverRef: song.coverArtFileName, songID: song.id, size: 48, cornerRadius: 6, sourceID: song.sourceID, filePath: song.filePath)
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
