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
    /// 报告的总数已被证明偏小（末尾之后还有条目）：之后只认空页 / 短页，不再按总数停。
    public private(set) var ignoresReportedTotal = false

    public init() {}

    public var admittedCount: Int { seenIDs.count }

    public func hasAdmitted(_ id: String) -> Bool { seenIDs.contains(id) }

    /// 记下一页报的总数，和上一页不一样就算漂移。
    public mutating func observeTotal(_ pageTotal: Int?) {
        guard let pageTotal, !ignoresReportedTotal else { return }
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

    /// 按报告的总数停下、而最后一页是满页：总数可能偏小（服务端或中间的代理把它钉在
    /// 某个上限上），调用方应再要一页确认真的到头。正常的「整页结尾」只多花一个请求。
    public func shouldConfirmEnd(offset: Int, rawCount: Int, pageSize: Int) -> Bool {
        guard !ignoresReportedTotal, let reportedTotal, rawCount == pageSize else { return false }
        return offset >= reportedTotal
    }

    /// 确认页里有没见过的条目：总数不可信，之后像不报总数的服务器一样翻到空页 / 短页
    /// 为止。确认页全是见过的（服务端把越界的偏移夹回了末尾）就说明总数没错，不要调用。
    public mutating func continuePastReportedTotal() {
        ignoresReportedTotal = true
        reportedTotal = nil
    }
}
