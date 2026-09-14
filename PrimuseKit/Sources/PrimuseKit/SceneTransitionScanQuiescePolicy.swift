import Foundation

/// SwiftUI 的 `ScenePhase` 在 PrimuseKit 里的纯值镜像。Kit 不链接 SwiftUI,
/// 所以场景相关的判定策略用这个枚举表达。
public enum ScenePhaseKind: Sendable, Equatable {
    case active
    case inactive
    case background
}

/// 场景切换时扫描的静默策略。
///
/// iOS 在控制中心下拉、来电横幅、Face ID 弹窗这些临时遮挡上也会先发一个
/// `.inactive`, 紧接着又回到 `.active`; 真正进入后台才会继续发 `.background`。
/// 在 `.inactive` 上立刻取消扫描, 这类"闪一下"就会白白丢掉预检、登录与已经
/// 走过的目录, 回到前台后再从检查点重来一遍。
public enum SceneTransitionScanQuiescePolicy {
    public enum CancelDisposition: Sendable, Equatable {
        /// 防抖窗口内又回到前台: 扫描原样继续, 不取消。
        case skip
        /// 真的进入后台, 或者窗口到期仍未回到前台: 现在取消。
        case cancelNow
    }

    /// `.inactive` 之后等多久才真正取消扫描。窗口要短于用户能察觉的中断,
    /// 又要长到覆盖控制中心 / 通知中心的一次下拉上推。
    public static let inactiveCancelDebounce: TimeInterval = 0.6

    /// 后台音频让 `UIApplication.backgroundTimeRemaining` 返回
    /// `.greatestFiniteMagnitude`。任何大得离谱的剩余时间都按"窗口无限"处理。
    public static let unboundedBackgroundWindow: TimeInterval = 3600

    /// 续扫在真正读目录之前的固定开销 (登录、诊断、检查点回灌)。窗口连这段
    /// 都装不下时, 恢复出来的只有开销, 没有进度。
    public static let estimatedPreflightSeconds: TimeInterval = 10

    /// 防抖窗口内观察到的下一个相位决定这次取消要不要真的发生。
    /// - Parameter nextPhaseWithinDebounce: 窗口内到达的下一个相位;
    ///   `nil` 表示窗口到期都没有新相位。
    public static func cancelDisposition(
        nextPhaseWithinDebounce: ScenePhaseKind?
    ) -> CancelDisposition {
        switch nextPhaseWithinDebounce {
        case .active:
            // 控制中心 / 来电 / Face ID: 场景从没真的离开前台。
            return .skip
        case .background:
            // 挂起近在眼前, 检查点必须在这一刻就落地。
            return .cancelNow
        case .inactive, .none:
            return .cancelNow
        }
    }

    /// 后台窗口够不够把续扫跑出进度。
    ///
    /// 有后台音频时进程本来就活着, 窗口是无限的, 照常续扫 (#99: 后台播放不能
    /// 反过来把扫描停掉)。没有音频时窗口是有限的几十秒: 窗口连预检都装不下、
    /// 而且已经排好了 BGProcessing 唤醒, 就把这轮让给那次唤醒; 没有排上唤醒
    /// 则宁可在窄窗口里跑一段, 绝不把活儿彻底搁下。
    public static func shouldResumeInFiniteBackgroundWindow(
        secondsRemaining: TimeInterval,
        estimatedPreflightSeconds: TimeInterval = estimatedPreflightSeconds,
        isBackgroundPlaybackActive: Bool,
        hasScheduledProcessingWake: Bool
    ) -> Bool {
        if isBackgroundPlaybackActive { return true }
        guard secondsRemaining.isFinite,
              secondsRemaining < unboundedBackgroundWindow else { return true }
        guard hasScheduledProcessingWake else { return true }
        return secondsRemaining > max(0, estimatedPreflightSeconds)
    }
}

/// 一次用户发起的扫描要不要向系统申请 continued processing 时间 (iOS 26+)。
///
/// 除了后台音频, iOS 没有别的办法让一次长任务在用户离开 app 之后继续跑:
/// `beginBackgroundTask` 只有 ~30 秒, BGProcessing 的唤醒时机由系统决定。
/// 标签读取已经走这条路, 所以它在后台能接着读; 扫描没有, 用户一离开 app
/// 扫描就停在检查点上, 回来还得再点一次「继续扫描」(#99)。
public enum ScanContinuedProcessingPolicy {
    public enum Disposition: Sendable, Equatable {
        /// 申请一次新的系统任务。
        case submit
        /// 已经有一个仍在授权期内的会话, 沿用它。
        case keepExisting
        /// 不申请。
        case skip
    }

    /// - Parameters:
    ///   - isForegroundOnlySource: 这个源的扫描按策略只在前台跑 (百度网盘的
    ///     快照遍历), 不该被放到后台继续。
    ///   - hasUserInitiatedIntent: 本进程内这个源的当前扫描意图来自用户的
    ///     前台操作。
    public static func requestDisposition(
        context: BaiduSnapshotExecutionContext,
        isForegroundOnlySource: Bool,
        isApplicationActive: Bool,
        hasUserInitiatedIntent: Bool,
        hasExistingSession: Bool
    ) -> Disposition {
        // 系统只接受前台、由用户动作触发的申请。
        guard isApplicationActive, !isForegroundOnlySource else { return .skip }
        switch context {
        case .userInitiatedForeground:
            break
        case .foregroundResume:
            // 会话被系统收回之后用户回到前台: 用户的意图还在, 续一次。冷启动
            // 时没有这份意图, 所以启动期的自动续扫不会弹出系统任务卡片。
            guard hasUserInitiatedIntent else { return .skip }
        case .background:
            return .skip
        }
        return hasExistingSession ? .keepExisting : .submit
    }

    /// 系统收回执行权时要不要取消扫描。app 还在前台就不取消 —— 扫描回到普通
    /// 的前台生命周期继续跑, 取消只会白丢掉预检与已经走过的目录。
    public static func cancelsScanOnExpiration(isApplicationActive: Bool) -> Bool {
        !isApplicationActive
    }

    /// 系统任务卡片上的进度。连接器扫描要走完整棵树才知道总数, 在那之前
    /// `totalCount` 是 0 —— 这时交出一个不确定进度, 而不是一条永远贴着满格
    /// 的进度条。
    public static func progressUnits(
        scannedCount: Int,
        totalCount: Int
    ) -> (completed: Int64, total: Int64) {
        guard totalCount > 0 else { return (0, 0) }
        return (Int64(min(max(0, scannedCount), totalCount)), Int64(totalCount))
    }

    /// 卡片副标题。总数未知时只报已扫描的数量。
    public static func progressSubtitle(
        sourceName: String,
        scannedCount: Int,
        totalCount: Int
    ) -> String {
        let scanned = max(0, scannedCount)
        let counts = totalCount > 0
            ? "\(min(scanned, totalCount)) / \(totalCount)"
            : "\(scanned)"
        guard !sourceName.isEmpty else { return counts }
        return "\(sourceName) · \(counts)"
    }
}
