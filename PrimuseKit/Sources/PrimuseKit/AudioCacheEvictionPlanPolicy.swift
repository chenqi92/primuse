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

/// 离线下载的歌除了缓存目录里那个入口, 在离线目录(不会被系统清理)里还有一个
/// 指向同一份数据的硬链接。这里决定一个文件的两个入口该怎么对齐。纯函数,
/// 不碰文件系统: 两边是不是同一个文件由调用方按 (设备, inode) 判断好再传进来。
public enum OfflineAudioMirrorPolicy {
    public struct FileIdentity: Sendable, Equatable {
        public let device: UInt64
        public let inode: UInt64

        public init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    public enum Action: Sendable, Equatable {
        case keep
        /// 把缓存目录里的文件链进离线目录, 离线目录里有旧的就换掉。
        case mirror
        /// 缓存目录被系统清过: 从离线目录把入口链回缓存目录。
        case restore
        /// 离线目录里这个入口不该再留着。
        case drop
    }

    /// 缓存目录是读写的正本, 两边不一致时以它为准。缓存目录里没有、离线目录
    /// 里有, 只有在缓存目录被整体清掉过时才是「丢了要找回」; 平时就是歌被
    /// 有意删掉了(移除、内容更新、转成精简副本), 跟着删。
    public static func action(
        isPinned: Bool,
        cacheFile: FileIdentity?,
        mirrorFile: FileIdentity?,
        cacheDirectoryIntact: Bool
    ) -> Action {
        guard isPinned else { return mirrorFile == nil ? .keep : .drop }
        switch (cacheFile, mirrorFile) {
        case (nil, nil):
            return .keep
        case (.some, nil):
            return .mirror
        case let (.some(cache), .some(mirror)):
            return cache == mirror ? .keep : .mirror
        case (nil, .some):
            return cacheDirectoryIntact ? .drop : .restore
        }
    }
}
