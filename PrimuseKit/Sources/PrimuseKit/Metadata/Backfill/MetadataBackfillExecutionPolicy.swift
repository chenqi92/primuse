import Foundation

/// Controls how aggressively the metadata queue uses network and CPU time.
/// iOS background work deliberately favors continuity over throughput, and
/// becomes even gentler while audio is the user-facing foreground workload.
public enum MetadataBackfillExecutionMode: Sendable, Equatable {
    case standard
    /// The user explicitly asked one source to keep reading. The selected
    /// reading mode applies while additional snapshots run and the scene stays
    /// active. Per-song failures are recorded and skipped instead of ending the
    /// source job.
    case userInitiated
    /// The iOS Files importer has already copied audio into the app sandbox.
    /// Keep consuming bounded snapshots while the scene remains active; this
    /// work is fully offline and must not inherit cloud-source network gates.
    case foregroundDeviceLocal
    /// A source scan just committed new bare rows while the iOS scene is
    /// interactive. Continue through small serial snapshots while the app stays
    /// active so the scan naturally finishes reading tags without monopolizing
    /// the network or competing with playback.
    case foregroundAfterSourceScan
    /// Runs bounded snapshots until the queue drains or iOS ends execution.
    /// A granted continued-processing task retains the selected reading speed.
    case background
    case backgroundDuringPlayback
}

public struct MetadataBackfillExecutionLimits: Sendable, Equatable {
    public let workerCount: Int
    public let snapshotLimit: Int
    public let interRequestDelay: TimeInterval
    public let flushInterval: TimeInterval
    /// 攒满多少首就发布一次资料库。一次发布的代价与整库规模成正比, 与这一批
    /// 有几首无关, 所以它必须是"按完成量"触发的那一个闸门; `flushInterval`
    /// 只是慢档位下的兜底。两者都必须远大于首页的重算节流窗口, 否则每一次
    /// 发布都换来一次整库重算。
    public let flushBatchSize: Int
    public let snapshotPassLimit: Int?

    public init(
        workerCount: Int,
        snapshotLimit: Int,
        interRequestDelay: TimeInterval,
        flushInterval: TimeInterval,
        flushBatchSize: Int = 64,
        snapshotPassLimit: Int? = nil
    ) {
        self.workerCount = workerCount
        self.snapshotLimit = snapshotLimit
        self.interRequestDelay = interRequestDelay
        self.flushInterval = flushInterval
        self.flushBatchSize = max(1, flushBatchSize)
        self.snapshotPassLimit = snapshotPassLimit
    }
}

extension MetadataBackfillExecutionLimits {
    public func withWorkerCount(_ count: Int) -> Self {
        .init(workerCount: max(0, count), snapshotLimit: snapshotLimit,
              interRequestDelay: interRequestDelay, flushInterval: flushInterval,
              flushBatchSize: flushBatchSize, snapshotPassLimit: snapshotPassLimit)
    }
}

public enum MetadataBackfillExecutionPolicy {
    /// Only a plain `.background` window is bounded by the UIKit background
    /// assertion. Foreground modes never hold it and background playback is
    /// kept alive by the audio session, so an assertion that expired earlier
    /// must not veto the queue when one of those modes begins.
    public static func clearsBackgroundExpiration(entering mode: MetadataBackfillExecutionMode) -> Bool {
        mode != .background
    }

    /// Process CPU time includes parsing, playback, and UI work across executor
    /// hops, while disk/network waits do not inflate the thermal work budget.
    /// An unavailable or invalid counter keeps the conservative wall-time fallback.
    ///
    /// `concurrentReads` 是这一首读取期间同时在读的读取位数(含自己)。进程 CPU
    /// 把同一时段里其他读取位的解析也算了进来, 而休息预算按「每位的代价 ×
    /// (2×位数−1)」折算, 不分摊就等于把别人的活记到每一位头上, 歇息被放大
    /// 位数倍 —— 自动档几乎一直顶在上限。只有一位在读时(发热降到单位)不变。
    public static func processingDuration(
        cpuTimeBefore: TimeInterval?, cpuTimeAfter: TimeInterval?,
        fallback: TimeInterval, concurrentReads: Int = 1
    ) -> TimeInterval {
        guard let before = cpuTimeBefore, let after = cpuTimeAfter,
              before.isFinite, after.isFinite, before >= 0, after >= before else {
            return fallback.isFinite && fallback >= 0 ? fallback : 0.5
        }
        return (after - before) / Double(max(1, concurrentReads))
    }

