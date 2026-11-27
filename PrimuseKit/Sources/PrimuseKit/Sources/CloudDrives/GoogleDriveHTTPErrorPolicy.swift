import Foundation

public enum GoogleDriveHTTPDisposition: Equatable, Sendable {
    case retryRateLimit
    case permissionDenied
    case other
}

/// Google uses HTTP 403 for both permanent permission failures and documented
/// per-user/project quota throttling. Only the two Drive rate-limit reasons
/// are retryable; an ordinary 403 must still stop at the source boundary.
public enum GoogleDriveHTTPErrorPolicy {
    public static func disposition(
        statusCode: Int,
        reasons: Set<String>
    ) -> GoogleDriveHTTPDisposition {
        guard statusCode == 403 else { return .other }
        if !reasons.isDisjoint(with: ["rateLimitExceeded", "userRateLimitExceeded"]) {
            return .retryRateLimit
        }
        return .permissionDenied
    }
}
