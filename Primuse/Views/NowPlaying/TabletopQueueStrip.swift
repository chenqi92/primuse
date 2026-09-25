#if os(iOS)
import PrimuseKit
import SwiftUI

/// iPhone Duo 桌面半折时，播放页下半屏控件上方那一排「接下来播放」封面（几何与取哪几首见
/// `TabletopQueueStripPolicy`）。当前曲居中放大，左边露出刚放过的、右边露出接下来的；
/// 左右滑到哪一张停下就放那一首，点一张也放那一首。
struct TabletopQueueStrip: View {
    let player: AudioPlayerService

    var body: some View {
        // 取哪几首只在队列、当前曲变化时重算；滚动时逐帧变的状态在下一层，不带着这里重算。
        let items = TabletopQueueStripItem.items(for: player)
        GeometryReader { proxy in
            if items.count > 1,
               let metrics = TabletopQueueStripPolicy.metrics(
                   width: Double(proxy.size.width),
                   availableHeight: Double(proxy.size.height)
               ) {
                TabletopQueueStripScroller(
                    player: player,
                    items: items,
                    metrics: metrics,
                    width: proxy.size.width
                )
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

private struct TabletopQueueStripScroller: View {
    let player: AudioPlayerService
    let items: [TabletopQueueStripItem]
    let metrics: TabletopQueueStripPolicy.Metrics
    let width: CGFloat

    @Environment(MusicLibrary.self) private var library
    /// 此刻停在中间的那一张（队列条目的身份）。
    @State private var focusedID: UUID?
    /// 手指还在拖、或者还在惯性滑：这期间换了歌也不去抢滚动位置。
    @State private var isScrolling = false
    /// 可见区域的中线（内容坐标）。每张按离它多远缩放；还没滚过时按停在中间的那张算。
    @State private var visibleMidX: CGFloat?

    private var currentID: UUID? {
        items.first(where: \.isCurrent)?.id
    }

    var body: some View {
        let side = CGFloat(metrics.coverSide)
        let pitch = side + CGFloat(metrics.spacing)
        let currentID = currentID
        let centeredIndex = items.firstIndex { $0.id == (focusedID ?? currentID) } ?? 0
        let midX = visibleMidX ?? CGFloat(centeredIndex) * pitch + side / 2
        ScrollView(.horizontal) {
            LazyHStack(spacing: CGFloat(metrics.spacing)) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    // 按离中线的远近缩小、变淡：居中那张是当前曲，两侧的越远越小。
                    let distance = CGFloat(index) * pitch + side / 2 - midX
                    cover(item, side: side, scale: TabletopQueueStripPolicy.scale(
                        forDistance: Double(distance),
                        metrics: metrics
                    ))
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $focusedID, anchor: .center)
        // 第一张和最后一张也能停到正中间。
        .contentMargins(.horizontal, max(0, (width - side) / 2), for: .scrollContent)
        .frame(height: side + 16)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.visibleRect.midX
        } action: { _, midX in
            visibleMidX = midX
        }
        .onScrollPhaseChange { _, phase in
            isScrolling = phase != .idle
            guard phase == .idle,
                  let focusedID, focusedID != currentID,
                  let item = items.first(where: { $0.id == focusedID }) else { return }
            play(item)
        }
        .onChange(of: currentID, initial: true) { _, id in
            // 按了上一首 / 下一首、放完自动换歌：把新的当前曲挪回中间。第一次出现直接放好。
            guard !isScrolling, let id, focusedID != id else { return }
            if focusedID == nil {
                focusedID = id
            } else {
                pmWithAnimation(.selection) { focusedID = id }
            }
        }
    }

    private func cover(_ item: TabletopQueueStripItem, side: CGFloat, scale: Double) -> some View {
        let song = item.song
        let artist = library.artistDisplayName(for: song) ?? song.albumTitle ?? ""
        let emphasis = (scale - metrics.sideScale) / max(0.0001, 1 - metrics.sideScale)
        return Button {
            guard !item.isCurrent else { return }
            play(item)
        } label: {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: side,
                cornerRadius: 14,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(scale)
        .opacity(0.5 + 0.5 * emphasis)
        .accessibilityLabel(Text(verbatim: artist.isEmpty ? song.title : "\(song.title), \(artist)"))
        .accessibilityAddTraits(item.isCurrent ? .isSelected : [])
    }

    private func play(_ item: TabletopQueueStripItem) {
        let entries = player.queueEntries
        let index = entries.indices.contains(item.queueIndex) && entries[item.queueIndex].id == item.id
            ? item.queueIndex
            : entries.firstIndex(where: { $0.id == item.id })
        guard let index else { return }
        Task {
            await player.playFromQueue(at: index)
            // 没切过去（音乐源连不上、用户在确认框里取消）就回到当前曲，别让中间停着一首没在放的歌。
            let entries = player.queueEntries
            if entries.indices.contains(player.currentIndex),
               entries[player.currentIndex].id != item.id,
               !isScrolling {
                pmWithAnimation(.selection) { focusedID = entries[player.currentIndex].id }
            }
        }
    }
}

/// 封面条里的一张：队列条目的身份、它此刻在队列里的下标、歌本身。
struct TabletopQueueStripItem: Identifiable {
    let id: UUID
    let queueIndex: Int
    let song: Song
    let isCurrent: Bool

    /// 刚放过的几首 + 当前曲 + 接下来的几首，与「播放队列」页同一套顺序（随机时按本轮的实际顺序）。
    /// 只取当前曲前后几首，不展开整条队列。
    @MainActor
    static func items(for player: AudioPlayerService) -> [TabletopQueueStripItem] {
        let entries = player.queueEntries
        let current = player.currentIndex
        guard entries.indices.contains(current) else { return [] }
        let shuffled = player.usesManagedShuffleOrder ? player.shuffledIndices : nil
        let position = player.shuffleAnchorPosition ?? player.shufflePosition
        let played = TabletopQueueStripPolicy.recentPlayedIndices(
            queueCount: entries.count,
            currentIndex: current,
            shuffledIndices: shuffled,
            shufflePosition: position,
            limit: TabletopQueueStripPolicy.playedLimit
        )
        let upcoming = QueuePresentationPolicy.firstCurrentRoundUpcomingIndices(
            queueCount: entries.count,
            currentIndex: current,
            shuffledIndices: shuffled,
            shufflePosition: position,
            limit: TabletopQueueStripPolicy.upcomingLimit
        )
        return TabletopQueueStripPolicy.stripIndices(
            played: played,
            currentIndex: current,
            upcoming: upcoming,
            queueCount: entries.count
        ).map { index in
            TabletopQueueStripItem(
                id: entries[index].id,
                queueIndex: index,
                song: index == current ? (player.currentSong ?? entries[index].song) : entries[index].song,
                isCurrent: index == current
            )
        }
    }
}
#endif
