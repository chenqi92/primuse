import Foundation

public struct AppleMusicLibraryAccess: Equatable, Sendable {
    public var storefrontCountryCode: String?
    public var canPlayCatalogContent: Bool
    public var canBecomeSubscriber: Bool

    public init(storefrontCountryCode: String?, canPlayCatalogContent: Bool, canBecomeSubscriber: Bool) {
        self.storefrontCountryCode = storefrontCountryCode?.uppercased()
        self.canPlayCatalogContent = canPlayCatalogContent
        self.canBecomeSubscriber = canBecomeSubscriber
    }

    public var syncMode: AppleMusicLibrarySyncMode {
        canPlayCatalogContent ? .authoritative : .partialFallback
    }

    public func syncMode(hasCompleteDeviceLibrary: Bool) -> AppleMusicLibrarySyncMode {
        // Catalog playback entitlement does not limit a successful, unfiltered
        // read of the iPhone's system library, including an empty library.
        hasCompleteDeviceLibrary ? .authoritative : syncMode
    }

    public func canCommit(comparedTo latest: Self) -> Bool {
        self == latest
    }

    public func storefrontChanged(since previousCountryCode: String?) -> Bool {
        guard let previousCountryCode, let storefrontCountryCode else { return false }
        return previousCountryCode.uppercased() != storefrontCountryCode
    }
}

public enum AppleMusicPlaybackFailure: Equatable, Sendable {
    case authenticationRequired
    case systemPlayerFailedAfterAccessCheck
    case systemPlayerFailed
    case other

    public var stopsSource: Bool { self == .authenticationRequired }
}

public enum AppleMusicPlaybackFailurePolicy {
    public static func classify(
        _ error: any Error,
        catalogPlaybackWasVerified: Bool,
        authenticationRequired: Bool = false
    ) -> AppleMusicPlaybackFailure {
        let errors = errorChain(error as NSError)
        if authenticationRequired || errors.contains(where: isAuthenticationFailure) {
            return .authenticationRequired
        }
        if errors.contains(where: { $0.domain == AppleMusicQueueRecoveryPolicy.musicPlayerErrorDomain }) {
            // MP error 6 only reports a failed preparation. It does not identify
            // an expired subscription, revoked authorization, or account failure.
            return catalogPlaybackWasVerified ? .systemPlayerFailedAfterAccessCheck : .systemPlayerFailed
        }
        return .other
    }

    private static func isAuthenticationFailure(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorUserAuthenticationRequired {
            return true
        }
        // These may be supplied as underlying errors by Apple's playback service.
        // An opaque MP error must never be promoted to either of these diagnoses.
        return (error.domain == "AMSErrorDomain" && error.code == 100)
            || (error.domain == "ICError" && error.code == -7403)
    }

    private static func errorChain(_ root: NSError) -> [NSError] {
        var pending: [(NSError, Int)] = [(root, 0)]
        var visited: Set<ObjectIdentifier> = []
        var result: [NSError] = []
        while let (error, depth) = pending.popLast(), result.count < 32 {
            guard depth < 8, visited.insert(ObjectIdentifier(error)).inserted else { continue }
            result.append(error)
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
                pending.append((underlying as NSError, depth + 1))
            }
            if let underlying = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error] {
                pending.append(contentsOf: underlying.prefix(32).map { ($0 as NSError, depth + 1) })
            }
        }
        return result
    }
}

/// 系统音乐库里一首歌为什么要订阅才能放。订阅一开这些歌就都能放，所以同步时不从曲库里
/// 拿掉（拿掉的话订阅一变就整批删歌、加歌），只在放不了的时候标出来、播放时跳过。
public enum AppleMusicPlaybackRestriction: String, Sendable, Equatable {
    /// 只在云端、没下载到这台设备，也不带版权保护（多是买过的歌）：在“音乐”App 里下载到
    /// 本机后就是普通文件，不用订阅也能放。
    case cloudOnly
    /// 带 Apple Music 版权保护，或者认不出是这台设备上的文件：只有订阅能放。
    case subscriptionRequired
}

public enum AppleMusicPlaybackRestrictionPolicy {
    /// 同步之后怎么处理上一次的定性结果。
    public enum Update: Equatable, Sendable {
        /// 整份资料库都读到了、账号又放不了目录内容：逐首重新定性。
        case recompute
        /// 账号能放目录内容：一首都不拦，不必为整库逐首解析。
        case clear
        /// 只读到一部分（本机副本）：没读到的行没法定性，沿用上一次的结果。
        case keep
    }

    public static func update(
        syncMode: AppleMusicLibrarySyncMode,
        canPlayCatalogContent: Bool
    ) -> Update {
        guard syncMode == .authoritative else { return .keep }
        return canPlayCatalogContent ? .clear : .recompute
    }

    /// 媒体库里在云端、不带版权保护的条目，下载下来就是普通的本机文件。
    public static func isDownloadableCloudItem(isCloudItem: Bool, hasProtectedAsset: Bool) -> Bool {
        isCloudItem && !hasProtectedAsset
    }

    /// 给一行定性。和起播前的订阅检查（`AppleMusicSubscriptionGatePolicy`）是同一个判断：
    /// 不靠订阅就能放的本机文件返回 nil。
    public static func restriction(
        for source: AppleMusicPlaybackSource,
        isDownloadableCloudItem: Bool
    ) -> AppleMusicPlaybackRestriction? {
        guard AppleMusicSubscriptionGatePolicy.requiresCatalogCapability(for: source) else { return nil }
        return isDownloadableCloudItem ? .cloudOnly : .subscriptionRequired
    }

    /// 现在点它会不会被订阅检查拦下。能放目录内容时都能放；还没查过订阅（nil）时不拦，照常去试。
    public static func activeRestriction(
        _ restriction: AppleMusicPlaybackRestriction?,
        canPlayCatalogContent: Bool?
    ) -> AppleMusicPlaybackRestriction? {
        canPlayCatalogContent == false ? restriction : nil
    }

    /// 资料库「歌曲」里有几首要订阅才能放（只在歌单里的那些不算，同步数也不算它们）。
    public static func restrictedCount(
        _ restrictions: [String: AppleMusicPlaybackRestriction],
        among songIDs: Set<String>
    ) -> Int {
        guard !restrictions.isEmpty else { return 0 }
        return songIDs.reduce(0) { $0 + (restrictions[$1] == nil ? 0 : 1) }
    }
}

/// Whether an Apple Music response is a complete cloud snapshot or merely the
/// local-device fallback. Only a complete snapshot may prune songs/playlists.
public enum AppleMusicLibrarySyncMode: Sendable, Equatable {
    case authoritative
    case partialFallback

    public var shouldPruneMissingSongs: Bool { self == .authoritative }
    public var shouldReplaceMirrorPlaylist: Bool { self == .authoritative }
}
