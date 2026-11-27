import Foundation

/// Decides whether an SMB transport failure should discard the current
/// session and repeat the operation on a fresh connection.
public enum SMBConnectionRecoveryPolicy {
    public static let maximumReconnectAttempts = 1

    public static func shouldReconnect(
        errorDomain: String,
        errorCode: Int,
        completedReconnectAttempts: Int
    ) -> Bool {
        guard completedReconnectAttempts < maximumReconnectAttempts,
              errorDomain == NSPOSIXErrorDomain else {
            return false
        }

        return [
            POSIXErrorCode.ECONNRESET,
            .EPIPE,
            .EBADF,
            .ENOTCONN,
            .ETIMEDOUT,
            .ENETRESET,
            // AMSMB2 reports a successful SMB callback without its required
            // payload as ENODATA. This is a broken session/response, not an
            // empty directory; reconnecting is safe and avoids a false scan
            // failure for otherwise accessible shares.
            .ENODATA,
        ].contains { Int($0.rawValue) == errorCode }
    }
}
