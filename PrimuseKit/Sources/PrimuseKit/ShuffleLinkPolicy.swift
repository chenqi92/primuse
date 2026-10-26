import Foundation

/// 一首歌的「随机时连播」开关指向哪一边(#335)。上一首 / 下一首按专辑曲序(`AlbumTrackOrder`)取。
public enum ShuffleLinkDirection: String, CaseIterable, Sendable {
    /// 「接着放下一首」: 随机抽到这首, 专辑里的下一首紧跟着放。
    case next
    /// 「先放上一首」: 随机抽到这首, 专辑里的上一首先放。
    case previous
}

/// 随机播放时连着放的歌(#335)。一条连接 A → B 表示随机时 B 紧跟在 A 后面放, 不论是 A 设了
/// 「接着放下一首」还是 B 设了「先放上一首」。
///
/// 同一张列表里两首都在时一律连成一块; 列表里只有其中一首时才看方向: 设了开关的那首被抽到,
/// 才把另一首带进来(见 `ShuffleLinkPolicy.bringingLinkedSongs`)。
public struct ShuffleLinkGraph: Equatable, Sendable {
    public static let empty = ShuffleLinkGraph()

    private var successors: [String: String] = [:]
    private var predecessors: [String: String] = [:]
    /// 被抽到时把下一首带进来的歌(设了「接着放下一首」)。
    private var bringsNext: Set<String> = []
    /// 被抽到时把上一首带进来的歌(设了「先放上一首」)。
    private var bringsPrevious: Set<String> = []

    public init() {}

    /// - Parameters:
    ///   - nextLinks: 设了「接着放下一首」的歌 → 专辑里它的下一首。
    ///   - previousLinks: 设了「先放上一首」的歌 → 专辑里它的上一首。
    public init(nextLinks: [String: String], previousLinks: [String: String]) {
        // 按键排一下再连: 极少见的冲突(专辑曲序在两次设置之间变过)每次都留同一条。
        for song in nextLinks.keys.sorted() {
            guard let next = nextLinks[song], link(song, to: next) else { continue }
            bringsNext.insert(song)
        }
        for song in previousLinks.keys.sorted() {
            guard let previous = previousLinks[song], link(previous, to: song) else { continue }
            bringsPrevious.insert(song)
        }
    }

    /// 一首歌前后各只接一首, 也不连成环; 和已有的连接冲突时保留先连上的那条。
    private mutating func link(_ from: String, to next: String) -> Bool {
        guard from != next else { return false }
        if let existing = successors[from] { return existing == next }
        guard predecessors[next] == nil else { return false }
        var cursor = from
        while let previous = predecessors[cursor] {
            guard previous != next else { return false }
            cursor = previous
        }
        successors[from] = next
        predecessors[next] = from
        return true
    }

    public var isEmpty: Bool { successors.isEmpty }

    /// 随机时紧跟在这首后面放的歌。
    public func successor(of songID: String) -> String? { successors[songID] }

    /// 随机时紧排在这首前面放的歌。
    public func predecessor(of songID: String) -> String? { predecessors[songID] }

    /// 随机时 `nextID` 紧跟在 `songID` 后面放。
    public func isLinked(_ songID: String, to nextID: String) -> Bool {
        successors[songID] == nextID
    }

    /// 只抽到这首时要不要把那一边的歌带进来。
    public func brings(_ songID: String, _ direction: ShuffleLinkDirection) -> Bool {
        switch direction {
        case .next: bringsNext.contains(songID)
        case .previous: bringsPrevious.contains(songID)
        }
    }
}

