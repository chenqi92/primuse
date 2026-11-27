import Foundation
import Testing
@testable import PrimuseKit

@Suite("SMB connection recovery")
struct SMBConnectionRecoveryPolicyTests {
    @Test("An empty AMSMB2 callback reconnects instead of treating the directory as empty")
    func reconnectsForInvalidEmptyData() {
        #expect(SMBConnectionRecoveryPolicy.shouldReconnect(
            errorDomain: NSPOSIXErrorDomain,
            errorCode: Int(POSIXErrorCode.ENODATA.rawValue),
            completedReconnectAttempts: 0
        ))
    }

    @Test("Known broken-session errors reconnect")
    func reconnectsForBrokenSessionErrors() {
        let codes: [POSIXErrorCode] = [
            .ECONNRESET, .EPIPE, .EBADF, .ENOTCONN, .ETIMEDOUT, .ENETRESET,
        ]

        for code in codes {
            #expect(SMBConnectionRecoveryPolicy.shouldReconnect(
                errorDomain: NSPOSIXErrorDomain,
                errorCode: Int(code.rawValue),
                completedReconnectAttempts: 0
            ))
        }
    }

    @Test("Recovery is bounded to one fresh SMB session")
    func reconnectIsBounded() {
        #expect(!SMBConnectionRecoveryPolicy.shouldReconnect(
            errorDomain: NSPOSIXErrorDomain,
            errorCode: Int(POSIXErrorCode.ENODATA.rawValue),
            completedReconnectAttempts: SMBConnectionRecoveryPolicy.maximumReconnectAttempts
        ))
    }

    @Test("Authentication and unrelated domains fail without reconnecting")
    func rejectsPermanentAndUnrelatedErrors() {
        #expect(!SMBConnectionRecoveryPolicy.shouldReconnect(
            errorDomain: NSPOSIXErrorDomain,
            errorCode: Int(POSIXErrorCode.EACCES.rawValue),
            completedReconnectAttempts: 0
        ))
        #expect(!SMBConnectionRecoveryPolicy.shouldReconnect(
            errorDomain: NSURLErrorDomain,
            errorCode: NSURLErrorNetworkConnectionLost,
            completedReconnectAttempts: 0
        ))
    }
}
