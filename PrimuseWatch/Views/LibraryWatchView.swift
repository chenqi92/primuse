import SwiftUI

/// 当前播放设备的队列，点选后在该设备播放。
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
            // 导航栏不画底色:行滚到时间和标题底下时渐渐淡掉,不压着字。
            .mask { WatchTopFadeMask() }
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

/// 列表顶上的淡出遮罩:停在原位的第一行完整显示,往上滚进导航栏那一段才逐渐透明。
/// 列表的区域不含导航栏时 `safeAreaInsets.top` 为 0,什么也不遮。
private struct WatchTopFadeMask: View {
    var body: some View {
        GeometryReader { geometry in
            let fadeEnd = geometry.safeAreaInsets.top
            let fadeLength = min(18, fadeEnd)
            VStack(spacing: 0) {
                Color.clear.frame(height: max(0, fadeEnd - fadeLength))
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: fadeLength)
                Color.black
            }
            .ignoresSafeArea()
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
