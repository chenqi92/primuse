import SwiftUI
import PrimuseKit

private struct ArtistListeningSnapshot {
    var monthlyListenCount = 0
    var playCountsBySongID: [String: Int] = [:]
    var playCountsByAlbumID: [String: Int] = [:]
}

struct ArtistDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.legacyBottomChromeOverlayActive)
    private var legacyBottomChromeOverlayActive
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(CoverTintProvider.self) private var coverTints
    @Environment(\.colorScheme) private var colorScheme
    #endif

    let artist: Artist
    private let onMacInlineBack: (() -> Void)?

    @State private var selection = SongSelectionModel()
    @State private var showArtworkEditor = false
    @State private var serverMediaShareTarget: ServerMediaShareTarget?
    @State private var listeningSnapshot = ArtistListeningSnapshot()

    init(artist: Artist, onMacInlineBack: (() -> Void)? = nil) {
        self.artist = artist
        self.onMacInlineBack = onMacInlineBack
    }

    private var songs: [Song] { library.songs(forArtist: artist.id) }
    private var playableSongs: [Song] { songs.filteredPlayable() }

    #if os(iOS)
    /// 整页底色取自艺术家头像 —— 跟头像视图回退到的是同一首歌。
    private var artworkTintSong: Song? {
        library.preferredArtworkSong(forArtistID: artist.id) ?? songs.first
    }

    private var tint: LibraryDetailTintStyle {
        .artwork(
            artworkTintSong.flatMap { coverTints.tint(forSongID: $0.id) },
            colorScheme: colorScheme
        )
    }
    #endif

    private var releaseAlbums: [Album] {
        library.visibleAlbums.filter(isPrimaryArtistAlbum).sorted(by: albumOrder)
    }

    private var appearsOnAlbums: [Album] {
        let songAlbumIDs = Set(songs.compactMap(\.albumID))
        return library.visibleAlbums
            .filter { songAlbumIDs.contains($0.id) && !isPrimaryArtistAlbum($0) }
            .sorted(by: albumOrder)
    }

    private var mostPlayedAlbums: [Album] {
        releaseAlbums
            .filter { listeningSnapshot.playCountsByAlbumID[$0.id, default: 0] > 0 }
            .sorted { lhs, rhs in
                let left = listeningSnapshot.playCountsByAlbumID[lhs.id, default: 0]
                let right = listeningSnapshot.playCountsByAlbumID[rhs.id, default: 0]
                if left != right { return left > right }
                return albumOrder(lhs, rhs)
            }
    }

    private var rankedSongs: [Song] {
        var originalIndex: [String: Int] = [:]
        for (index, song) in songs.enumerated() where originalIndex[song.id] == nil {
            originalIndex[song.id] = index
        }
        return songs.sorted { lhs, rhs in
            let lhsLocal = listeningSnapshot.playCountsBySongID[lhs.id, default: 0]
            let rhsLocal = listeningSnapshot.playCountsBySongID[rhs.id, default: 0]
            if lhsLocal != rhsLocal { return lhsLocal > rhsLocal }

            let lhsServer = lhs.serverPlayCount ?? 0
            let rhsServer = rhs.serverPlayCount ?? 0
            if lhsServer != rhsServer { return lhsServer > rhsServer }
            return originalIndex[lhs.id, default: .max] < originalIndex[rhs.id, default: .max]
        }
    }

    private var topSongs: [Song] {
        #if os(iOS)
        Array(rankedSongs.prefix(6))
        #else
        Array(rankedSongs.prefix(8))
        #endif
    }
    private var albumCount: Int { releaseAlbums.count + appearsOnAlbums.count }
    private var selectableSongIDs: [String] { topSongs.map(\.id) }

    private var displayArtistName: String {
        let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(localized: "unknown_artist") : name
    }

    private var monthlyListenText: String {
        String(
            format: String(localized: "artist_monthly_plays_format"),
            listeningSnapshot.monthlyListenCount
        )
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

    var body: some View {
        Group {
            #if os(macOS)
            macBody
            #else
            iosBody
            #endif
        }
        #if os(iOS)
        .libraryDetailTint(from: artworkTintSong)
        .minimalNavigationDetail()
        .librarySearchContext {
            LibrarySearchScope(title: displayArtistName, songIDs: Set(songs.map(\.id)), kind: .artist)
        }
        #endif
        .songBatchActions(
            selection: selection,
            orderedIDs: { selectableSongIDs },
            resolve: { library.song(id: $0) }
        )
        .onAppear(perform: refreshListeningSnapshot)
        .onChange(of: library.visibleSongCollectionRevision) { _, _ in
            refreshListeningSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseListeningStatsDidChange)) { _ in
            refreshListeningSnapshot()
        }
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
                Button { showArtworkEditor = true } label: {
                    Image(systemName: "photo.badge.plus")
                }
                .accessibilityLabel(Text("artwork_edit"))
            }
        }
        #endif
    }

    #if os(iOS)
    private var iosBody: some View {
        ImmersiveLibraryDetailScrollView { insets in
            iosHero(insets: insets)
        } content: {
            VStack(alignment: .leading, spacing: 30) {
                if songs.isEmpty && releaseAlbums.isEmpty {
                    EmptyStateView(
                        titleKey: "no_songs",
                        descriptionKey: "no_songs_desc",
                        systemImage: "music.mic"
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                } else {
                    if !topSongs.isEmpty { iosTopSongs }
                    if !mostPlayedAlbums.isEmpty {
                        iosAlbumShelf(
                            title: "artist_most_played_albums",
                            albums: Array(mostPlayedAlbums.prefix(6)),
                            showsPlayCount: true
                        )
                    }
                    if !releaseAlbums.isEmpty {
                        iosAlbumShelf(title: "artist_releases", albums: releaseAlbums)
                    }
                    if !appearsOnAlbums.isEmpty {
                        iosAlbumShelf(title: "artist_appears_on", albums: appearsOnAlbums)
                    }
                    if !songs.isEmpty {
                        allSongsLink.padding(.horizontal, 20)
                    }
                }
            }
            .padding(.top, 26)
            .padding(.bottom, BottomChromeClearancePolicy.clearance(
                legacyOverlayActive: legacyBottomChromeOverlayActive,
                legacy: 64,
                baseline: 16
            ))
        }
    }

    /// 手机横屏只剩三百多点高, 头像、块间距、上下留白都按竖屏标定过一遍,
    /// 紧凑高度下各降一档, 让 hero 压到 170pt 以内, 首屏才露得出热门单曲。
    private func iosHero(insets: ImmersiveLibraryDetailInsets) -> some View {
        let identityLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 18))
        let actionLayout = dynamicTypeSize >= .xxLarge
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        let avatarSide = heightClass.value(88, compact: 64)
        let blockSpacing = heightClass.value(20, compact: 12)
        let heroTopPadding = heightClass.value(12, compact: 8)
        let heroBottomPadding = heightClass.value(24, compact: 14)
        let nameFont = heightClass.pick(Font.title2, compact: .title3)
        let nameLineLimit: Int? = heightClass.isCompact ? 2 : nil

        return VStack(alignment: .leading, spacing: blockSpacing) {
            identityLayout {
                ArtistArtworkView(artist: artist, size: avatarSide, cornerRadius: avatarSide / 2)
                    .overlay { Circle().stroke(.white.opacity(0.28), lineWidth: 1) }
                    .shadow(color: .black.opacity(0.24), radius: 12, y: 4)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: displayArtistName)
                        .font(nameFont.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(nameLineLimit)
                        .minimumScaleFactor(heightClass.value(1, compact: 0.82))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(
                        verbatim:
                            "\(songs.count) \(String(localized: "songs_count")) · \(albumCount) \(String(localized: "albums_count"))"
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.78))

                    Text(verbatim: monthlyListenText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            actionLayout {
                LibraryDetailActionButton(
                    title: "play",
                    systemImage: "play.fill",
                    emphasized: true,
                    fillsWidth: true,
                    disabled: playableSongs.isEmpty,
                    action: playAll
                )
                LibraryDetailActionButton(
                    title: "shuffle",
                    systemImage: "shuffle",
                    fillsWidth: true,
                    disabled: playableSongs.count < 2,
                    action: shuffleAll
                )
            }
        }
        // 底图铺满整幅屏幕, 文字与按钮按侧留在安全区内 —— 横屏两侧安全区不一定相等。
        .padding(.leading, insets.leading + 20)
        .padding(.trailing, insets.trailing + 20)
        .padding(.top, insets.top + heroTopPadding)
        .padding(.bottom, heroBottomPadding)
        .frame(maxWidth: .infinity)
        .background {
            GeometryReader { geometry in
                ArtistArtworkView(
                    artist: artist,
                    size: max(geometry.size.width, geometry.size.height),
                    cornerRadius: 0
                )
                .blur(radius: 24)
                .scaleEffect(1.16)
                .opacity(0.78)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .background(tint.top)
            .accessibilityHidden(true)
            .overlay {
                // 头图往下化进整页底色, 而不是收在一块黑里 —— 页面接下去就是这个颜色,
                // 所以看不出头图在哪儿结束。
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.16), location: 0),
                        .init(color: tint.top.opacity(0.42), location: 0.5),
                        .init(color: tint.top, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .clipped()
    }

    private var iosTopSongs: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("artist_popular") {
                NavigationLink("see_all") { ArtistAllSongsView(artist: artist) }
                    .font(.subheadline.weight(.semibold))
            }

            LazyVStack(spacing: 0) {
                ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
                    SongRowView(
                        song: song,
                        isPlaying: player.currentSong?.id == song.id,
                        selection: selection,
                        context: SongRowView.context(
                            for: song,
                            sourcesStore: sourcesStore,
                            backfill: backfill
                        )
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                    .onTapGesture { playSong(song) }
                    .songSelectable(
                        songID: song.id,
                        selection: selection,
                        orderedIDs: { selectableSongIDs }
                    )

                    if index != topSongs.count - 1 {
                        Divider().padding(.leading, 66)
                    }
                }
            }
            .songRowColumnsContainer()
            .libraryDetailSection(tint: tint)
            .padding(.horizontal, 20)
        }
    }

    private func iosAlbumShelf(
        title: LocalizedStringKey,
        albums: [Album],
        showsPlayCount: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(albums) { album in
                        NavigationLink(value: album) {
                            albumShelfTile(album, showsPlayCount: showsPlayCount)
                        }
                        .buttonStyle(.plain)
                        .mediaZoomSource(.album, id: album.id)
                    }
                }
                .padding(.horizontal, 20)
            }
            .contentMargins(.horizontal, 0, for: .scrollContent)
        }
    }

    private func albumShelfTile(_ album: Album, showsPlayCount: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            AlbumArtworkView(album: album, cornerRadius: 14)
                .frame(width: 142, height: 142)
                .shadow(color: .black.opacity(0.16), radius: 9, y: 4)

            Text(verbatim: album.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            if showsPlayCount {
                Text(verbatim: String(
                    format: String(localized: "stats_play_count_format"),
                    listeningSnapshot.playCountsByAlbumID[album.id, default: 0]
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(verbatim: album.year.map(String.init) ?? "\(album.songCount) \(String(localized: "songs_count"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 142, alignment: .leading)
    }

    private func sectionHeader<Trailing: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 20)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        sectionHeader(title) { EmptyView() }
    }
    #endif

    #if os(macOS)
    private var macBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                macHero

                VStack(alignment: .leading, spacing: 28) {
                    if releaseAlbums.isEmpty && songs.isEmpty {
                        EmptyStateView(
                            titleKey: "no_songs",
                            descriptionKey: "no_songs_desc",
                            systemImage: "music.mic"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    } else {
                        if !topSongs.isEmpty { macTopSongs }
                        if !mostPlayedAlbums.isEmpty {
                            macAlbumSection(
                                title: String(localized: "artist_most_played_albums"),
                                albums: Array(mostPlayedAlbums.prefix(4)),
                                showsPlayCount: true
                            )
                        }
                        if !releaseAlbums.isEmpty {
                            macAlbumSection(
                                title: String(localized: "artist_releases"),
                                albums: releaseAlbums
                            )
                        }
                        if !appearsOnAlbums.isEmpty {
                            macAlbumSection(
                                title: String(localized: "artist_appears_on"),
                                albums: appearsOnAlbums
                            )
                        }
                        if !songs.isEmpty { allSongsLink }
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
            subtitle: "\(songs.count) \(String(localized: "songs_count")) · \(albumCount) \(String(localized: "albums_count")) · \(monthlyListenText)",
            iconSystemName: "music.mic",
            coverArtist: artist,
            accent: Color(red: 0.70, green: 0.32, blue: 0.42),
            darkAccent: Color(red: 0.14, green: 0.10, blue: 0.20),
            onBack: onMacInlineBack.map { onBack in
                {
                    selection.deactivate()
                    onBack()
                }
            },
            backAccessibilityIdentifier: "artistInlineBack",
            onPlay: playAll,
            onShuffle: shuffleAll,
            moreMenu: artistMoreMenu
        )
    }

    private var artistMoreMenu: AnyView {
        var items: [MacHeaderMoreMenu.Item] = [
            .init(icon: "photo.badge.plus", title: String(localized: "artwork_edit")) {
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
        VStack(alignment: .leading, spacing: 10) {
            macSectionTitle(String(localized: "artist_popular"))

            VStack(spacing: 1) {
                ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
                    macTopSongRow(
                        song,
                        index: index,
                        playCount: listeningSnapshot.playCountsBySongID[song.id, default: 0]
                    )
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

    private func macAlbumSection(
        title: String,
        albums: [Album],
        showsPlayCount: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            macSectionTitle(title)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: 18, alignment: .top)],
                alignment: .leading,
                spacing: 22
            ) {
                ForEach(albums) { album in
                    NavigationLink(value: album) {
                        macAlbumTile(album, showsPlayCount: showsPlayCount)
                    }
                    .buttonStyle(.plain)
                    .pmHoverLift()
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
                    .frame(width: 24)

                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 32,
                    cornerRadius: 4,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )

                Text(verbatim: song.title)
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

                Text(verbatim: song.duration.formattedDuration)
                    .font(.system(size: 11, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.textMuted)
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .pmRowBackground(selected: isCurrent)
            .contentShape(Rectangle())
            // 行底色自带 0.12 的高亮动画, 字色不跟上就会分两段到达。
            .pmAnimation(.hover, value: isCurrent)
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

    private func macAlbumTile(_ album: Album, showsPlayCount: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AlbumArtworkView(album: album, cornerRadius: PMRadius.s)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.20), radius: 8, y: 4)

            Text(verbatim: album.title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .lineLimit(1)

            Text(verbatim: showsPlayCount
                ? String(
                    format: String(localized: "stats_play_count_format"),
                    listeningSnapshot.playCountsByAlbumID[album.id, default: 0]
                )
                : album.year.map(String.init) ?? "\(album.songCount) \(String(localized: "songs_count"))"
            )
            .font(.system(size: 10.5))
            .foregroundStyle(PMColor.textFaint)
            .lineLimit(1)
        }
    }
    #endif

    private var allSongsLink: some View {
        NavigationLink {
            ArtistAllSongsView(artist: artist)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    #if os(iOS)
                    // 主题色跟着正在播放的歌走, 压在本页底色上容易撞色。
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    #else
                    .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 12))
                    #endif

                VStack(alignment: .leading, spacing: 3) {
                    Text("all_songs_section").font(.headline)
                    Text(verbatim: "\(songs.count) \(String(localized: "songs_count"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            #if os(iOS)
            .libraryDetailSection(tint: tint)
            #else
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.primary.opacity(0.07), lineWidth: 0.5)
            }
            #endif
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func isPrimaryArtistAlbum(_ album: Album) -> Bool {
        if album.artistID == artist.id { return true }
        guard let albumArtist = album.artistName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !albumArtist.isEmpty else { return false }
        return albumArtist.compare(
            displayArtistName,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        ) == .orderedSame
    }

    private func albumOrder(_ lhs: Album, _ rhs: Album) -> Bool {
        let lhsYear = lhs.year ?? Int.min
        let rhsYear = rhs.year ?? Int.min
        if lhsYear != rhsYear { return lhsYear > rhsYear }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func refreshListeningSnapshot() {
        let currentSongs = songs
        let relevantIDs = Set(currentSongs.map(\.id))
        guard !relevantIDs.isEmpty else {
            listeningSnapshot = ArtistListeningSnapshot()
            return
        }

        var songCounts: [String: Int] = [:]
        for entry in PlayHistoryStore.shared.entries where relevantIDs.contains(entry.songID) {
            songCounts[entry.songID, default: 0] += 1
        }

        let albumIDBySongID = Dictionary(
            currentSongs.compactMap { song in song.albumID.map { (song.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        var albumCounts: [String: Int] = [:]
        for (songID, count) in songCounts {
            guard let albumID = albumIDBySongID[songID] else { continue }
            albumCounts[albumID, default: 0] += count
        }

        let monthlyCount = PlayHistoryStore.shared.entries(in: .month)
            .lazy
            .filter { relevantIDs.contains($0.songID) }
            .count
        listeningSnapshot = ArtistListeningSnapshot(
            monthlyListenCount: monthlyCount,
            playCountsBySongID: songCounts,
            playCountsByAlbumID: albumCounts
        )
    }

    private func playAll() { playAll(shuffled: false) }

    private func playAll(shuffled: Bool) {
        let queue = shuffled ? playableSongs.shuffled() : playableSongs
        guard !queue.isEmpty else { return }
        if shuffled { player.shuffleEnabled = true }
        Task { await player.play(queue: queue, startingAt: 0) }
    }

    private func shuffleAll() { playAll(shuffled: true) }

    private func playSong(_ song: Song) {
        let queue = playableSongs
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        SiriMediaInteractionDonor.donate(song: song)
        Task { await player.play(queue: queue, startingAt: index) }
    }
}

private struct ArtistAllSongsView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill

    let artist: Artist
    @State private var selection = SongSelectionModel()

    private var songs: [Song] { library.songs(forArtist: artist.id) }
    private var playableSongs: [Song] { songs.filteredPlayable() }

    var body: some View {
        Group {
            if songs.isEmpty {
                EmptyStateView(
                    titleKey: "no_songs",
                    descriptionKey: "no_songs_desc",
                    systemImage: "music.note"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            SongRowView(
                                song: song,
                                isPlaying: player.currentSong?.id == song.id,
                                selection: selection,
                                context: SongRowView.context(
                                    for: song,
                                    sourcesStore: sourcesStore,
                                    backfill: backfill
                                )
                            )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .onTapGesture { playSong(song) }
                            .songSelectable(
                                songID: song.id,
                                selection: selection,
                                orderedIDs: { songs.map(\.id) }
                            )

                            if index != songs.count - 1 {
                                Divider().padding(.leading, 66)
                            }
                        }
                    }
                    #if os(macOS)
                    .background(PMColor.bgElev, in: RoundedRectangle(cornerRadius: 8))
                    .padding(24)
                    #endif
                }
            }
        }
        .navigationTitle("all_songs_section")
        .toolbarTitleDisplayMode(.inline)
        #if os(iOS)
        .minimalNavigationDetail()
        .librarySearchContext {
            let name = artist.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return LibrarySearchScope(
                title: name.isEmpty ? String(localized: "unknown_artist") : name,
                songIDs: Set(songs.map(\.id)),
                kind: .artist
            )
        }
        #endif
        .songBatchActions(
            selection: selection,
            orderedIDs: { songs.map(\.id) },
            resolve: { library.song(id: $0) }
        )
    }

    private func playSong(_ song: Song) {
        guard let index = playableSongs.firstIndex(where: { $0.id == song.id }) else { return }
        SiriMediaInteractionDonor.donate(song: song)
        Task { await player.play(queue: playableSongs, startingAt: index) }
    }
}
