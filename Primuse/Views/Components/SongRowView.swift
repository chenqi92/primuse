import SwiftUI
import PrimuseKit

struct SongRowView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(SourceManager.self) private var sourceManager
    @Environment(AudioPlayerService.self) private var player
    let song: Song
    var isPlaying: Bool = false
    var showAlbum: Bool = true
    var showsActions: Bool = true

    @State private var showScrapeOptions = false
    @State private var showAddToPlaylist = false
    @State private var showSongInfo = false
    @State private var showDeleteConfirm = false
    @State private var showBareAlert = false

    /// Cloud songs added by Phase A scan have no metadata until
    /// `MetadataBackfillService` fills them in. The row dims slightly and
    /// shows "loading details" where duration would normally appear. Tap
    /// is intercepted to a hint alert — streaming would still work, but
    /// the UX is clearer if users wait for details to land.
    /// Same predicate as `MetadataBackfillService.isBareSong` so both
    /// stay in sync (a song that's "not bare enough to backfill" is also
    /// "not bare enough to dim in the list").
    private var isBare: Bool {
        MetadataBackfillService.isBareSong(song)
    }

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
                    Image(systemName: "waveform")
                        .font(.caption)
                        .symbolEffect(.variableColor.iterative)
                        .foregroundStyle(.white)
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
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 12, height: 12)
                        Text("backfill_in_progress")
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
                        if sourcesStore.sources.count > 1,
                           let source = sourcesStore.source(id: song.sourceID) {
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
        .alert(String(localized: "song_details_loading"), isPresented: $showBareAlert) {
            Button(String(localized: "done"), role: .cancel) {}
        } message: {
            Text(String(localized: "song_details_loading_message"))
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
        // Remove from library
        library.deleteSong(song)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        duration.formattedDuration
    }
}
