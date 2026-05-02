import SwiftUI
import PrimuseKit

struct QueueView: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill
    @Environment(\.dismiss) private var dismiss

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
                        Section {
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
                        } header: {
                            HStack {
                                Text("played")
                                Spacer()
                                Button {
                                    clearPlayed(uptoIndex: player.currentIndex)
                                } label: {
                                    Text("clear_all")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #endif
            #if os(iOS)
            .environment(\.editMode, .constant(.active)) // Enable drag handles
            #endif
            .navigationTitle("queue_title")
            .navigationBarTitleDisplayMode(.inline)
            #if os(macOS)
            // iOS 用 presentationDragIndicator 关闭,macOS sheet 里没有,
            // 加一个显式的 Done 按钮。
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
            #endif
        }
    }

    /// 清除「已播放」区(Apple Music 行为)。从队列里移除 0..<index 的歌,
    /// 同时把 currentIndex 修正到 0,这样当前歌仍是播放中那首。
    private func clearPlayed(uptoIndex: Int) {
        guard uptoIndex > 0, uptoIndex <= player.queue.count else { return }
        player.queue.removeFirst(uptoIndex)
        player.currentIndex = max(0, player.currentIndex - uptoIndex)
    }

    private func playAt(index: Int) {
        guard index >= 0, index < player.queue.count else { return }
        player.currentIndex = index
        let song = player.queue[index]
        Task { await player.play(song: song) }
    }
}
