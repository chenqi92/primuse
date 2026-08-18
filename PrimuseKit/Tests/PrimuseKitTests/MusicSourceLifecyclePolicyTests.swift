import Foundation
import Testing
@testable import PrimuseKit

@Suite("Music source lifecycle policy")
struct MusicSourceLifecyclePolicyTests {
    @Test("Ordinary active edits cannot supersede a deletion")
    func ordinaryEditDoesNotRestore() {
        let deletedAt = Date(timeIntervalSince1970: 100)
        let tombstone = MusicSource(
            id: "source",
            name: "Deleted",
            type: .oneDrive,
            modifiedAt: deletedAt,
            isDeleted: true,
            deletedAt: deletedAt
        )
        let active = MusicSource(
            id: "source",
            name: "Stale",
            type: .oneDrive,
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let deletion = MusicSourceDeletionRecord(tombstone: tombstone)
        #expect(MusicSourceLifecyclePolicy.shouldSuppress(active: active, with: deletion))
        #expect(MusicSourceLifecyclePolicy.winner(local: tombstone, remote: active) == .local)
    }

    @Test("Explicit restore after deletion wins")
    func explicitRestoreWins() {
        let deletedAt = Date(timeIntervalSince1970: 100)
        let tombstone = MusicSource(
            id: "source",
            name: "Deleted",
            type: .oneDrive,
            modifiedAt: deletedAt,
            isDeleted: true,
            deletedAt: deletedAt
        )
        let restoredAt = Date(timeIntervalSince1970: 101)
        let active = MusicSource(
            id: "source",
            name: "Restored",
            type: .oneDrive,
            modifiedAt: restoredAt,
            restoredAt: restoredAt
        )

        let deletion = MusicSourceDeletionRecord(tombstone: tombstone)
        #expect(MusicSourceLifecyclePolicy.isExplicitRestore(active, after: deletion))
        #expect(MusicSourceLifecyclePolicy.winner(local: tombstone, remote: active) == .remote)
    }

    @Test("An unrelated new source is not suppressed by old deletions")
    func unrelatedBaiduSourceRemainsActive() {
        let deletedAt = Date(timeIntervalSince1970: 100)
        let oldOneDrive = MusicSource(
            id: "deleted-onedrive",
            name: "Old OneDrive",
            type: .oneDrive,
            modifiedAt: deletedAt,
            isDeleted: true,
            deletedAt: deletedAt
        )
        let newBaidu = MusicSource(
            id: "new-baidu",
            name: "Baidu",
            type: .baiduPan,
            modifiedAt: Date(timeIntervalSince1970: 200)
        )

        let deletion = MusicSourceDeletionRecord(tombstone: oldOneDrive)
        #expect(!MusicSourceLifecyclePolicy.shouldSuppress(active: newBaidu, with: deletion))
    }

    @Test("Deletion records retain the newest full tombstone")
    func deletionCoalescing() {
        let deletedAt = Date(timeIntervalSince1970: 100)
        let idOnly = MusicSourceDeletionRecord(id: "source", deletedAt: deletedAt)
        let tombstone = MusicSource(
            id: "source",
            name: "Deleted",
            type: .smb,
            modifiedAt: deletedAt,
            isDeleted: true,
            deletedAt: deletedAt
        )
        let merged = MusicSourceLifecyclePolicy.coalescing(
            current: idOnly,
            incoming: MusicSourceDeletionRecord(tombstone: tombstone)
        )

        #expect(merged.tombstone == tombstone)
    }

    @Test("A newer ID-only deletion retains the full tombstone payload")
    func idOnlyDeletionRetainsPayload() {
        let oldDeletedAt = Date(timeIntervalSince1970: 100)
        let newDeletedAt = Date(timeIntervalSince1970: 200)
        let tombstone = MusicSource(
            id: "source",
            name: "Deleted",
            type: .oneDrive,
            modifiedAt: oldDeletedAt,
            isDeleted: true,
            deletedAt: oldDeletedAt
        )
        let merged = MusicSourceLifecyclePolicy.coalescing(
            current: MusicSourceDeletionRecord(tombstone: tombstone),
            incoming: MusicSourceDeletionRecord(id: "source", deletedAt: newDeletedAt)
        )

        #expect(merged.deletedAt == newDeletedAt)
        #expect(merged.tombstone?.deletedAt == newDeletedAt)
        #expect(merged.tombstone?.isDeleted == true)
    }

    @Test("Directory labels and restore metadata survive source encoding")
    func sourceRoundTrip() throws {
        let restoredAt = Date(timeIntervalSince1970: 123)
        let source = MusicSource(
            id: "source",
            name: "Drive",
            type: .oneDrive,
            scannedDirectoryDisplayNames: ["opaque-id": "Music"],
            restoredAt: restoredAt
        )
        let decoded = try JSONDecoder().decode(
            MusicSource.self,
            from: JSONEncoder().encode(source)
        )

        #expect(decoded.scannedDirectoryDisplayNames == ["opaque-id": "Music"])
        #expect(decoded.restoredAt == restoredAt)
    }

    @Test("Older source payloads default new metadata safely")
    func legacySourceDefaults() throws {
        let source = MusicSource(id: "source", name: "Drive", type: .oneDrive)
        let encoded = try JSONEncoder().encode(source)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "scannedDirectoryDisplayNames")
        object.removeValue(forKey: "restoredAt")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(MusicSource.self, from: legacy)

        #expect(decoded.scannedDirectoryDisplayNames.isEmpty)
        #expect(decoded.restoredAt == nil)
    }

    @Test("Opaque directory IDs never become path-derived labels")
    func opaqueFallbackIsHidden() {
        for type in [MusicSourceType.oneDrive, .googleDrive, .aliyunDrive, .drime, .pan115, .pan123] {
            #expect(SourceDirectoryLabelPolicy.readableFallback(
                path: "opaque-internal-id",
                sourceType: type
            ) == nil)
        }
        #expect(SourceDirectoryLabelPolicy.readableFallback(
            path: "/Music/Jazz",
            sourceType: .baiduPan
        ) == "Jazz")
    }
}
