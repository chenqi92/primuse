import Foundation

/// 批量刮削停在断点上之后，回到前台时要不要自动从断点接着刮。
///
/// 用户点「停止」会连断点一起清掉，所以断点还在、又没在刮，就不是用户停的：
/// 后台时间用完、进程被挂起或被系统回收、后台开始放歌给播放让路、刮削源一时不可用。
/// 这些情况回到前台都该接着刮，不能只等系统不知哪天才给的 BGProcessing。
///
/// 断点是上一个进程留下的（被系统回收、闪退后重新打开）时多一道防线：上一次打开时
/// 已经从这个位置自动续过、却一首都没往前走进程就没了，很可能正是死在这一段上。
/// 这次不在前台自动续，留给后台任务或用户自己再点，免得每次打开都闪退。
public enum BatchScrapeForegroundResumePolicy {
    public enum Decision: Equatable, Sendable {
        case resume
        case skip(SkipReason)
    }

    public enum SkipReason: String, Equatable, Sendable {
        /// 没有断点：刮完了，或者用户自己停了（停止会清掉断点）。
        case noCheckpoint
        /// 已经在刮了。
        case alreadyRunning
        /// 场景又在离开前台：交给后台那条路接着刮。
        case leavingForeground
        /// 启动安全模式：自动的活儿一律让开。
        case safeMode
        /// 单曲刮削占着，这时开不了批量；下次回到前台再试。
        case singleScrapeRunning
        /// 上一个进程从这里自动续过，一首都没往前走进程就没了。
        case noProgressSinceLastLaunch
    }

    /// 回到前台后先等这么久再续：让开回前台头几帧的界面重建和续扫。
    public static let foregroundResumeDelay: TimeInterval = 3

    /// - Parameters:
    ///   - checkpointFromPreviousProcess: 断点是从盘上读来的、这个进程还没跑过它。
    ///   - resumeIndex: 断点里下一首的位置。
    ///   - lastLaunchResumeIndex: 上一个进程在前台自动续这份断点时的起点，没续过为 nil。
    public static func decision(
        hasCheckpoint: Bool,
        isBatchRunning: Bool,
        isSingleRunning: Bool,
        isApplicationActive: Bool,
        isSafeModeActive: Bool,
        checkpointFromPreviousProcess: Bool,
        resumeIndex: Int,
        lastLaunchResumeIndex: Int?
    ) -> Decision {
        guard hasCheckpoint else { return .skip(.noCheckpoint) }
        guard !isBatchRunning else { return .skip(.alreadyRunning) }
        guard isApplicationActive else { return .skip(.leavingForeground) }
        guard !isSafeModeActive else { return .skip(.safeMode) }
        guard !isSingleRunning else { return .skip(.singleScrapeRunning) }
        // 同一个进程里被打断的（后台到期、放歌让路、源不可用）进程还活着，不是闪退，照常续。
        if checkpointFromPreviousProcess, let lastLaunchResumeIndex, lastLaunchResumeIndex >= resumeIndex {
            return .skip(.noProgressSinceLastLaunch)
        }
        return .resume
    }
}
