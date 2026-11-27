import Foundation

/// 按行号物化歌曲的有界 LRU 缓存。缺的行一批从目录取回;容量用满后淘汰最久没用的。
/// 缓存着的行也能按歌曲 id 取(`song(id:in:)`):按 id 读一首不必每次都查目录。
/// 线程安全:内部加锁,取数在锁外进行;取数途中目录变过(有行失效)时取回的行不放进缓存。
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
    /// 缓存着的行的歌曲 id → 槽位(与 `slotByRowid` 同进同出)。
    private var slotByID: [String: Int] = [:]
    private var freeSlots: [Int] = []
    /// 每次失效加一。取数在锁外做:取之前记下它,放进缓存时不一样了就不放
    /// (取到的可能是失效之前的旧行,放进去就一直留着)。
    private var generation: UInt64 = 0
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
        var fetchGeneration: UInt64 = 0
        lock.withLock {
            fetchGeneration = generation
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
            guard generation == fetchGeneration else { return }
            for rowid in missing {
                if let song = fetched[rowid] { insert(song, for: rowid) }
            }
        }
        for (offset, rowid) in requested.enumerated() where result[offset] == nil {
            result[offset] = fetched[rowid]
        }
        return result
    }

    /// 按 id 取一首:缓存里有就不碰目录,没有就按 id 查这一行并放进缓存。目录里没有这首时为 nil(不记)。
    public func song(id: String, in catalog: LibraryCatalog) throws -> Song? {
        var fetchGeneration: UInt64 = 0
        let cached: Song? = lock.withLock {
            fetchGeneration = generation
            guard let slot = slotByID[id] else { return nil }
            touch(slot)
            return nodes[slot].song
        }
        if let cached { return cached }
        guard let fetched = try catalog.songWithRowid(id: id) else { return nil }
        lock.withLock {
            if generation == fetchGeneration { insert(fetched.song, for: fetched.rowid) }
        }
        return fetched.song
    }

    /// 按 id 取一批,与输入一一对应;目录里没有的位置为 nil。缓存里没有的一次查回来。
    /// 一次最多 `LibraryScale.maxMaterializedRows` 首(超出的不取)。一批比缓存的四分之一还大时
    /// 取回的行不放进缓存(一张几千首的歌单不该把列表正在用的行都挤出去)。
    public func songs(
        ids: [String],
        in catalog: LibraryCatalog,
        file: StaticString = #fileID,
        line: UInt = #line
    ) throws -> [Song?] {
        let admitted = LibraryScaleGuard.admitMaterialization(count: ids.count, file: file, line: line)
        let requested = Array(ids.prefix(admitted))
        let keepsFetchedRows = requested.count <= capacity / 4
        var result = [Song?](repeating: nil, count: requested.count)
        var missing: [String] = []
        var fetchGeneration: UInt64 = 0
        lock.withLock {
            fetchGeneration = generation
            for (offset, id) in requested.enumerated() {
                if let slot = slotByID[id] {
                    result[offset] = nodes[slot].song
                    if keepsFetchedRows { touch(slot) }
                } else {
                    missing.append(id)
                }
            }
        }
        guard !missing.isEmpty else { return result }
        let fetched = try catalog.songsWithRowids(ids: missing)
        if keepsFetchedRows {
            lock.withLock {
                guard generation == fetchGeneration else { return }
                for id in missing {
                    if let row = fetched[id] { insert(row.song, for: row.rowid) }
                }
            }
        }
        for (offset, id) in requested.enumerated() where result[offset] == nil {
            result[offset] = fetched[id]?.song
        }
        return result
    }

    /// 目录变更后丢掉受影响的行。
    public func invalidate(rowids: some Sequence<Int32>) {
        lock.withLock {
            generation &+= 1
            for rowid in rowids {
                guard let slot = slotByRowid.removeValue(forKey: rowid) else { continue }
                forgetID(of: slot)
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
            generation &+= 1
            nodes.removeAll()
            slotByRowid.removeAll()
            slotByID.removeAll()
            freeSlots.removeAll()
            head = -1
            tail = -1
        }
    }

    // MARK: - LRU list (call with the lock held)

    private func insert(_ song: Song, for rowid: Int32) {
        // 这个 id 原来记在别的行号上(删掉又加回来的歌换了行号):那一行已经不是它了。
        if let stale = slotByID[song.id], nodes[stale].rowid != rowid {
            slotByRowid.removeValue(forKey: nodes[stale].rowid)
            slotByID.removeValue(forKey: song.id)
            unlink(stale)
            freeSlots.append(stale)
        }
        if let slot = slotByRowid[rowid] {
            if nodes[slot].song.id != song.id { forgetID(of: slot) }
            nodes[slot].song = song
            slotByID[song.id] = slot
            touch(slot)
            return
        }
        if slotByRowid.count >= capacity, tail >= 0 {
            let evicted = tail
            slotByRowid.removeValue(forKey: nodes[evicted].rowid)
            forgetID(of: evicted)
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
        slotByID[song.id] = slot
    }

    /// 槽位让出来之前:它的歌曲 id 还指着它时一并去掉。
    private func forgetID(of slot: Int) {
        let id = nodes[slot].song.id
        if slotByID[id] == slot { slotByID.removeValue(forKey: id) }
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
