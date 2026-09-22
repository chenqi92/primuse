import Foundation

/// 日志积压准入策略。写盘串行队列没有任何准入上限时, 某个组件一旦进入紧循环
/// 打点, 每次调用都会往队列里塞一个闭包(还捕获了整条消息), 队列消费速度远
/// 跟不上生产速度, 积压会以每秒数十 MB 的速度膨胀, 最终把进程推到 Jetsam。
///
/// 策略只做纯判定, 不持有任何状态: 由调用方在锁内维护待处理条数, 超限直接丢弃
/// 并累计丢弃数, 恢复后用 `droppedSummary` 在日志里记下丢了多少行、丢在哪里。
public enum LogBacklogPolicy {
    /// 队列里允许挂起的最大条数。2000 行足够覆盖正常的批量回填突发,
    /// 又把最坏情况下的内存占用限制在几 MB 量级。
    public static let maximumPendingEntries = 2_000

    /// 队列未满时放行。等于上限即拒绝, 保证挂起条数不会超过 `limit`。
    public static func admits(pendingCount: Int, limit: Int = maximumPendingEntries) -> Bool {
        pendingCount < limit
    }

    /// 丢弃汇总, 单行, 与普通日志一样会被加上时间戳后写入。
    public static func droppedSummary(count: Int) -> String {
        "⚠️ 日志积压超限, 已丢弃 \(count) 行"
    }
}

/// 连续重复行折叠器。紧循环打点里绝大多数是同一处、同一条消息的重复, 折叠后
/// 既能把写盘量压下去, 又不会丢掉"这里在刷屏"这个诊断信息。
///
/// 只在同一条串行队列上驱动, 所以顺序天然保持: `absorb` 返回什么就按顺序写什么。
public struct LogDuplicateCoalescer: Sendable {
    /// 连续重复累计到这个数时立刻吐一条汇总并清零, 保证无限重复的行
    /// 每 `flushEvery` 次至少留下一行痕迹, 不会一直沉默。
    private let flushEvery: Int
    private var previousKey: String?
    private var repeatCount = 0

    public init(flushEvery: Int = 100) {
        self.flushEvery = max(1, flushEvery)
    }

    /// 吸收一行。`key` 用于判重(通常是 文件:行 + 原始消息), `line` 是实际要写的内容。
    /// 返回需要按顺序写出的行: 新行返回自身(必要时前面带上一段重复汇总),
    /// 重复行返回空数组, 只有攒够 `flushEvery` 次才返回一条汇总。
    public mutating func absorb(key: String, line: String) -> [String] {
        if key == previousKey {
            repeatCount += 1
            guard repeatCount >= flushEvery else { return [] }
            let summary = Self.repeatSummary(count: repeatCount)
            repeatCount = 0
            return [summary]
        }

        var produced: [String] = []
        if repeatCount > 0 {
            produced.append(Self.repeatSummary(count: repeatCount))
            repeatCount = 0
        }
        previousKey = key
        produced.append(line)
        return produced
    }

    /// 收尾: 把挂起的重复计数写出去。会同时清掉上一条 key, 让 flush 之后
    /// 再来的同一行当作新行完整打印(轮转、会话切换这类边界需要这个行为)。
    public mutating func flush() -> [String] {
        previousKey = nil
        guard repeatCount > 0 else { return [] }
        let summary = Self.repeatSummary(count: repeatCount)
        repeatCount = 0
        return [summary]
    }

    private static func repeatSummary(count: Int) -> String {
        "（上一行重复 \(count) 次）"
    }
}

/// 诊断日志模式: 开发时由脚本打开, 在有效期内放大日志容量, 并让 App 定时记录
/// 运行状态, 用来事后排查界面上看不出来的后台线程、卡顿、发热与写盘问题。
///
/// 开关走环境变量 `PRIMUSE_DIAGNOSTIC_LOGGING`(`scripts/primuse-dev.sh diag-on`):
/// "off" / "0" 关闭; 正整数 = 开启多少小时(最多 `maximumHours`); 其它非空值 =
/// 默认 `defaultHours` 小时。有效期会存下来, 期间 App 被系统或手动重新启动也继续
/// 记录, 到期后自动回到常规模式。
public enum DiagnosticLoggingPolicy {
    public static let environmentKey = "PRIMUSE_DIAGNOSTIC_LOGGING"
    public static let defaultHours = 24
    public static let maximumHours = 72

    public enum Change: Equatable, Sendable {
        case unchanged
        case enabled(until: Date)
        case disabled
        case expired
    }

    public struct Resolution: Equatable, Sendable {
        /// 诊断模式生效到什么时候; nil 表示常规模式。
        public var expiresAt: Date?
        /// 这次启动相对上次的变化, 调用方据此改写存下来的有效期并记一行日志。
        public var change: Change

        public var isActive: Bool { expiresAt != nil }
    }

    public static func resolve(request: String?, storedExpiry: Date?, now: Date) -> Resolution {
        let value = (request ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value == "off" || value == "0" {
            return Resolution(expiresAt: nil, change: storedExpiry == nil ? .unchanged : .disabled)
        }
        if !value.isEmpty {
            let hours = Int(value).map { min(max($0, 1), maximumHours) } ?? defaultHours
            let until = now.addingTimeInterval(TimeInterval(hours) * 3600)
            return Resolution(expiresAt: until, change: .enabled(until: until))
        }
        guard let storedExpiry else { return Resolution(expiresAt: nil, change: .unchanged) }
        if storedExpiry > now {
            return Resolution(expiresAt: storedExpiry, change: .unchanged)
        }
        return Resolution(expiresAt: nil, change: .expired)
    }

    public struct Limits: Equatable, Sendable {
        /// 单个日志文件写到多大就轮转。
        public var maxFileBytes: Int
        /// 轮转保留的历史代数: `.1` 最新, `.N` 最老。
        public var rotatedGenerations: Int
        /// 写盘队列最多积压多少条, 超出的直接丢弃并记数。
        public var backlogLimit: Int
    }

    /// 常规模式与改动前完全一致: 10MB 一个文件、保留一代、积压 2000 条。
    public static let standardLimits = Limits(
        maxFileBytes: 10_000_000,
        rotatedGenerations: 1,
        backlogLimit: LogBacklogPolicy.maximumPendingEntries
    )

    /// 诊断模式: 25MB × (当前 + 4 代) ≈ 125MB, 够记录一整天的操作过程;
    /// 积压上限放宽十倍, 突发时尽量不丢行。
    public static let diagnosticLimits = Limits(
        maxFileBytes: 25_000_000,
        rotatedGenerations: 4,
        backlogLimit: 20_000
    )

    public static func limits(isActive: Bool) -> Limits {
        isActive ? diagnosticLimits : standardLimits
    }

    /// 轮转要做的改名, 按顺序执行。0 表示当前文件, k 表示 `.k`。
    /// 调用方先删掉第 `generations` 代, 再从最老的一代往前挪, 例如 3 代:
    /// `.2 → .3`、`.1 → .2`、当前 → `.1`。
    public struct RotationMove: Equatable, Sendable {
        public var from: Int
        public var to: Int
    }

    public static func rotationMoves(generations: Int) -> [RotationMove] {
        let count = max(1, generations)
        return stride(from: count - 1, through: 0, by: -1).map { RotationMove(from: $0, to: $0 + 1) }
    }
}
