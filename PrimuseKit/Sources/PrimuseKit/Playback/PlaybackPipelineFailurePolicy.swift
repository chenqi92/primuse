import Foundation

/// Losing the system audio session says nothing about whether a song is playable.
public struct PlaybackAudioSessionFailure: Error, LocalizedError, Sendable {
    public let underlyingError: NSError

    public init(_ error: any Error) {
        underlyingError = error as NSError
    }

    public var errorDescription: String? { underlyingError.localizedDescription }
}

public enum PlaybackPipelineFailureAction: Equatable, Sendable {
    /// The result belongs to an older request and must not publish any state.
    case discardStaleResult
    /// Cancellation, audio ownership or a local asset requiring user action
    /// must preserve the selected item.
    case preserveCurrentItem
    /// A current, non-cancellation failure may use normal queue recovery.
    case advanceAfterFailure
}

public enum PlaybackPipelineFailurePolicy {
    public static func action(
        requestIsCurrent: Bool,
        error: any Error
    ) -> PlaybackPipelineFailureAction {
        action(
            requestIsCurrent: requestIsCurrent,
            errorIsCancellation: OperationCancellationPolicy.isCancellation(error),
            errorIsAudioSessionFailure: error is PlaybackAudioSessionFailure,
            errorRequiresUserAction: error is AppleMusicLocalAssetError
        )
    }

    public static func action(
        requestIsCurrent: Bool,
        errorIsCancellation: Bool,
        errorIsAudioSessionFailure: Bool = false,
        errorRequiresUserAction: Bool = false
    ) -> PlaybackPipelineFailureAction {
        guard requestIsCurrent else { return .discardStaleResult }
        return errorIsCancellation || errorIsAudioSessionFailure || errorRequiresUserAction
            ? .preserveCurrentItem : .advanceAfterFailure
    }
}

/// 从本机音频缓存起播、原生解码器和兜底解码器(FFmpeg / AVAssetReader)都解不出来时怎么办(#48)。
/// 缓存只是源上那个文件的一份副本, 两种解码器都打不开多半是这份副本坏了(写到一半、被截断、
/// 源上的文件换过) —— 丢掉它、从源头重新取一次, 而不是每次播到这首都直接跳过。
/// 同一首每次启动只重取一次, 再失败就照原来的失败处理走, 不会在坏文件和重下之间来回打转。
public enum UndecodableCachedAudioPolicy {
    public enum Decision: Equatable, Sendable {
        /// 删掉这份缓存, 从源头重新起播这一首。
        case discardAndRefetch
        /// 照原来的失败处理走(跳下一首或停住)。
        case keepFailureHandling(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        /// 播的不是音频缓存里的副本: 本机文件、播客下载、Apple Music 本地文件、远程流。
        case notPlayedFromAudioCache
        /// 没有能重新取的源头(光盘镜像切出来的分轨、DLNA / 播客这类外部地址)。
        case notRefetchable
        /// 文件读不到(权限、数据保护)不等于内容坏了, 不能因此删掉用户的离线副本。
        case cacheFileUnreadable
        /// 这次启动已经为这首重取过一次。
        case alreadyRefetched
    }

    public static func decision(
        playedFromAudioCache: Bool,
        sourceIsRefetchable: Bool,
        cacheFileIsReadable: Bool,
        alreadyRefetched: Bool
    ) -> Decision {
        guard playedFromAudioCache else { return .keepFailureHandling(.notPlayedFromAudioCache) }
        guard sourceIsRefetchable else { return .keepFailureHandling(.notRefetchable) }
        guard cacheFileIsReadable else { return .keepFailureHandling(.cacheFileUnreadable) }
        guard !alreadyRefetched else { return .keepFailureHandling(.alreadyRefetched) }
        return .discardAndRefetch
    }
}

/// 这次启动里哪些歌已经因为缓存解不出来重取过 —— 每首只给一次机会。
public struct UndecodableCachedAudioRefetchLedger: Sendable {
    private var refetchedSongIDs: Set<String> = []

    public init() {}

    public func hasRefetched(songID: String) -> Bool {
        refetchedSongIDs.contains(songID)
    }

    /// 记下这一首要重取; 已经记过时返回 false, 调用方不能再重取。
    @discardableResult
    public mutating func claim(songID: String) -> Bool {
        refetchedSongIDs.insert(songID).inserted
    }
}

/// App 在后台时系统不许激活不可混音的会话(`AVAudioSession.ErrorCode.cannotInterruptOthers`,
/// '!int')。锁屏下 Apple Music 播完接本地歌就撞这条: MusicKit 起播时打断了 Primuse 自己的会话,
/// 后台再要独占系统不给。可混音的会话后台能激活, 先这样把歌接上, 再找机会切回独占 ——
/// 混音的会话当不了「正在播放」App, 锁屏和耳机按键控制不到它。
public enum PlaybackSessionBackgroundActivationPolicy {
    public static let cannotInterruptOthersCode = 560_557_684

    /// 这次激活失败后要不要改用可混音再激活一次。
    public static func shouldRetryAsMixable(
        failureCode: Int,
        fallbackIsActive: Bool,
        capturesMicrophone: Bool,
        alreadyMixable: Bool
    ) -> Bool {
        guard !capturesMicrophone, !alreadyMixable else { return false }
        // 已经靠可混音在放时, 切回独占没成不能把正在放的会话丢掉。
        return fallbackIsActive || failureCode == cannotInterruptOthersCode
    }

