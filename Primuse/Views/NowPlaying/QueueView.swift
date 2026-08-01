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

                    // Up Next (draggable). Iterate over presentation entries
                    // (each has a stable slot + round identity) instead of integer
                    // indices — the previous `id: \.self` on Int
                    // index made SwiftUI's diff see no identity change
                    // after a reorder (range stays 0..N-1), so only
                    // the dragged row animated while the others
                    // swapped contents in place. Two rows visually
                    // overlapped for a few frames whenever the source
                    // and destination weren't adjacent. Occurrence-keyed
                    // ForEach lets SwiftUI animate every row's real
                    // position swap, and is also robust to the queue
                    // holding duplicate songs or previewing the same slot again
                    // in the next repeat-all shuffle round.
                    let queueEntries = player.queueEntries
                    let currentIndex = queueEntries.isEmpty
                        ? 0
                        : min(max(player.currentIndex, 0), queueEntries.count - 1)

                    // Up Next follows the *real* play order: in shuffle mode
                    // that's the player's shuffled remainder (not the raw queue
                    // tail), so the visible list matches what `next()` plays.
                    let upNextEntries = player.upcomingQueueEntries
                    if !upNextEntries.isEmpty {
                        let upNextStart = currentIndex + 1
                        Section("up_next") {
                            ForEach(upNextEntries) { entry in
                                SongRowView(
                                    song: entry.entry.song,
                                    isPlaying: false,
                                    showsActions: false,
                                    context: SongRowView.context(for: entry.entry.song, sourcesStore: sourcesStore, backfill: backfill)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { playEntry(entry.entry) }
                            }
                            // Drag-reorder only maps cleanly to raw queue
                            // offsets when the displayed order *is* the queue
                            // order (shuffle off). Under shuffle the rows are in
                            // shuffled order, so a section-relative move can't be
                            // rebased to `queueEntries` indices — skip it there.
                            .onMove { source, destination in
                                guard !player.shuffleEnabled else { return }
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

                    // Previously played follows the actual shuffle prefix instead
                    // of the raw queue prefix, so no current-round row appears in
                    // both Played and Up Next.
                    let playedEntries = player.playedQueueEntries
                    if !playedEntries.isEmpty {
                        Section("played") {
                            ForEach(playedEntries) { entry in
                                SongRowView(
                                    song: entry.entry.song,
                                    isPlaying: false,
                                    showsActions: false,
                                    context: SongRowView.context(for: entry.entry.song, sourcesStore: sourcesStore, backfill: backfill)
                                )
                                .opacity(0.6)
                                .contentShape(Rectangle())
                                .onTapGesture { playEntry(entry.entry) }
                            }
                        }
                    }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active)) // Enable drag handles
            #endif
            .navigationTitle("queue_title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
    }

    /// Resolve the tapped entry back to its raw `queueEntries` index (by stable
    /// per-slot UUID) and route through the player. `playFromQueue(at:)` keeps
    /// `currentIndex` *and* the shuffle bookkeeping (`shufflePosition` /
    /// `shuffledIndices`) aligned, so `next()` advances from the tapped track
    /// instead of a stale shuffle position — and without reshuffling the rest
    /// of the round (which a plain `shuffleEnabled` re-toggle would do).
    private func playEntry(_ entry: QueueEntry) {
        guard let index = player.queueEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        Task { await player.playFromQueue(at: index) }
    }
}
