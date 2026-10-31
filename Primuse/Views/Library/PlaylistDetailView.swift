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
    #if os(iOS)
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage(CollectionCoverWall.preferenceKey) private var usesCoverWallHeader = CollectionCoverWall.defaultEnabled
    #elseif os(macOS)
    @Environment(\.locale) private var locale
    @State private var tableLayout = MacSongTableLayout(scope: .playlist)
    @State private var showColumnOptions = false
    @AppStorage("playlist.mac.showNetworkNotice.v1") private var showsNetworkNotice = true
    /// 歌曲表手工分窗：页面滚到的首行 (按 SongListScrollWindow.rowStride 取整) 和表格行在页面里的起点。
    @State private var macTableFirstVisibleRow = 0
    @State private var macTableRowsTop: CGFloat = 0
    @State private var macTableRowsCache = MacTableRowsCache()
    #endif
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:工具栏按钮带上标题,收进系统溢出菜单时看得懂。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    let playlist: Playlist
    private let onMacInlineBack: (() -> Void)?

    init(playlist: Playlist, onMacInlineBack: (() -> Void)? = nil) {
        self.playlist = playlist
        self.onMacInlineBack = onMacInlineBack
    }

    @State private var exportShareItem: ExportShareItem?
    @State private var exportError: String?
    @State private var showExportFormats = false
    @State private var pendingOfflineRemoval: PlaylistOfflineRemoval?
    @State private var showsNoOfflineDownloads = false
    @State private var songOrderDraft: PlaylistSongOrderDraft?
    @State private var pendingPlaylistRemoval: PlaylistRemovalRequest?
    @State private var scrapeFeedback: ScrapeFeedback?
    @State private var showNoScraperSourceAlert = false
    @State private var showArtworkEditor = false
    @State private var trackedScrapeRunID: UUID?
    @State private var isViewVisible = false
    @State private var selection = SongSelectionModel()
    @State private var songLocation = SongListLocation()
    @State private var sortedSongsCache = PlaylistSortedSongsCache()
    /// nil = 尚未选择；空串 = 用户选择了歌单顺序，不能用默认排序覆盖。
    @AppStorage(PlaylistSongSortOrderPreference.storageKey) private var displaySortRawValue: String?
    /// 收藏的顺序就是收藏歌单的账：头部那颗心看它。
    @AppStorage(LibraryPinStorage.defaultsKey) private var favoritesRawValue = ""
    @State private var serverMediaShareTarget: ServerMediaShareTarget?
    @State private var showCopyToServer = false
    @State private var showsDescriptionEditor = false
    @State private var descriptionExpanded = false
    /// 「⋯」里点了「重命名」。
    @State private var renamingPlaylist: Playlist?
    /// 「在歌单里找歌」的输入。只筛眼前的行：播放、加入队列、导出照旧按整张歌单。
    @State private var findText = ""
    #if os(iOS)
    @State private var isFindPresented = false
    #endif

    /// 镜像歌单 (Apple Music 资料库 / 服务端曲库) 里的条目不给移除入口 —— 我们
    /// 没法把改动推回服务端，下次 sync 又会把它们带回来，视觉上就是"删了又出现"。
    private var allowsPlaylistRemoval: Bool {
        (currentPlaylist ?? playlist).allowsManualSongMembership
    }

    private var currentPlaylist: Playlist? {
        library.playlist(id: playlist.id)
    }

    /// 歌单里存着的顺序 —— 手动重排改的是它,不跟随下面的显示排序。
    private var storedSongs: [Song] {
        library.songs(forPlaylist: playlist.id)
    }

    private var isReorderingSongs: Bool { songOrderDraft != nil }

    private var reorderEntries: [MusicLibrary.PlaylistEntry] {
        guard let songOrderDraft else { return [] }
        let entries = Dictionary(
            library.entries(forPlaylist: playlist.id).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return songOrderDraft.ids.compactMap { entries[$0] }
    }

    private func beginSongReordering() {
        guard allowsPlaylistRemoval else { return }
        let entries = displayEntries
        guard entries.count > 1 else { return }
        selection.deactivate()
        songLocation.cancel()
        songOrderDraft = PlaylistSongOrderDraft(entries.map(\.id))
    }

    private func finishSongReordering() {
        defer { songOrderDraft = nil }
        guard let songOrderDraft,
              let currentPlaylist, currentPlaylist.allowsManualSongMembership,
              let order = songOrderDraft.changedOrder(
                availableIDs: Set(library.entries(forPlaylist: playlist.id).map(\.id))
              ) else { return }
        library.reorderPlaylistSongs(playlistID: playlist.id, listedOrder: order)
        displaySortRawValue = ""
    }

    private func moveDraftEntries(from offsets: IndexSet, to destination: Int) {
        let availableIDs = Set(reorderEntries.map(\.id))
        songOrderDraft?.move(
            fromOffsets: offsets,
            toOffset: destination,
            availableIDs: availableIDs
        )
    }

    /// 这张歌单发起的批量离线下载在 `SourceManager` 里的登记键。
    private var offlineBatchOwnerID: String { "playlist:" + playlist.id }

    private func toggleOfflineBatch() {
        if sourceManager.activeOfflineBatchOwnerIDs.contains(offlineBatchOwnerID) {
            sourceManager.cancelOfflineBatch(ownerID: offlineBatchOwnerID)
        } else {
            sourceManager.downloadForOffline(
                songs: sourcesStore.downloadableSongs(in: songs),
                ownerID: offlineBatchOwnerID
            )
        }
    }

    /// 界面上看到的顺序。「我喜欢」默认按添加日期倒序，其他歌单默认保持歌单顺序；
    /// 播放全部 / 加入队列 / 离线下载 / 导出也一并按看到的顺序走 —— 用户按的是
    /// 眼前这一列,不是歌单里存的那一列。
    private var songs: [Song] {
        guard let order = displaySortOrder else { return storedSongs }
        let usesPlayCounts = order.criterion == .playCount
        let key = PlaylistSortedSongsCache.Key(
            content: library.playlistContentVersion,
            playlistID: playlist.id,
            order: order,
            playCountsVersion: usesPlayCounts ? PlayHistoryStore.shared.playCountsVersion : 0
        )
        return sortedSongsCache.songs(for: key) {
            if let newestFirst = addedOrderNewestFirst {
                return newestFirst ? Array(storedSongs.reversed()) : storedSongs
            }
            let values: SongListSortValues = usesPlayCounts
                ? SongListSortValues(playCountsBySongID: playCountsBySongID)
                : .empty
            return SongListSnapshot.sortedSongs(storedSongs, order: order, sortValues: values)
        }
    }

    /// 整张歌单的行: 歌单顺序下置灰的占位留在原位; 选了别的排序时它们没有可比的
    /// 值, 统一排到最后。按加入先后排时占位也有自己的先后, 跟着整张一起倒。
    private var orderedEntries: [MusicLibrary.PlaylistEntry] {
        guard displaySortOrder != nil else { return library.entries(forPlaylist: playlist.id) }
        if let newestFirst = addedOrderNewestFirst {
            let entries = library.entries(forPlaylist: playlist.id)
            return newestFirst ? Array(entries.reversed()) : entries
        }
        let pending = library.entries(forPlaylist: playlist.id).filter {
            if case .pending = $0 { return true }
            return false
        }
        return songs.map { MusicLibrary.PlaylistEntry.song($0) } + pending
    }

    private var findQuery: LibraryFindPolicy.Query? {
        LibraryFindPolicy.query(findText)
    }

    /// 列表里的行: 在歌单里找歌时只留命中的, 顺序不变。
    private var displayEntries: [MusicLibrary.PlaylistEntry] {
        let entries = orderedEntries
        guard let query = findQuery else { return entries }
        return entries.filter { Self.entry($0, matches: query) }
    }

    private static func entry(_ entry: MusicLibrary.PlaylistEntry, matches query: LibraryFindPolicy.Query) -> Bool {
        switch entry {
        case .song(let song): LibraryFindPolicy.matches(query, song: song)
        case .pending(let pending): LibraryFindPolicy.matches(query, pending: pending)
        }
    }

    /// 多选的「全选」与连选只认眼前这一列: 找歌时就是找到的那几首。
    private var selectableSongIDs: [String] {
        guard let query = findQuery else { return songs.map(\.id) }
        return songs.filter { LibraryFindPolicy.matches(query, song: $0) }.map(\.id)
    }

    /// 输入框弹着(哪怕还没输字)也算在找: 头部让开, 结果紧挨着输入框。
    private var isFinding: Bool {
        #if os(iOS)
        isFindPresented || findQuery != nil
        #else
        findQuery != nil
        #endif
    }

    private var pendingEntryCount: Int {
        library.pendingEntryCount(forPlaylist: playlist.id)
    }

    /// 按播放次数排序和 macOS 的曲目表都要读它,所以放在平台分支之外。
    private var playCountsBySongID: [String: Int] {
        PlayHistoryStore.shared.playCountsBySongID
    }

    /// nil = 保持歌单自己的顺序。
    private var displaySortOrder: LibrarySongSortOrder? {
        PlaylistSongSortOrderPreference.resolve(
            displaySortRawValue,
            isLikedSongs: playlist.id == MusicLibrary.likedSongsPlaylistID
        )
    }

    /// 歌单里的「添加日期」指加进这张歌单的先后, 不是歌入库的日子。歌单没记每首是
    /// 哪天加的, 但加歌一律接在末尾(「我喜欢」同步来的新红心、服务端歌单也一样),
    /// 存着的顺序就是加入的先后, 最早的在前。文件夹歌单的成员按文件夹重算, 顺序与
    /// 加入无关, 仍按入库日期排 —— 新放进文件夹的歌就是那时入库的。
    /// 返回 nil = 不走这条, 照常按歌曲的值排。
    private var addedOrderNewestFirst: Bool? {
        guard let order = displaySortOrder, order.criterion == .dateAdded,
              (currentPlaylist ?? playlist).folderBinding == nil else { return nil }
        return !order.isAscending
    }

    /// 歌单菜单里放的排序维度。码率、位深、格式这些技术参数留给曲库列表 ——
    /// 在歌单里找歌靠的是名字、艺术家、专辑、什么时候加进来的、多长、哪年、听过几遍。
    private static let sortCriteria: [LibrarySongSortCriterion] = [
        .title, .artist, .album, .dateAdded, .duration, .year, .playCount,
    ]

    /// 再点一次当前维度就调头,和曲库列表的排序菜单是同一套手势。
    @ViewBuilder
    private var sortMenuOptions: some View {
        Button {
            displaySortRawValue = ""
        } label: {
            if displaySortOrder == nil {
                // 当前排序与升降序只靠图标表达；macOS 27 起菜单默认隐藏图标。
                Label("playlist_order_title", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
            } else {
                Text("playlist_order_title")
            }
        }
        if allowsPlaylistRemoval {
            Button("playlist_reorder", systemImage: "line.3.horizontal") {
                beginSongReordering()
            }
            .disabled(displayEntries.count < 2)
            .accessibilityIdentifier("playlistDetail.reorder")
        }
        Divider()
        ForEach(Self.sortCriteria, id: \.self) { criterion in
            Button {
                selectSort(criterion)
            } label: {
                if let order = displaySortOrder, order.criterion == criterion {
                    Label(criterion.label, systemImage: order.isAscending ? "arrow.up" : "arrow.down")
                        .labelStyle(.titleAndIcon)
                } else {
                    Text(verbatim: criterion.label)
                }
            }
            .accessibilityValue(Text(verbatim: sortDirectionLabel(for: criterion)))
        }
    }

    /// 选中的那一项才把升/降序念出来。走 `String(localized:)` 是因为三元里的
    /// 两个字面量要先定成 `String.LocalizationValue`,直接塞给 `Text` 会被解析成
    /// 不查表的那个重载,读出来就是键名本身。
    private func sortDirectionLabel(for criterion: LibrarySongSortCriterion) -> String {
        guard let order = displaySortOrder, order.criterion == criterion else { return "" }
        return String(localized: order.isAscending
                      ? "smart_sort_ascending" : "smart_sort_descending")
    }

    private func selectSort(_ criterion: LibrarySongSortCriterion) {
        if let order = displaySortOrder {
            displaySortRawValue = order.selecting(criterion).rawValue
        } else {
            displaySortRawValue = LibrarySongSortOrder.defaultOrder(for: criterion).rawValue
        }
    }

    /// 工具条按钮上显示当前排的是哪一项。
    private var sortMenuTitle: String {
        guard let order = displaySortOrder else {
            return String(localized: "playlist_order_title")
        }
        return order.criterion.label
    }

    /// 有一台能写歌单的音乐服务器, 而且这个歌单不是那台服务器自己的歌单。
    private var canCopyToServer: Bool {
        ServerPlaylistCopyService.hasTarget(for: playlist.id, sourcesStore: sourcesStore)
    }

    private var playlistServerMediaShareTarget: ServerMediaShareTarget? {
        guard let sourceID = songs.first?.sourceID,
              let source = sourcesStore.source(id: sourceID) else { return nil }
        return try? ServerMediaShareTargetPolicy.makeTarget(
            kind: .playlist,
            title: currentPlaylist?.name ?? playlist.name,
            songs: songs,
            source: source
        )
    }

    /// 菜单与按钮要的几个「有没有」。页面每重画一次都要问; 全是本地原始文件的歌单
    /// 碰不到能下载的歌, 每次都得把整张走完, 所以按歌单内容与音乐源配置缓存。
    private var songAvailability: PlaylistSortedSongsCache.Availability {
        let key = PlaylistSortedSongsCache.AvailabilityKey(
            content: .init(content: library.playlistContentVersion, playlistID: playlist.id),
            sources: sourcesStore.allSources
        )
        return sortedSongsCache.availability(for: key) {
            let songs = storedSongs
            #if os(iOS)
            let coverWallAvailable = CollectionCoverWall.isAvailable(for: songs)
            #else
            let coverWallAvailable = false
            #endif
            return .init(
                hasPlayable: songs.contains(where: \.isPlayable),
                hasDownloadable: sourcesStore.containsDownloadableSong(in: songs),
                supportsAlwaysDownload: Self.supportsAlwaysDownload(songs, sources: sourcesStore.sources),
                sourceIDs: Set(songs.lazy.map(\.sourceID)),
                coverWallAvailable: coverWallAvailable
            )
        }
    }

    private var supportsAlwaysDownload: Bool {
        songAvailability.supportsAlwaysDownload
    }

    private static func supportsAlwaysDownload(_ songs: [Song], sources: [MusicSource]) -> Bool {
        if songs.isEmpty { return true }
        let sourcesByID = Dictionary(
            sources.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return songs.contains { song in
            guard AutomaticOfflineSongPolicy.supports(song),
                  let source = sourcesByID[song.sourceID],
                  AutomaticOfflineDownloadPolicy.supportsSourceType(source.type) else { return false }
            // 全是本地原始文件的歌单没有「始终下载」，和单曲菜单里不出现「下载」一致。
            return OfflineDownloadActionPolicy.allowsDownload(for: song, source: source)
        }
    }

    /// 空态占位图标 ── Liked 用 heart, 其它歌单用列表图标。
    private var coverPlaceholderIcon: String {
        playlist.id == MusicLibrary.likedSongsPlaylistID ? "heart.fill" : "music.note.list"
    }

    /// 手机横屏 (纵向紧凑) 才把头部换成矮横带。Mac 没有纵向尺寸等级, 恒为 false。
    private var usesCompactHeaderLayout: Bool {
        #if os(iOS)
        heightClass.isCompact
        #else
        false
        #endif
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
        var isCompact = false
    }

    @ViewBuilder
    var body: some View {
        Group {
            if isReorderingSongs {
                inlineSongReordering
            } else {
        #if os(macOS)
                macPlaylistDetail
        #else
                legacyPlaylistDetail
        #endif
            }
        }
        #if os(macOS)
        .environment(\.songListLocation, songLocation)
        #else
        .songLocationReader(songLocation, revision: displayEntries.map(\.id))
        #endif
        .onDisappear { songLocation.cancel() }
        #if os(iOS)
        .minimalNavigationDetail()
        .librarySearchContext {
            LibrarySearchScope(title: currentPlaylist?.name ?? playlist.name, songIDs: Set(songs.map(\.id)))
        }
        #endif
        // 这两个确认框平时挂在工具栏的「⋯」上（见 playlistMoreToolbarItem）；
        // 系统竖栏的溢出菜单和 Mac 头部菜单没有本页的视图可挂，才由整页弹。
        .confirmationDialog(
            "playlist_export_choose_format",
            isPresented: Binding(
                get: { !moreMenuHostsDialogs && showExportFormats },
                set: { showExportFormats = $0 }
            ),
            titleVisibility: .visible
        ) {
            exportFormatActions
        }
        .confirmationDialog(
            String(localized: "playlist_remove_offline_confirm_title"),
            isPresented: Binding(
                get: { !moreMenuHostsDialogs && pendingOfflineRemoval != nil },
                set: { if !$0 { pendingOfflineRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingOfflineRemoval
        ) { removal in
            offlineRemovalActions(removal)
        } message: { removal in
            Text(verbatim: removal.message)
        }
        .alert("playlist_remove_offline_none", isPresented: $showsNoOfflineDownloads) {
            Button("ok", role: .cancel) {}
        }
        .playlistRenameAlert($renamingPlaylist)
        .playlistRemovalAlert($pendingPlaylistRemoval) { _ in
            #if os(macOS)
            NotificationCenter.default.post(name: .primuseSelectPlaylists, object: nil)
            #else
            dismiss()
            #endif
        }
        .sheet(isPresented: $showsDescriptionEditor) {
            PlaylistDescriptionEditor(playlist: currentPlaylist ?? playlist)
        }
        .overlay(alignment: .bottom) {
            scrapeFeedbackToast
        }
        .songBatchActions(
            selection: selection,
            context: .playlist(id: playlist.id, allowsRemoval: allowsPlaylistRemoval),
            orderedIDs: { selectableSongIDs },
            resolve: { library.song(id: $0) },
            onMoveToTop: allowsPlaylistRemoval ? { moveSongsToTop($0) } : nil
        )
        .onChange(of: findText) { _, _ in
            guard selection.isActive, !selection.isEmpty else { return }
            selection.prune(to: Set(selectableSongIDs))
        }
        .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
        .sheet(isPresented: $showArtworkEditor) {
            LibraryArtworkEditorSheet(
                owner: LibraryArtworkOwner(kind: .playlist, id: playlist.id),
                title: String(localized: "artwork_editor_title"),
                songs: songs
            )
        }
        .sheet(item: $serverMediaShareTarget) { target in
            ServerMediaShareSheet(target: target)
        }
        .sheet(isPresented: $showCopyToServer) {
            PlaylistCopyToServerSheet(playlistIDs: [playlist.id])
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
            #if DEBUG && os(iOS)
            // 编译机截图用: `PRIMUSE_DEBUG_PLAYLIST_FIND=<词>` 打开歌单就弹出搜索框并填上这个词,
            // 只写 `@` 就只弹出不填。
            if let query = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_PLAYLIST_FIND"], !query.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    isFindPresented = true
                    if query != "@" { findText = query }
                }
            }
            #endif
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
            songOrderDraft = nil
        }
    }

    private var inlineSongReordering: some View {
        let entries = reorderEntries
        return VStack(spacing: 0) {
            #if os(macOS)
            HStack(spacing: 16) {
                Text(currentPlaylist?.name ?? playlist.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Button("cancel") { songOrderDraft = nil }
                    .keyboardShortcut(.cancelAction)
                Button("done") { finishSongReordering() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, PMSpace.xxxl)
            .padding(.vertical, PMSpace.l)
            #endif
            List {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    inlineReorderRow(entry, index: index, count: entries.count)
                        .listRowSeparator(.visible)
                        .listRowBackground(Color.clear)
                        .accessibilityAction(named: Text("home_edit_move_up")) {
                            guard index > 0 else { return }
                            moveDraftEntries(from: IndexSet(integer: index), to: index - 1)
                        }
                        .accessibilityAction(named: Text("home_edit_move_down")) {
                            guard index + 1 < entries.count else { return }
                            moveDraftEntries(from: IndexSet(integer: index), to: index + 2)
                        }
                        .contextMenu {
                            Button("radio_manage_pin_top", systemImage: "arrow.up.to.line") {
                                moveDraftEntries(from: IndexSet(integer: index), to: 0)
                            }
                            .disabled(index == 0)
                        }
                }
                .onMove(perform: moveDraftEntries)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            .songRowColumnsContainer()
            #endif
        }
        .navigationTitle(currentPlaylist?.name ?? playlist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("cancel") { songOrderDraft = nil }
                    .accessibilityIdentifier("playlistDetail.reorder.cancel")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("done") { finishSongReordering() }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("playlistDetail.reorder.done")
            }
        }
        #elseif os(macOS)
        .background(PMColor.bg.ignoresSafeArea())
        #endif
    }

    private func inlineReorderRow(_ entry: MusicLibrary.PlaylistEntry, index: Int, count: Int) -> some View {
        HStack(spacing: 12) {
            switch entry {
            case .song(let song):
                SongRowView(
                    song: song,
                    isPlaying: player.currentSong?.id == song.id,
                    trackNumber: index + 1,
                    largestTrackNumber: count,
                    showsActions: false,
                    queueSwipeActionsEnabled: false,
                    context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                )
                .allowsHitTesting(false)
            case .pending(let pending):
                numberedPendingRow(pending, number: index + 1, count: count, allowsEditing: false)
                    .allowsHitTesting(false)
            }
            #if os(macOS)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            #endif
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var legacyPlaylistDetail: some View {
        // iPhone Duo 内屏横握时头部在左栏、曲目在右栏；其它设备原样单栏。
        LibraryDetailWideColumns {
            // 头部顶到屏幕上沿, 返回键和工具栏按钮浮在头部上。
            LibraryDetailTopBleedScroll(bleedsUnderTopBar: !isFinding) { topInset in
                VStack(spacing: 20) {
                    // 找歌时头部让开: 键盘弹起后剩下的那点高度全留给结果。
                    if !isFinding {
                        playlistHeader(topInset: topInset)
                            .libraryDetailMatchedHeader()

                        playlistReviewSection
                            .pmLayoutSwitchFade()
                    }

                    playlistListSections
                        .pmLayoutSwitchFade()
                }
            }
        } header: {
            VStack(spacing: 20) {
                playlistHeader()
                    .libraryDetailMatchedHeader()

                playlistReviewSection
            }
        } content: {
            VStack(spacing: 20) {
                playlistListSections
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        #if os(iOS)
        .libraryDetailFind(isPresented: $isFindPresented, text: $findText, prompt: "playlist_find_prompt")
        #endif
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { locateCurrentButton }
            #if os(iOS)
            // 找歌的输入框平时不出现, 这颗按钮把它钉到导航栏下面并聚焦。
            ToolbarItem(placement: .topBarTrailing) {
                HiddenWhileSelectingSongs(selection: selection) {
                    Button {
                        pmWithAnimation(.control) { isFindPresented = true }
                    } label: {
                        PMToolbarItemLabel("playlist_find_prompt", systemImage: "magnifyingglass", titled: verticalBarEdge != nil)
                    }
                    .disabled(songs.isEmpty && pendingEntryCount == 0)
                    .accessibilityIdentifier("playlistDetail.find")
                }
            }
            #endif
            ToolbarItem(placement: .topBarTrailing) {
                HiddenWhileSelectingSongs(selection: selection) {
                    Menu {
                        sortMenuOptions
                    } label: {
                        PMToolbarItemLabel("sort_by", systemImage: "arrow.up.arrow.down.circle", titled: verticalBarEdge != nil)
                    }
                    .disabled(songs.count < 2)
                    .accessibilityLabel(Text("sort_by"))
                    .accessibilityIdentifier("playlistDetail.sort")
                }
            }
            #if os(iOS)
            if verticalBarEdge != nil {
                // 系统竖栏(iPhone Duo):「⋯」里的动作并进系统溢出菜单,和竖栏里别的按钮收在一处。
                if #available(iOS 27.0, *) {
                    ToolbarOverflowMenu {
                        HiddenWhileSelectingSongs(selection: selection) {
                            playlistMoreMenuContent
                        }
                        SongSelectionOptionsToolbarItem(
                            selection: selection,
                            orderedIDs: { selectableSongIDs },
                            asOverflowItems: true
                        )
                    }
                }
            } else {
                playlistMoreToolbarItem
            }
            SongSelectionToolbarItems(
                selection: selection,
                orderedIDs: { selectableSongIDs },
                titled: verticalBarEdge != nil,
                includesOptions: verticalBarEdge == nil
            )
            #else
            playlistMoreToolbarItem
            #endif
        }
        .sheet(item: $exportShareItem) { item in
            ShareSheet(items: [item.url])
        }
        .alert(String(localized: "playlist_export_failed_title"),
               isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("ok", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    private var favoritePin: QuickAccessPinReference {
        QuickAccessPinReference(kind: .playlist, itemID: playlist.id)
    }

    private var isCollected: Bool {
        LibraryPinStorage.decode(favoritesRawValue).contains(favoritePin)
    }

    /// Mac 头部那颗心：和 iPhone 头部、歌单列表长按菜单里的收藏是同一件事。
    private var playlistFavorite: LibraryDetailFavoriteToggle {
        let pin = favoritePin
        let isFavorite = isCollected
        let library = library
        return LibraryDetailFavoriteToggle(isLiked: isFavorite) {
            FavoriteCollectionStore.shared.setCollected(!isFavorite, pin, library: library)
        }
    }

    /// 工具栏里那颗「⋯」。
    @ToolbarContentBuilder
    private var playlistMoreToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HiddenWhileSelectingSongs(selection: selection) {
                playlistMoreMenuButton
            }
        }
    }

    private var playlistMoreMenuButton: some View {
        Menu {
            playlistMoreMenuContent
        } label: {
            Image(systemName: "ellipsis")
        }
        // Do not disable the whole menu for an empty playlist. Actions
        // that require tracks already carry their own disabled state,
        // while exporting or deleting the playlist must remain usable.
        .accessibilityLabel(Text("a11y_more_actions"))
        // 菜单里「导出」「移除离线下载」的确认框挂在这颗「⋯」上，从按钮长出来。
        .confirmationDialog(
            "playlist_export_choose_format",
            isPresented: $showExportFormats,
            titleVisibility: .visible
        ) {
            exportFormatActions
        }
        .confirmationDialog(
            String(localized: "playlist_remove_offline_confirm_title"),
            isPresented: Binding(
                get: { pendingOfflineRemoval != nil },
                set: { if !$0 { pendingOfflineRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingOfflineRemoval
        ) { removal in
            offlineRemovalActions(removal)
        } message: { removal in
            Text(verbatim: removal.message)
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
    private var exportFormatActions: some View {
        Button { export(format: .m3u8) } label: { Text(verbatim: "M3U8") }
        Button { export(format: .json) } label: { Text(verbatim: "Primuse JSON") }
        Button("cancel", role: .cancel) {}
    }

    @ViewBuilder
    private func offlineRemovalActions(_ removal: PlaylistOfflineRemoval) -> some View {
        Button("offline_downloads_remove", role: .destructive) {
            removal.request.perform(sourceManager: sourceManager)
        }
        Button("cancel", role: .cancel) {}
    }

    /// 歌单页「⋯」菜单的内容。普通 iPhone 上是工具栏里那颗「⋯」,iPhone Duo 竖栏里并进系统溢出菜单。
    @ViewBuilder
    private var playlistMoreMenuContent: some View {
        // 最常用的三个排成顶部一行。队列两项用同一份可播放曲目,
        // 文案跟歌曲行保持一致(`insert_next`,不是更长的 `up_next`)。
        PMMenuQuickActions {
            PMMenuQuickActionButton(
                shortKey: "insert_next_short",
                fullKey: "insert_next",
                systemImage: "text.line.first.and.arrowtriangle.forward"
            ) {
                player.insertNextInQueue(songs.filteredPlayable())
            }
            .disabled(songs.filteredPlayable().isEmpty)

            PMMenuQuickActionButton(
                shortKey: "add_to_queue_short",
                fullKey: "add_to_queue",
                systemImage: "text.line.last.and.arrowtriangle.forward"
            ) {
                player.appendToQueue(songs.filteredPlayable())
            }
            .disabled(songs.filteredPlayable().isEmpty)

            Button {
                if selection.isActive {
                    selection.deactivate()
                } else {
                    selection.activate()
                }
            } label: {
                Label(selection.isActive ? LocalizedStringKey("done") : "batch_select",
                      systemImage: "checkmark.circle")
            }
            .disabled(songs.isEmpty)
        }

        Section {
            // 镜像歌单不让用户重排 ── 下次 sync / 扫描会被覆盖,
            // 重排白做; 普通用户歌单 + 智能歌单的衍生不在这里。
            if allowsPlaylistRemoval {
                Button {
                    beginSongReordering()
                } label: {
                    Label("playlist_reorder", systemImage: "arrow.up.arrow.down")
                }
                .disabled(displayEntries.count < 2)
            }
            if PlaylistDescriptionService.canEdit(currentPlaylist ?? playlist, sourcesStore: sourcesStore) {
                Button { showsDescriptionEditor = true } label: {
                    Label("library_insight_editor_summary", systemImage: "text.alignleft")
                }
            }
            PlaylistRenameButton(playlist: currentPlaylist ?? playlist) {
                renamingPlaylist = currentPlaylist ?? playlist
            }
            Button {
                showArtworkEditor = true
            } label: {
                Label("artwork_edit", systemImage: "photo.badge.plus")
            }
            Button {
                startPlaylistScrape()
            } label: {
                Label("scrape_missing_metadata", systemImage: "wand.and.stars")
            }
            .disabled(songs.isEmpty || scraperService.isScraping)
            if let target = playlistServerMediaShareTarget {
                Button {
                    serverMediaShareTarget = target
                } label: {
                    Label("server_share_action", systemImage: "link.badge.plus")
                }
            }
            if canCopyToServer {
                Button {
                    showCopyToServer = true
                } label: {
                    Label("server_playlist_copy_action", systemImage: "server.rack")
                }
                .disabled(songs.isEmpty)
            }
            Button {
                showExportFormats = true
            } label: {
                Label("export", systemImage: "square.and.arrow.up")
            }
        }

        Section {
            Button(role: .destructive) {
                prepareOfflineRemoval()
            } label: {
                Label("playlist_remove_offline_downloads", systemImage: "minus.circle")
            }
            .disabled(storedSongs.isEmpty)
        }

        if canDeletePlaylist(playlist.id) {
            Section {
                Button(role: .destructive) {
                    deleteCurrentPlaylist()
                } label: {
                    Label("delete_playlist", systemImage: "trash")
                }
            }
        }
    }

    private var playlistReviewSection: some View {
        LibraryReviewSection(
            subject: .playlist(playlist.id),
            compact: true
        )
        .padding(.horizontal)
    }

    /// 头部之下的提示与曲目表。单栏时它们与头部排在同一列里，两栏时单独成右栏。
    @ViewBuilder
    private var playlistListSections: some View {
        if !isFinding {
            if hasSongsFromUnreachableSources {
                unreachableSongsNotice
                    .padding(.horizontal)
            }

            if pendingEntryCount > 0 {
                PlaylistPendingNotice(count: pendingEntryCount)
                    .padding(.horizontal)
            }

            if supportsAlwaysDownload {
                alwaysDownloadControl
                    .padding(.horizontal)
                    .pmFadeTransition(motion: .list)
            }
        }

        let entries = displayEntries
        if entries.isEmpty, findQuery != nil {
            ContentUnavailableView.search(text: findText)
                .padding(.top, 40)
        } else {
            playlistRows(entries)
        }

        // 喜欢的播客单集不在曲库里,不进歌单本身,列在「我喜欢」最下面。
        if playlist.id == MusicLibrary.likedSongsPlaylistID, !isFinding {
            PodcastLikedEpisodesFooter(matchesSongRows: true)
        }
    }

    private func playlistRows(_ entries: [MusicLibrary.PlaylistEntry]) -> some View {
        // 歌单顺序下，已经在最前面的歌曲不再显示「置顶」。
        let topSongID = allowsPlaylistRemoval ? storedSongs.first?.id : nil
        return LazyVStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                switch entry {
                case .song(let song):
                    songRow(
                        song,
                        number: index + 1,
                        count: entries.count,
                        canMoveToTop: topSongID != nil && (song.id != topSongID || displaySortOrder != nil)
                    )
                        .songLocationRow(song.id)
                case .pending(let pending):
                    numberedPendingRow(
                        pending,
                        number: index + 1,
                        count: entries.count,
                        allowsEditing: allowsPlaylistRemoval
                    )
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                Divider().padding(.leading, 50)
            }
        }
        #if os(iOS)
        .songRowColumnsContainer()
        #endif
    }

    @ViewBuilder
    private var playlistDescription: some View {
        let text = (currentPlaylist ?? playlist).descriptionText
        if !text.isEmpty {
            Button { descriptionExpanded.toggle() } label: {
                Text(verbatim: text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(descriptionExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("playlist.description")
        }
    }

    /// 竖屏是「居中大封面 + 标题 + 计数 + 操作行」的竖排; 手机横屏纵向只剩三百多点,
    /// 同一批视图换成「左封面 + 右信息与操作」的矮横带, 曲目表才进得了首屏。
    ///
    /// 两种排布共用同一棵子树 —— `AnyLayout` 只换布局不换视图身份, 旋转时行上的
    /// 长按菜单不会被连根替换。竖屏的取值全部照抄原来的常量: 外层 8 的间距加上
    /// 计数行之后那 12 的上边距, 还原成原来「计数 → 操作行」之间的 20。
    ///
    /// `topInset`: 头部顶到屏幕上沿时状态栏加导航栏那一截, 封面墙往上铺过去, 单封面头部往下让开。
    @ViewBuilder
    private func playlistHeader(topInset: CGFloat = 0) -> some View {
        #if os(iOS)
        if let wallSongs = coverWallSongs {
            coverWallPlaylistHeader(wallSongs, topInset: topInset)
        } else {
            classicPlaylistHeader
                .padding(.top, topInset)
        }
        #else
        classicPlaylistHeader
            .padding(.top, topInset)
        #endif
    }

    #if os(iOS)
    /// 封面墙只跟随显示设置和歌曲内容；首页与列表的自选封面不改变详情页背景。
    private var coverWallSongs: [Song]? {
        guard usesCoverWallHeader, !usesCompactHeaderLayout else { return nil }
        // 能不能上墙只看歌单里的歌, 随内容缓存, 不必每次重画都把前几百首挑一遍。
        return songAvailability.coverWallAvailable ? storedSongs : nil
    }

    /// 墙面自带标题与歌曲数；下面接原来的批量刮削进度与操作行。
    private func coverWallPlaylistHeader(_ wallSongs: [Song], topInset: CGFloat) -> some View {
        VStack(spacing: 8) {
            CollectionCoverWallHeader(
                title: currentPlaylist?.name ?? playlist.name,
                subtitle: "\(wallSongs.count) \(String(localized: "songs_count"))",
                songs: wallSongs,
                nowPlaying: player.currentSong,
                wallHeight: horizontalSizeClass == .regular ? 340 : 300,
                topInset: topInset
            ) {
                EmptyView()
            }

            if isCurrentPlaylistScraping {
                batchScrapeProgressCard
                    .padding(.horizontal)
                    .pmFadeTransition(motion: .list)
            }

            playlistDescription
                .padding(.horizontal)
            playlistActionButtons
                .padding(.horizontal)
                .padding(.top, 4)
        }
    }
    #endif

    private var classicPlaylistHeader: some View {
        let compact = usesCompactHeaderLayout
        let coverSide: CGFloat = compact ? 116 : 180
        let bandLayout = compact
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 14))
            : AnyLayout(VStackLayout(spacing: 8))
        let detailAlignment: HorizontalAlignment = compact ? .leading : .center
        let detailLayout = AnyLayout(VStackLayout(alignment: detailAlignment, spacing: 8))
        let stackedTopPadding: CGFloat = compact ? 0 : 12
        let rowHorizontalPadding: CGFloat? = compact ? 0 : nil
        let titleLineLimit: Int? = compact ? 2 : nil
        let bandTopPadding: CGFloat = compact ? 10 : 20
        let bandHorizontalPadding: CGFloat = compact ? 16 : 0

        return bandLayout {
            PlaylistArtworkView(
                playlist: currentPlaylist ?? playlist,
                size: coverSide,
                cornerRadius: 14,
                placeholderIcon: coverPlaceholderIcon
            )

            detailLayout {
                VStack(alignment: detailAlignment, spacing: 8) {
                    Text(currentPlaylist?.name ?? playlist.name)
                        .font(.title2)
                        .fontWeight(.bold)
                        .lineLimit(titleLineLimit)

                    Text("\(songs.count) \(String(localized: "songs_count"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                playlistDescription
                    .padding(.horizontal, rowHorizontalPadding)

                if isCurrentPlaylistScraping {
                    batchScrapeProgressCard
                        .padding(.horizontal, rowHorizontalPadding)
                        .padding(.top, stackedTopPadding)
                        // 只让卡片自己淡入淡出: 下面就是整份曲目表, 不能在
                        // 它们共同的祖先上挂动画。
                        .pmFadeTransition(motion: .list)
                }

                playlistActionButtons
                    .padding(.horizontal, rowHorizontalPadding)
                    .padding(.top, stackedTopPadding)
            }
        }
        .padding(.top, bandTopPadding)
        .padding(.horizontal, bandHorizontalPadding)
    }

    /// Action buttons ── 主按钮"播放全部"占大头, 旁边两个紧凑图标按钮。
    /// 三按钮等分时中文 label 在 iPhone 上挤换行 / 截断, 这套 Apple Music
    /// 风格的 1+2 布局更稳。
    ///
    /// 窄栏里（iPhone Duo 两栏的左栏）或 375 点宽的手机上长文案的语言里连「播放全部」都放不下时，
    /// 主按钮只留图标，文字不折行。放得下的屏幕与原来一致。
    private var playlistActionButtons: some View {
        LibraryDetailAdaptiveActionRow(adaptsAtAnyWidth: true) {
            playlistActionButtonRow(showsPlayTitle: true)
        } reduced: {
            playlistActionButtonRow(showsPlayTitle: false)
        } minimal: {
            playlistActionButtonRow(showsPlayTitle: false)
        }
    }

    private func playlistActionButtonRow(showsPlayTitle: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                playAll()
            } label: {
                if showsPlayTitle {
                    Label("play_all", systemImage: "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                } else {
                    Label("play_all", systemImage: "play.fill")
                        .labelStyle(.iconOnly)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .prominentLabelOnAccent()
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

            let isFavorite = isCollected
            Button {
                PMHaptics.likeToggled(isLiked: !isFavorite)
                FavoriteCollectionStore.shared.setCollected(!isFavorite, favoritePin, library: library)
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.headline)
                    .frame(width: 24, height: 24)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel(Text(isFavorite ? "library_favorite_unlike" : "library_favorite_like"))
            .accessibilityAddTraits(isFavorite ? .isSelected : [])
            .accessibilityIdentifier("playlistDetail.favorite")

            if songAvailability.hasDownloadable {
                // 下着的时候同一颗键停下这一轮(#336):几千首的歌单误点了不用再杀掉 App。
                let isDownloading = sourceManager.activeOfflineBatchOwnerIDs.contains(offlineBatchOwnerID)
                Button {
                    toggleOfflineBatch()
                } label: {
                    Image(systemName: isDownloading ? "stop.circle" : "arrow.down.circle")
                        .font(.headline)
                        .frame(width: 24, height: 24)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel(Text(isDownloading ? "offline_download_stop" : "offline_download"))
            }
        }
    }

    @ViewBuilder
    private func songRow(_ song: Song, number: Int, count: Int, canMoveToTop: Bool) -> some View {
        // 「移出歌单」「置顶」挂在行自己的长按菜单里 —— 在行外面再套一层
        // contextMenu 的话，SwiftUI 只认最里面那一份，外层永远弹不出来。
        // 所有外部镜像歌单都只读：本地无法把删除回写到源端，
        // 下次同步也会覆盖任何临时改动，所以那些歌单不给这个入口。
        SongRowView(
            song: song,
            isPlaying: player.currentSong?.id == song.id,
            trackNumber: number,
            largestTrackNumber: count,
            showsActions: false,
            selection: selection,
            onRemoveFromPlaylist: allowsPlaylistRemoval
                ? { library.remove(songID: song.id, fromPlaylist: playlist.id) }
                : nil,
            onMoveToTop: canMoveToTop ? { moveSongsToTop([song.id]) } : nil,
            context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
        )
        .songSelectable(
            songID: song.id,
            selection: selection,
            orderedIDs: { selectableSongIDs },
            defaultAction: { playSong(song) }
        )
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if selection.isActive {
                selection.toggle(song.id)
            } else {
                playSong(song)
            }
        }
    }

    private func numberedPendingRow(
        _ pending: PlaylistPendingEntry,
        number: Int,
        count: Int,
        allowsEditing: Bool
    ) -> some View {
        PlaylistPendingEntryRow(
            entry: pending,
            playlistID: playlist.id,
            allowsEditing: allowsEditing,
            trackNumber: number,
            largestTrackNumber: count
        )
    }

    /// The set is empty on a network that reaches everything. During an outage
    /// the playlist's own source set (cached with its content) is intersected
    /// instead of walking every song on each redraw.
    private var hasSongsFromUnreachableSources: Bool {
        let unreachable = sourceManager.unreachablePlaybackSourceIDs
        guard !unreachable.isEmpty else { return false }
        return !unreachable.isDisjoint(with: songAvailability.sourceIDs)
    }

    private var unreachableSongsNotice: some View {
        let offersOfflineHint = supportsAlwaysDownload
            && !AppServices.shared.alwaysDownload.isEnabled(for: playlist.id)
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("playlist_unreachable_notice")
                if offersOfflineHint {
                    Text(verbatim: String(
                        format: String(localized: "playlist_unreachable_offline_hint_format"),
                        String(localized: "playlist_always_download")
                    ))
                    .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            #if os(macOS)
            Button {
                showsNetworkNotice = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("playlist_hide_network_notice"))
            #endif
        }
        .padding(14)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        #if os(macOS)
        .accessibilityElement(children: .contain)
        #else
        .accessibilityElement(children: .combine)
        #endif
    }

    private var alwaysDownloadControl: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            // 说明只留给辅助功能读：卡片里堆三句话反而抢了歌曲列表的位置。
            Text("playlist_always_download")
                .font(.subheadline.weight(.semibold))
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

    private struct PlaylistOfflineRemoval {
        let request: OfflineDownloadRemovalRequest
        let message: String
    }

    /// 「移除离线下载」: 关掉这个歌单的「始终保持离线」(开着的话), 删掉歌单里的离线下载。
    /// 还被其他开着「始终保持离线」的歌单保持着的歌留着, 删了也会被那个歌单重新下载。
    private func prepareOfflineRemoval() {
        let playlistSongs = storedSongs
        Task {
            let items = await sourceManager.offlineDownloadItems(in: playlistSongs)
            let alwaysDownload = AppServices.shared.alwaysDownload
            let turnsOffAlwaysDownload = alwaysDownload.isEnabled(for: playlist.id)
            // 别的歌单和开着「保持离线」的书保持着的歌留着。
            let otherOwners = alwaysDownload.enabledOwnerIDs.subtracting([playlist.id])
            let removable = items.filter { $0.playlistIDs.isDisjoint(with: otherOwners) }
            guard !removable.isEmpty || turnsOffAlwaysDownload else {
                showsNoOfflineDownloads = true
                return
            }
            let byteCount = removable.reduce(Int64(0)) { $0 + $1.byteCount }
            var lines: [String] = [
                removable.isEmpty
                    ? String(localized: "playlist_remove_offline_none")
                    : String(
                        format: String(localized: "playlist_remove_offline_confirm_message_format"),
                        removable.count,
                        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
                    ),
            ]
            if turnsOffAlwaysDownload {
                lines.append(String(localized: "playlist_remove_offline_turns_off_always"))
            }
            if items.count > removable.count {
                lines.append(String(
                    format: String(localized: "playlist_remove_offline_kept_format"),
                    items.count - removable.count
                ))
            }
            pendingOfflineRemoval = PlaylistOfflineRemoval(
                request: OfflineDownloadRemovalRequest(
                    songs: removable.map(\.song),
                    byteCount: byteCount,
                    playlistIDs: turnsOffAlwaysDownload ? [playlist.id] : []
                ),
                message: lines.joined(separator: "\n")
            )
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
            PlaylistFeedbackToast(
                message: scrapeFeedback.message,
                systemImage: scrapeFeedback.systemImage,
                color: scrapeFeedback.color,
                isCompact: scrapeFeedback.isCompact
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    #if os(macOS)
    private var macPlaylistDetail: some View {
        GeometryReader { geometry in
            let table = macTableRows()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    MacLibraryHeader(
                        eyebrow: "server_share_kind_playlist",
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
                        moreMenu: playlistMoreMenu,
                        favorite: playlistFavorite
                    )

                    VStack(alignment: .leading, spacing: PMSpace.l) {
                        playlistDescription
                        LibraryReviewSection(subject: .playlist(playlist.id))

                        if showsNetworkNotice && hasSongsFromUnreachableSources {
                            unreachableSongsNotice
                        }

                        if pendingEntryCount > 0 {
                            PlaylistPendingNotice(count: pendingEntryCount)
                        }

                        if isCurrentPlaylistScraping {
                            batchScrapeProgressCard
                                .pmFadeTransition(motion: .list)
                        }

                        // 设计稿: 普通歌单只有 LibraryHeader + 歌曲表。智能歌单才显示
                        // smart rule callout (放在 SmartPlaylistDetailView 里)。原来这里
                        // 给所有非 Liked/AM 歌单都套了一个 "reorder + 导出" 工具卡, 不在
                        // 设计稿里, 现在直接换成 toolbar (排序/导出/更多) 工具条。
                        macPlaylistToolbar

                        if songs.isEmpty && pendingEntryCount == 0 {
                            EmptyStateView(
                                titleKey: "no_songs",
                                descriptionKey: "no_songs_desc",
                                systemImage: "music.note.list"
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.top, 48)
                        } else if table.rows.isEmpty, findQuery != nil {
                            ContentUnavailableView.search(text: findText)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 32)
                        } else {
                            macSongTable(
                                table,
                                viewportWidth: max(0, geometry.size.width - PMSpace.xxxl * 2),
                                viewportHeight: geometry.size.height
                            )
                        }

                        if playlist.id == MusicLibrary.likedSongsPlaylistID, findQuery == nil {
                            PodcastLikedEpisodesFooter(opensEpisodes: false)
                        }
                    }
                    .padding(.horizontal, PMSpace.xxxl)
                    .padding(.top, PMSpace.l)
                }
                .padding(.bottom, 112)
                .coordinateSpace(.named(Self.macScrollContentSpace))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .songLocationScrollPosition(
                songLocation,
                revision: [AnyHashable(table.rows.map(\.id)), AnyHashable(macTableRowsTop)]
            ) { songID, viewportHeight in
                guard let index = table.rows.firstIndex(where: { $0.id == songID }) else { return nil }
                return macTableRowsTop + CGFloat(table.offsets.top(of: index))
                    + Self.macSongRowHeight / 2 - viewportHeight / 2
            }
            .onScrollGeometryChange(for: Int.self) { scroll in
                let row = table.offsets.row(at: Double(scroll.visibleRect.minY - macTableRowsTop))
                return row / SongListScrollWindow.rowStride * SongListScrollWindow.rowStride
            } action: { _, row in
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    macTableFirstVisibleRow = row
                }
            }
        }
        .background(PMColor.bg.ignoresSafeArea())
        .alert(String(localized: "playlist_export_failed_title"),
               isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("ok", role: .cancel) {}
        } message: { Text(exportError ?? "") }
    }

    private var playlistSubtitle: String {
        // 总时长与显示顺序无关, 按歌单内容缓存; 不然后台每发布一批, 几万首都要再加一遍。
        let duration = sortedSongsCache.totalDuration(
            for: .init(content: library.playlistContentVersion, playlistID: playlist.id)
        ) { storedSongs.reduce(0) { $0 + $1.duration } }
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
           allowsPlaylistRemoval {
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
                Button("playlist_reorder") { beginSongReordering() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5, weight: .medium))
                    .disabled(displayEntries.count < 2)
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
            locateCurrentButton
            Text("tab_songs")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(PMColor.textFaint)
            Spacer()
            macFindField
            Menu {
                sortMenuOptions
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(verbatim: sortMenuTitle)
                }
                .font(.system(size: 11.5, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(songs.count < 2)
            .accessibilityLabel(Text("sort_by"))
            .accessibilityIdentifier("playlistDetail.sort")
            Button {
                showColumnOptions.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .foregroundStyle(PMColor.textMuted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("songs_column_settings_ellipsis"))
            .accessibilityIdentifier("playlistDetail.columns")
            .popover(isPresented: $showColumnOptions, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("songs_view_options").font(.system(size: 13, weight: .semibold))
                    MacSongTableColumnOptions(layout: tableLayout)
                }
                .padding(16)
                .frame(width: 280)
                .background(PMColor.bg)
            }
        }
        .padding(.top, -2)
    }

    /// 空歌单没什么可找, 不放。
    @ViewBuilder
    private var macFindField: some View {
        if !songs.isEmpty || pendingEntryCount > 0 {
            MacLibraryFindField(text: $findText, prompt: "playlist_find_prompt")
        }
    }

    /// header 右上角"更多"按钮的菜单内容。播放 / 队列 / 重排 / 离线 / 导出 / 删除。
    private var playlistMoreMenu: AnyView {
        // 页面每重画一次就重建一遍菜单: 这里只判断有没有, 要用的列表等点下去再取。
        let availability = songAvailability
        let hasPlayable = availability.hasPlayable
        let canDelete = canDeletePlaylist(playlist.id)

        var middle: [MacHeaderMoreMenu.Item] = []
        let shownPlaylist = currentPlaylist ?? playlist
        if PlaylistDescriptionService.canEdit(shownPlaylist, sourcesStore: sourcesStore) {
            middle.append(.init(icon: "text.alignleft", title: String(localized: "library_insight_editor_summary")) {
                showsDescriptionEditor = true
            })
        }
        if MusicLibrary.allowsRename(shownPlaylist) {
            middle.append(.init(icon: "pencil", title: String(localized: "playlist_rename")) {
                renamingPlaylist = shownPlaylist
            })
        }
        middle.append(.init(icon: "photo.badge.plus", title: String(localized: "artwork_edit")) {
            showArtworkEditor = true
        })
        if allowsPlaylistRemoval {
            middle.append(.init(icon: "arrow.up.arrow.down", title: String(localized: "playlist_reorder"),
                                enabled: displayEntries.count >= 2) {
                beginSongReordering()
            })
        }
        if availability.hasDownloadable {
            if sourceManager.activeOfflineBatchOwnerIDs.contains(offlineBatchOwnerID) {
                middle.append(.init(icon: "stop.circle", title: String(localized: "offline_download_stop")) {
                    toggleOfflineBatch()
                })
            } else {
                middle.append(.init(icon: "arrow.down.circle", title: String(localized: "offline_download")) {
                    toggleOfflineBatch()
                })
            }
        }
        if availability.supportsAlwaysDownload {
            middle.append(.init(
                icon: alwaysDownloadBinding.wrappedValue ? "checkmark.circle.fill" : "arrow.down.circle",
                title: String(localized: "playlist_always_download")
            ) {
                alwaysDownloadBinding.wrappedValue.toggle()
            })
        }
        middle.append(.init(icon: "minus.circle", title: String(localized: "playlist_remove_offline_downloads"),
                            enabled: !storedSongs.isEmpty) {
            prepareOfflineRemoval()
        })
        middle.append(.init(
            icon: showsNetworkNotice ? "eye.slash" : "eye",
            title: String(localized: showsNetworkNotice
                          ? "playlist_hide_network_notice" : "playlist_show_network_notice")
        ) { showsNetworkNotice.toggle() })
        middle.append(.init(icon: "list.bullet.rectangle", title: String(localized: "songs_column_settings_ellipsis")) {
            showColumnOptions = true
        })
        middle.append(.init(icon: "wand.and.stars", title: String(localized: "scrape_missing_metadata"),
                            trailing: songs.count.formatted(),
                            enabled: !songs.isEmpty && !scraperService.isScraping) {
            startPlaylistScrape()
        })
        if let target = playlistServerMediaShareTarget {
            middle.append(.init(
                icon: "link.badge.plus",
                title: String(localized: "server_share_action")
            ) {
                serverMediaShareTarget = target
            })
        }
        if canCopyToServer {
            middle.append(.init(
                icon: "server.rack",
                title: String(localized: "server_playlist_copy_action"),
                enabled: !songs.isEmpty
            ) {
                showCopyToServer = true
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
                .init(icon: "play.fill", title: String(localized: "play_all"),
                      enabled: hasPlayable) { playAll() },
                .init(icon: "shuffle", title: String(localized: "shuffle"),
                      enabled: hasPlayable) {
                    playAll(shuffled: true)
                },
                .init(icon: "text.line.last.and.arrowtriangle.forward", title: String(localized: "add_to_queue"),
                      enabled: hasPlayable) { player.appendToQueue(songs.filteredPlayable()) },
                .init(icon: "text.line.first.and.arrowtriangle.forward", title: String(localized: "up_next"),
                      enabled: hasPlayable) { player.insertNextInQueue(songs.filteredPlayable()) },
            ],
            middle,
            [
                .init(icon: "square.and.arrow.up", title: String(localized: "export")) {
                    showExportFormats = true
                },
            ],
            canDelete ? [
                .init(icon: "trash", title: String(localized: "delete_playlist"),
                      isDestructive: true) { deleteCurrentPlaylist() },
            ] : [],
        ]))
    }

    /// 歌曲与待匹配条目都按当前显示顺序编号。
    private struct MacTableRow: Identifiable {
        let entry: MusicLibrary.PlaylistEntry
        let songIndex: Int
        var id: String { entry.id }
    }

    private struct MacTableRows {
        let rows: [MacTableRow]
        let songCount: Int
        let offsets: SongListScrollRowOffsets
    }

    /// 行高固定, 歌曲表才能只建页面滚到的那一段 (见 macSongTable)。
    private static let macSongRowHeight: CGFloat = 44
    private static let macPendingRowHeight: CGFloat = 60
    private static let macRowSpacing: CGFloat = 1
    private nonisolated static let macScrollContentSpace = "playlistDetail.macScrollContent"

    private static func macRowHeight(_ entry: MusicLibrary.PlaylistEntry) -> CGFloat {
        switch entry {
        case .song: macSongRowHeight
        case .pending: macPendingRowHeight
        }
    }

    /// 页面每滚过一段 (SongListScrollWindow.rowStride 行) 就重算一次页面; 整张表的行与
    /// 行高偏移只随歌单内容、排序与找歌的字变, 几万首的歌单不必每次重建。
    private final class MacTableRowsCache {
        struct Key: Equatable {
            let content: MusicLibrary.PlaylistContentVersion
            let playlistID: String
            let order: LibrarySongSortOrder?
            let playCountsVersion: UInt64
            let findText: String
        }

        private var key: Key?
        private var rows: MacTableRows?

        func rows(for key: Key, make: () -> MacTableRows) -> MacTableRows {
            if key == self.key, let rows { return rows }
            let made = make()
            self.key = key
            rows = made
            return made
        }
    }

    private func macTableRows() -> MacTableRows {
        let order = displaySortOrder
        let key = MacTableRowsCache.Key(
            content: library.playlistContentVersion,
            playlistID: playlist.id,
            order: order,
            playCountsVersion: order?.criterion == .playCount ? PlayHistoryStore.shared.playCountsVersion : 0,
            findText: findText
        )
        return macTableRowsCache.rows(for: key, make: makeMacTableRows)
    }

    private func makeMacTableRows() -> MacTableRows {
        let rows = displayEntries.enumerated().map { index, entry in
            MacTableRow(entry: entry, songIndex: index)
        }
        return MacTableRows(
            rows: rows,
            songCount: rows.count,
            offsets: SongListScrollRowOffsets(
                rowHeights: rows.lazy.map { Double(Self.macRowHeight($0.entry) + Self.macRowSpacing) }
            )
        )
    }

    /// 横向可滚的表格放在纵向滚动的页面里, 里面不能用 LazyVStack: 横向 ScrollView 给不了它
    /// 有限的高度, 每次布局都要把整张歌单逐行估一遍高度, 「我喜欢」这种上千首的歌单一点进去
    /// 主线程就卡死。这里按页面的滚动位置只建可见的一段行, 上下用占位撑出整张表的高度。
    private func macSongTable(_ table: MacTableRows, viewportWidth: CGFloat, viewportHeight: CGFloat) -> some View {
        let playCounts = playCountsBySongID
        // 已经排在歌单最前面的那首不给「置顶」。
        let topSongID = allowsPlaylistRemoval ? storedSongs.first?.id : nil
        let indexColumnWidth = MacOrdinalColumn.width(
            for: table.rows.count, minimum: 32, fontSize: 11, locale: locale
        )
        let window = SongListScrollWindow.range(
            totalCount: table.rows.count,
            firstVisibleRow: macTableFirstVisibleRow,
            viewportHeight: Double(viewportHeight),
            rowHeight: Double(Self.macSongRowHeight + Self.macRowSpacing)
        )
        return ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                if tableLayout.showsHeader {
                    MacSongTableHeader(
                        layout: tableLayout, ordinalWidth: indexColumnWidth,
                        isSelectionActive: selection.isActive, sortOrder: displaySortOrder,
                        sortableCriteria: Set(Self.sortCriteria),
                        onSort: selectSort
                    )
                    .padding(.horizontal, MacSongTableLayout.horizontalPadding)
                    .padding(.vertical, 8)
                    Rectangle().fill(PMColor.divider).frame(height: 0.5)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .frame(height: CGFloat(table.offsets.top(of: window.lowerBound)))
                        .accessibilityHidden(true)

                    ForEach(table.rows[window]) { row in
                        Group {
                            switch row.entry {
                            case .song(let song):
                                macSongRow(
                                    song,
                                    index: row.songIndex,
                                    indexColumnWidth: indexColumnWidth,
                                    playCount: playCounts[song.id, default: 0],
                                    canMoveToTop: topSongID != nil && (song.id != topSongID || displaySortOrder != nil)
                                )
                                    .songLocationRow(song.id)
                                    .songSelectable(
                                        songID: song.id,
                                        selection: selection,
                                        orderedIDs: { selectableSongIDs },
                                        defaultAction: { playSong(song) }
                                    )
                            case .pending(let pending):
                                HStack(spacing: 12) {
                                    Text(row.songIndex + 1, format: .number.grouping(.never))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(PMColor.textFaint)
                                        .frame(width: indexColumnWidth, alignment: .leading)
                                    PlaylistPendingEntryRow(
                                        entry: pending,
                                        playlistID: playlist.id,
                                        allowsEditing: allowsPlaylistRemoval
                                    )
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                            }
                        }
                        .frame(height: Self.macRowHeight(row.entry))
                        .padding(.bottom, Self.macRowSpacing)
                    }

                    Color.clear
                        .frame(height: CGFloat(table.offsets.totalHeight - table.offsets.top(of: window.upperBound)))
                        .accessibilityHidden(true)
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(Self.macScrollContentSpace)).minY
                } action: { top in
                    guard abs(macTableRowsTop - top) > 0.5 else { return }
                    macTableRowsTop = top
                }
                .padding(.vertical, 4)
            }
            .frame(width: tableLayout.contentWidth(ordinalWidth: indexColumnWidth) + MacSongTableLayout.horizontalPadding * 2,
                   alignment: .leading)
        }
        .frame(width: viewportWidth, alignment: .leading)
        .defaultScrollAnchor(.topLeading, for: .alignment)
    }

    private func macSongRow(
        _ song: Song,
        index: Int,
        indexColumnWidth: CGFloat,
        playCount: Int,
        canMoveToTop: Bool
    ) -> some View {
        let isCurrent = player.currentSong?.id == song.id
        let columns = tableLayout.activeColumns
        let source = columns.contains(.source)
            ? sourcesStore.sources.first(where: { $0.id == song.sourceID })
            : nil
        return HStack(spacing: 12) {
            MacPlaylistSelectionIndexCell(
                index: index,
                isCurrent: isCurrent,
                isSelectionActive: selection.isActive,
                membership: selection.membership(for: song.id)
            )
            .frame(
                width: indexColumnWidth,
                alignment: selection.isActive ? .center : .leading
            )

            MacPlaylistSongCells(
                song: song,
                isEmphasized: isCurrent,
                liked: library.isLiked(songID: song.id),
                plays: playCount,
                artistName: columns.contains(.artist) ? library.artistDisplayName(for: song) : nil,
                sourceName: source.map {
                    $0.name.components(separatedBy: "·").first?
                        .trimmingCharacters(in: .whitespaces) ?? $0.name
                },
                sourceDotColor: source.map { macSourceDotColor(for: $0) },
                columns: columns,
                columnWidths: Dictionary(uniqueKeysWithValues: columns.map { ($0, tableLayout.width($0)) })
            )
            .equatable()
        }
        .frame(width: tableLayout.contentWidth(ordinalWidth: indexColumnWidth), alignment: .leading)
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

            if canMoveToTop {
                Button {
                    moveSongsToTop([song.id])
                } label: {
                    Label("radio_manage_pin_top", systemImage: "arrow.up.to.line")
                }
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

    private struct MacPlaylistSelectionIndexCell: View {
        @Environment(\.locale) private var locale
        let index: Int
        let isCurrent: Bool
        let isSelectionActive: Bool
        let membership: SongSelectionMembership

        var body: some View {
            // 过渡自带曲线, 并且只在这一格里做 —— 进出多选态时整张表的每一行
            // 都会经过这里, 不能靠外层包一次事务来驱动。
            ZStack {
                if isSelectionActive {
                    SongSelectionCheckmark(isSelected: membership.isSelected)
                        .pmFadeTransition(motion: .list)
                } else {
                    Text(verbatim: (index + 1).formatted(.number.locale(locale)))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? PMColor.brand : PMColor.textFaint)
                        .pmFadeTransition(motion: .list)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    /// 用源类型 hash 出稳定彩色点 (跟 sidebar 同算法)。
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

    /// 置顶同时恢复歌单顺序，让刚移动的歌曲立即出现在顶部。
    private func moveSongsToTop(_ songIDs: [String]) {
        let resetsDisplayOrder = displaySortOrder != nil
        let moved = library.moveSongsToTop(songIDs, inPlaylist: playlist.id)
        guard moved || resetsDisplayOrder else { return }
        if resetsDisplayOrder {
            displaySortRawValue = ""
        }
        let message = songIDs.count == 1
            ? String(localized: "playlist_moved_to_top_one")
            : String(format: String(localized: "playlist_moved_to_top_format"), songIDs.count)
        showScrapeFeedback(message, systemImage: "checkmark", color: .accentColor, isCompact: true)
    }

    private func canDeletePlaylist(_ playlistID: String) -> Bool {
        playlistID != MusicLibrary.likedSongsPlaylistID
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
        color: Color,
        isCompact: Bool = false
    ) {
        let feedback = ScrapeFeedback(
            message: message,
            systemImage: systemImage,
            color: color,
            isCompact: isCompact
        )
        pmWithAnimation(.list) {
            scrapeFeedback = feedback
        }
        announceScrapeFeedback(message)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(isCompact ? 2 : 4))
            guard scrapeFeedback?.id == feedback.id else { return }
            pmWithAnimation(.list) {
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
        pendingPlaylistRemoval = PlaylistRemovalRequest(playlists: [currentPlaylist ?? playlist])
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

    private var locateCurrentButton: some View {
        LocateCurrentSongButton(
            isEditing: selection.isActive || isReorderingSongs,
            titled: verticalBarEdge != nil,
            contains: { id in songs.contains { $0.id == id } },
            isVisible: { id in
                displayEntries.contains { entry in
                    if case .song(let song) = entry { return song.id == id }
                    return false
                }
            }
        ) { songID, clearsFilters in
            if clearsFilters {
                findText = ""
                #if os(iOS)
                isFindPresented = false
                #endif
            }
            songLocation.locate(songID)
        }
    }

    private func playAll(shuffled: Bool = false) {
        let playable = songs.filteredPlayable()
        let queue = shuffled ? player.shufflePlayOrder(playable) : playable
        guard !queue.isEmpty else { return }
        if shuffled { player.shuffleEnabled = true }
        SiriMediaInteractionDonor.donate(.playlist(id: playlist.id), shuffled: shuffled)
        Task { await player.play(queue: queue, startingAt: 0) }
    }

    private func playSong(_ song: Song) {
        let queue = songs.filteredPlayable()
        guard let index = queue.firstIndex(where: { $0.id == song.id }) else { return }
        // 从歌单里点一首也是在放这个歌单, 捐歌单而不是这一首。
        SiriMediaInteractionDonor.donate(.playlist(id: playlist.id), shuffled: false)
        Task { await player.play(queue: queue, startingAt: index) }
    }
}

struct PlaylistSongOrderDraft {
    private let initialIDs: [String]
    private(set) var ids: [String]

    init(_ ids: [String]) {
        self.initialIDs = ids
        self.ids = ids
    }

    mutating func move(fromOffsets offsets: IndexSet, toOffset destination: Int, availableIDs: Set<String>) {
        ids.removeAll { !availableIDs.contains($0) }
        guard !offsets.isEmpty,
              offsets.allSatisfy({ ids.indices.contains($0) }),
              (0...ids.count).contains(destination) else { return }
        ids.move(fromOffsets: offsets, toOffset: destination)
    }

    func changedOrder(availableIDs: Set<String>) -> [String]? {
        let currentIDs = ids.filter { availableIDs.contains($0) }
        let startingIDs = initialIDs.filter { availableIDs.contains($0) }
        return currentIDs != startingIDs ? currentIDs : nil
    }
}

// MARK: - Playlist Reorder Sheet

/// 拖拽重排歌单内歌曲顺序。用 List + ForEach.onMove (SwiftUI 原生拖动; iOS 开
/// EditMode 显示手柄, Mac 上整行按住即可拖、右键可置顶), 完成后回调把新顺序
/// 传出去, parent 调 library.replacePlaylistSongs 写回 + sync。Apple Music 镜像
/// 歌单不进这里 (PlaylistDetailView 已经 disable 重排入口)。
struct PlaylistReorderSheet: View {
    /// 歌单名;本地播客节目调单集顺序时是节目名。
    let name: String
    let initialSongs: [Song]
    let onDone: ([Song]) -> Void
    /// Mac 头部名字后面的数量:「12 首」「12 集」。
    private let countLabel: String
    private let hintKey: String.LocalizationValue

    @Environment(\.dismiss) private var dismiss
    @Environment(MusicLibrary.self) private var library
    #if os(macOS)
    @Environment(\.locale) private var locale
    @Environment(SourceManager.self) private var sourceManager
    #endif
    @State private var localSongs: [Song]

    init(playlist: Playlist, songs: [Song], onDone: @escaping ([Song]) -> Void) {
        self.init(
            name: playlist.name,
            countLabel: "\(songs.count) \(String(localized: "songs_count"))",
            hintKey: "playlist_reorder_hint",
            songs: songs,
            onDone: onDone
        )
    }

    init(
        name: String,
        countLabel: String,
        hintKey: String.LocalizationValue,
        songs: [Song],
        onDone: @escaping ([Song]) -> Void
    ) {
        self.name = name
        self.countLabel = countLabel
        self.hintKey = hintKey
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
                ForEach(Array(localSongs.enumerated()), id: \.element.id) { index, song in
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
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                SongRowTrackNumber(number: index + 1, largestNumber: localSongs.count)
                                Text(song.title).font(.subheadline).lineLimit(1)
                            }
                            if let artist = library.artistDisplayName(for: song) {
                                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 8)
                        // 上千首的歌单里把一首拖到最上面要拖很久，每行给一颗「置顶」。
                        if localSongs.first?.id != song.id {
                            Button {
                                moveSongToTop(song.id)
                            } label: {
                                Image(systemName: "arrow.up.to.line")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 32, height: 32)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(Text("radio_manage_pin_top"))
                        }
                    }
                    .accessibilityAction(named: Text("radio_manage_pin_top")) {
                        moveSongToTop(song.id)
                    }
                }
                .onMove { from, to in
                    localSongs.move(fromOffsets: from, toOffset: to)
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .navigationTitle(name)
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

    private func moveSongToTop(_ songID: String) {
        guard let index = localSongs.firstIndex(where: { $0.id == songID }), index > 0 else { return }
        pmWithAnimation(.list) {
            let item = localSongs.remove(at: index)
            localSongs.insert(item, at: 0)
        }
    }

    #if os(macOS)
    private var macBody: some View {
        let ordinalWidth = MacOrdinalColumn.width(
            for: localSongs.count, minimum: 26, fontSize: 11, locale: locale
        )
        return VStack(spacing: 0) {
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
                    Text(verbatim: "\(name) · \(countLabel)")
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

            // 原生 List 的拖动排序:插入线、拖到边缘自动滚动都由系统负责,
            // 上千首的歌单也能一次拖到位。
            List {
                ForEach(Array(localSongs.enumerated()), id: \.element.id) { index, song in
                    macSongRow(song, index: index, ordinalWidth: ordinalWidth)
                        .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .onMove { from, to in
                    localSongs.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.vertical, 10, for: .scrollContent)

            Rectangle().fill(PMColor.divider).frame(height: 0.5)

            HStack {
                Text(hasChanges
                    ? String(localized: "playlist_reorder_changed")
                    : String(localized: hintKey))
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
                    .keyboardShortcut(.cancelAction)
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
                .keyboardShortcut(.defaultAction)
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

    private func macSongRow(_ song: Song, index: Int, ordinalWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
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
                SongRowNumberedTitle(number: index + 1, title: song.title)
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

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(PMColor.bgElev.opacity(0.84), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
        }
        .contentShape(.rect(cornerRadius: 10))
        .help(Text("Drag to Reorder"))
        .contextMenu {
            Button("radio_manage_pin_top", systemImage: "arrow.up.to.line") {
                moveSong(from: index, to: 0)
            }
            .disabled(index == 0)
        }
        .accessibilityAction(named: Text("home_edit_move_up")) {
            moveSong(from: index, to: index - 1)
        }
        .accessibilityAction(named: Text("home_edit_move_down")) {
            moveSong(from: index, to: index + 1)
        }
        // 拖起的行可能被搬进独立的预览宿主渲染, 封面要读的两个模型显式带上。
        .environment(library)
        .environment(sourceManager)
    }

    private func moveSong(from source: Int, to destination: Int) {
        guard localSongs.indices.contains(source), localSongs.indices.contains(destination),
              source != destination else { return }
        pmWithAnimation(.list) {
            let item = localSongs.remove(at: source)
            localSongs.insert(item, at: destination)
        }
    }
    #endif
}

#if os(macOS)
/// 歌单表格一行里封面与各列的格子, 同歌曲页的 `MacSongTableRowContent`: 父视图每重算
/// 一次, 只有输入真变了的行重建。
private struct MacPlaylistSongCells: View, Equatable {
    let song: Song
    let isEmphasized: Bool
    let liked: Bool
    let plays: Int
    let artistName: String?
    let sourceName: String?
    let sourceDotColor: Color?
    let columns: [MacSongsColumn]
    let columnWidths: [MacSongsColumn: CGFloat]

    var body: some View {
        HStack(spacing: 12) {
            CachedArtworkView(
                coverRef: song.coverArtFileName, songID: song.id,
                size: 28, cornerRadius: 4,
                sourceID: song.sourceID, filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            .frame(width: 32, alignment: .leading)

            ForEach(columns) { column in
                cell(column)
                    .frame(width: columnWidths[column] ?? 0, alignment: column.alignment)
            }
        }
    }

    @ViewBuilder
    private func cell(_ column: MacSongsColumn) -> some View {
        Group {
            switch column {
            case .title:
                HStack(spacing: 6) {
                    Text(song.title)
                        .font(.system(size: 12.5, weight: isEmphasized ? .semibold : .medium))
                        .foregroundStyle(isEmphasized ? PMColor.brand : PMColor.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if liked {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(PMColor.brand)
                    }
                }
            case .artist:
                Text(artistName ?? "—")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            case .album:
                Text(song.albumTitle ?? "—")
                    .font(.system(size: 12.5))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            case .format:
                HStack(spacing: 6) {
                    PMFormatPill.forFormat(song.codecFormat.displayName)
                    if let sampleRate = song.formattedSampleRate {
                        Text(verbatim: sampleRate)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(PMColor.textFaint)
                    }
                }
            case .duration:
                Text(song.duration.formattedDuration)
                    .font(.system(size: 11.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.textMuted)
            case .plays:
                playCountText(plays)
            case .sourcePlays:
                playCountText(song.serverPlayCount ?? 0)
            case .downloaded:
                MacSongTableDownloadIndicator(song: song)
            case .source:
                sourceCell
            case .year:
                Text(song.year.map(String.init) ?? "—")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(PMColor.textMuted)
            case .rating:
                Text(verbatim: "—")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
            case .dateAdded:
                Text(song.dateAdded, style: .date)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            case .bitRate:
                Text(song.formattedBitRate ?? "—")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(PMColor.textMuted)
            case .bitDepth:
                Text(song.formattedBitDepth ?? "—")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(PMColor.textMuted)
            }
        }
    }

    @ViewBuilder
    private func playCountText(_ plays: Int) -> some View {
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

    private var sourceCell: some View {
        HStack(spacing: 5) {
            if let sourceName {
                Circle()
                    .fill(sourceDotColor ?? PMColor.textFaint)
                    .frame(width: 6, height: 6)
                Text(verbatim: sourceName)
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
    }
}
#endif

/// 选了排序维度时, 歌单页一次重绘要读好几遍排好序的歌; 每读一遍都整份重排。
/// 按歌单内容、排序方式和播放次数的版本记住。
private final class PlaylistSortedSongsCache {
    struct Key: Equatable {
        let content: MusicLibrary.PlaylistContentVersion
        let playlistID: String
        let order: LibrarySongSortOrder
        let playCountsVersion: UInt64
    }

    struct ContentKey: Equatable {
        let content: MusicLibrary.PlaylistContentVersion
        let playlistID: String
    }

    struct AvailabilityKey: Equatable {
        let content: ContentKey
        let sources: [MusicSource]
    }

    struct Availability {
        let hasPlayable: Bool
        let hasDownloadable: Bool
        let supportsAlwaysDownload: Bool
        /// 歌单里的歌来自哪几个源。
        let sourceIDs: Set<String>
        /// 头图能不能用封面墙(只有 iOS 用)。
        let coverWallAvailable: Bool
    }

    private var key: Key?
    private var cached: [Song] = []
    private var durationKey: ContentKey?
    private var cachedDuration: TimeInterval = 0
    private var availabilityKey: AvailabilityKey?
    private var cachedAvailability: Availability?

    func songs(for key: Key, make: () -> [Song]) -> [Song] {
        if key == self.key { return cached }
        cached = make()
        self.key = key
        return cached
    }

    func availability(for key: AvailabilityKey, make: () -> Availability) -> Availability {
        if key == availabilityKey, let cachedAvailability { return cachedAvailability }
        let made = make()
        availabilityKey = key
        cachedAvailability = made
        return made
    }

    func totalDuration(for key: ContentKey, make: () -> TimeInterval) -> TimeInterval {
        if key == durationKey { return cachedDuration }
        cachedDuration = make()
        durationKey = key
        return cachedDuration
    }
}

struct PlaylistFeedbackToast: View {
    let message: String
    let systemImage: String
    let color: Color
    var isCompact = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text(message)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: isCompact ? nil : 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: isCompact ? 24 : 12))
        .overlay {
            RoundedRectangle(cornerRadius: isCompact ? 24 : 12)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(isCompact ? 0.08 : 0.12), radius: 10, y: 3)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(message))
    }
}

private struct PlaylistDescriptionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(MusicLibrary.self) private var library
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    let playlist: Playlist
    @State private var text: String
    @State private var saving = false
    @State private var errorMessage: String?

    init(playlist: Playlist) {
        self.playlist = playlist
        _text = State(initialValue: playlist.descriptionText)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(playlist.name).font(.headline)
                TextEditor(text: $text)
                    .frame(minHeight: 180)
                    .accessibilityLabel(Text("library_insight_editor_summary"))
                if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout) }
            }
            .padding()
            .navigationTitle("library_insight_editor_summary")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("save") {
                        saving = true
                        errorMessage = nil
                        Task {
                            do {
                                try await PlaylistDescriptionService.save(text, playlist: playlist, library: library,
                                    sourcesStore: sourcesStore, sourceManager: sourceManager)
                                dismiss()
                            } catch {
                                errorMessage = SourceErrorPresentation.userFacingDescription(error)
                            }
                            saving = false
                        }
                    }.disabled(saving)
                }
            }
            .interactiveDismissDisabled(saving)
        }
        #if os(macOS)
        .frame(width: 520, height: 360)
        #endif
    }
}
