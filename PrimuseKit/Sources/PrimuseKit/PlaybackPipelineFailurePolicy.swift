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
    /// 请求下载之后这么久都没见到「正在下载」就算失败。
    public static let idleTimeout: TimeInterval = 30
    /// 整首歌最多等这么久;上百兆的无损文件在慢网络上也该够了,用户随时能切歌。
    public static let overallTimeout: TimeInterval = 600

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
            return now - lastActivityAt >= UbiquitousPlaybackDownloadPolicy.idleTimeout
                ? .failed(.neverStarted) : .waiting
        }
    }
}