    public static let highPerformanceAfterScanDefaultsKey =
        "primuse.metadataBackfill.highPerformanceAfterScan"
    public static let readingModeDefaultsKey = "primuse.metadataBackfill.readingMode"

    public static func limits(
        for mode: MetadataBackfillExecutionMode,
        highPerformanceAfterScanEnabled: Bool = false
    ) -> MetadataBackfillExecutionLimits {
        limits(for: mode, preference: highPerformanceAfterScanEnabled ? .fast : .automatic)
    }

    /// 暂停档只关掉自动队列。用户主动发起的单源任务照常跑。
    public static func honoursPausedPreference(
        _ mode: MetadataBackfillExecutionMode
    ) -> Bool {
        mode != .userInitiated
    }

    public static func constraint(
        for mode: MetadataBackfillExecutionMode,
        environment: MetadataReadingEnvironment,
        preference: MetadataReadingMode = .automatic
    ) -> MetadataReadingConstraint {
        // 用户把读取关掉了, 这压过任何设备侧的理由。
        if !preference.readsAutomatically { return .paused }
        if environment.thermalState == .critical { return .cooling }
        if environment.thermalState == .serious || environment.thermalState == .fair {
            return .thermal
        }
        if mode == .background || mode == .backgroundDuringPlayback { return .background }
        if environment.lowPowerMode { return .lowPower }
        if environment.playbackActive { return .playback }
        return .none
    }

    public static func limits(
        for mode: MetadataBackfillExecutionMode,
        preference: MetadataReadingMode,
        environment: MetadataReadingEnvironment = .init(),
        continuedProcessing: Bool = false,
        recentProcessingDuration: TimeInterval? = nil
    ) -> MetadataBackfillExecutionLimits {
        let isBackground = mode == .background || mode == .backgroundDuringPlayback
        let offline = environment.offlineSource || mode == .foregroundDeviceLocal
        // 获批的续跑窗口保留所选档位, 发布节奏也跟着回到前台口径。
        let usesBackgroundCadence = isBackground && !continuedProcessing
        let playing = mode == .backgroundDuringPlayback
        // 暂停只关掉自动队列, 用户主动发起的任务照常跑 (按最保守的档位)。
        let preference = honoursPausedPreference(mode)
            ? preference
            : preference.resolvedForExplicitWork
        // 读取关掉时不给任何读取位, 也不让 worker 再取下一个快照。
        guard preference.readsAutomatically else {
            return MetadataBackfillExecutionLimits(
                workerCount: 0,
                snapshotLimit: 1,
                interRequestDelay: 0,
                flushInterval: publishInterval(
                    for: preference, isBackground: usesBackgroundCadence, playing: playing
                ),
                flushBatchSize: publishBatchSize,
                snapshotPassLimit: 0
            )
        }
        let ceiling = environment.device.maximumWorkers(
            offlineSource: offline,
            pooledHTTPRemoteSource: environment.pooledHTTPRemoteSource
        )
        let automatic = offline ? min(4, (ceiling + 2) / 2) : min(3, (ceiling + 1) / 2)
        var workers = preference == .fast ? ceiling : min(ceiling, automatic)
        var delay: TimeInterval = 0
        var snapshot = preference == .fast ? 192 : 96
        // 发布节奏只看档位与执行模式, 不跟着快照大小走: 一次发布的代价与整库
        // 规模成正比, 快照变小只会让同样的代价摊到更少的歌上。
        let flush = publishInterval(
            for: preference, isBackground: usesBackgroundCadence, playing: playing
        )
        let flushBatch = publishBatchSize
        if preference == .energySaving {
            workers = 1
            delay = offline ? 0.1 : 0.75
            snapshot = 48
        }
        if environment.playbackActive {
            // 全速是用户主动选的偏好，播放期间给它三个读取位而不是两个。
            //
            // 远程标签读取绝大部分时间花在等网络上，真正占 CPU 的解析很短；
            // 缓冲调度也已经不在主线程上，播放不再受读取节奏牵动。两个读取位
            // 会让内网 NAS 的整库读取慢到肉眼可见，而第三个位带来的额外压力
            // 主要落在网络等待上。其余偏好保持原样：自动仍是保守的单位，
            // 电视只有一个位。
            let playbackCeiling: Int
            if environment.device.platform == .television {
                playbackCeiling = 1
            } else if preference == .fast {
                playbackCeiling = 3
            } else {
                playbackCeiling = offline ? 2 : 1
            }
            workers = min(workers, playbackCeiling)
        }
        if environment.lowPowerMode {
            workers = 1
            delay = max(delay, offline ? 0.1 : 0.35)
        }
        if usesBackgroundCadence {
            workers = 1
            snapshot = playing ? 8 : 24
            delay = max(delay, preference == .fast ? 0 : (playing ? 1.5 : 0.75))
        }
        // 刚扫完一个源、App 在前台时, 用户正等着这批歌的标签: 自动档在系统报热
        // 之前不预先歇, 和用户点「读取标签」一样。一旦报热(fair 起)、低电量、
        // 放歌, 下面各自的降速照常生效; 节能档与平时的维护补读仍预留 CPU 余量。
        let userAwaitsScanResults = preference == .automatic
            && (mode == .foregroundAfterSourceScan || mode == .foregroundDeviceLocal)
            && environment.thermalState == .nominal
        if mode != .userInitiated, preference != .fast, !userAwaitsScanResults,
           environment.thermalState == .nominal || environment.thermalState == .fair {
            let warm = environment.thermalState == .fair
            // 每个读取位独立等待, 预算须计入并发数, 否则本地文件多开几个位
            // 就会把休息时间抵消。自动队列在系统报热之前也留出 CPU 余量。
            let rest = preference == .automatic
                ? MetadataReadingThermalRest(
                    multiplier: warm ? 7 : Double(max(1, 2 * workers - 1)),
                    floor: warm ? 0.75 : 0.15 * Double(workers),
                    ceiling: 1.5
                )
                : MetadataReadingThermalRest(
                    multiplier: warm ? 14 : 10,
                    floor: warm ? 1 : 0.75,
                    ceiling: 3
                )
            delay = max(delay, rest.cooldown(recentProcessingDuration: recentProcessingDuration))
        }
        switch environment.thermalState {
        case .nominal: break
        case .fair:
            // Full speed still yields capacity at mild warmth. Severe heat
            // and low-power constraints remain authoritative in every mode.
            workers = min(workers, preference == .fast ? max(1, ceiling / 2) : 1)
            if preference != .fast { delay = max(delay, 0.35) }
        case .serious:
            workers = min(workers, 1)
            // 歇多久按最近实测的 CPU 工作量折算 —— 纯等网络的便宜标签不该被按
            // 最坏情况罚站 —— 但折算按档位分层, 所以 `serious` 下档位之间仍然
            // 是严格有序的。缺失/无效的测量退回该档位的天花板, critical 照常暂停。
            delay = max(
                delay,
                MetadataReadingThermalRest.budget(for: preference)
                    .cooldown(recentProcessingDuration: recentProcessingDuration)
            )
        case .critical:
            workers = 0
        }
        return MetadataBackfillExecutionLimits(
            workerCount: workers,
            snapshotLimit: snapshot,
            interRequestDelay: delay,
            flushInterval: flush,
            flushBatchSize: flushBatch,
            snapshotPassLimit: nil
        )
    }

