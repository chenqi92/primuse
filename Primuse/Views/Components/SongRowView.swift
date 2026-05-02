import SwiftUI
import PrimuseKit

struct SongRowView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(SourceManager.self) private var sourceManager
    @Environment(AudioPlayerService.self) private var player
    @Environment(MetadataBackfillService.self) private var backfill
    let song: Song
    var isPlaying: Bool = false
    var showAlbum: Bool = true
    var showsActions: Bool = true

    /// Read the song from the library on every render. The `song` param is
    /// a snapshot from when the parent built the row; backfill updates the
    /// library in place but SwiftUI does NOT reliably re-invoke the
    /// NavigationDestination closure that captures it, so the spinner and
    /// duration text would otherwise stay frozen on the bare snapshot
    /// forever even after duration is filled. Falling back to `song` keeps
    /// the row alive if the song was just deleted.
    private var liveSong: Song {
        library.song(id: song.id) ?? song
    }

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
    private var isBare: Bool { !liveSong.isPlayable }

    /// Backfill ran and gave up — file is parseable but exposes no
    /// duration. Distinct from "still loading": the row stops the
    /// spinner and switches to a static "details unavailable" hint so
    /// the user isn't watching a forever-loading row.
    private var backfillGaveUp: Bool {
        isBare && backfill.didFail(songID: song.id)
    }

    var body: some View {
        let live = liveSong
        return HStack(spacing: 10) {
            // Cover art with playing overlay
            ZStack {
                CachedArtworkView(
                    coverRef: live.coverArtFileName,
                    songID: live.id,
                    size: 44, cornerRadius: 6,
                    sourceID: live.sourceID,
                    filePath: live.filePath
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
                Text(live.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                    .opacity(isBare ? 0.65 : 1)

                HStack(spacing: 4) {
                    if isBare {
                        if backfillGaveUp {
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
                        if let artist = live.artistName {
                            Text(artist)
                        }
                        if showAlbum, let album = live.albumTitle {
                            Text("·")
                            Text(album)
                        }
                        Text("·")
                        Text(formatDuration(live.duration))
                            .monospacedDigit()
                        if sourcesStore.sources.count > 1,
                           let source = sourcesStore.source(id: live.sourceID) {
                            Text("·")
                            Image(systemName: source.type.iconName)
                            Text(source.name)
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
            String(localized: backfillGaveUp ? "song_details_unavailable" : "song_details_loading"),
            isPresented: $showBareAlert
        ) {
            Button(String(localized: "done"), role: .cancel) {}
        } message: {
            Text(String(localized: backfillGaveUp ? "song_details_unavailable_message" : "song_details_loading_message"))
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
        .sheet(isPresented: $showScrapeOptions) {
            ScrapeOptionsView(song: song) { updated in
                CachedArtworkView.invalidateCache(for: updated.id)
                if let oldRef = song.coverArtFileName {
                    CachedArtworkView.invalidateCache(for: oldRef)
                }
            }
            .presentationDetents([.medium, .large])
        }
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

    private var songDetailText: String {
        var parts: [String] = [song.fileFormat.displayName, formatDuration(song.duration)]
        if let sr = song.sampleRate { parts.append("\(sr / 1000)kHz") }
        if let bits = song.bitDepth { parts.append("\(bits)bit") }
        return parts.joined(separator: " · ")
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
