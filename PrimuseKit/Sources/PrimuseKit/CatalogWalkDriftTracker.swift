import Foundation

/// 按偏移翻页走整库时，把「服务器正在增删」和真正的错误分开。
///
/// 服务器在翻页途中入库或删歌，报的总数会变，条目会前后挪一位：重复出现的
/// 跳过，总数以最新一页为准，走到头就停。这样拼出来的结果可能漏几行，所以
/// `driftObserved` 为真时它只能用来新增和更新，不能当作「没列出来的都删了」
/// 的证据。以前任何一处对不上都让整次扫描失败，一直在入库的大服务器因此
/// 永远扫不完。
public struct CatalogWalkDriftTracker: Sendable {
    public private(set) var driftObserved = false
    /// 最新一页报的总数；服务器不报时为 nil。
    public private(set) var reportedTotal: Int?
    private var seenIDs: Set<String> = []

    public init() {}

    public var admittedCount: Int { seenIDs.count }

    /// 记下一页报的总数，和上一页不一样就算漂移。
    public mutating func observeTotal(_ pageTotal: Int?) {
        guard let pageTotal else { return }
        if let reportedTotal, reportedTotal != pageTotal {
            driftObserved = true
        }
        reportedTotal = pageTotal
    }

    /// 第一次见到的条目返回 true；前面的页已经给过的返回 false 并记为漂移。
    public mutating func admit(_ id: String) -> Bool {
        if seenIDs.insert(id).inserted { return true }
        driftObserved = true
        return false
    }

    /// 本页读完后是否该停。`offset` 是连同本页在内已经翻过的原始条数。
    /// 在报告的末尾之前出现空页或短页、或者翻过了末尾，都说明目录在动。
    public mutating func isFinished(offset: Int, rawCount: Int, pageSize: Int) -> Bool {
        if rawCount == 0 {
            if let reportedTotal, offset < reportedTotal { driftObserved = true }
            return true
        }
        if let reportedTotal, offset >= reportedTotal {
            if offset > reportedTotal { driftObserved = true }
            return true
        }
        if rawCount < pageSize {
            if reportedTotal != nil { driftObserved = true }
            return true
        }
        return false
    }

    /// 同一页原样又出现一次时调用：偏移没在前进，只能停下，结果按漂移处理。
    public mutating func markStalled() {
        driftObserved = true
    }
}
