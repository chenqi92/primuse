import Foundation

/// Decides whether a failed SMB request may have been abandoned before its
/// reply arrived.
///
/// libsmb2 keeps the directory handle that `smb2_opendir_async` allocated on
/// the context until the matching reply is serviced. When AMSMB2 stops waiting
/// on a request — its own operation timeout, a dropped transport, or Primuse's
/// `RemoteRequestDeadline` letting go of a request still in flight — the command
/// stays queued while still referencing that handle. Closing the session then
/// runs `smb2_free_all_dirs()` first and fires the queued callback through the
/// freed handle afterwards, which is an indirect jump through released memory.
///
/// A reply that did arrive carries the failure as a status, leaves nothing
/// queued, and can be torn down normally.
public enum SMBSessionDisposalPolicy {
    public static func mayHaveAbandonedRequest(
        errorDomain: String,
        errorCode: Int
    ) -> Bool {
        guard errorDomain == NSPOSIXErrorDomain else { return false }

        return [
            // The wait itself gave up or the socket stopped delivering.
            POSIXErrorCode.ETIMEDOUT,
            .ECONNRESET,
            .ECONNABORTED,
            .ECONNREFUSED,
            .EPIPE,
            .ENOTCONN,
            .ESHUTDOWN,
            .EBADF,
            .ENOTSOCK,
            .ENETRESET,
            .ENETDOWN,
            .ENETUNREACH,
            .EHOSTDOWN,
            .EHOSTUNREACH,
            .EIO,
        ].contains { Int($0.rawValue) == errorCode }
    }
}
