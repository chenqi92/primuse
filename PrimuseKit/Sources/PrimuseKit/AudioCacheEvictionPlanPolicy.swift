import Foundation

/// 决定 LRU 淘汰要删哪些缓存条目。纯函数, 不碰文件系统: 候选集、排除集与
/// 需要腾出的字节数都由调用方在 actor 上快照好再传进来。
public enum AudioCacheEvictionPlanPolicy {
    public struct Candidate: Sendable, Equatable {
        public let relativePath: String
        public let size: Int64
        public let lastUsed: Date
        /// 没下完的半成品: 边播边存剩下的 `.partial`、离线下载的临时文件、
        /// 预热的头尾片段等。
        public let isIncomplete: Bool

        public init(
            relativePath: String,
            size: Int64,
            lastUsed: Date,
            isIncomplete: Bool = false
        ) {
            self.relativePath = relativePath
            self.size = size
            self.lastUsed = lastUsed
            self.isIncomplete = isIncomplete
        }
    }

    /// 半成品闲置超过这么久才算下载中断了。刚写过的可能是下一首的预热,
    /// 马上要播, 和完整文件一样按使用时间排。
    public static let abandonedIncompleteAge: TimeInterval = 10 * 60

    /// 中断的半成品先删, 再按最久没用的删完整文件, 累计到 `neededBytes` 即停。
    /// 排除集里的路径(正在播放 / 正在传输 / 受保护)与非正尺寸条目一律跳过。
    public static func plan(
        candidates: [Candidate],
        excludedPaths: Set<String>,
        neededBytes: Int64,
        now: Date = Date()
    ) -> [Candidate] {
        guard neededBytes > 0 else { return [] }
        func isAbandoned(_ candidate: Candidate) -> Bool {
            candidate.isIncomplete
                && now.timeIntervalSince(candidate.lastUsed) >= abandonedIncompleteAge
        }
        let eligible = candidates
            .filter { $0.size > 0 && !excludedPaths.contains($0.relativePath) }
            .sorted { lhs, rhs in
                let lhsAbandoned = isAbandoned(lhs)
                if lhsAbandoned != isAbandoned(rhs) { return lhsAbandoned }
                return lhs.lastUsed < rhs.lastUsed
            }

        var planned: [Candidate] = []
        planned.reserveCapacity(eligible.count)
        var accumulated: Int64 = 0
        for candidate in eligible {
            if accumulated >= neededBytes { break }
            planned.append(candidate)
            accumulated &+= candidate.size
        }
        return planned
    }
}
