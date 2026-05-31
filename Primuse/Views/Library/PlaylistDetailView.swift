import SwiftUI
import PrimuseKit

struct PlaylistDetailView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicScraperService.self) private var scraperService
    let playlist: Playlist

    @State private var exportShareItem: ExportShareItem?
    @State private var exportError: String?
    @State private var showReorderSheet = false

    private var currentPlaylist: Playlist? {
        library.playlist(id: playlist.id)
    }

    private var songs: [Song] {
        library.songs(forPlaylist: playlist.id)
    }

    /// 给 .sheet 用 — URL 不是 Identifiable, 包一层。
    struct ExportShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    @ViewBuilder
    var body: some View {
        #if os(macOS)
        macPlaylistDetail
        #else
        legacyPlaylistDetail
        #endif
    }

    private var legacyPlaylistDetail: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Playlist header
                VStack(spacing: 8) {
                    StoredCoverArtView(
                        fileName: currentPlaylist?.coverArtPath,
                        size: 180,
                        cornerRadius: 14
                    )

                    Text(currentPlaylist?.name ?? playlist.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("\(songs.count) \(String(localized: "songs_count"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Action buttons ── 主按钮"播放全部"占大头, 旁边两个紧凑图标按钮。
                // 三按钮等分时中文 label 在 iPhone 上挤换行 / 截断, 这套 Apple Music
                // 风格的 1+2 布局更稳。
                HStack(spacing: 10) {
                    Button {
                        playAll()
                    } label: {
                        Label("play_all", systemImage: "play.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        player.shuffleEnabled = true
                        playAll()
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.headline)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityLabel(Text("shuffle"))

                    Button {
                        sourceManager.downloadForOffline(songs: songs)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.headline)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(songs.filteredPlayable().isEmpty)
                    .accessibilityLabel(Text("offline_download"))
                }
                .padding(.horizontal)

                // Songs
                LazyVStack(spacing: 0) {
                    ForEach(songs) { song in
                        SongRowView(
                            song: song,
                            isPlaying: player.currentSong?.id == song.id,
                            showsActions: false,
                            context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .onTapGesture { playSong(song) }
                        .contextMenu {
                            // Apple Music 资料库镜像里的 Apple Music 歌不能移除 ──
                            // 我们没法 push 回 Apple Music 删收藏, 移除后下次 sync
                            // 又自动回来, 视觉上会变成"删了又出现"的 bug。其它源
                            // 的歌 (用户额外手动加进来等情况) 仍能正常移除。
                            if !isAppleMusicMirrorEntry(song: song) {
                                Button(role: .destructive) {
                                    library.remove(songID: song.id, fromPlaylist: playlist.id)
                                } label: {
                                    Label("remove_from_playlist", systemImage: "trash")
                                }
                            }
                        }

                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Apple Music 镜像歌单不让用户重排 ── 下次 sync 会被覆盖,
                    // 重排白做; 普通用户歌单 + 智能歌单的衍生不在这里。
                    if !AppleMusicLibraryService.isAppleMusicMirrorPlaylist(playlist.id) {
                        Button {
                            showReorderSheet = true
                        } label: {
                            Label("playlist_reorder", systemImage: "arrow.up.arrow.down")
                        }
                        .disabled(songs.count < 2)
                    }
                    Button {
                        player.appendToQueue(songs.filteredPlayable())
                    } label: {
                        Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                    }
                    .disabled(songs.filteredPlayable().isEmpty)
                    Button {
                        player.insertNextInQueue(songs.filteredPlayable())
                    } label: {
                        Label("up_next", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .disabled(songs.filteredPlayable().isEmpty)
                    Button {
                        scraperService.scrapeMissingMetadata(songs: songs, in: library)
                    } label: {
                        Label("scrape_missing_metadata", systemImage: "wand.and.stars")
                    }
                    .disabled(songs.isEmpty || scraperService.isScraping)
                    Button {
                        export(format: .m3u8)
                    } label: {
                        Label("playlist_export_m3u8", systemImage: "doc.text")
                    }
                    Button {
                        export(format: .json)
                    } label: {
                        Label("playlist_export_json", systemImage: "doc.badge.gearshape")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(songs.isEmpty)
            }
        }
        .sheet(item: $exportShareItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $showReorderSheet) {
            PlaylistReorderSheet(playlist: playlist, songs: songs) { newOrder in
                library.replacePlaylistSongs(
                    playlistID: playlist.id,
                    songIDs: newOrder.map(\.id)
                )
            }
        }
        .alert(String(localized: "playlist_export_failed_title"),
               isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("ok", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    #if os(macOS)
    private var macPlaylistDetail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                MacLibraryHeader(
                    eyebrow: "playlist",
                    title: currentPlaylist?.name ?? playlist.name,
                    subtitle: playlistSubtitle,
                    iconSystemName: playlist.id == MusicLibrary.likedSongsPlaylistID ? "heart.fill" : "music.note.list",
                    coverSong: songs.first(where: { $0.coverArtFileName?.isEmpty == false }),
                    onPlay: playAll,
                    onShuffle: {
                        player.shuffleEnabled = true
                        playAll()
                    },
                    moreMenu: playlistMoreMenu
                )

                VStack(alignment: .leading, spacing: PMSpace.l) {
                    // 设计稿: 普通歌单只有 LibraryHeader + 歌曲表。智能歌单才显示
                    // smart rule callout (放在 SmartPlaylistDetailView 里)。原来这里
                    // 给所有非 Liked/AM 歌单都套了一个 "reorder + 导出" 工具卡, 不在
                    // 设计稿里, 现在直接换成 toolbar (排序/导出/更多) 工具条。
                    macPlaylistToolbar

                    if songs.isEmpty {
                        EmptyStateView(
                            titleKey: "no_songs",
                            descriptionKey: "no_songs_desc",
                            systemImage: "music.note.list"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                    } else {
                        macSongTable
                    }
                }
                .padding(.horizontal, PMSpace.xxxl)
                .padding(.top, PMSpace.l)
            }
            .padding(.bottom, 112)
        }
        .background(PMColor.bg.ignoresSafeArea())
        .sheet(isPresented: $showReorderSheet) {
            PlaylistReorderSheet(playlist: playlist, songs: songs) { newOrder in
                library.replacePlaylistSongs(
                    playlistID: playlist.id,
                    songIDs: newOrder.map(\.id)
                )
            }
        }
        .alert(String(localized: "playlist_export_failed_title"),
               isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("ok", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    private var playlistSubtitle: String {
        let duration = songs.reduce(0) { $0 + $1.duration }
        let kind = AppleMusicLibraryService.isAppleMusicMirrorPlaylist(playlist.id)
            ? "Apple Music"
            : String(localized: "tab_playlists")
        return "\(songs.count) \(String(localized: "songs_count")) · \(duration.formattedShort) · \(kind)"
    }

    @ViewBuilder
    private var macPlaylistRuleCard: some View {
        if playlist.id != MusicLibrary.likedSongsPlaylistID,
           !AppleMusicLibraryService.isAppleMusicMirrorPlaylist(playlist.id) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PMColor.brand)
                VStack(alignment: .leading, spacing: 3) {
                    Text("tab_playlists")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(verbatim: "\(songs.count) \(String(localized: "songs_count")) · \(String(localized: "playlist_reorder")) / M3U8 / JSON")
                        .font(.system(size: 12))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                Button("playlist_reorder") { showReorderSheet = true }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5, weight: .medium))
                    .disabled(songs.count < 2)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .pmGlass(cornerRadius: PMRadius.m10)
        }
    }

    /// 设计稿 PlaylistDetail: header(含"更多"菜单) 之下直接是一行 "歌曲" 小标题 +
    /// 曲目表, 不再单独放重排/导出工具条 —— 那些动作都收进了 header 的更多菜单。
    private var macPlaylistToolbar: some View {
        HStack(spacing: 8) {
            Text(verbatim: "歌曲")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(PMColor.textFaint)
            Spacer()
        }
        .padding(.top, -2)
    }

    /// header 右上角"更多"按钮的菜单内容。播放 / 队列 / 重排 / 离线 / 导出 / 删除。
    private var playlistMoreMenu: AnyView {
        let playable = songs.filteredPlayable()
        let isMirror = AppleMusicLibraryService.isAppleMusicMirrorPlaylist(playlist.id)
        let canDelete = canDeletePlaylist(playlist.id)

        var middle: [MacHeaderMoreMenu.Item] = []
        if !isMirror {
            middle.append(.init(icon: "arrow.up.arrow.down", title: String(localized: "playlist_reorder"),
                                enabled: songs.count >= 2) { showReorderSheet = true })
        }
        middle.append(.init(icon: "arrow.down.circle", title: String(localized: "offline_download"),
                            enabled: !playable.isEmpty) {
            sourceManager.downloadForOffline(songs: songs)
        })
        middle.append(.init(icon: "wand.and.stars", title: String(localized: "scrape_missing_metadata"),
                            trailing: songs.count.formatted(),
                            enabled: !songs.isEmpty && !scraperService.isScraping) {
            scraperService.scrapeMissingMetadata(songs: songs, in: library)
        })

        return AnyView(MacHeaderMoreMenu(sections: [
            [
                .init(icon: "play.fill", title: String(localized: "play_all"),
                      enabled: !playable.isEmpty, action: playAll),
                .init(icon: "shuffle", title: String(localized: "shuffle"),
                      enabled: !playable.isEmpty) {
                    player.shuffleEnabled = true
                    playAll()
                },
                .init(icon: "text.line.last.and.arrowtriangle.forward", title: String(localized: "add_to_queue"),
                      enabled: !playable.isEmpty) { player.appendToQueue(playable) },
                .init(icon: "text.line.first.and.arrowtriangle.forward", title: String(localized: "up_next"),
                      enabled: !playable.isEmpty) { player.insertNextInQueue(playable) },
            ],
            middle,
            [
                .init(icon: "doc.text", title: String(localized: "playlist_export_m3u8"),
                      enabled: !songs.isEmpty) { export(format: .m3u8) },
                .init(icon: "curlybraces", title: String(localized: "playlist_export_json"),
                      enabled: !songs.isEmpty) { export(format: .json) },
            ],
            canDelete ? [
                .init(icon: "trash", title: String(localized: "delete_playlist"),
                      isDestructive: true) { deleteCurrentPlaylist() },
            ] : [],
        ]))
    }

    private var macSongTable: some View {
        let rows = Array(songs.enumerated())
        return VStack(spacing: 0) {
            // 设计稿 9 列: # / cover / 标题 / 艺术家 / 专辑 / 格式 / 时长 / 播放 / 源
            HStack(spacing: 12) {
                Text("#").frame(width: 32, alignment: .leading)
                Color.clear.frame(width: 32, height: 1)
                Text("sort_title").frame(maxWidth: .infinity, alignment: .leading)
                Text("sort_artist").frame(maxWidth: .infinity, alignment: .leading)
                Text("sort_album").frame(maxWidth: .infinity, alignment: .leading)
                Text("sort_format").frame(width: 100, alignment: .leading)
                Text("track_duration_short").frame(width: 80, alignment: .trailing)
                Text("home_playable_count_short").frame(width: 80, alignment: .trailing)
                Text("source").frame(width: 60, alignment: .leading)
            }
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(PMColor.textFaint)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            LazyVStack(spacing: 1) {
                ForEach(rows, id: \.element.id) { index, song in
                    macSongRow(song, index: index)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var playCountsBySongID: [String: Int] {
        var dict: [String: Int] = [:]
        for e in PlayHistoryStore.shared.entries {
            dict[e.songID, default: 0] += 1
        }
        return dict
    }

    private func macSongRow(_ song: Song, index: Int) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        let plays = playCountsBySongID[song.id] ?? 0
        let source = sourcesStore.sources.first(where: { $0.id == song.sourceID })
        return HStack(spacing: 12) {
            ZStack {
                if isCurrent {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.brand)
                } else {
                    Text("\(index + 1)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            .frame(width: 32, alignment: .leading)

            CachedArtworkView(
                coverRef: song.coverArtFileName, songID: song.id,
                size: 28, cornerRadius: 4,
                sourceID: song.sourceID, filePath: song.filePath
            )
            .frame(width: 32, alignment: .leading)

            Text(song.title)
                .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(song.artistName ?? "—")
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(song.albumTitle ?? "—")
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                PMFormatPill.forFormat(song.fileFormat.displayName)
                if let sr = song.sampleRate, sr > 0 {
                    Text(verbatim: "\(sr / 1000)k")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            .frame(width: 100, alignment: .leading)

            Text(song.duration.formattedDuration)
                .font(.system(size: 11.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(PMColor.textMuted)
                .frame(width: 80, alignment: .trailing)

            Group {
                if plays > 0 {
                    Text("\(plays)")
                        .font(.system(size: 11.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(PMColor.textMuted)
                } else {
                    Text(verbatim: "—")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            .frame(width: 80, alignment: .trailing)

            HStack(spacing: 5) {
                if let source {
                    Circle()
                        .fill(macSourceDotColor(for: source))
                        .frame(width: 6, height: 6)
                    Text(verbatim: source.name.components(separatedBy: "·").first?
                        .trimmingCharacters(in: .whitespaces) ?? source.name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(verbatim: "—")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                }
            }
            .frame(width: 60, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: 44)
        .pmRowBackground(selected: isCurrent)
        .contentShape(Rectangle())
        .onTapGesture { playSong(song) }
        .contextMenu {
            if !isAppleMusicMirrorEntry(song: song) {
                Button(role: .destructive) {
                    library.remove(songID: song.id, fromPlaylist: playlist.id)
                } label: {
                    Label("remove_from_playlist", systemImage: "trash")
                }
            }
        }
    }

    private func macSourceDotColor(for source: MusicSource) -> Color {
        let palette: [Color] = [
            PMColor.flac, PMColor.dsd, PMColor.warn, PMColor.brand,
            Color(red: 0.4, green: 0.7, blue: 0.95),
            Color(red: 0.7, green: 0.6, blue: 0.95),
        ]
        let h = abs(source.type.rawValue.hashValue) % palette.count
        return palette[h]
    }
    #endif

    /// 这个 song 是不是 Apple Music 镜像歌单里的 Apple Music 歌 ── 同时
     /// 满足 (playlist 是任意 AM 镜像) 且 (song 是 Apple Music 来源) 才算,
     /// 用户自己手动 add 进去的其它源歌仍可正常移除。
     private func isAppleMusicMirrorEntry(song: Song) -> Bool {
         AppleMusicLibraryService.isAppleMusicMirrorPlaylist(playlist.id)
             && song.sourceID == AppleMusicLibraryService.systemSourceID
     }

    private func canDeletePlaylist(_ playlistID: String) -> Bool {
        !AppleMusicLibraryService.isAppleMusicMirrorPlaylist(playlistID)
            && playlistID != MusicLibrary.likedSongsPlaylistID
    }

    private func deleteCurrentPlaylist() {
        guard canDeletePlaylist(playlist.id) else { return }
        library.deletePlaylist(id: playlist.id)
        #if os(macOS)
        NotificationCenter.default.post(name: .primuseSelectPlaylists, object: nil)
        #endif
    }

     private func export(format: PlaylistExporter.Format) {
        do {
            let target = currentPlaylist ?? playlist
            let url = try PlaylistExporter.export(
                playlist: target,
                songs: songs,
                format: format,
                sourcesStore: sourcesStore
            )
            #if os(macOS)
            try PlaylistExporter.presentSavePanel(for: url)
            #else
            exportShareItem = ExportShareItem(url: url)
            #endif
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func playAll() {
        let queue = songs.filteredPlayable()
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
}

// MARK: - Playlist Reorder Sheet

/// 拖拽重排歌单内歌曲顺序。用 List + EditMode + ForEach.onMove (SwiftUI 原生
/// 拖动 handle), 完成后回调把新顺序传出去, parent 调 library.replacePlaylistSongs
/// 写回 + sync。Apple Music 镜像歌单不进这里 (PlaylistDetailView 已经 disable
/// 重排入口)。
struct PlaylistReorderSheet: View {
    let playlist: Playlist
    let initialSongs: [Song]
    let onDone: ([Song]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var localSongs: [Song]

    init(playlist: Playlist, songs: [Song], onDone: @escaping ([Song]) -> Void) {
        self.playlist = playlist
        self.initialSongs = songs
        self._localSongs = State(initialValue: songs)
        self.onDone = onDone
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    private var iosBody: some View {
        NavigationStack {
            List {
                ForEach(localSongs) { song in
                    HStack(spacing: 10) {
                        CachedArtworkView(
                            coverRef: song.coverArtFileName,
                            songID: song.id,
                            size: 36,
                            cornerRadius: 5,
                            sourceID: song.sourceID,
                            filePath: song.filePath
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).font(.subheadline).lineLimit(1)
                            if let artist = song.artistName {
                                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .onMove { from, to in
                    localSongs.move(fromOffsets: from, toOffset: to)
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle(playlist.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) {
                        // 只有顺序真改了才写库, 避免无意义触发 sync。
                        if localSongs.map(\.id) != initialSongs.map(\.id) {
                            onDone(localSongs)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                #else
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "done")) {
                        if localSongs.map(\.id) != initialSongs.map(\.id) {
                            onDone(localSongs)
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                #endif
            }
        }
    }

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PMColor.brand.opacity(0.16))
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(PMColor.brand)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text("调整播放顺序")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(PMColor.text)
                    Text("\(playlist.name) · \(localSongs.count) \(String(localized: "songs_count"))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PMColor.textMuted)
                        .frame(width: 26, height: 26)
                        .background(PMColor.glassBtn, in: .circle)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 8) {
                    ForEach(Array(localSongs.enumerated()), id: \.element.id) { index, song in
                        macSongRow(song, index: index)
                    }
                }
                .padding(14)
            }

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack {
                Text(hasChanges ? "顺序已更改" : "使用箭头移动歌曲")
                    .font(.system(size: 11.5))
                    .foregroundStyle(hasChanges ? PMColor.brand : PMColor.textFaint)
                Spacer()
                Button("cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.text)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(PMColor.glassBtn, in: .rect(cornerRadius: 7))
                Button("done") {
                    if hasChanges {
                        onDone(localSongs)
                    }
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(PMColor.brand, in: .rect(cornerRadius: 7))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(width: 520, height: 620)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(PMColor.bg.opacity(0.78))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.24), radius: 28, y: 14)
    }

    private var hasChanges: Bool {
        localSongs.map(\.id) != initialSongs.map(\.id)
    }

    private func macSongRow(_ song: Song, index: Int) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(PMColor.textFaint)
                .frame(width: 26, alignment: .trailing)

            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 38,
                cornerRadius: 5,
                sourceID: song.sourceID,
                filePath: song.filePath
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(song.artistName ?? String(localized: "unknown_artist"))
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 2) {
                reorderButton("chevron.up", disabled: index == 0) {
                    moveSong(from: index, to: index - 1)
                }
                reorderButton("chevron.down", disabled: index == localSongs.count - 1) {
                    moveSong(from: index, to: index + 1)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(PMColor.bgElev.opacity(0.84), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
    }

    private func reorderButton(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(disabled ? PMColor.textFaint.opacity(0.45) : PMColor.textMuted)
                .frame(width: 24, height: 24)
                .background(PMColor.glassBtn, in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func moveSong(from source: Int, to destination: Int) {
        guard localSongs.indices.contains(source), localSongs.indices.contains(destination) else { return }
        let item = localSongs.remove(at: source)
        localSongs.insert(item, at: destination)
    }
    #endif
}
