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
    #if os(iOS)
    @Environment(\.legacyBottomChromeOverlayActive)
    private var legacyBottomChromeOverlayActive
    @Environment(\.pmHeightClass) private var heightClass
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:工具栏按钮带上标题,收进系统溢出菜单时看得懂。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @Environment(CoverTintProvider.self) private var coverTints
    @Environment(\.colorScheme) private var colorScheme
    #elseif os(macOS)
    @Environment(\.locale) private var locale
    #endif
    let album: Album
    private let onMacInlineBack: (() -> Void)?

    @State private var showNoScraperSourceAlert = false
    @State private var showArtworkEditor = false
    @State private var showsRestoreFileTagsConfirmation = false
    @State private var serverMediaShareTarget: ServerMediaShareTarget?
    @State private var selection = SongSelectionModel()

    init(album: Album, onMacInlineBack: (() -> Void)? = nil) {
        self.album = album
        self.onMacInlineBack = onMacInlineBack
    }

    private var songs: [Song] {
        library.songs(forAlbum: album.id)
    }

    /// 这张专辑里有手动编辑或刮削改过、不再跟随文件标签的歌。
    private var hasUserEditedSongs: Bool {
        songs.contains { $0.userMetadataEditedAt != nil }
    }

    private func restoreFileTags() {
        let songIDs = songs.map(\.id)
        plog("🔁 restore file tags album=\(album.id.prefix(12)) songs=\(songIDs.count)")
        Task { await backfill.restoreFileTags(songIDs: songIDs) }
    }

    #if os(iOS)
    /// 整页底色取自这张专辑的封面 —— 跟封面视图挑的是同一首歌。
    private var artworkTintSong: Song? {
        library.preferredArtworkSong(forAlbumID: album.id) ?? songs.first
    }

    private var tint: LibraryDetailTintStyle {
        .artwork(
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
        // 平时挂在工具栏的「⋯」上（见 iosBody）；系统竖栏的溢出菜单和 Mac 头部菜单
        // 没有本页的视图可挂，才由整页弹。
        .confirmationDialog(
            Text("restore_file_tags"),
            isPresented: Binding(
                get: { !moreMenuHostsDialogs && showsRestoreFileTagsConfirmation },
                set: { showsRestoreFileTagsConfirmation = $0 }
            ),
            titleVisibility: .visible
        ) {
            restoreFileTagsActions
        } message: {
            Text("restore_file_tags_message")
        }
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

    /// 工具栏里有自己的「⋯」时(普通 iPhone/iPad)确认框挂在它上面;
    /// 系统竖栏(iPhone Duo)把菜单收进系统溢出菜单、Mac 用头部菜单，这两种退回整页。
    private var moreMenuHostsDialogs: Bool {
        #if os(iOS)
        verticalBarEdge == nil
        #else
        false
        #endif
    }

    @ViewBuilder
    private var restoreFileTagsActions: some View {
        Button("restore_file_tags_confirm", role: .destructive, action: restoreFileTags)
        Button("cancel", role: .cancel) {}
    }

    /// 「关于这张专辑」的身份:只看专辑名和专辑艺人。
    private var insightIdentity: LibraryInsightSubject {
        .album(title: album.title, artist: insightArtistName, year: album.year, genres: [], tracks: [])
    }

    private var insightArtistName: String {
        let name = album.artistName ?? ""
        return name == String(localized: "unknown_artist") ? "" : name
    }

    /// 点「生成」时才收集:按碟号与曲序排好的曲名和最常见的风格。
    private func insightDetails() -> LibraryInsightSubject {
        let ordered = discSections.flatMap(\.songs)
        return .album(
            title: album.title,
            artist: insightArtistName,
            year: album.year,
            genres: LibraryInsightSubject.topGenres(ordered.map(\.genre)),
            tracks: ordered.map(\.title)
        )
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

    private var albumFavorite: LibraryDetailFavoriteToggle {
        let favorites = LibraryFavoritesStore.shared
        let album = album
        return LibraryDetailFavoriteToggle(isLiked: favorites.isLiked(album)) {
            favorites.toggle(album)
        }
    }

    #if os(iOS)
    private var iosBody: some View {
        let discs = discSections
        let showsDiscHeaders = discs.contains { $0.number > 1 }
        return ImmersiveLibraryDetailScrollView { insets in
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
        .toolbar {
            if verticalBarEdge != nil {
                // 系统竖栏(iPhone Duo):「⋯」里的动作并进系统溢出菜单。
                if #available(iOS 27.0, *) {
                    ToolbarOverflowMenu {
                        albumMoreMenuContent
                    }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        albumMoreMenuContent
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel(Text("a11y_more_actions"))
                    .accessibilityIdentifier("albumDetail.more")
                    // 菜单里「恢复文件标签」的确认框挂在这颗「⋯」上，从按钮长出来。
                    .confirmationDialog(
                        Text("restore_file_tags"),
                        isPresented: $showsRestoreFileTagsConfirmation,
                        titleVisibility: .visible
                    ) {
                        restoreFileTagsActions
                    } message: {
                        Text("restore_file_tags_message")
                    }
                }
            }
        }
    }

    /// 专辑页右上角「⋯」：顶上一行是接下来播放、加入队列、离线下载，下面是这张专辑本身的整理。
    /// 收藏在头图那一行的心上，播放与随机也在那里。
    @ViewBuilder
    private var albumMoreMenuContent: some View {
        let playable = songs.filteredPlayable()
        PMMenuQuickActions {
            PMMenuQuickActionButton(
                shortKey: "insert_next_short",
                fullKey: "insert_next",
                systemImage: "text.line.first.and.arrowtriangle.forward"
            ) {
                _ = player.insertNextInQueue(playable)
            }
            .disabled(playable.isEmpty)

            PMMenuQuickActionButton(
                shortKey: "add_to_queue_short",
                fullKey: "add_to_queue",
                systemImage: "text.line.last.and.arrowtriangle.forward"
            ) {
                player.appendToQueue(playable)
            }
            .disabled(playable.isEmpty)

            PMMenuQuickActionButton(
                shortKey: "offline_download",
                fullKey: "offline_download",
                systemImage: "arrow.down.circle"
            ) {
                sourceManager.downloadForOffline(songs: songs)
            }
            .disabled(playable.isEmpty)
        }

        Section {
            if let target = albumServerMediaShareTarget {
                Button {
                    serverMediaShareTarget = target
                } label: {
                    Label("server_share_action", systemImage: "link.badge.plus")
                }
            }
            Button {
                showArtworkEditor = true
            } label: {
                Label("artwork_edit", systemImage: "photo.badge.plus")
            }
            // 只在有改过的歌时出现。
            if hasUserEditedSongs {
                Button {
                    showsRestoreFileTagsConfirmation = true
                } label: {
                    Label("restore_file_tags", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    /// 头图改成「封面浮在整页底色上」: 封面居中, 标题、信息、按钮顺着往下, 页面其余
    /// 部分继续用同一条渐变 —— 原来那种卡片贴在系统灰底上的接缝没有了。
    ///
    /// 手机横屏只剩三百多点高, 封面、间距、留白各降一档并改成封面在左的一行,
    /// 头图压到 190pt 以内, 首屏才露得出歌。
    ///
    /// 简介照影片介绍页的位置放在播放键下面: 风格、几行摘录, 点「更多」就地展开全文。
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

            LibraryDetailPlayShuffleRow(
                playDisabled: songs.filteredPlayable().isEmpty,
                shuffleDisabled: songs.filteredPlayable().count < 2,
                play: { playAll() },
                shuffle: shuffleAll,
                favorite: albumFavorite
            )

            LibraryInsightSynopsis(
                subject: insightIdentity,
                details: insightDetails,
                songs: { songs },
                compact: compact
            )

            LibraryReviewSection(subject: .album(album.id), compact: true, onArtwork: true)
        }
        // 底色铺满整幅屏幕, 文字与按钮按侧留在安全区内 —— 横屏两侧安全区不一定相等。
        .padding(.leading, insets.leading + 20)
        .padding(.trailing, insets.trailing + 20)
        .padding(.top, insets.top + heroTopPadding)
        .padding(.bottom, heroBottomPadding)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            heroBackdrop(
                coverSide: coverSide,
                // 竖排时封面居中; 横排(手机横屏)时封面贴在左侧安全区里。
                coverCenterX: stacksIdentity ? nil : insets.leading + 20 + coverSide / 2,
                coverCenterY: insets.top + heroTopPadding + coverSide / 2,
                topInset: insets.top
            )
        }
    }

    /// 头图背后那层封面氛围:把这张封面放大、轻度虚化,以封面为中心铺满头图上半截,再往下化进整页底色。
    ///
    /// 整页底色只取了封面主色一种颜色,平铺开来很素;这一层让封面里的画面往四周延伸出去 ——
    /// 上半屏是这张专辑自己的画面,跟艺人页的人像海报一个分量。
    /// 每个通道都乘一个上限再铺:浅色封面放大开是一片白,不压住的话标题和返回键都读不清。
    /// 上限 0.5 时纯白封面也只压到 4:1;渐隐从封面下沿就开始,艺人名那一行已经掺进整页底色。
    private func heroBackdrop(
        coverSide: CGFloat,
        coverCenterX: CGFloat?,
        coverCenterY: CGFloat,
        topInset: CGFloat
    ) -> some View {
        let coverBottom = coverCenterY + coverSide / 2
        return GeometryReader { geometry in
            let width = geometry.size.width
            let height = max(geometry.size.height, 1)
            // 渐隐收在头图里面:手机横屏头图很矮,收不完就在头图下沿留一道硬边。
            let fadeEnd = min(coverBottom + 280, height)
            let fadeStart = min(coverBottom + 10, fadeEnd * 0.6)
            // 放大后的边缘落在屏幕外: 虚化会把边缘化成透明, 留在屏幕里就是一圈暗边。
            let side = max(width, coverBottom + 60) * 1.3
            // 按封面那么大取图(跟头图共用一份解码),放大交给图层。
            AlbumArtworkView(
                album: album,
                size: coverSide,
                cornerRadius: 0,
                showsPlaceholder: false
            )
            .scaleEffect(side / coverSide)
            .blur(radius: 20)
            .saturation(1.25)
            .colorMultiply(Color(white: 0.5))
            .position(x: coverCenterX ?? width / 2, y: coverCenterY)
            .frame(width: width, height: height)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: fadeStart / height),
                        .init(color: .black.opacity(0.32), location: (fadeStart + fadeEnd) / 2 / height),
                        .init(color: .clear, location: fadeEnd / height),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .top) {
                // 顶部压一点暗, 返回键和工具栏读得清。
                LinearGradient(
                    colors: [.black.opacity(0.18), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: topInset + 64)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
                .shadow(color: .black.opacity(0.22), radius: 12, y: 2)

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
                    moreMenu: albumMoreMenu,
                    favorite: albumFavorite,
                    synopsis: AnyView(LibraryInsightSynopsis(
                        subject: insightIdentity,
                        details: insightDetails,
                        songs: { songs }
                    )),
                    artworkBackdrop: true
                )

                VStack(alignment: .leading, spacing: PMSpace.l) {
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

    private func scrapeAlbum(parts: ScrapeParts) {
        guard scraperSettings.hasEnabledSource else {
            showNoScraperSourceAlert = true
            return
        }
        scraperService.scrapeMissingMetadata(songs: songs, in: library, parts: parts)
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
                scrapeAlbum(parts: .all)
            },
            .init(icon: "text.quote", title: String(localized: "scrape_parts_lyrics_only"),
                  enabled: !songs.isEmpty && !scraperService.isScraping) {
                scrapeAlbum(parts: .lyrics)
            },
            .init(icon: "photo", title: String(localized: "scrape_parts_cover_only"),
                  enabled: !songs.isEmpty && !scraperService.isScraping) {
                scrapeAlbum(parts: .cover)
            },
            .init(icon: "arrow.uturn.backward", title: String(localized: "restore_file_tags"),
                  enabled: hasUserEditedSongs) {
                showsRestoreFileTagsConfirmation = true
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

    /// 专辑艺人对应的艺人页。「群星」这类只当过专辑艺人的人只在「专辑艺术家」列表里有。
    private var albumArtist: Artist? {
        if let id = album.artistID,
           let artist = library.visibleArtist(id: id) ?? library.visibleAlbumArtist(id: id) {
            return artist
        }
        return library.visibleArtists.first { $0.name == album.artistName }
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
        let largestTrackNumber = max(
            discs.map { $0.songs.count }.max() ?? 1,
            discs.flatMap(\.songs).compactMap(\.trackNumber).filter { $0 > 0 }.max() ?? 1
        )
        let ordinalWidth = MacOrdinalColumn.width(
            for: largestTrackNumber, minimum: 28, fontSize: 11, locale: locale
        )
        return VStack(spacing: 0) {
            HStack(spacing: PMSpace.s10) {
                Text("#").frame(width: ordinalWidth, alignment: .center)
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
                        macTrackRow(song, index: index, ordinalWidth: ordinalWidth)
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

    private func macTrackRow(_ song: Song, index: Int, ordinalWidth: CGFloat) -> some View {
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
                        Text(verbatim: trackNumber.formatted(.number.locale(locale)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                            .lineLimit(1)
                            .pmFadeTransition()
                    }
                }
                .frame(width: ordinalWidth, alignment: .center)

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
        SiriMediaInteractionDonor.donate(.album(id: album.id), shuffled: shuffled)
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
