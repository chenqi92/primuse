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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.skin) private var skin
    #if os(iOS)
    @Environment(\.legacyBottomChromeOverlayActive)
    private var legacyBottomChromeOverlayActive
    @Environment(\.pmHeightClass) private var heightClass
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

    /// 自己画页面底色的皮肤下为 nil —— 页面用皮肤的底色，不再叠封面色。
    private var tint: LibraryDetailTintStyle? {
        guard !skin.paintsPageBackground else { return nil }
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
    private var iosBody: some View {
        let discs = discSections
        let showsDiscHeaders = discs.contains { $0.number > 1 }
        return Group {
            // 头部怎么画由界面皮肤决定;曲目列表、按钮、评分两种画法共用一份。
            switch skin.skin.detailHeader {
            case .coverWall:
                ScrollView {
                    VStack(spacing: 20) {
                        coverWallHeader
                        trackList(discs: discs, showsDiscHeaders: showsDiscHeaders)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, BottomChromeClearancePolicy.clearance(
                        legacyOverlayActive: legacyBottomChromeOverlayActive,
                        legacy: 64,
                        baseline: 16
                    ))
                }
                .skinPageBackground(replacing: .canvas)
                .navigationBarTitleDisplayMode(.inline)
            case .classic:
                ImmersiveLibraryDetailScrollView { insets in
                    iosHero(insets: insets)
                } content: {
                    trackList(discs: discs, showsDiscHeaders: showsDiscHeaders)
                        .padding(.horizontal, 16)
                        .padding(.top, 18)
                        .padding(.bottom, BottomChromeClearancePolicy.clearance(
                            legacyOverlayActive: legacyBottomChromeOverlayActive,
                            legacy: 64,
                            baseline: 16
                        ))
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    sourceManager.downloadForOffline(songs: songs)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .disabled(songs.filteredPlayable().isEmpty)
                .accessibilityLabel(Text("offline_download"))
                if let target = albumServerMediaShareTarget {
                    Button {
                        serverMediaShareTarget = target
                    } label: {
                        Image(systemName: "link.badge.plus")
                    }
                    .accessibilityLabel(Text("server_share_action"))
                }
                Button {
                    showArtworkEditor = true
                } label: {
                    Image(systemName: "photo.badge.plus")
                }
                .accessibilityLabel(Text("artwork_edit"))
            }
        }
    }

    /// 封面墙皮肤的单封面头图。手机横屏下降一档:封面 180 → 116、块间距 18 → 12,
    /// 头图连同按钮压到 200pt 以内。
    private var coverWallHeader: some View {
        let heroCoverSide = heightClass.value(180, compact: 116)
        let heroSpacing = heightClass.value(18, compact: 12)
        return VStack(spacing: heroSpacing) {
            CollectionSingleCoverHeader(
                title: album.title,
                subtitle: album.artistName ?? String(localized: "unknown_artist"),
                caption: heroMetaLine
            ) {
                AlbumArtworkView(
                    album: album,
                    size: heroCoverSide,
                    cornerRadius: 20,
                    presentationRole: .animatedHero
                )
            } backdrop: {
                AlbumArtworkView(album: album, size: 320, cornerRadius: 0, showsPlaceholder: false)
            }
            albumActionRow(onArtwork: false)
            LibraryReviewSection(subject: .album(album.id), compact: true)
        }
    }

    /// - Parameter onArtwork: 按钮是不是压在封面色上;封面墙头图下按钮在皮肤底色上。
    private func albumActionRow(onArtwork: Bool) -> some View {
        let actionLayout = dynamicTypeSize >= .xxLarge
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))

        return actionLayout {
            LibraryDetailActionButton(
                title: "play",
                systemImage: "play.fill",
                emphasized: true,
                onArtwork: onArtwork,
                fillsWidth: true,
                disabled: songs.filteredPlayable().isEmpty,
                action: { playAll() }
            )
            LibraryDetailActionButton(
                title: "shuffle",
                systemImage: "shuffle",
                onArtwork: onArtwork,
                fillsWidth: true,
                disabled: songs.filteredPlayable().count < 2,
                action: shuffleAll
            )
        }
    }

    /// 头图改成「封面浮在整页底色上」: 封面居中, 标题、信息、按钮顺着往下, 页面其余
    /// 部分继续用同一条渐变 —— 原来那种卡片贴在系统灰底上的接缝没有了。
    ///
    /// 手机横屏只剩三百多点高, 封面、间距、留白各降一档并改成封面在左的一行,
    /// 头图压到 190pt 以内, 首屏才露得出歌。
    private func iosHero(insets: ImmersiveLibraryDetailInsets) -> some View {
        let compact = heightClass.isCompact
        // 无障碍字号下横排放不下, 一律回到竖排居中。
        let stacksIdentity = !compact || dynamicTypeSize.isAccessibilitySize
        let coverSide: CGFloat = compact ? 88 : 190
        let heroTopPadding: CGFloat = compact ? 18 : 52
        let heroBottomPadding: CGFloat = compact ? 16 : 26
        let blockSpacing: CGFloat = compact ? 14 : 18

        return VStack(alignment: stacksIdentity ? .center : .leading, spacing: blockSpacing) {
            if stacksIdentity {
                VStack(spacing: 14) {
                    heroCover(side: coverSide)
                    heroIdentityText(centered: true)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .center, spacing: 16) {
                    heroCover(side: coverSide)
                    heroIdentityText(centered: false)
                }
            }

            albumActionRow(onArtwork: true)

            LibraryReviewSection(subject: .album(album.id), compact: true, onArtwork: true)
        }
        // 底色铺满整幅屏幕, 文字与按钮按侧留在安全区内 —— 横屏两侧安全区不一定相等。
        .padding(.leading, insets.leading + 20)
        .padding(.trailing, insets.trailing + 20)
        .padding(.top, insets.top + heroTopPadding)
        .padding(.bottom, heroBottomPadding)
        .frame(maxWidth: .infinity)
    }

    private func heroCover(side: CGFloat) -> some View {
        AlbumArtworkView(
            album: album,
            size: side,
            cornerRadius: side > 140 ? 14 : 10,
            presentationRole: .animatedHero
        )
        .shadow(color: .black.opacity(0.34), radius: 18, y: 10)
        .accessibilityHidden(true)
    }

    private func heroIdentityText(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 6) {
            Text(album.title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(heightClass.isCompact ? 2 : 3)
                .fixedSize(horizontal: false, vertical: true)

            Text(album.artistName ?? String(localized: "unknown_artist"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: heroMetaLine)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.62))
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private var heroMetaLine: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append("\(album.songCount) \(String(localized: "songs_count"))")
        parts.append(formatDuration(album.totalDuration))
        return parts.joined(separator: " \u{00B7} ")
    }

    private func trackList(discs: [DiscSection], showsDiscHeaders: Bool) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(discs) { disc in
                if showsDiscHeaders {
                    Text(verbatim: disc.title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.top, 20)
                        .padding(.bottom, 8)
                        .accessibilityAddTraits(.isHeader)
                }

                ForEach(Array(disc.songs.enumerated()), id: \.element.id) { index, song in
                    SongRowView(
                        song: song,
                        isPlaying: player.currentSong?.id == song.id,
                        showAlbum: false,
                        selection: selection,
                        context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        playSong(song)
                    }
                    .songSelectable(
                        songID: song.id,
                        selection: selection,
                        orderedIDs: { orderedSongIDs }
                    )

                    if index < disc.songs.count - 1 {
                        Divider().padding(.leading, 66)
                    }
                }
            }
        }
        // 专辑详情页的行都在同一张专辑里, 宽行不必再补一列专辑名。
        .songRowColumnsContainer(showsAlbum: false)
        .libraryDetailSection(tint: tint, cornerRadius: 20)
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
