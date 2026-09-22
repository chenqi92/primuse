import PrimuseKit
import SwiftUI

/// The audiobooks, 评书/相声 series, radio dramas and lectures in the library.
///
/// They are kept out of the songs, albums and artists surfaces — one book is a
/// single item that buries a music library — and listed here instead, ordered
/// the way they are actually used: whatever is part-heard first.
struct SpokenWordLibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player

    private var store: SpokenWordStore { SpokenWordStore.shared }

    private struct Item: Identifiable {
        let song: Song
        let stored: SpokenWordStore.StoredPosition?
        var id: String { song.id }
        var isInProgress: Bool { stored != nil }
    }

    private var items: [Item] {
        // `revision` is read so the list refreshes when a position is stored
        // or an item is reclassified.
        _ = store.revision
        return library.spokenWordSongs.map {
            Item(song: $0, stored: store.position(forSongID: $0.id))
        }
    }

    var body: some View {
        let all = items
        let inProgress = all
            .filter(\.isInProgress)
            .sorted {
                ($0.stored?.updatedAt ?? .distantPast) > ($1.stored?.updatedAt ?? .distantPast)
            }

        List {
            if !inProgress.isEmpty {
                Section("spoken_word_continue_section") {
                    ForEach(inProgress) { row($0, in: all) }
                }
            }
            Section(inProgress.isEmpty ? "" : String(localized: "spoken_word_all_section")) {
                ForEach(all) { row($0, in: all) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("tab_spoken_word")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if all.isEmpty {
                ContentUnavailableView(
                    "tab_spoken_word",
                    systemImage: "books.vertical",
                    description: Text("spoken_word_empty_hint")
                )
            }
        }
    }

    @ViewBuilder
    private func row(_ item: Item, in all: [Item]) -> some View {
        Button {
            play(item, in: all)
        } label: {
            SpokenWordRow(
                song: item.song,
                stored: item.stored,
                isPlaying: player.currentSong?.id == item.song.id
            )
        }
        .buttonStyle(.plain)
        // A plain button only takes hits on its content's own shape, so the
        // row's padding would otherwise be dead space.
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                store.setKind(.music, forSongIDs: [item.song.id])
                library.refreshContentClassification()
            } label: {
                Label(String(localized: "mark_as_music"), systemImage: "music.note")
            }
            if item.isInProgress {
                Button(role: .destructive) {
                    store.clearPosition(forSongID: item.song.id)
                } label: {
                    Label(
                        String(localized: "spoken_word_clear_progress"),
                        systemImage: "arrow.counterclockwise"
                    )
                }
            }
        }
    }

    private func play(_ item: Item, in all: [Item]) {
        // The queue is the spoken-word list itself, so finishing one part of a
        // series continues into the next rather than into unrelated music.
        let songs = all.map(\.song)
        let index = songs.firstIndex { $0.id == item.song.id } ?? 0
        player.setQueue(songs, startAt: index)
        Task { await player.play(song: item.song) }
    }
}

private struct SpokenWordRow: View {
    let song: Song
    let stored: SpokenWordStore.StoredPosition?
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 48,
                cornerRadius: 8,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.body)
                    .foregroundStyle(isPlaying ? Color.accentColor : .primary)
                    .lineLimit(1)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let stored {
                    ProgressView(value: stored.fractionComplete)
                        .progressViewStyle(.linear)
                        .tint(Color.accentColor)
                        .frame(maxWidth: 220)
                    Text(remainingText(stored))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String? {
        let parts = [song.artistName, song.albumTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private func remainingText(_ stored: SpokenWordStore.StoredPosition) -> String {
        guard stored.duration > 0 else {
            return ChapterTimeFormatter.string(from: stored.position)
        }
        let remaining = max(0, stored.duration - stored.position)
        return String(
            format: String(localized: "spoken_word_remaining_format"),
            ChapterTimeFormatter.string(from: remaining)
        )
    }
}
