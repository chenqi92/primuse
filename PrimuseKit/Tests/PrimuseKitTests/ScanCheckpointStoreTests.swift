import Foundation
import Dispatch
import Testing
@testable import PrimuseKit

@Suite("Scan checkpoint preparation")
struct ScanCheckpointPreparationTests {
    @Test("Initial intent contains a recoverable queue before progress")
    func initialIntentBeforeProgress() {
        let checkpoint = ScanCheckpointPreparationPolicy.preparingCheckpoint(
            existing: nil,
            directories: ["/Music"],
            mode: .automatic,
            now: Date(timeIntervalSince1970: 100)
        )

        #expect(checkpoint.phase == .initial)
        #expect(checkpoint.intent == .automatic)
        #expect(checkpoint.songs.isEmpty)
        #expect(checkpoint.directoryState?.pendingDirectories == ["/Music"])
        #expect(checkpoint.isUsable)
        #expect(checkpoint.permitsStatefulRefresh)
    }

    @Test("Preparing never regresses an existing progress checkpoint")
    func existingProgressWins() {
        let progress = makeCheckpoint(
            phase: .scanning,
            intent: .fullScan,
            directories: ["/Music"],
            totalCount: 20,
            currentFile: "album/track.flac",
            pendingDirectories: ["/Music/next"],
            baselineCursors: ["/Music": "cursor-1"]
        )

        let prepared = ScanCheckpointPreparationPolicy.preparingCheckpoint(
            existing: progress,
            directories: ["/Music"],
            mode: .automatic,
            now: Date(timeIntervalSince1970: 999)
        )

        #expect(prepared == progress)
    }

    @Test("Deep and quick intents keep their cold-launch semantics")
    func scanIntentSemantics() {
        let deep = ScanCheckpointPreparationPolicy.preparingCheckpoint(
            existing: nil,
            directories: ["/"],
            mode: .deep
        )
        let quick = ScanCheckpointPreparationPolicy.preparingCheckpoint(
            existing: nil,
            directories: ["/"],
            mode: .quick
        )

        #expect(deep.intent == .fullScan)
        #expect(!deep.permitsStatefulRefresh)
        #expect(quick.intent == .quickOnly)
        #expect(quick.permitsStatefulRefresh)
        #expect(quick.isQuickOnly)
    }

    @Test("Promotion to a full walk preserves accumulated state")
    func promotionPreservesState() {
        let initial = makeCheckpoint(
            phase: .initial,
            intent: .automatic,
            directories: ["/Music"],
            totalCount: 7,
            currentFile: "preflight",
            pendingDirectories: ["/Music/A", "/Music/B"],
            baselineCursors: ["/Music": "cursor"]
        )

        let promoted = initial.promotedToFullScan(at: Date(timeIntervalSince1970: 500))

        #expect(promoted.intent == .fullScan)
        #expect(promoted.phase == initial.phase)
        #expect(promoted.directories == initial.directories)
        #expect(promoted.totalCount == initial.totalCount)
        #expect(promoted.currentFile == initial.currentFile)
        #expect(promoted.directoryState == initial.directoryState)
        #expect(promoted.baselineCursors == initial.baselineCursors)
    }

