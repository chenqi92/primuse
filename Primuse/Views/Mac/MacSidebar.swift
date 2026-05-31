#if os(macOS)
import SwiftUI
import PrimuseKit

/// 新设计的 macOS 侧栏 — 不再用 SwiftUI `List`,改成纯 ScrollView + VStack,
/// 这样能精确控制行高 (24pt)、分组 header 字号 (10.5pt uppercase)、
/// 当前项的 accent 着色与圆角背景, 跟设计稿的 sidebar 节奏完全一致。
struct MacSidebar: View {
    @Binding var selection: MacRoute
    /// 「工具」区的点击回调 —— 由 `MacContentView` 接住后弹 `.sheet`。工具不进
    /// 路由, 所以走独立回调而非 `selection`。
    var onOpenTool: (MacTool) -> Void = { _ in }
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(\.pmAppearance) private var mode

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                brandHeader
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)

                primaryItems
                librarySection
                playlistsSection
                sourcesSection
                toolsSection

                Spacer(minLength: 16)
            }
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .frame(maxHeight: .infinity)
        .background(sidebarBackground.ignoresSafeArea())
    }

    // MARK: - Brand header

    private var brandHeader: some View {
        HStack(spacing: 10) {
            BrandMonogram(slot: .sidebar)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: PMAppPrimaryDisplayName())
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(PMColor.text)
                if let secondary = PMAppSecondaryDisplayName() {
                    Text(verbatim: secondary)
                        .font(.system(size: 13, weight: .medium))
                        .tracking(-0.1)
                        .foregroundStyle(PMColor.textMuted)
                }
            }
            Spacer()
        }
    }

    // MARK: - Primary section (Home / Stats / Sources / Search)

    private var primaryItems: some View {
        VStack(alignment: .leading, spacing: 1) {
            item(route: .home,    icon: "house.fill",                       title: "home_title")
            item(route: .stats,   icon: "chart.bar.xaxis",                  title: "stats_title")
            item(route: .sources, icon: "externaldrive.connected.to.line.below", title: "sources_title")
            item(route: .search,  icon: "magnifyingglass",                  title: "search_title")
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Library section

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("library_title")

            item(route: .section(.songs), icon: "music.note",
                 title: "sidebar_all_songs",
                 trailing: countLabel(library.visibleSongs.count))
            item(route: .section(.albums), icon: "square.stack.fill",
                 title: LibrarySection.albums.title,
                 trailing: countLabel(library.visibleAlbums.count))
            item(route: .section(.artists), icon: "music.mic",
                 title: LibrarySection.artists.title,
                 trailing: countLabel(library.visibleArtists.count))
            // "我喜欢的" 作为资料库的固定快捷入口 (设计稿 LIB 侧栏)。它底层就是
            // likedSongsPlaylistID 那个系统歌单, 所以下面的「歌单」分区会把它过滤掉,
            // 避免同一个东西出现两次。
            item(route: .liked, icon: "heart.fill",
                 title: "sidebar_liked_songs",
                 trailing: countLabel(library.songs(forPlaylist: MusicLibrary.likedSongsPlaylistID).count))
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Playlists section

    private var playlistsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                sectionHeader("playlists_title")
                Spacer()
                Menu {
                    Button {
                        NotificationCenter.default.post(name: .primuseSidebarRequestNewPlaylist, object: nil)
                    } label: {
                        Label("new_playlist", systemImage: "music.note.list")
                    }
                    Button {
                        NotificationCenter.default.post(name: .primuseSidebarRequestNewSmartPlaylist, object: nil)
                    } label: {
                        Label("new_smart_playlist", systemImage: "sparkles")
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
                .help(Text("new_playlist"))
                .padding(.trailing, 4)
            }

            // 智能歌单排在普通歌单上面 (跟歌单总览页的分区顺序一致)。
            ForEach(sidebarSmartPlaylists.prefix(6), id: \.id) { smart in
                item(route: .smartPlaylist(smart), icon: "sparkles",
                     title: LocalizedStringKey(smart.name))
                .contextMenu {
                    smartPlaylistContextMenu(for: smart)
                }
            }

            ForEach(sidebarPlaylists.prefix(6), id: \.id) { playlist in
                item(route: .playlist(playlist), icon: "music.note.list",
                     title: LocalizedStringKey(playlist.name),
                     trailing: countLabel(library.songs(forPlaylist: playlist.id).count))
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
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Sources section

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("manage_sources")

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
                        let count = library.visibleSongs.filter { $0.sourceID == source.id }.count
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
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
    }

    // MARK: - Tools section

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            sectionHeader("mac_sidebar_tools")

            toolItem(.playlistImport, icon: "tray.and.arrow.down",
                     title: "Import Playlist (M3U8/JSON)")
            toolItem(.duplicates, icon: "arrow.triangle.2.circlepath",
                     title: "Duplicate Song Cleanup")
            toolItem(.scrobble, icon: "waveform.path.ecg",
                     title: "Scrobble Configuration")
        }
        .padding(.horizontal, 6)
    }

    /// 工具行 —— 跟 `item` 长得一样, 但点击是弹 sheet (`onOpenTool`) 而不是
    /// 切路由, 所以永远不显示选中态。右侧带一个箭头暗示"打开面板"。
    @ViewBuilder
    private func toolItem(_ tool: MacTool, icon: String, title: LocalizedStringKey) -> some View {
        Button {
            onOpenTool(tool)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(PMColor.text.opacity(0.78))
                    .frame(width: 18, height: 18)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(PMColor.text.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PMColor.textFaint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .pmRowBackground(selected: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        let playlistSongs = library.songs(forPlaylist: playlist.id)
        let playable = playlistSongs.filteredPlayable()

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
        .disabled(playable.isEmpty)

        Button {
            player.shuffleEnabled = true
            playPlaylist(playlist)
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
            scraperService.scrapeMissingMetadata(songs: playlistSongs, in: library)
        } label: {
            Label("scrape_missing_metadata", systemImage: "wand.and.stars")
        }
        .disabled(playlistSongs.isEmpty || scraperService.isScraping)

        if canDeletePlaylist(playlist.id) {
            Divider()
            Button(role: .destructive) {
                deletePlaylist(playlist)
            } label: {
                Label("delete_playlist", systemImage: "trash")
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
            player.shuffleEnabled = true
            playSmart(smart)
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

    private func playPlaylist(_ playlist: Playlist) {
        let queue = library.songs(forPlaylist: playlist.id).filteredPlayable()
        guard let first = queue.first else { return }
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }

    /// 「歌单」分区展示的歌单 —— 过滤掉 liked 系统歌单, 因为它已经作为
    /// 「资料库 · 我喜欢的」固定入口出现了, 不重复。
    private var sidebarPlaylists: [Playlist] {
        library.playlists.filter { $0.id != MusicLibrary.likedSongsPlaylistID }
    }

    private var sidebarSmartPlaylists: [SmartPlaylist] {
        library.smartPlaylists
    }

    private func canDeletePlaylist(_ playlistID: String) -> Bool {
        !AppleMusicLibraryService.isAppleMusicMirrorPlaylist(playlistID)
            && playlistID != MusicLibrary.likedSongsPlaylistID
    }

    private func deletePlaylist(_ playlist: Playlist) {
        guard canDeletePlaylist(playlist.id) else { return }
        library.deletePlaylist(id: playlist.id)
        if case .playlist(let selectedPlaylist) = selection, selectedPlaylist.id == playlist.id {
            select(.home)
        }
    }

    private func playSmart(_ smart: SmartPlaylist) {
        let queue = SmartPlaylistEngine.match(smart, in: library, history: PlayHistoryStore.shared)
            .filteredPlayable()
        guard let first = queue.first else { return }
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
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
        let h = abs(source.type.rawValue.hashValue) % palette.count
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

// MARK: - Notification

extension Notification.Name {
    static let primuseSidebarRequestNewPlaylist = Notification.Name("primuse.sidebar.newPlaylist")
    static let primuseSidebarRequestNewSmartPlaylist = Notification.Name("primuse.sidebar.newSmartPlaylist")
}

#endif
