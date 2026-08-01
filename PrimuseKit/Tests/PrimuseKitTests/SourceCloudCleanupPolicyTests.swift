import Foundation
import Testing
@testable import PrimuseKit

@Suite("Source cloud cleanup journal policy")
struct SourceCloudCleanupPolicyTests {
    @Test("Permanent removal cannot discard a captured soft-delete intent")
    func missingLocalSourceKeepsIntent() {
        let tombstone = makeSource(id: "source", deletedAt: Date(timeIntervalSince1970: 100))
        let intent = SourceCloudCleanupPolicy.coalescing(current: nil, tombstone: tombstone)

        #expect(intent != nil)
        #expect(!SourceCloudCleanupPolicy.isSuperseded(intent!, by: nil))
        #expect(intent?.needsSourceSnapshotUpload == true)
        #expect(intent?.needsCredentialRemoval == true)
    }

    @Test("Partial remote success retains only the failed operation for retry")
    func partialSuccessIsDurable() {
        let intent = SourceCloudCleanupIntent(
            tombstone: makeSource(id: "source", deletedAt: Date(timeIntervalSince1970: 100))
        )

        let afterSourceUpload = SourceCloudCleanupPolicy.applying(
            sourceSnapshotUploaded: true,
            credentialRemoved: false,
            to: intent
        )
        #expect(afterSourceUpload?.needsSourceSnapshotUpload == false)
        #expect(afterSourceUpload?.needsCredentialRemoval == true)

        let completed = SourceCloudCleanupPolicy.applying(
            sourceSnapshotUploaded: false,
            credentialRemoved: true,
            to: afterSourceUpload!
        )
        #expect(completed == nil)
    }

    @Test("Only a newer active restore supersedes a pending tombstone")
    func newerRestoreCancelsCleanup() {
        let deletedAt = Date(timeIntervalSince1970: 100)
        let intent = SourceCloudCleanupIntent(
            tombstone: makeSource(id: "source", deletedAt: deletedAt)
        )
        let olderActive = MusicSource(
            id: "source",
            name: "Older",
            type: .smb,
            modifiedAt: Date(timeIntervalSince1970: 99)
        )
        let newerActive = MusicSource(
            id: "source",
            name: "Restored",
            type: .smb,
            modifiedAt: Date(timeIntervalSince1970: 101)
        )

        #expect(!SourceCloudCleanupPolicy.isSuperseded(intent, by: olderActive))
        #expect(SourceCloudCleanupPolicy.isSuperseded(intent, by: newerActive))
    }

    @Test("A later delete refreshes the tombstone and both retry flags")
    func coalescingKeepsNewestDelete() {
        let old = makeSource(id: "source", name: "Old", deletedAt: Date(timeIntervalSince1970: 100))
        let current = SourceCloudCleanupIntent(
            tombstone: old,
            needsSourceSnapshotUpload: false,
            needsCredentialRemoval: true
        )
        let new = makeSource(id: "source", name: "New", deletedAt: Date(timeIntervalSince1970: 200))

        let result = SourceCloudCleanupPolicy.coalescing(current: current, tombstone: new)
        #expect(result?.tombstone.name == "New")
        #expect(result?.needsSourceSnapshotUpload == true)
        #expect(result?.needsCredentialRemoval == true)
    }

    private func makeSource(
        id: String,
        name: String = "Deleted",
        deletedAt: Date
    ) -> MusicSource {
        MusicSource(
            id: id,
            name: name,
            type: .smb,
            modifiedAt: deletedAt,
            isDeleted: true,
            deletedAt: deletedAt
        )
    }
}
