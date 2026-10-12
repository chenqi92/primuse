import Foundation
import Testing
@testable import PrimuseKit

/// NFSKit leaves a request queued in libnfs when its wait gives up, and
/// libnfs later calls back through the waiting frame that is already gone:
/// on the next call, on unmount (`rpc_disconnect`), or when the context is
/// destroyed. These cases pin which failures park the client for good.
@Suite("NFS context disposal")
struct NFSContextDisposalPolicyTests {
    @Test("A wait that gave up or a failed poll keeps the client alive")
    func retainsClientForAbandonedRequests() {
        let codes: [POSIXErrorCode] = [
            .ETIMEDOUT, .EINTR, .ECANCELED, .ENOMEM, .EINVAL,
            .ECONNRESET, .ECONNABORTED, .ECONNREFUSED, .EPIPE, .ENOTCONN,
            .ESHUTDOWN, .EBADF, .ENOTSOCK, .ENETRESET, .ENETDOWN,
            .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH,
        ]

        for code in codes {
            #expect(NFSContextDisposalPolicy.mayHaveAbandonedRequest(
                errorDomain: NSPOSIXErrorDomain,
                errorCode: Int(code.rawValue)
            ))
        }
    }

    /// libnfs turns the server's NFS status into a negative errno, and an RPC
    /// level failure that was delivered into EFAULT; either way the request
    /// completed and nothing is left queued.
    @Test("Statuses carried by a reply still unmount and release the client")
    func releasesClientForDeliveredFailures() {
        let codes: [POSIXErrorCode] = [
            .ENOENT, .EACCES, .EPERM, .EIO, .EEXIST, .ENOTDIR, .EISDIR,
            .ENOSPC, .EROFS, .ESTALE, .EFAULT, .ENAMETOOLONG, .ENOTEMPTY,
            .EDQUOT, .ENODATA,
        ]

        for code in codes {
            #expect(!NFSContextDisposalPolicy.mayHaveAbandonedRequest(
                errorDomain: NSPOSIXErrorDomain,
                errorCode: Int(code.rawValue)
            ))
        }
    }

    @Test("Errors from other domains never retire a client")
    func ignoresUnrelatedDomains() {
        #expect(!NFSContextDisposalPolicy.mayHaveAbandonedRequest(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorTimedOut
        ))
        #expect(!NFSContextDisposalPolicy.mayHaveAbandonedRequest(
            errorDomain: NSCocoaErrorDomain,
            errorCode: Int(POSIXErrorCode.ETIMEDOUT.rawValue)
        ))
    }
}