/// 随机播放怎么照顾连着放的歌(#335)。这里只排先后, 抽歌偏好照旧由调用方给的 `shuffle` 决定:
/// 一块按它的第一首参与加权。
public enum ShuffleLinkPolicy {
    /// 把列表分成块: 连着的几首按先后成一块, 其余一首一块。块按各自最早出现的那首排先后。
    /// 同一首在列表里出现多次时只有第一次参与连接, 其余各自成块。
    public static func units<Element>(
        _ elements: [Element],
        graph: ShuffleLinkGraph,
        id: (Element) -> String?
    ) -> [[Element]] {
        guard !graph.isEmpty else { return elements.map { [$0] } }
        var firstPosition: [String: Int] = [:]
        firstPosition.reserveCapacity(elements.count)
        for (index, element) in elements.enumerated() {
            if let key = id(element), firstPosition[key] == nil { firstPosition[key] = index }
        }
        func linkedKey(at index: Int) -> String? {
            guard let key = id(elements[index]), firstPosition[key] == index else { return nil }
            return key
        }

        var used = [Bool](repeating: false, count: elements.count)
        var result: [[Element]] = []
        for start in elements.indices where !used[start] {
            var head = start
            var visited: Set<Int> = [start]
            while let key = linkedKey(at: head),
                  let previousKey = graph.predecessor(of: key),
                  let previous = firstPosition[previousKey],
                  !used[previous],
                  visited.insert(previous).inserted {
                head = previous
            }
            var unit: [Element] = []
            var cursor: Int? = head
            while let index = cursor, !used[index] {
                used[index] = true
                unit.append(elements[index])
                cursor = linkedKey(at: index)
                    .flatMap { graph.successor(of: $0) }
                    .flatMap { firstPosition[$0] }
            }
            result.append(unit)
        }
        return result
    }

    /// 按块打乱后摊平。`shuffle` 只给每块的第一首排先后(抽歌偏好就按它加权), 必须原样交回
    /// 同一批元素; `lead` 所在的那块从 `lead` 起放在最前, 它前面那几首另成一块跟着打乱。
    public static func shuffled<Element: Hashable>(
        _ elements: [Element],
        graph: ShuffleLinkGraph,
        id: (Element) -> String?,
        leading lead: Element? = nil,
        shuffle: ([Element]) -> [Element]
    ) -> [Element] {
        var blocks = units(elements, graph: graph, id: id)
        var result: [Element] = []
        if let lead, let blockIndex = blocks.firstIndex(where: { $0.contains(lead) }) {
            let block = blocks.remove(at: blockIndex)
            let offset = block.firstIndex(of: lead) ?? 0
            result.append(contentsOf: block[offset...])
            if offset > 0 { blocks.append(Array(block[..<offset])) }
        }
        var blocksByHead: [Element: [Int]] = [:]
        for (index, block) in blocks.enumerated() {
            blocksByHead[block[0], default: []].append(index)
        }
        var emitted = [Bool](repeating: false, count: blocks.count)
        for head in shuffle(blocks.map { $0[0] }) {
            guard var pending = blocksByHead[head], !pending.isEmpty else { continue }
            let index = pending.removeFirst()
            blocksByHead[head] = pending
            emitted[index] = true
            result.append(contentsOf: blocks[index])
        }
        // `shuffle` 没交回的块(不该发生)照原先后接在最后, 一首也不丢。
        for (index, block) in blocks.enumerated() where !emitted[index] {
            result.append(contentsOf: block)
        }
        return result
    }

