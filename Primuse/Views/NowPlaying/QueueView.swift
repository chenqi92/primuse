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
                            SongRowView(song: current, isPlaying: true, showsPlaylistActions: false)
                        }
                    }

                    // Up Next
                    let upNext = Array(player.queue.enumerated()).filter { $0.offset > player.currentIndex }
                    if !upNext.isEmpty {
                        Section("up_next") {
                            ForEach(upNext, id: \.element.id) { index, song in
                                SongRowView(song: song, isPlaying: false, showsPlaylistActions: false)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        playAt(index: index)
                                    }
                            }
                        }
                    }

                    // Previously played
                    let played = Array(player.queue.enumerated()).filter { $0.offset < player.currentIndex }
                    if !played.isEmpty {
                        Section("played") {
                            ForEach(played, id: \.element.id) { index, song in
                                SongRowView(song: song, isPlaying: false, showsPlaylistActions: false)
                                    .opacity(0.6)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        playAt(index: index)
                                    }
                            }
                        }
                    }
                }
            }
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
