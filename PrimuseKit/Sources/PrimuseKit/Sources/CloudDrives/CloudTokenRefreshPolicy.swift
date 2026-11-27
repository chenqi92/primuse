import Foundation

/// Distinguishes retryable OAuth token-endpoint failures from credentials that
/// are definitively unusable. Callers must not delete or merge account data
/// merely because a provider is temporarily unavailable.
public enum CloudTokenRefreshFailureDisposition: Sendable {
    case transient
    case permanent
}

public enum CloudTokenRefreshPolicy {
    public static func disposition(
        statusCode: Int?,
        providerErrorCode: String? = nil
    ) -> CloudTokenRefreshFailureDisposition {
        let normalizedError = providerErrorCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let transientErrors: Set<String> = [
            "temporarily_unavailable", "server_error", "slow_down",
            "rate_limited", "rate_limit_exceeded", "too_many_requests",
        ]
        if let normalizedError, transientErrors.contains(normalizedError) {
            return .transient
        }

        if let statusCode,
           statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode) {
            return .transient
        }

        return .permanent
    }
}
