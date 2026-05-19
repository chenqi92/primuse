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

    /// Cloud songs added by Phase A scan stay non-playable until the
    /// backfill fills `duration` (needed for the progress bar / seek).
    /// The row dims and intercepts taps with a hint alert. We key on
    /// `isPlayable` (duration > 0) rather than the broader bare-song
    /// predicate — a song with artist/album parsed but duration still
    /// unknown would otherwise look "ready" but auto-advance to it would
    /// hand the player a track it can't render properly.
    private var isBare: Bool { !song.isPlayable }
    private var offlineSnapshot: OfflineAudioCacheSnapshot {
        sourceManager.offlineAudioSnapshot(for: song)
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
                    filePath: song.filePath
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
                        if let artist = song.artistName {
                            Text(artist)
                        }
                        if showAlbum, let album = song.albumTitle {
                            Text("·")
                            Text(album)
                        }
                        Text("·")
                        Text(formatDuration(song.duration))
                            .monospacedDigit()
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

                        offlineActionButton(snapshot: offline)

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
        // VoiceOver 把整行合并成一个可选元素,读出来 "歌名,艺术家",
        // 操作菜单走 contextMenu (VoiceOver 长按手势仍可触发)。
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(
            [song.title, song.artistName]
                .compactMap { $0 }
                .joined(separator: " — ")
        ))
        // Bare songs (still being filled by MetadataBackfillService) are
        // tap-disabled with a clear hint rather than just visually dimmed.
        // The overlay is layered above the row's content so its tap
        // handler intercepts before the parent List/NavigationLink
        // forwards the tap to play().
        .overlay {
            if isBare {
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

                offlineActionButton(snapshot: offline)

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
        .sheet(isPresented: $showSimilarSongs) {
            SimilarSongsSheet(seed: song)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
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
        .task(id: song.id) {
            await sourceManager.refreshOfflineAudioSnapshot(for: song)
        }
    }

    @ViewBuilder
    private func offlineActionButton(snapshot: OfflineAudioCacheSnapshot) -> some View {
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
                Label(String(localized: "offline_remove_download"), systemImage: "trash")
            }
        case .cached:
            Button {
                sourceManager.downloadForOffline(song: song)
            } label: {
                Label(String(localized: "offline_keep_cached"), systemImage: "pin")
            }
        case .failed:
            Button {
                sourceManager.downloadForOffline(song: song)
            } label: {
                Label(String(localized: "offline_retry_download"), systemImage: "arrow.clockwise")
            }
        case .notCached:
            Button {
                sourceManager.downloadForOffline(song: song)
            } label: {
                Label(String(localized: "offline_download"), systemImage: "arrow.down.circle")
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
            Image(systemName: "arrow.down.circle.fill")
                .font(.callout)
                .foregroundStyle(.tint)
                .accessibilityLabel("offline_available")
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.orange)
                .accessibilityLabel("offline_download_failed")
        case .cached, .notCached:
            EmptyView()
        }
    }
}

struct SimilarSongsSheet: View {
    let seed: Song

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    private var results: [MusicDiscoveryResult] {
        MusicDiscoveryEngine.similarSongs(to: seed, in: library, limit: 30)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    seedRow
                    if !results.isEmpty {
                        Button {
                            startSimilarMix()
                        } label: {
                            Label(String(localized: "start_similar_mix"), systemImage: "play.circle.fill")
                        }
                    }
                }

                if results.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "similar_songs_empty"), systemImage: "sparkles")
                    } description: {
                        Text(String(localized: "similar_songs_empty_desc"))
                    }
                    .listRowBackground(Color.clear)
                } else {
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
            }
            .navigationTitle(String(localized: "similar_songs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
        }
    }

    private var seedRow: some View {
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: seed.coverArtFileName,
                songID: seed.id,
                size: 44,
                cornerRadius: 6,
                sourceID: seed.sourceID,
                filePath: seed.filePath
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
                filePath: song.filePath
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

                Label {
                    Text(LocalizedStringKey(result.primaryReason.localizationKey))
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "sparkles")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tint)
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
        let source = showBadge ? sourcesStore.source(id: song.sourceID) : nil
        return RowContext(
            sourceName: source?.name,
            sourceIconName: source?.type.iconName,
            backfillFailed: !song.isPlayable && backfill.didFail(songID: song.id)
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
