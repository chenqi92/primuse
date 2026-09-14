import Foundation

/// 挂载型网关(alist/OpenList 这类把网盘挂成 WebDAV 的代理, 或者反代后的
/// 家庭 NAS)在后端取不到文件时, 回给客户端的统一是 5xx —— 状态码里看不出
/// 后端到底是限流、掉线还是凭据过期。
///
/// 整库标签读取一次排几百首, 每首都是一次独立的 Range GET。后端一旦开始
/// 拒绝, 继续按正常并发往上撞只有两个结果: 网关被压得更死, 以及每首歌的
/// 自动重试配额在几分钟内全部烧光 —— 等后端恢复时, 整批歌已经躺在"需要
/// 处理"里, 只能靠用户手动重试。
///
/// 这里只描述"连续网关失败之后该怎么退让", 不持有任何会话状态, 所以
/// backfill 以外的读取路径也能复用同一套判断。
public enum RemoteGatewayBackoffPolicy {
    /// 服务端自己报的错才算网关失败。4xx 是这一个请求本身的问题(路径、权限、
    /// Range 语法), 退让不会让它变成可读; 5xx 才是"后端暂时拿不到数据"。
    /// 501/505 例外 —— 服务器明确表示不支持这种请求, 等多久都一样。
    public static func isGatewayFailure(statusCode: Int) -> Bool {
        guard (500...599).contains(statusCode) else { return false }
        return statusCode != 501 && statusCode != 505
    }

    /// 连续失败到这个次数以后, 同一个源同时只放一个读取在飞。
    public static let serializationThreshold = 2

    /// 退让的上限。再久就不是退让而是停摆了 —— 真正长期不可用的源由
    /// `sourceUnavailable` 那条路径接管。
    public static let maximumDelay: TimeInterval = 30

    /// 计数的饱和点。持续失败不需要无限累加, 到顶就停在最长退让上。
    public static let maximumConsecutiveFailures = 6

    /// 下一次读取之前要等多久。
    ///
    /// 第一次失败不等: 单发 5xx 常常只是某一个文件的后端抖动, 让它按原节奏
    /// 走完自己的重试。从第二次连续失败起才认定是整个源的问题。
    public static func delay(consecutiveFailures: Int) -> TimeInterval {
        switch max(0, consecutiveFailures) {
        case 0, 1: 0
        case 2: 2
        case 3: 5
        case 4: 10
        case 5: 20
        default: maximumDelay
        }
    }

    public static func serializesReads(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= serializationThreshold
    }

    public static func clampedFailureCount(_ count: Int) -> Int {
        min(maximumConsecutiveFailures, max(0, count))
    }
}

/// 每个音乐源的连续网关失败计数。
///
/// 计数按源而不是按歌: 一首歌读失败可能是文件的问题, 同一个源连着失败才是
/// 后端的问题, 而退让也只该落在那一个源上 —— 本地曲库和另一台 NAS 不该
/// 跟着一起慢下来。
public struct RemoteGatewayBackoffState: Sendable, Equatable {
    private var consecutiveFailures: [String: Int] = [:]

    public init() {}

    /// 记一次网关失败, 返回累计后的连续失败次数。
    @discardableResult
    public mutating func recordFailure(sourceID: String) -> Int {
        let next = RemoteGatewayBackoffPolicy.clampedFailureCount(
            (consecutiveFailures[sourceID] ?? 0) + 1
        )
        consecutiveFailures[sourceID] = next
        return next
    }

    /// 任何一次真正读到字节都证明后端又通了, 立刻把退让撤掉。
    public mutating func recordSuccess(sourceID: String) {
        consecutiveFailures.removeValue(forKey: sourceID)
    }

    public func failureCount(sourceID: String) -> Int {
        consecutiveFailures[sourceID] ?? 0
    }

    public func delay(sourceID: String) -> TimeInterval {
        RemoteGatewayBackoffPolicy.delay(consecutiveFailures: failureCount(sourceID: sourceID))
    }

    public func serializesReads(sourceID: String) -> Bool {
        RemoteGatewayBackoffPolicy.serializesReads(
            consecutiveFailures: failureCount(sourceID: sourceID)
        )
    }

    public var backedOffSourceIDs: Set<String> {
        Set(consecutiveFailures.keys)
    }

    /// 用户主动重试或来源配置变更时清掉 —— 这两种都代表"再按正常节奏试一次"。
    public mutating func reset(sourceID: String) {
        consecutiveFailures.removeValue(forKey: sourceID)
    }

    public mutating func removeAll() {
        consecutiveFailures.removeAll()
    }
}
