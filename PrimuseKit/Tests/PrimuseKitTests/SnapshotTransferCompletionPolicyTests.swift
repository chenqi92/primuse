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
}
