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
                    ContentUnavailableView(
                        "queue_empty",
                        systemImage: "music.note.list",
                        description: Text("queue_empty_desc")
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

                    // Up Next (draggable)
                    let upNextIndices = (player.currentIndex + 1)..<player.queue.count
                    if !upNextIndices.isEmpty {
                        Section("up_next") {
                            ForEach(Array(upNextIndices), id: \.self) { index in
                                let song = player.queue[index]
                                SongRowView(
                                    song: song,
                                    isPlaying: false,
                                    showsActions: false,
                                    context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { playAt(index: index) }
                            }
                            .onMove { source, destination in
                                // Adjust indices relative to queue (not section)
                                let adjustedSource = IndexSet(source.map { $0 + player.currentIndex + 1 })
                                let adjustedDest = destination + player.currentIndex + 1
                                player.queue.move(fromOffsets: adjustedSource, toOffset: adjustedDest)
                            }
                        }
                    }

                    // Previously played
                    let playedIndices = 0..<player.currentIndex
                    if !playedIndices.isEmpty {
                        Section("played") {
                            ForEach(Array(playedIndices), id: \.self) { index in
                                let song = player.queue[index]
                                SongRowView(
                                    song: song,
                                    isPlaying: false,
                                    showsActions: false,
                                    context: SongRowView.context(for: song, sourcesStore: sourcesStore, backfill: backfill)
                                )
                                .opacity(0.6)
                                .contentShape(Rectangle())
                                .onTapGesture { playAt(index: index) }
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
