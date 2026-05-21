import SwiftUI
import PrimuseKit

struct QueueView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill

    var body: some View {
        NavigationStack {
            List {
                if player.queue.isEmpty {
                    EmptyStateView(
                        titleKey: "queue_empty",
                        descriptionKey: "queue_empty_desc",
                        systemImage: "music.note.list"
                    )
                } else {
                    // Now Playing
                    if let current = player.currentSong {
                        Section("now_playing") {
                            SongRowView(
                                song: current,
                                isPlaying: true,
                                showsActions: false,
                                context: SongRowView.context(for: current, sourcesStore: sourcesStore, backfill: backfill)
                            )
                        }
                    }

                    // Up Next (draggable). Iterate over queueEntries
                    // (each has a stable UUID) instead of integer
                    // indices — the previous `id: \.self` on Int
                    // index made SwiftUI's diff see no identity change
                    // after a reorder (range stays 0..N-1), so only
                    // the dragged row animated while the others
                    // swapped contents in place. Two rows visually
                    // overlapped for a few frames whenever the source
                    // and destination weren't adjacent. UUID-keyed
                    // ForEach lets SwiftUI animate every row's real
                    // position swap, and is also robust to the queue
                    // holding the same song multiple times.
                    let upNextStart = player.currentIndex + 1
                    if upNextStart < player.queueEntries.count {
                        let upNextEntries = Array(player.queueEntries[upNextStart..<player.queueEntries.count])
                        Section("up_next") {
                            ForEach(Array(upNextEntries.enumerated()), id: \.element.id) { offset, entry in
                                SongRowView(
                                    song: entry.song,
                                    isPlaying: false,
                                    showsActions: false,
                                    context: SongRowView.context(for: entry.song, sourcesStore: sourcesStore, backfill: backfill)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { playAt(index: upNextStart + offset) }
                            }
                            .onMove { source, destination in
                                // ForEach's source/destination are
                                // section-relative; rebase to queue
                                // indices before mutating. Routed
                                // through the player so shuffle plan
                                // invalidation happens centrally.
                                let adjustedSource = IndexSet(source.map { $0 + upNextStart })
                                let adjustedDest = destination + upNextStart
                                player.moveQueueItems(fromOffsets: adjustedSource, toOffset: adjustedDest)
                            }
                        }
                    }

                    // Previously played. Same UUID-keyed identity for
                    // consistency, even without onMove.
                    if player.currentIndex > 0 {
                        let playedEntries = Array(player.queueEntries[0..<player.currentIndex])
                        Section("played") {
                            ForEach(Array(playedEntries.enumerated()), id: \.element.id) { offset, entry in
                                SongRowView(
                                    song: entry.song,
                                    isPlaying: false,
                                    showsActions: false,
                                    context: SongRowView.context(for: entry.song, sourcesStore: sourcesStore, backfill: backfill)
                                )
                                .opacity(0.6)
                                .contentShape(Rectangle())
                                .onTapGesture { playAt(index: offset) }
                            }
                        }
                    }
                }
            }
            .environment(\.editMode, .constant(.active)) // Enable drag handles
            .navigationTitle("queue_title")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func playAt(index: Int) {
        guard index >= 0, index < player.queue.count else { return }
        player.currentIndex = index
        let song = player.queue[index]
        Task { await player.play(song: song) }
    }
}
