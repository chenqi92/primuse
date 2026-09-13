import Foundation

/// 后台标签读取允许占用多大比例的挂钟时间。
///
/// 这是业界对"后台工作不要拖垮前台"的通用解法：预算表达成**占空比**而不是
/// 绝对的等待时间。Go 的 GC pacer 盯住固定的 CPU 占用率，PostgreSQL 的
/// autovacuum 用 `vacuum_cost_limit` 累计抽象工作单位，Chrome 给后台标签页
/// 一份按固定速率再生的时间预算——都是同一个形状。
///
/// 为什么必须是比例：设备发热后会降频，同样的工作量测出来的**时间**会变长。
/// 用"实测耗时 × 固定倍数"算休息，降频会让休息和工作一起变长，看起来比例守住了，
/// 但只要那个实测量里混进了别的活（旧实现量的是整个进程的 CPU 时间），
/// 占空比就会被悄悄压到远低于目标值，吞吐随会话时长塌陷。占空比是无量纲的，
/// 降频时分子分母同时变长，比例不变。
public enum MetadataReadingDutyCycle {
    /// 档位 × 热状态的基准占空比。
    ///
    /// `fast` 在 `nominal` 下是 1.0，也就是完全不限速（与旧实现的 delay=0 一致）。
    /// `serious` 下 `fast` 是 0.25，沿用旧实现对全速定下的同一个目标占空比。
    /// 任何一格都满足 fast > automatic > energySaving。
    public static func baseFraction(
        for preference: MetadataReadingMode,
        thermalState: MetadataReadingThermalState
    ) -> Double {
        switch (preference, thermalState) {
        case (_, .critical): 0
        case (.fast, .nominal): 1
        case (.fast, .fair): 0.5
        case (.fast, .serious): 0.25
        case (.automatic, .nominal): 0.5
        case (.automatic, .fair): 0.25
        case (.automatic, .serious): 0.1
        case (.energySaving, .nominal), (.paused, .nominal): 0.2
        case (.energySaving, .fair), (.paused, .fair): 0.1
        case (.energySaving, .serious), (.paused, .serious): 0.05
        }
    }

    /// 低电量与后台窗口在基准上再收紧。续跑窗口保留所选档位，不算后台。
    public static func activeFraction(
        for preference: MetadataReadingMode,
        thermalState: MetadataReadingThermalState,
        lowPowerMode: Bool,
        usesBackgroundCadence: Bool,
        playing: Bool
    ) -> Double {
        var fraction = baseFraction(for: preference, thermalState: thermalState)
        guard fraction > 0 else { return 0 }
        if lowPowerMode { fraction *= 0.5 }
        if usesBackgroundCadence { fraction *= playing ? 0.25 : 0.5 }
        // 低于这个比例就不是"慢"而是"几乎不动"了，留一个下限。
        return max(0.01, min(1, fraction))
    }
}

/// 按占空比给标签读取限速的令牌桶。
///
/// 桶里的令牌以"可用的工作秒数"计：每过 1 秒挂钟补 `activeFraction` 秒额度，
/// 每完成一次读取按它**实际占用的计算时间**扣除。额度透支时，下一次读取前要等
/// 到补齐为止。
///
/// 相比"按上一次读取的成本预测下一次该歇多久"，令牌桶不做预测：它按真实累计
/// 工作量记账，所以单首成本忽高忽低（实测 0.2s~0.75s）时占空比依然准确，也不需要
/// 对历史成本做 `max()` 锁峰那种会被一个贵样本长期压住的处理。
public struct MetadataReadPacer: Sendable {
    /// 桶容量，以"可连续工作多少秒"计。允许短促的突发，避免把每一首都切碎。
    public static let defaultBurst: TimeInterval = 2

    public private(set) var activeFraction: Double
    public let burst: TimeInterval
    private var tokens: TimeInterval
    private var lastRefillAt: TimeInterval?

    public init(activeFraction: Double = 1, burst: TimeInterval = Self.defaultBurst) {
        self.activeFraction = min(1, max(0.01, activeFraction))
        self.burst = max(0, burst)
        self.tokens = self.burst
        self.lastRefillAt = nil
    }

    /// 档位或热状态变了就换预算。额度不清零：已经歇过的时间不该白歇，
    /// 已经透支的也不该靠切档位抹掉。
    public mutating func setActiveFraction(_ fraction: Double, now: TimeInterval) {
        refill(now: now)
        activeFraction = min(1, max(0.01, fraction))
    }

    /// 记一次读取实际占用的计算时间（不含纯网络等待——等网络不产生热量，
    /// 把它算进占空比会让慢速网络凭空变成"设备很忙"）。
    public mutating func recordWork(_ duration: TimeInterval, now: TimeInterval) {
        guard duration.isFinite, duration > 0 else {
            refill(now: now)
            return
        }
        refill(now: now)
        tokens -= duration
    }

    /// 下一次读取之前应该歇多久。0 表示可以立刻开始。
    public mutating func rest(now: TimeInterval) -> TimeInterval {
        refill(now: now)
        guard tokens < 0 else { return 0 }
        return -tokens / activeFraction
    }

    private mutating func refill(now: TimeInterval) {
        defer { lastRefillAt = now }
        guard let lastRefillAt, now.isFinite, now > lastRefillAt else { return }
        tokens = min(burst, tokens + (now - lastRefillAt) * activeFraction)
    }
}
