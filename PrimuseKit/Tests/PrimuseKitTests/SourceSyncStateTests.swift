import Foundation
import Testing
@testable import PrimuseKit

struct SourceSyncStateTests {
    @Test func stateIsInvalidatedByScopeOrSchemaChange() {
        let state = SourceSyncState(sourceID: "source", scopeFingerprint: "scope")
        #expect(state.isUsable(sourceID: "source", scopeFingerprint: "scope"))
        #expect(!state.isUsable(sourceID: "source", scopeFingerprint: "other"))
        #expect(!state.isUsable(sourceID: "other", scopeFingerprint: "scope"))
        var old = state
        old.schemaVersion = 0
        #expect(!old.isUsable(sourceID: "source", scopeFingerprint: "scope"))
    }

    @Test func cursorNeverAdvancesBeforeLibraryCommit() {
        #expect(!SourceSyncCommitPolicy.shouldAdvanceCursor(
            libraryPersistenceSucceeded: false,
            scanCompleted: true,
            hadPartialFailure: false
        ))
        #expect(!SourceSyncCommitPolicy.shouldAdvanceCursor(
            libraryPersistenceSucceeded: true,
            scanCompleted: false,
            hadPartialFailure: false
        ))
        #expect(SourceSyncCommitPolicy.shouldAdvanceCursor(
            libraryPersistenceSucceeded: true,
            scanCompleted: true,
            hadPartialFailure: false
        ))
    }

    @Test func partialScanCannotPruneOrCommitCursor() {
        #expect(!SourceSyncCommitPolicy.shouldPruneUnseenEntries(
            scanCompleted: true,
            hadPartialFailure: true
        ))
        #expect(!SourceSyncCommitPolicy.shouldAdvanceCursor(
            libraryPersistenceSucceeded: true,
            scanCompleted: true,
            hadPartialFailure: true
        ))
    }

    @Test func stateRoundTripsWithPendingDirectoryQueue() throws {
        let item = SourceSyncIndexedItem(
            stableKey: "id:1",
            path: "/music/a.flac",
            displayName: "a.flac",
            parentPath: "/music",
            isDirectory: false,
            songIDs: ["song"],
            size: 12,
            modifiedDate: Date(timeIntervalSince1970: 10),
            revision: "etag",
            seenEpoch: 4
        )
        let state = SourceSyncState(
            sourceID: "source",
            scopeFingerprint: "scope",
            cursors: ["/": "cursor"],
            index: [item.stableKey: item],
            pendingDirectories: ["/music/next"],
            scanEpoch: 4
        )
        let decoded = try JSONDecoder().decode(
            SourceSyncState.self,
            from: JSONEncoder().encode(state)
        )
        #expect(decoded == state)
        #expect(decoded.index["id:1"]?.displayName == "a.flac")
    }

    @Test func legacyIndexWithoutDisplayNameStillDecodes() throws {
        let data = Data(#"""
        {
          "stableKey":"id:1",
          "path":"opaque-item-id",
          "parentPath":"opaque-parent-id",
          "isDirectory":false,
          "songIDs":["song"],
          "size":12,
          "revision":"etag",
          "seenEpoch":4
        }
        """#.utf8)
        let item = try JSONDecoder().decode(SourceSyncIndexedItem.self, from: data)
        #expect(item.displayName == nil)
        #expect(item.path == "opaque-item-id")
    }

    @Test func opaqueCloudSourcesRebuildLegacyFolderTopology() {
        let legacyItem = SourceSyncIndexedItem(
            stableKey: "opaque-item-id",
            path: "opaque-item-id",
            parentPath: "opaque-parent-id",
            isDirectory: false,
            size: 12,
            modifiedDate: nil,
            revision: "etag"
        )
        let legacyState = SourceSyncState(
            sourceID: "source",
            scopeFingerprint: "scope",
            index: [legacyItem.stableKey: legacyItem]
        )

        for sourceType in [
            MusicSourceType.aliyunDrive,
            .googleDrive,
            .oneDrive,
            .drime,
            .pan115,
            .pan123,
        ] {
            #expect(SourceSyncFolderTopologyPolicy.requiresRebuild(
                sourceType: sourceType,
                state: legacyState
            ))
        }
    }

    @Test func currentCloudTopologyAndPathBasedSourcesDoNotRebuild() {
        let currentItem = SourceSyncIndexedItem(
            stableKey: "opaque-item-id",
            path: "opaque-item-id",
            displayName: "周杰伦",
            parentPath: "opaque-parent-id",
            isDirectory: true,
            size: 0,
            modifiedDate: nil,
            revision: "etag"
        )
        let currentState = SourceSyncState(
            sourceID: "source",
            scopeFingerprint: "scope",
            index: [currentItem.stableKey: currentItem]
        )
        var legacyState = currentState
        legacyState.index[currentItem.stableKey]?.displayName = nil

        #expect(!SourceSyncFolderTopologyPolicy.requiresRebuild(
            sourceType: .oneDrive,
            state: currentState
        ))
        #expect(!SourceSyncFolderTopologyPolicy.requiresRebuild(
            sourceType: .oneDrive,
            state: SourceSyncState(sourceID: "source", scopeFingerprint: "scope")
        ))
        for sourceType in [MusicSourceType.baiduPan, .dropbox] {
            #expect(!SourceSyncFolderTopologyPolicy.requiresRebuild(
                sourceType: sourceType,
                state: legacyState
            ))
        }
    }

    @Test func uncommittedDirectoryProgressRoundTripsIndependently() throws {
        let item = SourceSyncIndexedItem(
            stableKey: "id:1",
            path: "/music/a.flac",
            parentPath: "/music",
            isDirectory: false,
            songIDs: ["song"],
            size: 12,
            modifiedDate: nil,
            revision: "etag",
            seenEpoch: 5
        )
        let progress = SourceScanResumeState(
            pendingDirectories: ["/music/b", "/music/c"],
            encounteredSongIDs: ["song"],
            index: [item.stableKey: item]
        )
        let decoded = try JSONDecoder().decode(
            SourceScanResumeState.self,
            from: JSONEncoder().encode(progress)
        )
        #expect(decoded == progress)
        #expect(decoded.isUsable)

        var stale = decoded
        stale.schemaVersion = 0
        #expect(!stale.isUsable)
    }

    @Test("Version-1 snapshots are rejected because index keys changed")
    func legacySchemaVersionForcesRebuild() throws {
        // A v1 state keyed Google Drive items by the bare provider id and Baidu
        // items by "path:<lowercased path>". Both are keyed differently now, so
        // reusing a v1 index would diff every file against a key that no longer
        // exists and report the whole source as deleted-and-re-added.
        var legacy = SourceSyncState(
            sourceID: "source",
            scopeFingerprint: "scope",
            cursors: ["account": "cursor"]
        )
        legacy.schemaVersion = 1
        #expect(!legacy.isUsable(sourceID: "source", scopeFingerprint: "scope"))
        #expect(SourceSyncState.currentSchemaVersion == 2)

        var legacyResume = SourceScanResumeState(pendingDirectories: ["/music"])
        legacyResume.schemaVersion = 1
        #expect(!legacyResume.isUsable)
        #expect(SourceScanResumeState.currentSchemaVersion == 2)
    }

    @Test("Periodic sync requires a committed native cursor")
    func periodicSyncRequiresCursor() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var state = SourceSyncState(
            sourceID: "source",
            scopeFingerprint: "scope",
            lastSuccessfulSyncAt: now.addingTimeInterval(-SourcePeriodicSyncPolicy.interval - 1)
        )
        #expect(!SourcePeriodicSyncPolicy.isDue(state, now: now))

        state.cursors = ["/": "cursor"]
        #expect(SourcePeriodicSyncPolicy.isDue(state, now: now))
        state.requiresDeepScan = true
        #expect(!SourcePeriodicSyncPolicy.isDue(state, now: now))
    }

    @Test("Periodic sync schedules from the last successful commit")
    func periodicSyncSchedule() {
        let committedAt = Date(timeIntervalSince1970: 1_000_000)
        let state = SourceSyncState(
            sourceID: "source",
            scopeFingerprint: "scope",
            cursors: ["/": "cursor"],
            lastFullScanAt: committedAt.addingTimeInterval(-1_000),
            lastSuccessfulSyncAt: committedAt
        )
        #expect(
            SourcePeriodicSyncPolicy.nextSyncDate(for: state)
                == committedAt.addingTimeInterval(SourcePeriodicSyncPolicy.interval)
        )
    }
}
