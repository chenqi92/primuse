import SwiftUI
import PrimuseKit

struct QueueView: View {
    @Environment(AudioPlayerService.self) private var player

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
                            SongRowView(song: current, isPlaying: true)
                        }
                    }

                    // Up Next
                    let upNext = Array(player.queue.dropFirst(player.currentIndex + 1))
                    if !upNext.isEmpty {
                        Section("up_next") {
                            ForEach(upNext) { song in
                                SongRowView(song: song, isPlaying: false)
                            }
                        }
                    }
                }
            }
            .navigationTitle("queue_title")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
