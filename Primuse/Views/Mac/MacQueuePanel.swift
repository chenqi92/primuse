#if os(macOS)
import SwiftUI
import PrimuseKit

/// 右侧 slide-in 队列面板,模仿 Apple Music 的「正在播放」队列。跟 sheet
/// 版 (`QueueView`) 唯一的区别是布局——侧栏紧贴 detail 右边,不劫持
/// 整个窗口。内部 list / 拖拽逻辑跟 sheet 版保持一致,源数据来自同一个
/// AudioPlayerService。
struct MacQueuePanel: View {
    var onClose: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(SourcesStore.self) private var sourcesStore
    @Environment(MetadataBackfillService.self) private var backfill

    var body: some View {
        // 用 NavigationStack + 自定义 toolbar 让队列侧栏跟主 detail 共享
        // 同一个 titlebar 安全区,不再额外多出一段顶部留白。原来 VStack
        // 自带的 header 行被去掉,标题改成 inline navigation title,关闭
        // 按钮挂到 toolbar 上,跟 macOS 26 sidebar 风格一致。
        NavigationStack {
            list
                .navigationTitle("queue_title")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                        }
                        .help(Text("close"))
                    }
                }
        }
        .background(.regularMaterial)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if player.queue.isEmpty {
            ContentUnavailableView(
                "queue_empty",
                systemImage: "music.note.list",
                description: Text("queue_empty_desc")
            )
        } else {
            List {
                if let current = player.currentSong {
                    Section("now_playing") {
                        SongRowView(
                            song: current,
                            isPlaying: true,
                            showsActions: false,
                            context: SongRowView.context(for: current,
                                                         sourcesStore: sourcesStore,
                                                         backfill: backfill)
                        )
                    }
                }

                let upNextIndices = (player.currentIndex + 1)..<player.queue.count
                if !upNextIndices.isEmpty {
                    Section("up_next") {
                        ForEach(Array(upNextIndices), id: \.self) { index in
                            let song = player.queue[index]
                            SongRowView(
                                song: song,
                                isPlaying: false,
                                showsActions: false,
                                context: SongRowView.context(for: song,
                                                             sourcesStore: sourcesStore,
                                                             backfill: backfill)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { playAt(index: index) }
                        }
                        .onMove { source, destination in
                            // 把 section 内偏移换算成 queue 全局 offset。
                            let adjustedSource = IndexSet(source.map { $0 + player.currentIndex + 1 })
                            let adjustedDest = destination + player.currentIndex + 1
                            player.queue.move(fromOffsets: adjustedSource, toOffset: adjustedDest)
                        }
                    }
                }

                let playedIndices = 0..<player.currentIndex
                if !playedIndices.isEmpty {
                    Section {
                        ForEach(Array(playedIndices), id: \.self) { index in
                            let song = player.queue[index]
                            SongRowView(
                                song: song,
                                isPlaying: false,
                                showsActions: false,
                                context: SongRowView.context(for: song,
                                                             sourcesStore: sourcesStore,
                                                             backfill: backfill)
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
            // .plain 比 .inset 在 sidebar 场景下顶部留白更紧凑,且 section
            // header 直接贴到第一行上方,跟 Apple Music 队列视觉一致。
            .listStyle(.plain)
        }
    }

    // MARK: - Actions

    private func playAt(index: Int) {
        guard index >= 0, index < player.queue.count else { return }
        player.currentIndex = index
        let song = player.queue[index]
        Task { await player.play(song: song) }
    }

    private func clearPlayed(uptoIndex: Int) {
        guard uptoIndex > 0, uptoIndex <= player.queue.count else { return }
        player.queue.removeFirst(uptoIndex)
        player.currentIndex = max(0, player.currentIndex - uptoIndex)
    }
}
#endif
