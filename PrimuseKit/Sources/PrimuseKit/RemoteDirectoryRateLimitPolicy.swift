import Foundation

/// 列目录被服务端限流(HTTP 429)时怎么等、等到什么时候该停。
///
/// Yandex Disk 这类 WebDAV 服务在一阵快速 PROPFIND 之后就对列目录回 429,
/// 同一时间里按 Range 取文件仍然正常。原来的处理和断线一样: 马上断开重连再试
/// 一次, 接着去列下一个目录。限流窗口里每个目录白白多打一个请求, 一轮扫描把
/// 剩下的几十上百个目录全部标成失败, 用户点「继续扫描」又立刻撞回去。
///
/// 这里只描述等待的节奏, 不持有状态: 每个目录按服务端给的 Retry-After(没有就
/// 按固定阶梯)等几次; 等完仍被限流, 扫描就该整轮停下, 把剩下的目录留给续扫。
public enum RemoteDirectoryRateLimitPolicy {
    /// 只认 429。503 也可能是限流, 但同样常见于某个超大目录让后端超时 ——
    /// 当成限流会让每一轮扫描都停在那一个目录上。
    public static func isRateLimited(statusCode: Int) -> Bool {
        statusCode == 429
    }

    /// 没有 Retry-After 时的等待阶梯, 也就是同一个目录最多等几次。
    public static let fallbackDelays: [TimeInterval] = [2, 5, 10]

    /// 单次等待的上限。服务端要求等得更久时这一轮不再硬等, 交给续扫 ——
    /// 自动续扫本身有 5 分钟起的退避。
    public static let maximumDelay: TimeInterval = 30

    public static var maximumWaits: Int { fallbackDelays.count }

    /// 已经等过 `completedWaits` 次之后, 下一次要等多久。nil 表示不该再等,
    /// 这一轮扫描应当停下。
    public static func delay(completedWaits: Int, retryAfter: TimeInterval?) -> TimeInterval? {
        guard completedWaits >= 0, completedWaits < maximumWaits else { return nil }
        guard let retryAfter, retryAfter.isFinite, retryAfter > 0 else {
            return fallbackDelays[completedWaits]
        }
        guard retryAfter <= maximumDelay else { return nil }
        return max(1, retryAfter)
    }
}