    @Test("Disabled sources are retained but never auto-resumed")
    func sourceLifecycleBoundaries() {
        #expect(ScanCheckpointSourcePolicy.disposition(
            sourceExists: true,
            isEnabled: true,
            isDeleted: false
        ) == .resume)
        #expect(ScanCheckpointSourcePolicy.disposition(
            sourceExists: true,
            isEnabled: false,
            isDeleted: false
        ) == .retain)
        #expect(ScanCheckpointSourcePolicy.disposition(
            sourceExists: true,
            isEnabled: true,
            isDeleted: true
        ) == .discard)
        #expect(ScanCheckpointSourcePolicy.disposition(
            sourceExists: false,
            isEnabled: false,
            isDeleted: false
        ) == .discard)
    }

    @Test("Automatic resume failures back off durably and successful progress clears them")
    func automaticResumeFailureBackoff() {
        let start = Date(timeIntervalSince1970: 10_000)
        let initial = makeCheckpoint(
            phase: .initial,
            intent: .automatic,
            directories: ["/Music"],
            pendingDirectories: ["/Music"]
        )

        let first = initial.recordingAutomaticResumeFailure(at: start)
        #expect(first.automaticResumeFailureCount == 1)
        #expect(!first.canAutomaticallyResume(at: start.addingTimeInterval(299)))
        #expect(first.canAutomaticallyResume(at: start.addingTimeInterval(300)))

        let second = first.recordingAutomaticResumeFailure(at: start)
        #expect(second.automaticResumeFailureCount == 2)
        #expect(!second.canAutomaticallyResume(at: start.addingTimeInterval(599)))
        #expect(second.canAutomaticallyResume(at: start.addingTimeInterval(600)))

        let cleared = second.clearingAutomaticResumeFailure()
        #expect(cleared.automaticResumeFailureCount == 0)
        #expect(cleared.automaticResumeAfter == nil)
        #expect(cleared.canAutomaticallyResume(at: start))
    }

    @Test("A cloud account switch never resumes the previous scope")
    func scopeMismatchRestartsCheckpoint() {
        let previous = makeCheckpoint(
            phase: .scanning,
            intent: .automatic,
            directories: ["/Music"],
            pendingDirectories: ["/Music/Album"],
            scopeFingerprint: "account-a"
        )

        let restarted = ScanCheckpointPreparationPolicy.preparingCheckpoint(
            existing: previous,
            directories: ["/Music"],
            mode: .automatic,
            scopeFingerprint: "account-b",
            now: Date(timeIntervalSince1970: 999)
        )

        #expect(restarted != previous)
        #expect(restarted.phase == .initial)
        #expect(restarted.scopeFingerprint == "account-b")
        #expect(restarted.directoryState?.pendingDirectories == ["/Music"])
        #expect(restarted.baiduSnapshotState == nil)
    }

    @Test("Baidu snapshot progress remains quick-resumable across encoding")
    func baiduSnapshotProgressRoundTrip() throws {
        let snapshot = BaiduSnapshotResumeState(
            baselineScanEpoch: 4,
            roots: ["/Music"],
            pendingDirectories: ["/Music/B"],
            visitedDirectories: ["/Music"],
            estimatedTotalCount: 12
        )
        let checkpoint = makeCheckpoint(
            phase: .scanning,
            intent: .automatic,
            directories: ["/Music"],
            pendingDirectories: [],
            scopeFingerprint: "account-a",
            baiduSnapshotState: snapshot,
            baiduTelemetry: SourceSyncTelemetry(
                requestCount: 4,
                directoryCount: 1,
                elapsed: 2,
                resumed: true
            )
        )

        let decoded = try JSONDecoder().decode(
            ScanCheckpoint.self,
            from: JSONEncoder().encode(checkpoint)
        )

        #expect(decoded == checkpoint)
        #expect(decoded.permitsStatefulRefresh)
        #expect(decoded.baiduSnapshotState == snapshot)
        #expect(decoded.baiduSnapshotState?.estimatedTotalCount == 12)
        #expect(decoded.baiduTelemetry?.requestCount == 4)
    }

    @Test("Subsonic page progress survives a cold restart without becoming authoritative")
    func subsonicCatalogProgressRoundTrip() throws {
        let catalogState = SubsonicCatalogResumeState(
            stageSessionID: "session-a",
            catalogRevision: "2026-08-31T12:00:00Z|800",
            nextOffset: 500,
            completedPageCount: 1,
            stagedSongCount: 2,
            stagedItemCount: 2,
            firstPageItemIDs: ["one", "two"],
            seenItemIDs: []
        )
        let checkpoint = makeCheckpoint(
            phase: .scanning,
            intent: .automatic,
            directories: ["/"],
            pendingDirectories: [],
            scopeFingerprint: "navidrome-account",
            subsonicCatalogState: catalogState
        )

        let decoded = try JSONDecoder().decode(
            ScanCheckpoint.self,
            from: JSONEncoder().encode(checkpoint)
        )

        #expect(decoded == checkpoint)
        #expect(decoded.subsonicCatalogState == catalogState)
        #expect(decoded.songs.isEmpty)
        #expect(decoded.subsonicCatalogState?.isUsable(stagedSongCount: 2) == true)
        #expect(decoded.promotedToFullScan().subsonicCatalogState == catalogState)
    }

    @Test("A stale snapshot directory restarts from roots without becoming a deep scan")
    func staleBaiduDirectoryRestartsSnapshot() {
        let progress = BaiduSnapshotResumeState(
            baselineScanEpoch: 3,
            roots: ["/Music"],
            pendingDirectories: ["/Music/Old"]
        )
        let checkpoint = makeCheckpoint(
            phase: .scanning,
            intent: .automatic,
            baiduSnapshotState: progress
        )
        let telemetry = SourceSyncTelemetry(requestCount: 4, directoryCount: 2)

        let restarted = checkpoint.restartingSnapshotTraversal(
            telemetry: telemetry,
            at: Date(timeIntervalSince1970: 456)
        )

        #expect(restarted.phase == .initial)
        #expect(restarted.intent == .automatic)
        #expect(restarted.baiduSnapshotState == nil)
        #expect(restarted.baiduTelemetry == telemetry)
        #expect(restarted.permitsStatefulRefresh)
    }
}

