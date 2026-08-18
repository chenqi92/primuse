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
        #expect(intent?.needsMusicSourceTombstoneUpload == true)
        #expect(intent?.needsSourceSnapshotUpload == true)
        #expect(intent?.needsCredentialRemoval == true)
    }

    @Test("Partial remote success retains only the failed operation for retry")
    func partialSuccessIsDurable() {
        let intent = SourceCloudCleanupIntent(
            tombstone: makeSource(id: "source", deletedAt: Date(timeIntervalSince1970: 100))
        )

        let afterSourceUpload = SourceCloudCleanupPolicy.applying(
            musicSourceTombstoneUploaded: true,
            sourceSnapshotUploaded: true,
            credentialRemoved: false,
            to: intent
        )
        #expect(afterSourceUpload?.needsSourceSnapshotUpload == false)
        #expect(afterSourceUpload?.needsCredentialRemoval == true)
        #expect(afterSourceUpload?.needsMusicSourceTombstoneUpload == false)

        let completed = SourceCloudCleanupPolicy.applying(
            musicSourceTombstoneUploaded: false,
            sourceSnapshotUploaded: false,
            credentialRemoved: true,
            to: afterSourceUpload!
        )
        #expect(completed == nil)
    }

    @Test("Only an explicit restore supersedes a pending tombstone")
    func explicitRestoreCancelsCleanup() {
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
        let ordinaryNewerEdit = MusicSource(
            id: "source",
            name: "Edited",
            type: .smb,
            modifiedAt: Date(timeIntervalSince1970: 101)
        )
        let restoredAt = Date(timeIntervalSince1970: 102)
        let explicitRestore = MusicSource(
            id: "source",
            name: "Restored",
            type: .smb,
            modifiedAt: restoredAt,
            restoredAt: restoredAt
        )

        #expect(!SourceCloudCleanupPolicy.isSuperseded(intent, by: olderActive))
        #expect(!SourceCloudCleanupPolicy.isSuperseded(intent, by: ordinaryNewerEdit))
        #expect(SourceCloudCleanupPolicy.isSuperseded(intent, by: explicitRestore))
    }

    @Test("A later delete refreshes the tombstone and all retry flags")
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
        #expect(result?.needsMusicSourceTombstoneUpload == true)
        #expect(result?.needsSourceSnapshotUpload == true)
        #expect(result?.needsCredentialRemoval == true)
    }

    @Test("Legacy cleanup journals require a source tombstone upload")
    func legacyJournalMigration() throws {
        let intent = SourceCloudCleanupIntent(
            tombstone: makeSource(id: "source", deletedAt: Date(timeIntervalSince1970: 100)),
            needsMusicSourceTombstoneUpload: false,
            needsSourceSnapshotUpload: false,
            needsCredentialRemoval: false
        )
        let data = try JSONEncoder().encode(intent)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "needsMusicSourceTombstoneUpload")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(SourceCloudCleanupIntent.self, from: legacy)
        #expect(decoded.needsMusicSourceTombstoneUpload)
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
