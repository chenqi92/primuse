import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct PlaylistDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(MusicScraperService.self) private var scraperService
    let playlist: Playlist
    private let onMacInlineBack: (() -> Void)?

    init(playlist: Playlist, onMacInlineBack: (() -> Void)? = nil) {
        self.playlist = playlist
        self.onMacInlineBack = onMacInlineBack
    }

    @State private var exportShareItem: ExportShareItem?
    @State private var exportError: String?
    @State private var showReorderSheet = false
    @State private var scrapeFeedback: ScrapeFeedback?
    @State private var showNoScraperSourceAlert = false
    @State private var showArtworkEditor = false
    @State private var trackedScrapeRunID: UUID?
    @State private var isViewVisible = false
    @State private var selection = SongSelectionModel()

    /// 镜像歌单 (Apple Music 资料库 / 服务端曲库) 里的条目不给移除入口 —— 我们
    /// 没法把改动推回服务端，下次 sync 又会把它们带回来，视觉上就是"删了又出现"。
    private var allowsPlaylistRemoval: Bool {
        !MirrorPlaylistIdentity.isMirrorPlaylist(playlist.id)
    }

    private var currentPlaylist: Playlist? {
        library.playlist(id: playlist.id)
    }

    private var songs: [Song] {
        library.songs(forPlaylist: playlist.id)
    }

    /// 空态占位图标 ── Liked 用 heart, 其它歌单用列表图标。
    private var coverPlaceholderIcon: String {
        playlist.id == MusicLibrary.likedSongsPlaylistID ? "heart.fill" : "music.note.list"
    }

    private var isCurrentPlaylistScraping: Bool {
        guard scraperService.isScraping,
              scraperService.activeOriginPlaylistID == playlist.id,
              let activeRunID = scraperService.activeRunID else { return false }
        return trackedScrapeRunID == nil || trackedScrapeRunID == activeRunID
    }

    /// 给 .sheet 用 — URL 不是 Identifiable, 包一层。
    struct ExportShareItem: Identifiable {
        let id = UUID()
        let url: URL
    }

    private struct ScrapeFeedback: Identifiable {
        let id = UUID()
        let message: String
        let systemImage: String
        let color: Color
    }

    @ViewBuilder
    var body: some View {
        Group {
        #if os(macOS)
            macPlaylistDetail
        #else
            legacyPlaylistDetail
        #endif
        }
        .overlay(alignment: .bottom) {
            scrapeFeedbackToast
        }
        .songBatchActions(
            selection: selection,
            context: .playlist(id: playlist.id, allowsRemoval: allowsPlaylistRemoval),
            orderedIDs: { songs.map(\.id) },
            resolve: { library.song(id: $0) }
        )
        .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
        .sheet(isPresented: $showArtworkEditor) {
            LibraryArtworkEditorSheet(
                owner: LibraryArtworkOwner(kind: .playlist, id: playlist.id),
                title: String(localized: "artwork_editor_title"),
                songs: songs
            )
        }
        .onChange(of: scraperService.completionRevision) { _, _ in
            showScrapeCompletion()
        }
        .onChange(of: scraperService.activeRunID) { _, activeRunID in
            if scraperService.activeOriginPlaylistID == playlist.id {
                trackedScrapeRunID = activeRunID
            } else if activeRunID == nil {
                trackedScrapeRunID = nil
            }
        }
        .onAppear {
            isViewVisible = true
            if scraperService.activeOriginPlaylistID == playlist.id {
                trackedScrapeRunID = scraperService.activeRunID
            } else {
                trackedScrapeRunID = nil
            }
            showScrapeCompletion()
        }
        .onDisappear {
            isViewVisible = false
        }
    }

    private var legacyPlaylistDetail: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Playlist header
                VStack(spacing: 8) {
                    PlaylistArtworkView(
                        playlist: currentPlaylist ?? playlist,
                        size: 180,
                        cornerRadius: 14,
                        placeholderIcon: coverPlaceholderIcon
                    )

                    Text(currentPlaylist?.name ?? playlist.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("\(songs.count) \(String(localized: "songs_count"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                if isCurrentPlaylistScraping {
                    batchScrapeProgressCard
                        .padding(.horizontal)
                }

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
                        playAll(shuffled: true)
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

                alwaysDownloadControl
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
                            // 所有外部镜像歌单都只读：本地无法把删除回写到源端，
                            // 下次同步也会覆盖任何临时改动。
                            Button {
                                selection.activate(seed: song.id)
                            } label: {
                                Label("batch_select", systemImage: "checkmark.circle")
                            }

                            if allowsPlaylistRemoval {
                                Button(role: .destructive) {
                                    library.remove(songID: song.id, fromPlaylist: playlist.id)
                                } label: {
                                    Label("remove_from_playlist", systemImage: "trash")
                                }
                            }
                        }
                        .songSelectable(
                            songID: song.id,
                            selection: selection,
                            orderedIDs: { songs.map(\.id) }
                        )

                        Divider().padding(.leading, 50)
                    }
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showArtworkEditor = true
                    } label: {
                        Label("artwork_edit", systemImage: "photo.badge.plus")
                    }

                    Button {
                        if selection.isActive {
                            selection.deactivate()
                        } else {
                            selection.activate()
                        }
                    } label: {
                        Label(selection.isActive ? "done" : "batch_select",
                              systemImage: "checkmark.circle")
                    }
                    .disabled(songs.isEmpty)

                    // 镜像歌单不让用户重排 ── 下次 sync / 扫描会被覆盖,
                    // 重排白做; 普通用户歌单 + 智能歌单的衍生不在这里。
                    if !MirrorPlaylistIdentity.isMirrorPlaylist(playlist.id) {
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
                        startPlaylistScrape()
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
                    if canDeletePlaylist(playlist.id) {
                        Divider()
                        Button(role: .destructive) {
                            deleteCurrentPlaylist()
                        } label: {
                            Label("delete_playlist", systemImage: "trash")
                        }
                    } else if MirrorPlaylistIdentity.isMirrorPlaylist(playlist.id) {
                        Divider()
                        Button {
                            hideCurrentPlaylist()
                        } label: {
                            Label("hide_playlist_from_primuse", systemImage: "eye.slash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                // Do not disable the whole menu for an empty playlist. Actions
                // that require tracks already carry their own disabled state,
                // while exporting or deleting the playlist must remain usable.
                .accessibilityLabel(Text("a11y_more_actions"))
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

    private var alwaysDownloadControl: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("playlist_always_download")
                    .font(.subheadline.weight(.semibold))
                Text("playlist_always_download_description")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityHidden(true)

            Spacer(minLength: 10)

            Toggle("", isOn: alwaysDownloadBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text("playlist_always_download"))
                .accessibilityHint(Text("playlist_always_download_description"))
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12), lineWidth: 0.5)
        }
    }

    private var alwaysDownloadBinding: Binding<Bool> {
        Binding(
            get: {
                AppServices.shared.alwaysDownload.isEnabled(for: playlist.id)
            },
            set: { enabled in
                AppServices.shared.alwaysDownload.setEnabled(enabled, for: playlist.id)
            }
        )
    }

    private var batchScrapeProgressCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(batchScrapeProgressTitle)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Spacer(minLength: 8)
                Button("cancel", role: .cancel) {
                    cancelPlaylistScrape()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            ProgressView(value: scraperService.phaseProgress)
                .progressViewStyle(.linear)
                .accessibilityLabel(Text(batchScrapeProgressTitle))
                .accessibilityValue(Text(batchScrapeCountsText))

            if !scraperService.currentSongTitle.isEmpty {
                Text(scraperService.currentSongTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(batchScrapeCountsText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
    }

    private var batchScrapeProgressTitle: String {
        let key = switch scraperService.batchPhase {
        case .songs:
            "batch_scrape_song_progress_format"
        case .artwork:
            "batch_scrape_artwork_progress_format"
        }
        return String(
            format: String(localized: String.LocalizationValue(key)),
            scraperService.phaseProcessedCount,
            scraperService.phaseTotalCount
        )
    }

    private var batchScrapeCountsText: String {
        switch scraperService.batchPhase {
        case .songs:
            return String(
                format: String(localized: "batch_scrape_counts_format"),
                scraperService.updatedCount,
                scraperService.skippedCount,
                scraperService.failedCount
            )
        case .artwork:
            return String(
                format: String(localized: "batch_scrape_artwork_counts_format"),
                scraperService.artworkAvailableCount,
                scraperService.artworkUnavailableCount
            )
        }
    }

    @ViewBuilder
    private var scrapeFeedbackToast: some View {
        if let scrapeFeedback {
            HStack(spacing: 10) {
                Image(systemName: scrapeFeedback.systemImage)
                    .foregroundStyle(scrapeFeedback.color)
                Text(scrapeFeedback.message)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(scrapeFeedback.message))
        }
    }

    #if os(macOS)
    private var macPlaylistDetail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                MacLibraryHeader(
                    eyebrow: "playlist",
                    title: currentPlaylist?.name ?? playlist.name,
                    subtitle: playlistSubtitle,
                    iconSystemName: coverPlaceholderIcon,
                    coverPlaylist: currentPlaylist ?? playlist,
                    onBack: onMacInlineBack.map { onBack in
                        {
                            selection.deactivate()
                            onBack()
                        }
                    },
                    backAccessibilityIdentifier: "playlistInlineBack",
                    onPlay: { playAll() },
                    onShuffle: {
                        playAll(shuffled: true)
                    },
                    moreMenu: playlistMoreMenu
                )

                VStack(alignment: .leading, spacing: PMSpace.l) {
                    alwaysDownloadControl

                    if isCurrentPlaylistScraping {
                        batchScrapeProgressCard
                    }

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
        return "\(songs.count) \(String(localized: "songs_count")) · \(duration.formattedShort) · \(playlistKindLabel)"
    }

    /// 镜像歌单标出来源, 让用户知道这份内容为什么不可编辑。服务端镜像用音乐源
    /// 名字 (用户给它起的名, 比 "Subsonic" 更能对上号); 源已被删掉时退回通用词。
    private var playlistKindLabel: String {
        if AppleMusicLibraryService.isAppleMusicMirrorPlaylist(playlist.id) { return "Apple Music" }
        if ServerPlaylistIdentity.isMirrorPlaylist(playlist.id) {
            let owner = sourcesStore.sources.first {
                playlist.id.hasPrefix(ServerPlaylistIdentity.playlistIDPrefix(sourceID: $0.id))
            }
            return owner?.name ?? String(localized: "playlist_kind_server_mirror")
        }
        return String(localized: "tab_playlists")
    }

    @ViewBuilder
    private var macPlaylistRuleCard: some View {
        if playlist.id != MusicLibrary.likedSongsPlaylistID,
           !MirrorPlaylistIdentity.isMirrorPlaylist(playlist.id) {
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
            Text("tab_songs")
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
        let isMirror = MirrorPlaylistIdentity.isMirrorPlaylist(playlist.id)
        let canDelete = canDeletePlaylist(playlist.id)

        var middle: [MacHeaderMoreMenu.Item] = []
        middle.append(.init(icon: "photo.badge.plus", title: String(localized: "artwork_edit")) {
            showArtworkEditor = true
        })
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
            startPlaylistScrape()
        })

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
                .init(icon: "play.fill", title: String(localized: "play_all"),
                      enabled: !playable.isEmpty) { playAll() },
                .init(icon: "shuffle", title: String(localized: "shuffle"),
                      enabled: !playable.isEmpty) {
                    playAll(shuffled: true)
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
            ] : isMirror ? [
                .init(icon: "eye.slash", title: String(localized: "hide_playlist_from_primuse")) {
                    hideCurrentPlaylist()
                },
            ] : [],
        ]))
    }

    private var macSongTable: some View {
        let rows = Array(songs.enumerated())
        let playCounts = playCountsBySongID
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
                    macSongRow(song, index: index, playCount: playCounts[song.id, default: 0])
                        .songSelectable(
                            songID: song.id,
                            selection: selection,
                            orderedIDs: { songs.map(\.id) },
                            defaultAction: { playSong(song) }
                        )
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

    private func macSongRow(_ song: Song, index: Int, playCount: Int) -> some View {
        let isCurrent = player.currentSong?.id == song.id
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
                sourceID: song.sourceID, filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            .frame(width: 32, alignment: .leading)

            Text(song.title)
                .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                .foregroundStyle(isCurrent ? PMColor.brand : PMColor.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(library.artistDisplayName(for: song) ?? "—")
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
                if playCount > 0 {
                    Text("\(playCount)")
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
            Button {
                selection.activate(seed: song.id)
            } label: {
                Label("batch_select", systemImage: "checkmark.circle")
            }

            if allowsPlaylistRemoval {
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
        let h = source.type.rawValue.utf8.reduce(0) { ($0 + Int($1)) % palette.count }
        return palette[h]
    }
    #endif

    private func canDeletePlaylist(_ playlistID: String) -> Bool {
        !MirrorPlaylistIdentity.isMirrorPlaylist(playlistID)
            && playlistID != MusicLibrary.likedSongsPlaylistID
    }

    private func startPlaylistScrape() {
        switch scraperService.scrapeMissingMetadata(
            songs: songs,
            in: library,
            originPlaylistID: playlist.id
        ) {
        case let .started(runID, songCount):
            trackedScrapeRunID = runID
            showScrapeFeedback(
                String(
                    format: String(localized: "batch_scrape_started_format"),
                    songCount
                ),
                systemImage: "checkmark.circle.fill",
                color: .green
            )
        case .busy, .deferred, .empty:
            showScrapeFeedback(
                String(localized: "batch_scrape_start_failed"),
                systemImage: "exclamationmark.circle.fill",
                color: .red
            )
        case .noScraperSource:
            showNoScraperSourceAlert = true
        }
    }

    private func cancelPlaylistScrape() {
        guard isCurrentPlaylistScraping else { return }
        scraperService.cancel()
        trackedScrapeRunID = nil
        showScrapeFeedback(
            String(localized: "batch_scrape_cancelled"),
            systemImage: "xmark.circle.fill",
            color: .gray
        )
    }

    private func showScrapeCompletion() {
        guard isViewVisible,
              let completion = scraperService.consumeBatchCompletion(
                  forPlaylistID: playlist.id,
                  matching: trackedScrapeRunID
              ) else { return }
        trackedScrapeRunID = nil
        var message = String(
            format: String(localized: "batch_scrape_completed_format"),
            completion.processedSongCount,
            completion.songCount,
            completion.updatedCount,
            completion.skippedCount,
            completion.failedCount
        )
        if completion.artworkTotalCount > 0 {
            message += "\n" + String(
                format: String(localized: "batch_scrape_completed_artwork_format"),
                completion.artworkAvailableCount,
                completion.artworkTotalCount,
                completion.artworkUnavailableCount
            )
        }
        let symbol: String
        let color: Color
        let appliedCount = completion.updatedCount + completion.artworkAvailableCount
        let unavailableCount = completion.failedCount + completion.artworkUnavailableCount
        if appliedCount == 0, unavailableCount > 0 {
            symbol = "xmark.circle.fill"
            color = .red
        } else if unavailableCount > 0 {
            symbol = "exclamationmark.triangle.fill"
            color = .orange
        } else if appliedCount > 0 {
            symbol = "checkmark.circle.fill"
            color = .green
        } else {
            symbol = "info.circle.fill"
            color = .accentColor
        }
        showScrapeFeedback(message, systemImage: symbol, color: color)
    }

    private func showScrapeFeedback(
        _ message: String,
        systemImage: String,
        color: Color
    ) {
        let feedback = ScrapeFeedback(
            message: message,
            systemImage: systemImage,
            color: color
        )
        withAnimation {
            scrapeFeedback = feedback
        }
        announceScrapeFeedback(message)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard scrapeFeedback?.id == feedback.id else { return }
            withAnimation {
                scrapeFeedback = nil
            }
        }
    }

    private func announceScrapeFeedback(_ message: String) {
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: message)
        #elseif os(macOS)
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
        #endif
    }

    private func deleteCurrentPlaylist() {
        guard canDeletePlaylist(playlist.id) else { return }
        library.deletePlaylist(id: playlist.id)
        #if os(macOS)
        NotificationCenter.default.post(name: .primuseSelectPlaylists, object: nil)
        #else
        dismiss()
        #endif
    }

    private func hideCurrentPlaylist() {
        guard MirrorPlaylistIdentity.isMirrorPlaylist(playlist.id) else { return }
        library.hideMirrorPlaylist(id: playlist.id)
        #if os(macOS)
        NotificationCenter.default.post(name: .primuseSelectPlaylists, object: nil)
        #else
        dismiss()
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

    private func playAll(shuffled: Bool = false) {
        let playable = songs.filteredPlayable()
        let queue = shuffled ? playable.shuffled() : playable
        guard let first = queue.first else { return }
        if shuffled { player.shuffleEnabled = true }
        player.setQueue(queue, startAt: 0)
        Task { await player.play(song: first) }
    }

    private func playSong(_ song: Song) {
        let queue = songs.filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        player.setQueue(queue, startAt: index)
        SiriMediaInteractionDonor.donate(song: song)
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
    @Environment(MusicLibrary.self) private var library
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
                            filePath: song.filePath,
                            fileFormat: song.fileFormat
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).font(.subheadline).lineLimit(1)
                            if let artist = library.artistDisplayName(for: song) {
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
                    Text("playlist_reorder_title")
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
                Text(hasChanges
                    ? String(localized: "playlist_reorder_changed")
                    : String(localized: "playlist_reorder_hint"))
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
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(
                    library.artistDisplayName(for: song)
                        ?? String(localized: "unknown_artist")
                )
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
