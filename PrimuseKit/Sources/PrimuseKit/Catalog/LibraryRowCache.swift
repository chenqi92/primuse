import Foundation

/// 按行号物化歌曲的有界 LRU 缓存。缺的行一批从目录取回;容量用满后淘汰最久没用的。
/// 线程安全:内部加锁,取数在锁外进行。
public final class LibraryRowCache: @unchecked Sendable {
    private struct Node {
        var rowid: Int32
        var song: Song
        var previous: Int
        var next: Int
    }

    public let capacity: Int
    private let lock = NSLock()
    private var nodes: [Node] = []
    private var slotByRowid: [Int32: Int] = [:]
    private var freeSlots: [Int] = []
    /// 最近用过的在头。
    private var head = -1
    private var tail = -1

    public init(capacity: Int = LibraryScale.rowCacheCapacity) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { lock.withLock { slotByRowid.count } }

    /// 按给定顺序返回这些行的歌;不在目录里(已删除)的位置是 nil。
    /// 一次最多物化 `LibraryScale.maxMaterializedRows` 行。
    public func songs(
        forRowids rowids: some Collection<Int32>,
        in catalog: LibraryCatalog,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws -> [Song?] {
        let admitted = LibraryScaleGuard.admitMaterialization(count: rowids.count, file: file, line: line)
        let requested = Array(rowids.prefix(admitted))
        var result = [Song?](repeating: nil, count: requested.count)
        var missing: [Int32] = []
        lock.withLock {
            for (offset, rowid) in requested.enumerated() {
                if let slot = slotByRowid[rowid] {
                    result[offset] = nodes[slot].song
                    touch(slot)
                } else {
                    missing.append(rowid)
                }
            }
        }
        guard !missing.isEmpty else { return result }
        let fetched = try catalog.songsByRowid(missing)
        lock.withLock {
            for rowid in missing {
                if let song = fetched[rowid] { insert(song, for: rowid) }
            }
        }
        for (offset, rowid) in requested.enumerated() where result[offset] == nil {
            result[offset] = fetched[rowid]
        }
        return result
    }

    /// 目录变更后丢掉受影响的行。
    public func invalidate(rowids: some Sequence<Int32>) {
        lock.withLock {
            for rowid in rowids {
                guard let slot = slotByRowid.removeValue(forKey: rowid) else { continue }
                unlink(slot)
                freeSlots.append(slot)
            }
        }
    }

    public func invalidate(_ summary: LibraryCatalogChangeSummary) {
        invalidate(rowids: summary.updatedRowids)
        invalidate(rowids: summary.deletedRowids)
    }

    public func removeAll() {
        lock.withLock {
            nodes.removeAll()
            slotByRowid.removeAll()
            freeSlots.removeAll()
            head = -1
            tail = -1
        }
    }

    // MARK: - LRU list (call with the lock held)

    private func insert(_ song: Song, for rowid: Int32) {
        if let slot = slotByRowid[rowid] {
            nodes[slot].song = song
            touch(slot)
            return
        }
        if slotByRowid.count >= capacity, tail >= 0 {
            let evicted = tail
            slotByRowid.removeValue(forKey: nodes[evicted].rowid)
            unlink(evicted)
            freeSlots.append(evicted)
        }
        let node = Node(rowid: rowid, song: song, previous: -1, next: head)
        let slot: Int
        if let free = freeSlots.popLast() {
            nodes[free] = node
            slot = free
        } else {
            slot = nodes.count
            nodes.append(node)
        }
        if head >= 0 { nodes[head].previous = slot }
        head = slot
        if tail < 0 { tail = slot }
        slotByRowid[rowid] = slot
    }

    private func touch(_ slot: Int) {
        guard slot != head else { return }
        unlink(slot)
        nodes[slot].previous = -1
        nodes[slot].next = head
        if head >= 0 { nodes[head].previous = slot }
        head = slot
        if tail < 0 { tail = slot }
    }

    private func unlink(_ slot: Int) {
        let previous = nodes[slot].previous
        let next = nodes[slot].next
        if previous >= 0 { nodes[previous].next = next } else if head == slot { head = next }
        if next >= 0 { nodes[next].previous = previous } else if tail == slot { tail = previous }
        nodes[slot].previous = -1
        nodes[slot].next = -1
    }
}
