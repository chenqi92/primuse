import Foundation

/// 标签读取速率的采样窗口。
///
/// 读取变慢时，光看「慢」没法判断卡在哪一环：读取位被压到几个、是不是在播放、
/// 机器是不是热了，都会各自把速率拉下来。把这几项和实测速率打在同一行日志里，
/// 下次再遇到就能直接对号入座，不必凭现象猜。
public struct MetadataReadThroughputSample: Equatable, Sendable {
    /// 本窗口实测速率，单位是「首 / 分钟」。
    public let itemsPerMinute: Double
    public let processedInWindow: Int
    public let windowSeconds: TimeInterval

    public init(itemsPerMinute: Double, processedInWindow: Int, windowSeconds: TimeInterval) {
        self.itemsPerMinute = itemsPerMinute
        self.processedInWindow = processedInWindow
        self.windowSeconds = windowSeconds
    }
}

public struct MetadataReadThroughputSampler: Sendable {
    /// 采样窗口。太短会被单首的抖动带偏，太长又要等很久才看得到一行。
    public static let defaultWindow: TimeInterval = 30

    private let window: TimeInterval
    private var windowStartedAt: Date?
    private var completedAtWindowStart: Int = 0

    public init(window: TimeInterval = defaultWindow) {
        self.window = max(1, window)
    }

    /// 汇报累计完成数。够一个窗口才返回一条采样，其余时候返回 `nil`。
    public mutating func record(
        totalCompleted: Int,
        at date: Date = Date()
    ) -> MetadataReadThroughputSample? {
        guard let startedAt = windowStartedAt else {
            windowStartedAt = date
            completedAtWindowStart = totalCompleted
            return nil
        }
        let elapsed = date.timeIntervalSince(startedAt)
        guard elapsed >= window else { return nil }

        // 计数回退意味着换了一轮读取，这一窗作废重开，免得算出负速率。
        guard totalCompleted >= completedAtWindowStart else {
            windowStartedAt = date
            completedAtWindowStart = totalCompleted
            return nil
        }

        let processed = totalCompleted - completedAtWindowStart
        windowStartedAt = date
        completedAtWindowStart = totalCompleted
        return MetadataReadThroughputSample(
            itemsPerMinute: Double(processed) / elapsed * 60,
            processedInWindow: processed,
            windowSeconds: elapsed
        )
    }

    /// 读取轮次结束或暂停时调用，下一轮从新窗口开始计。
    public mutating func reset() {
        windowStartedAt = nil
        completedAtWindowStart = 0
    }
}
