import SwiftUI
import PrimuseKit

struct ArtistDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    let artist: Artist
    private let onMacInlineBack: (() -> Void)?

    init(artist: Artist, onMacInlineBack: (() -> Void)? = nil) {
        self.artist = artist
        self.onMacInlineBack = onMacInlineBack
    }

    private var albums: [Album] {
        library.visibleAlbums.filter {
            $0.artistID == artist.id || $0.artistName == artist.name
        }
    }

    private var songs: [Song] {
        library.songs(forArtist: artist.id)
    }

    private var playableSongs: [Song] {
        songs.filteredPlayable()
    }

    private var visibleSongCount: Int {
        songs.count
    }

    private var displayArtistName: String {
        let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "unknown_artist") : name
    }

    private var monthlyListenCount: Int {
        let target = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return 0 }
        return PlayHistoryStore.shared.entries(in: .month).filter {
            ArtistNameParser.contains(
                artistName: target,
                rawName: $0.artistName,
                configuration: library.artistNameConfiguration
            )
        }.count
    }

    private var monthlyListenText: String {
        String(
            format: String(localized: "artist_monthly_plays_format"),
            monthlyListenCount
        )
    }

    private var playCountsBySongID: [String: Int] {
        Dictionary(grouping: PlayHistoryStore.shared.entries, by: \.songID)
            .mapValues(\.count)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 100), spacing: 12)
    ]

    @State private var selection = SongSelectionModel()
    @State private var showArtworkEditor = false
    @State private var serverMediaShareTarget: ServerMediaShareTarget?

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            ScrollView {
                detailContent
            }
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(iOS)
        .minimalNavigationDetail()
        #endif
        .songBatchActions(
            selection: selection,
            orderedIDs: { selectableSongIDs },
            resolve: { library.song(id: $0) }
        )
        #if os(iOS) || os(macOS)
        .sheet(isPresented: $showArtworkEditor) {
            LibraryArtworkEditorSheet(
                owner: LibraryArtworkOwner(kind: .artist, id: artist.id),
                title: String(localized: "artwork_editor_title"),
                songs: songs
            )
        }
        .sheet(item: $serverMediaShareTarget) { target in
            ServerMediaShareSheet(target: target)
        }
        #endif
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let target = artistServerMediaShareTarget {
                    Button {
                        serverMediaShareTarget = target
                    } label: {
                        Image(systemName: "link.badge.plus")
                    }
                    .accessibilityLabel(Text("server_share_action"))
                }
                Button("artwork_edit") {
                    showArtworkEditor = true
                }
            }
        }
        #endif
    }

    /// macOS 的艺术家页只铺「热门」那 8 首，"全选"就不该把用户看不到的
    /// 其余歌一起圈进来。
    private var selectableSongIDs: [String] {
        #if os(macOS)
        Array(songs.prefix(8).map(\.id))
        #else
        songs.map(\.id)
        #endif
    }

    private var artistServerMediaShareTarget: ServerMediaShareTarget? {
        guard let sourceID = songs.first?.sourceID,
              let source = sourcesStore.source(id: sourceID) else { return nil }
        return try? ServerMediaShareTargetPolicy.makeTarget(
            kind: .artist,
            title: displayArtistName,
            songs: songs,
            source: source
        )
    }

    #if os(macOS)
    private var macBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                macHero

                VStack(alignment: .leading, spacing: 24) {
                    if albums.isEmpty && songs.isEmpty {
                        EmptyStateView(
                            titleKey: "no_songs",
                            descriptionKey: "no_songs_desc",
                            systemImage: "music.mic"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    } else {
                        if !songs.isEmpty {
                            macTopSongs
                        }

                        if !albums.isEmpty {
                            macAlbums
                        }
                    }
                }
                .padding(.horizontal, PMSpace.xxxl)
                .padding(.top, PMSpace.l24)
            }
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
    }

    private var macHero: some View {
        MacLibraryHeader(
            eyebrow: "artist_label",
            title: displayArtistName,
            subtitle: "\(visibleSongCount) \(String(localized: "songs_count")) · \(albums.count) \(String(localized: "albums_count")) · \(monthlyListenText)",
            iconSystemName: "music.mic",
            coverArtist: artist,
            accent: Color(red: 0.78, green: 0.43, blue: 0.34),
            darkAccent: Color(red: 0.18, green: 0.13, blue: 0.20),
            onBack: onMacInlineBack.map { onBack in
                {
                    selection.deactivate()
                    onBack()
                }
            },
            backAccessibilityIdentifier: "artistInlineBack",
            onPlay: { playAll() },
            onShuffle: shuffleAll,
            moreMenu: artistMoreMenu
        )
    }

    private var artistMoreMenu: AnyView {
        var items: [MacHeaderMoreMenu.Item] = [
            .init(
                icon: "photo.badge.plus",
                title: String(localized: "artwork_edit")
            ) {
                showArtworkEditor = true
            },
        ]
        if let target = artistServerMediaShareTarget {
            items.append(.init(
                icon: "link.badge.plus",
                title: String(localized: "server_share_action")
            ) {
                serverMediaShareTarget = target
            })
        }
        return AnyView(MacHeaderMoreMenu(sections: [items]))
    }

    private var macTopSongs: some View {
        let playCounts = playCountsBySongID
        return VStack(alignment: .leading, spacing: 10) {
            macSectionTitle(String(localized: "artist_popular"))

            VStack(spacing: 1) {
                ForEach(Array(songs.prefix(8).enumerated()), id: \.element.id) { index, song in
                    macTopSongRow(song, index: index, playCount: playCounts[song.id, default: 0])
                        .songSelectable(
                            songID: song.id,
                            selection: selection,
                            orderedIDs: { selectableSongIDs },
                            defaultAction: { playSong(song) }
                        )
                }
            }
        }
    }

    private var macAlbums: some View {
        VStack(alignment: .leading, spacing: 12) {
            macSectionTitle(String(localized: "albums_section"))

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 18, alignment: .top), count: 4),
                alignment: .leading,
                spacing: 22
            ) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        macAlbumTile(album)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func macSectionTitle(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(PMColor.text)
    }

    private func macTopSongRow(_ song: Song, index: Int, playCount: Int) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        return Button { playSong(song) } label: {
            HStack(spacing: 12) {
                Text("\(index + 1)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(width: 24, alignment: .center)

                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 32,
                    cornerRadius: 4,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )

                Text(song.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                    .lineLimit(1)

                Spacer(minLength: 12)

                PMFormatPill.forFormat(song.fileFormat.displayName)
                    .frame(width: 70, alignment: .leading)

                Text(verbatim: String(
                    format: String(localized: "stats_play_count_format"),
                    playCount
                ))
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 54, alignment: .trailing)

                Text(song.duration.formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .pmRowBackground(selected: isCurrent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                selection.activate(seed: song.id)
            } label: {
                Label("batch_select", systemImage: "checkmark.circle")
            }
        }
    }

    private func macAlbumTile(_ album: Album) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(album: album, cornerRadius: PMRadius.s)
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.20), radius: 8, y: 4)

            Text(album.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            Text(album.year.map(String.init) ?? String(
                format: String(localized: "carplay_playlist_song_count_format"),
                library.songs(forAlbum: album.id).count
            ))
                .font(.system(size: 10.5))
                .foregroundStyle(PMColor.textFaint)
                .lineLimit(1)
        }
    }
    #endif

    private var detailContent: some View {
        VStack(spacing: 24) {
                #if os(macOS)
                macHeader
                #else
                iosHeader
                #endif

                if albums.isEmpty && songs.isEmpty {
                    ContentUnavailableView(
                        "no_songs",
                        systemImage: "music.mic",
                        description: Text("no_songs_desc")
                    )
                    .padding(.top, 24)
                }

                if songs.isEmpty == false {
                    MediaDetailActionBar(
                        canPlay: playableSongs.isEmpty == false,
                        canShuffle: playableSongs.count > 1,
                        playAction: { playAll() },
                        shuffleAction: shuffleAll
                    )
                    #if os(macOS)
                    .padding(.horizontal, 24)
                    #else
                    .padding(.bottom, 2)
                    #endif
                }

                // Albums
                if !albums.isEmpty {
                    VStack(alignment: .leading) {
                        Text("albums_section")
                            .font(.title3)
                            .fontWeight(.semibold)
                            #if os(macOS)
                            .padding(.horizontal, 24)
                            #else
                            .padding(.horizontal)
                            #endif

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(albums) { album in
                                NavigationLink(value: album) {
                                    AlbumCardView(album: album)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        #if os(macOS)
                        .padding(.horizontal, 24)
                        #else
                        .padding(.horizontal)
                        #endif
                    }
                }

                // All songs
                if !songs.isEmpty {
                    VStack(alignment: .leading) {
                        Text("all_songs_section")
                            .font(.title3)
                            .fontWeight(.semibold)
                            #if os(macOS)
                            .padding(.horizontal, 24)
                            #else
                            .padding(.horizontal)
                            #endif

                        LazyVStack(spacing: 0) {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                SongRowView(
                                    song: song,
                                    isPlaying: player.currentSong?.id == song.id,
                                    selection: selection,
                                    context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                                )
                                #if os(macOS)
                                .padding(.horizontal, 12)
                                #else
                                .padding(.horizontal)
                                #endif
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    playSong(song)
                                }
                                .songSelectable(
                                    songID: song.id,
                                    selection: selection,
                                    orderedIDs: { selectableSongIDs }
                                )

                                if index != songs.count - 1 {
                                    Divider()
                                    #if os(macOS)
                                        .padding(.leading, 68)
                                    #else
                                        .padding(.leading, 50)
                                    #endif
                                }
                            }
                        }
                        #if os(macOS)
                        .padding(.horizontal, 12)
                        .background(PMColor.bgElev, in: .rect(cornerRadius: 8))
                        .padding(.horizontal, 24)
                        #endif
                    }
                }
        }
    }

    #if os(macOS)
    private var macHeader: some View {
        HStack(alignment: .center, spacing: 20) {
            ArtistArtworkView(
                artist: artist,
                size: 140,
                cornerRadius: 70
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(displayArtistName)
                    .font(.title)
                    .fontWeight(.bold)
                    .lineLimit(2)

                Text("\(albums.count) \(String(localized: "albums_count")) · \(visibleSongCount) \(String(localized: "songs_count"))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
    }
    #endif

    private var iosHeader: some View {
        VStack(spacing: 8) {
            ArtistArtworkView(
                artist: artist,
                size: 120,
                cornerRadius: 60
            )

            Text(displayArtistName)
                .font(.title)
                .fontWeight(.bold)

            Text("\(albums.count) \(String(localized: "albums_count")) · \(visibleSongCount) \(String(localized: "songs_count"))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    private func playAll(shuffled: Bool = false) {
        let queue = shuffled ? playableSongs.shuffled() : playableSongs
        guard let first = queue.first else { return }
        if shuffled { player.shuffleEnabled = true }
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }

    private func shuffleAll() {
        playAll(shuffled: true)
    }

    private func playSong(_ song: Song) {
        let queue = playableSongs
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        SiriMediaInteractionDonor.donate(song: song)
        Task { await player.play(song: song) }
    }
}
