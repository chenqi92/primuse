import Testing
@testable import PrimuseKit

@Suite("Library snapshot backup policy")
struct LibrarySnapshotBackupPolicyTests {
    @Test("Only a successful chained predecessor makes the existing file known-valid")
    func knownValidRequiresASucceededPredecessor() {
        #expect(
            LibrarySnapshotBackupPolicy.existingFileIsKnownValid(
                previousChainedWriteSucceeded: true
            )
        )
        #expect(
            LibrarySnapshotBackupPolicy.existingFileIsKnownValid(
                previousChainedWriteSucceeded: false
            ) == false
        )
        #expect(
            LibrarySnapshotBackupPolicy.existingFileIsKnownValid(
                previousChainedWriteSucceeded: nil
            ) == false
        )
    }

    @Test("No predecessor on the chain still decodes the file before promoting it")
    func noPredecessorValidates() {
        let knownValid = LibrarySnapshotBackupPolicy.existingFileIsKnownValid(
            previousChainedWriteSucceeded: nil
        )
        #expect(
            LibrarySnapshotBackupPolicy.shouldValidateExistingFile(
                existingFileIsKnownValid: knownValid
            )
        )
        #expect(
            LibrarySnapshotBackupPolicy.shouldPreserveExistingAsBackup(
                existingFileIsKnownValid: knownValid,
                existingFileIsValid: true
            )
        )
    }

    @Test("A succeeded predecessor skips the decode and still promotes the file")
    func succeededPredecessorSkipsDecode() {
        let knownValid = LibrarySnapshotBackupPolicy.existingFileIsKnownValid(
            previousChainedWriteSucceeded: true
        )
        #expect(
            LibrarySnapshotBackupPolicy.shouldValidateExistingFile(
                existingFileIsKnownValid: knownValid
            ) == false
        )
        #expect(
            LibrarySnapshotBackupPolicy.shouldPreserveExistingAsBackup(
                existingFileIsKnownValid: knownValid,
                existingFileIsValid: nil
            )
        )
    }

    @Test("A failed predecessor re-establishes validity by decoding")
    func failedPredecessorValidatesAgain() {
        let knownValid = LibrarySnapshotBackupPolicy.existingFileIsKnownValid(
            previousChainedWriteSucceeded: false
        )
        #expect(
            LibrarySnapshotBackupPolicy.shouldValidateExistingFile(
                existingFileIsKnownValid: knownValid
            )
        )
        #expect(
            LibrarySnapshotBackupPolicy.shouldPreserveExistingAsBackup(
                existingFileIsKnownValid: knownValid,
                existingFileIsValid: false
            ) == false
        )
    }

    @Test("A corrupt or absent existing file is never promoted to the backup slot")
    func corruptOrAbsentFileIsNeverPromoted() {
        #expect(
            LibrarySnapshotBackupPolicy.shouldPreserveExistingAsBackup(
                existingFileIsKnownValid: false,
                existingFileIsValid: false
            ) == false
        )
        // No file on disk: nothing was decoded, nothing may be promoted.
        #expect(
            LibrarySnapshotBackupPolicy.shouldPreserveExistingAsBackup(
                existingFileIsKnownValid: false,
                existingFileIsValid: nil
            ) == false
        )
    }
}
