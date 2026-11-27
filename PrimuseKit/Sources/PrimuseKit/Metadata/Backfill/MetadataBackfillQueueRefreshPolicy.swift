import Foundation

/// 整库剩余数对账的节流策略。off-main 变体回到主 actor 时会重新校验代次与
/// 输入集合, 校验失败就丢弃这次结果; 问题是失败之后要不要把节流时间戳退回
/// `.distantPast` (等于放行下一次对账立刻整库重算)。
public enum MetadataBackfillRemainingCountRefreshPolicy {
    public enum StaleReason: Sendable, Equatable {
        /// 计算代次被顶替: 又有一次刷新在跑 (例如连续两批扫描结果各自触发了
        /// 一次延后对账, 后一次取消了前一次, 但前一次的 detached 计算仍会跑完
        /// 并先回到主 actor)。接管的那一次会自己负责发布结果。
        case supersededComputation
        /// 计算期间资料库 / 队列 / 源集合真的变了, 这次结果对不上现状。
        case inputsChanged
    }

    /// 只有输入真的变了才回退节流时间戳。被顶替的那次若也回退, 接管者随后
    /// 调用的 `start()` 会发现节流已失效, 又在主 actor 上把整库对账同步做一遍
    /// —— 正是把对账挪到主 actor 之外想避免的那次开销。
    public static func throttleResetsAfterFailure(reason: StaleReason) -> Bool {
        switch reason {
        case .supersededComputation: false
        case .inputsChanged: true
        }
    }

    /// 这次 off-main 计算结果的处置。
    public enum Application: Sendable, Equatable {
        /// 什么都没动: 数字与队列对账一起落地。
        case apply
        /// 只有歌曲代次动了 (扫描 flush、回填自己的发布): 数字是一份一致的
        /// 过去状态, 可以发布给源卡片; 但队列仍然脏着, 下一次对账照旧要跑。
        case applyKeepingQueueDirty
        /// 结果回答的已经是另一个问题: 丢弃。
        case discard
    }

    /// 把"快照稍微旧了一点"和"快照回答的是另一个问题"分开。
    ///
    /// 扫描期间资料库每 1.5 s 就发布一次, 歌曲代次几乎必然在 detached 计算
    /// 跑完之前就动了。把它和源集合 / 禁用集合 / 队列代次这些语义变化归成
    /// 同一类丢弃, 结果就是整场扫描里源卡片的剩余数一直冻着, 而队列对账也
    /// 永远补不上, 下一次 `start()` 只能在主 actor 上把整库同步走一遍。
    public static func application(
        superseded: Bool,
        songGenerationChanged: Bool,
        queueGenerationChanged: Bool,
        semanticInputsChanged: Bool
    ) -> Application {
        if superseded || queueGenerationChanged || semanticInputsChanged {
            return .discard
        }
        return songGenerationChanged ? .applyKeepingQueueDirty : .apply
    }
}

/// How `MetadataBackfillService.refreshQueue` reconciles the queue after
/// marking it dirty. Every library publication (a scan flush) lands here, and
/// the reconcile it triggers walks the whole library on the main actor, so the
/// automatic path hands that pass to the existing off-main variant instead.
public enum MetadataBackfillQueueRefreshPolicy {
    public enum Reconciliation: Sendable, Equatable {
        /// Only mark the queue dirty; no worker is requested.
        case markDirtyOnly
        /// Reconcile through the off-main variant first, then start.
        case deferredOffMain
        /// Start on the caller's turn; `start()` reconciles synchronously.
        case synchronous
    }

    /// - Parameters:
    ///   - startImmediately: the caller also wants a worker started.
    ///   - workerIsRunning: `start()` is a no-op while a worker is in flight.
    ///   - requiresSynchronousStart: a system background-processing session or
    ///     a continued-processing grant is waiting on the worker. Those drains
    ///     poll `worker != nil` (`waitUntilIdle`), so deferring `start()` to a
    ///     later turn would let the background task complete without work.
    public static func reconciliation(
        startImmediately: Bool,
        workerIsRunning: Bool,
        requiresSynchronousStart: Bool
    ) -> Reconciliation {
        guard startImmediately, !workerIsRunning else { return .markDirtyOnly }
        return requiresSynchronousStart ? .synchronous : .deferredOffMain
    }
}
