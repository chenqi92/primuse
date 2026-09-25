import SwiftUI
import PrimuseKit

struct AlbumDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @Environment(\.skin) private var skin
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:「⋯」的内容并进系统溢出菜单。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    #if os(iOS)
    @Environment(\.legacyBottomChromeOverlayActive)
    private var legacyBottomChromeOverlayActive
    @Environment(CoverTintProvider.self) private var coverTints
    @Environment(\.colorScheme) private var colorScheme
    #endif
    let album: Album
    private let onMacInlineBack: (() -> Void)?

    @State private var showNoScraperSourceAlert = false
    @State private var showArtworkEditor = false
    @State private var serverMediaShareTarget: ServerMediaShareTarget?
    @State private var selection = SongSelectionModel()

    init(album: Album, onMacInlineBack: (() -> Void)? = nil) {
        self.album = album
        self.onMacInlineBack = onMacInlineBack
    }

    private var songs: [Song] {
        library.songs(forAlbum: album.id)
    }

    #if os(iOS)
    /// 整页底色取自这张专辑的封面 —— 跟封面视图挑的是同一首歌。
    private var artworkTintSong: Song? {
        library.preferredArtworkSong(forAlbumID: album.id) ?? songs.first
    }

    /// 两套基座的详情页默认铺封面色;样式声明了用自己的底色时不染。
    private var tint: LibraryDetailTintStyle? {
        guard skin.tintsCollectionPages else { return nil }
        return .artwork(
            artworkTintSong.flatMap { coverTints.tint(forSongID: $0.id) },
            colorScheme: colorScheme
        )
    }
    #endif

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
            LibrarySearchScope(
                title: album.title,
                songIDs: Set(songs.map(\.id)),
                kind: .album,
                detail: album.artistName
            )
        }
        #endif
        .songBatchActions(
            selection: selection,
            orderedIDs: { orderedSongIDs },
            resolve: { library.song(id: $0) }
        )
        .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
        .sheet(isPresented: $showArtworkEditor) {
            LibraryArtworkEditorSheet(
                owner: LibraryArtworkOwner(kind: .album, id: album.id),
                title: String(localized: "artwork_editor_title"),
                songs: songs
            )
        }
        .sheet(item: $serverMediaShareTarget) { target in
            ServerMediaShareSheet(target: target)
        }
    }

    /// 全选和"按看到的顺序入队"都要用列表实际渲染的顺序。
    private var orderedSongIDs: [String] {
        songs.map(\.id)
    }

    private struct DiscSection: Identifiable {
        let number: Int
        let songs: [Song]
        var id: Int { number }
        var title: String { "\(String(localized: "disc_label")) \(number)" }
    }

    private var discSections: [DiscSection] {
        // Group the canonical library order without reordering tracks in the UI.
        let grouped = Dictionary(grouping: songs, by: AlbumTrackOrder.discNumber(for:))
        return grouped.keys.sorted().map { DiscSection(number: $0, songs: grouped[$0] ?? []) }
    }

    private var albumServerMediaShareTarget: ServerMediaShareTarget? {
        guard let sourceID = songs.first?.sourceID,
              let source = sourcesStore.source(id: sourceID) else { return nil }
        return try? ServerMediaShareTargetPolicy.makeTarget(
            kind: .album,
            title: album.title,
            songs: songs,
            source: source
        )
    }

    #if os(iOS)
    /// 两套基座共用的专辑页:整页铺封面色,封面浮在上面,标题 / 艺术家 / 信息居中,
    /// 一排「随机 · 播放 · 下载」,下面是曲目、发行信息和同一艺术家的其他专辑。
    private var iosBody: some View {
        let discs = discSections
        let showsDiscHeaders = discs.contains { $0.number > 1 }
        return ImmersiveLibraryDetailScrollView(title: album.title) { insets in
            CollectionDetailHeader(model: headerModel, insets: insets)
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                trackList(discs: discs, showsDiscHeaders: showsDiscHeaders)
                albumFooter
                moreFromArtist
            }
            .padding(.bottom, BottomChromeClearancePolicy.clearance(
                legacyOverlayActive: legacyBottomChromeOverlayActive,
                legacy: 64,
                baseline: 16
            ))
        }
        .toolbar {
            if verticalBarEdge != nil {
                // 系统竖栏(iPhone Duo):分享留在栏里,「⋯」里的动作并进系统溢出菜单。
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let target = albumServerMediaShareTarget {
                        Button {
                            serverMediaShareTarget = target
                        } label: {
                            Label("server_share_action", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                if #available(iOS 27.0, *) {
                    ToolbarOverflowMenu {
                        Button {
                            showArtworkEditor = true
                        } label: {
                            Label("artwork_edit", systemImage: "photo.badge.plus")
                        }
                    }
                }
            } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let target = albumServerMediaShareTarget {
                    Button {
                        serverMediaShareTarget = target
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(Text("server_share_action"))
                }
                Menu {
                    Button {
                        showArtworkEditor = true
                    } label: {
                        Label("artwork_edit", systemImage: "photo.badge.plus")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel(Text("a11y_more_actions"))
            }
            }
        }
    }

    /// 头图与操作行的数据:封面、标题、可点进艺术家页的艺术家名、流派 · 年份 · 格式,
    /// 「随机 · 播放 · 下载」与评分。画法交给 `CollectionDetailHeader`。
    private var headerModel: CollectionDetailHeaderModel {
        let playable = songs.filteredPlayable()
        let artist = album.artistID.flatMap { library.visibleArtist(id: $0) }
        return CollectionDetailHeaderModel(
            title: album.title,
            subtitle: .init(
                text: album.artistName ?? String(localized: "unknown_artist"),
                destination: artist
            ),
            meta: CollectionDetailHeaderPolicy.albumMeta(
                genre: album.genre,
                year: album.year,
                formats: Set(songs.map { $0.fileFormat.rawValue.uppercased() })
            ),
            artwork: .album(album),
            actions: .init(
                shuffle: .init(isEnabled: playable.count >= 2, perform: shuffleAll),
                play: .init(isEnabled: !playable.isEmpty, perform: { playAll() }),
                playTitle: "play",
                trailing: .download(.init(isEnabled: !playable.isEmpty) {
                    sourceManager.downloadForOffline(songs: songs)
                })
            ),
            review: .album(album.id)
        )
    }

    private func trackList(discs: [DiscSection], showsDiscHeaders: Bool) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(discs) { disc in
                if showsDiscHeaders {
                    Text(verbatim: disc.title)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 22)
                        .padding(.bottom, 6)
                        .accessibilityAddTraits(.isHeader)
                }

                ForEach(Array(disc.songs.enumerated()), id: \.element.id) { index, song in
                    if index == 0 { trackSeparator(leading: 20) }
                    SongRowView(
                        song: song,
                        isPlaying: player.currentSong?.id == song.id,
                        showAlbum: false,
                        selection: selection,
                        leading: .trackNumber(song.trackNumber),
                        hidesArtist: library.artistDisplayName(for: song) == album.artistName,
                        context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                    )
                    .padding(.leading, 14)
                    .padding(.trailing, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        playSong(song)
                    }
                    .songSelectable(
                        songID: song.id,
                        selection: selection,
                        orderedIDs: { orderedSongIDs }
                    )
                    trackSeparator(leading: index < disc.songs.count - 1 ? 52 : 20)
                }
            }
        }
        // 专辑详情页的行都在同一张专辑里, 宽行不必再补一列专辑名。
        .songRowColumnsContainer(showsAlbum: false)
    }

    private func trackSeparator(leading: CGFloat) -> some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(height: 0.5)
            .padding(.leading, leading)
            .padding(.trailing, 20)
    }

    /// 发行日期、曲目数与总时长、来源与音质 —— 专辑页页尾那几行小字。
    private var albumFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let year = album.year {
                Text(verbatim: String(year))
            }
            Text(verbatim: "\(album.songCount) \(String(localized: "songs_count")) \u{00B7} \(formatDuration(album.totalDuration))")
            if let source = songs.first.flatMap({ sourcesStore.source(id: $0.sourceID) }) {
                Text(verbatim: source.name)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    /// 同一艺术家的其他专辑。只有一张的艺术家整块不出现。
    @ViewBuilder
    private var moreFromArtist: some View {
        let others = otherAlbumsByArtist
        if !others.isEmpty, let name = album.artistName {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: String(format: String(localized: "album_more_from_artist_format"), name))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .accessibilityAddTraits(.isHeader)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(others) { other in
                            NavigationLink {
                                AlbumDetailView(album: other)
                                    .mediaZoomDestination(.album, id: other.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    AlbumArtworkView(album: other, cornerRadius: 12)
                                        .frame(width: 150, height: 150)
                                    Text(verbatim: other.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    if let year = other.year {
                                        Text(verbatim: String(year))
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.66))
                                    }
                                }
                                .frame(width: 150, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .mediaZoomSource(.album, id: other.id)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .pmStopsAtVerticalBar()
            }
            .padding(.top, 32)
        }
    }

    private var otherAlbumsByArtist: [Album] {
        guard let artistID = album.artistID else { return [] }
        return library.visibleAlbums
            .filter { $0.artistID == artistID && $0.id != album.id }
            .prefix(12)
            .map { $0 }
    }
    #endif

    #if os(macOS)
    private var macBody: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                MacLibraryHeader(
                    eyebrow: "album_label",
                    title: album.title,
                    subtitle: albumSubtitle,
                    iconSystemName: "square.stack.fill",
                    coverAlbum: album,
                    onBack: onMacInlineBack.map { onBack in
                        {
                            selection.deactivate()
                            onBack()
                        }
                    },
                    backAccessibilityIdentifier: "albumInlineBack",
                    onPlay: { playAll() },
                    onShuffle: shuffleAll,
                    moreMenu: albumMoreMenu
                )

                VStack(alignment: .leading, spacing: PMSpace.l) {
                    albumInfoCard
                    LibraryReviewSection(subject: .album(album.id))
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
            .init(icon: "photo.badge.plus", title: String(localized: "artwork_edit")) {
                showArtworkEditor = true
            },
            .init(icon: "arrow.down.circle", title: String(localized: "offline_download"), enabled: !playable.isEmpty) {
                sourceManager.downloadForOffline(songs: songs)
            },
            .init(icon: "wand.and.stars", title: String(localized: "scrape_missing_metadata"),
                  trailing: songs.count.formatted(),
                  enabled: !songs.isEmpty && !scraperService.isScraping) {
                guard scraperSettings.hasEnabledSource else {
                    showNoScraperSourceAlert = true
                    return
                }
                scraperService.scrapeMissingMetadata(songs: songs, in: library)
            },
        ]
        if let artist = albumArtist {
            second.append(.init(icon: "music.mic", title: String(localized: "go_to_artist")) {
                NotificationCenter.default.post(name: .primuseDetailOpenArtist, object: artist)
            })
        }
        if let target = albumServerMediaShareTarget {
            second.append(.init(
                icon: "link.badge.plus",
                title: String(localized: "server_share_action")
            ) {
                serverMediaShareTarget = target
            })
        }

        return AnyView(MacHeaderMoreMenu(sections: [
            [
                .init(icon: "checkmark.circle",
                      title: selection.isActive
                          ? String(localized: "done")
                          : String(localized: "batch_select"),
                      enabled: !songs.isEmpty) {
                    if selection.isActive {
                        selection.deactivate()
                    } else {
                        selection.activate()
                    }
                },
            ],
            [
                .init(icon: "play.fill", title: String(localized: "play_all"), enabled: !playable.isEmpty) { playAll() },
                .init(icon: "shuffle", title: String(localized: "shuffle"), enabled: !playable.isEmpty, action: shuffleAll),
                .init(icon: "text.line.last.and.arrowtriangle.forward", title: String(localized: "add_to_queue"),
                      enabled: !playable.isEmpty) { player.appendToQueue(playable) },
                .init(icon: "text.line.first.and.arrowtriangle.forward", title: String(localized: "insert_next"),
                      enabled: !playable.isEmpty) { player.insertNextInQueue(playable) },
            ],
            second,
        ]))
    }

    private var albumArtist: Artist? {
        library.visibleArtists.first { $0.id == album.artistID || $0.name == album.artistName }
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
        let discs = discSections
        let showsDiscHeaders = discs.contains { $0.number > 1 }
        return VStack(spacing: 0) {
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
                ForEach(discs) { disc in
                    if showsDiscHeaders {
                        macDiscHeader(disc, isFirst: disc.id == discs.first?.id)
                    }

                    ForEach(Array(disc.songs.enumerated()), id: \.element.id) { index, song in
                        macTrackRow(song, index: index)
                            .songSelectable(
                                songID: song.id,
                                selection: selection,
                                orderedIDs: { orderedSongIDs },
                                defaultAction: { playSong(song) }
                            )
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func macDiscHeader(_ disc: DiscSection, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isFirst {
                Rectangle().fill(PMColor.divider).frame(height: 0.5)
                    .padding(.top, PMSpace.m)
            }
            Text(verbatim: disc.title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(PMColor.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PMSpace.s8)
                .padding(.top, PMSpace.m)
                .padding(.bottom, PMSpace.s8)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func macTrackRow(_ song: Song, index: Int) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        let trackNumber = song.trackNumber.flatMap { $0 > 0 ? $0 : nil } ?? index + 1
        return Button { playSong(song) } label: {
            HStack(spacing: PMSpace.s10) {
                ZStack {
                    if isCurrent {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                            .pmFadeTransition()
                    } else {
                        Text("\(trackNumber)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                            .pmFadeTransition()
                    }
                }
                .frame(width: 28, alignment: .center)

                CachedArtworkView(
                    coverRef: song.coverArtFileName, songID: song.id,
                    size: 32, cornerRadius: PMRadius.xs,
                    sourceID: song.sourceID, filePath: song.filePath,
                    fileFormat: song.fileFormat
                )

                Text(song.title)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(library.artistDisplayName(for: song) ?? "—")
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
            // 行底色自带 0.12 的高亮动画, 序号与字色不跟上就会分两段到达。
            .pmAnimation(.hover, value: isCurrent)
        }
        .buttonStyle(.plain)
    }
    #endif

    private func playAll(shuffled: Bool = false) {
        let playable = songs.filteredPlayable()
        let queue = shuffled ? playable.shuffled() : playable
        guard !queue.isEmpty else { return }
        if shuffled { player.shuffleEnabled = true }
        Task { await player.play(queue: queue, startingAt: 0) }
    }

    private func shuffleAll() {
        playAll(shuffled: true)
    }

    private func playSong(_ song: Song) {
        let queue = songs.filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        SiriMediaInteractionDonor.donate(song: song)
        Task { await player.play(queue: queue, startingAt: index) }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        duration.formattedShort
    }
}