    /// 别的 App 正在出声时切回独占会把它打断, 留到下一首起播再试。
    public static func shouldAttemptExclusiveRestore(
        fallbackIsActive: Bool,
        otherAudioIsPlaying: Bool
    ) -> Bool {
        fallbackIsActive && !otherAudioIsPlaying
    }
}

public enum SourceConfigurationInvalidationAction: Equatable, Sendable {
    case ignoreNonSecurityChange
    /// The account and the content root are unchanged; only the addresses that
    /// reach them differ. Connectors must be rebuilt on the new route list, but
    /// the active transport and the trusted offline bytes stay valid.
    case rebuildRoutesOnly
    case invalidateSecurityScope
}

/// Source rows also carry display and scan-derived fields. Those changes must
/// not cancel an active transport unless the account/endpoint security scope
/// actually changed.
public enum SourceConfigurationInvalidationPolicy {
    public static func action(
        previousScopeFingerprint: String?,
        currentScopeFingerprint: String?,
        previousCredentialScopeFingerprint: String? = nil,
        currentCredentialScopeFingerprint: String? = nil
    ) -> SourceConfigurationInvalidationAction {
        if previousScopeFingerprint == currentScopeFingerprint,
           previousScopeFingerprint != nil {
            return .ignoreNonSecurityChange
        }
        // Both credential fingerprints must be known before a mismatch can be
        // attributed to routing alone. A missing one (older state, unreadable
        // revision file) keeps the fail-closed answer.
        if let previousCredentialScopeFingerprint,
           let currentCredentialScopeFingerprint,
           previousCredentialScopeFingerprint == currentCredentialScopeFingerprint {
            return .rebuildRoutesOnly
        }
        return .invalidateSecurityScope
    }
}

/// 本机文件夹引用的歌放在 iCloud 云盘里、但还没下到这台设备时,起播前先把它拉下来,
/// 而不是让解码器卡在一次看不见进度的读文件上(#170)。
public enum UbiquitousPlaybackDownloadPolicy {
    /// 文件在 iCloud 里的下载状态,对应 `URLUbiquitousItemDownloadingStatus`。
    public enum Status: Equatable, Sendable {
        /// 不是 iCloud 文件,或读不到状态 —— 照常播放。
        case notUbiquitous
        case current
        /// 本机有一份,可能不是最新的,照样能播。
        case downloaded
        case notDownloaded
    }

    public static func needsDownload(_ status: Status) -> Bool {
        status == .notDownloaded
    }

    public enum Failure: Equatable, Sendable {
        /// 没有网络,下不了。
        case offline
        /// iCloud 报了下载错误。
        case downloadError
        /// 请求之后一直没开始下载(iCloud 云盘关了、账号状态不对)。
        case neverStarted
        /// 下了太久还没完。
        case timedOut
    }

    public enum Verdict: Equatable, Sendable {
        case waiting
        case ready
        case failed(Failure)
    }

    public static let pollInterval: Duration = .milliseconds(500)
    /// 请求下载之后这么久都没见到「已受理/正在下载」就算失败。
    public static let idleTimeout: TimeInterval = 30
    /// 系统已受理排队(`ubiquitousItemDownloadRequested`)、正在等 iCloud 调度建连时的宽限期。
    public static let queuedTimeout: TimeInterval = 90
    /// 整首歌最多等这么久;上百兆的无损文件在慢网络上也该够了,用户随时能切歌。
    public static let overallTimeout: TimeInterval = 600
    /// 队列预热同时向 iCloud 发起预下载的曲目上限,避免把 fileproviderd 队列打满。
    public static let maxUpcomingPrefetchCount = 4

    public static func upcomingPrefetchCount(
        configured: Int,
        isMeteredNetwork: Bool
    ) -> Int {
        let planned = UpcomingPlaybackPrefetchPolicy.plannedSongCount(
            configured: configured,
            isMeteredNetwork: isMeteredNetwork
        )
        return min(planned, maxUpcomingPrefetchCount)
    }

    public static func normalizedProgressFraction(percent: Double?) -> Double? {
        guard let percent, percent.isFinite, percent >= 0 else { return nil }
        return min(max(percent / 100.0, 0), 1)
    }

    /// 「正在从 iCloud 下载」后面接百分比;百分号的写法(「%42」「42 %」)、数字按 `locale`。
    public static func formattedDownloadStatus(baseText: String, progress: Double?, locale: Locale = .current) -> String {
        guard let progress, progress.isFinite, progress > 0, progress < 1 else {
            return baseText
        }
        let pct = Int((progress * 100).rounded(.down))
        guard pct > 0, pct < 100 else { return baseText }
        let percent = (Double(pct) / 100).formatted(.percent.precision(.fractionLength(0)).locale(locale))
        return "\(baseText) \(percent)"
    }

    /// 轮询下载状态的判定。每读一次状态喂一次。
    public struct Monitor: Sendable {
        public let startedAt: TimeInterval
        public private(set) var lastActivityAt: TimeInterval

        public init(startedAt: TimeInterval) {
            self.startedAt = startedAt
            lastActivityAt = startedAt
        }

        public mutating func observe(
            status: Status,
            isDownloading: Bool,
            isDownloadRequested: Bool = false,
            hasDownloadError: Bool,
            isOffline: Bool,
            at now: TimeInterval
        ) -> Verdict {
            if !UbiquitousPlaybackDownloadPolicy.needsDownload(status) { return .ready }
            if hasDownloadError { return .failed(.downloadError) }
            if isOffline { return .failed(.offline) }
            if now - startedAt >= UbiquitousPlaybackDownloadPolicy.overallTimeout {
                return .failed(.timedOut)
            }
            if isDownloading {
                lastActivityAt = now
                return .waiting
            }
            let stallLimit = isDownloadRequested
                ? UbiquitousPlaybackDownloadPolicy.queuedTimeout
                : UbiquitousPlaybackDownloadPolicy.idleTimeout
            return now - lastActivityAt >= stallLimit
                ? .failed(.neverStarted) : .waiting
        }
    }
}
