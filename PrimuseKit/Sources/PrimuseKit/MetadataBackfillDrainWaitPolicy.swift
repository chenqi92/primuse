import Foundation

/// BGProcessing 处理器等待回填收尾的策略。
///
/// `stop()` 会把在飞的 worker 挪到 `drainingWorker` 再取消它: 那个任务还要跑
/// 完最后一次 flush。只看 `worker` 的等待会在这一刻立刻返回, 处理器随即
/// `complete(success:)`, 已经读到的字节就随进程挂起一起丢了。反过来, 无上限
/// 地等一个已经被取消的收尾任务, 又可能把到期的处理器卡住。
public enum MetadataBackfillDrainWaitPolicy {
    /// 硬停止之后留给收尾任务的宽限时间。
    public static let drainGrace: TimeInterval = 10

    /// 收尾等待的轮询间隔。活着的 worker 是直接 await 的, 这个间隔只用在
    /// "已取消、正在收尾"的那一小段, 所以取得比一帧还短。
    public static let drainPollInterval: TimeInterval = 0.1

    /// 还要不要继续等。
    /// - Parameters:
    ///   - hasWorker: 还有活着的 worker (正常排空, 不设上限)。
    ///   - hasDrainingWorker: 还有已取消、正在收尾的 worker。
    ///   - elapsedSinceStop: 进入等待后已经过去的秒数。
    ///   - grace: 收尾宽限。
    ///   - callerCancelled: 调用方自己被取消了。
    public static func shouldKeepWaiting(
        hasWorker: Bool,
        hasDrainingWorker: Bool,
        elapsedSinceStop: TimeInterval,
        grace: TimeInterval = drainGrace,
        callerCancelled: Bool
    ) -> Bool {
        if callerCancelled { return false }
        if hasWorker { return true }
        guard hasDrainingWorker else { return false }
        return elapsedSinceStop < grace
    }
}
