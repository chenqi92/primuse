import Foundation

/// 标签读取状态页里对筛选结果发起的一批重读。按音乐源一批, 由回填服务持有,
/// 页面只发起、显示、暂停 / 继续 / 取消 —— 离开页面、关掉弹出页都不影响它。
///
/// 这里只管账: 哪些还没读、哪些交给了调度器、读完的各算哪一类、现在处在哪个阶段。
/// 真正的读取、并发预算和后台时间由服务决定。
public struct MetadataTagRereadQueue: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case running
        /// 用户点了暂停: 不再发起新的读取, 读完的保留, 点继续接着读剩下的。
        case paused
        /// 系统收回了执行时间(退到后台、后台时间到期): 剩下的记着,
        /// 回到前台自动接着读。用户看到的仍是「在读」, 不单独提示。
        case suspended
        case finished
        case cancelled
    }

    /// 一批一个: 被取消的旧批还在收尾时, 它迟到的结果不会记进同一个源上新起的那一批。
    public let id: UUID
    public private(set) var phase: Phase
    /// 这一批里所有歌, 按加入的先后。去重后只增不减, 进度的总数就是它的长度。
    private var order: [String]
    private var members: Set<String>
    /// 已经有结果的(读完、失败或跳过), 不会再读。
    private var settled: Set<String> = []
    /// 交给当前这一趟调度器、还没有结果的。调度器退出时放回待读。
    private var dispatched: Set<String> = []
    public private(set) var completed = 0
    public private(set) var failed = 0
    public private(set) var skipped = 0
    /// 完成的结果提示是否已经给过用户。页面重建时据此不重复弹。
    public private(set) var resultAnnounced = false

    public init(songIDs: [String], id: UUID = UUID()) {
        self.id = id
        var seen = Set<String>()
        order = songIDs.filter { seen.insert($0).inserted }
        members = seen
        phase = order.isEmpty ? .finished : .running
    }

    public var total: Int { order.count }
    public var processed: Int { completed + failed + skipped }
    /// 还没有结果的首数, 包括交给调度器正在读的。
    public var remainingCount: Int { order.count - settled.count }
    public var isActive: Bool {
        switch phase {
        case .running, .paused, .suspended: true
        case .finished, .cancelled: false
        }
    }

    public var shouldAnnounceResult: Bool { phase == .finished && !resultAnnounced }

    public var progress: MetadataTagRereadProgress {
        var value = MetadataTagRereadProgress(total: total)
        value.completed = completed
        value.failed = failed
        value.skipped = skipped
        value.isCancelled = phase == .cancelled
        return value
    }

    /// 同一个源已有一批没结束时再点一次: 去重后接到这一批后面, 不另起一批、
    /// 也不把前一批顶掉。返回新加入的首数。已经结束或取消的批不再接, 调用方另起一批。
    @discardableResult
    public mutating func merge(_ songIDs: [String]) -> Int {
        guard isActive else { return 0 }
        var added = 0
        for id in songIDs where members.insert(id).inserted {
            order.append(id)
            added += 1
        }
        return added
    }

    /// 交给调度器的下一趟: 还没结果、也不在当前这一趟里的, 按加入顺序, 最多 `limit` 首。
    /// 分段读让新并进来的歌、以及要借用这个源的文件夹重读不必等整批读完。
    /// 只有在读的批才取得出来。
    public mutating func takeNextRun(limit: Int = .max) -> [String] {
        guard phase == .running, limit > 0 else { return [] }
        var next: [String] = []
        for id in order where !settled.contains(id) && !dispatched.contains(id) {
            next.append(id)
            if next.count >= limit { break }
        }
        dispatched.formUnion(next)
        return next
    }

    /// 一首有了结果。暂停或取消之后才回来的读取, 已经写进资料库的照样记上 ——
    /// 「读完的保留」。不在这一批里或已经记过的忽略。
    public mutating func record(_ songID: String, outcome: MetadataTagRereadBatch.Outcome) {
        guard members.contains(songID), settled.insert(songID).inserted else { return }
        dispatched.remove(songID)
        switch outcome {
        case .completed: completed += 1
        case .failed: failed += 1
        case .skipped: skipped += 1
        }
    }

    /// 这一趟调度器退出了(读完、被暂停、被系统打断): 没来得及读的放回待读,
    /// 下一趟按原来的先后接着读。
    public mutating func returnUnfinished() {
        dispatched.removeAll()
    }

    /// 用户暂停。系统打断中的批也可以被用户暂停, 之后回到前台不会自己接着读。
    @discardableResult
    public mutating func pause() -> Bool {
        guard phase == .running || phase == .suspended else { return false }
        phase = .paused
        returnUnfinished()
        return true
    }

    /// 系统收回执行时间。用户暂停的批保持暂停, 不会因为回到前台被自动续上。
    @discardableResult
    public mutating func suspend() -> Bool {
        guard phase == .running else { return false }
        phase = .suspended
        returnUnfinished()
        return true
    }

    /// 用户点继续, 或回到前台自动续。
    @discardableResult
    public mutating func resume() -> Bool {
        guard phase == .paused || phase == .suspended else { return false }
        phase = .running
        return true
    }

    /// 用户取消: 剩下的不读了, 已经读完的保留并照常计数。
    @discardableResult
    public mutating func cancel() -> Bool {
        guard isActive else { return false }
        phase = .cancelled
        returnUnfinished()
        return true
    }

    /// 在读而且全部有了结果: 这一批结束。
    @discardableResult
    public mutating func finishIfDrained() -> Bool {
        guard phase == .running, remainingCount == 0 else { return false }
        phase = .finished
        return true
    }

    public mutating func markResultAnnounced() {
        resultAnnounced = true
    }
}
