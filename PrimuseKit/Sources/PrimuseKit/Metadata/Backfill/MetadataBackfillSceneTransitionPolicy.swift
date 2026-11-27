import Foundation

/// 元数据回填在场景切换上的处置策略。
///
/// 回填的一次读取是一段 Range 下载。`.inactive` 上直接取消 worker, 会把刚刚
/// 读完、还没回调的那几首连同已下载的字节一起丢掉 —— 调度器的消费循环在
/// `Task.isCancelled` 上先一步 break, 排队的完成事件根本没机会落库, 下一次
/// `start()` 只能重新下载。临时遮挡 (控制中心 / 来电 / Face ID) 因此改成暂停:
/// 在飞的读取照常收尾并记账, 但不再发起新的 I/O。
/// 真正进入后台与 BGProcessing 到期仍然是硬停止 —— 那两处要的是立刻交出
/// 执行权并让检查点落地。
public enum MetadataBackfillSceneTransitionPolicy {
    public enum Disposition: Sendable, Equatable {
        /// 保留 worker 与队列, 只把并发降到 0。
        case pause
        /// 取消 worker, 交出后台断言, 落地状态。
        case hardStop
        /// 解除暂停, 让 worker 继续吃同一批快照。
        case resume
    }

    public static func disposition(
        phase: ScenePhaseKind,
        isPlaybackActive: Bool,
        isSystemBackgroundProcessing: Bool
    ) -> Disposition {
        // BGProcessing 会话到期压过相位: 系统已经要收回执行权了。
        if isSystemBackgroundProcessing { return .hardStop }
        switch phase {
        case .inactive:
            return .pause
        case .background:
            // 后台播放让进程继续活着, 但回填的后台档位由 `.background` 分支
            // 自己重新启动, 这里给出的仍是"先硬停止"。
            _ = isPlaybackActive
            return .hardStop
        case .active:
            return .resume
        }
    }

    /// 暂停期间的并发数。调度器内层 `while` 拿到 0 就一个都不放行, 外层
    /// `for await` 原地空转 —— 这正好是一次暂停, 而不是一次取消。
    public static func workerCount(base: Int, isPaused: Bool) -> Int {
        isPaused ? 0 : max(0, base)
    }

    /// 暂停期间要不要把攒下的结果发布进资料库。
    ///
    /// 场景静默的整个意义就是不在过渡窗口里重发那两个上万元素的可观察数组,
    /// 所以暂停时只累积不发布; 最后一批 (worker 收尾 / 硬停止) 不受此限,
    /// 否则那一批会随着局部变量一起消失。
    public static func shouldPublishFlush(isPaused: Bool, isFinalFlush: Bool) -> Bool {
        isFinalFlush || !isPaused
    }
}
