import SwiftUI

/// 当前播放队列 ── 跟 iPhone 端 NowPlayingView 看到的"播放列表"一致,
/// 顺序由 iPhone 端 player.queue 决定。点行直接发 playSong 命令到 iPhone,
/// 让 iPhone 实际播放; Watch 自己不持有音频文件, 也不参与解码。
///
/// 打开时滚到正在播的那首; 已经播过的几首淡一些。
struct LibraryWatchView: View {
    @Environment(WatchPlayerStore.self) private var store

    var body: some View {
        Group {
            if store.queue.isEmpty {
                emptyState
            } else {
                queueList
            }
        }
        .navigationTitle(WatchString("ext.watch.queue.title"))
        .containerBackground(for: .navigation) {
            LinearGradient(
                colors: [store.accent.opacity(0.45), .black],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var queueList: some View {
        let currentIndex = store.queue.firstIndex { $0.id == store.songID }
        return ScrollViewReader { proxy in
            List {
                // 同一首歌可以在队列里出现两次, 行的身份用位置而不是 songID。
                ForEach(Array(store.queue.enumerated()), id: \.offset) { index, song in
                    let isCurrent = index == currentIndex
                    Button {
                        store.play(songID: song.id)
                    } label: {
                        WatchQueueRow(
                            song: song,
                            position: index + 1,
                            isCurrent: isCurrent,
                            isPlaying: isCurrent && store.isPlaying,
                            isPast: currentIndex.map { index < $0 } ?? false,
                            accent: store.accent
                        )
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(isCurrent ? store.accent.opacity(0.35) : Color.white.opacity(0.1))
                    )
                    .id(index)
                }
                if let notice = store.queueTruncationNotice {
                    Text(notice)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .listRowBackground(Color.clear)
                }
            }
            .onAppear {
                if let currentIndex { proxy.scrollTo(currentIndex, anchor: .center) }
            }
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                Text(WatchString("ext.watch.queue.empty.title"))
                    .font(.headline)
                Text(WatchString("ext.watch.queue.empty.subtitle"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
    }
}

struct WatchQueueRow: View {
    let song: WatchLibrarySong
    let position: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let isPast: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isCurrent {
                    Image(systemName: "waveform")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: isPlaying)
                } else {
                    Text("\(position)")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(isCurrent ? .headline : .body)
                    .lineLimit(2)
                if !song.artist.isEmpty {
                    Text(song.artist)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .opacity(isPast ? 0.55 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
