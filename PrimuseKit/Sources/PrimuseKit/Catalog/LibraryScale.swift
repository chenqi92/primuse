import Foundation
import os

/// 曲库规模的硬上限。目录里的整范围结果只能是行号列表(`LibraryRowList`)或流式遍历;
/// 物化成 `Song` 的接口都受 `maxMaterializedRows` 约束。
public enum LibraryScale {
    /// 一次调用最多物化这么多首。超出时 DEBUG 断言, Release 每个调用点记一次日志,
    /// 结果截到这个数。
    public static let maxMaterializedRows = 5_000
    /// 行缓存(`LibraryRowCache`)默认容量。
    public static let rowCacheCapacity = 3_000
    /// 每批导入、每批派生维护处理的行数。
    public static let importBatchSize = 2_000
    /// 读连接数上限(§4.1)。
    public static let maximumReaderCount = 2
    /// 每个连接的页缓存上限(KiB, 写成负数给 `PRAGMA cache_size`)。
    public static let connectionCacheKiB = 4_096
    /// 映射读的上限:干净的映射页不计入 footprint。
    public static let mmapSize = 256 * 1_024 * 1_024
}

/// 运行时守卫:物化超过上限时 DEBUG 断言, Release 每个调用点只记一次日志。
public enum LibraryScaleGuard {
    private static let logger = Logger(subsystem: "com.primuse.library", category: "LibraryScale")
    private static let state = OSAllocatedUnfairLock(initialState: State())

    private struct State: Sendable {
        var reportedCallSites: Set<String> = []
        var handler: (@Sendable (String) -> Void)?
    }

    /// 测试用:替换 DEBUG 断言,改为收集消息。传 nil 恢复默认。
    static func setViolationHandlerForTesting(_ handler: (@Sendable (String) -> Void)?) {
        state.withLock { $0.handler = handler }
    }

    /// 检查一次物化请求。返回允许物化的行数(超限时截到上限)。
    @discardableResult
    public static func admitMaterialization(
        count: Int,
        limit: Int = LibraryScale.maxMaterializedRows,
        file: StaticString = #fileID,
        line: UInt = #line
    ) -> Int {
        let cap = min(max(0, limit), LibraryScale.maxMaterializedRows)
        guard count > cap else { return count }
        let callSite = "\(file):\(line)"
        let message = "materialization of \(count) rows exceeds \(cap) at \(callSite)"
        let (handler, firstReport) = state.withLock { state in
            (state.handler, state.reportedCallSites.insert(callSite).inserted)
        }
        if let handler {
            handler(message)
        } else {
            #if DEBUG
            assertionFailure(message)
            #endif
            if firstReport {
                logger.error("🧠 \(message, privacy: .public)")
            }
        }
        return cap
    }
}
