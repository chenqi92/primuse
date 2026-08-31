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

    @Test func successfulNoChangeScanNotifiesLifecycleExactlyOnce() {
        let completions = [SourceScanLifecycleCompletion.committedNoChanges]
        let notificationCount = completions.count {
            SourceScanLifecyclePolicy.shouldNotifySuccessfulScan(for: $0)
        }

        #expect(notificationCount == 1)
    }

    @Test func unsuccessfulOrUncommittedScansDoNotNotifyLifecycle() {
        for completion in [
            SourceScanLifecycleCompletion.failed,
            .cancelled,
            .uncommitted,
        ] {
            #expect(!SourceScanLifecyclePolicy.shouldNotifySuccessfulScan(
                for: completion
            ))
        }
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

    @Test func serverAndUPnPTopologyRequireOneLegacyRebuild() {
        let legacyState = SourceSyncState(
            sourceID: "source",
            scopeFingerprint: "scope"
        )
        let hierarchyRoot = SourceSyncIndexedItem(
            stableKey: "hierarchy-root:server-root:abc",
            path: "server-root:abc",
            displayName: "Music",
            parentPath: nil,
            isDirectory: true,
            size: 0,
            modifiedDate: nil,
            revision: nil
        )
        let currentState = SourceSyncState(
            sourceID: "source",
            scopeFingerprint: "scope",
            index: [hierarchyRoot.stableKey: hierarchyRoot]
        )

        for sourceType in [MusicSourceType.emby, .plex, .navidrome, .fnMusic, .upnp] {
            #expect(SourceSyncFolderTopologyPolicy.requiresRebuild(
                sourceType: sourceType,
                state: nil
            ))
            #expect(SourceSyncFolderTopologyPolicy.requiresRebuild(
                sourceType: sourceType,
                state: legacyState
            ))
            #expect(!SourceSyncFolderTopologyPolicy.requiresRebuild(
                sourceType: sourceType,
                state: currentState
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

    @Test("Automatic refresh requires a native changes feed")
    func automaticRefreshRequiresNativeChangesFeed() {
        #expect(SourcePeriodicSyncPolicy.supportsAutomaticRefresh(.dropbox))
        #expect(SourcePeriodicSyncPolicy.supportsAutomaticRefresh(.googleDrive))
        #expect(SourcePeriodicSyncPolicy.supportsAutomaticRefresh(.oneDrive))
        #expect(!SourcePeriodicSyncPolicy.supportsAutomaticRefresh(.baiduPan))
        #expect(!SourcePeriodicSyncPolicy.supportsAutomaticRefresh(.synology))
        #expect(!SourcePeriodicSyncPolicy.supportsAutomaticRefresh(.local))
    }
}

