import Foundation

/// Identity of a snapshot file on disk: size, modification time and, where the
/// file system reports it, the inode. Enough to notice both an in-place rewrite
/// and a replace-by-rename.
public struct SnapshotFileIdentity: Codable, Equatable, Sendable {
    public let size: Int64
    public let modificationNanoseconds: Int64
    public let fileNumber: UInt64?

    public init(size: Int64, modificationNanoseconds: Int64, fileNumber: UInt64?) {
        self.size = size
        self.modificationNanoseconds = modificationNanoseconds
        self.fileNumber = fileNumber
    }
}

/// Guards a computation that reads a snapshot file, works on the bytes away
/// from the actor that owns the file, and then writes the result back.
///
/// Between the read and the write another writer may have replaced the file, in
/// which case the computed result was derived from a baseline that no longer
/// exists and writing it would undo that writer's change. The caller captures
/// the identity before reading and compares it again before writing.
///
/// A file that was absent both times is unchanged, so the baseline still holds.
/// A file that appeared or disappeared in between does not.
public enum SnapshotBaselineGate {
    public static func isStillValid(captured: SnapshotFileIdentity?, current: SnapshotFileIdentity?) -> Bool {
        captured == current
    }
}
