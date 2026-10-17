import Foundation

/// 用户点「缓存」整源下载时，单首歌失败后的重试节奏。
///
/// 自动离线那条管线（常驻队列 + 日志）本来就有分类退避和来源冷却，手动批量
/// 一直是一次定生死：网络抖一下、WebDAV 反代偶发一个 5xx、连接被中途掐断，
/// 这首歌当场记成失败，用户只能整批重来。十几首里失败七八首就是这么来的。
///
/// 退避同时也是给服务端的喘息：家用 NAS 和反代在并发下最容易在同一时刻连续
/// 报错，立刻重试只会把同一批错误再撞一遍。
public enum OfflineBatchRetryPolicy {

    /// 一首歌最多尝试几次（含第一次）。
    ///
    /// 3 次：真正的瞬时故障基本在第二次就过去了，第三次留给退避窗口正好覆盖
    /// 一次短暂的服务端重启。再多就变成对着一台已经不行的服务器空转。
    public static let maximumAttempts = 3

    /// 第 `attempt` 次尝试失败之后，要不要再来一次。
    ///
    /// `isRetryable` 由调用方按失败分类给出：凭据错误和权限拒绝重试没有意义，
    /// 只会拿同一份错凭据反复敲服务端。
    public static func shouldRetry(afterAttempt attempt: Int, isRetryable: Bool) -> Bool {
        guard isRetryable else { return false }
        guard attempt >= 1 else { return false }
        return attempt < maximumAttempts
    }

    /// 第 `attempt` 次尝试失败之后等多久再重试。
    ///
    /// 指数退避 2s → 4s，上限 16s。服务端明说限流时至少等 30 秒 —— 这种情况下
    /// 几秒钟后重试必然再吃一个 429。
    public static func retryDelay(afterAttempt attempt: Int, isRateLimited: Bool) -> TimeInterval {
        let exponent = Double(max(attempt, 1) - 1)
        let backoff = min(pow(2, exponent) * 2, 16)
        return isRateLimited ? max(backoff, 30) : backoff
    }
}

/// 手动批量离线下载里一首歌最后失败在哪一类。决定这一批还要不要接着往下试，
/// 也决定收尾时跟用户说什么原因。
public enum OfflineBatchFailureCategory: String, Sendable, CaseIterable {
    /// 连不上、超时、连接中途断开，或者手机此刻没有网络。
    case connectivity
    /// 账号或密码失效，要先去音乐源里重新登录。
    case authentication
    /// 服务器明确拒绝读取（没有权限）。
    case accessDenied
    /// 手机剩余空间放不下这首歌。
    case storage
    /// 只跟这一首有关：文件已经不在、服务器对这一首报错等。
    case other
}

/// 一批下载提前停下的原因。停下之后还没开始的歌不再逐首去试。
public enum OfflineBatchStopReason: String, Sendable, Equatable {
    case insufficientStorage
    case networkUnavailable
    case sourceUnreachable
    case sourceAuthentication
}

/// 手动批量下载的熔断。
///
/// 原来每首歌各自重试几轮就算完：NAS 一断（出门换了网、硬盘休眠、外网线路抖），
/// 剩下的几百首会一首接一首把重试走完再记成失败。家用 NAS 连不上时每次请求要等满
/// 超时，整批空转能拖上几个小时，最后弹出一串「失败」(#321)。这里按源数连续失败：
/// 连续几首都是连不上或账号失效，这个源剩下的就不再开始；空间不够是整台设备的事，
/// 一次就停下全部。服务器答了话但只是这一首不行（文件不在、单首报错、没权限），
/// 说明源本身是通的，不计入连续失败。
public struct OfflineBatchFailureBreaker: Sendable, Equatable {
    /// 同一个源连续几首失败在连接或登录上就停下这个源。
    ///
    /// 3 首：并发 2 首时一次网络中断会让在下的两首一起失败，第三首还连不上才说明
    /// 不是一次瞬断；一首卡死的歌本身已经走过分段与整首两层重试。
    public static let consecutiveSourceFailureLimit = 3

    private var consecutiveSourceFailures: [String: Int] = [:]
    public private(set) var stoppedSources: [String: OfflineBatchStopReason] = [:]
    public private(set) var deviceStopReason: OfflineBatchStopReason?