@Suite("Automatic artist artwork catalog")
struct SourceArtistArtworkCatalogTests {
    @Test("Nearest exact same-name image wins for every credited artist")
    func nearestAncestorAndContributorResolution() throws {
        let index = makeIndex([
            item(path: "/Music/Adele", name: "Adele", parent: "/Music", directory: true),
            item(path: "/Music/Adele/25", name: "25", parent: "/Music/Adele", directory: true),
            item(path: "/Music/Adele/Adele.jpg", name: "Adele.jpg", parent: "/Music/Adele", revision: "artist-v1"),
            item(path: "/Music/Adele/Guest.png", name: "Guest.png", parent: "/Music/Adele", revision: "guest-v1"),
            item(path: "/Music/Adele/25/Adele.png", name: "Adele.png", parent: "/Music/Adele/25", revision: "artist-v2"),
            item(path: "/Music/Adele/25/track.flac", name: "track.flac", parent: "/Music/Adele/25", songIDs: ["song"]),
        ])
        let catalog = SourceArtistArtworkCatalog(sourceID: "source", index: index)
        let persisted = try JSONDecoder().decode(
            SourceArtistArtworkCatalog.self,
            from: JSONEncoder().encode(catalog)
        )
        let encoded = try #require(catalog.automaticReference(
            forSongID: "song",
            artistNames: ["Adèle", "Guest"]
        ))
        let resolved = try #require(AutomaticArtistArtworkReference.resolve(encoded))

        #expect(persisted == catalog)
        #expect(resolved.entry(forArtistName: "Adele")?.reference == "/Music/Adele/25/Adele.png")
        #expect(resolved.entry(forArtistName: "Guest")?.reference == "/Music/Adele/Guest.png")
        #expect(resolved.entry(forArtistName: "Adele")?.cacheDiscriminator.contains("artist-v2") == true)
    }

    @Test("Generic, song-cover, hidden, and sibling images are rejected")
    func rejectsLikelyMismatches() {
        let index = makeIndex([
            item(path: "/Music/Artist", name: "Artist", parent: "/Music", directory: true),
            item(path: "/Music/Other", name: "Other", parent: "/Music", directory: true),
            item(path: "/Music/Artist/Artist.flac", name: "Artist.flac", parent: "/Music/Artist", songIDs: ["song"]),
            item(path: "/Music/Artist/Artist.jpg", name: "Artist.jpg", parent: "/Music/Artist"),
            item(path: "/Music/Artist/cover.png", name: "cover.png", parent: "/Music/Artist"),
            item(path: "/Music/Artist/.Artist.png", name: ".Artist.png", parent: "/Music/Artist"),
            item(path: "/Music/Other/Artist.png", name: "Artist.png", parent: "/Music/Other"),
        ])
        let catalog = SourceArtistArtworkCatalog(sourceID: "source", index: index)

        #expect(catalog.automaticReference(
            forSongID: "song",
            artistNames: ["Artist"]
        ) == nil)
    }

    @Test("Candidate revision changes the cache identity without changing its source path")
    func revisionInvalidatesCacheIdentity() throws {
        func catalog(revision: String) -> SourceArtistArtworkCatalog {
            SourceArtistArtworkCatalog(sourceID: "source", index: makeIndex([
                item(path: "/Artist", name: "Artist", parent: "/", directory: true),
                item(path: "/Artist/Artist.jpg", name: "Artist.jpg", parent: "/Artist", revision: revision),
                item(path: "/Artist/song.flac", name: "song.flac", parent: "/Artist", songIDs: ["song"]),
            ]))
        }
        let first = try #require(AutomaticArtistArtworkReference.resolve(
            catalog(revision: "v1").automaticReference(
                forSongID: "song",
                artistNames: ["Artist"]
            )
        )?.entry(forArtistName: "Artist"))
        let second = try #require(AutomaticArtistArtworkReference.resolve(
            catalog(revision: "v2").automaticReference(
                forSongID: "song",
                artistNames: ["Artist"]
            )
        )?.entry(forArtistName: "Artist"))

        #expect(first.reference == second.reference)
        #expect(first.cacheDiscriminator != second.cacheDiscriminator)
    }

    private func makeIndex(
        _ items: [SourceSyncIndexedItem]
    ) -> [String: SourceSyncIndexedItem] {
        Dictionary(uniqueKeysWithValues: items.map { ($0.stableKey, $0) })
    }

    private func item(
        path: String,
        name: String,
        parent: String,
        directory: Bool = false,
        songIDs: [String] = [],
        revision: String? = nil
    ) -> SourceSyncIndexedItem {
        SourceSyncIndexedItem(
            stableKey: "path:\(path.lowercased())",
            path: path,
            displayName: name,
            parentPath: parent,
            isDirectory: directory,
            songIDs: songIDs,
            size: directory ? 0 : 123,
            modifiedDate: nil,
            revision: revision
        )
    }
}