@Suite("Scan checkpoint file store")
struct ScanCheckpointFileStoreTests {
    @Test("Cancellation before progress survives a cold process restart")
    func initialCheckpointSurvivesColdRestart() async throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let checkpoint = makeCheckpoint(
            phase: .initial,
            intent: .fullScan,
            directories: ["/Delayed-WebDAV"],
            pendingDirectories: ["/Delayed-WebDAV"]
        )
        let store = ScanCheckpointFileStore(
            checkpointURL: urls.checkpoint,
            backupURL: urls.backup
        )

        try await store.upsert(checkpoint, for: "webdav")
        let sameProcess = await store.snapshot()
        let coldStore = ScanCheckpointFileStore(
            checkpointURL: urls.checkpoint,
            backupURL: urls.backup
        )
        let coldProcess = await coldStore.snapshot()

        #expect(sameProcess["webdav"] == checkpoint)
        #expect(coldProcess["webdav"] == checkpoint)
    }

    @Test("Normal completion removes the durable checkpoint")
    func normalCompletionClearsCheckpoint() async throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let store = ScanCheckpointFileStore(
            checkpointURL: urls.checkpoint,
            backupURL: urls.backup
        )
        try await store.upsert(makeCheckpoint(), for: "source")

        try await store.remove(sourceID: "source")
        let coldSnapshot = ScanCheckpointFileStore.load(
            from: urls.checkpoint,
            backupURL: urls.backup
        )

        #expect(coldSnapshot.isEmpty)
    }

    @Test("Concurrent source updates do not overwrite each other")
    func concurrentSourcesAreMerged() async throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let store = ScanCheckpointFileStore(
            checkpointURL: urls.checkpoint,
            backupURL: urls.backup
        )
        let first = makeCheckpoint(directories: ["/A"], pendingDirectories: ["/A"])
        let second = makeCheckpoint(directories: ["/B"], pendingDirectories: ["/B"])

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await store.upsert(first, for: "source-a") }
            group.addTask { try await store.upsert(second, for: "source-b") }
            try await group.waitForAll()
        }
        let persisted = ScanCheckpointFileStore.load(
            from: urls.checkpoint,
            backupURL: urls.backup
        )

        #expect(persisted["source-a"] == first)
        #expect(persisted["source-b"] == second)
    }

    @Test("A malformed source entry does not erase valid sources")
    func malformedEntryIsIsolated() throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let valid = makeCheckpoint(directories: ["/Valid"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validData = try encoder.encode(["valid": valid])
        var object = try #require(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        object["broken"] = ["schemaVersion": "not-an-integer"]
        try JSONSerialization.data(withJSONObject: object).write(to: urls.checkpoint)

        let loaded = ScanCheckpointFileStore.load(
            from: urls.checkpoint,
            backupURL: urls.backup
        )

        #expect(loaded == ["valid": valid])
    }

    @Test("Empty and unsupported-version snapshots fail closed")
    func emptyAndOldSnapshotsFailClosed() throws {
        let emptyURLs = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: emptyURLs.directory) }
        try Data().write(to: emptyURLs.checkpoint)
        #expect(ScanCheckpointFileStore.load(
            from: emptyURLs.checkpoint,
            backupURL: emptyURLs.backup
        ).isEmpty)

        let oldURLs = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: oldURLs.directory) }
        var old = makeCheckpoint()
        old.schemaVersion = 0
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(["old": old]).write(to: oldURLs.checkpoint)
        #expect(ScanCheckpointFileStore.load(
            from: oldURLs.checkpoint,
            backupURL: oldURLs.backup
        ).isEmpty)
    }

    @Test("Legacy progress without new fields remains safely resumable")
    func legacyProgressCompatibility() throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let checkpoint = makeCheckpoint(
            phase: .scanning,
            intent: .fullScan,
            directories: ["/Legacy"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(["legacy": checkpoint])
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var legacy = try #require(object["legacy"] as? [String: Any])
        legacy["schemaVersion"] = nil
        legacy["phase"] = nil
        legacy["intent"] = nil
        object["legacy"] = legacy
        try JSONSerialization.data(withJSONObject: object).write(to: urls.checkpoint)

        let loaded = try #require(ScanCheckpointFileStore.load(
            from: urls.checkpoint,
            backupURL: urls.backup
        )["legacy"])

        #expect(loaded.phase == .scanning)
        #expect(loaded.intent == .fullScan)
        #expect(loaded.isUsable)
    }

    @Test("A truncated primary recovers the previous readable backup")
    func truncatedPrimaryUsesBackup() throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let previous = makeCheckpoint(directories: ["/Previous"])
        try ScanCheckpointFileStore.writeSnapshot(
            ["source": previous],
            to: urls.backup,
            backupURL: urls.directory.appendingPathComponent("unused-backup.json")
        )
        try Data("{\"source\":".utf8).write(to: urls.checkpoint)

        let loaded = ScanCheckpointFileStore.load(
            from: urls.checkpoint,
            backupURL: urls.backup
        )

        #expect(loaded == ["source": previous])
    }

    @Test("An interrupted replacement leaves the prior snapshot readable")
    func interruptedWriteKeepsPreviousSnapshot() throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let previous = makeCheckpoint(directories: ["/Previous"])
        let replacement = makeCheckpoint(directories: ["/Replacement"])
        try ScanCheckpointFileStore.writeSnapshot(
            ["source": previous],
            to: urls.checkpoint,
            backupURL: urls.backup
        )
        let orphan = urls.directory.appendingPathComponent("interrupted.replacement")

        var didThrow = false
        do {
            try ScanCheckpointFileStore.writeSnapshot(
                ["source": replacement],
                to: urls.checkpoint,
                backupURL: urls.backup,
                atomicWriter: { data, _, _, _ in
                    try Data(data.prefix(max(1, data.count / 2))).write(to: orphan)
                    throw CocoaError(.fileWriteUnknown)
                }
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(FileManager.default.fileExists(atPath: orphan.path))
        #expect(ScanCheckpointFileStore.load(
            from: urls.checkpoint,
            backupURL: urls.backup
        ) == ["source": previous])
    }

    @Test("A replacement failure leaves the prior snapshot readable")
    func failedWriteKeepsPreviousSnapshot() throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let previous = makeCheckpoint(directories: ["/Previous"])
        try ScanCheckpointFileStore.writeSnapshot(
            ["source": previous],
            to: urls.checkpoint,
            backupURL: urls.backup
        )

        var didThrow = false
        do {
            try ScanCheckpointFileStore.writeSnapshot(
                ["source": makeCheckpoint(directories: ["/Replacement"])],
                to: urls.checkpoint,
                backupURL: urls.backup,
                atomicWriter: { _, _, _, _ in
                    throw CocoaError(.fileWriteNoPermission)
                }
            )
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(ScanCheckpointFileStore.load(
            from: urls.checkpoint,
            backupURL: urls.backup
        ) == ["source": previous])
    }

    @Test("A valid empty snapshot does not revive a stale backup")
    func validEmptySnapshotWinsOverBackup() throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        try ScanCheckpointFileStore.writeSnapshot(
            ["stale": makeCheckpoint()],
            to: urls.backup,
            backupURL: urls.directory.appendingPathComponent("unused-backup.json")
        )
        try Data("{}".utf8).write(to: urls.checkpoint)

        #expect(ScanCheckpointFileStore.load(
            from: urls.checkpoint,
            backupURL: urls.backup
        ).isEmpty)
    }
}

