import Foundation

/// 源卡片计数落盘的合并策略。
///
/// 扫描中间 flush 每 1.5 s 一次, 每次都把 `songCount` 写回 `sources.json` ——
/// 一次完整编码加一次原子文件写, 全在主 actor 上。中间计数是派生状态, 丢了
/// 下一次 flush 就会补上; 终态提交、扫描取消与场景离开前台这三处则必须立刻
/// 落盘, 那里的值是用户会看见、也要跨进程存活的。
public enum SourcePersistCoalescingPolicy {
    /// 两次真正落盘之间的最短间隔。
    public static let debounceInterval: TimeInterval = 0.75

    /// 这次更新要不要立刻落盘。
    /// - Parameters:
    ///   - isFinalCommit: 终态提交 (completeScan / cancelScan)。
    ///   - isBackgrounded: 场景已经离开前台, 后面随时可能被挂起。
    ///   - secondsSinceLastPersist: 距上次真正落盘的秒数。
    public static func shouldPersistNow(
        isFinalCommit: Bool,
        isBackgrounded: Bool,
        secondsSinceLastPersist: TimeInterval,
        debounceInterval: TimeInterval = debounceInterval
    ) -> Bool {
        if isFinalCommit || isBackgrounded { return true }
        return secondsSinceLastPersist >= debounceInterval
    }
}