@Suite("Local reference refresh policy")
struct LocalReferenceRefreshPolicyTests {
    @Test("Only active device-local bookmark sources are monitored")
    func monitoredSources() {
        let active = MusicSource(id: "active", name: "Active", type: .local)
        let copied = MusicSource(id: "copied", name: "Copied", type: .local)
        let disabled = MusicSource(
            id: "disabled",
            name: "Disabled",
            type: .local,
            isEnabled: false
        )
        let deleted = MusicSource(
            id: "deleted",
            name: "Deleted",
            type: .local,
            isDeleted: true,
            deletedAt: Date()
        )
        let remote = MusicSource(id: "remote", name: "Remote", type: .webdav)

        #expect(LocalReferenceRefreshPolicy.monitoredSourceIDs(
            in: [active, copied, disabled, deleted, remote],
            bookmarkedSourceIDs: ["active", "disabled", "deleted", "remote"]
        ) == ["active"])
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
        #expect(SourceSyncState.currentSchemaVersion == 2)
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

    @Test("A unique in-place fs_id replacement keeps the existing Song ID")
    func exactPathStrongIdentityReplacement() throws {
        let previous = baiduIndexedItem(
            key: "baidu:42",
            path: "/Music/A.flac",
            parent: "/Music",
            songIDs: ["song-a"]
        )
        let replacement = baiduIndexedItem(
            key: "baidu:99",
            path: "/Music/A.flac",
            parent: "/Music"
        )

        let result = try BaiduSnapshotDiffPolicy.plan(
            previousIndex: [previous.stableKey: previous],
            currentItems: [replacement],
            liveDirectories: ["/Music"]
        )

        #expect(result.reconciledIndex[previous.stableKey] == nil)
        #expect(result.reconciledIndex[replacement.stableKey]?.songIDs == ["song-a"])
        #expect(result.identityAliases[previous.stableKey] == replacement.stableKey)
        #expect(result.changedParentPaths == ["/Music"])
        #expect(result.deletedStableKeys.isEmpty)
        #expect(result.reconciliation == nil)
    }

    @Test("In-place identity replacement stays fail-closed when either side is ambiguous")
    func ambiguousExactPathStrongIdentityReplacement() throws {
        let previous = baiduIndexedItem(
            key: "baidu:42",
            path: "/Music/A.flac",
            parent: "/Music",
            songIDs: ["song-a"]
        )
        let first = baiduIndexedItem(
            key: "baidu:98",
            path: "/Music/A.flac",
            parent: "/Music"
        )
        let second = baiduIndexedItem(
            key: "baidu:99",
            path: "/Music/A.flac",
            parent: "/Music"
        )

        let result = try BaiduSnapshotDiffPolicy.plan(
            previousIndex: [previous.stableKey: previous],
            currentItems: [first, second],
            liveDirectories: ["/Music"]
        )

        #expect(result.reconciledIndex[first.stableKey]?.songIDs.isEmpty == true)
        #expect(result.reconciledIndex[second.stableKey]?.songIDs.isEmpty == true)
        #expect(result.reconciledIndex[previous.stableKey]?.songIDs == ["song-a"])
        #expect(result.identityAliases[previous.stableKey] == nil)
        #expect(result.reconciliation?.unresolvedStableKeys == [previous.stableKey])
    }

    @Test("A still-live old fs_id cannot be reinterpreted as a replacement")
    func liveStrongIdentityDoesNotMigrateByPath() throws {
        let previous = baiduIndexedItem(
            key: "baidu:42",
            path: "/Music/A.flac",
            parent: "/Music",
            songIDs: ["song-a"]
        )
        var stillLive = previous
        stillLive.songIDs = []
        let additional = baiduIndexedItem(
            key: "baidu:99",
            path: "/Music/A.flac",
            parent: "/Music"
        )

        let result = try BaiduSnapshotDiffPolicy.plan(
            previousIndex: [previous.stableKey: previous],
            currentItems: [stillLive, additional],
            liveDirectories: ["/Music"]
        )

        #expect(result.reconciledIndex[previous.stableKey]?.songIDs == ["song-a"])
        #expect(result.reconciledIndex[additional.stableKey]?.songIDs.isEmpty == true)
        #expect(result.identityAliases[previous.stableKey] == nil)
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

    @Test("Snapshot progress includes files, directories, and the persisted baseline")
    func snapshotProgressUsesTotalWork() {
        let previousIndex = [
            "baidu:1": baiduIndexedItem(
                key: "baidu:1",
                path: "/Music/A.flac",
                parent: "/Music"
            ),
            "baidu:2": baiduIndexedItem(
                key: "baidu:2",
                path: "/Music/B.flac",
                parent: "/Music"
            ),
        ]
        let estimate = BaiduSnapshotProgressPolicy.estimatedTotalCount(
            previousIndex: previousIndex,
            roots: ["/Music"]
        )
        var progress = BaiduSnapshotResumeState(
            baselineScanEpoch: 7,
            roots: ["/Music"],
            pendingDirectories: ["/Music/Album"],
            visitedDirectories: ["/Music"],
            snapshot: [
                "baidu:10": baiduIndexedItem(
                    key: "baidu:10",
                    path: "/Music/New.flac",
                    parent: "/Music"
                )
            ],
            estimatedTotalCount: estimate
        )

        #expect(estimate == 3)
        #expect(BaiduSnapshotProgressPolicy.progress(for: progress) == .init(
            completedCount: 2,
            totalCount: 3
        ))

        progress.pendingDirectories = []
        #expect(BaiduSnapshotProgressPolicy.progress(for: progress) == .init(
            completedCount: 3,
            totalCount: 3
        ))
    }

    @Test("Snapshot progress expands when newly discovered work exceeds the baseline")
    func snapshotProgressExpandsForNewWork() {
        let progress = BaiduSnapshotResumeState(
            baselineScanEpoch: 1,
            roots: ["/Music"],
            pendingDirectories: ["/Music/A", "/Music/B"],
            visitedDirectories: ["/Music"],
            snapshot: [
                "baidu:1": baiduIndexedItem(
                    key: "baidu:1",
                    path: "/Music/New.flac",
                    parent: "/Music"
                )
            ],
            estimatedTotalCount: 1
        )

        #expect(BaiduSnapshotProgressPolicy.progress(for: progress) == .init(
            completedCount: 2,
            totalCount: 4
        ))
    }

    @Test("A missing snapshot child does not restart the selected roots")
    func missingSnapshotDirectoryDisposition() {
        #expect(BaiduSnapshotMissingDirectoryPolicy.disposition(
            missingDirectory: "/Music/Deleted Album",
            roots: ["/Music"]
        ) == .discardStaleDescendant)
        #expect(BaiduSnapshotMissingDirectoryPolicy.disposition(
            missingDirectory: "/Music",
            roots: ["/Music", "/Music/Album"]
        ) == .requiresRootReselection)
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
        #expect(decoded.schemaVersion == SourceSyncState.currentSchemaVersion)
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

