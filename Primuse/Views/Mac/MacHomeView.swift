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
            VStack(alignment: .leading, spacing: 32) {
                heroSection

                if hasContent {
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
            .padding(.top, 24)
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

    /// 左 greeting + 大标题 + 库统计一行 / 右 Play All + Shuffle 按钮组。
    /// 替换原本的 4 列 stat strip — 后者最末位放 quick-play 双按钮卡，
    /// 在窗口偏窄时按钮文案被截断成 "随机..."。
    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(greeting)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("welcome_back")
                        .font(.system(size: 34, weight: .bold))
                    Text(librarySummary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    Button { playLibrary(shuffled: true) } label: {
                        Label("shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button { playLibrary(shuffled: false) } label: {
                        Label("play_all", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .disabled(!hasContent)
            }
        }
    }

    private var librarySummary: String {
        let songs = String(localized: "tab_songs")
        let albums = String(localized: "tab_albums")
        let artists = String(localized: "tab_artists")
        return "\(library.songCount) \(songs) · \(library.albumCount) \(albums) · \(library.artistCount) \(artists)"
    }

    // MARK: - Recently Added

    private var recentlyAddedAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("recently_added")
                .font(.title3).fontWeight(.semibold)

            // 130/170 让 1180 宽窗口下能塞 6 列；之前 160/200 在窄窗口
            // 退化成 1 列就一片留白。
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 18, alignment: .top)
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
