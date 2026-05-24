import SwiftUI
import PrimuseKit

enum LibrarySection: String, CaseIterable, Hashable {
    case playlists, artists, albums, songs

    var title: LocalizedStringKey {
        switch self {
        case .playlists: return "tab_playlists"
        case .artists: return "tab_artists"
        case .albums: return "tab_albums"
        case .songs: return "tab_songs"
        }
    }

    var icon: String {
        switch self {
        case .playlists: return "music.note.list"
        case .artists: return "music.mic"
        case .albums: return "square.stack.fill"
        case .songs: return "music.note"
        }
    }

    var color: Color {
        switch self {
        case .playlists: return .red
        case .artists: return .pink
        case .albums: return .purple
        case .songs: return .blue
        }
    }
}

enum LibraryDeepLink: Equatable, Sendable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
}

struct LibraryView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Binding private var deepLink: LibraryDeepLink?
    @State private var navigationPath = NavigationPath()

    private var songs: [Song] { library.visibleSongs }
    private var albums: [Album] { library.visibleAlbums }
    private var artists: [Artist] { library.visibleArtists }
    private var playlists: [Playlist] { library.playlists }
    private var hasContent: Bool { !songs.isEmpty }

    init(deepLink: Binding<LibraryDeepLink?> = .constant(nil)) {
        self._deepLink = deepLink
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                // 主入口 ── 大行 List 风格 (类似 Apple Music 资料库主页),
                // 4 个分类按 内容窄→宽 排序 (歌单 < 艺人 < 专辑 < 全部歌曲)。
                // 每行带数量徽标方便扫读。「我喜欢」就是歌单里的一个 system
                // 歌单, 不单独提到这里, 用户从「歌单」入口能看到。
                Section {
                    ForEach(LibrarySection.allCases, id: \.self) { section in
                        Button {
                            navigationPath.append(section)
                        } label: {
                            libraryEntryRowLabel(
                                icon: section.icon,
                                color: section.color,
                                title: Text(section.title),
                                count: count(for: section)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if hasContent {
                    // 最近添加 ── 保留, 在 List 里嵌横向 ScrollView 比上一版
                    // 嵌 LazyVGrid 更轻; 看完直接 see_all 进 songs。
                    Section {
                        NavigationLink(value: LibrarySection.songs) {
                            HStack {
                                Text("recently_added")
                                    .font(.headline)
                                Spacer()
                                Text("see_all")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(recentItems) { item in
                                    RecentItemCard(item: item)
                                        .frame(width: 130)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            if let song = item.song {
                                                playSong(song)
                                            } else if let album = item.album {
                                                playAlbum(album)
                                            }
                                        }
                                }
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 4)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    // 听歌统计 ── 本周时长 + 歌数 + top 3 艺人小封面, 一眼看到
                    // 自己在听什么。点击 row 进 ListeningStatsView 详细页。
                    if !listenedThisWeek.isEmpty {
                        Section {
                            NavigationLink {
                                ListeningStatsView()
                            } label: {
                                listeningStatsSummary
                            }
                        } header: {
                            Text("library_stats_header")
                        }
                    }

                    // 待整理 ── 健康度指示, 仅有数据时显示, 没东西整理就不出现
                    // 避免噪音。点击直接进对应处理页。
                    if duplicateGroupsCount > 0 || trashItemsCount > 0 {
                        Section {
                            if duplicateGroupsCount > 0 {
                                NavigationLink {
                                    DuplicateSongsView()
                                } label: {
                                    cleanupRow(
                                        icon: "square.stack.3d.up.badge.automatic",
                                        color: .orange,
                                        title: Text("library_cleanup_dup"),
                                        detail: String(format: String(localized: "library_cleanup_dup_count_format"),
                                                       duplicateGroupsCount)
                                    )
                                }
                            }
                            if trashItemsCount > 0 {
                                NavigationLink {
                                    RecentlyDeletedView()
                                } label: {
                                    cleanupRow(
                                        icon: "trash",
                                        color: .gray,
                                        title: Text("library_cleanup_trash"),
                                        detail: String(format: String(localized: "library_cleanup_trash_count_format"),
                                                       trashItemsCount)
                                    )
                                }
                            }
                        } header: {
                            Text("library_cleanup_header")
                        }
                    }
                } else {
                    // 空态 ── 引导用户去加第一个 source
                    Section {
                        VStack(spacing: 16) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 40))
                                .foregroundStyle(.tertiary)

                            Text("welcome_title")
                                .font(.headline)
                            Text("welcome_desc")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            NavigationLink {
                                SourcesView()
                            } label: {
                                Text("manage_sources").fontWeight(.medium)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                }
            }
            .listSectionSpacing(.compact)
            .navigationTitle("library_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(for: LibrarySection.self) { section in
                switch section {
                case .albums: AlbumGridView().navigationTitle(section.title)
                case .artists: ArtistListView(artists: artists).navigationTitle(section.title)
                case .songs: SongListView(songs: songs).navigationTitle(section.title)
                case .playlists: PlaylistListView().navigationTitle(section.title)
                }
            }
            .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
            .navigationDestination(for: Artist.self) { ArtistDetailView(artist: $0) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .onAppear { applyDeepLink(deepLink) }
            .onChange(of: deepLink) { _, newValue in applyDeepLink(newValue) }
        }
    }

    // MARK: - Recent Items

    private var recentItems: [RecentItem] {
        if !albums.isEmpty {
            return albums.prefix(6).map { album in
                let firstSong = library.songs(forAlbum: album.id).first
                return RecentItem(
                    id: album.id,
                    title: album.title,
                    subtitle: album.artistName ?? "",
                    coverFileName: firstSong?.coverArtFileName,
                    songID: firstSong?.id,
                    sourceID: firstSong?.sourceID,
                    filePath: firstSong?.filePath,
                    song: nil,
                    album: album
                )
            }
        }
        return songs.prefix(6).map { song in
            RecentItem(
                id: song.id,
                title: song.title,
                subtitle: song.artistName ?? "",
                coverFileName: song.coverArtFileName,
                songID: song.id,
                sourceID: song.sourceID,
                filePath: song.filePath,
                song: song,
                album: nil
            )
        }
    }

    // MARK: - Helpers

    private func statLabel(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Entry row helpers

    private func count(for section: LibrarySection) -> Int {
        switch section {
        case .playlists: return playlists.count
        case .artists: return artists.count
        case .albums: return albums.count
        case .songs: return songs.count
        }
    }

    /// 主入口大行 ── label + 右侧数量徽标 + chevron。
    @ViewBuilder
    private func libraryEntryRowLabel(
        icon: String,
        color: Color,
        title: Text,
        count: Int
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color)
                )
            title
                .font(.body)
            Spacer()
            Text("\(count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    // MARK: - Listening stats section

    /// 本周 (近 7 天) 的播放历史; 给主页 summary card 用, 不到 7 天的新用户
    /// 自然显示为空, summary section 走条件渲染 (entries 空就整段不显示)。
    private var listenedThisWeek: [PlayHistoryStore.Entry] {
        PlayHistoryStore.shared.entries(in: .week)
    }

    private var listeningStatsSummary: some View {
        let entries = listenedThisWeek
        let totalSec = entries.reduce(0.0) { $0 + $1.listenedSec }
        let totalHours = Int(totalSec / 3600)
        let totalMin = Int((totalSec.truncatingRemainder(dividingBy: 3600)) / 60)
        let topArtists = PlayHistoryStore.shared.topArtists(in: .week, limit: 3)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if totalHours > 0 {
                    Text("\(totalHours)").font(.title2.weight(.semibold)).monospacedDigit()
                    Text("h").font(.subheadline).foregroundStyle(.secondary)
                }
                Text("\(totalMin)").font(.title2.weight(.semibold)).monospacedDigit()
                Text("min").font(.subheadline).foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text("\(entries.count)").font(.title3.weight(.medium)).monospacedDigit()
                Text("library_stats_plays_suffix")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if !topArtists.isEmpty {
                HStack(spacing: 8) {
                    Text("library_stats_top_artists_label")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(topArtists) { item in
                        Text(item.title)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Cleanup section

    /// 待整理: 重复歌组数 + 回收站项数。两者都 > 0 时整段才显示。
    /// 重复歌检测是 O(N) 一次扫, library 大时 (上万首) 可能微卡, 但只在
    /// LibraryView body 渲染时跑一次, 不进 timer 循环, 可接受。
    private var duplicateGroupsCount: Int {
        DuplicateDetector.detect(in: songs).count
    }

    private var trashItemsCount: Int {
        library.recentlyDeletedPlaylists.count
            + library.recentlyDeletedSmartPlaylists.count
            + sourcesStore.recentlyDeletedSources.count
            + ScraperConfigStore.shared.recentlyDeletedConfigs.count
    }

    @ViewBuilder
    private func cleanupRow(
        icon: String,
        color: Color,
        title: Text,
        detail: String
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(color)
                )
            VStack(alignment: .leading, spacing: 2) {
                title.font(.body)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private func playAlbum(_ album: Album) {
        let queue = library.songs(forAlbum: album.id).filteredPlayable()
        guard let first = queue.first else { return }
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }

    private func playSong(_ song: Song) {
        let queue = songs.filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        Task { await player.play(song: song) }
    }

    private func applyDeepLink(_ link: LibraryDeepLink?) {
        guard let link else { return }
        var path = NavigationPath()
        switch link {
        case .album(let album):
            path.append(LibrarySection.albums)
            path.append(album)
        case .artist(let artist):
            path.append(LibrarySection.artists)
            path.append(artist)
        case .playlist(let playlist):
            path.append(LibrarySection.playlists)
            path.append(playlist)
        }
        navigationPath = path
        deepLink = nil
    }
}

// MARK: - Recent Item

struct RecentItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let coverFileName: String?
    let songID: String?
    let sourceID: String?
    let filePath: String?
    let song: Song?
    let album: Album?
}

struct RecentItemCard: View {
    let item: RecentItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedArtworkView(coverRef: item.coverFileName, songID: item.songID ?? "", cornerRadius: 8,
                              sourceID: item.sourceID, filePath: item.filePath)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)

            Text(item.title)
                .font(.caption)
                .lineLimit(1)

            Text(item.subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

#Preview {
    LibraryView()
        .environment(AudioPlayerService())
        .environment(MusicLibrary())
}