@Suite("Directory sidecar indexing")
struct SidecarDirectoryIndexTests {
    @Test("Lookup priority and listing order match the legacy resolver")
    func lookupPriority() {
        let items = [
            sidecarItem("Track.FLAC"),
            sidecarItem("track-cover.jpg"),
            sidecarItem("TRACK.JPG"),
            sidecarItem("folder.png"),
            sidecarItem("cover.webp"),
            sidecarItem("track.TTML"),
            sidecarItem("track.mov"),
            sidecarItem("track.mp4"),
            sidecarItem("orphan.m4v"),
        ]
        let index = SidecarDirectoryIndex(items)

        #expect(index.containsAudioOrStream(basename: "TRACK"))
        #expect(!index.containsAudioOrStream(basename: "orphan"))
        #expect(index.sameNameCover(basename: "track")?.sidecarName == "track-cover.jpg")
        #expect(index.folderCover()?.sidecarName == "cover.webp")
        #expect(index.sameNameLyrics(basename: "track")?.sidecarName == "track.TTML")
        #expect(index.sameNameMusicVideo(basename: "track")?.sidecarName == "track.mp4")
    }

    @Test("Animated artwork extensions are indexed case-insensitively as source sidecars")
    func animatedArtworkLookup() {
        let index = SidecarDirectoryIndex([
            sidecarItem("TRACK.GIF"),
            sidecarItem("folder.GiF"),
        ])
        let apngIndex = SidecarDirectoryIndex([
            sidecarItem("Track.ApNg"),
        ])

        #expect(PrimuseConstants.supportedCoverExtensions.contains("gif"))
        #expect(PrimuseConstants.supportedCoverExtensions.contains("apng"))
        #expect(index.sameNameCover(basename: "track")?.sidecarName == "TRACK.GIF")
        #expect(index.folderCover()?.sidecarName == "folder.GiF")
        #expect(apngIndex.sameNameCover(basename: "track")?.sidecarName == "Track.ApNg")
    }

