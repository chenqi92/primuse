#if os(macOS)
import SwiftUI
import PrimuseKit

/// 新设计的 macOS 侧栏 — 不再用 SwiftUI `List`,改成纯 ScrollView + VStack,
/// 这样能精确控制行高 (24pt)、分组 header 字号 (10.5pt uppercase)、
/// 当前项的 accent 着色与圆角背景, 跟设计稿的 sidebar 节奏完全一致。
/// 侧栏只放「去哪儿」: 首页、资料库、歌单、音乐源。搜索在标题栏正中; 收藏、智能推荐、
/// 听歌统计、工具在标题栏右侧 —— 它们是临时看一眼或用完就关的, 不占导航。
struct MacSidebar: View {
    @Binding var selection: MacRoute
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(RadioStationsStore.self) private var radioStationsStore
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(\.pmAppearance) private var mode
    /// 「艺术家」行的数字跟着艺术家页的列法。
    @AppStorage(ArtistBrowseMode.storageKey)
    private var artistBrowseModeRaw = ArtistBrowseMode.allArtists.rawValue
    @AppStorage(LibraryDisplayConfiguration.sectionOrderKey)
    private var librarySectionOrderRawValue = ""
    @AppStorage(LibraryDisplayConfiguration.hiddenSectionsKey)
    private var hiddenLibrarySectionsRawValue = ""

    private var visibleLibrarySections: [LibrarySection] {
        LibraryDisplayConfiguration.visibleSections(
            orderRawValue: librarySectionOrderRawValue,
            hiddenRawValue: hiddenLibrarySectionsRawValue
        )
    }

    /// 「资料库」分组里的行: 照设置 › 外观里排好的顺序与显隐, 设置页那张列表就是这一组的样子。
    /// 歌单是下面单独的分区, 收藏、智能推荐、听歌统计在标题栏, 都不在这一组里。
    private var sidebarLibrarySections: [LibrarySection] {
        visibleLibrarySections.filter(MacSidebarLibraryLayout.isLibraryGroupRow)
    }

    /// 有声内容按「书」计数: 一部 200 集的评书是一本, 不是 200 条。分组在曲库
    /// 发布时算好一次, 这里不读收听位置, 听书时侧栏也不跟着重算。
    private var spokenWordBookCount: Int {
        library.spokenWordBookCount
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                brandHeader
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)

                homeItem
                librarySection
                if showsPlaylistsSection {
                    playlistsSection
                        .pmFadeTransition()
                }
                sourcesSection

