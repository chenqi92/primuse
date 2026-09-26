import Foundation

/// Whether the library snapshot currently on disk may be promoted to the backup
/// slot by the write that is about to replace it.
///
/// Promoting a corrupt file would destroy the last known-good copy, so the
/// default answer requires decoding the whole file first. That decode is only
/// redundant in one case: the write immediately before this one, on the same
/// serialized chain, produced those exact bytes and reported success. Every
/// other producer of the file — a previous launch, `reloadFromDisk`, an
/// iCloud/Apple TV snapshot import, a failed write — leaves the validity
/// unknown, and the decode stays the guard that protects the backup slot.
public enum LibrarySnapshotBackupPolicy {
    /// Validity is only known from the chained predecessor's own success.
    /// `nil` means there was no predecessor on this chain.
    public nonisolated static func existingFileIsKnownValid(
        previousChainedWriteSucceeded: Bool?
    ) -> Bool {
        existingFileIsKnownValid(
            previousChainedWriteSucceeded: previousChainedWriteSucceeded,
            existingFileMatchesLastVerifiedWrite: false
        )
    }

    /// A successful write also records the file identity (size, modification
    /// time, file number) it left behind. When the file on disk still carries
    /// that identity, those are the bytes an earlier — possibly previous-launch —
    /// write encoded and replaced atomically, so the whole-file decode would only
    /// re-prove what is already known. On a 200K-song library that decode is
    /// hundreds of MB on top of the encode and is enough to get the app killed.
    /// Any other producer replaces the file and changes its identity.
    public nonisolated static func existingFileIsKnownValid(
        previousChainedWriteSucceeded: Bool?,
        existingFileMatchesLastVerifiedWrite: Bool
    ) -> Bool {
        previousChainedWriteSucceeded == true || existingFileMatchesLastVerifiedWrite
    }

    /// Decode the existing file exactly when its validity is not already known.
    public nonisolated static func shouldValidateExistingFile(
        existingFileIsKnownValid: Bool
    ) -> Bool {
        !existingFileIsKnownValid
    }

    /// `existingFileIsValid` is `nil` when no decode was performed — either
    /// because validity was already known, or because there is no file.
    public nonisolated static func shouldPreserveExistingAsBackup(
        existingFileIsKnownValid: Bool,
        existingFileIsValid: Bool?
    ) -> Bool {
        existingFileIsKnownValid || existingFileIsValid == true
    }
}
