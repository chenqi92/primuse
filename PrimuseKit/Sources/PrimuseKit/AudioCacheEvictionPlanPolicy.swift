import Foundation

/// 决定 LRU 淘汰要删哪些缓存条目。纯函数, 不碰文件系统: 候选集、排除集与
/// 需要腾出的字节数都由调用方在 actor 上快照好再传进来。
public enum AudioCacheEvictionPlanPolicy {
    public struct Candidate: Sendable, Equatable {
        public let relativePath: String
        public let size: Int64
        public let lastUsed: Date

        public init(relativePath: String, size: Int64, lastUsed: Date) {
            self.relativePath = relativePath
            self.size = size
            self.lastUsed = lastUsed
        }
    }

    /// 最旧的优先, 累计到 `neededBytes` 即停。排除集里的路径(正在播放 /
    /// 正在传输 / 受保护)与非正尺寸条目一律跳过。
    public static func plan(
        candidates: [Candidate],
        excludedPaths: Set<String>,
        neededBytes: Int64
    ) -> [Candidate] {
        guard neededBytes > 0 else { return [] }
        let eligible = candidates
            .filter { $0.size > 0 && !excludedPaths.contains($0.relativePath) }
            .sorted { $0.lastUsed < $1.lastUsed }

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
