import Foundation

public enum CloudHTTPRetryPolicy {
    public static func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || statusCode == 429 || statusCode >= 500
    }

    public static func shouldRetry(urlErrorCode: Int) -> Bool {
        switch URLError.Code(rawValue: urlErrorCode) {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
             .networkConnectionLost, .dnsLookupFailed,
             .notConnectedToInternet, .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}
