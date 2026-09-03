import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#endif

struct SongRowView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    /// Used only inside `deleteSong` (not read in `body`) so it doesn't
    /// register as a body-time observation dependency. Keeping this as
    /// `@Environment` lets us update the source badge count without
    /// drilling through callbacks at every call site.
    @Environment(SourcesStore.self) private var sourcesStore

    let song: Song
    var isPlaying: Bool = false
    var showAlbum: Bool = true
    var showsActions: Bool = true

    /// Source badge — only shown when the parent decides multiple sources
    /// exist and resolves the song's source. Passing `nil` hides the badge
    /// without the row needing to observe `SourcesStore` (which would
    /// otherwise invalidate every visible row whenever any source mutates).
    var sourceName: String? = nil
    var sourceIconName: String? = nil
    var canDeleteSourceFile = false

    /// 非 nil 时由外层列表接管长按，直接进入多选并选中这一行。
    var selection: SongSelectionModel? = nil

    /// Resolved by the parent so rows do not individually observe every
    /// backfill state mutation.
    var detailsState: SongDetailsState = .ready

    @State private var showScrapeOptions = false
    @State private var showNoScraperSourceAlert = false
    @State private var showAddToPlaylist = false
    @State private var showSongInfo = false
    @State private var showDeleteConfirm = false
    @State private var showBareAlert = false
    @State private var showTagEditor = false
    /// 歌词编辑跟标签编辑平级；iOS 全屏打开，避免长文本编辑时误滑关闭。
    @State private var showLyricsEditor = false
    /// 标签编辑器翻页到的那一首。nil 表示还停在本行这首歌上。
    @State private var tagEditorSongID: String?
    @State private var showSimilarSongs = false
    @State private var deleteErrorMessage: String?
    @State private var sourceCheckMessage: String?
    @State private var tagReadMessage: String?
    @State private var presentedShareSong: Song?

    /// "Metadata still pending" — cloud Phase-A songs whose `duration` (and
    /// usually cover/artist) hasn't been backfilled yet. Drives a soft dim +
    /// "loading / details unavailable" subtitle. These songs ARE playable now
    /// (the player resolves duration on play), so this no longer blocks taps.
    /// 独立 MV 不算 bare —— 时长常由播放时 AVPlayer 回填, 元数据本来就薄,
    /// 不该顶着"读取中/详情不可用"的置灰样式。
    private var showsDetailsStatus: Bool { detailsState != .ready }
    private var isReadingDetails: Bool { detailsState == .reading }
    private var offlineSnapshot: OfflineAudioCacheSnapshot {
        guard supportsOfflineAudioCache else { return .notCached }
        return sourceManager.offlineAudioSnapshotEntry(for: song).snapshot
    }

    var body: some View {
        let offline = offlineSnapshot

        HStack(spacing: 10) {
            // Cover art with playing overlay
            ZStack {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 44, cornerRadius: 6,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )

                if isPlaying {
                    Color.black.opacity(0.35)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .frame(width: 44, height: 44)
                    // While the player is still loading the active track,
                    // show a spinner instead of the playing-waveform so the
                    // user can tell "tap registered, audio is on the way"
                    // from "audio is actually playing".
                    if player.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "waveform")
                            .font(.caption)
                            .symbolEffect(.variableColor.iterative)
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .opacity(isReadingDetails ? 0.65 : 1)

            // Song info — title and subtitle only, no format/duration clutter
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                    .opacity(isReadingDetails ? 0.75 : 1)

                HStack(spacing: 4) {
                    if showsDetailsStatus {
                        switch detailsState {
                        case .reading:
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 12, height: 12)
                            if backfill.isDeferredRetry(songID: song.id) {
                                Text("backfill_retry_in_progress")
                            } else {
                                Text("backfill_in_progress")
                            }
                        case .waitingForSource:
                            Image(systemName: "wifi.exclamationmark")
                                .font(.caption2)
                            Text("song_details_waiting_source")
                        case .playableIncomplete:
                            Image(systemName: "info.circle")
                                .font(.caption2)
                            Text("song_details_incomplete")
                        case .confirmedFailure:
                            Image(systemName: "exclamationmark.circle")
                                .font(.caption2)
                            Text("song_details_parse_failed")
                        case .ready:
                            EmptyView()
                        }
                        if let sourceName {
                            Text("·")
                            if let sourceIconName {
                                Image(systemName: sourceIconName)
                            }
                            Text(sourceName)
                        }
                    } else {
                        if song.isStandaloneMusicVideo {
                            Image(systemName: "play.rectangle.fill")
                                .font(.caption2)
                                .accessibilityLabel(Text("music_video_badge"))
                        }
                        if let artist = library.artistDisplayName(for: song) {
                            if song.isStandaloneMusicVideo { Text("·") }
                            Text(artist)
                        }
                        if showAlbum, let album = song.albumTitle {
                            Text("·")
                            Text(album)
                        }
                        // 独立 MV 时长可能尚未回填, 不显示 0:00
                        if song.duration > 0 {
                            Text("·")
                            Text(formatDuration(song.duration))
                                .monospacedDigit()
                        }
                        if let sourceName {
                            Text("·")
                            if let sourceIconName {
                                Image(systemName: sourceIconName)
                            }
                            Text(sourceName)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            OfflineAudioStatusBadge(snapshot: offline)

            if showsActions {
                Menu {
                    // Group 1: Actions
                    Section {
                        Button {
                            requestScrape(from: .songRowActionMenu)
                        } label: {
                            Label(String(localized: "scrape_song"), systemImage: "wand.and.stars")
                        }

                        Button {
                            showTagEditor = true
                        } label: {
                            Label(String(localized: "tag_editor_menu"), systemImage: "tag")
                        }

                        Button {
                            showLyricsEditor = true
                        } label: {
                            Label(String(localized: "lyrics_editor_menu"), systemImage: "quote.bubble")
                        }

                        Button {
                            showAddToPlaylist = true
                        } label: {
                            Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
                        }

                        Button {
                            showSimilarSongs = true
                        } label: {
                            Label(String(localized: "similar_songs"), systemImage: "sparkles")
                        }

                        if supportsOfflineAudioCache {
                            offlineActionButtons(snapshot: offline)
                        }

                        metadataRecoveryButtons()

                        Button {
                            showSongInfo = true
                        } label: {
                            Label(String(localized: "song_info"), systemImage: "info.circle")
                        }
                    }

                    // Group 2: Share
                    Section {
                        Button {
                            presentedShareSong = song
                        } label: {
                            Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                        }
                    }

                    if canDeleteSourceFile {
                        // Group 3: Destructive
                        Section {
                            Button(role: .destructive) {
                                showDeleteConfirm = true
                            } label: {
                                Label(String(localized: "delete_song"), systemImage: "trash")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("a11y_more_actions")
            }
        }
        .songRowSwipeActions(
            songID: song.id,
            isEnabled: song.isPlayable && selection?.isActive != true,
            onInsertNext: { player.insertNextInQueue([song]) },
            onAppendToQueue: { player.appendToQueue([song]) }
        )
        .contentShape(Rectangle())
        .task(id: song.id) {
            guard supportsOfflineAudioCache else { return }
            await sourceManager.ensureOfflineAudioSnapshot(for: song)
        }
        // VoiceOver 把整行合并成一个可选元素,读出来 "歌名,艺术家"。
        // 支持多选的 iOS 列表由 SongSelectable 提供命名选择动作；其余页面
        // 仍可通过 contextMenu 使用单曲操作。
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            [song.title, library.artistDisplayName(for: song)]
                .compactMap { $0 }
                .joined(separator: " — ")
        ))
        // Only songs with nothing to play (no path and no duration) intercept
        // taps with a hint; metadata-pending cloud songs stay tappable and
        // play — the player resolves their duration on the fly.
        .overlay {
            if !song.isPlayable {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { showBareAlert = true }
            }
        }
        .alert(
            detailsAlertTitle,
            isPresented: $showBareAlert
        ) {
            Button(String(localized: "done"), role: .cancel) {}
        } message: {
            Text(detailsAlertMessage)
        }
        .songRowContextMenu(isEnabled: usesContextMenu) {
            if let selection {
                Section {
                    Button {
                        selection.activate(seed: song.id)
                    } label: {
                        Label(String(localized: "batch_select"), systemImage: "checkmark.circle")
                    }
                }
            }

            // Group 1: Actions
            Section {
                Button {
                    requestScrape(from: .songRowContextMenu)
                } label: {
                    Label(String(localized: "scrape_song"), systemImage: "wand.and.stars")
                }

                Button {
                    showTagEditor = true
                } label: {
                    Label(String(localized: "tag_editor_menu"), systemImage: "tag")
                }

                Button {
                    showLyricsEditor = true
                } label: {
                    Label(String(localized: "lyrics_editor_menu"), systemImage: "quote.bubble")
                }

                Button {
                    showAddToPlaylist = true
                } label: {
                    Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
                }

                Button {
                    showSimilarSongs = true
                } label: {
                    Label(String(localized: "similar_songs"), systemImage: "sparkles")
                }

                if supportsOfflineAudioCache {
                    offlineActionButtons(snapshot: offline)
                }

                metadataRecoveryButtons()

                Button {
                    showSongInfo = true
                } label: {
                    Label(String(localized: "song_info"), systemImage: "info.circle")
                }
            }

            // Group 2: Share
            Section {
                Button {
                    presentedShareSong = song
                } label: {
                    Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                }
            }

            if canDeleteSourceFile {
                // Group 3: Destructive
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label(String(localized: "delete_song"), systemImage: "trash")
                    }
                }
            }
        }
        .sheet(isPresented: $showScrapeOptions) {
            ScrapeOptionsView(song: song) { updated in
                CachedArtworkView.invalidateCache(for: updated.id)
                if let oldRef = song.coverArtFileName {
                    CachedArtworkView.invalidateCache(for: oldRef)
                }
            }
            // 与 NowPlayingView 一致 — medium 半屏会把"自动/手动刮削"按钮和
            // 搜索数量 picker 挤到下方,用户不知道要上滑会以为功能消失。
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showTagEditor, onDismiss: { tagEditorSongID = nil }) {
            TagEditorView(
                song: tagEditorSong,
                queue: tagEditorQueue,
                onNavigate: { tagEditorSongID = $0.id }
            )
            .presentationDetents([.large])
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $showLyricsEditor) {
            LyricsEditorSheet(song: library.song(id: song.id) ?? song) { updated in
                player.syncSongMetadata(updated)
            }
        }
        #else
        .sheet(isPresented: $showLyricsEditor) {
            LyricsEditorSheet(song: library.song(id: song.id) ?? song) { updated in
                player.syncSongMetadata(updated)
            }
            .presentationDetents([.large])
        }
        #endif
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(song: song)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $presentedShareSong) { sharedSong in
            SongShareSheet(song: sharedSong)
        }
        .similarSongsPanel(isPresented: $showSimilarSongs, seed: song)
        .sheet(isPresented: $showSongInfo) {
            SongInfoSheet(song: song)
                .songInfoPresentationStyle()
        }
        .alert(String(localized: "delete_song"), isPresented: $showDeleteConfirm) {
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "delete"), role: .destructive) {
                deleteSong()
            }
        } message: {
            Text(String(localized: "delete_song_message"))
        }
        .alert(
            String(localized: "delete_song_failed_title"),
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "done"), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .alert(
            String(localized: "song_details_check_source"),
            isPresented: Binding(
                get: { sourceCheckMessage != nil },
                set: { if !$0 { sourceCheckMessage = nil } }
            )
        ) {
            Button(String(localized: "done"), role: .cancel) {}
        } message: {
            Text(sourceCheckMessage ?? "")
        }
        .alert(
            String(localized: "reread_song_tags"),
            isPresented: Binding(
                get: { tagReadMessage != nil },
                set: { if !$0 { tagReadMessage = nil } }
            )
        ) {
            Button(String(localized: "done"), role: .cancel) {}
        } message: {
            Text(tagReadMessage ?? "")
        }
        .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
    }

    private var usesContextMenu: Bool {
        #if os(iOS)
        // SwiftUI's context-menu recognizer wins the same long press that the
        // selection modifier uses. Selection-enabled rows already expose every
        // single-song action in their trailing ellipsis menu, so reserve the
        // row long press for direct multi-selection.
        selection == nil
        #else
        true
        #endif
    }

    private func requestScrape(from entryPoint: SingleSongScrapeEntryPoint) {
        scraperSettings.performSingleSongScrapeAction(
            from: entryPoint,
            onProceed: { showScrapeOptions = true },
            onRequireSource: { showNoScraperSourceAlert = true }
        )
    }

    @ViewBuilder
    private func metadataRecoveryButtons() -> some View {
        if backfill.canRereadTags(for: song) {
            Button {
                rereadTags()
            } label: {
                Label(
                    String(localized: backfill.isRereadingTags(songID: song.id)
                        ? "reread_song_tags_in_progress"
                        : "reread_song_tags"),
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(backfill.isRereadingTags(songID: song.id))
        }

        if showsDetailsStatus, detailsState != .reading {
            Button {
                checkSource()
            } label: {
                Label(String(localized: "song_details_check_source"), systemImage: "network")
            }
        }
    }

    private func rereadTags() {
        Task {
            let result = await backfill.rereadTags(songID: song.id)
            switch result {
            case .completed(let kind):
                CachedArtworkView.invalidateCache(for: song.id)
                if let coverRef = song.coverArtFileName {
                    CachedArtworkView.invalidateCache(for: coverRef)
                }
                if let updated = library.song(id: song.id) {
                    player.syncSongMetadata(updated)
                }
                tagReadMessage = kind.localizedRereadResult
            case .alreadyReading:
                tagReadMessage = String(localized: "reread_song_tags_in_progress")
            case .unsupported:
                tagReadMessage = String(localized: "reread_song_tags_unsupported")
            case .failed(let reason):
                let fileName = URL(fileURLWithPath: song.filePath).lastPathComponent
                let format = song.fileFormat.rawValue.uppercased()
                let resolvedSourceName = sourcesStore.source(id: song.sourceID)?.name
                    ?? sourceName
                    ?? song.sourceID
                tagReadMessage = String(
                    format: String(localized: "reread_song_tags_failed_detail_format"),
                    fileName,
                    format,
                    resolvedSourceName,
                    reason
                )
            }
        }
    }

    private func checkSource() {
        Task {
            do {
                _ = try await sourceManager.connectorForSong(song)
                backfill.retry(songID: song.id)
                sourceCheckMessage = String(localized: "song_details_source_available")
            } catch {
                sourceCheckMessage = String(localized: "song_details_source_unavailable")
            }
        }
    }

    private var detailsAlertTitle: String {
        switch detailsState {
        case .reading:
            String(localized: "song_details_loading")
        case .waitingForSource:
            String(localized: "song_details_waiting_source")
        case .playableIncomplete:
            String(localized: "song_details_incomplete")
        case .confirmedFailure:
            String(localized: "song_details_parse_failed")
        case .ready:
            String(localized: "song_details_unavailable")
        }
    }

    private var detailsAlertMessage: String {
        switch detailsState {
        case .reading:
            String(localized: "song_details_loading_message")
        case .waitingForSource:
            String(localized: "song_details_waiting_source_message")
        case .playableIncomplete:
            String(localized: "song_details_incomplete_message")
        case .confirmedFailure:
            String(localized: "song_details_parse_failed_message")
        case .ready:
            String(localized: "song_details_unavailable_message")
        }
    }

    private var supportsOfflineAudioCache: Bool {
        song.sourceID != AppleMusicLibraryService.systemSourceID
    }

    /// 编辑器当前显示的那首。翻页只换 id，行本身不动。
    private var tagEditorSong: Song {
        guard let tagEditorSongID, let resolved = library.song(id: tagEditorSongID) else {
            return library.song(id: song.id) ?? song
        }
        return resolved
    }

    /// 翻页队列 = 同源同目录的歌，按文件名排。整理标签基本都是一个文件夹一个
    /// 文件夹地过，跨目录翻页反而乱。
    private var tagEditorQueue: [Song] {
        let directory = (song.filePath as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return [] }
        let siblings = library.visibleSongs.filter {
            $0.sourceID == song.sourceID
                && ($0.filePath as NSString).deletingLastPathComponent == directory
        }
        guard siblings.count > 1 else { return [] }
        return siblings.sorted {
            ($0.filePath as NSString).lastPathComponent
                .localizedStandardCompare(($1.filePath as NSString).lastPathComponent)
                == .orderedAscending
        }
    }

    @ViewBuilder
    private func offlineActionButtons(snapshot: OfflineAudioCacheSnapshot) -> some View {
        switch snapshot.state {
        case .downloading:
            Button {} label: {
                Label(String(localized: "offline_downloading"), systemImage: "arrow.down.circle")
            }
            .disabled(true)
        case .pinned:
            Button(role: .destructive) {
                sourceManager.removeOfflineDownload(song: song)
            } label: {
                Label(String(localized: "offline_remove_song_cache"), systemImage: "trash")
            }
        case .cached:
            Button {
                sourceManager.downloadForOffline(song: song)
            } label: {
                Label(String(localized: "offline_keep_cached"), systemImage: "pin")
            }

            Button(role: .destructive) {
                sourceManager.removeOfflineDownload(song: song)
            } label: {
                Label(String(localized: "offline_remove_cached_file"), systemImage: "trash")
            }
        case .failed:
            Button {
                sourceManager.downloadForOffline(song: song)
            } label: {
                Label(String(localized: "offline_retry_download"), systemImage: "arrow.clockwise")
            }

            Button(role: .destructive) {
                sourceManager.removeOfflineDownload(song: song)
            } label: {
                Label(String(localized: "offline_clear_failed_download"), systemImage: "trash")
            }
        case .notCached:
            Button {
                sourceManager.downloadForOffline(song: song)
            } label: {
                Label(String(localized: "offline_cache_song"), systemImage: "arrow.down.circle")
            }
        }
    }

    private func deleteSong() {
        guard canDeleteSourceFile else { return }
        Task {
            // Stop if currently playing
            if player.currentSong?.id == song.id {
                await player.next()
            }
            let retainedSongs = library.songs.filter { $0.id != song.id }
            let deleteSidecars = sourceManager.shouldDeleteSidecars(for: song, retaining: retainedSongs)
            let result = await sourceManager.deleteSourceFilesAndCaches(
                for: song,
                deleteSidecars: deleteSidecars
            )
            guard result.shouldRemoveLibraryRecord else {
                deleteErrorMessage = deletionFailureMessage(result)
                return
            }
            // Remove from library and keep the source badge in sync.
            let remaining = library.deleteSong(song)
            sourcesStore.updateLocal(song.sourceID) { $0.songCount = remaining }
        }
    }

    private func deletionFailureMessage(_ result: SongFileDeletionResult) -> String {
        let summary = String(localized: "delete_song_failed_message")
        guard let detail = result.failedPaths.first?.message, !detail.isEmpty else { return summary }
        return "\(summary)\n\(detail)"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        duration.formattedDuration
    }
}

#if os(iOS)
private extension Notification.Name {
    static let songRowSwipeDidOpen = Notification.Name("Primuse.songRowSwipeDidOpen")
}

private enum SongRowPanPhase {
    case began
    case changed
    case ended
    case cancelled
}

private struct SongRowPanEvent {
    var phase: SongRowPanPhase
    var translationX: CGFloat
    var velocityX: CGFloat
}

private struct SongRowSwipeModifier: ViewModifier {
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let songID: String
    let isEnabled: Bool
    let onInsertNext: () -> Void
    let onAppendToQueue: () -> Void

    @State private var offset: CGFloat = 0
    @State private var dragOriginOffset: CGFloat = 0
    @State private var settledAction: SongRowSwipeAction?

    private var isRightToLeft: Bool { layoutDirection == .rightToLeft }
    private var revealWidth: CGFloat { CGFloat(SongRowSwipePolicy.revealWidth) }
    private var visibleAction: SongRowSwipeAction? {
        SongRowSwipePolicy.action(
            forOffset: Double(offset),
            isRightToLeft: isRightToLeft
        )
    }

    func body(content: Content) -> some View {
        ZStack {
            actionLayer

            content
                .offset(x: offset)
                .gesture(
                    SongRowHorizontalPanGesture(
                        isEnabled: isEnabled,
                        isRightToLeft: isRightToLeft,
                        onEvent: handlePan
                    )
                )
        }
        .clipped()
        .onChange(of: songID) { _, _ in
            close(animated: false)
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                close(animated: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .songRowSwipeDidOpen)) { notification in
            guard let openedSongID = notification.object as? String,
                  openedSongID != songID,
                  settledAction != nil else { return }
            close(animated: true)
        }
        .accessibilityAction(named: Text("insert_next")) {
            guard isEnabled else { return }
            perform(.insertNext)
        }
        .accessibilityAction(named: Text("add_to_queue")) {
            guard isEnabled else { return }
            perform(.appendToQueue)
        }
    }

    @ViewBuilder
    private var actionLayer: some View {
        if let visibleAction {
            let positiveOffset = offset > 0
            actionButton(visibleAction, positiveOffset: positiveOffset)
                .frame(width: revealWidth)
                .frame(maxWidth: .infinity, alignment: physicalAlignment(positiveOffset: positiveOffset))
                .mask(alignment: physicalAlignment(positiveOffset: positiveOffset)) {
                    Rectangle()
                        .frame(width: min(abs(offset), revealWidth))
                }
                .allowsHitTesting(
                    settledAction == visibleAction
                        && abs(offset) >= revealWidth - 1
                )
        }
    }

    private func actionButton(
        _ action: SongRowSwipeAction,
        positiveOffset: Bool
    ) -> some View {
        Button {
            perform(action)
        } label: {
            VStack(spacing: 2) {
                Image(systemName: actionSystemImage(action))
                    .font(.callout.weight(.semibold))
                Text(verbatim: actionTitle(action))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(actionTint(action), in: .rect(cornerRadius: 10))
            .padding(.vertical, 4)
            .padding(outerEdge(positiveOffset: positiveOffset), 4)
            .padding(contentFacingEdge(positiveOffset: positiveOffset), 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: actionTitle(action)))
    }

    private func handlePan(_ event: SongRowPanEvent) {
        guard isEnabled else { return }
        switch event.phase {
        case .began:
            dragOriginOffset = offset
        case .changed:
            let proposed = dragOriginOffset + event.translationX
            offset = CGFloat(SongRowSwipePolicy.interactiveOffset(Double(proposed)))
        case .ended:
            let proposed = dragOriginOffset + event.translationX
            let action = SongRowSwipePolicy.settledAction(
                offset: Double(proposed),
                velocityX: Double(event.velocityX),
                isRightToLeft: isRightToLeft
            )
            settle(on: action, animated: true)
        case .cancelled:
            settle(on: settledAction, animated: true)
        }
    }

    private func settle(on action: SongRowSwipeAction?, animated: Bool) {
        settledAction = action
        let target = CGFloat(SongRowSwipePolicy.restingOffset(
            for: action,
            isRightToLeft: isRightToLeft
        ))
        let animation: Animation? = animated && !reduceMotion
            ? .spring(response: 0.3, dampingFraction: 0.86)
            : nil
        withAnimation(animation) {
            offset = target
        }
        if action != nil {
            NotificationCenter.default.post(name: .songRowSwipeDidOpen, object: songID)
        }
    }

    private func close(animated: Bool) {
        settle(on: nil, animated: animated)
    }

    private func perform(_ action: SongRowSwipeAction) {
        switch action {
        case .insertNext:
            onInsertNext()
        case .appendToQueue:
            onAppendToQueue()
        }

        let actionName = actionTitle(action)
        let countMessage = String(format: String(localized: "new_songs_added"), 1)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        UIAccessibility.post(
            notification: .announcement,
            argument: "\(actionName), \(countMessage)"
        )
        close(animated: true)
    }

    private func physicalAlignment(positiveOffset: Bool) -> Alignment {
        if positiveOffset {
            return isRightToLeft ? .trailing : .leading
        }
        return isRightToLeft ? .leading : .trailing
    }

    private func outerEdge(positiveOffset: Bool) -> Edge.Set {
        if positiveOffset {
            return isRightToLeft ? .trailing : .leading
        }
        return isRightToLeft ? .leading : .trailing
    }

    private func contentFacingEdge(positiveOffset: Bool) -> Edge.Set {
        if positiveOffset {
            return isRightToLeft ? .leading : .trailing
        }
        return isRightToLeft ? .trailing : .leading
    }

    private func actionTitle(_ action: SongRowSwipeAction) -> String {
        switch action {
        case .insertNext: String(localized: "insert_next")
        case .appendToQueue: String(localized: "add_to_queue")
        }
    }

    private func actionSystemImage(_ action: SongRowSwipeAction) -> String {
        switch action {
        case .insertNext: "text.line.first.and.arrowtriangle.forward"
        case .appendToQueue: "text.line.last.and.arrowtriangle.forward"
        }
    }

    private func actionTint(_ action: SongRowSwipeAction) -> Color {
        switch action {
        case .insertNext: .accentColor
        case .appendToQueue: .green
        }
    }
}

private struct SongRowHorizontalPanGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let isRightToLeft: Bool
    let onEvent: (SongRowPanEvent) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(isEnabled: isEnabled, isRightToLeft: isRightToLeft)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.isRightToLeft = isRightToLeft
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UIPanGestureRecognizer,
        context: Context
    ) {
        guard let view = recognizer.view else { return }
        let translation = recognizer.translation(in: view)
        let velocity = recognizer.velocity(in: view)
        let phase: SongRowPanPhase
        switch recognizer.state {
        case .began:
            phase = .began
        case .changed:
            phase = .changed
        case .ended:
            phase = .ended
        case .cancelled, .failed:
            phase = .cancelled
        default:
            return
        }
        onEvent(SongRowPanEvent(
            phase: phase,
            translationX: translation.x,
            velocityX: velocity.x
        ))
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool
        var isRightToLeft: Bool

        init(isEnabled: Bool, isRightToLeft: Bool) {
            self.isEnabled = isEnabled
            self.isRightToLeft = isRightToLeft
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled,
                  let recognizer = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = recognizer.view else { return false }
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            let location = recognizer.location(in: view)
            let sample = SongRowSwipeSample(
                translationX: Double(translation.x),
                translationY: Double(translation.y),
                velocityX: Double(velocity.x),
                velocityY: Double(velocity.y),
                startX: Double(location.x - translation.x),
                containerWidth: Double(view.bounds.width),
                isRightToLeft: isRightToLeft
            )
            return SongRowSwipePolicy.shouldBegin(sample)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            isScrollViewPan(otherGestureRecognizer)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer is UIScreenEdgePanGestureRecognizer
        }

        private func isScrollViewPan(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            var view = gestureRecognizer.view
            while let current = view {
                if let scrollView = current as? UIScrollView,
                   gestureRecognizer === scrollView.panGestureRecognizer {
                    return true
                }
                view = current.superview
            }
            return false
        }
    }
}
#endif

