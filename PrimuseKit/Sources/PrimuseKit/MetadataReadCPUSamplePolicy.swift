import Foundation

/// 一次标签读取的 CPU 测量窗口快照。
///
/// 读取的 CPU 代价用 `getrusage(RUSAGE_SELF)` 量，那是**整个进程**的 CPU，所以
/// 读取窗口里只要发生过别的重活，就会被记到这一首头上。
public struct MetadataReadCPUSampleWindow: Sendable, Equatable {
    public let publishGeneration: UInt64
    public let publishInFlight: Bool

    public init(publishGeneration: UInt64, publishInFlight: Bool) {
        self.publishGeneration = publishGeneration
        self.publishInFlight = publishInFlight
    }
}

/// 哪些读取可以作为"这一首标签有多贵"的样本。
///
/// `recentProcessingDuration` 的唯一用途是决定发热后每读一首该歇多久，而资料库
/// 发布的代价与读取速度无关：它按批摊销，歇得更久一点也不会让它变便宜，只会让
/// 同样的发布代价落在更少的歌上。把它算进读取成本，等于让"发布批次有多大"去
/// 决定"每读一首歇多久"，而 `recordProcessingDuration` 的 `max(duration, …)`
/// 会锁住峰值，所以一个被污染的样本会压住随后许多次读取。
///
/// 实测 (2026-09-12，18405 首云端曲库)：发布每次 5.4 首时，耗时超过 1.6s 的
/// 读取间隔有 23.7% 跨过一次发布，而正常间隔只有 6.6% —— 污染是可观测的。
/// 发布合并到每次 18 首之后这两个数字降到 6.2% 与 2.8%，但每次发布的代价也
/// 相应变大，所以剔除污染样本比以前更要紧。
public enum MetadataReadCPUSamplePolicy {
    /// 只有完整落在两次资料库发布之间的读取才是有效样本。
    ///
    /// 四种情形：窗口整段在发布之前 → 有效；跨进发布、从发布中开始、
    /// 以及整段都在同一次发布之内 → 一律丢弃，保留上一次的估算。
    public static func acceptsSample(
        before: MetadataReadCPUSampleWindow,
        after: MetadataReadCPUSampleWindow
    ) -> Bool {
        !before.publishInFlight && before == after
    }
}