    public init() {}

    /// 这个源的下一首还要不要开始下。
    public func admits(sourceID: String) -> Bool {
        deviceStopReason == nil && stoppedSources[sourceID] == nil
    }

    public mutating func recordSuccess(sourceID: String) {
        consecutiveSourceFailures[sourceID] = 0
    }

    public mutating func recordFailure(
        sourceID: String,
        category: OfflineBatchFailureCategory
    ) {
        switch category {
        case .storage:
            stopAll(.insufficientStorage)
        case .connectivity, .authentication:
            let count = (consecutiveSourceFailures[sourceID] ?? 0) + 1
            consecutiveSourceFailures[sourceID] = count
            guard count >= Self.consecutiveSourceFailureLimit,
                  stoppedSources[sourceID] == nil else { return }
            stoppedSources[sourceID] = category == .authentication
                ? .sourceAuthentication
                : .sourceUnreachable
        case .accessDenied, .other:
            consecutiveSourceFailures[sourceID] = 0
        }
    }

    /// 整批停下（断网等太久、空间不够）。先记下的原因优先。
    public mutating func stopAll(_ reason: OfflineBatchStopReason) {
        if deviceStopReason == nil { deviceStopReason = reason }
    }

    /// 收尾时告诉用户的那一个原因：整批停下的优先；只有源被停下时，登录失效
    /// 比连不上更需要用户去处理，排在前面。
    public var primaryStopReason: OfflineBatchStopReason? {
        if let deviceStopReason { return deviceStopReason }
        let reasons = Set(stoppedSources.values)
        if reasons.contains(.sourceAuthentication) { return .sourceAuthentication }
        if reasons.contains(.sourceUnreachable) { return .sourceUnreachable }
        return nil
    }
}

/// 批量下载遇到手机整个断网时的等待。
///
/// 断网时去下只会让每首歌都把重试走完记成失败；网络回来以后又得用户整批重点。
/// 改成停在原地等网络回来再接着下（地铁里、电梯里几分钟的空白都过得去），等太久
/// 才把整批停下。
public enum OfflineBatchNetworkWaitPolicy {
    /// 一次断网最多等多久。超过了整批停下，用户连上网后再点「缓存」接着下。
    public static let maximumWait: TimeInterval = 600
    /// 多久看一次网络回来没有。
    public static let pollInterval: TimeInterval = 1
    /// 同一首歌因为断网等过之后重来的次数上限。网络时断时续时，超过之后这首歌
    /// 按普通失败走重试次数，不会无限地等—试—等。
    public static let maximumNetworkRetriesPerSong = 3

    /// 断网等待时这一首要不要「等网回来再重来」，而不是按普通失败计一次尝试。
    public static func waitsForNetwork(
        category: OfflineBatchFailureCategory?,
        deviceIsOffline: Bool,
        networkRetriesSoFar: Int
    ) -> Bool {
        category == .connectivity
            && deviceIsOffline
            && networkRetriesSoFar < maximumNetworkRetriesPerSong
    }
}

/// 批量下载在用户离开 App 之后继续跑的那段系统时间（iOS 的 continued processing）。
public enum OfflineBatchBackgroundRunPolicy {
    /// 只有一首的下载很快结束，也不值得每次都弹一张系统任务卡片。
    public static func requestsSystemTask(songCount: Int, isApplicationActive: Bool) -> Bool {
        songCount >= 2 && isApplicationActive
    }

    /// 系统收回时间（或用户在系统卡片上点了停止）时要不要停下这一批。App 还在前台
    /// 时下载本来就能继续，停下反而让用户眼看着进度断掉；不在前台时按用户停止处理：
    /// 下完的和下了一半的都留着，再点「缓存」接着下。
    public static func cancelsBatchOnExpiration(isApplicationActive: Bool) -> Bool {
        !isApplicationActive
    }

    /// 系统卡片的进度单位：首数。
    public static func progressUnits(handledCount: Int, totalCount: Int) -> (completed: Int64, total: Int64) {
        let total = Int64(max(1, totalCount))
        return (min(Int64(max(0, handledCount)), total), total)
    }
}