@Suite("Source sync state persistence")
struct SourceSyncStateFileStoreTests {
    @Test("Loaded snapshots skip duplicates while unverified state is repaired")
    func loadedSnapshotSkipsDuplicateWrite() async throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let syncURL = urls.directory.appendingPathComponent("source-sync-states.json")
        let state = makeSourceSyncState(sourceID: "source", marker: "loaded")
        let durableRecorder = SourceSyncStateWriteRecorder()
        let durableStore = SourceSyncStateFileStore(
            url: syncURL,
            initialStates: ["source": state],
            initialSnapshotIsPersisted: true,
            atomicWriter: durableRecorder.write
        )

        _ = try await durableStore.upsert(state, expectedMutationEpoch: 0)
        #expect(durableRecorder.writeCount == 0)

        let repairRecorder = SourceSyncStateWriteRecorder()
        let repairStore = SourceSyncStateFileStore(
            url: syncURL,
            initialStates: ["source": state],
            atomicWriter: repairRecorder.write
        )
        _ = try await repairStore.upsert(state, expectedMutationEpoch: 0)

        #expect(repairRecorder.writeCount == 1)
        #expect(try decodeSourceSyncStates(from: syncURL) == ["source": state])
    }

    @Test("Identical state and absent invalidation do not rewrite the snapshot")
    func unchangedStateDoesNotRewrite() async throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let recorder = SourceSyncStateWriteRecorder()
        let syncURL = urls.directory.appendingPathComponent("source-sync-states.json")
        let store = SourceSyncStateFileStore(
            url: syncURL,
            atomicWriter: recorder.write
        )
        let state = makeSourceSyncState(sourceID: "source", marker: "stable")

        _ = try await store.upsert(state, expectedMutationEpoch: 0)
        _ = try await store.upsert(state, expectedMutationEpoch: 0)
        _ = try await store.invalidate(sourceID: "missing", mutationEpoch: 1)

        #expect(recorder.writeCount == 1)
        #expect(try decodeSourceSyncStates(from: syncURL) == ["source": state])
    }

    @Test("Burst updates retain only the latest follow-up snapshot")
    func burstUpdatesPersistLatestState() async throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let recorder = SourceSyncStateWriteRecorder(blocksFirstWrite: true)
        defer { recorder.releaseFirstWrite() }
        let syncURL = urls.directory.appendingPathComponent("source-sync-states.json")
        let store = SourceSyncStateFileStore(
            url: syncURL,
            atomicWriter: recorder.write
        )
        let initial = makeSourceSyncState(sourceID: "source", marker: "initial")
        let intermediate = makeSourceSyncState(sourceID: "source", marker: "intermediate")
        let latest = makeSourceSyncState(sourceID: "source", marker: "latest")

        let initialTask = Task {
            try await store.upsert(initial, expectedMutationEpoch: 0)
        }
        await recorder.waitForFirstWrite()
        let intermediateTask = Task {
            try await store.upsert(intermediate, expectedMutationEpoch: 0)
        }
        while await store.snapshot()["source"] != intermediate {
            await Task.yield()
        }
        let latestTask = Task {
            try await store.upsert(latest, expectedMutationEpoch: 0)
        }
        while await store.snapshot()["source"] != latest {
            await Task.yield()
        }
        recorder.releaseFirstWrite()

        #expect(try await initialTask.value != nil)
        #expect(try await intermediateTask.value != nil)
        #expect(try await latestTask.value != nil)
        #expect(recorder.writeCount == 2)
        #expect(try decodeSourceSyncStates(from: syncURL) == ["source": latest])
    }

    @Test("A failed atomic write remains pending and is retried")
    func failedWriteIsRetried() async throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let recorder = SourceSyncStateWriteRecorder(failuresBeforeSuccess: 1)
        let syncURL = urls.directory.appendingPathComponent("source-sync-states.json")
        let store = SourceSyncStateFileStore(
            url: syncURL,
            atomicWriter: recorder.write
        )
        let state = makeSourceSyncState(sourceID: "source", marker: "retry")

        await #expect(throws: (any Error).self) {
            try await store.upsert(state, expectedMutationEpoch: 0)
        }
        #expect(recorder.writeCount == 1)
        #expect(!FileManager.default.fileExists(atPath: syncURL.path))

        #expect(try await store.upsert(state, expectedMutationEpoch: 0) != nil)
        #expect(recorder.writeCount == 2)
        #expect(try decodeSourceSyncStates(from: syncURL) == ["source": state])
    }

    @Test("Concurrent source commits merge instead of replacing the snapshot")
    func concurrentSourceCommitsMerge() async throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let syncURL = urls.directory.appendingPathComponent("source-sync-states.json")
        let store = SourceSyncStateFileStore(url: syncURL)

        async let first = store.upsert(
            makeSourceSyncState(sourceID: "source-a", marker: "a"),
            expectedMutationEpoch: 0
        )
        async let second = store.upsert(
            makeSourceSyncState(sourceID: "source-b", marker: "b"),
            expectedMutationEpoch: 0
        )
        let receipts = try await (first, second)

        #expect(receipts.0 != nil)
        #expect(receipts.1 != nil)
        let snapshot = await store.snapshot()
        #expect(Set(snapshot.keys) == ["source-a", "source-b"])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(
            [String: SourceSyncState].self,
            from: Data(contentsOf: syncURL)
        )
        #expect(persisted == snapshot)
    }

    @Test("A credential epoch rejects stale writes without erasing fresh state")
    func credentialEpochRejectsStaleWrites() async throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let store = SourceSyncStateFileStore(
            url: urls.directory.appendingPathComponent("source-sync-states.json")
        )
        let stale = makeSourceSyncState(sourceID: "source", marker: "old")
        let fresh = makeSourceSyncState(sourceID: "source", marker: "new")

        _ = try await store.upsert(stale, expectedMutationEpoch: 0)
        _ = try await store.invalidate(sourceID: "source", mutationEpoch: 1)
        #expect(try await store.upsert(stale, expectedMutationEpoch: 0) == nil)
        #expect(try await store.upsert(fresh, expectedMutationEpoch: 1) != nil)
        #expect(try await store.invalidate(sourceID: "source", mutationEpoch: 1) == nil)

        let snapshot = await store.snapshot()
        #expect(snapshot["source"] == fresh)
    }

    @Test("Cancelling a generation fences its delayed write but keeps committed state")
    func cancelledGenerationCannotOverwriteReplacement() async throws {
        let urls = try makeTemporaryURLs()
        defer { try? FileManager.default.removeItem(at: urls.directory) }
        let store = SourceSyncStateFileStore(
            url: urls.directory.appendingPathComponent("source-sync-states.json")
        )
        let committed = makeSourceSyncState(sourceID: "source", marker: "committed")
        let stale = makeSourceSyncState(sourceID: "source", marker: "cancelled")
        let replacement = makeSourceSyncState(sourceID: "source", marker: "replacement")

        _ = try await store.upsert(committed, expectedMutationEpoch: 0)
        _ = try await store.advanceMutationEpoch(sourceID: "source", mutationEpoch: 1)
        #expect(try await store.upsert(stale, expectedMutationEpoch: 0) == nil)
        #expect(await store.snapshot()["source"] == committed)
        #expect(try await store.upsert(replacement, expectedMutationEpoch: 1) != nil)
        #expect(await store.snapshot()["source"] == replacement)
    }
}

