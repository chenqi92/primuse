#if os(macOS)
import SwiftUI
import PrimuseKit

/// macOS-native home dashboard. Replaces the iOS hero card + full-width
/// purple buttons with a denser layout that's appropriate for a wide
/// desktop window: a quick-stats strip, recently added albums grid and
/// recently played row. No tinted blocks, no fixed-width oversized
/// buttons — inherits the system's tinted/bordered controls so it sits
/// quietly inside the window chrome.
struct MacHomeView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player

    private var hasContent: Bool { !library.visibleSongs.isEmpty }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 28) {
                header

                if hasContent {
                    statsStrip
                    recentlyAddedAlbumsSection
                    recentlyPlayedSection
                    if !library.visibleArtists.isEmpty {
                        artistsSection
                    }
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            // Mini bar (~76pt) sits in the bottom safe area inset; pad
            // generously so the last row doesn't tuck under it.
            .padding(.bottom, 96)
        }
    }

    // MARK: - Sections

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return String(localized: "greeting_morning")
        case 12..<18: return String(localized: "greeting_afternoon")
        case 18..<22: return String(localized: "greeting_evening")
        default: return String(localized: "greeting_night")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greeting)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("home_title")
                .font(.system(size: 30, weight: .bold))
        }
    }

    private var statsStrip: some View {
        HStack(spacing: 12) {
            statCard(symbol: "music.note", value: library.songCount, label: String(localized: "tab_songs"))
            statCard(symbol: "square.stack.fill", value: library.albumCount, label: String(localized: "tab_albums"))
            statCard(symbol: "music.mic", value: library.artistCount, label: String(localized: "tab_artists"))
            quickPlayCard
        }
    }

    private func statCard(symbol: String, value: Int, label: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }

    private var quickPlayCard: some View {
        HStack(spacing: 8) {
            Button { playLibrary(shuffled: true) } label: {
                Label("shuffle", systemImage: "shuffle")
            }
            .buttonStyle(.borderedProminent)

            Button { playLibrary(shuffled: false) } label: {
                Label("play_all", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }

    // MARK: - Recently Added

    private var recentlyAddedAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("recently_added")
                .font(.title3).fontWeight(.semibold)

            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 18, alignment: .top)
            ], alignment: .leading, spacing: 22) {
                ForEach(library.recentlyAddedAlbums(limit: 12)) { album in
                    Button { playAlbum(album) } label: {
                        albumCard(album)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func albumCard(_ album: Album) -> some View {
        let song = library.songs(forAlbum: album.id).first
        return VStack(alignment: .leading, spacing: 8) {
            CachedArtworkView(
                coverRef: song?.coverArtFileName,
                songID: song?.id ?? "",
                cornerRadius: 8,
                sourceID: song?.sourceID,
                filePath: song?.filePath
            )
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

            Text(album.title)
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(1)
            if let artist = album.artistName {
                Text(artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Recently Played

    private var recentlyPlayedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("recently_played")
                .font(.title3).fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(recentSongs) { song in
                        Button { playSong(song) } label: {
                            recentSongChip(song)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func recentSongChip(_ song: Song) -> some View {
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 44,
                cornerRadius: 6,
                sourceID: song.sourceID,
                filePath: song.filePath
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(song.artistName ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 160, alignment: .leading)
        }
        .padding(8)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }

    private var recentSongs: [Song] {
        let recent = library.recentlyPlayedSongs(limit: 18)
        if !recent.isEmpty { return recent }
        return Array(library.visibleSongs.sorted { $0.dateAdded > $1.dateAdded }.prefix(18))
    }

    // MARK: - Artists

    private var artistsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("tab_artists")
                .font(.title3).fontWeight(.semibold)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(library.visibleArtists.prefix(10)) { artist in
                        NavigationLink(value: artist) {
                            VStack(spacing: 6) {
                                CachedArtworkView(
                                    artistID: artist.id,
                                    artistName: artist.name,
                                    size: 84,
                                    cornerRadius: 42
                                )
                                Text(artist.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(width: 84)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer().frame(height: 60)
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(.tertiary)
            Text("welcome_title")
                .font(.title2).fontWeight(.semibold)
            Text("welcome_desc")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("home_empty_mac_hint")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func playAlbum(_ album: Album) {
        var queue = library.songs(forAlbum: album.id)
        if queue.count < 20 {
            let existingIDs = Set(queue.map(\.id))
            let extra = library.visibleSongs.filter { !existingIDs.contains($0.id) }.shuffled()
            queue.append(contentsOf: extra)
        }
        queue = queue.filteredPlayable()
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }

    private func playSong(_ song: Song) {
        var queue = library.recentlyPlayedSongs(limit: 50)
        if !queue.contains(where: { $0.id == song.id }) { queue.insert(song, at: 0) }
        if queue.count < 20 {
            let existingIDs = Set(queue.map(\.id))
            queue.append(contentsOf: library.visibleSongs.filter { !existingIDs.contains($0.id) })
        }
        queue = queue.filteredPlayable()
        guard let startIndex = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: startIndex)
        Task { await player.play(song: queue[startIndex]) }
    }

    private func playLibrary(shuffled: Bool) {
        let candidates = library.visibleSongs.filteredPlayable()
        guard !candidates.isEmpty else { return }
        let queue = shuffled ? candidates.shuffled() : candidates
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }
}
#endif