private extension View {
    @ViewBuilder
    func songRowSwipeActions(
        songID: String,
        isEnabled: Bool,
        onInsertNext: @escaping () -> Void,
        onAppendToQueue: @escaping () -> Void
    ) -> some View {
        #if os(iOS)
        modifier(SongRowSwipeModifier(
            songID: songID,
            isEnabled: isEnabled,
            onInsertNext: onInsertNext,
            onAppendToQueue: onAppendToQueue
        ))
        #else
        self
        #endif
    }
}

private struct OfflineAudioStatusBadge: View {
    let snapshot: OfflineAudioCacheSnapshot

    var body: some View {
        switch snapshot.state {
        case .downloading:
            ProgressView(value: snapshot.progress)
                .controlSize(.mini)
                .frame(width: 20, height: 20)
                .accessibilityLabel("offline_downloading")
        case .pinned:
            Image(systemName: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .accessibilityLabel("offline_available")
        case .cached:
            Image(systemName: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityLabel("offline_cached")
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityLabel("offline_download_failed")
        case .notCached:
            EmptyView()
        }
    }
}

struct DiscoveryReasonsView: View {
    let reasons: [MusicDiscoveryReason]
    var maxCount: Int = 2

    private var text: String {
        let visible = reasons.prefix(maxCount)
        guard !visible.isEmpty else {
            return String(localized: "discovery_reason_libraryPick")
        }
        return visible
            .map { String(localized: LocalizedStringResource(stringLiteral: $0.localizationKey)) }
            .joined(separator: " · ")
    }

    var body: some View {
        Label {
            Text(text)
                .lineLimit(1)
        } icon: {
            Image(systemName: "sparkles")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.tint)
        .accessibilityLabel(text)
    }
}

struct SimilarSongsSheet: View {
    let seed: Song

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    /// Last.fm getSimilar 的结果, 跟本地算法独立 — 一个看"特征相似" (metadata),
    /// 一个看"听众重叠" (Last.fm)。空数组表示 API 没配 / 没结果 / 加载中。
    @State private var lastFmCandidates: [SimilarTracksCandidate] = []
    @State private var isLoadingLastFm: Bool = true
    @State private var lastFmError: String?

    /// 本地相似度结果, 在 .task 里算一次缓存进来 (而不是每次 body 求值都重跑
    /// 全库 O(n) 扫描)。`resultsLoaded` 区分"还没算"和"算完为空", 避免在计算
    /// 完成前闪一下空状态。
    @State private var results: [MusicDiscoveryResult] = []
    @State private var resultsLoaded: Bool = false

    /// 点"歌曲电台"时 songRadio 是 @MainActor 的全库 O(limit×n) 扫描, 给按钮一个
    /// loading 态, 让 spinner 先上屏再跑同步计算。
    @State private var isBuildingRadio: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    seedRow
                    if !results.isEmpty {
                        Button {
                            startSongRadio()
                        } label: {
                            HStack {
                                Label(String(localized: "start_song_radio"), systemImage: "dot.radiowaves.left.and.right")
                                if isBuildingRadio {
                                    Spacer()
                                    ProgressView().controlSize(.small)
                                }
                            }
                        }
                        .disabled(isBuildingRadio)

                        Button {
                            startSimilarMix()
                        } label: {
                            Label(String(localized: "start_similar_mix"), systemImage: "play.circle.fill")
                        }
                    }
                }

                if resultsLoaded && results.isEmpty && lastFmCandidates.isEmpty && !isLoadingLastFm {
                    ContentUnavailableView {
                        Label(String(localized: "similar_songs_empty"), systemImage: "sparkles")
                    } description: {
                        Text(String(localized: "similar_songs_empty_desc"))
                    }
                    .listRowBackground(Color.clear)
                } else {
                    if !results.isEmpty {
                        Section(String(localized: "similar_songs")) {
                            ForEach(results) { result in
                                Button {
                                    play(result.song)
                                } label: {
                                    SimilarSongResultRow(result: result)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if isLoadingLastFm {
                        Section {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("similar_loading").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else if !lastFmCandidates.isEmpty {
                        Section {
                            ForEach(lastFmCandidates) { candidate in
                                if let song = candidate.librarySong {
                                    Button {
                                        play(song)
                                    } label: {
                                        LastFmSimilarRow(song: song, match: candidate.match)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } header: {
                            Text("similar_section_lastfm")
                        } footer: {
                            Text("similar_source_lastfm")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(String(localized: "similar_songs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            .task { await loadLocalResults() }
            .task { await loadLastFmSimilar() }
        }
    }

    /// 本地相似度只算一次, 缓存进 `results`。songRadio/similarSongs 都是 @MainActor
    /// 绑定的全库扫描, 没法真正搬到后台线程; 这里先 yield 让 sheet 上屏再跑同步
    /// 计算, 避免打开瞬间卡住转场动画。
    private func loadLocalResults() async {
        guard !resultsLoaded else { return }
        await Task.yield()
        results = MusicDiscoveryEngine.similarSongs(to: seed, in: library, limit: 30)
        resultsLoaded = true
    }

    private func loadLastFmSimilar() async {
        guard !LastFmCredentialsStore.effectiveAPIKey().isEmpty else {
            isLoadingLastFm = false
            return
        }
        let service = AppServices.shared.similarTracks
        let pool = library.visibleSongs
        do {
            lastFmCandidates = try await service.fetchSimilar(
                to: seed,
                limit: 30,
                library: pool,
                includeUnmatched: false
            )
        } catch {
            lastFmError = error.localizedDescription
        }
        isLoadingLastFm = false
    }

    private var seedRow: some View {
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: seed.coverArtFileName,
                songID: seed.id,
                size: 44,
                cornerRadius: 6,
                sourceID: seed.sourceID,
                filePath: seed.filePath,
                fileFormat: seed.fileFormat
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(seed.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(library.artistDisplayName(for: seed) ?? seed.albumTitle ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func startSimilarMix() {
        let queue = ([seed] + results.map(\.song)).filteredPlayable()
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: 0)
        dismiss()
        Task { await player.play(song: first) }
    }

    private func startSongRadio() {
        guard !isBuildingRadio else { return }
        isBuildingRadio = true
        // songRadio 是 @MainActor 的 O(limit×n) 全库扫描, 没法搬离主线程; 先 yield
        // 让按钮 loading 态上屏, 万首库上点这个按钮才不会像彻底卡死。
        Task { @MainActor in
            await Task.yield()
            let radio = MusicDiscoveryEngine.songRadio(from: seed, in: library, limit: 48)
            let queue = radio.map(\.song).filteredPlayable()
            isBuildingRadio = false
            guard let first = queue.first else { return }
            player.shuffleEnabled = false
            player.setQueue(queue, startAt: 0)
            dismiss()
            await player.play(song: first)
        }
    }

    private func play(_ song: Song) {
        let tail = results.map(\.song).filter { $0.id != song.id }
        let queue = ([song] + tail).filteredPlayable()
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        player.setQueue(queue, startAt: 0)
        dismiss()
        SiriMediaInteractionDonor.donate(song: first)
        Task { await player.play(song: first) }
    }
}

private struct LastFmSimilarRow: View {
    @Environment(MusicLibrary.self) private var library

    let song: Song
    let match: Double

    var body: some View {
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 44,
                cornerRadius: 6,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title).font(.subheadline).lineLimit(1)
                Text(library.artistDisplayName(for: song) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if match > 0 {
                Text("\(Int(min(1.0, max(0, match)) * 100))%")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct SimilarSongResultRow: View {
    @Environment(MusicLibrary.self) private var library

    let result: MusicDiscoveryResult

    var body: some View {
        let song = result.song
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 44,
                cornerRadius: 6,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if let artist = library.artistDisplayName(for: song) {
                        Text(artist)
                    }
                    if let album = song.albumTitle {
                        Text("·")
                        Text(album)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                DiscoveryReasonsView(reasons: result.reasons, maxCount: 3)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// 相似歌曲呈现:macOS 用会自动消失的 PM 悬浮浮层 (`MacSimilarSongsPopover`),
    /// iOS 仍用半屏 sheet。统一入口,各调用点不用各写一份平台分支。
    @ViewBuilder
    func similarSongsPanel(
        isPresented: Binding<Bool>,
        seed: Song?,
        arrowEdge: Edge = .trailing
    ) -> some View {
        #if os(macOS)
        popover(isPresented: isPresented, arrowEdge: arrowEdge) {
            if let seed {
                MacSimilarSongsPopover(seed: seed) { isPresented.wrappedValue = false }
            }
        }
        #else
        sheet(isPresented: isPresented) {
            if let seed {
                SimilarSongsSheet(seed: seed)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        #endif
    }
}

private extension View {
    @ViewBuilder
    func songRowContextMenu<MenuItems: View>(
        isEnabled: Bool,
        @ViewBuilder menuItems: () -> MenuItems
    ) -> some View {
        if isEnabled {
            contextMenu(menuItems: menuItems)
        } else {
            self
        }
    }
}

extension SongRowView {
    /// Pre-derive per-row metadata from observed stores at the parent
    /// level. Each call site reads the stores once (registering one
    /// dependency on the parent body) and threads simple values down to
    /// the row, so a single source / backfill change only invalidates the
    /// parent body rather than every visible row.
    struct RowContext {
        var sourceName: String?
        var sourceIconName: String?
        var detailsState: SongDetailsState
        var canDeleteSourceFile: Bool
    }

    static func context(
        for song: Song,
        sourcesStore: SourcesStore,
        backfill: MetadataBackfillService
    ) -> RowContext {
        let showBadge = sourcesStore.sources.count > 1
        let source = sourcesStore.source(id: song.sourceID)
        return RowContext(
            sourceName: showBadge ? source?.name : nil,
            sourceIconName: showBadge ? source?.type.iconName : nil,
            detailsState: backfill.detailsState(
                for: song,
                isLocalSource: source?.type == .local
            ),
            canDeleteSourceFile: SourceFileDeletionPolicy.shouldShowDeleteAction(
                for: source?.type
            )
        )
    }

    init(
        song: Song,
        isPlaying: Bool = false,
        showAlbum: Bool = true,
        showsActions: Bool = true,
        selection: SongSelectionModel? = nil,
        context: RowContext
    ) {
        self.song = song
        self.isPlaying = isPlaying
        self.showAlbum = showAlbum
        self.showsActions = showsActions
        self.selection = selection
        self.sourceName = context.sourceName
        self.sourceIconName = context.sourceIconName
        self.detailsState = context.detailsState
        self.canDeleteSourceFile = context.canDeleteSourceFile
    }
}
