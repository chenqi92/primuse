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
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    queueSummary

                if let current = player.currentSong {
                        queueSection(title: "now_playing") {
                            queueRow(song: current, index: player.currentIndex, isPlaying: true)
                        }
                }

                let upNextIndices = (player.currentIndex + 1)..<player.queue.count
                if !upNextIndices.isEmpty {
                        queueSection(title: "up_next") {
                            ForEach(Array(upNextIndices), id: \.self) { index in
                                queueRow(song: player.queue[index], index: index)
                        }
                    }
                }

                let playedIndices = 0..<player.currentIndex
                if !playedIndices.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("played")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                clearPlayed(uptoIndex: player.currentIndex)
                            } label: {
                                    Label("clear_all", systemImage: "trash")
                                        .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help(Text("clear_all"))
                            }

                            VStack(spacing: 0) {
                                ForEach(Array(playedIndices), id: \.self) { index in
                                    queueRow(song: player.queue[index], index: index)
                                        .opacity(0.58)
                                    if index != playedIndices.upperBound - 1 {
                                        Divider().padding(.leading, 56)
                                    }
                                }
                            }
                            .background(.background.secondary, in: .rect(cornerRadius: 8))
                        }
                    }
                }
            }
                .padding(16)
                .padding(.bottom, 24)
            }
    }

    private var queueSummary: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.14), in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text("queue_title")
                    .font(.headline)
                Text("\(player.queue.count) \(String(localized: "songs_count"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }

    private func queueSection<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .background(.background.secondary, in: .rect(cornerRadius: 8))
        }
    }

    private func queueRow(song: Song, index: Int, isPlaying: Bool = false) -> some View {
        SongRowView(
            song: song,
            isPlaying: isPlaying,
            showsActions: false,
            context: SongRowView.context(for: song,
                                         sourcesStore: sourcesStore,
                                         backfill: backfill)
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { playAt(index: index) }
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
        player.removeQueuePrefix(count: uptoIndex)
    }
}
#endif