                Spacer(minLength: 16)
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
            // 只盯「歌单分区可见性」这一个开关 —— 它一变整列都要重新排, 所以
            // 动画挂在这层; 其余分区各自用自己的 id 列表(见下)。
            .pmAnimation(.list, value: showsPlaylistsSection)
            .pmAnimation(.list, value: sidebarLibrarySections)
        }
        .frame(maxHeight: .infinity)
        .background(sidebarBackground.ignoresSafeArea())
    }

    // MARK: - Brand header

    private var brandHeader: some View {
        HStack(spacing: 10) {
            BrandMonogram(slot: .sidebar)

            Text(verbatim: PMAppDisplayName())
                .font(.system(size: 16, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(PMColor.text)
            Spacer()
        }
    }

    // MARK: - Home

    private var homeItem: some View {
        VStack(alignment: .leading, spacing: 1) {
            item(route: .home, icon: "house.fill", title: "home_title")
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Library section

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("library_title")

            ForEach(sidebarLibrarySections) { section in
                libraryNavigationItems(for: section)
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func libraryNavigationItems(for section: LibrarySection) -> some View {
        switch section {
        case .folders, .releaseDate:
            item(route: .section(section), icon: section.icon, title: section.title)
        case .playlists, .favorites, .recommendations, .statistics:
            // 不在这一组 (见 `MacSidebarLibraryLayout.isLibraryGroupRow`)。
            EmptyView()
        case .songs:
            item(
                route: .section(.songs),
                icon: section.icon,
                title: "sidebar_all_songs",
                // 「歌曲」只数音乐, 有声内容按书计在自己那一行。
                trailing: countLabel(library.musicSongs.count)
            )
        case .radio:
            item(
                route: .section(.radio),
                icon: section.icon,
                title: ListeningSpace.radio.titleKey,
                trailing: countLabel(radioStationsStore.stations.count)
            )
        case .spokenWord:
            // 没有内容时也留着入口 (设置里能关): 有声页自己会说明哪些内容
            // 会出现在这里, 比整行消失、让人以为功能没了要好。
            item(
                route: .section(.spokenWord),
                icon: section.icon,
                title: ListeningSpace.spokenWord.titleKey,
                trailing: countLabel(spokenWordBookCount)
            )
        case .podcasts:
            item(
                route: .section(.podcasts),
                icon: section.icon,
                title: ListeningSpace.podcast.titleKey,
                trailing: countLabel(PodcastStore.shared.shows.count)
            )
        case .albums:
            item(
                route: .section(.albums),
                icon: section.icon,
                title: section.title,
                trailing: countLabel(library.visibleAlbums.count)
            )
        case .artists:
            item(
                route: .section(.artists),
                icon: section.icon,
                title: section.title,
                trailing: countLabel(library.browsableArtists(.resolved(artistBrowseModeRaw)).count)
            )
        case .genres:
            item(
                route: .section(.genres),
                icon: section.icon,
                title: section.title,
                trailing: countLabel(library.visibleGenres.count)
            )
        }
    }

    // MARK: - Playlists section

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                sectionHeader("playlists_title")
                Spacer()
                newPlaylistMenu
            }

            // 「我喜欢」就是系统歌单, 像 Apple Music 的「喜爱的歌曲」一样钉在歌单最上面;
            // 下面列歌单时把它滤掉, 不出现两次。
            item(route: .liked, icon: "heart.fill",
                 title: "sidebar_liked_songs",
                 trailing: countLabel(library.songCount(forPlaylist: MusicLibrary.likedSongsPlaylistID)))

            // 智能歌单排在普通歌单上面 (跟歌单总览页的分区顺序一致)。侧栏只列前
            // 几个保持节奏, 全部歌单从末尾「查看全部」进总览页。
            ForEach(sidebarSmartPlaylists.prefix(sidebarPlaylistLimit), id: \.id) { smart in
                item(route: .smartPlaylist(smart),
                     icon: smart.effectiveKind == .ai ? "sparkles" : "slider.horizontal.3",
                     title: LocalizedStringKey(smart.name))
                .contextMenu {
                    smartPlaylistContextMenu(for: smart)
                }
            }

            ForEach(sidebarPlaylists.prefix(sidebarPlaylistLimit), id: \.id) { playlist in
                playlistItem(playlist)
                .contextMenu {
                    playlistContextMenu(for: playlist)
                }
            }

            if sidebarPlaylists.isEmpty && sidebarSmartPlaylists.isEmpty {
                Text("sidebar_playlists_empty")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .pmFadeTransition()
            } else {
                // 歌单总览(排序、管理)只从这一行进, 没截断时也留着。
                showAllPlaylistsItem
                    .pmFadeTransition()
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
        .pmAnimation(.list, value: playlistRowIDs)
    }

    /// 侧栏歌单区当前列出来的那几行。歌单量级几十到几百, 而这里只取前几条,
    /// 用 id 数组当动画的触发值足够小。
    private var playlistRowIDs: [String] {
        sidebarSmartPlaylists.prefix(sidebarPlaylistLimit).map(\.id)
            + sidebarPlaylists.prefix(sidebarPlaylistLimit).map(\.id)
            + (sidebarPlaylists.isEmpty && sidebarSmartPlaylists.isEmpty ? [] : ["show-all"])
    }

    /// 歌单分区的末行: 文字弱一档, 右侧给出总数, 点进歌单总览页。
    private var showAllPlaylistsItem: some View {
        Button {
            select(.section(.playlists))
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(width: 18, height: 18)

                Text("see_all")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let trailing = countLabel(sidebarPlaylists.count + sidebarSmartPlaylists.count) {
                    trailing
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .pmRowBackground(selected: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var newPlaylistMenu: some View {
        Menu {
            Button {
                select(.section(.playlists))
            } label: {
                Label("manage_playlists", systemImage: "rectangle.stack")
            }

            Divider()

            Button {
                NotificationCenter.default.post(name: .primuseSidebarRequestNewPlaylist, object: nil)
            } label: {
                Label("new_playlist", systemImage: "music.note.list")
            }
            Button {
                NotificationCenter.default.post(name: .primuseSidebarRequestNewSmartPlaylist, object: nil)
            } label: {
                Label("new_rule_smart_playlist", systemImage: "slider.horizontal.3")
            }
            Button {
                NotificationCenter.default.post(name: .primuseSidebarRequestNewAIPlaylist, object: nil)
            } label: {
                Label("new_ai_smart_playlist", systemImage: "sparkles")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("playlists_title"))
        .padding(.trailing, 4)
    }

    // MARK: - Sources section

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("sources_title")

            ForEach(sourcesStore.sources.prefix(6), id: \.id) { source in
                Button {
                    select(.source(source.id))
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(sourceDotColor(for: source))
                            .frame(width: 7, height: 7)
                        Text(verbatim: source.name)
                            .font(isSelected(.source(source.id)) ? .system(size: 13, weight: .medium) : .system(size: 13))
                            .foregroundStyle(isSelected(.source(source.id)) ? PMColor.text : PMColor.text.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 4)
                        // 设计稿: 音乐源行右侧显示该源的歌曲数 (mono 字体 + textFaint)
                        let count = library.visibleSongCount(forSourceID: source.id)
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(PMColor.textFaint)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .pmRowBackground(selected: isSelected(.source(source.id)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if sourcesStore.sources.isEmpty {
                Text("sidebar_sources_empty")
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .pmFadeTransition()
            }

            // 添加、编辑、超出 6 个的音乐源都在这一页。
            item(
                route: .sources,
                icon: sourcesStore.sources.isEmpty ? "plus.circle" : "slider.horizontal.3",
                title: sourcesStore.sources.isEmpty ? "add_source" : "manage_sources"
            )
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
        .pmAnimation(.list, value: sourceRowIDs)
    }

    /// 侧栏音乐源区当前列出来的那几行(最多 6 条)。
    private var sourceRowIDs: [String] {
        sourcesStore.sources.prefix(6).map(\.id)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func item(route: MacRoute, icon: String, title: LocalizedStringKey,
                      trailing: AnyView? = nil) -> some View {
        let selected = isSelected(route)
        Button {
            select(route)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? PMColor.brand : PMColor.text.opacity(0.78))
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(selected ? .system(size: 13, weight: .medium) : .system(size: 13))
                    .foregroundStyle(selected ? PMColor.text : PMColor.text.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if let trailing { trailing }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .pmRowBackground(selected: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func playlistItem(_ playlist: Playlist) -> some View {
        let route = MacRoute.playlist(playlist)
        let selected = isSelected(route)
        return Button {
            select(route)
        } label: {
            HStack(spacing: 9) {
                PlaylistArtworkView(
                    playlist: playlist,
                    size: 18,
                    cornerRadius: 4
                )

                Text(verbatim: playlist.name)
                    .font(selected ? .system(size: 13, weight: .medium) : .system(size: 13))
                    .foregroundStyle(selected ? PMColor.text : PMColor.text.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if let trailing = countLabel(library.songCount(forPlaylist: playlist.id)) {
                    trailing
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .pmRowBackground(selected: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func countLabel(_ n: Int) -> AnyView? {
        guard n > 0 else { return nil }
        return AnyView(
            Text("\(n)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(PMColor.textFaint)
        )
    }

    @ViewBuilder
    private func playlistContextMenu(for playlist: Playlist) -> some View {
        // 侧栏每次重绘都会给每一行求一遍菜单, 这里只数个数; 歌在点下去时才取。
        let isEmpty = library.songCount(forPlaylist: playlist.id) == 0

        Button {
            select(.playlist(playlist))
        } label: {
            Label("open", systemImage: "arrow.right.circle")
        }

        Button {
            playPlaylist(playlist)
        } label: {
            Label("play_all", systemImage: "play.fill")
        }
        .disabled(isEmpty)

        Button {
            playPlaylist(playlist, shuffled: true)
        } label: {
            Label("shuffle", systemImage: "shuffle")
        }
        .disabled(isEmpty)

        Button {
            player.appendToQueue(library.songs(forPlaylist: playlist.id).filteredPlayable())
        } label: {
            Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        .disabled(isEmpty)

        Button {
            player.insertNextInQueue(library.songs(forPlaylist: playlist.id).filteredPlayable())
        } label: {
            Label("up_next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .disabled(isEmpty)

        Button {
            scraperService.scrapeMissingMetadata(songs: library.songs(forPlaylist: playlist.id), in: library)
        } label: {
            Label("scrape_missing_metadata", systemImage: "wand.and.stars")
        }
        .disabled(isEmpty || scraperService.isScraping)

        if canDeletePlaylist(playlist.id) {
            Divider()
            Button(role: .destructive) {
                deletePlaylist(playlist)
            } label: {
                Label("delete_playlist", systemImage: "trash")
            }
        } else if MirrorPlaylistIdentity.isMirrorPlaylist(playlist.id) {
            Divider()
            Button {
                hidePlaylist(playlist)
            } label: {
                Label("hide_playlist_from_primuse", systemImage: "eye.slash")
            }
        }
    }

    @ViewBuilder
    private func smartPlaylistContextMenu(for smart: SmartPlaylist) -> some View {
        let matched = SmartPlaylistEngine.match(smart, in: library, history: PlayHistoryStore.shared)
        let playable = matched.filteredPlayable()

        Button {
            select(.smartPlaylist(smart))
        } label: {
            Label("open", systemImage: "arrow.right.circle")
        }

        Button {
            playSmart(smart)
        } label: {
            Label("play_all", systemImage: "play.fill")
        }
        .disabled(playable.isEmpty)

        Button {
            playSmart(smart, shuffled: true)
        } label: {
            Label("shuffle", systemImage: "shuffle")
        }
        .disabled(playable.isEmpty)

        Button {
            player.appendToQueue(playable)
        } label: {
            Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        .disabled(playable.isEmpty)

        Button {
            player.insertNextInQueue(playable)
        } label: {
            Label("up_next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .disabled(playable.isEmpty)

        Button {
            scraperService.scrapeMissingMetadata(songs: matched, in: library)
        } label: {
            Label("scrape_missing_metadata", systemImage: "wand.and.stars")
        }
        .disabled(matched.isEmpty || scraperService.isScraping)

        SmartPlaylistIntentPinButton(playlistID: smart.id)

        Divider()
        Button(role: .destructive) {
            deleteSmart(smart)
        } label: {
            Label("delete", systemImage: "trash")
        }
    }

    private func isSelected(_ route: MacRoute) -> Bool {
        switch (selection, route) {
        case (.home, .home), (.stats, .stats), (.search, .search),
             (.sources, .sources), (.liked, .liked):
            return true
        case (.section(let a), .section(let b)):
            return a == b
        case (.playlist(let a), .playlist(let b)):
            return a.id == b.id
        case (.smartPlaylist(let a), .smartPlaylist(let b)):
            return a.id == b.id
        case (.source(let a), .source(let b)):
            return a == b
        default:
            return false
        }
    }

    private func select(_ route: MacRoute) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selection = route
        }
    }

    private func playPlaylist(_ playlist: Playlist, shuffled: Bool = false) {
        let playable = library.songs(forPlaylist: playlist.id).filteredPlayable()
        let queue = shuffled ? playable.shuffled() : playable
        guard !queue.isEmpty else { return }
        if shuffled { player.shuffleEnabled = true }
        Task { await player.play(queue: queue, startingAt: 0) }
    }

    /// 「歌单」分区展示的歌单 —— 过滤掉 liked 系统歌单, 因为它已经作为
    /// 「资料库 · 我喜欢的」固定入口出现了, 不重复。
    private var sidebarPlaylists: [Playlist] {
        library.playlists.filter { $0.id != MusicLibrary.likedSongsPlaylistID }
    }

    private var sidebarSmartPlaylists: [SmartPlaylist] {
        library.smartPlaylists
    }

    /// 侧栏每个歌单列表最多直接展示的条数, 超出的折叠进「全部歌单」入口。
    private var sidebarPlaylistLimit: Int { 6 }

    private var showsPlaylistsSection: Bool {
        visibleLibrarySections.contains(.playlists)
    }

    private func canDeletePlaylist(_ playlistID: String) -> Bool {
        !MirrorPlaylistIdentity.isMirrorPlaylist(playlistID)
            && playlistID != MusicLibrary.likedSongsPlaylistID
    }

    private func deletePlaylist(_ playlist: Playlist) {
        guard canDeletePlaylist(playlist.id) else { return }
        library.deletePlaylist(id: playlist.id)
        if case .playlist(let selectedPlaylist) = selection, selectedPlaylist.id == playlist.id {
            select(.home)
        }
    }

    private func hidePlaylist(_ playlist: Playlist) {
        guard MirrorPlaylistIdentity.isMirrorPlaylist(playlist.id) else { return }
        library.hideMirrorPlaylist(id: playlist.id)
        if case .playlist(let selectedPlaylist) = selection, selectedPlaylist.id == playlist.id {
            select(.home)
        }
    }

    private func playSmart(_ smart: SmartPlaylist, shuffled: Bool = false) {
        let playable = SmartPlaylistEngine.match(smart, in: library, history: PlayHistoryStore.shared)
            .filteredPlayable()
        let queue = shuffled ? playable.shuffled() : playable
        guard !queue.isEmpty else { return }
        if shuffled { player.shuffleEnabled = true }
        Task { await player.play(queue: queue, startingAt: 0) }
    }

    private func deleteSmart(_ smart: SmartPlaylist) {
        library.deleteSmartPlaylist(id: smart.id)
        if case .smartPlaylist(let selectedSmart) = selection, selectedSmart.id == smart.id {
            select(.home)
        }
    }

    private func sourceDotColor(for source: MusicSource) -> Color {
        // 用源类型 hash 出一个稳定颜色,但限定在调色板里。
        let palette: [Color] = [
            PMColor.flac, PMColor.dsd, PMColor.warn, PMColor.brand,
            Color(red: 0.4, green: 0.7, blue: 0.95),  // sky
            Color(red: 0.7, green: 0.6, blue: 0.95),  // lilac
        ]
        let h = source.type.rawValue.utf8.reduce(0) { ($0 + Int($1)) % palette.count }
        return palette[h]
    }

    // MARK: - Background

    @ViewBuilder
    private var sidebarBackground: some View {
        if mode == .glass {
            // 玻璃模式: NSVisualEffectView 提供模糊底, 上面盖一层暗色让对比够。
            ZStack {
                NSVisualEffectBackdrop(material: .sidebar, blending: .behindWindow)
                Rectangle().fill(PMColor.sidebarGlass)
            }
        } else {
            Rectangle().fill(PMColor.sidebarClassic)
        }
    }
}

/// 侧栏「资料库」分组的行 = 设置里可见的分类按原顺序 (歌单也是其中一行),
/// Mac 设置页的排序列表就是这份完整顺序, 两边必然一致。
enum MacSidebarLibraryLayout {
    /// 侧栏「资料库」组里有没有这一行。歌单是自己的分区; 收藏、智能推荐、听歌统计在标题栏
    /// 右侧 —— 它们在 iPhone 上仍是资料库里的分类, 共用的顺序与显隐只是 Mac 这组不列。
    static func isLibraryGroupRow(_ section: LibrarySection) -> Bool {
        switch section {
        case .playlists, .favorites, .recommendations, .statistics: false
        default: true
        }
    }

    /// 侧栏上这一行叫什么; 设置页的排序列表用同一个名字。
    static func localizedTitle(for section: LibrarySection) -> String {
        switch section {
        case .songs: return String(localized: "sidebar_all_songs")
        case .radio: return String(localized: "listening_space_radio")
        case .spokenWord: return String(localized: "listening_space_spoken_word")
        default: return section.localizedTitle
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let primuseSidebarRequestNewPlaylist = Notification.Name("primuse.sidebar.newPlaylist")
    static let primuseSidebarRequestNewSmartPlaylist = Notification.Name("primuse.sidebar.newSmartPlaylist")
    static let primuseSidebarRequestNewAIPlaylist = Notification.Name("primuse.sidebar.newAIPlaylist")
}

#endif
