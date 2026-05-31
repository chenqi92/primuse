import SwiftUI
import PrimuseKit

struct ArtistDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    let artist: Artist

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

    private var monthlyListenCount: Int {
        let target = artist.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return 0 }
        return PlayHistoryStore.shared.entries(in: .month).filter {
            $0.artistName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == target
        }.count
    }

    private var monthlyListenText: String {
        "本月听 \(monthlyListenCount) 次"
    }

    private var playCountsBySongID: [String: Int] {
        Dictionary(grouping: PlayHistoryStore.shared.entries, by: \.songID)
            .mapValues(\.count)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 100), spacing: 12)
    ]

    var body: some View {
        #if os(macOS)
        macBody
        #else
        ScrollView {
            detailContent
        }
        .navigationBarTitleDisplayMode(.inline)
        #endif
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
                            macActionRow
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
        ZStack(alignment: .bottomLeading) {
            AmbientBackdrop(
                accent: Color(red: 0.78, green: 0.43, blue: 0.34),
                darkAccent: Color(red: 0.18, green: 0.13, blue: 0.20),
                strength: 0.82
            )

            HStack(alignment: .bottom, spacing: 22) {
                CachedArtworkView(
                    artistID: artist.id,
                    artistName: artist.name,
                    size: 138,
                    cornerRadius: 69
                )
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)

                VStack(alignment: .leading, spacing: 9) {
                    Text(verbatim: "艺术家")
                        .font(.system(size: 11, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.white.opacity(0.72))

                    Text(artist.name)
                        .font(.system(size: 56, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)

                    Text(verbatim: "\(visibleSongCount) \(String(localized: "songs_count")) · \(albums.count) \(String(localized: "albums_count")) · \(monthlyListenText)")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.74))
                }

                Spacer()
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
        }
        .frame(height: 260)
        .clipped()
    }

    private var macActionRow: some View {
        HStack(spacing: 8) {
            Button(action: playAll) {
                Label("play_all", systemImage: "play.fill")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 32)
                    .background(PMColor.brand, in: .rect(cornerRadius: 8))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(playableSongs.isEmpty)

            Button(action: shuffleAll) {
                Label("shuffle", systemImage: "shuffle")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(PMColor.cardBorder, lineWidth: 0.5) }
                    .foregroundStyle(PMColor.text)
            }
            .buttonStyle(.plain)
            .disabled(playableSongs.count < 2)

            Spacer()
        }
    }

    private var macTopSongs: some View {
        VStack(alignment: .leading, spacing: 10) {
            macSectionTitle("热门")

            VStack(spacing: 1) {
                ForEach(Array(songs.prefix(8).enumerated()), id: \.element.id) { index, song in
                    macTopSongRow(song, index: index)
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

    private func macTopSongRow(_ song: Song, index: Int) -> some View {
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
                    filePath: song.filePath
                )

                Text(song.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                    .lineLimit(1)

                Spacer(minLength: 12)

                PMFormatPill.forFormat(song.fileFormat.displayName)
                    .frame(width: 70, alignment: .leading)

                Text(verbatim: "\(playCountsBySongID[song.id, default: 0]) 次")
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
    }

    private func macAlbumTile(_ album: Album) -> some View {
        let song = library.songs(forAlbum: album.id).first
        return VStack(alignment: .leading, spacing: 8) {
            CachedArtworkView(
                coverRef: song?.coverArtFileName,
                songID: song?.id ?? "",
                cornerRadius: PMRadius.s,
                sourceID: song?.sourceID,
                filePath: song?.filePath
            )
            .aspectRatio(1, contentMode: .fit)
            .shadow(color: .black.opacity(0.20), radius: 8, y: 4)

            Text(album.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)
            Text(album.year.map(String.init) ?? "\(library.songs(forAlbum: album.id).count) \(String(localized: "songs_count"))")
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
                        playAction: playAll,
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
            CachedArtworkView(
                artistID: artist.id,
                artistName: artist.name,
                size: 140,
                cornerRadius: 70
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(artist.name)
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
            CachedArtworkView(artistID: artist.id, artistName: artist.name,
                              size: 120, cornerRadius: 60)

            Text(artist.name)
                .font(.title)
                .fontWeight(.bold)

            Text("\(albums.count) \(String(localized: "albums_count")) · \(visibleSongCount) \(String(localized: "songs_count"))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    private func playAll() {
        let queue = playableSongs
        guard let first = queue.first else { return }
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }

    private func shuffleAll() {
        player.shuffleEnabled = true
        playAll()
    }

    private func playSong(_ song: Song) {
        let queue = playableSongs
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        Task { await player.play(song: song) }
    }
}
