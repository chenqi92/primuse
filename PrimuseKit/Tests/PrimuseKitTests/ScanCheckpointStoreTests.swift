import Foundation
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
        #expect(checkpoint.permitsNativeQuickSync)
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
        #expect(!deep.permitsNativeQuickSync)
        #expect(quick.intent == .quickOnly)
        #expect(quick.permitsNativeQuickSync)
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

private func makeCheckpoint(
    phase: ScanCheckpointPhase = .scanning,
    intent: ScanCheckpointIntent = .fullScan,
    directories: [String] = ["/Music"],
    totalCount: Int = 0,
    currentFile: String = "",
    pendingDirectories: [String] = ["/Music"],
    baselineCursors: [String: String]? = nil
) -> ScanCheckpoint {
    ScanCheckpoint(
        phase: phase,
        intent: intent,
        directories: directories,
        songs: [],
        totalCount: totalCount,
        currentFile: currentFile,
        updatedAt: Date(timeIntervalSince1970: 123),
        directoryState: SourceScanResumeState(pendingDirectories: pendingDirectories),
        baselineCursors: baselineCursors
    )
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
