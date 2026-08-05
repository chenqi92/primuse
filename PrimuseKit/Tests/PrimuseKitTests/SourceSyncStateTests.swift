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
