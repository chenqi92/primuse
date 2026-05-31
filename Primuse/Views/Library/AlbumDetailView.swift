import SwiftUI
import PrimuseKit

struct AlbumDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicScraperService.self) private var scraperService
    let album: Album

    private var songs: [Song] {
        library.songs(forAlbum: album.id)
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        legacyBody
        #endif
    }

    private var legacyBody: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Album header
                VStack(spacing: 12) {
                    CachedArtworkView(albumID: album.id, albumTitle: album.title,
                                      artistName: album.artistName,
                                      size: 220, cornerRadius: 14)

                    Text(album.title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)

                    Text(album.artistName ?? String(localized: "unknown_artist"))
                        .font(.body)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        if let year = album.year {
                            Text("\(year)")
                        }
                        Text("\(album.songCount) \(String(localized: "songs_count"))")
                        Text(formatDuration(album.totalDuration))
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                .padding(.top, 20)

                // Action buttons ── 主按钮"播放全部"占大头, 旁边两个紧凑图标按钮。
                HStack(spacing: 10) {
                    Button {
                        playAll()
                    } label: {
                        Label("play_all", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        shuffleAll()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.headline)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel(Text("shuffle"))

                    Button {
                        sourceManager.downloadForOffline(songs: songs)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.headline)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(songs.filteredPlayable().isEmpty)
                    .accessibilityLabel(Text("offline_download"))
                }
                .padding(.horizontal)

                // Track list
                LazyVStack(spacing: 0) {
                    ForEach(songs) { song in
                        SongRowView(
                            song: song,
                            isPlaying: player.currentSong?.id == song.id,
                            showAlbum: false,
                            context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            playSong(song)
                        }

                        Divider()
                            .padding(.leading, 50)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    #if os(macOS)
    private var macBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                MacLibraryHeader(
                    eyebrow: "专辑",
                    title: album.title,
                    subtitle: albumSubtitle,
                    iconSystemName: "square.stack.fill",
                    coverSong: songs.first(where: { $0.coverArtFileName?.isEmpty == false }) ?? songs.first,
                    onPlay: playAll,
                    onShuffle: shuffleAll,
                    moreMenu: albumMoreMenu
                )

                VStack(alignment: .leading, spacing: PMSpace.l) {
                    albumInfoCard
                    macToolbar

                    if songs.isEmpty {
                        EmptyStateView(
                            titleKey: "no_songs",
                            descriptionKey: "no_songs_desc",
                            systemImage: "music.note"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    } else {
                        macTrackTable
                    }
                }
                .padding(.horizontal, PMSpace.xxxl)
                .padding(.top, PMSpace.l)
            }
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    /// header 右上角"更多"按钮的菜单内容。播放 / 队列 / 离线 / 前往艺术家。
    private var albumMoreMenu: AnyView {
        let playable = songs.filteredPlayable()

        var second: [MacHeaderMoreMenu.Item] = [
            .init(icon: "arrow.down.circle", title: "离线下载", enabled: !playable.isEmpty) {
                sourceManager.downloadForOffline(songs: songs)
            },
            .init(icon: "wand.and.stars", title: String(localized: "scrape_missing_metadata"),
                  trailing: songs.count.formatted(),
                  enabled: !songs.isEmpty && !scraperService.isScraping) {
                scraperService.scrapeMissingMetadata(songs: songs, in: library)
            },
        ]
        if let artist = albumArtist {
            second.append(.init(icon: "music.mic", title: "前往艺术家") {
                NotificationCenter.default.post(name: .primuseDetailOpenArtist, object: artist)
            })
        }

        return AnyView(MacHeaderMoreMenu(sections: [
            [
                .init(icon: "play.fill", title: "播放全部", enabled: !playable.isEmpty, action: playAll),
                .init(icon: "shuffle", title: "随机播放", enabled: !playable.isEmpty, action: shuffleAll),
                .init(icon: "text.line.last.and.arrowtriangle.forward", title: "加入播放队列",
                      enabled: !playable.isEmpty) { player.appendToQueue(playable) },
                .init(icon: "text.line.first.and.arrowtriangle.forward", title: "下一首播放",
                      enabled: !playable.isEmpty) { player.insertNextInQueue(playable) },
            ],
            second,
        ]))
    }

    private var albumArtist: Artist? {
        library.artists.first { $0.id == album.artistID || $0.name == album.artistName }
    }

    private var albumSubtitle: String {
        var parts: [String] = []
        if let artist = album.artistName, !artist.isEmpty {
            parts.append(artist)
        }
        if let year = album.year {
            parts.append("\(year)")
        }
        parts.append("\(album.songCount) \(String(localized: "songs_count"))")
        parts.append(formatDuration(album.totalDuration))
        return parts.joined(separator: " · ")
    }

    private var albumInfoCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PMColor.brand)
                .frame(width: 42, height: 42)
                .background(PMColor.brand.opacity(0.16), in: .rect(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 4) {
                Text(album.artistName ?? String(localized: "unknown_artist"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(verbatim: "\(songs.filteredPlayable().count) \(String(localized: "home_playable")) · \(album.totalDuration.formattedShort)")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }

            Spacer()

            if let year = album.year {
                Text(verbatim: "\(year)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(PMColor.glassBtn, in: .capsule)
            }
        }
        .padding(14)
        .pmGlass(cornerRadius: PMRadius.m10)
    }

    private var macToolbar: some View {
        HStack(spacing: 8) {
            Text("songs_count")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(PMColor.textFaint)
            Spacer()
            PMRoundBtn(icon: "arrow.down.circle", size: 26, iconSize: 12, style: .glass,
                       help: "offline_download") {
                sourceManager.downloadForOffline(songs: songs)
            }
            .disabled(songs.filteredPlayable().isEmpty)
        }
        .padding(.top, -2)
    }

    private var macTrackTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: PMSpace.s10) {
                Text("#").frame(width: 28, alignment: .center)
                Color.clear.frame(width: 36)
                Text("sort_title").frame(maxWidth: .infinity, alignment: .leading)
                Text("sort_artist").frame(width: 180, alignment: .leading)
                Text("sort_format").frame(width: 70, alignment: .leading)
                Text("track_duration_short").frame(width: 58, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
            .padding(.horizontal, PMSpace.s8)
            .padding(.vertical, 6)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            LazyVStack(spacing: 1) {
                ForEach(Array(albumTracks.enumerated()), id: \.element.id) { index, song in
                    macTrackRow(song, index: index)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var albumTracks: [Song] {
        songs.sorted {
            let left = $0.trackNumber ?? Int.max
            let right = $1.trackNumber ?? Int.max
            if left != right { return left < right }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func macTrackRow(_ song: Song, index: Int) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        return Button { playSong(song) } label: {
            HStack(spacing: PMSpace.s10) {
                ZStack {
                    if isCurrent {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                    } else {
                        Text("\(song.trackNumber ?? index + 1)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
                .frame(width: 28, alignment: .center)

                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id,
                    size: 32, cornerRadius: PMRadius.xs,
                    sourceID: song.sourceID, filePath: song.filePath
                )

                Text(song.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(song.artistName ?? "—")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .frame(width: 180, alignment: .leading)

                PMFormatPill.forFormat(song.fileFormat.displayName)
                    .frame(width: 70, alignment: .leading)

                Text(song.duration.formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.textFaint)
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, PMSpace.s8)
            .padding(.vertical, 6)
            .pmRowBackground(selected: isCurrent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    #endif

    private func playAll() {
        let queue = songs.filteredPlayable()
        guard let first = queue.first else { return }
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }

    private func shuffleAll() {
        player.shuffleEnabled = true
        playAll()
    }

    private func playSong(_ song: Song) {
        let queue = songs.filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        Task { await player.play(song: song) }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        duration.formattedShort
    }
}
