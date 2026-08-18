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

@Suite("Baidu stable snapshot reconciliation")
struct BaiduSnapshotReconciliationTests {
    @Test("Legacy v1 state decodes without discarding path index")
    func legacyStateMigrationDefaults() throws {
        let data = Data(#"""
        {
          "schemaVersion":1,
          "sourceID":"baidu-source",
          "scopeFingerprint":"account-a",
          "cursors":{},
          "index":{
            "path:/music/a.flac":{
              "stableKey":"path:/music/a.flac",
              "path":"/Music/A.flac",
              "parentPath":"/Music",
              "isDirectory":false,
              "songIDs":["song-a"],
              "size":42,
              "revision":"md5-a",
              "seenEpoch":3
            }
          },
          "pendingDirectories":[],
          "scanEpoch":3,
          "requiresDeepScan":false
        }
        """#.utf8)

        let state = try JSONDecoder().decode(SourceSyncState.self, from: data)

        #expect(state.schemaVersion == 1)
        #expect(SourceSyncState.currentSchemaVersion == 1)
        #expect(state.identityScopeFingerprint == nil)
        #expect(state.index["path:/music/a.flac"]?.songIDs == ["song-a"])
        #expect(state.identityAliases.isEmpty)
        #expect(state.missingStableKeys.isEmpty)
        #expect(state.reconciliation == nil)
    }

    @Test("Same fs_id keeps Song ID through file move and rename")
    func stableIdentitySurvivesPathChange() throws {
        let previous = baiduIndexedItem(
            key: "baidu:42",
            path: "/Old/A.flac",
            parent: "/Old",
            songIDs: ["song-a"]
        )
        let current = baiduIndexedItem(
            key: "baidu:42",
            path: "/New/Renamed.flac",
            parent: "/New"
        )

        let result = try BaiduSnapshotDiffPolicy.plan(
            previousIndex: [previous.stableKey: previous],
            currentItems: [current],
            liveDirectories: ["/Old", "/New"]
        )

        #expect(result.reconciledIndex["baidu:42"]?.songIDs == ["song-a"])
        #expect(result.changedParentPaths == ["/Old", "/New"])
        #expect(result.deletedStableKeys.isEmpty)
        #expect(result.reconciliation == nil)
    }

    @Test("Directory moves, additions and same-ID overwrites identify every live parent")
    func topologyAdditionAndOverwriteDiff() throws {
        let previousDirectory = SourceSyncIndexedItem(
            stableKey: "baidu:10",
            path: "/Old/Album",
            displayName: "Album",
            parentPath: "/Old",
            isDirectory: true,
            size: 0,
            modifiedDate: nil,
            revision: nil
        )
        let previousAudio = baiduIndexedItem(
            key: "baidu:42",
            path: "/Old/Album/A.flac",
            parent: "/Old/Album",
            songIDs: ["song-a"],
            revision: "old-md5"
        )
        var movedDirectory = previousDirectory
        movedDirectory.path = "/New/Renamed"
        movedDirectory.parentPath = "/New"
        movedDirectory.displayName = "Renamed"
        let overwrittenAudio = baiduIndexedItem(
            key: "baidu:42",
            path: "/New/Renamed/A.flac",
            parent: "/New/Renamed",
            revision: "new-md5"
        )
        let addedAudio = baiduIndexedItem(
            key: "baidu:99",
            path: "/New/Renamed/B.flac",
            parent: "/New/Renamed"
        )

        let result = try BaiduSnapshotDiffPolicy.plan(
            previousIndex: [
                previousDirectory.stableKey: previousDirectory,
                previousAudio.stableKey: previousAudio,
            ],
            currentItems: [movedDirectory, overwrittenAudio, addedAudio],
            liveDirectories: ["/Old", "/Old/Album", "/New", "/New/Renamed"]
        )

        #expect(result.reconciledIndex["baidu:42"]?.songIDs == ["song-a"])
        #expect(result.reconciledIndex["baidu:99"] != nil)
        #expect(result.changedParentPaths == [
            "/Old", "/Old/Album", "/New", "/New/Renamed",
        ])
        #expect(result.deletedStableKeys.isEmpty)
    }

    @Test("Exact legacy path becomes an alias without changing Song ID")
    func exactPathMigration() throws {
        let legacy = baiduIndexedItem(
            key: "path:/music/a.flac",
            path: "/Music/A.flac",
            parent: "/Music",
            songIDs: ["song-a"]
        )
        let current = baiduIndexedItem(
            key: "baidu:42",
            path: "/Music/A.flac",
            parent: "/Music"
        )

        let result = try BaiduSnapshotDiffPolicy.plan(
            previousIndex: [legacy.stableKey: legacy],
            currentItems: [current],
            liveDirectories: ["/Music"]
        )

        #expect(result.reconciledIndex[legacy.stableKey] == nil)
        #expect(result.reconciledIndex[current.stableKey]?.songIDs == ["song-a"])
        #expect(result.identityAliases[legacy.stableKey] == current.stableKey)
        #expect(result.changedParentPaths.isEmpty)
    }

    @Test("Unique strong fingerprint migrates a moved legacy path")
    func movedLegacyFingerprintMigration() throws {
        let legacy = baiduIndexedItem(
            key: "path:/old/a.flac",
            path: "/Old/A.flac",
            parent: "/Old",
            songIDs: ["song-a"],
            revision: "same-md5"
        )
        let current = baiduIndexedItem(
            key: "baidu:42",
            path: "/New/A.flac",
            parent: "/New",
            revision: "same-md5"
        )

        let result = try BaiduSnapshotDiffPolicy.plan(
            previousIndex: [legacy.stableKey: legacy],
            currentItems: [current],
            liveDirectories: ["/Old", "/New"]
        )

        #expect(result.reconciledIndex[current.stableKey]?.songIDs == ["song-a"])
        #expect(result.identityAliases[legacy.stableKey] == current.stableKey)
        #expect(result.changedParentPaths == ["/Old", "/New"])
    }

    @Test("Ambiguous migration retains every old row until explicit confirmation")
    func ambiguousMigrationIsConservative() throws {
        let first = baiduIndexedItem(
            key: "path:/old/a.flac",
            path: "/Old/A.flac",
            parent: "/Old",
            songIDs: ["song-a"],
            revision: "shared-md5"
        )
        let second = baiduIndexedItem(
            key: "path:/other/a.flac",
            path: "/Other/A.flac",
            parent: "/Other",
            songIDs: ["song-b"],
            revision: "shared-md5"
        )
        let current = baiduIndexedItem(
            key: "baidu:42",
            path: "/New/A.flac",
            parent: "/New",
            revision: "shared-md5"
        )

        let firstPass = try BaiduSnapshotDiffPolicy.plan(
            previousIndex: [first.stableKey: first, second.stableKey: second],
            currentItems: [current],
            liveDirectories: ["/Old", "/Other", "/New"]
        )

        #expect(firstPass.deletedStableKeys.isEmpty)
        #expect(firstPass.reconciledIndex[first.stableKey]?.songIDs == ["song-a"])
        #expect(firstPass.reconciledIndex[second.stableKey]?.songIDs == ["song-b"])
        #expect(Set(firstPass.reconciliation?.unresolvedStableKeys ?? [])
            == [first.stableKey, second.stableKey])
        #expect(firstPass.changedParentPaths == ["/New"])

        let confirmed = try BaiduSnapshotDiffPolicy.plan(
            previousIndex: firstPass.reconciledIndex,
            currentItems: [current],
            liveDirectories: ["/Old", "/Other", "/New"],
            identityAliases: firstPass.identityAliases,
            missingStableKeys: firstPass.missingStableKeys
        )
        #expect(confirmed.deletedStableKeys == [first.stableKey, second.stableKey])
    }

    @Test("A deletion needs two complete snapshots")
    func deletionNeedsConfirmation() throws {
        let previous = baiduIndexedItem(
            key: "baidu:42",
            path: "/Music/A.flac",
            parent: "/Music",
            songIDs: ["song-a"]
        )
        let first = try BaiduSnapshotDiffPolicy.plan(
            previousIndex: [previous.stableKey: previous],
            currentItems: [],
            liveDirectories: ["/Music"]
        )
        #expect(first.deletedStableKeys.isEmpty)
        #expect(first.changedParentPaths.isEmpty)
        #expect(first.reconciledIndex[previous.stableKey] != nil)
        #expect(first.reconciliation != nil)

        let second = try BaiduSnapshotDiffPolicy.plan(
            previousIndex: first.reconciledIndex,
            currentItems: [],
            liveDirectories: ["/Music"],
            missingStableKeys: first.missingStableKeys
        )
        #expect(second.deletedStableKeys == [previous.stableKey])
        #expect(second.changedParentPaths == ["/Music"])
    }

    @Test("A post-snapshot directory omission cannot prune an unconfirmed item")
    func reconciliationListingMustContainUnconfirmedItems() {
        #expect(BaiduSnapshotDirectoryReconciliationPolicy.unconfirmedMissingKeys(
            expectedKeys: ["baidu:1", "baidu:2"],
            listedKeys: ["baidu:1"],
            confirmedDeletedKeys: []
        ) == ["baidu:2"])
        #expect(BaiduSnapshotDirectoryReconciliationPolicy.unconfirmedMissingKeys(
            expectedKeys: ["baidu:1", "baidu:2"],
            listedKeys: ["baidu:1"],
            confirmedDeletedKeys: ["baidu:2"]
        ).isEmpty)
    }

    @Test("Independent cover lyrics video or CUE fingerprint changes rescan the parent")
    func sidecarFingerprintChange() throws {
        let previous = baiduIndexedItem(
            key: "baidu:42",
            path: "/Music/A.flac",
            parent: "/Music",
            songIDs: ["song-a"],
            sidecarFingerprint: "cover-v1|lyrics-v1|cue-v1"
        )
        let current = baiduIndexedItem(
            key: "baidu:42",
            path: "/Music/A.flac",
            parent: "/Music",
            sidecarFingerprint: "cover-v2|lyrics-v1|cue-v1"
        )

        let result = try BaiduSnapshotDiffPolicy.plan(
            previousIndex: [previous.stableKey: previous],
            currentItems: [current],
            liveDirectories: ["/Music"]
        )
        #expect(result.changedParentPaths == ["/Music"])
        #expect(result.reconciledIndex["baidu:42"]?.songIDs == ["song-a"])
    }

    @Test("Authoritative sidecar deletion preserves user and cache references safely")
    func sidecarReferenceReconciliation() {
        #expect(SourceSidecarReferencePolicy.reconciledReference(
            existing: "/Music/A.lrc",
            incoming: nil,
            currentParentPath: "/Music",
            authoritative: true
        ) == nil)
        #expect(SourceSidecarReferencePolicy.reconciledReference(
            existing: "song-id.lyrics.json",
            incoming: nil,
            currentParentPath: "/Music",
            authoritative: true
        ) == "song-id.lyrics.json")
        #expect(SourceSidecarReferencePolicy.reconciledReference(
            existing: "/Old/A.lrc",
            incoming: nil,
            currentParentPath: "/New",
            authoritative: true
        ) == "/Old/A.lrc")
        #expect(SourceSidecarReferencePolicy.reconciledReference(
            existing: "user-cover.jpg",
            incoming: "/Music/cover.jpg",
            currentParentPath: "/Music",
            authoritative: true,
            preserveExisting: true
        ) == "user-cover.jpg")
        #expect(SourceSidecarReferencePolicy.reconciledReference(
            existing: "/Music/A.lrc",
            incoming: "/Music/A.ttml",
            currentParentPath: "/Music",
            authoritative: true
        ) == "/Music/A.ttml")
    }

    @Test("Missing and duplicate fs_id fail closed")
    func invalidStableIdentitiesFailClosed() {
        let missing = baiduIndexedItem(
            key: "path:/music/a.flac",
            path: "/Music/A.flac",
            parent: "/Music"
        )
        let duplicateA = baiduIndexedItem(
            key: "baidu:42",
            path: "/Music/A.flac",
            parent: "/Music"
        )
        let duplicateB = baiduIndexedItem(
            key: "baidu:42",
            path: "/Music/B.flac",
            parent: "/Music"
        )

        #expect(throws: BaiduSnapshotDiffError.self) {
            try BaiduSnapshotDiffPolicy.plan(
                previousIndex: [:],
                currentItems: [missing],
                liveDirectories: ["/Music"]
            )
        }
        #expect(throws: BaiduSnapshotDiffError.self) {
            try BaiduSnapshotDiffPolicy.plan(
                previousIndex: [:],
                currentItems: [duplicateA, duplicateB],
                liveDirectories: ["/Music"]
            )
        }
    }

    @Test("Stable root relocation wins over an unrelated replacement at the old path")
    func rootRelocationAndSafeFallback() {
        let previous = SourceSyncRootIdentity(
            configuredPath: "/Music",
            currentPath: "/Music",
            stableKey: "baidu:9"
        )
        #expect(BaiduRootRelocationPolicy.decision(
            configuredPath: "/Music",
            previousIdentity: previous,
            listedStableKey: "baidu:99",
            metadataPathForPreviousStableKey: "/Archive/Music"
        ) == .use(path: "/Archive/Music", stableKey: "baidu:9"))
        #expect(BaiduRootRelocationPolicy.decision(
            configuredPath: "/Music",
            previousIdentity: previous,
            listedStableKey: "baidu:99",
            metadataPathForPreviousStableKey: nil
        ) == .requiresReselection)
        #expect(BaiduRootRelocationPolicy.decision(
            configuredPath: "/Music",
            previousIdentity: nil,
            listedStableKey: "baidu:99",
            metadataPathForPreviousStableKey: nil
        ) == .use(path: "/Music", stableKey: "baidu:99"))
    }

    @Test("Nested roots and pagination stay deterministic")
    func nestedRootsAndPagination() throws {
        #expect(BaiduSnapshotRootPolicy.normalizedRoots([
            "Music/Album", "/Music", "/Music/Album/Disc 1", "/Other/"
        ]) == ["/Music", "/Other"])
        #expect(try BaiduSnapshotPaginationPolicy.nextOffset(
            currentOffset: 0,
            decodedItemCount: 1_000,
            pageSize: 1_000
        ) == 1_000)
        #expect(try BaiduSnapshotPaginationPolicy.nextOffset(
            currentOffset: 1_000,
            decodedItemCount: 12,
            pageSize: 1_000
        ) == nil)
        #expect(throws: BaiduSnapshotPaginationError.self) {
            try BaiduSnapshotPaginationPolicy.nextOffset(
                currentOffset: 0,
                decodedItemCount: 1_001,
                pageSize: 1_000
            )
        }
    }

    @Test("Budget and foreground gates stop before excess work")
    func budgetsAndEligibility() {
        let budget = BaiduSnapshotRefreshBudget(
            maximumRequests: 2,
            maximumDirectories: 1,
            maximumDuration: 5
        )
        #expect(BaiduSnapshotBudgetPolicy.decision(
            budget: budget,
            requestCount: 1,
            directoryCount: 0,
            elapsed: 1,
            reservingRequest: true
        ) == .allow)
        #expect(BaiduSnapshotBudgetPolicy.decision(
            budget: budget,
            requestCount: 2,
            directoryCount: 0,
            elapsed: 1,
            reservingRequest: true
        ) == .stop(.requests))
        #expect(BaiduSnapshotBudgetPolicy.decision(
            budget: budget,
            requestCount: 0,
            directoryCount: 1,
            elapsed: 1,
            reservingDirectory: true
        ) == .stop(.directories))
        #expect(BaiduSnapshotBudgetPolicy.decision(
            budget: budget,
            requestCount: 0,
            directoryCount: 0,
            elapsed: 5
        ) == .stop(.duration))

        #expect(BaiduSnapshotRefreshPolicy.eligibility(
            context: .background,
            hasDeterminedNetwork: true,
            isReachable: true,
            isExpensive: false,
            isConstrained: false,
            isLowPowerModeEnabled: false,
            hasSeriousThermalPressure: false
        ) == .deferred(.backgroundTraversalDisabled))
        #expect(BaiduSnapshotRefreshPolicy.eligibility(
            context: .foregroundResume,
            hasDeterminedNetwork: true,
            isReachable: true,
            isExpensive: true,
            isConstrained: false,
            isLowPowerModeEnabled: false,
            hasSeriousThermalPressure: false
        ) == .deferred(.expensiveNetwork))
        #expect(BaiduSnapshotRefreshPolicy.eligibility(
            context: .userInitiatedForeground,
            hasDeterminedNetwork: true,
            isReachable: true,
            isExpensive: true,
            isConstrained: false,
            isLowPowerModeEnabled: false,
            hasSeriousThermalPressure: false
        ) == .allowed)
    }

    @Test("Snapshot resume survives cold launch but not a stale baseline")
    func coldResumeValidity() throws {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let progress = BaiduSnapshotResumeState(
            baselineScanEpoch: 7,
            roots: ["/Music/Album", "/Music"],
            pendingDirectories: ["/Music/Next"],
            visitedDirectories: ["/Music"],
            snapshot: ["baidu:42": baiduIndexedItem(
                key: "baidu:42",
                path: "/Music/A.flac",
                parent: "/Music"
            )],
            createdAt: createdAt
        )
        let decoded = try JSONDecoder().decode(
            BaiduSnapshotResumeState.self,
            from: JSONEncoder().encode(progress)
        )
        #expect(decoded == progress)
        #expect(decoded.roots == ["/Music"])
        #expect(decoded.isUsable(
            baselineScanEpoch: 7,
            roots: ["/Music", "/Music/Album"],
            now: createdAt.addingTimeInterval(60 * 60)
        ))
        #expect(!decoded.isUsable(
            baselineScanEpoch: 8,
            roots: ["/Music"],
            now: createdAt.addingTimeInterval(60 * 60)
        ))
        #expect(!decoded.isUsable(
            baselineScanEpoch: 7,
            roots: ["/Music"],
            now: createdAt.addingTimeInterval(25 * 60 * 60)
        ))
    }

    @Test("Account scope fences identity reuse and other provider keys stay unchanged")
    func accountAndProviderIsolation() throws {
        let rawProviderKeys = [
            "opaque-google-file-id",
            "opaque-onedrive-item-id",
            "opaque-dropbox-rev",
            "opaque-aliyun-file-id",
            "opaque-drime-file-id",
            "opaque-115-file-id",
            "opaque-123-file-id",
        ]
        let rawIndex = Dictionary(uniqueKeysWithValues: rawProviderKeys.map { key in
            (key, baiduIndexedItem(
                key: key,
                path: key,
                parent: "opaque-parent",
                songIDs: ["song-\(key)"]
            ))
        })
        let rawCursors = Dictionary(uniqueKeysWithValues: rawProviderKeys.map {
            ($0, "cursor-v1")
        })
        let state = SourceSyncState(
            sourceID: "source",
            scopeFingerprint: "account-a",
            identityScopeFingerprint: "identity-account-a",
            cursors: rawCursors,
            index: rawIndex
        )

        #expect(SourceSyncIdentityReusePolicy.reusableIndex(
            from: state,
            sourceID: "source",
            scopeFingerprint: "account-b"
        ).isEmpty)
        #expect(SourceSyncIdentityReusePolicy.reusableIndex(
            from: state,
            sourceID: "source",
            scopeFingerprint: "account-a"
        )["opaque-google-file-id"]?.songIDs == ["song-opaque-google-file-id"])
        #expect(state.matchesIdentityScope(
            sourceID: "source",
            identityScopeFingerprint: "identity-account-a"
        ))
        #expect(!state.matchesIdentityScope(
            sourceID: "source",
            identityScopeFingerprint: "identity-account-b"
        ))

        let decoded = try JSONDecoder().decode(
            SourceSyncState.self,
            from: JSONEncoder().encode(state)
        )
        #expect(decoded.schemaVersion == 1)
        #expect(decoded.cursors == rawCursors)
        #expect(Set(decoded.index.keys) == Set(rawProviderKeys))
        for key in rawProviderKeys {
            #expect(SourceSongIdentityMaterialPolicy.itemIdentity(
                path: "/Existing/\(key).flac",
                providerID: key,
                usesStableProviderIdentity: false
            ) == "/Existing/\(key).flac")
        }
        #expect(SourceSongIdentityMaterialPolicy.itemIdentity(
            path: "/Baidu/A.flac",
            providerID: "baidu:42",
            usesStableProviderIdentity: true
        ) == "provider:baidu:42")
    }

    @Test("Stable moves migrate only a strongly matching local cache")
    func stableMoveCacheTransition() {
        #expect(SourceStableCacheTransitionPolicy.decision(
            previousPath: "/Old/A.flac",
            currentPath: "/New/A.flac",
            previousRevision: "ABC123",
            currentRevision: "abc123",
            previousSize: 42,
            currentSize: 42
        ) == .migrate)
        #expect(SourceStableCacheTransitionPolicy.decision(
            previousPath: "/Old/A.flac",
            currentPath: "/New/A.flac",
            previousRevision: "old-md5",
            currentRevision: "new-md5",
            previousSize: 42,
            currentSize: 42
        ) == .invalidate)
        #expect(SourceStableCacheTransitionPolicy.decision(
            previousPath: "/Old/A.flac",
            currentPath: "/New/A.flac",
            previousRevision: nil,
            currentRevision: nil,
            previousSize: 42,
            currentSize: 42
        ) == .invalidate)
        #expect(SourceStableCacheTransitionPolicy.decision(
            previousPath: "/Music/A.flac",
            currentPath: "/Music/A.flac",
            previousRevision: "old-md5",
            currentRevision: "new-md5",
            previousSize: 42,
            currentSize: 42
        ) == .none)
    }

    @Test("Completed local cache follows a stable move and partial bytes are dropped")
    func stableMoveCacheFileMigration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-stable-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldURL = directory.appendingPathComponent("old.flac")
        let newURL = directory.appendingPathComponent("nested/new.flac")
        let partialURL = URL(fileURLWithPath: oldURL.path + ".partial")
        let staleDestinationPartial = URL(fileURLWithPath: newURL.path + ".offline")
        try FileManager.default.createDirectory(
            at: newURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3, 4]).write(to: oldURL)
        try Data([9]).write(to: partialURL)
        try Data([8]).write(to: staleDestinationPartial)

        let byteCount = try SourceStableCacheFileMigration.migrateCompletedFile(
            from: oldURL,
            to: newURL
        )

        #expect(byteCount == 4)
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
        #expect(!FileManager.default.fileExists(atPath: partialURL.path))
        #expect(!FileManager.default.fileExists(atPath: staleDestinationPartial.path))
        #expect(try Data(contentsOf: newURL) == Data([1, 2, 3, 4]))
        #expect(try SourceStableCacheFileMigration.migrateCompletedFile(
            from: oldURL,
            to: newURL
        ) == 4)
    }
}

private func baiduIndexedItem(
    key: String,
    path: String,
    parent: String,
    songIDs: [String] = [],
    revision: String? = "md5",
    sidecarFingerprint: String? = nil
) -> SourceSyncIndexedItem {
    SourceSyncIndexedItem(
        stableKey: key,
        path: path,
        displayName: (path as NSString).lastPathComponent,
        parentPath: parent,
        isDirectory: false,
        songIDs: songIDs,
        size: 42,
        modifiedDate: nil,
        revision: revision,
        sidecarFingerprint: sidecarFingerprint,
        seenEpoch: 3
    )
}