    /// 两次资料库发布之间的最小间隔。
    ///
    /// 发布一次要重发两个上万元素的可观察数组, 并让首页/搜索/CarPlay 目录各做
    /// 一次整库重算 —— 这笔钱与这一批有几首无关。原先前台是 5 秒 (节能 10 秒),
    /// 比首页的重算节流窗口还短, 于是每一次发布都换来一次整库重算, 降档只是
    /// 让同样的代价摊到更少的歌上。这里的间隔必须大于
    /// `LibraryDerivedRefreshPolicy.minimumInterval`, 并且随档位单调变长。
    public static func publishInterval(
        for preference: MetadataReadingMode,
        isBackground: Bool,
        playing: Bool
    ) -> TimeInterval {
        let base: TimeInterval = switch preference {
        case .fast: 20
        case .automatic: 30
        case .energySaving, .paused: 60
        }
        guard isBackground else { return base }
        // 后台没有可见界面要喂, 发布只为让检查点落地。
        return max(base, playing ? 60 : 45)
    }

    /// 攒满多少首就发布一次, 不等 `publishInterval`。这是主闸门: 发布次数因此
    /// 与真正完成的工作量成正比, 而不是与挂钟时间或快照边界成正比。
    ///
    /// 它刻意不分档位: "列表里的新标题最多落后多少首"是一个与读取速度无关的
    /// 体感上限, 按档位调低它只会让慢档位反而发布得更频繁 —— 原先按快照边界
    /// 收尾就是这个错误的极端形式。
    public static let publishBatchSize = 64
}
