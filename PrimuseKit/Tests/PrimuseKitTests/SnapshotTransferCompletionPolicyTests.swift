import Testing
@testable import PrimuseKit

@Suite("Snapshot transfer completion")
struct SnapshotTransferCompletionPolicyTests {
    @Test("iCloud reports success only when every required transfer completes")
    func iCloudRequiresSnapshotAndCredentialCompletion() {
        #expect(SnapshotTransferCompletionPolicy.iCloudSucceeded(
            snapshotUploaded: true,
            credentialOutcome: .succeeded
        ))
        #expect(SnapshotTransferCompletionPolicy.iCloudSucceeded(
            snapshotUploaded: true,
            credentialOutcome: .skipped
        ))
        #expect(!SnapshotTransferCompletionPolicy.iCloudSucceeded(
            snapshotUploaded: true,
            credentialOutcome: .failed
        ))
        #expect(!SnapshotTransferCompletionPolicy.iCloudSucceeded(
            snapshotUploaded: false,
            credentialOutcome: .succeeded
        ))
    }

    @Test("LAN never sends a partial payload without prepared credentials")
    func lanRequiresPreparedCredentials() {
        #expect(SnapshotTransferCompletionPolicy.canSendLAN(
            credentialOutcome: .succeeded
        ))
        #expect(!SnapshotTransferCompletionPolicy.canSendLAN(
            credentialOutcome: .skipped
        ))
        #expect(!SnapshotTransferCompletionPolicy.canSendLAN(
            credentialOutcome: .failed
        ))
    }

    @Test("Apple TV transfer failures expose stable diagnostic codes")
    func transferFailureDiagnosticCodes() {
        #expect(AppleTVTransferFailure.snapshotMissing.diagnosticCode == "TV-SNAPSHOT-MISSING")
        #expect(AppleTVTransferFailure.localNetworkFailed(
            detail: "offline"
        ).diagnosticCode == "TV-LAN-CONNECTION")
        #expect(AppleTVTransferFailure.tvRejected(
            statusCode: 403
        ).diagnosticCode == "TV-HTTP-403")
    }

    @Test("Apple TV HTTP failures retain the actual status")
    func transferFailureHTTPStatusMessage() {
        let forbidden = AppleTVTransferFailure.tvRejected(statusCode: 403)
        let unexpected = AppleTVTransferFailure.tvRejected(statusCode: 429)
        #expect(forbidden.userFacingMessage.contains("403"))
        #expect(unexpected.userFacingMessage.contains("429"))
    }
}
