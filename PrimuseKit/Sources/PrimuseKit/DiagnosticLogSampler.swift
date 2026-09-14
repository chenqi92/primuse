import Foundation

/// 整库读取会把同一行诊断刷成几百遍, 而用户能导出的日志只有 10 MB。
///
/// 每一类故障在一个时间窗口内留前若干条完整记录, 之后只按间隔记一行计数;
/// 窗口过去额度重新发放 —— 用户过一会儿再试一次时, 日志里仍然有完整现场,
/// 而不是只剩一串"已省略"。
public struct DiagnosticLogSampler: Sendable {
    public struct Decision: Sendable, Equatable {
        /// 这一条写完整细节。
        public let detailed: Bool
        /// 当前窗口内的第几次。
        public let count: Int
        /// 细节已经省略, 但这一条要写一行计数摘要。
        public let summarize: Bool
    }

    private struct Window {
        var count: Int
        var startedAt: Date
    }

    private var windows: [String: Window] = [:]
    private let detailLimit: Int
    private let summaryInterval: Int
    private let windowDuration: TimeInterval

    public init(
        detailLimit: Int = 20,
        summaryInterval: Int = 50,
        windowDuration: TimeInterval = 300
    ) {
        self.detailLimit = max(0, detailLimit)
        self.summaryInterval = max(1, summaryInterval)
        self.windowDuration = max(0, windowDuration)
    }

    public mutating func record(key: String, now: Date = Date()) -> Decision {
        var window = windows[key] ?? Window(count: 0, startedAt: now)
        // 窗口按"第一条"起算而不是滚动重置: 持续失败时额度不会被无限续上。
        if now.timeIntervalSince(window.startedAt) > windowDuration {
            window = Window(count: 0, startedAt: now)
        }
        window.count += 1
        windows[key] = window

        if window.count <= detailLimit {
            return Decision(detailed: true, count: window.count, summarize: false)
        }
        return Decision(
            detailed: false,
            count: window.count,
            summarize: window.count % summaryInterval == 0
        )
    }

    public func count(forKey key: String) -> Int {
        windows[key]?.count ?? 0
    }

    public mutating func reset() {
        windows.removeAll()
    }
}
