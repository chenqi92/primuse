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

    /// Cloud songs added by Phase A scan stay non-playable until the
    /// backfill fills `duration` (needed for the progress bar / seek).
    /// The row dims and intercepts taps with a hint alert. We key on
    /// `isPlayable` (duration > 0) rather than the broader bare-song
    /// predicate — a song with artist/album parsed but duration still
    /// unknown would otherwise look "ready" but auto-advance to it would
    /// hand the player a track it can't render properly.
    private var isBare: Bool { !song.isPlayable }

    var body: some View {
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
                // macOS 默认会在 Menu 旁边再画一个下拉小箭头,跟我们的
                // ellipsis 图标重复;隐藏它只保留 ⋯,跟 iOS 行为一致。
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .contentShape(Rectangle())
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
                    showAddToPlaylist = true
                } label: {
                    Label(String(localized: "add_to_playlist"), systemImage: "text.badge.plus")
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
        #if os(macOS)
        // macOS 改成独立 NSWindow (ScrapeWindowController) —— 带原生红灯,
        // 不再走 sheet。showScrapeOptions 只用来触发开窗,然后立刻置 false。
        .onChange(of: showScrapeOptions) { _, new in
            guard new else { return }
            ScrapeWindowController.shared.show(song: song) { updated in
                CachedArtworkView.invalidateCache(for: updated.id)
                if let oldRef = song.coverArtFileName {
                    CachedArtworkView.invalidateCache(for: oldRef)
                }
            }
            showScrapeOptions = false
        }
        #else
        .sheet(isPresented: $showScrapeOptions) {
            ScrapeOptionsView(song: song) { updated in
                CachedArtworkView.invalidateCache(for: updated.id)
                if let oldRef = song.coverArtFileName {
                    CachedArtworkView.invalidateCache(for: oldRef)
                }
            }
            .presentationDetents([.medium, .large])
        }
        #endif
        .sheet(isPresented: $showAddToPlaylist) {
            AddToPlaylistSheet(song: song)
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
    }

    private func deleteSong() {
        // Stop if currently playing
        if player.currentSong?.id == song.id {
            Task { await player.next() }
        }
        // Clean caches
        let songID = song.id
        Task {
            await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
            await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: songID)
        }
        CachedArtworkView.invalidateCache(for: song.id)
        sourceManager.deleteAudioCache(for: song)
        // Remove from library and keep the source badge in sync.
        let remaining = library.deleteSong(song)
        sourcesStore.updateLocal(song.sourceID) { $0.songCount = remaining }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        duration.formattedDuration
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