    @Test("Non-CUE fingerprints retain the committed component format")
    func legacyFingerprintFormat() {
        let cover = sidecarItem(
            "Track.jpg",
            size: 42,
            revision: "cover-v1",
            providerID: "provider-cover"
        )
        let index = SidecarDirectoryIndex([cover])
        let expected = [
            "provider-cover",
            cover.sidecarPath,
            "cover-v1",
            "42",
            "",
        ].joined(separator: "\u{1F}")

        #expect(index.snapshotFingerprint(selectedPaths: [cover.sidecarPath]) == expected)
        #expect(index.snapshotFingerprint(selectedPaths: ["/external/Track.jpg"])
            == "missing\u{1F}/external/Track.jpg")
    }

    @Test("CUE dependencies are stable and invalidate every indexed song")
    func cueFingerprint() {
        let cover = sidecarItem("cover.jpg", revision: "cover-v1")
        let cueV1 = sidecarItem("album.cue", revision: "cue-v1")
        let cueV2 = sidecarItem("album.cue", revision: "cue-v2")
        let first = SidecarDirectoryIndex([cover, cueV1])
        let reordered = SidecarDirectoryIndex([cueV1, cover])
        let changed = SidecarDirectoryIndex([cover, cueV2])

        let firstFingerprint = first.snapshotFingerprint(selectedPaths: [cover.sidecarPath])
        #expect(firstFingerprint == reordered.snapshotFingerprint(
            selectedPaths: [cover.sidecarPath]
        ))
        #expect(firstFingerprint != changed.snapshotFingerprint(
            selectedPaths: [cover.sidecarPath]
        ))
        #expect(firstFingerprint?.contains("cue-sha256-v2") == true)
    }

    @Test("A large directory resolves all songs through one reusable index")
    func largeDirectoryLookup() {
        let songCount = 5_000
        var items: [SidecarIndexItem] = []
        items.reserveCapacity(songCount * 2)
        for index in 0..<songCount {
            items.append(sidecarItem("track-\(index).flac"))
            items.append(sidecarItem("track-\(index).lrc"))
        }

        let directoryIndex = SidecarDirectoryIndex(items)
        let resolvedCount = (0..<songCount).reduce(into: 0) { count, index in
            if directoryIndex.sameNameLyrics(basename: "track-\(index)") != nil {
                count += 1
            }
        }

        #expect(directoryIndex.itemCount == songCount * 2)
        #expect(resolvedCount == songCount)
    }
}

@Suite("Baidu foreground execution policy")
struct BaiduSnapshotExecutionPolicyTests {
    @Test("Automatic foreground resume is one short utility slice")
    func automaticResumeBudget() {
        let automatic = BaiduSnapshotExecutionPolicy.refreshBudget(for: .foregroundResume)
        let userInitiated = BaiduSnapshotExecutionPolicy.refreshBudget(
            for: .userInitiatedForeground
        )

        #expect(automatic.maximumRequests == 64)
        #expect(automatic.maximumDirectories == 32)
        #expect(automatic.maximumDuration == 8)
        #expect(userInitiated == BaiduSnapshotRefreshBudget())
        #expect(!BaiduSnapshotExecutionPolicy.shouldContinueImmediately(
            context: .foregroundResume
        ))
        #expect(BaiduSnapshotExecutionPolicy.shouldContinueImmediately(
            context: .userInitiatedForeground
        ))
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

private struct SidecarIndexItem: SidecarDirectoryItem {
    var sidecarName: String
    var sidecarPath: String
    var sidecarIsDirectory: Bool
    var sidecarSize: Int64
    var sidecarModifiedDate: Date?
    var sidecarRevision: String?
    var sidecarProviderID: String?
}

private func sidecarItem(
    _ name: String,
    size: Int64 = 0,
    revision: String? = nil,
    providerID: String? = nil
) -> SidecarIndexItem {
    SidecarIndexItem(
        sidecarName: name,
        sidecarPath: "/Music/\(name)",
        sidecarIsDirectory: false,
        sidecarSize: size,
        sidecarModifiedDate: nil,
        sidecarRevision: revision,
        sidecarProviderID: providerID
    )
}
