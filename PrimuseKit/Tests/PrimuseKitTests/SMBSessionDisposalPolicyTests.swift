import Foundation
import Testing
@testable import PrimuseKit

@Suite("SMB session disposal")
struct SMBSessionDisposalPolicyTests {
    @Test("A request that stopped being awaited keeps its session alive")
    func retainsSessionForAbandonedRequests() {
        let codes: [POSIXErrorCode] = [
            .ETIMEDOUT, .ECONNRESET, .ECONNABORTED, .ECONNREFUSED, .EPIPE,
            .ENOTCONN, .ESHUTDOWN, .EBADF, .ENOTSOCK, .ENETRESET, .ENETDOWN,
            .ENETUNREACH, .EHOSTDOWN, .EHOSTUNREACH, .EIO,
        ]

        for code in codes {
            #expect(SMBSessionDisposalPolicy.mayHaveAbandonedRequest(
                errorDomain: NSPOSIXErrorDomain,
                errorCode: Int(code.rawValue)
            ))
        }
    }

    /// A delivered reply leaves nothing queued inside libsmb2, so the session
    /// can still be closed and released the normal way.
    @Test("Failures carried by a delivered reply still close their session")
    func closesSessionForDeliveredFailures() {
        let codes: [POSIXErrorCode] = [
            .EACCES, .EPERM, .ENOENT, .EEXIST, .ENOTDIR, .EISDIR, .ENOSPC,
            // AMSMB2 reports a callback that fired without its payload as
            // ENODATA: the reply arrived, so nothing is left queued.
            .ENODATA,
        ]

        for code in codes {
            #expect(!SMBSessionDisposalPolicy.mayHaveAbandonedRequest(
                errorDomain: NSPOSIXErrorDomain,
                errorCode: Int(code.rawValue)
            ))
        }
    }

    @Test("Errors from other domains never retire a session")
    func ignoresUnrelatedDomains() {
        #expect(!SMBSessionDisposalPolicy.mayHaveAbandonedRequest(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorTimedOut
        ))
        #expect(!SMBSessionDisposalPolicy.mayHaveAbandonedRequest(
            errorDomain: NSCocoaErrorDomain,
            errorCode: Int(POSIXErrorCode.ETIMEDOUT.rawValue)
        ))
    }

    @Test("A retired session is held for the rest of the process")
    func retiredSessionsStayAlive() {
        final class Session {}

        let store = SMBRetiredSessions()
        weak var observed: Session?

        do {
            let session = Session()
            observed = session
            #expect(store.retire(session) == 1)
        }

        #expect(observed != nil)
        #expect(store.count == 1)
    }
}
