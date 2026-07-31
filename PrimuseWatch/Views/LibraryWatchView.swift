import SwiftUI

/// 当前播放队列 ── 跟 iPhone 端 NowPlayingView 看到的"播放列表"一致,
/// 顺序由 iPhone 端 player.queue 决定。点行直接发 playSong 命令到 iPhone,
/// 让 iPhone 实际播放; Watch 自己不持有音频文件, 也不参与解码。
struct LibraryWatchView: View {
    @Environment(WatchPlayerStore.self) private var store

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if store.queue.isEmpty {
                    emptyState
                } else {
                    ForEach(store.queue) { song in
                        Button {
                            store.play(songID: song.id)
                        } label: {
                            row(for: song)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle(WatchString("ext.watch.queue.title"))
    }

    private func row(for song: WatchLibrarySong) -> some View {
        HStack(spacing: 8) {
            // 当前曲目高亮显示一个小波形
            ZStack {
                if song.id == store.songID {
                    Image(systemName: store.isPlaying ? "waveform" : "pause.fill")
                        .font(.caption)
                        .foregroundStyle(store.accent)
                } else {
                    Image(systemName: "music.note")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if !song.artist.isEmpty {
                    Text(song.artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(song.id == store.songID
                      ? store.accent.opacity(0.18)
                      : Color.gray.opacity(0.10))
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(WatchString("ext.watch.queue.empty.title"))
                .font(.caption)
            Text(WatchString("ext.watch.queue.empty.subtitle"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
    }
}
