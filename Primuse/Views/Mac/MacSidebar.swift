#if os(macOS)
import SwiftUI
import PrimuseKit

/// 新设计的 macOS 侧栏 — 不再用 SwiftUI `List`,改成纯 ScrollView + VStack,
/// 这样能精确控制行高 (24pt)、分组 header 字号 (10.5pt uppercase)、
/// 当前项的 accent 着色与圆角背景, 跟设计稿的 sidebar 节奏完全一致。
struct MacSidebar: View {
    @Binding var selection: MacRoute
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
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
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [PMColor.brand, PMColor.brand.opacity(0.7)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 28, height: 28)
                .overlay {
                    // 设计稿要求左侧 logo 用一个中文字符 monogram (设计 demo 用的是
                    // "猿" 字), 比 SF Symbol 更切合品牌名 "猿音 Primuse"。
                    Text(verbatim: "猿")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: PMColor.brand.opacity(0.35), radius: 4, y: 2)

            // 中文 "猿音" 是主名, Latin "Primuse" 副名小一号。两段 tracking 略收紧。
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "猿音")
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(PMColor.text)
                Text(verbatim: "Primuse")
                    .font(.system(size: 13, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(PMColor.textMuted)
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
                 title: LibrarySection.songs.title,
                 trailing: countLabel(library.visibleSongs.count))
            item(route: .section(.albums), icon: "square.stack.fill",
                 title: LibrarySection.albums.title,
                 trailing: countLabel(library.visibleAlbums.count))
            item(route: .section(.artists), icon: "music.mic",
                 title: LibrarySection.artists.title,
                 trailing: countLabel(library.visibleArtists.count))
            item(route: .liked, icon: "heart.fill",
                 title: "playlist_liked_name",
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
                Button {
                    NotificationCenter.default.post(name: .primuseSidebarRequestNewPlaylist, object: nil)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PMColor.textFaint)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("new_playlist"))
                .padding(.trailing, 4)
            }

            ForEach(library.playlists.prefix(6), id: \.id) { playlist in
                item(route: .playlist(playlist), icon: "music.note.list",
                     title: LocalizedStringKey(playlist.name),
                     trailing: countLabel(library.songs(forPlaylist: playlist.id).count))
            }

            if library.playlists.isEmpty {
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
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
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

            item(route: .playlistImport, icon: "tray.and.arrow.down",
                 title: "导入歌单 (M3U8/JSON)")
            item(route: .duplicates, icon: "arrow.triangle.2.circlepath",
                 title: "重复歌曲清理")
            item(route: .scrobble, icon: "waveform.path.ecg",
                 title: "Scrobble 配置")
        }
        .padding(.horizontal, 6)
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
            .padding(.vertical, 5)
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

    private func isSelected(_ route: MacRoute) -> Bool {
        switch (selection, route) {
        case (.home, .home), (.stats, .stats), (.search, .search),
             (.sources, .sources), (.playlistImport, .playlistImport),
             (.duplicates, .duplicates), (.scrobble, .scrobble),
             (.liked, .liked):
            return true
        case (.section(let a), .section(let b)):
            return a == b
        case (.playlist(let a), .playlist(let b)):
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
}

#endif
