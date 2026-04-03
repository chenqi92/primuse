import SwiftUI
import PrimuseKit

struct SongRowView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore
    let song: Song
    var isPlaying: Bool = false
    var showAlbum: Bool = true
    var showsActions: Bool = true

    @State private var showCreatePlaylistAlert = false
    @State private var playlistName = ""
    @State private var showScrapeOptions = false
    @State private var showAddToPlaylist = false
    @State private var showSongInfo = false

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

            // Song info
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)

                HStack(spacing: 4) {
                    if let artist = song.artistName {
                        Text(artist)
                    }
                    if showAlbum, let album = song.albumTitle {
                        Text("·")
                        Text(album)
                    }
                    if sourcesStore.sources.count > 1,
                       let source = sourcesStore.source(id: song.sourceID) {
                        Text("·")
                        Image(systemName: source.type.iconName)
                        Text(source.name)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer()

            // Format badge
            Text(song.fileFormat.displayName)
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .foregroundStyle(song.fileFormat.isLossless ? Color.blue : Color.secondary)
                .background(song.fileFormat.isLossless ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 3))

            // Duration
            Text(formatDuration(song.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if showsActions {
                Menu {
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

                    ShareLink(item: "\(song.title) - \(song.artistName ?? "")") {
                        Label(String(localized: "share"), systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .contentShape(Rectangle())
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
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
