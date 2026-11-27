import Foundation

/// CarPlay 侧关心的播放状态快照。
public struct CarPlayPlayerState: Equatable, Sendable {
    public var songID: String?
    public var songTitle: String?
    public var stationID: String?
    public var stationName: String?
    public var isPlaying: Bool
    public var shuffleEnabled: Bool
    public var repeatModeRawValue: String
    public var currentIndex: Int
    public var radioMetadataTitle: String?

    public init(
        songID: String? = nil,
        songTitle: String? = nil,
        stationID: String? = nil,
        stationName: String? = nil,
        isPlaying: Bool = false,
        shuffleEnabled: Bool = false,
        repeatModeRawValue: String = "",
        currentIndex: Int = 0,
        radioMetadataTitle: String? = nil
    ) {
        self.songID = songID
        self.songTitle = songTitle
        self.stationID = stationID
        self.stationName = stationName
        self.isPlaying = isPlaying
        self.shuffleEnabled = shuffleEnabled
        self.repeatModeRawValue = repeatModeRawValue
        self.currentIndex = currentIndex
        self.radioMetadataTitle = radioMetadataTitle
    }
}

public enum CarPlayListRefreshPolicy {
    /// 首页与各详情页里的每一行,文字和封面都只取决于「在放哪一首 / 哪个台」。
    ///
    /// 播放暂停、随机、循环、队列位置、电台曲目元数据都不改变任何一行的内容,
    /// 但它们变得非常勤。为它们重建整张列表,等于把所有行退回占位图再逐个重取,
    /// 用户看到的就是封面不停闪。电台列表是例外 —— 它要显示正在播放指示和当前
    /// 曲目名,由调用方单独刷新。
    public static func listsNeedRebuild(
        from previous: CarPlayPlayerState?,
        to next: CarPlayPlayerState
    ) -> Bool {
        guard let previous else { return true }
        return previous.songID != next.songID
            || previous.songTitle != next.songTitle
            || previous.stationID != next.stationID
            || previous.stationName != next.stationName
    }

    /// 「即将播放」页比其他列表多看两样：随机与循环改变后面几行的顺序，
    /// 队列位置变了首行的正在播放指示要跟着走。播放暂停与电台元数据仍然不算。
    public static func queuePageNeedsRebuild(
        from previous: CarPlayPlayerState?,
        to next: CarPlayPlayerState
    ) -> Bool {
        guard let previous else { return true }
        return previous.songID != next.songID
            || previous.currentIndex != next.currentIndex
            || previous.shuffleEnabled != next.shuffleEnabled
            || previous.repeatModeRawValue != next.repeatModeRawValue
    }
}

/// CarPlay lists show at most a few hundred rows. Picking them must not sort
/// the whole library: a full sort of 400K titles with localized comparison
/// takes seconds on the main thread.
public enum CarPlayListSelection {
    /// The first `limit` elements in `areInIncreasingOrder` order, the same
    /// as `Array(elements.sorted(by:).prefix(limit))` for a strict weak
    /// ordering. Ties keep their original relative order.
    @inlinable
    public static func firstSorted<Element>(
        _ elements: some Sequence<Element>,
        limit: Int,
        by areInIncreasingOrder: (Element, Element) -> Bool
    ) -> [Element] {
        guard limit > 0 else { return [] }
        // Kept elements sit in fixed slots; a heap of slot numbers keeps the one
        // that would come last on top. A later element costs one comparison,
        // and an admitted one overwrites that slot and moves O(log limit) slot
        // numbers. Shifting a sorted array instead moved every kept element for
        // each newcomer, which for a library listed oldest-first and a
        // 20 000-song limit was terabytes of copying.
        var kept: [Element] = []
        var arrival: [Int] = []
        var heap: [Int] = []
        var position = 0
        for element in elements {
            defer { position += 1 }
            if heap.count < limit {
                kept.append(element)
                arrival.append(position)
                heap.append(kept.count - 1)
                var child = heap.count - 1
                while child > 0 {
                    let parent = (child - 1) / 2
                    guard slot(heap[parent], precedes: heap[child], kept, arrival, areInIncreasingOrder) else { break }
                    heap.swapAt(parent, child)
                    child = parent
                }
            } else if areInIncreasingOrder(element, kept[heap[0]]) {
                // Strictly ahead of the last kept one; an equal newcomer comes
                // after it in input order and stays out.
                kept[heap[0]] = element
                arrival[heap[0]] = position
                var parent = 0
                while true {
                    let left = 2 * parent + 1
                    let right = left + 1
                    var last = parent
                    if left < heap.count, slot(heap[last], precedes: heap[left], kept, arrival, areInIncreasingOrder) {
                        last = left
                    }
                    if right < heap.count, slot(heap[last], precedes: heap[right], kept, arrival, areInIncreasingOrder) {
                        last = right
                    }
                    guard last != parent else { break }
                    heap.swapAt(parent, last)
                    parent = last
                }
            }
        }
        return heap
            .sorted { slot($0, precedes: $1, kept, arrival, areInIncreasingOrder) }
            .map { kept[$0] }
    }

    /// Slot `a` comes before slot `b` in the result: by the ordering, then by
    /// input position, which is what keeps ties in their original order.
    @inlinable
    static func slot<Element>(
        _ a: Int,
        precedes b: Int,
        _ kept: [Element],
        _ arrival: [Int],
        _ areInIncreasingOrder: (Element, Element) -> Bool
    ) -> Bool {
        if areInIncreasingOrder(kept[a], kept[b]) { return true }
        if areInIncreasingOrder(kept[b], kept[a]) { return false }
        return arrival[a] < arrival[b]
    }
}
