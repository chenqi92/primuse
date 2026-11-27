import Foundation

/// Directory PROPFIND has its own quota: some servers continue serving media
/// Range reads while directory enumeration is throttled.
public enum WebDAVDirectoryRequestPolicy {
    private static let service = RequestQuota.Service(id: "webdav.directory", policy: .init(
        maximumConcurrentRequests: 8, maximumAttempts: 1, timeout: 600,
        rateLimitStatusCodes: [429], defaultCooldown: 2
    ))

    /// Basic-auth usernames identify accounts independently of connector IDs,
    /// configured root folders and password rotation. The registry retains a digest.
    public static func quota(url: URL, username: String) -> RequestQuota? {
        RequestQuota(service: service, url: url, account: .init(stableID: username))
    }

    public static func failure(
        statusCode: Int, retryAfter: TimeInterval?, completedWaits: Int
    ) -> HTTPResponseFailure {
        let explicitDelay = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        // An ordinary 503 can be a single expensive directory timing out.
        let limited = statusCode == 429 || (statusCode == 503 && explicitDelay != nil)
        let ladder = RemoteDirectoryRateLimitPolicy.fallbackDelays
        let fallback = ladder[min(max(completedWaits, 0), ladder.count - 1)]
        let cooldown = explicitDelay.flatMap { $0 > 0 ? $0 : nil } ?? fallback
        return HTTPResponseFailure(statusCode: statusCode,
                                   retryAfter: limited ? cooldown : nil,
                                   isRateLimited: limited)
    }
}