private func makeCheckpoint(
    phase: ScanCheckpointPhase = .scanning,
    intent: ScanCheckpointIntent = .fullScan,
    directories: [String] = ["/Music"],
    totalCount: Int = 0,
    currentFile: String = "",
    pendingDirectories: [String] = ["/Music"],
    baselineCursors: [String: String]? = nil,
    scopeFingerprint: String? = nil,
    baiduSnapshotState: BaiduSnapshotResumeState? = nil,
    baiduTelemetry: SourceSyncTelemetry? = nil,
    subsonicCatalogState: SubsonicCatalogResumeState? = nil
) -> ScanCheckpoint {
    ScanCheckpoint(
        phase: phase,
        intent: intent,
        directories: directories,
        songs: [],
        totalCount: totalCount,
        currentFile: currentFile,
        updatedAt: Date(timeIntervalSince1970: 123),
        scopeFingerprint: scopeFingerprint,
        directoryState: SourceScanResumeState(pendingDirectories: pendingDirectories),
        baselineCursors: baselineCursors,
        baiduSnapshotState: baiduSnapshotState,
        baiduTelemetry: baiduTelemetry,
        subsonicCatalogState: subsonicCatalogState
    )
}

private func makeSourceSyncState(sourceID: String, marker: String) -> SourceSyncState {
    SourceSyncState(
        sourceID: sourceID,
        scopeFingerprint: "scope-\(marker)",
        identityScopeFingerprint: "identity-\(marker)",
        cursors: ["/": "cursor-\(marker)"],
        index: [:],
        scanEpoch: 1
    )
}

