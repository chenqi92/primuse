import Foundation

/// 一个电台的台标自动发现状态。存在设备本地，不进 CloudKit ——
/// 失败计数是「这台设备这条网络」的事实，换台设备值得重新试一次。
public struct RadioLogoDiscoveryState: Codable, Equatable, Sendable {
    public var lastAttemptAt: Date?
    public var failureCount: Int
    /// 上一次成功命中的来源，用来判断新候选值不值得覆盖。
    public var resolvedSource: RadioLogoSource?

    public init(
        lastAttemptAt: Date? = nil,
        failureCount: Int = 0,
        resolvedSource: RadioLogoSource? = nil
    ) {
        self.lastAttemptAt = lastAttemptAt
        self.failureCount = failureCount
        self.resolvedSource = resolvedSource
    }

    public static let initial = RadioLogoDiscoveryState()
}

/// 发现流程要走哪几步。每一步都可能失败，失败就往下走，全败就记退避。
public enum RadioLogoDiscoveryStep: Equatable, Sendable {
    /// 连一次流，读响应头(`icy-logo` / `icy-url`)和一块带内元数据。
    case streamProbe
    /// 抓电台主页，取 og:image / apple-touch-icon / favicon。
    case homepage(String)
    /// 拿流地址回查在线目录，取 favicon。
    case directoryLookup(String)
}

/// 什么时候该发现、失败后隔多久再试、拿到的候选值不值得写回。
///
/// 全是纯函数：发现服务只负责发请求，「要不要发」这个判断在这里，
/// 这样退避行为可以被单测钉住，不用真的等上几个小时。
public enum RadioLogoDiscoveryPolicy {
    /// 连续失败到这个次数后就进入最长退避，不再频繁骚扰台方服务器。
    public static let maximumFailureCount = 5

    /// 指数退避。第一次失败只等 5 分钟(用户可能刚换了网络)，
    /// 之后迅速拉长到几天 —— 一个没有台标的电台，多等几天没有任何损失。
    public static func retryDelay(failureCount: Int) -> TimeInterval {
        switch max(failureCount, 0) {
        case 0: return 0
        case 1: return 5 * 60
        case 2: return 30 * 60
        case 3: return 2 * 60 * 60
        case 4: return 12 * 60 * 60
        default: return 3 * 24 * 60 * 60
        }
    }

    /// 这个电台现在需不需要发现台标。
    ///
    /// - `hasUserProvidedLogo`: 用户自己选过图 —— 永远不碰。
    /// - `hasResolvedLogo`: 已经发现过一张可用的图。除非是用户主动要求刷新，
    ///   否则不再重复发现：台标很少变，而每次发现都意味着连一次台方服务器。
    public static func shouldAttempt(
        state: RadioLogoDiscoveryState,
        hasUserProvidedLogo: Bool,
        hasResolvedLogo: Bool,
        now: Date = Date(),
        isManualRequest: Bool = false
    ) -> Bool {
        guard !hasUserProvidedLogo else { return false }
        if isManualRequest { return true }
        guard !hasResolvedLogo else { return false }
        guard let lastAttemptAt = state.lastAttemptAt else { return true }
        let delay = retryDelay(failureCount: state.failureCount)
        return now.timeIntervalSince(lastAttemptAt) >= delay
    }

    /// 走哪几步，按顺序。已知主页时先抓主页也行，但流探测顺带就能拿到
    /// `icy-logo`，而且它是唯一「一次连接同时验证流可用」的步骤，所以放最前。
    public static func steps(
        streamURL: String?,
        knownHomepageURL: String?,
        allowsDirectoryLookup: Bool
    ) -> [RadioLogoDiscoveryStep] {
        var steps: [RadioLogoDiscoveryStep] = []
        if streamURL?.isEmpty == false {
            steps.append(.streamProbe)
        }
        if let homepage = RadioLogoURLPolicy.normalized(knownHomepageURL) {
            steps.append(.homepage(homepage))
        }
        if allowsDirectoryLookup, let streamURL, !streamURL.isEmpty {
            steps.append(.directoryLookup(streamURL))
        }
        return steps
    }

    /// 成功后的新状态。
    public static func succeeded(
        _ state: RadioLogoDiscoveryState,
        source: RadioLogoSource,
        at date: Date = Date()
    ) -> RadioLogoDiscoveryState {
        RadioLogoDiscoveryState(
            lastAttemptAt: date,
            failureCount: 0,
            resolvedSource: source
        )
    }

    /// 失败后的新状态。计数封顶，免得整数无意义地长大。
    public static func failed(
        _ state: RadioLogoDiscoveryState,
        at date: Date = Date()
    ) -> RadioLogoDiscoveryState {
        RadioLogoDiscoveryState(
            lastAttemptAt: date,
            failureCount: min(state.failureCount + 1, maximumFailureCount),
            resolvedSource: state.resolvedSource
        )
    }

    /// 新候选要不要写回电台。同来源允许更新地址(台方换了图)，
    /// 可信度更低的来源不许顶掉已有的图。
    public static func shouldApply(
        candidateSource: RadioLogoSource,
        candidateURL: String?,
        currentSource: RadioLogoSource?,
        currentURL: String?
    ) -> Bool {
        guard let candidateURL = RadioLogoURLPolicy.normalized(candidateURL) else { return false }
        guard RadioLogoURLPolicy.shouldReplace(current: currentSource, with: candidateSource) else {
            return false
        }
        guard let currentURL = RadioLogoURLPolicy.normalized(currentURL) else { return true }
        // 地址没变就不必写回 —— 写回会触发持久化和界面刷新。
        return candidateURL != currentURL || candidateSource != currentSource
    }
}
