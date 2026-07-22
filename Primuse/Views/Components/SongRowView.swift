import SwiftUI
import PrimuseKit

struct SongRowView: View {
    @Environment(SourceManager.self) private var sourceManager
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
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

    /// Whether `MetadataBackfillService` gave up on this song. Resolved by
    /// the parent so the row doesn't observe `failedSongIDs` directly —
    /// otherwise any backfill failure during a scan would re-evaluate every
    /// visible row's body.
    var backfillFailed: Bool = false

    @State private var showScrapeOptions = false
    @State private var showAddToPlaylist = false
    @State private var showSongInfo = false
    @State private var showDeleteConfirm = false
    @State private var showBareAlert = false
    @State private var showTagEditor = false
    @State private var showSimilarSongs = false

    /// "Metadata still pending" — cloud Phase-A songs whose `duration` (and
    /// usually cover/artist) hasn't been backfilled yet. Drives a soft dim +
    /// "loading / details unavailable" subtitle. These songs ARE playable now
    /// (the player resolves duration on play), so this no longer blocks taps.
    /// 独立 MV 不算 bare —— 时长常由播放时 AVPlayer 回填, 元数据本来就薄,
    /// 不该顶着"读取中/详情不可用"的置灰样式。
    private var isBare: Bool { song.duration <= 0 && !song.isStandaloneMusicVideo }
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
            .opacity(isBare ? 0.55 : 1)

            // Song info — title and subtitle only, no format/duration clutter
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                    .opacity(isBare ? 0.65 : 1)

                HStack(spacing: 4) {
                    if isBare {
                        if backfillFailed {
                            Image(systemName: "exclamationmark.circle")
                                .font(.caption2)
                            Text("song_details_unavailable")
                        } else {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 12, height: 12)
                            Text("backfill_in_progress")
                        }
                    } else {
                        if song.isStandaloneMusicVideo {
                            Image(systemName: "play.rectangle.fill")
                                .font(.caption2)
                                .accessibilityLabel(Text("music_video_badge"))
                        }
                        if let artist = song.artistName {
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
                            showScrapeOptions = true
                        } label: {
                            Label(String(localized: "scrape_song"), systemImage: "wand.and.stars")
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

                        Button {
                            showSongInfo = true
                        } label: {
                            Label(String(localized: "song_info"), systemImage: "info.circle")
                        }
                    }

                    // Group 2: Share
                    Section {
                        ShareLink(item: "\(song.title) - \(song.artistName ?? "")") {
                            Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                        }
                    }

                    // Group 3: Destructive
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label(String(localized: "delete_song"), systemImage: "trash")
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
        .contentShape(Rectangle())
        .task(id: song.id) {
            guard supportsOfflineAudioCache else { return }
            await sourceManager.ensureOfflineAudioSnapshot(for: song)
        }
        // VoiceOver 把整行合并成一个可选元素,读出来 "歌名,艺术家",
        // 操作菜单走 contextMenu (VoiceOver 长按手势仍可触发)。
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            [song.title, song.artistName]
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
            String(localized: backfillFailed ? "song_details_unavailable" : "song_details_loading"),
            isPresented: $showBareAlert
        ) {
            Button(String(localized: "done"), role: .cancel) {}
        } message: {
            Text(String(localized: backfillFailed ? "song_details_unavailable_message" : "song_details_loading_message"))
        }
        .contextMenu {
            // Group 1: Actions
            Section {
                Button {
                    showScrapeOptions = true
                } label: {
                    Label(String(localized: "scrape_song"), systemImage: "wand.and.stars")
                }

                Button {
                    showTagEditor = true
                } label: {
                    Label(String(localized: "tag_editor_menu"), systemImage: "tag")
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

                Button {
                    showSongInfo = true
                } label: {
                    Label(String(localized: "song_info"), systemImage: "info.circle")
                }
            }

            // Group 2: Share
            Section {
                ShareLink(item: "\(song.title) - \(song.artistName ?? "")") {
                    Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                }
            }

            // Group 3: Destructive
            Section {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label(String(localized: "delete_song"), systemImage: "trash")
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
        .sheet(isPresented: $showTagEditor) {
            TagEditorView(song: song)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(song: song)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .similarSongsPanel(isPresented: $showSimilarSongs, seed: song)
        .sheet(isPresented: $showSongInfo) {
            SongInfoSheet(song: song)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert(String(localized: "delete_song"), isPresented: $showDeleteConfirm) {
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "delete"), role: .destructive) {
                deleteSong()
            }
        } message: {
            Text(String(localized: "delete_song_message"))
        }
    }

    private var supportsOfflineAudioCache: Bool {
        song.sourceID != AppleMusicLibraryService.systemSourceID
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
        Task {
            // Stop if currently playing
            if player.currentSong?.id == song.id {
                await player.next()
            }
            let retainedSongs = library.songs.filter { $0.id != song.id }
            let deleteSidecars = sourceManager.shouldDeleteSidecars(for: song, retaining: retainedSongs)
            _ = await sourceManager.deleteSourceFilesAndCaches(for: song, deleteSidecars: deleteSidecars)
            // Remove from library and keep the source badge in sync.
            let remaining = library.deleteSong(song)
            sourcesStore.updateLocal(song.sourceID) { $0.songCount = remaining }
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        duration.formattedDuration
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
                Text(seed.artistName ?? seed.albumTitle ?? "")
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
        Task { await player.play(song: first) }
    }
}

private struct LastFmSimilarRow: View {
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
                Text(song.artistName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                    if let artist = song.artistName {
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

extension SongRowView {
    /// Pre-derive per-row metadata from observed stores at the parent
    /// level. Each call site reads the stores once (registering one
    /// dependency on the parent body) and threads simple values down to
    /// the row, so a single source / backfill change only invalidates the
    /// parent body rather than every visible row.
    struct RowContext {
        var sourceName: String?
        var sourceIconName: String?
        var backfillFailed: Bool
    }

    static func context(
        for song: Song,
        sourcesStore: SourcesStore,
        backfill: MetadataBackfillService
    ) -> RowContext {
        let showBadge = sourcesStore.sources.count > 1
        let source = sourcesStore.source(id: song.sourceID)
        let localBareSong = song.duration <= 0 && source?.type == .local
        return RowContext(
            sourceName: showBadge ? source?.name : nil,
            sourceIconName: showBadge ? source?.type.iconName : nil,
            backfillFailed: song.duration <= 0 && (backfill.didFail(songID: song.id) || localBareSong)
        )
    }

    init(
        song: Song,
        isPlaying: Bool = false,
        showAlbum: Bool = true,
        showsActions: Bool = true,
        context: RowContext
    ) {
        self.song = song
        self.isPlaying = isPlaying
        self.showAlbum = showAlbum
        self.showsActions = showsActions
        self.sourceName = context.sourceName
        self.sourceIconName = context.sourceIconName
        self.backfillFailed = context.backfillFailed
    }
}