    /// 补上要带进来的歌: 设了「接着放下一首」的后面补它的下一首, 设了「先放上一首」的前面补它的
    /// 上一首, 补进来的歌自己也设了的接着往下补。列表里已有的、`excluding` 里的、`includes` 不收的
    /// 不补。补进来的紧挨着带它进来的那首, 原有的歌先后不变。
    public static func bringingLinkedSongs(
        _ ids: [String],
        graph: ShuffleLinkGraph,
        excluding: Set<String> = [],
        includes: (String) -> Bool
    ) -> [String] {
        guard !graph.isEmpty, !ids.isEmpty else { return ids }
        var present = excluding
        present.formUnion(ids)
        var result: [String] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            var before: [String] = []
            var cursor = id
            while graph.brings(cursor, .previous),
                  let previous = graph.predecessor(of: cursor),
                  !present.contains(previous),
                  includes(previous) {
                present.insert(previous)
                before.append(previous)
                cursor = previous
            }
            result.append(contentsOf: before.reversed())
            result.append(id)
            cursor = id
            while graph.brings(cursor, .next),
                  let next = graph.successor(of: cursor),
                  !present.contains(next),
                  includes(next) {
                present.insert(next)
                result.append(next)
                cursor = next
            }
        }
        return result
    }

    /// 截前 `maxCount` 首; 截口落在连着的一块中间时, 这块剩下的也一起带上。
    public static func prefix<Element>(
        _ elements: [Element],
        maxCount: Int,
        graph: ShuffleLinkGraph,
        id: (Element) -> String?
    ) -> ArraySlice<Element> {
        var end = min(max(0, maxCount), elements.count)
        guard end > 0, !graph.isEmpty else { return elements[..<end] }
        while end < elements.count,
              let previous = id(elements[end - 1]),
              let next = id(elements[end]),
              graph.isLinked(previous, to: next) {
            end += 1
        }
        return elements[..<end]
    }

    /// 往一轮随机末尾接上一段(`addition` 已经排好): 跟本轮还没放到的歌连着的块挪到那首旁边 ——
    /// 块头的上一首在那里就接在它后面, 块尾的下一首在那里就插在它前面; 其余照原先后接在末尾。
    /// `anchor` 是正在放的位置: 可以接在它后面, 不会插到它前面, 它之前的位置都不动。
    public static func appending<Element>(
        _ addition: [Element],
        to order: [Element],
        anchor: Int,
        graph: ShuffleLinkGraph,
        id: (Element) -> String?
    ) -> [Element] {
        guard !graph.isEmpty, !addition.isEmpty, !order.isEmpty else { return order + addition }
        let first = max(0, min(anchor, order.count - 1))
        var result = order
        var tail: [Element] = []
        func position(of songID: String, from start: Int) -> Int? {
            guard start < result.count else { return nil }
            return result[start...].firstIndex { id($0) == songID }
        }
        for block in units(addition, graph: graph, id: id) {
            if let headID = id(block[0]),
               let previousID = graph.predecessor(of: headID),
               let previous = position(of: previousID, from: first),
               !(result.indices.contains(previous + 1) && id(result[previous + 1]) == headID) {
                result.insert(contentsOf: block, at: previous + 1)
            } else if let tailID = block.last.flatMap(id),
                      let nextID = graph.successor(of: tailID),
                      let next = position(of: nextID, from: first + 1),
                      !(id(result[next - 1]) == tailID) {
                result.insert(contentsOf: block, at: next)
            } else {
                tail.append(contentsOf: block)
            }
        }
        return result + tail
    }

    /// 重复播放的下一轮别从上一轮最后那首起头: 打头那块的第一首是 `boundary` 时, 把整块挪到后面
    /// 随便哪两块之间(不拆开别的块)。只剩一块时原样交回。
    public static func movingLeadingBlock<Element: Equatable, G: RandomNumberGenerator>(
        awayFrom boundary: Element,
        in order: [Element],
        graph: ShuffleLinkGraph,
        id: (Element) -> String?,
        using generator: inout G
    ) -> [Element] {
        guard order.first == boundary else { return order }
        var blocks: [[Element]] = []
        for element in order {
            if let previous = blocks.last?.last,
               let previousID = id(previous),
               let elementID = id(element),
               graph.isLinked(previousID, to: elementID) {
                blocks[blocks.count - 1].append(element)
            } else {
                blocks.append([element])
            }
        }
        guard blocks.count > 1 else { return order }
        let leading = blocks.removeFirst()
        blocks.insert(leading, at: Int.random(in: 1...blocks.count, using: &generator))
        return blocks.flatMap { $0 }
    }
}