private func decodeSourceSyncStates(from url: URL) throws -> [String: SourceSyncState] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
        [String: SourceSyncState].self,
        from: Data(contentsOf: url)
    )
}

private final class SourceSyncStateWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let firstWriteStarted = DispatchSemaphore(value: 0)
    private let firstWriteRelease = DispatchSemaphore(value: 0)
    private let blocksFirstWrite: Bool
    private var failuresBeforeSuccess: Int
    private var writes = 0

    init(
        blocksFirstWrite: Bool = false,
        failuresBeforeSuccess: Int = 0
    ) {
        self.blocksFirstWrite = blocksFirstWrite
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    var writeCount: Int {
        lock.withLock { writes }
    }

    func write(_ data: Data, _ url: URL) throws {
        let attempt = lock.withLock { () -> (number: Int, shouldFail: Bool) in
            writes += 1
            let shouldFail = failuresBeforeSuccess > 0
            failuresBeforeSuccess = max(0, failuresBeforeSuccess - 1)
            return (writes, shouldFail)
        }
        if blocksFirstWrite, attempt.number == 1 {
            firstWriteStarted.signal()
            firstWriteRelease.wait()
        }
        if attempt.shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    func waitForFirstWrite() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [firstWriteStarted] in
                firstWriteStarted.wait()
                continuation.resume()
            }
        }
    }

    func releaseFirstWrite() {
        firstWriteRelease.signal()
    }
}

private func makeTemporaryURLs() throws -> (directory: URL, checkpoint: URL, backup: URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "primuse-scan-checkpoint-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (
        directory,
        directory.appendingPathComponent("scan-checkpoints.json"),
        directory.appendingPathComponent("scan-checkpoints.backup.json")
    )
}
